#if canImport(Observation)
import Observation

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension Store where State: ObservableState {
  var observableState: State {
    (self._$observationRegistrar as? ObservationRegistrar)?
      .access(self, keyPath: \.currentState)
    return self.currentState
  }

  public var state: State {
    self.observableState
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value>) -> Value {
    self.state[keyPath: keyPath]
  }
}
#endif

extension Store: Equatable {
  public static nonisolated func == (lhs: Store, rhs: Store) -> Bool {
    lhs === rhs
  }
}

extension Store: Hashable {
  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

extension Store: Identifiable {}
