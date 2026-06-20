import Foundation
@preconcurrency import Combine

extension Effect {

  public func cancellable(
    id: some Hashable & Sendable,
    cancelInFlight: Bool = false
  ) -> Self {
    let cancellationID = DependencyValues._current.cancellationID

    switch self.operation {
    case .none:
      return .none

    case .publisher(let publisher):
      return Self(
        operation: .publisher(
          Deferred {
            ()
              -> Publishers.HandleEvents<
                Publishers.PrefixUntilOutput<
                  AnyPublisher<Action, Never>, PassthroughSubject<Void, Never>
                >
              > in
            _cancellationCancellables.withValue {
              if cancelInFlight {
                $0.cancel(id: id, cancellationID: cancellationID)
              }

              let cancellationSubject = PassthroughSubject<Void, Never>()

              let cancellable = LockIsolated<AnyCancellable?>(nil)
              cancellable.setValue(
                AnyCancellable { @Sendable in
                  _cancellationCancellables.withValue {
                    cancellationSubject.send(())
                    cancellationSubject.send(completion: .finished)
                    $0.remove(cancellable.value!, at: id, cancellationID: cancellationID)
                  }
                }
              )

              return publisher.prefix(untilOutputFrom: cancellationSubject)
                .handleEvents(
                  receiveSubscription: { _ in
                    _cancellationCancellables.withValue {
                      $0.insert(cancellable.value!, at: id, cancellationID: cancellationID)
                    }
                  },
                  receiveCompletion: { _ in cancellable.value!.cancel() },
                  receiveCancel: cancellable.value!.cancel
                )
            }
          }
          .eraseToAnyPublisher()
        )
      )

    case .run(let name, let priority, let operation):
      return withEscapedDependencies { continuation in
        Self(
          operation: .run(name: name, priority: priority) { send in
            await continuation.yield {
              await withTaskCancellation(id: id, cancelInFlight: cancelInFlight) {
                await operation(send)
              }
            }
          }
        )
      }
    }
  }

  public static func cancel(id: some Hashable & Sendable) -> Self {
    let dependencies = DependencyValues._current
    let cancellationID = dependencies.cancellationID
    return .publisher {
      DependencyValues.$_current.withValue(dependencies) {
        _cancellationCancellables.withValue {
          $0.cancel(id: id, cancellationID: cancellationID)
        }
      }
      return Empty<Action, Never>(completeImmediately: true)
    }
  }
}

public func withTaskCancellation<T: Sendable>(
  id: some Hashable & Sendable,
  cancelInFlight: Bool = false,
  operation: @escaping @Sendable () async throws -> T
) async rethrows -> T {
  let cancellationID = DependencyValues._current.cancellationID

  let (cancellable, task): (AnyCancellable, Task<T, any Error>) =
    _cancellationCancellables
    .withValue {
      if cancelInFlight {
        $0.cancel(id: id, cancellationID: cancellationID)
      }
      let task = Task { try await operation() }
      let cancellable = AnyCancellable { @Sendable in task.cancel() }
      $0.insert(cancellable, at: id, cancellationID: cancellationID)
      return (cancellable, task)
    }

  defer {
    _cancellationCancellables.withValue {
      $0.remove(cancellable, at: id, cancellationID: cancellationID)
    }
  }

  do {
    return try await task.cancellableValue
  } catch {
    return try Result<T, any Error>.failure(error)._rethrowGet()
  }
}

let _cancellationCancellables = LockIsolated(CancellablesCollection())

@rethrows
private protocol _ErrorMechanism {
  associatedtype Output
  func get() throws -> Output
}

extension _ErrorMechanism {
  func _rethrowError() rethrows -> Never {
    _ = try _rethrowGet()
    fatalError()
  }

  func _rethrowGet() rethrows -> Output {
    return try get()
  }
}

extension Result: _ErrorMechanism {}

struct CancellationID: Hashable, Sendable {
  private let id = UUID()
}

struct _CancelID: Hashable {
  let discriminator: ObjectIdentifier
  let id: AnyHashable
  let cancellationID: CancellationID

  init(id: some Hashable & Sendable, cancellationID: CancellationID) {
    self.discriminator = ObjectIdentifier(type(of: id))
    self.id = AnyHashable(id)
    self.cancellationID = cancellationID
  }
}

final class CancellablesCollection {
  var storage: [_CancelID: Set<AnyCancellable>] = [:]

  func insert(
    _ cancellable: AnyCancellable,
    at id: some Hashable & Sendable,
    cancellationID: CancellationID
  ) {
    let cancelID = _CancelID(id: id, cancellationID: cancellationID)
    self.storage[cancelID, default: []].insert(cancellable)
  }

  func remove(
    _ cancellable: AnyCancellable,
    at id: some Hashable & Sendable,
    cancellationID: CancellationID
  ) {
    let cancelID = _CancelID(id: id, cancellationID: cancellationID)
    self.storage[cancelID]?.remove(cancellable)
    if self.storage[cancelID]?.isEmpty == true {
      self.storage[cancelID] = nil
    }
  }

  func cancel(
    id: some Hashable & Sendable,
    cancellationID: CancellationID
  ) {
    let cancelID = _CancelID(id: id, cancellationID: cancellationID)
    self.storage[cancelID]?.forEach { $0.cancel() }
    self.storage[cancelID] = nil
  }

  func exists(
    at id: some Hashable & Sendable,
    cancellationID: CancellationID
  ) -> Bool {
    self.storage[_CancelID(id: id, cancellationID: cancellationID)] != nil
  }

  var count: Int {
    self.storage.count
  }

  func removeAll() {
    self.storage.removeAll()
  }
}

extension Task where Failure == Never {
  var cancellableValue: Success {
    get async {
      await withTaskCancellationHandler {
        await self.value
      } onCancel: {
        self.cancel()
      }
    }
  }
}

extension Task where Failure == Error {
  var cancellableValue: Success {
    get async throws {
      try await withTaskCancellationHandler {
        try await self.value
      } onCancel: {
        self.cancel()
      }
    }
  }
}
