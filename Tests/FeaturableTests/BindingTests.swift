import Featurable
import SwiftUI
import XCTest

#if canImport(Observation)
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
private struct BindingReducer: Reducer {
  @ObservableState
  struct State: Equatable {
    var name = ""
    var count = 0
  }

  enum Action: Equatable {
    case setName(String)
    case setCount(Int)
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .setName(let name):
      state.name = name
      return .none

    case .setCount(let count):
      state.count = count
      return .none
    }
  }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class BindingTests: XCTestCase {
  @MainActor
  func testBindingWithKeyPath() {
    let store = Store(initialState: BindingReducer.State(), reducer: BindingReducer())
    let binding = store.binding(get: \.name, send: BindingReducer.Action.setName)

    XCTAssertEqual(binding.wrappedValue, "")

    binding.wrappedValue = "Blob"

    XCTAssertEqual(store.name, "Blob")
    XCTAssertEqual(binding.wrappedValue, "Blob")
  }

  @MainActor
  func testBindingWithGetter() {
    let store = Store(initialState: BindingReducer.State(), reducer: BindingReducer())
    let binding = store.binding(get: { $0.count }, send: BindingReducer.Action.setCount)

    XCTAssertEqual(binding.wrappedValue, 0)

    binding.wrappedValue = 42

    XCTAssertEqual(store.count, 42)
    XCTAssertEqual(binding.wrappedValue, 42)
  }
}
#endif
