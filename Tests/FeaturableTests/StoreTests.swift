import Combine
import Featurable
import XCTest

#if canImport(Observation)
import Observation
#endif

private struct CounterReducer: Reducer {
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case increment
    case incrementLater
    case incrementTwice
    case setCount(Int)
    case secondIncrement
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .increment:
      state.count += 1
      return .none

    case .incrementLater:
      return .run { send in
        await send(.increment)
      }

    case .incrementTwice:
      return .run { send in
        await send(.increment)
        await send(.secondIncrement)
      }

    case .setCount(let count):
      state.count = count
      return .none

    case .secondIncrement:
      state.count += 1
      return .run { send in
        await send(.increment)
      }
    }
  }
}

#if canImport(Observation)
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
private struct ObservableCounterReducer: Reducer {
  @ObservableState
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case increment
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .increment:
      state.count += 1
      return .none
    }
  }
}
#endif

final class StoreTests: XCTestCase {
  private var cancellables: Set<AnyCancellable> = []

  #if canImport(Observation)
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @MainActor
  func testDynamicMemberReadsObservableState() {
    let store = Store(
      initialState: ObservableCounterReducer.State(),
      reducer: ObservableCounterReducer()
    )

    XCTAssertEqual(store.count, 0)
    store.send(.increment)
    XCTAssertEqual(store.count, 1)
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @MainActor
  func testDynamicMemberInvalidatesObservationTracking() {
    let store = Store(
      initialState: ObservableCounterReducer.State(),
      reducer: ObservableCounterReducer()
    )
    let expectation = expectation(description: "observation tracking invalidates")

    withObservationTracking {
      _ = store.count
    } onChange: {
      expectation.fulfill()
    }

    store.send(.increment)
    wait(for: [expectation], timeout: 1)
  }
  #endif

  @MainActor
  func testPublisherEmitsInitialAndChangedState() {
    let store = Store(initialState: CounterReducer.State(), reducer: CounterReducer())
    let expectation = expectation(description: "publisher emits initial and changed state")
    expectation.expectedFulfillmentCount = 2

    var values: [Int] = []
    store.publisher[dynamicMember: \.count]
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &cancellables)

    store.send(.increment)
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(values, [0, 1])
  }

  @MainActor
  func testPublisherDynamicMemberRemovesDuplicates() {
    let store = Store(initialState: CounterReducer.State(), reducer: CounterReducer())

    var values: [Int] = []
    store.publisher[dynamicMember: \.count]
      .sink { values.append($0) }
      .store(in: &cancellables)

    store.send(.setCount(0))
    store.send(.setCount(1))
    store.send(.setCount(1))
    store.send(.setCount(2))

    XCTAssertEqual(values, [0, 1, 2])
  }

  @MainActor
  func testStoreTaskFinishesNestedEffectActions() async {
    let store = Store(initialState: CounterReducer.State(), reducer: CounterReducer())

    await store.send(.incrementTwice).finish()

    XCTAssertEqual(store.withState(\.count), 3)
  }

  @MainActor
  func testNoEffectStoreTaskIsImmediatelyCancelled() async {
    let store = Store(initialState: CounterReducer.State(), reducer: CounterReducer())

    let task = store.send(.increment)
    await task.finish()

    XCTAssertTrue(task.isCancelled)
    XCTAssertEqual(store.withState(\.count), 1)
  }
}
