import Combine

#if canImport(Observation)
import Observation
#endif

@MainActor
@dynamicMemberLookup
public final class Store<State, Action> {

  #if canImport(Observation)
    let _$observationRegistrar: Any?
  #endif
  private let core: RootCore<State, Action>
  private var didSetCancellable: AnyCancellable?

  var currentState: State {
    core.state
  }

  var _isIdle: Bool {
    core.isIdle
  }

  private init(
    initialState: State,
    reducer: @escaping @MainActor (inout State, Action) -> Effect<Action>,
    withDependencies prepareDependencies: ((inout DependencyValues) -> Void)? = nil
  ) {
    let dependencies = withDependencies(prepareDependencies ?? { _ in }) {
      var updatedDependencies = DependencyValues._current
      updatedDependencies.cancellationID = CancellationID()
      return updatedDependencies
    }
    #if canImport(Observation)
      if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
        let _ = State.self as? any ObservableState.Type
      {
        self._$observationRegistrar = ObservationRegistrar()
      } else {
        self._$observationRegistrar = nil
      }
    #endif
    self.core = RootCore(
      initialState: initialState,
      reducer: reducer,
      dependencies: dependencies
    )
    #if canImport(Observation)
      if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *),
        let stateType = State.self as? any ObservableState.Type
      {
        func subscribeToDidSet<T: ObservableState>(_ type: T.Type) -> AnyCancellable {
          core.didSet
            .compactMap { [weak self] in (self?.withState(\.self) as? T)?._$id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
              guard
                let self,
                let observationRegistrar = self._$observationRegistrar as? ObservationRegistrar
              else { return }
              observationRegistrar.withMutation(of: self, keyPath: \.currentState) {}
            }
        }
        self.didSetCancellable = subscribeToDidSet(stateType)
      }
    #endif
  }

  public convenience init<R: Reducer>(
    initialState: R.State,
    reducer: R
  ) where State == R.State, Action == R.Action {
    self.init(
      initialState: initialState,
      reducer: { state, action in
        reducer.reduce(into: &state, action: action)
      }
    )
  }

  @discardableResult
  public func send(_ action: Action) -> StoreTask {
    StoreTask(rawValue: core.send(action, origin: .store))
  }
}

extension Store {
  public var publisher: StorePublisher<State> {
    StorePublisher(
      store: self,
      upstream: core.didSet
        .receive(on: UIScheduler.shared)
        .map { self.withState(\.self) }
    )
  }

  public func withState<R>(_ body: (_ state: State) -> R) -> R {
    body(self.currentState)
  }
}

public typealias StoreOf<R: Reducer> = Store<R.State, R.Action>

@dynamicMemberLookup
public struct StorePublisher<State>: Publisher {
  public typealias Output = State
  public typealias Failure = Never

  let store: Any
  let upstream: AnyPublisher<State, Never>

  init(store: Any, upstream: some Publisher<Output, Failure>) {
    self.store = store
    self.upstream = upstream.eraseToAnyPublisher()
  }

  public func receive(subscriber: some Subscriber<Output, Failure>) {
    upstream.subscribe(
      AnySubscriber(
        receiveSubscription: subscriber.receive(subscription:),
        receiveValue: { value in subscriber.receive(value) },
        receiveCompletion: { [store = self.store] in
          subscriber.receive(completion: $0)
          _ = store
        }
      )
    )
  }

  public subscript<Value: Equatable>(
    dynamicMember keyPath: KeyPath<State, Value>
  ) -> StorePublisher<Value> {
    StorePublisher<Value>(
      store: store,
      upstream: upstream.map(keyPath).removeDuplicates()
    )
  }
}

public struct StoreTask: Hashable, Sendable {
  let rawValue: Task<Void, Never>?

  init(rawValue: Task<Void, Never>?) {
    self.rawValue = rawValue
  }

  public func cancel() {
    rawValue?.cancel()
  }

  public func finish() async {
    await rawValue?.cancellableValue
  }

  public var isCancelled: Bool {
    rawValue?.isCancelled ?? true
  }
}

#if canImport(Observation)
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension Store: Observable {}
#endif
