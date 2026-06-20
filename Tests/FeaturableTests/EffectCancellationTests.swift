@testable import Featurable
import XCTest

private actor CancellationCounter {
  private var subscriptions = 0
  private(set) var count = 0

  func subscribe() {
    subscriptions += 1
  }

  func increment() {
    count += 1
  }

  func value() -> Int {
    count
  }

  func waitForCount(_ expectedCount: Int) async {
    while count < expectedCount {
      await Task.yield()
    }
  }

  func waitForSubscriptions(_ expectedCount: Int) async {
    while subscriptions < expectedCount {
      await Task.yield()
    }
  }
}

private struct CancellationReducer: Reducer {
  struct State: Equatable {
    var starts = 0
  }

  enum Action {
    case start
    case startCancelInFlight
    case cancel
  }

  enum CancelID: Hashable, Sendable {
    case effect
  }

  let cancellations: CancellationCounter

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .start:
      state.starts += 1
      return longLivingEffect.cancellable(id: CancelID.effect)

    case .startCancelInFlight:
      state.starts += 1
      return longLivingEffect.cancellable(id: CancelID.effect, cancelInFlight: true)

    case .cancel:
      return .cancel(id: CancelID.effect)
    }
  }

  private var longLivingEffect: Effect<Action> {
    .run { _ in
      await cancellations.subscribe()
      await withTaskCancellationHandler {
        try? await Task.sleep(nanoseconds: .max)
      } onCancel: {
        Task {
          await cancellations.increment()
        }
      }
    }
  }
}

final class EffectCancellationTests: XCTestCase {
  @MainActor
  func testCancelEffectByID() async {
    let cancellations = CancellationCounter()
    let store = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: cancellations)
    )

    store.send(.start)
    await cancellations.waitForSubscriptions(1)
    await store.send(.cancel).finish()
    await cancellations.waitForCount(1)

    let cancellationCount = await cancellations.value()
    XCTAssertEqual(cancellationCount, 1)
  }

  @MainActor
  func testCancelInFlightCancelsPreviousEffect() async {
    let cancellations = CancellationCounter()
    let store = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: cancellations)
    )

    store.send(.startCancelInFlight)
    await cancellations.waitForSubscriptions(1)
    store.send(.startCancelInFlight)
    await cancellations.waitForCount(1)
    await cancellations.waitForSubscriptions(2)
    await store.send(.cancel).finish()
    await cancellations.waitForCount(2)

    let cancellationCount = await cancellations.value()
    XCTAssertEqual(cancellationCount, 2)
  }

  @MainActor
  func testStoreTaskCancelCancelsEffect() async {
    let cancellations = CancellationCounter()
    let store = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: cancellations)
    )

    let task = store.send(.start)
    await cancellations.waitForSubscriptions(1)
    task.cancel()
    await task.finish()
    await cancellations.waitForCount(1)

    XCTAssertTrue(task.isCancelled)
    let cancellationCount = await cancellations.value()
    XCTAssertEqual(cancellationCount, 1)
  }

  @MainActor
  func testCancelByIDIsIsolatedPerStorePath() async {
    let firstCancellations = CancellationCounter()
    let secondCancellations = CancellationCounter()
    let firstStore = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: firstCancellations)
    )
    let secondStore = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: secondCancellations)
    )

    firstStore.send(.start)
    secondStore.send(.start)
    await firstCancellations.waitForSubscriptions(1)
    await secondCancellations.waitForSubscriptions(1)

    await firstStore.send(.cancel).finish()
    await firstCancellations.waitForCount(1)
    for _ in 0..<10 {
      await Task.yield()
    }

    var firstCancellationCount = await firstCancellations.value()
    var secondCancellationCount = await secondCancellations.value()
    XCTAssertEqual(firstCancellationCount, 1)
    XCTAssertEqual(secondCancellationCount, 0)

    await secondStore.send(.cancel).finish()
    await secondCancellations.waitForCount(1)

    firstCancellationCount = await firstCancellations.value()
    secondCancellationCount = await secondCancellations.value()
    XCTAssertEqual(firstCancellationCount, 1)
    XCTAssertEqual(secondCancellationCount, 1)
  }

  @MainActor
  func testCancelInFlightIsIsolatedPerStorePath() async {
    let firstCancellations = CancellationCounter()
    let secondCancellations = CancellationCounter()
    let firstStore = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: firstCancellations)
    )
    let secondStore = Store(
      initialState: CancellationReducer.State(),
      reducer: CancellationReducer(cancellations: secondCancellations)
    )

    firstStore.send(.start)
    secondStore.send(.start)
    await firstCancellations.waitForSubscriptions(1)
    await secondCancellations.waitForSubscriptions(1)

    firstStore.send(.startCancelInFlight)
    await firstCancellations.waitForCount(1)
    await firstCancellations.waitForSubscriptions(2)
    for _ in 0..<10 {
      await Task.yield()
    }

    var firstCancellationCount = await firstCancellations.value()
    var secondCancellationCount = await secondCancellations.value()
    XCTAssertEqual(firstCancellationCount, 1)
    XCTAssertEqual(secondCancellationCount, 0)

    await firstStore.send(.cancel).finish()
    await firstCancellations.waitForCount(2)
    await secondStore.send(.cancel).finish()
    await secondCancellations.waitForCount(1)

    firstCancellationCount = await firstCancellations.value()
    secondCancellationCount = await secondCancellations.value()
    XCTAssertEqual(firstCancellationCount, 2)
    XCTAssertEqual(secondCancellationCount, 1)
  }
}
