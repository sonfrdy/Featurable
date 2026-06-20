import Featurable
import Foundation
import Combine
import Dispatch
import IssueReporting
import CustomDump

@MainActor
public final class TestStore<State: Equatable, Action> {
  public var exhaustivity: Exhaustivity = .on
  public var timeout: TimeInterval
  public var useMainSerialExecutor = true

  public var state: State {
    reducer.state
  }

  private let fileID: StaticString
  private let filePath: StaticString
  private let line: UInt
  private let column: UInt
  private let reducer: TestReducer<State, Action>
  private let store: Store<State, TestReducer<State, Action>.TestAction>

  public init<R: Reducer>(
    initialState: @autoclosure () -> State,
    reducer: R,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) where R.State == State, R.Action == Action {
    let reducer = TestReducer(reducer, initialState: initialState())
    self.fileID = fileID
    self.filePath = filePath
    self.line = line
    self.column = column
    self.reducer = reducer
    self.store = Store(initialState: reducer.state, reducer: reducer)
    self.timeout = 1
  }

  public func finish(
    timeout duration: TimeInterval? = nil,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    assertNoReceivedActions(fileID: fileID, filePath: filePath, line: line, column: column)
    let duration = duration ?? self.timeout
    let deadline = Date().addingTimeInterval(duration)

    await Task.megaYield()
    while !reducer.inFlightEffects.isEmpty {
      guard Date() < deadline else {
        let timeoutMessage =
          duration != self.timeout
          ? #"try increasing the duration of this assertion's "timeout""#
          : #"configure this assertion with an explicit "timeout""#
        let suggestion = """
          There are effects in-flight. If the effect that delivers this action uses a \
          clock/scheduler (via "receive(on:)", "delay", "debounce", etc.), make sure that you wait \
          enough time for it to perform the effect. If you are using a test \
          clock/scheduler, advance it so that the effects may complete, or consider using \
          an immediate clock/scheduler to immediately perform the effect instead.

          If you are not yet using a clock/scheduler, or can not use a clock/scheduler, \
          \(timeoutMessage).
          """
        reportIssueHelper(
          """
          Expected effects to finish, but there are still effects in-flight\
          \(duration > 0 ? " after \(duration)" : "").

          \(suggestion)
          """,
          fileID: fileID,
          filePath: filePath,
          line: line,
          column: column
        )
        return
      }
      await Task.yield()
    }
  }

  deinit {
    mainActorNow { completed() }
  }

  private func completed() {
    assertNoReceivedActions(fileID: fileID, filePath: filePath, line: line, column: column)
    for effect in reducer.inFlightEffects {
      reportIssueHelper(
        """
        An effect returned for this action is still running. It must complete before the end of \
        the test.

        To fix, inspect any effects the reducer returns for this action and ensure that all of \
        them complete by the end of the test. There are a few reasons why an effect may not have \
        completed:

        If using async/await in your effect, it may need a little bit of time to properly \
        finish. To fix you can simply perform "await store.finish()" at the end of your test.

        If an effect uses a clock or scheduler (via "receive(on:)", "delay", "debounce", etc.), \
        make sure that you wait enough time for it to perform the effect. If you are using a test \
        clock/scheduler, advance it so that the effects may complete, or consider using an \
        immediate clock/scheduler to immediately perform the effect instead.

        If you are returning a long-living effect (timers, notifications, subjects, etc.), \
        then make sure those effects are torn down by marking the effect ".cancellable" and \
        returning a corresponding cancellation effect ("Effect.cancel") from another action, or, \
        if your effect is driven by a Combine subject, send it a completion.

        If you do not wish to assert on these effects, perform "await \
        store.skipInFlightEffects()", or consider using a non-exhaustive test store: \
        "store.exhaustivity = .off".
        """,
        fileID: effect.action.fileID,
        filePath: effect.action.filePath,
        line: effect.action.line,
        column: effect.action.column
      )
    }
  }

