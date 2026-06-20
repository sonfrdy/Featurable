import Foundation
@preconcurrency import Combine

enum Origin {
  case effect
  case store
}

@MainActor
final class RootCore<State, Action> {
  var state: State {
    didSet {
      didSet.send(())
    }
  }

  let didSet = CurrentValueRelay(())

  private let reducer: @MainActor (inout State, Action) -> Effect<Action>
  private let dependencies: DependencyValues

  private var bufferedActions: [Action] = []
  private var effectCancellables: [UUID: AnyCancellable] = [:]
  private var isSending = false

  var isIdle: Bool {
    effectCancellables.isEmpty && bufferedActions.isEmpty && !isSending
  }

  init(
    initialState: State,
    reducer: @escaping @MainActor (inout State, Action) -> Effect<Action>,
    dependencies: DependencyValues
  ) {
    self.state = initialState
    self.reducer = reducer
    self.dependencies = dependencies
  }

  deinit {
    for effectCancellable in effectCancellables.values {
      effectCancellable.cancel()
    }
  }

  func send(_ action: Action, origin: Origin) -> Task<Void, Never>? {
    _send(action, origin: origin)
  }

  private func _send(_ action: Action, origin: Origin) -> Task<Void, Never>? {
    self.bufferedActions.append(action)
    guard !self.isSending else {
      if origin == .store {
        reportIssue(
          """
          Sent '\(String(reflecting: action))' while an action was being processed.

          Reentrant actions are undefined and will be a precondition failure in a future version \
          of the library.
          """
        )
      }
      return nil
    }

    self.isSending = true
    var currentState = self.state
    let tasks = LockIsolated<[Task<Void, Never>]>([])
    defer {
      withExtendedLifetime(self.bufferedActions) {
        self.bufferedActions.removeAll()
      }
      self.state = currentState
      self.isSending = false
      if !self.bufferedActions.isEmpty {
        if let task = self.send(
          self.bufferedActions.removeLast(),
          origin: .effect
        ) {
          tasks.withValue { $0.append(task) }
        }
      }
    }

    var index = self.bufferedActions.startIndex
    while index < self.bufferedActions.endIndex {
      defer { index += 1 }
      let action = self.bufferedActions[index]
      let effect = withDependencies {
        $0 = self.dependencies
      } operation: {
        reducer(&currentState, action)
      }
      let uuid = UUID()

      switch effect.operation {
      case .none:
        break

      case .publisher(let publisher):
        var didComplete = false
        let boxedTask = Box<Task<Void, Never>?>(wrappedValue: nil)
        let effectCancellable = withEscapedDependencies { continuation in
          publisher
            .receive(on: UIScheduler.shared)
            .handleEvents(receiveCancel: { [weak self] in self?.effectCancellables[uuid] = nil })
            .sink(
              receiveCompletion: { [weak self] _ in
                boxedTask.wrappedValue?.cancel()
                didComplete = true
                self?.effectCancellables[uuid] = nil
              },
              receiveValue: { [weak self] effectAction in
                guard let self else { return }
                if let task = continuation.yield({
                  self.send(effectAction, origin: .effect)
                }) {
                  tasks.withValue { $0.append(task) }
                }
              }
            )
        }

        if !didComplete {
          let task = Task<Void, Never> { @MainActor in
            for await _ in AsyncStream<Void>.never {}
            effectCancellable.cancel()
          }
          boxedTask.wrappedValue = task
          tasks.withValue { $0.append(task) }
          self.effectCancellables[uuid] = AnyCancellable { @Sendable in
            task.cancel()
          }
        }

      case .run(let name, let priority, let operation):
        withEscapedDependencies { continuation in
          let task = Task(name: name, priority: priority) { @MainActor [weak self] in
            let isCompleted = LockIsolated(false)
            defer { isCompleted.setValue(true) }
            await operation(
              Send(send: { effectAction in
                if isCompleted.value {
                  reportIssue(
                    """
                    An action was sent from a completed effect.

                      Action:
                        \(String(reflecting: effectAction))

                      Effect returned from:
                        \(String(reflecting: action))

                    Avoid sending actions using the 'send' argument from 'Effect.run' after the \
                    effect has completed. This can happen if you escape the 'send' argument in an \
                    unstructured context.

                    To fix this, make sure that your 'run' closure does not return until you're \
                    done calling 'send'.
                    """
                  )
                }
                if let task = continuation.yield({
                  self?.send(effectAction, origin: .effect)
                }) {
                  tasks.withValue { $0.append(task) }
                }
              })
            )
            self?.effectCancellables[uuid] = nil
          }
          tasks.withValue { $0.append(task) }
          self.effectCancellables[uuid] = AnyCancellable { @Sendable in
            task.cancel()
          }
        }
      }
    }

    guard !tasks.value.isEmpty else { return nil }
    return Task { @MainActor in
      await withTaskCancellationHandler {
        var index = 0
        while let task = tasks.withValue({ index < $0.endIndex ? $0[index] : nil }) {
          await task.value
          index += 1
        }
      } onCancel: {
        for task in tasks.value {
          task.cancel()
        }
      }
    }
  }
}
