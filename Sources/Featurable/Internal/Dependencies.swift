struct DependencyValues: Sendable {
  @TaskLocal static var _current = Self()

  var cancellationID = CancellationID()
}

@discardableResult
func withDependencies<R>(
  _ updateValuesForOperation: (inout DependencyValues) throws -> Void,
  operation: () throws -> R
) rethrows -> R {
  var dependencies = DependencyValues._current
  try updateValuesForOperation(&dependencies)
  return try DependencyValues.$_current.withValue(dependencies) {
    try operation()
  }
}

func withEscapedDependencies<R>(
  _ operation: (DependencyValues.Continuation) throws -> R
) rethrows -> R {
  try operation(DependencyValues.Continuation())
}

extension DependencyValues {
  struct Continuation: Sendable {
    private let dependencies = DependencyValues._current

    func yield<R>(_ operation: () throws -> R) rethrows -> R {
      try DependencyValues.$_current.withValue(dependencies) {
        try operation()
      }
    }

    func yield<R>(_ operation: () async throws -> R) async rethrows -> R {
      try await DependencyValues.$_current.withValue(dependencies) {
        try await operation()
      }
    }
  }
}