  private func assertNoReceivedActions(
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    guard !reducer.receivedActions.isEmpty else { return }
    let actions = actionDump(reducer.receivedActions.map(\.action))

    reportIssueHelper(
      """
      The store received \(reducer.receivedActions.count) unexpected \
      action\(reducer.receivedActions.count == 1 ? "" : "s").

      Unhandled actions:
      \(actions)

      To fix, explicitly assert against these actions using "store.receive", skip these actions \
      by performing "await store.skipReceivedActions()", or consider using a non-exhaustive test \
      store: "store.exhaustivity = .off".
      """,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }
}

public typealias TestStoreOf<R: Reducer> = TestStore<R.State, R.Action> where R.State: Equatable

extension TestStore {
  @discardableResult
  public func send(
    _ action: Action,
    assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> TestStoreTask {
    if !reducer.receivedActions.isEmpty {
      let actions = actionDump(reducer.receivedActions.map(\.action))
      reportIssueHelper(
        """
        Must handle \(reducer.receivedActions.count) received \
        action\(reducer.receivedActions.count == 1 ? "" : "s") before sending an action.

        Unhandled actions: \(actions)
        """,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    }

    switch exhaustivity {
    case .on:
      break
    case .off(showSkippedAssertions: true):
      _skipReceivedActions(
        strict: false,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    case .off(showSkippedAssertions: false):
      reducer.receivedActions = []
    }

    let expectedState = state
    let previousState = reducer.state
    let task = store.send(
      .init(
        origin: .send(action),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    )
    if useMainSerialExecutor {
      await Task.yield()
    } else {
      for await _ in reducer.effectDidSubscribe.stream {
        break
      }
    }
    let currentState = state
    reducer.state = previousState
    defer { reducer.state = currentState }
    assertState(
      expected: expectedState,
      actual: currentState,
      updateStateToExpectedResult: updateStateToExpectedResult,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
    await Task.megaYield(count: 20)
    return TestStoreTask(rawValue: task, timeout: timeout)
  }

  public func assert(
    _ updateStateToExpectedResult: @escaping (_ state: inout State) throws -> Void,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    assertState(
      expected: state,
      actual: reducer.state,
      updateStateToExpectedResult: updateStateToExpectedResult,
      skipUnnecessaryModifyFailure: true,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  public func withExhaustivity<R>(
    _ exhaustivity: Exhaustivity,
    operation: () throws -> R
  ) rethrows -> R {
    let previous = self.exhaustivity
    defer { self.exhaustivity = previous }
    self.exhaustivity = exhaustivity
    return try operation()
  }

  public func withExhaustivity<R>(
    _ exhaustivity: Exhaustivity,
    operation: () async throws -> R
  ) async rethrows -> R {
    let previous = self.exhaustivity
    defer { self.exhaustivity = previous }
    self.exhaustivity = exhaustivity
    return try await operation()
  }

  public func skipReceivedActions(
    strict: Bool = true,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    await Task.megaYield()
    _skipReceivedActions(
      strict: strict,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  private func _skipReceivedActions(
    strict: Bool = true,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    guard !reducer.receivedActions.isEmpty else {
      if strict {
        reportIssue(
          "There were no received actions to skip.",
          fileID: fileID,
          filePath: filePath,
          line: line,
          column: column
        )
      }
      return
    }

    reportSkippedReceivedActions(
      reducer.receivedActions.map(\.action),
      overrideExhaustivity: exhaustivity == .on ? .off(showSkippedAssertions: true) : exhaustivity,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
    reducer.state = reducer.receivedActions.last!.state
    reducer.receivedActions = []
  }

  public func skipInFlightEffects(
    strict: Bool = true,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    await Task.megaYield()
    _skipInFlightEffects(
      strict: strict,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  private func _skipInFlightEffects(
    strict: Bool = true,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    guard !reducer.inFlightEffects.isEmpty else {
      if strict {
        reportIssue(
          "There were no in-flight effects to skip.",
          fileID: fileID,
          filePath: filePath,
          line: line,
          column: column
        )
      }
      return
    }

    var actions = ""
    if reducer.inFlightEffects.count == 1 {
      customDump(reducer.inFlightEffects.first!.action.action, to: &actions)
    } else {
      customDump(reducer.inFlightEffects.map { $0.action.action }, to: &actions)
    }

    reportIssueHelper(
      """
      \(reducer.inFlightEffects.count) in-flight effect\
      \(reducer.inFlightEffects.count == 1 ? " was" : "s were") cancelled, originating from:

      \(actions)
      """,
      overrideExhaustivity: exhaustivity == .on ? .off(showSkippedAssertions: true) : exhaustivity,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
    reducer.inFlightEffects = []
  }

  private func assertState(
    expected: State,
    actual: State,
    updateStateToExpectedResult: ((inout State) throws -> Void)? = nil,
    skipUnnecessaryModifyFailure: Bool = false,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    let previousState = expected

    switch exhaustivity {
    case .on:
      var expectedState = previousState
      guard apply(updateStateToExpectedResult, to: &expectedState) else { return }

      if expectedState != actual {
        expectationFailure(expected: expectedState)
      } else {
        unnecessaryModifyFailure(expected: expectedState)
      }

    case .off:
      var expectedState = actual
      guard apply(updateStateToExpectedResult, to: &expectedState) else { return }

      if expectedState != actual {
        expectationFailure(expected: expectedState, overrideExhaustivity: .on)
      } else if exhaustivity == .off(showSkippedAssertions: true) {
        var skippedExpectedState = previousState
        guard apply(updateStateToExpectedResult, to: &skippedExpectedState) else { return }

        if skippedExpectedState != actual {
          expectationFailure(expected: skippedExpectedState)
        } else {
          unnecessaryModifyFailure(expected: skippedExpectedState)
        }
      } else {
        unnecessaryModifyFailure(expected: expectedState)
      }
    }

    func apply(
      _ updateStateToExpectedResult: ((inout State) throws -> Void)?,
      to state: inout State
    ) -> Bool {
      do {
        try updateStateToExpectedResult?(&state)
        return true
      } catch {
        reportIssue(
          "Threw error: \(error)",
          fileID: fileID,
          filePath: filePath,
          line: line,
          column: column
        )
        return false
      }
    }

    func expectationFailure(expected: State, overrideExhaustivity: Exhaustivity? = nil) {
      let messageHeading =
        updateStateToExpectedResult != nil
        ? "A state change does not match expectation"
        : "State was not expected to change, but a change occurred"
      reportIssueHelper(
        """
        \(messageHeading).

        \(stateDifference(expected: expected, actual: actual))
        """,
        overrideExhaustivity: overrideExhaustivity,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    }

    func unnecessaryModifyFailure(expected: State) {
      guard
        !skipUnnecessaryModifyFailure,
        updateStateToExpectedResult != nil,
        expected == previousState
      else { return }

      reportIssueHelper(
        """
        Expected state to change, but no change occurred.

        The trailing closure made no observable modifications to state. If no change to state is \
        expected, omit the trailing closure.
        """,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    }
  }

  private func reportIssueHelper(
    _ message: String,
    overrideExhaustivity exhaustivity: Exhaustivity? = nil,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    switch exhaustivity ?? self.exhaustivity {
    case .on:
      reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
    case .off(let showSkippedAssertions):
      if showSkippedAssertions {
        withExpectedIssue {
          reportIssue(
            """
            Skipped assertions.

            \(message)
            """,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
          )
        }
      }
    }
  }

  private func reportSkippedReceivedActions(
    _ actions: [Action],
    overrideExhaustivity exhaustivity: Exhaustivity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    guard !actions.isEmpty else { return }

    var actionsDump = ""
    if actions.count == 1 {
      customDump(actions[0], to: &actionsDump)
    } else {
      customDump(actions, to: &actionsDump)
    }

    reportIssueHelper(
      """
      \(actions.count) received action\(actions.count == 1 ? " was" : "s were") skipped.

      \(actionsDump)
      """,
      overrideExhaustivity: exhaustivity,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }
}

private func stateDifference<State>(expected: State, actual: State) -> String {
  diff(expected, actual, format: .proportional)
    .map { "\($0.indent(by: 4))\n\n(Expected: -, Actual: +)" }
    ?? """
    Expected:
    \(String(describing: expected).indent(by: 2))

    Actual:
    \(String(describing: actual).indent(by: 2))
    """
}

private func actionDump<Action>(_ action: Action, indent: Int = 0) -> String {
  var actionDump = ""
  customDump(action, to: &actionDump, indent: indent)
  return actionDump
}

private func actionDump<Action>(_ actions: [Action]) -> String {
  if actions.count == 1 {
    actionDump(actions[0])
  } else {
    actionDump(actions)
  }
}

extension TestStore where Action: Equatable {
  public func receive(
    _ expectedAction: Action,
    timeout duration: TimeInterval? = nil,
    assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    let expectedActionDump = actionDump(expectedAction, indent: 2)
    await receive(
      matching: { $0 == expectedAction },
      failureMessage: """
        Expected to receive the following action, but didn't:

        \(expectedActionDump)
        """,
      unexpectedActionDescription: { receivedAction in
        diff(expectedAction, receivedAction, format: .proportional)
          .map { "\($0.indent(by: 4))\n\n(Expected: -, Received: +)" }
          ?? """
          Expected:
          \(String(describing: expectedAction).indent(by: 2))

          Received:
          \(String(describing: receivedAction).indent(by: 2))
          """
      },
      timeout: duration,
      assert: updateStateToExpectedResult,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }
}

extension TestStore {
  public func receive(
    matching predicate: @escaping (Action) -> Bool,
    timeout duration: TimeInterval? = nil,
    assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    await receive(
      matching: predicate,
      failureMessage: "Expected to receive a matching action, but didn't.",
      unexpectedActionDescription: { actionDump($0, indent: 2) },
      timeout: duration,
      assert: updateStateToExpectedResult,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  private func receive(
    matching predicate: @escaping (Action) -> Bool,
    failureMessage: @autoclosure () -> String,
    unexpectedActionDescription: (Action) -> String,
    timeout duration: TimeInterval?,
    assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)?,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) async {
    await receiveAction(
      matching: predicate,
      timeout: duration,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )

    guard !reducer.receivedActions.isEmpty else {
      reportIssue(
        failureMessage(),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
      return
    }

    if exhaustivity != .on {
      guard reducer.receivedActions.contains(where: { predicate($0.action) }) else {
        reportIssue(
          failureMessage(),
          fileID: fileID,
          filePath: filePath,
          line: line,
          column: column
        )
        return
      }

      var skippedActions: [Action] = []
      while let receivedAction = reducer.receivedActions.first,
        !predicate(receivedAction.action)
      {
        reducer.receivedActions.removeFirst()
        skippedActions.append(receivedAction.action)
        reducer.state = receivedAction.state
      }

      reportSkippedReceivedActions(
        skippedActions,
        overrideExhaustivity: exhaustivity,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    }

    let (receivedAction, state) = reducer.receivedActions.removeFirst()
    if !predicate(receivedAction) {
      let receivedActionLater = reducer.receivedActions.contains { action, _ in
        predicate(action)
      }
      reportIssueHelper(
        """
        Received unexpected action\(receivedActionLater ? " before this one" : ""):

        \(unexpectedActionDescription(receivedAction))
        """,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    } else {
      assertState(
        expected: self.state,
        actual: state,
        updateStateToExpectedResult: updateStateToExpectedResult,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    }
    reducer.state = state
  }

  private func receiveAction(
    matching predicate: (Action) -> Bool,
    timeout duration: TimeInterval?,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) async {
    let duration = duration ?? timeout
    let deadline = Date().addingTimeInterval(duration)

    await Task.megaYield()
    while !Task.isCancelled {
      await Task.detached(priority: .background) { await Task.yield() }.value

      switch exhaustivity {
      case .on:
        guard reducer.receivedActions.isEmpty else { return }
      case .off:
        guard !reducer.receivedActions.contains(where: { predicate($0.action) }) else { return }
      }

      guard Date() < deadline else {
        let suggestion: String
        if reducer.inFlightEffects.isEmpty {
          suggestion = """
            There are no in-flight effects that could deliver this action. Could the effect you \
            expected to deliver this action have been cancelled?
            """
        } else {
          let timeoutMessage =
            duration != self.timeout
            ? #"try increasing the duration of this assertion's "timeout""#
            : #"configure this assertion with an explicit "timeout""#
          suggestion = """
            There are effects in-flight. If the effect that delivers this action uses a \
            clock/scheduler (via "receive(on:)", "delay", "debounce", etc.), make sure that you \
            wait enough time for it to perform the effect. If you are using a test \
            clock/scheduler, advance it so that the effects may complete, or consider using \
            an immediate clock/scheduler to immediately perform the effect instead.

            If you are not yet using a clock/scheduler, or can not use a clock/scheduler, \
            \(timeoutMessage).
            """
        }
        reportIssue(
          """
          Expected to receive \(exhaustivity == .on ? "an action" : "a matching action"), but \
          received none\
          \(duration > 0 ? " after \(duration)" : "").

          \(suggestion)
          """,
          fileID: fileID,
          filePath: filePath,
          line: line,
          column: column
        )
        return
      }
      await Task.yield()
    }
  }
}

public struct TestStoreTask: Hashable, Sendable {
  private let rawValue: StoreTask
  private let timeout: TimeInterval

  init(rawValue: StoreTask, timeout: TimeInterval) {
    self.rawValue = rawValue
    self.timeout = timeout
  }

  public func cancel() async {
    rawValue.cancel()
    await rawValue.finish()
  }

  public func finish(
    timeout duration: TimeInterval? = nil,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    let duration = duration ?? self.timeout
    await Task.megaYield()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await rawValue.finish() }
        group.addTask {
          try await Task.sleep(nanoseconds: duration.nanoseconds)
          throw CancellationError()
        }
        try await group.next()
        group.cancelAll()
      }
    } catch {
      let timeoutMessage =
        duration != self.timeout
        ? #"try increasing the duration of this assertion's "timeout""#
        : #"configure this assertion with an explicit "timeout""#
      let suggestion = """
        If this task delivers its action using a clock/scheduler (via "sleep(for:)", \
        "timer(interval:)", etc.), make sure that you wait enough time for it to \
        perform its work. If you are using a test clock/scheduler, advance the scheduler so that \
        the effects may complete, or consider using an immediate clock/scheduler to immediately \
        perform the effect instead.

        If you are not yet using a clock/scheduler, or cannot use a clock/scheduler, \
        \(timeoutMessage).
        """

      reportIssue(
        """
        Expected task to finish, but it is still in-flight\
        \(duration > 0 ? " after \(duration)" : "").

        \(suggestion)
        """,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      )
    }
  }

  public var isCancelled: Bool {
    rawValue.isCancelled
  }
}

@MainActor
final class TestReducer<State: Equatable, Action>: Reducer {
  private let reduce: @MainActor (inout State, Action) -> Effect<Action>
  let effectDidSubscribe = AsyncStream.makeStream(of: Void.self)
  var inFlightEffects: Set<LongLivingEffect> = []
  var receivedActions: [(action: Action, state: State)] = []
  var state: State

  init<R: Reducer>(
    _ reducer: R,
    initialState: State
  ) where R.State == State, R.Action == Action {
    self.reduce = { state, action in
      reducer.reduce(into: &state, action: action)
    }
    self.state = initialState
  }

  func reduce(into state: inout State, action: TestAction) -> Effect<TestAction> {
    let effects: Effect<Action>
    switch action.origin {
    case .send(let action):
      effects = reduce(&state, action)
      self.state = state

    case .receive(let action):
      effects = reduce(&state, action)
      receivedActions.append((action, state))
    }

    switch effects.operation {
    case .none:
      effectDidSubscribe.continuation.yield()
      return .none

    case .publisher, .run:
      let effect = LongLivingEffect(action: action)
      return .publisher { [effectDidSubscribe, weak self] in
        _EffectPublisher(effects)
          .handleEvents(
            receiveSubscription: { _ in
              self?.inFlightEffects.insert(effect)
              Task { @MainActor in
                await Task.megaYield()
                effectDidSubscribe.continuation.yield()
              }
            },
            receiveCompletion: { [weak self] _ in
              self?.inFlightEffects.remove(effect)
            },
            receiveCancel: { [weak self] in
              self?.inFlightEffects.remove(effect)
            }
          )
          .map {
            TestAction(
              origin: .receive($0),
              fileID: action.fileID,
              filePath: action.filePath,
              line: action.line,
              column: action.column
            )
          }
      }
    }
  }

  struct LongLivingEffect: Hashable {
    let id = UUID()
    let action: TestAction

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
      id.hash(into: &hasher)
    }
  }

  struct TestAction {
    let origin: Origin
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    fileprivate var action: Action {
      origin.action
    }

    enum Origin {
      case receive(Action)
      case send(Action)

      fileprivate var action: Action {
        switch self {
        case .receive(let action), .send(let action):
          return action
        }
      }
    }
  }
}

public enum Exhaustivity: Equatable, Sendable {
  case on
  case off(showSkippedAssertions: Bool)

  public static let off = Self.off(showSkippedAssertions: false)
}

extension Task where Success == Never, Failure == Never {
  static func megaYield(count: Int = 20) async {
    for _ in 0..<count {
      await Task<Void, Never>.detached(priority: .background) {
        await Task.yield()
      }
      .value
    }
  }
}

extension TimeInterval {
  var nanoseconds: UInt64 {
    UInt64((self * 1_000_000_000).rounded())
  }
}

extension String {
  func indent(by count: Int) -> String {
    let indentation = String(repeating: " ", count: count)
    return indentation + replacingOccurrences(of: "\n", with: "\n\(indentation)")
  }
}

private func mainActorNow<R: Sendable>(execute block: @MainActor @Sendable () -> R) -> R {
  if DispatchQueue.getSpecific(key: mainActorNowKey) == mainActorNowValue {
    return MainActor.assumeIsolated {
      block()
    }
  } else {
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        block()
      }
    }
  }
}

private let mainActorNowKey: DispatchSpecificKey<UInt8> = {
  let key = DispatchSpecificKey<UInt8>()
  DispatchQueue.main.setSpecific(key: key, value: mainActorNowValue)
  return key
}()

private let mainActorNowValue: UInt8 = 0
