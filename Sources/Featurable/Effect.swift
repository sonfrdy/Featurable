import Foundation
import SwiftUI
@preconcurrency import Combine

public struct Effect<Action>: Sendable {

  package enum Operation: Sendable {
    case none
    case publisher(AnyPublisher<Action, Never>)
    case run(
      name: String? = nil,
      priority: TaskPriority? = nil,
      operation: @Sendable (_ send: Send<Action>) async -> Void
    )
  }

  package let operation: Operation

  public static var none: Self {
    Effect(operation: .none)
  }

  public static func run(
    priority: TaskPriority? = nil,
    name: String? = nil,
    operation: @escaping @Sendable (_ send: Send<Action>) async throws -> Void,
    catch handler: (@Sendable (_ error: any Error, _ send: Send<Action>) async -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) -> Self {
    withEscapedDependencies { escaped in
      Effect(
        operation: .run(name: name, priority: priority) { send in
          await escaped.yield {
            do {
              try await operation(send)
            } catch is CancellationError {
              return
            } catch {
              guard !Task.isCancelled else { return }
              guard let handler else {
                reportIssue(
                  """
                  An "Effect.run" returned from "\(fileID):\(line)" threw an unhandled error.

                  All non-cancellation errors must be explicitly handled via the "catch" parameter \
                  on "Effect.run", or via a "do" block.
                  """,
                  fileID: fileID,
                  filePath: filePath,
                  line: line,
                  column: column
                )
                return
              }
              await handler(error, send)
            }
          }
        }
      )
    }
  }

  public static func send(_ action: Action) -> Self {
    Effect(operation: .publisher(Just(action).eraseToAnyPublisher()))
  }

  package init(operation: Operation) {
    self.operation = operation
  }
}

public typealias EffectOf<R: Reducer> = Effect<R.Action>

@MainActor
public struct Send<Action>: Sendable {
  let send: @MainActor @Sendable (Action) -> Void

  public init(send: @escaping @MainActor @Sendable (Action) -> Void) {
    self.send = send
  }

  public func callAsFunction(_ action: Action) {
    guard !Task.isCancelled else { return }
    self.send(action)
  }

  public func callAsFunction(_ action: Action, animation: Animation?) {
    callAsFunction(action, transaction: Transaction(animation: animation))
  }

  public func callAsFunction(_ action: Action, transaction: Transaction) {
    guard !Task.isCancelled else { return }
    withTransaction(transaction) {
      self(action)
    }
  }
}

public typealias SendOf<R: Reducer> = Send<R.Action>

extension Effect {

  public static func merge(_ effects: Self...) -> Self {
    merge(effects)
  }

  public static func merge(_ effects: some Sequence<Self>) -> Self {
    effects.reduce(.none) { $0.merge(with: $1) }
  }

  public func merge(with other: Self) -> Self {
    switch (operation, other.operation) {
    case (_, .none):
      return self
    case (.none, _):
      return other
    case (.publisher, .publisher), (.run, .publisher), (.publisher, .run):
      return Effect(
        operation: .publisher(
          Publishers.Merge(
            _EffectPublisher(self),
            _EffectPublisher(other)
          )
          .eraseToAnyPublisher()
        )
      )
    case (
      .run(let lhsName, let lhsPriority, let lhsOperation),
      .run(let rhsName, let rhsPriority, let rhsOperation)
    ):
      return Effect(
        operation: .run { send in
          await withTaskGroup(of: Void.self) { group in
            group.addTask(name: lhsName, priority: lhsPriority) {
              await lhsOperation(send)
            }
            group.addTask(name: rhsName, priority: rhsPriority) {
              await rhsOperation(send)
            }
          }
        }
      )
    }
  }

}
