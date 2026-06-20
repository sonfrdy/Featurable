@testable import Featurable
import Combine
import XCTest

@MainActor
private final class PublisherClient {
  let subject = PassthroughSubject<PublisherReducer.Action, Never>()
  var didCancel = false
}

private struct PublisherReducer: Reducer {
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case start
    case response
  }

  let client: PublisherClient

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .start:
      return .publisher {
        client.subject
          .handleEvents(receiveCancel: { client.didCancel = true })
      }

    case .response:
      state.count += 1
      return .none
    }
  }
}

final class PublisherEffectTests: XCTestCase {
  @MainActor
  func testPublisherEffectSendsActionsAndCompletes() {
    let client = PublisherClient()
    let store = Store(
      initialState: PublisherReducer.State(),
      reducer: PublisherReducer(client: client)
    )

    XCTAssertTrue(store._isIdle)

    store.send(.start)
    XCTAssertFalse(store._isIdle)

    client.subject.send(.response)
    XCTAssertEqual(store.withState(\.count), 1)

    client.subject.send(completion: .finished)
    XCTAssertTrue(store._isIdle)
  }

  @MainActor
  func testPublisherEffectCancelsWithStoreTask() async {
    let client = PublisherClient()
    let store = Store(
      initialState: PublisherReducer.State(),
      reducer: PublisherReducer(client: client)
    )

    let task = store.send(.start)
    task.cancel()
    await task.finish()

    XCTAssertTrue(client.didCancel)
    XCTAssertTrue(store._isIdle)
  }
}
