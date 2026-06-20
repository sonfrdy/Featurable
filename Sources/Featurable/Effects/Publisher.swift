import Combine

extension Effect {
  public static func publisher(_ createPublisher: () -> some Publisher<Action, Never>) -> Self {
    Self(operation: .publisher(createPublisher().eraseToAnyPublisher()))
  }
}

package struct _EffectPublisher<Action>: Publisher {
  package typealias Output = Action
  package typealias Failure = Never

  package let effect: Effect<Action>

  package init(_ effect: Effect<Action>) {
    self.effect = effect
  }

  package func receive(subscriber: some Combine.Subscriber<Action, Failure>) {
    publisher.subscribe(subscriber)
  }

  private var publisher: AnyPublisher<Action, Failure> {
    switch effect.operation {
    case .none:
      return Empty().eraseToAnyPublisher()

    case let .publisher(publisher):
      return publisher

    case let .run(name, priority, operation):
      return .create { subscriber in
        let task = Task(name: name, priority: priority) { @MainActor in
          defer { subscriber.send(completion: .finished) }
          await operation(Send(send: { subscriber.send($0) }))
        }
        return AnyCancellable { @Sendable in
          task.cancel()
        }
      }
    }
  }
}
