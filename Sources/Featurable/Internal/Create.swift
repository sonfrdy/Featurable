import Foundation
@preconcurrency import Combine

final class DemandBuffer<S: Subscriber>: @unchecked Sendable {
  private var buffer = [S.Input]()
  private let subscriber: S
  private var completion: Subscribers.Completion<S.Failure>?
  private var demandState = Demand()
  private let lock = NSRecursiveLock()

  init(subscriber: S) {
    self.subscriber = subscriber
  }

  func buffer(value: S.Input) -> Subscribers.Demand {
    lock.lock()
    defer { lock.unlock() }

    precondition(completion == nil, "Completed publisher sent values.")

    switch demandState.requested {
    case .unlimited:
      return subscriber.receive(value)
    default:
      buffer.append(value)
      return flush()
    }
  }

  func complete(completion: Subscribers.Completion<S.Failure>) {
    lock.lock()
    defer { lock.unlock() }

    precondition(self.completion == nil, "Completion has already occurred.")

    self.completion = completion
    _ = flush()
  }

  func demand(_ demand: Subscribers.Demand) -> Subscribers.Demand {
    flush(adding: demand)
  }

  private func flush(adding newDemand: Subscribers.Demand? = nil) -> Subscribers.Demand {
    lock.lock()
    defer { lock.unlock() }

    if let newDemand {
      demandState.requested += newDemand
    }

    guard demandState.requested > 0 || newDemand == Subscribers.Demand.none else { return .none }

    while !buffer.isEmpty && demandState.processed < demandState.requested {
      demandState.requested += subscriber.receive(buffer.remove(at: 0))
      demandState.processed += 1
    }

    if let completion {
      buffer = []
      demandState = .init()
      self.completion = nil
      subscriber.receive(completion: completion)
      return .none
    }

    let sentDemand = demandState.requested - demandState.sent
    demandState.sent += sentDemand
    return sentDemand
  }

  struct Demand {
    var processed: Subscribers.Demand = .none
    var requested: Subscribers.Demand = .none
    var sent: Subscribers.Demand = .none
  }
}

extension AnyPublisher where Failure == Never {
  private init(
    _ callback: @escaping @Sendable (Effect<Output>.Subscriber) -> any Cancellable
  ) {
    self = Publishers.Create(callback: callback).eraseToAnyPublisher()
  }

  static func create(
    _ factory: @escaping @Sendable (Effect<Output>.Subscriber) -> any Cancellable
  ) -> AnyPublisher<Output, Failure> {
    AnyPublisher(factory)
  }
}

extension Publishers {
  fileprivate final class Create<Output>: Publisher, Sendable {
    typealias Failure = Never

    private let callback: @Sendable (Effect<Output>.Subscriber) -> any Cancellable

    init(callback: @escaping @Sendable (Effect<Output>.Subscriber) -> any Cancellable) {
      self.callback = callback
    }

    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
      subscriber.receive(subscription: Subscription(callback: callback, downstream: subscriber))
    }
  }
}

extension Publishers.Create {
  fileprivate final class Subscription<Downstream: Subscriber>: Combine.Subscription, Sendable
  where Downstream.Input == Output, Downstream.Failure == Never {
    private let buffer: DemandBuffer<Downstream>
    private let cancellable = LockIsolated<(any Cancellable)?>(nil)

    init(
      callback: @escaping @Sendable (Effect<Output>.Subscriber) -> any Cancellable,
      downstream: Downstream
    ) {
      self.buffer = DemandBuffer(subscriber: downstream)

      cancellable.setValue(
        callback(
          .init(
            send: { [weak self] in _ = self?.buffer.buffer(value: $0) },
            complete: { [weak self] in self?.buffer.complete(completion: $0) }
          )
        )
      )
    }

    func request(_ demand: Subscribers.Demand) {
      _ = buffer.demand(demand)
    }

    func cancel() {
      cancellable.value?.cancel()
    }
  }
}

extension Publishers.Create.Subscription: CustomStringConvertible {
  var description: String {
    "Create.Subscription<\(Output.self)>"
  }
}

extension Effect {
  struct Subscriber: Sendable {
    private let _send: @Sendable (Action) -> Void
    private let _complete: @Sendable (Subscribers.Completion<Never>) -> Void

    init(
      send: @escaping @Sendable (Action) -> Void,
      complete: @escaping @Sendable (Subscribers.Completion<Never>) -> Void
    ) {
      self._send = send
      self._complete = complete
    }

    func send(_ value: Action) {
      _send(value)
    }

    func send(completion: Subscribers.Completion<Never>) {
      _complete(completion)
    }
  }
}
