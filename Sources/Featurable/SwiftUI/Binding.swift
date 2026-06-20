#if canImport(SwiftUI) && canImport(Observation)
import SwiftUI
import Observation

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension Store where State: ObservableState {
  public func binding<Value>(
    get: @escaping (State) -> Value,
    send action: @escaping (Value) -> Action
  ) -> Binding<Value> {
    return Binding(
      get: { get(self.state) },
      set: { self.send(action($0)) }
    )
  }

  public func binding<Value>(
    get keyPath: KeyPath<State, Value>,
    send action: @escaping (Value) -> Action
  ) -> Binding<Value> {
    binding(
      get: { $0[keyPath: keyPath] },
      send: action
    )
  }
}
#endif
