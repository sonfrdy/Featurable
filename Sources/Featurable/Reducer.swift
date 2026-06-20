public protocol Reducer {
  associatedtype State
  associatedtype Action

  @MainActor
  func reduce(into state: inout State, action: Action) -> Effect<Action>
}
