//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift
@_implementationOnly import _SwiftConcurrencyShims

/// Property wrapper that defines a key for task-local storage.
///
/// A task-local value is a value
/// that can be accessed in the context of a task.
/// It's implicitly carried with the task, and is accessible by any
/// child tasks the task creates,
/// for example by using `TaskGroup` or `async`-`let`.
/// The value that a task sets for a task-local value
/// is guaranteed to not outlive that task.
///
/// A task-local value must be declared as a static stored constant or property --
/// for example:
///
///     enum TracingExample {
///         @TaskLocal static let traceID: TraceID?
///     }
///
/// ### Default Values
///
/// When you declare a task-local value, you specify its initial value,
/// which is also used as its default value.
/// The one exception is optionals,
/// which have a default value of `nil` if you don't specify an initial value.
/// The default value is used if the task-local value
/// is read from a context that has doesn't have any current task ---
/// for example, a synchronous function
/// that's called without any asynchronous function in its call stack.
///
/// ### Reading Task-Local Values
///
/// Any code running within a task can read that task's task-local storage,
/// including synchronous functions that are called from within the task.
/// Reading task local values
/// looks the same as reading a normal static property:
///
///     guard let traceID = TracingExample.traceID else {
///         print("no trace id")
///         return
///     }
///     print(traceID)
///
/// You can read task-local values
/// from both asynchronous and synchronous functions.
/// Within asynchronous functions,
/// as a "current" task is always guaranteed to exist,
/// this will perform the lookup in the task local context.
///
/// A lookup made from the context of a synchronous function, that is not called
/// from an asynchronous function (!), will immediately return the task-local's
/// default value.
///
/// ◊TODO: performance considerations: this can be SLOW
///
/// ### Binding Task-local Values
///
/// Task-local values cannot be set directly and must instead be bound using
/// the `withValue()` method on the property's projected value. The value is only bound
/// for the duration of that scope, and is available to any child tasks which
/// are created within that scope.
///
/// Detached tasks don't inherit task-local values,
/// however tasks created using the `Task.init()` initializer
/// inherit task-locals by copying them to the new asynchronous task,
/// even though it is an unstructured task.
///
/// ### Examples
///
///     @TaskLocal
///     static var traceID: TraceID?
///
///     print("traceID: \(traceID)") // traceID: nil
///
///     $traceID.withValue(1234) { // bind the value
///       print("traceID: \(traceID)") // traceID: 1234
///       call() // traceID: 1234
///
///       // Unstructured tasks inherit task locals by copying.
///       Task {
///         call() // traceID: 1234
///       }
///
///       // Detached tasks don't inherit task-local values.
///       Task.detached {
///         call() // traceID: nil
///       }
///     }
///
///     func call() {
///       print("traceID: \(traceID)") // 1234
///     }
///
/// This type must be a `class` so it has a stable identity, that is used as key
/// value for lookups in the task local storage.
@propertyWrapper
@available(SwiftStdlib 5.1, *)
public final class TaskLocal<Value: Sendable>: Sendable, CustomStringConvertible {
  let defaultValue: Value

  public init(wrappedValue defaultValue: Value) {
    self.defaultValue = defaultValue
  }

  var key: Builtin.RawPointer {
    unsafeBitCast(self, to: Builtin.RawPointer.self)
  }

  /// Gets the value currently bound to this task-local from the current task.
  ///
  /// If no current task is available in the context where this call is made,
  /// or if the task-local has no value bound, this will return the `defaultValue`
  /// of the task local.
  public func get() -> Value {
    guard let rawValue = _taskLocalValueGet(key: key) else {
      return self.defaultValue
    }

    // Take the value; The type should be correct by construction
    let storagePtr =
        rawValue.bindMemory(to: Value.self, capacity: 1)
    return UnsafeMutablePointer<Value>(mutating: storagePtr).pointee
  }

