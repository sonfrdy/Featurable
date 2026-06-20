import Featurable
import FeaturableTesting
import XCTest

private struct CounterTestReducer: Reducer {
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case increment
    case incrementLater
    case never
    case response
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .increment:
      state.count += 1
      return .none

    case .incrementLater:
      state.count += 1
      return .run { send in
        await send(.response)
      }

    case .never:
      return .run { _ in
        try? await Task.sleep(nanoseconds: .max)
      }

    case .response:
      state.count += 1
      return .none
    }
  }
}

final class TestStoreTests: XCTestCase {
  @MainActor
  func testSend() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )

    await store.send(.increment) {
      $0.count = 1
    }

    XCTAssertEqual(store.state.count, 1)
  }

  @MainActor
  func testReceiveEffectAction() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )

    await store.send(.incrementLater) {
      $0.count = 1
    }
    await store.receive(.response) {
      $0.count = 2
    }

    XCTAssertEqual(store.state.count, 2)
  }

  @MainActor
  func testSendWithoutMainSerialExecutorWaitsForSubscriptionSignal() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )
    store.useMainSerialExecutor = false

    await store.send(.increment) {
      $0.count = 1
    }

    XCTAssertEqual(store.state.count, 1)
  }

  @MainActor
  func testTestStoreTaskCancelFinishesLongLivingEffect() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )

    let task = await store.send(.never)
    await task.cancel()

    XCTAssertTrue(task.isCancelled)
  }

  @MainActor
  func testSkipInFlightEffects() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )
    store.exhaustivity = .off

    await store.send(.never)
    await store.skipInFlightEffects(strict: false)
  }

  @MainActor
  func testNonExhaustiveSendDoesNotRequireStateAssertion() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )
    store.exhaustivity = .off

    await store.send(.increment)

    XCTAssertEqual(store.state.count, 1)
  }

  @MainActor
  func testNonExhaustiveSendShowsSkippedAssertionWithoutFailing() async {
    let store = TestStore(
      initialState: CounterTestReducer.State(),
      reducer: CounterTestReducer()
    )
    store.exhaustivity = .off(showSkippedAssertions: true)

    await store.send(.increment)

    XCTAssertEqual(store.state.count, 1)
  }
}
