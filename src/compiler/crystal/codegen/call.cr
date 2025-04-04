require "./codegen"

class Crystal::CodeGenVisitor
  def visit(node : Call)
    if node.expanded
      raise "BUG: #{node} at #{node.location} should have been expanded"
    end

    target_defs = node.target_defs
    unless target_defs
      node.raise "BUG: no target defs"
    end

    if target_defs.size > 1
      codegen_dispatch node, target_defs
      return false
    end

    owner = node.super? ? node.scope : node.target_def.owner

    call_args = prepare_call_args node, owner

    # It can happen that one of the arguments caused an unreachable
    # to happen, so we must stop here
    return false if @builder.end

    if block = node.block
      # A block might turn into a proc literal but not be used if it participates in a dispatch
      if (fun_literal = block.fun_literal) && node.target_def.uses_block_arg?
        codegen_call_with_block_as_fun_literal(node, fun_literal, owner, call_args)
      else
        codegen_call_with_block(node, block, owner, call_args)
      end
    else
      codegen_call(node, node.target_def, owner, call_args)
    end

    false
  end

  def prepare_call_args(node, owner)
    target_def = node.target_def
    if external = target_def.c_calling_convention?
      prepare_call_args_external(node, external, owner)
    else
      prepare_call_args_non_external(node, target_def, owner)
    end
  end

  def prepare_call_args_non_external(node, target_def, owner)
    is_primitive = target_def.body.is_a?(Primitive)

    call_args = Array(LLVM::Value).new(node.args.size + 1)
    old_needs_value = @needs_value

    obj = node.obj

    case obj
    when Path
      # Non-generic metaclasses and lib types do not need a self argument,
      # reading them should not have side effects unless `obj` turns out to be
      # a constant with an initializer (e.g. `A = (puts 1; Int32)` has a side
      # effect).
      if obj.type.passed_as_self? || obj.target_const
        request_value(obj)
      end
    when ASTNode
      # Always accept obj: even if it's not passed as self this might
      # involve intermediate calls with side effects.
      request_value(obj)
    end

    # First self.
    if owner.passed_as_self?
      if owner.nil_type?
        call_args << llvm_nil
      else
        if obj && obj.type.passed_as_self?
          call_args << downcast(@last, target_def.owner, obj.type, true)
        else
          if node.uses_with_scope? && (yield_scope = context.vars["%scope"]?)
            call_args << downcast(yield_scope.pointer, target_def.owner, node.with_scope.not_nil!, true)
          else
            call_args << llvm_self(owner)
          end
        end
      end
    end

    c_calling_convention = target_def.c_calling_convention?

    # Then the arguments.
    node.args.zip(target_def.args) do |arg, def_arg|
      request_value(arg)

      if arg.type.void?
        call_arg = int8(0)
      else
        call_arg = @last
        call_arg = llvm_nil if arg.type.nil_type?
        call_arg = downcast(call_arg, def_arg.type, arg.type, true)
      end

      # - C calling convention passing needs a separate handling of pass-by-value
      # - Primitives might need a separate handling (for example invoking a Proc)
      if arg.type.passed_by_value? && !c_calling_convention && !is_primitive
        call_arg = load(llvm_type(arg.type), call_arg)
      end

      call_args << call_arg
    end

    # Then special variables ($~, $?)
    target_def.special_vars.try &.each do |special_var_name|
      call_args << context.vars[special_var_name].pointer
    end

    # Then magic constants (__LINE__, __FILE__, __DIR__)
    node.args.size.upto(target_def.args.size - 1) do |index|
      arg = target_def.args[index]
      default_value = arg.default_value.as(MagicConstant)
      location = node.location
      end_location = node.end_location
      case default_value.name
      when .magic_line?
        call_args << int32(MagicConstant.expand_line(location))
      when .magic_end_line?
        call_args << int32(MagicConstant.expand_line(end_location))
      when .magic_file?
        call_args << build_string_constant(MagicConstant.expand_file(location))
      when .magic_dir?
        call_args << build_string_constant(MagicConstant.expand_dir(location))
      else
        default_value.raise "BUG: unknown magic constant: #{default_value.name}"
      end
    end

    @needs_value = old_needs_value

    call_args
  end

  def call_abi_info(target_def, node)
    # For varargs we need to compute abi info for the arguments, which may be more
    # than those specified in the function definition
    if target_def.varargs?
      abi_info(target_def, node)
    else
      abi_info(target_def)
    end
  end

  def prepare_call_args_external(node, target_def, owner)
    abi_info = call_abi_info(target_def, node)

    call_args = Array(LLVM::Value).new(node.args.size + 1)
    old_needs_value = @needs_value

    if abi_info.return_type.attr == LLVM::Attribute::StructRet
      sret_value = @sret_value = alloca abi_info.return_type.type
      call_args << sret_value
    end

    target_def_args_size = target_def.args.size

    node.args.each_with_index do |arg, i|
      if arg.is_a?(Out)
        case exp = arg.exp
        when Var
          # Just get a pointer to the variable
          call_arg = context.vars[exp.name].pointer
        when InstanceVar
          # Just get a pointer to the instance variable
          call_arg = instance_var_ptr(type, exp.name, llvm_self_ptr)
        when Underscore
          # Allocate stack memory, but discard the value
          call_arg = alloca(llvm_type(arg.type))
        else
          arg.raise "BUG: out argument was #{exp}"
        end
      else
        request_value(arg)

        if arg.type.void?
          call_arg = int8(0)
        else
          def_arg = target_def.args[i]?

          call_arg = @last
          call_arg = llvm_nil if arg.type.nil_type?

          if def_arg && arg.type.nil_type? && (def_arg.type.pointer? || def_arg.type.proc?)
            # Nil to pointer
            call_arg = llvm_c_type(def_arg.type).null
          else
            if def_arg
              call_arg = downcast(call_arg, def_arg.type, arg.type, true)
            else
              # Def argument might be missing if it's a variadic call
              if arg.type.nil_type?
                call_arg = llvm_context.void_pointer.null
              end
            end
          end
        end
      end

      if arg.type.proc?
        # Try first with the def arg type (might be a proc pointer that return void,
        # while the argument's type a proc pointer that return something else)
        call_arg = check_proc_is_not_closure(call_arg, def_arg.try(&.type) || arg.type)
      end

      abi_arg_type = abi_info.arg_types[i]
      case abi_arg_type.kind
      in .direct?
        call_arg = codegen_direct_abi_call(arg.type, call_arg, abi_arg_type) unless arg.type.nil_type?
      in .indirect?
        call_arg = codegen_indirect_abi_call(call_arg, abi_arg_type) unless arg.type.nil_type?
      in .ignore?
        # Ignore
        next
      end

      # If we are passing variadic arguments there are some special rules
      if i >= target_def_args_size
        arg_type = arg.type.remove_indirection
        if arg_type.is_a?(FloatType) && arg_type.kind.bytesize < 64
          # Floats must be passed as doubles (there are no float varargs)
          call_arg = extend_float @program.float64, call_arg
        elsif arg_type.is_a?(IntegerType) && arg_type.kind.bytesize < 32
          # Integer with a size less that `int` must be converted to `int`
          call_arg = extend_int arg_type, @program.int32, call_arg
        end
      end

      call_args << call_arg
    end

    @needs_value = old_needs_value

    call_args
  end

  def codegen_direct_abi_call(call_arg_type, call_arg, abi_arg_type)
    if cast = abi_arg_type.cast
      final_value = alloca cast
      final_value_casted = cast_to_void_pointer final_value
      gep_call_arg = cast_to_void_pointer gep(llvm_type(call_arg_type), call_arg, 0, 0)
      size = @abi.size(abi_arg_type.type)
      align = @abi.align(abi_arg_type.type)
      memcpy(final_value_casted, gep_call_arg, size_t(size), align, int1(0))
      call_arg = load cast, final_value
    else
      # Keep same call arg
    end
    call_arg
  end

  # For an indirect argument we need to make a copy of the value in the stack
  # and *replace* the call argument by a pointer to the allocated memory
  def codegen_indirect_abi_call(call_arg, abi_arg_type)
    final_value = alloca abi_arg_type.type
    final_value_casted = cast_to_void_pointer final_value
    call_arg_casted = cast_to_void_pointer call_arg
    size = @abi.size(abi_arg_type.type)
    align = @abi.align(abi_arg_type.type)
    memcpy(final_value_casted, call_arg_casted, size_t(size), align, int1(0))
    final_value
  end

  def codegen_call_with_block(node, block, self_type, call_args)
    set_current_debug_location node if @debug.line_numbers?

    with_cloned_context do |old_block_context|
      context.vars = old_block_context.vars.dup
      context.closure_parent_context = old_block_context

      # Allocate block vars, but first undefine variables outside
      # the block with the same name. This can only happen in this case:
      #
      #     a = foo { |a| }
      #
      # that is, when assigning to a variable with the same name as
      # a block argument (no shadowing here)
      undef_vars block.vars, block
      alloca_non_closured_vars block.vars, block

      with_cloned_context do |old_context|
        context.block = block
        context.block_context = old_context
        context.vars = LLVMVars.new
        context.type = self_type
        context.reset_closure

        target_def = node.target_def

        set_ensure_exception_handler(node)
        set_ensure_exception_handler(target_def)

        args_base_index = create_local_copy_of_block_self(self_type, call_args)

        # Don't reset nilable vars here because we do it right before inlining the method body
        alloca_vars target_def.vars, target_def, reset_nilable_vars: false

        create_local_copy_of_block_args(target_def, self_type, call_args, args_base_index)

        Phi.open(self, node) do |phi|
          context.return_phi = phi

          # Reset vars that are declared inside the def and are nilable
          reset_nilable_vars(target_def)

          request_value(target_def.body)

          phi.add @last, target_def.body.type?, last: true
        end
      end
    end
  end

  def codegen_call_with_block_as_fun_literal(node, fun_literal, self_type, call_args)
    accept fun_literal
    call_args.push @last

    target_def = node.target_def
    func = target_def_fun(target_def, self_type)

    codegen_call_or_invoke(node, target_def, self_type, func, call_args, target_def.raises?, target_def.type)
  end

  def codegen_dispatch(node, target_defs)
    new_vars = context.vars.dup
    old_needs_value = @needs_value

    # Get type_id of obj or owner
    if node_obj = node.obj
      owner = node_obj.type
      request_value(node_obj)
      obj_type_id = @last
    elsif node.uses_with_scope? && (with_scope = node.with_scope)
      owner = with_scope
      obj_type_id = context.vars["%scope"].pointer
    else
      owner = node.scope
      obj_type_id = llvm_self
    end
    obj_type_id = type_id(obj_type_id, owner)

    # Create self var if available
    if node_obj
      # call `#remove_indirection` here so that the downcast call in
      # `#visit(Var)` doesn't spend time expanding module types again and again
      # (it should be the only use site of `node_obj.type`)
      new_vars["%self"] = LLVMVar.new(@last, node_obj.type.remove_indirection, true)
    end

    # Get type if of args and create arg vars
    arg_type_ids = node.args.map_with_index do |arg, i|
      request_value(arg)
      new_vars["%arg#{i}"] = LLVMVar.new(@last, arg.type, true)
      type_id(@last, arg.type)
    end

    # Reuse this call for each dispatch branch
    call = Call.new(node_obj ? Var.new("%self") : nil, node.name, node.args.map_with_index { |arg, i| Var.new("%arg#{i}").as(ASTNode) }, node.block).at(node)
    call.scope = with_scope || node.scope
    call.with_scope = with_scope
    call.uses_with_scope = node.uses_with_scope?
    call.name_location = node.name_location

    is_super = node.super?

    # call `#remove_indirection` here so that the `match_type_id` below doesn't
    # spend time expanding module types again and again
    owner = owner.remove_indirection unless is_super

    with_cloned_context do
      context.vars = new_vars

      Phi.open(self, node, old_needs_value) do |phi|
        # Iterate all defs and check if any match the current types, given their ids (obj_type_id and arg_type_ids)
        target_defs.each do |a_def|
          if is_super
            # A super call always matches the obj type
            result = int1(1)
          else
            result = match_type_id(owner, a_def.owner, obj_type_id)
          end
          node.args.each_with_index do |node_arg, i|
            a_def_arg = a_def.args[i]
            if node_arg.supports_autocast?(!@program.has_flag?("no_number_autocast"))
              # If a call argument is a literal like 1 or :foo then
              # it will match all the multidispatch overloads because
              # it has a single type and there's no way some overload
              # (from the ones we decided that match) won't match,
              # because if it doesn't match then we wouldn't have included
              # it in the match list.
              # Matches, so nothing to do
            else
              result = and(result, match_type_id(node_arg.type, a_def_arg.type, arg_type_ids[i]))
            end
          end

          current_def_label, next_def_label = new_blocks "current_def", "next_def"
          cond result, current_def_label, next_def_label

          position_at_end current_def_label

          # Prepare this specific call
          call.target_defs = [a_def] of Def
          call.obj.try &.set_type(a_def.owner)
          call.args.zip(a_def.args) do |call_arg, a_def_arg|
            call_arg.set_type(a_def_arg.type)
          end
          if (node_block = node.block) && node_block.break.type?
            call.set_type(@program.type_merge [a_def.type, node_block.break.type] of Type)
          else
            call.set_type(a_def.type)
          end
          accept call

          phi.add @last, call.type
          position_at_end next_def_label
        end
        unreachable
      end
    end

    @needs_value = old_needs_value
  end

  def codegen_call(node, target_def, self_type, call_args)
    body = target_def.body

    # Try to inline the call
    if try_inline_call(target_def, body, self_type, call_args)
      return
    end

    # We also always inline primitives
    if body.is_a?(Primitive)
      # Change context type: faster then creating a new context
      old_type = context.type
      context.type = self_type
      codegen_primitive(node, body, target_def, call_args)
      context.type = old_type
      return true
    end

    func = target_def_fun(target_def, self_type)
    codegen_call_or_invoke(node, target_def, self_type, func, call_args, target_def.raises?, target_def.type)
  end

  # If a method's body is just a simple literal, "self", or an instance variable,
  # we always inline it: less code generated, easier job for LLVM to optimize, and
  # avoid a call in non-release builds.
  #
  # Do this even in debug mode, because there's not much use in stepping
  # to read a constant value or the value of an instance variable.
  # Additionally, not inlining instance variable getters changes the semantic
  # a program, so we must always inline these.
  def try_inline_call(target_def, body, self_type, call_args)
    return false if target_def.is_a?(External)

    case body
    when Nop, NilLiteral, BoolLiteral, CharLiteral, StringLiteral, NumberLiteral, SymbolLiteral
      return true unless @needs_value

      accept body
      inline_call_return_value target_def, body
      true
    when Var
      if body.name == "self"
        return true unless @needs_value

        @last = self_type.passed_as_self? ? call_args.first : type_id(self_type)
        inline_call_return_value target_def, body
        true
      else
        false
      end
    when InstanceVar
      return true unless @needs_value

      read_instance_var(body.type, self_type, body.name, call_args.first)
      inline_call_return_value target_def, body
      true
    else
      false
    end
  end

  def inline_call_return_value(target_def, body)
    if target_def.type.nil_type?
      @last = llvm_nil
    else
      @last = upcast(@last, target_def.type, body.type)
    end
  end

  def codegen_call_or_invoke(node, target_def, self_type, func, call_args, raises, type, is_closure = false, fun_type = nil)
    # If *fun_type* is not nil, then this method is being called from
    # `codegen_primitive_proc_call` and *node* is simply `Proc#call`'s "body";
    # in that case do not replace line numbers so that call stacks will continue
    # using the original invocation
    set_current_debug_location node if @debug.line_numbers? && fun_type.nil?

    if raises && (rescue_block = @rescue_block)
      invoke_out_block = new_block "invoke_out"
      @last = invoke func, call_args, invoke_out_block, rescue_block
      position_at_end invoke_out_block
    else
      @last = call func, call_args
    end

    if target_def.is_a?(External) && (call_convention = target_def.call_convention)
      @last.call_convention = call_convention
    end

    if @builder.end
      return @last
    end

    set_call_attributes node, target_def, self_type, is_closure, fun_type

    external = target_def.try &.c_calling_convention?

    if external && (external.type.proc? || external.type.is_a?(NilableProcType))
      fun_ptr = cast_to_void_pointer(@last)
      ctx_ptr = llvm_context.void_pointer.null
      return @last = make_fun(external.type, fun_ptr, ctx_ptr)
    end

    if external
      if type.no_return?
        unreachable
      else
        abi_return = abi_info(external).return_type
        case abi_return.kind
        in .direct?
          if cast = abi_return.cast
            cast1 = alloca cast
            store @last, cast1
            cast2 = cast_to_void_pointer(cast1)
            final_value = alloca abi_return.type
            final_value_casted = cast_to_void_pointer final_value
            size = @abi.size(abi_return.type)
            align = @abi.align(abi_return.type)
            memcpy(final_value_casted, cast2, size_t(size), align, int1(0))
            @last = final_value
          end
        in .indirect?
          @last = @sret_value.not_nil!
        in .ignore?
          # Nothing
        end
      end
    else
      case type
      when .no_return?
        unreachable
      when .passed_by_value?
        if @needs_value
          union = alloca llvm_type(type)
          store @last, union
          @last = union
        else
          @last = llvm_nil
        end
      end
    end

    @last
  end

  def set_call_attributes(node : Call, target_def, self_type, is_closure, fun_type)
    if external = target_def.c_calling_convention?
      set_call_attributes_external(node, external)
    else
      # Non-external methods/functions have no arguments attributes
    end
  end

  def set_call_attributes_external(node, target_def)
    abi_info = call_abi_info(target_def, node)

    sret = sret?(abi_info)
    arg_offset = 1
    arg_offset += 1 if sret

    node.args.each_with_index do |arg, i|
      # If the argument is out the type might be a struct but we don't pass anything byval
      next if node.args[i]?.try &.is_a?(Out)

      abi_arg_type = abi_info.arg_types[i]?
      if abi_arg_type && (attr = abi_arg_type.attr)
        @last.add_instruction_attribute(i + arg_offset, attr, llvm_context, abi_arg_type.type)
      end
    end

    if sret
      @last.add_instruction_attribute(1, LLVM::Attribute::StructRet, llvm_context, abi_info.return_type.type)
    end
  end

  # This is for function pointer calls and exception handler re-raise
  def set_call_attributes(node, target_def, self_type, is_closure, fun_type)
    if target_def && target_def.abi_info?
      abi_info = abi_info(target_def)
    end

    sret = abi_info && sret?(abi_info)
    arg_offset = is_closure ? 2 : 1
    arg_offset += 1 if sret

    arg_types = fun_type.try(&.arg_types) || target_def.try &.args.map &.type
    arg_types.try &.each_with_index do |arg_type, i|
      if abi_info && (abi_arg_type = abi_info.arg_types[i]?) && (attr = abi_arg_type.attr)
        @last.add_instruction_attribute(i + arg_offset, attr, llvm_context, abi_arg_type.type)
      end
    end

    if abi_info && sret
      @last.add_instruction_attribute(1, LLVM::Attribute::StructRet, llvm_context, abi_info.return_type.type)
    end
  end

  def sret?(abi_info)
    abi_info.return_type.attr == LLVM::Attribute::StructRet
  end
end