  /// Binds the task-local to the specific value for the duration of the asynchronous operation.
  ///
  /// The value is available throughout the execution of the operation closure,
  /// including any `get` operations performed by child-tasks created during the
  /// execution of the operation closure.
  ///
  /// If the same task-local is bound multiple times, be it in the same task, or
  /// in specific child tasks, the more specific (i.e. "deeper") binding is
  /// returned when the value is read.
  ///
  /// If the value is a reference type, it will be retained for the duration of
  /// the operation closure.
  @discardableResult
  public func withValue<R>(_ valueDuringOperation: Value, operation: () async throws -> R,
                           file: String = #fileID, line: UInt = #line) async rethrows -> R {
    // check if we're not trying to bind a value from an illegal context; this may crash
    _checkIllegalTaskLocalBindingWithinWithTaskGroup(file: file, line: line)

    _taskLocalValuePush(key: key, value: valueDuringOperation)
    defer { _taskLocalValuePop() }

    return try await operation()
  }

  /// Binds the task-local to the specific value for the duration of the
  /// synchronous operation.
  ///
  /// The value is available throughout the execution of the operation closure,
  /// including any `get` operations performed by child-tasks created during the
  /// execution of the operation closure.
  ///
  /// If the same task-local is bound multiple times, be it in the same task, or
  /// in specific child tasks, the "more specific" binding is returned when the
  /// value is read.
  ///
  /// If the value is a reference type, it will be retained for the duration of
  /// the operation closure.
  @discardableResult
  public func withValue<R>(_ valueDuringOperation: Value, operation: () throws -> R,
                           file: String = #fileID, line: UInt = #line) rethrows -> R {
    // check if we're not trying to bind a value from an illegal context; this may crash
    _checkIllegalTaskLocalBindingWithinWithTaskGroup(file: file, line: line)

    _taskLocalValuePush(key: key, value: valueDuringOperation)
    defer { _taskLocalValuePop() }

    return try operation()
  }

  public var projectedValue: TaskLocal<Value> {
    get {
      self
    }

    @available(*, unavailable, message: "use '$myTaskLocal.withValue(_:do:)' instead")
    set {
      fatalError("Illegal attempt to set a \(Self.self) value, use `withValue(...) { ... }` instead.")
    }
  }

  // This subscript is used to enforce that the property wrapper may only be used
  // on static (or rather, "without enclosing instance") properties.
  // This is done by marking the `_enclosingInstance` as `Never` which informs
  // the type-checker that this property-wrapper never wants to have an enclosing
  // instance (it is impossible to declare a property wrapper inside the `Never`
  // type).
  @available(*, unavailable, message: "property wrappers cannot be instance members")
  public static subscript(
    _enclosingInstance object: Never,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<Never, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<Never, TaskLocal<Value>>
  ) -> Value {
    get {
      fatalError("Will never be executed, since enclosing instance is Never")
    }
  }

  public var wrappedValue: Value {
    self.get()
  }

  public var description: String {
    "\(Self.self)(defaultValue: \(self.defaultValue))"
  }

}

// ==== ------------------------------------------------------------------------

@available(SwiftStdlib 5.1, *)
@_silgen_name("swift_task_localValuePush")
func _taskLocalValuePush<Value>(
  key: Builtin.RawPointer/*: Key*/,
  value: __owned Value
) // where Key: TaskLocal

@available(SwiftStdlib 5.1, *)
@_silgen_name("swift_task_localValuePop")
func _taskLocalValuePop()

@available(SwiftStdlib 5.1, *)
@_silgen_name("swift_task_localValueGet")
func _taskLocalValueGet(
  key: Builtin.RawPointer/*Key*/
) -> UnsafeMutableRawPointer? // where Key: TaskLocal

@available(SwiftStdlib 5.1, *)
@_silgen_name("swift_task_localsCopyTo")
func _taskLocalsCopy(
  to target: Builtin.NativeObject
)

// ==== Checks -----------------------------------------------------------------

@available(SwiftStdlib 5.1, *)
@usableFromInline
func _checkIllegalTaskLocalBindingWithinWithTaskGroup(file: String, line: UInt) {
  if _taskHasTaskGroupStatusRecord() {
    file.withCString { _fileStart in
      _reportIllegalTaskLocalBindingWithinWithTaskGroup(
          _fileStart, file.count, true, line)
    }
  }
}

@available(SwiftStdlib 5.1, *)
@usableFromInline
@_silgen_name("swift_task_reportIllegalTaskLocalBindingWithinWithTaskGroup")
func _reportIllegalTaskLocalBindingWithinWithTaskGroup(
  _ _filenameStart: UnsafePointer<Int8>,
  _ _filenameLength: Int,
  _ _filenameIsASCII: Bool,
  _ _line: UInt)
