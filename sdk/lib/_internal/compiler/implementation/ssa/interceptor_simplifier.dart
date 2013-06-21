// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of ssa;

/**
 * This phase simplifies interceptors in multiple ways:
 *
 * 1) If the interceptor is for an object whose type is known, it
 * tries to use a constant interceptor instead.
 *
 * 2) It specializes interceptors based on the selectors it is being
 * called with.
 *
 * 3) If we know the object is not intercepted, we just use it
 * instead.
 *
 * 4) It replaces all interceptors that are used only once with
 * one-shot interceptors. It saves code size and makes the receiver of
 * an intercepted call a candidate for being generated at use site.
 *
 */
class SsaSimplifyInterceptors extends HBaseVisitor
    implements OptimizationPhase {
  final String name = "SsaSimplifyInterceptors";
  final ConstantSystem constantSystem;
  final Compiler compiler;
  final CodegenWorkItem work;
  HGraph graph;

  SsaSimplifyInterceptors(this.compiler, this.constantSystem, this.work);

  void visitGraph(HGraph graph) {
    this.graph = graph;
    visitDominatorTree(graph);
  }

  void visitBasicBlock(HBasicBlock node) {
    currentBlock = node;

    HInstruction instruction = node.first;
    while (instruction != null) {
      bool shouldRemove = instruction.accept(this);
      HInstruction next = instruction.next;
      if (shouldRemove) {
        instruction.block.remove(instruction);
      }
      instruction = next;
    }
  }

  bool visitInstruction(HInstruction instruction) => false;

  bool canUseSelfForInterceptor(HType receiverType,
                                Set<ClassElement> interceptedClasses) {
    JavaScriptBackend backend = compiler.backend;
    if (receiverType.canBePrimitive(compiler)) {
      // Primitives always need interceptors.
      return false;
    }
    if (receiverType.canBeNull()
        && interceptedClasses.contains(backend.jsNullClass)) {
      // Need the JSNull interceptor.
      return false;
    }

    // [interceptedClasses] is sparse - it is just the classes that define some
    // intercepted method.  Their subclasses (that inherit the method) are
    // implicit, so we have to extend them.

    TypeMask receiverMask = receiverType.computeMask(compiler);
    return interceptedClasses
        .where((cls) => cls != compiler.objectClass)
        .map((cls) => backend.classesMixedIntoNativeClasses.contains(cls)
            ? new TypeMask.subtype(cls.rawType)
            : new TypeMask.subclass(cls.rawType))
        .every((mask) => receiverMask.intersection(mask, compiler).isEmpty);
  }

  HInstruction tryComputeConstantInterceptor(
      HInstruction input,
      Set<ClassElement> interceptedClasses) {
    if (input == graph.explicitReceiverParameter) {
      // If `explicitReceiverParameter` is set it means the current method is an
      // interceptor method, and `this` is the interceptor.  The caller just did
      // `getInterceptor(foo).currentMethod(foo)` to enter the current method.
      return graph.thisInstruction;
    }

    HType type = input.instructionType;
    ClassElement constantInterceptor;
    JavaScriptBackend backend = compiler.backend;
    if (type.canBeNull()) {
      if (type.isNull()) {
        constantInterceptor = backend.jsNullClass;
      }
    } else if (type.isInteger()) {
      constantInterceptor = backend.jsIntClass;
    } else if (type.isDouble()) {
      constantInterceptor = backend.jsDoubleClass;
    } else if (type.isBoolean()) {
      constantInterceptor = backend.jsBoolClass;
    } else if (type.isString(compiler)) {
      constantInterceptor = backend.jsStringClass;
    } else if (type.isArray(compiler)) {
      constantInterceptor = backend.jsArrayClass;
    } else if (type.isNumber()
        && !interceptedClasses.contains(backend.jsIntClass)
        && !interceptedClasses.contains(backend.jsDoubleClass)) {
      // If the method being intercepted is not defined in [int] or [double] we
      // can safely use the number interceptor.  This is because none of the
      // [int] or [double] methods are called from a method defined on [num].
      constantInterceptor = backend.jsNumberClass;
    } else {
      // Try to find constant interceptor for a native class.  If the receiver
      // is constrained to a leaf native class, we can use the class's
      // interceptor directly.

      // TODO(sra): Key DOM classes like Node, Element and Event are not leaf
      // classes.  When the receiver type is not a leaf class, we might still be
      // able to use the receiver class as a constant interceptor.  It is
      // usually the case that methods defined on a non-leaf class don't test
      // for a subclass or call methods defined on a subclass.  Provided the
      // code is completely insensitive to the specific instance subclasses, we
      // can use the non-leaf class directly.
      ClassElement element = type.computeMask(compiler).singleClass(compiler);
      if (element != null && element.isNative()) {
        constantInterceptor = element;
      }
    }

    if (constantInterceptor == null) return null;
    if (constantInterceptor == work.element.getEnclosingClass()) {
      return graph.thisInstruction;
    }

    Constant constant = new InterceptorConstant(
        constantInterceptor.computeType(compiler));
    return graph.addConstant(constant, compiler);
  }

  HInstruction findDominator(Iterable<HInstruction> instructions) {
    HInstruction result;
    L1: for (HInstruction candidate in instructions) {
      for (HInstruction current in instructions) {
        if (current != candidate && !candidate.dominates(current)) continue L1;
      }
      result = candidate;
      break;
    }
    return result;
  }

  bool visitInterceptor(HInterceptor node) {
    if (node.isConstant()) return false;

    // If the interceptor is used by multiple instructions, specialize
    // it with a set of classes it intercepts.
    Set<ClassElement> interceptedClasses;
    JavaScriptBackend backend = compiler.backend;
    HInstruction dominator =
        findDominator(node.usedBy.where((i) => i is HInvokeDynamic));
    // If there is an instruction that dominates all others, we can
    // use only the selector of that instruction.
    if (dominator != null) {
      interceptedClasses = 
            backend.getInterceptedClassesOn(dominator.selector.name);

      // If we found that we need number, we must still go through all
      // uses to check if they require int, or double.
      if (interceptedClasses.contains(backend.jsNumberClass)
          && !(interceptedClasses.contains(backend.jsDoubleClass)
               || interceptedClasses.contains(backend.jsIntClass))) {
        for (var user in node.usedBy) {
          if (user is! HInvoke) continue;
          Set<ClassElement> intercepted =
              backend.getInterceptedClassesOn(user.selector.name);
          if (intercepted.contains(backend.jsIntClass)) {
            interceptedClasses.add(backend.jsIntClass);
          }
          if (intercepted.contains(backend.jsDoubleClass)) {
            interceptedClasses.add(backend.jsDoubleClass);
          }
        }
      }
    } else {
      interceptedClasses = new Set<ClassElement>();
      for (var user in node.usedBy) {
        if (user is! HInvoke) continue;
        // We don't handle escaping interceptors yet.
        interceptedClasses.addAll(
            backend.getInterceptedClassesOn(user.selector.name));
      }
    }

    HInstruction receiver = node.receiver;
    HType instructionType = receiver.instructionType;
    if (canUseSelfForInterceptor(instructionType, interceptedClasses)) {
      node.block.rewrite(node, receiver);
      return false;
    }

    // Try computing a constant interceptor.
    HInstruction constantInterceptor =
        tryComputeConstantInterceptor(receiver, interceptedClasses);
    if (constantInterceptor != null) {
      node.block.rewrite(node, constantInterceptor);
      return false;
    }

    if (node.usedBy.every((e) => e is HBailoutTarget || e is HTypeGuard)) {
      // The interceptor is only used by the bailout version. We don't
      // remove it because the bailout version will use it.
      node.interceptedClasses = backend.interceptedClasses;
      return false;
    }

    node.interceptedClasses = interceptedClasses;

    // Try creating a one-shot interceptor.
    if (node.usedBy.length != 1) return false;
    if (node.usedBy[0] is !HInvokeDynamic) return false;

    HInvokeDynamic user = node.usedBy[0];

    // If [node] was loop hoisted, we keep the interceptor.
    if (!user.hasSameLoopHeaderAs(node)) return false;

    // Replace the user with a [HOneShotInterceptor].
    HConstant nullConstant = graph.addConstantNull(compiler);
    List<HInstruction> inputs = new List<HInstruction>.from(user.inputs);
    inputs[0] = nullConstant;
    HOneShotInterceptor interceptor = new HOneShotInterceptor(
        user.selector, inputs, node.interceptedClasses);
    interceptor.sourcePosition = user.sourcePosition;
    interceptor.sourceElement = user.sourceElement;
    interceptor.instructionType = user.instructionType;

    HBasicBlock block = user.block;
    block.addAfter(user, interceptor);
    block.rewrite(user, interceptor);
    block.remove(user);
    return true;
  }

  
  bool visitOneShotInterceptor(HOneShotInterceptor node) {
    HInstruction constant = tryComputeConstantInterceptor(
        node.inputs[1], node.interceptedClasses);

    if (constant == null) return false;

    Selector selector = node.selector;
    // TODO(ngeoffray): make one shot interceptors know whether
    // they have side effects.
    HInstruction instruction;
    if (selector.isGetter()) {
      instruction= new HInvokeDynamicGetter(
          selector,
          node.element,
          <HInstruction>[constant, node.inputs[1]],
          false);
    } else if (node.selector.isSetter()) {
      instruction = new HInvokeDynamicSetter(
          selector,
          node.element,
          <HInstruction>[constant, node.inputs[1], node.inputs[2]],
          false);
    } else {
      List<HInstruction> inputs = new List<HInstruction>.from(node.inputs);
      inputs[0] = constant;
      instruction = new HInvokeDynamicMethod(selector, inputs, true);
    }

    HBasicBlock block = node.block;
    block.addAfter(node, instruction);
    block.rewrite(node, instruction);
    return true;
  }
}