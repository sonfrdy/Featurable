import Foundation

final class LockIsolated<Value>: @unchecked Sendable {
  private var _value: Value
  private let lock = NSRecursiveLock()

  init(_ value: Value) {
    self._value = value
  }

  func withValue<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation(&_value)
  }

  func setValue(_ value: Value) {
    withValue { $0 = value }
  }

  var value: Value {
    withValue { $0 }
  }
}
