import Combine

extension Effect where Action: Sendable {
  public func throttle<S: Scheduler & Sendable>(
    id: some Hashable & Sendable,
    for interval: S.SchedulerTimeType.Stride,
    scheduler: S,
    latest: Bool
  ) -> Self
  where S.SchedulerTimeType.Stride: Sendable {
    switch self.operation {
    case .none:
      return .none

    case .run:
      return .publisher { _EffectPublisher(self) }
        .throttle(id: id, for: interval, scheduler: scheduler, latest: latest)

    case .publisher(let publisher):
      return .publisher {
        publisher
          .receive(on: scheduler)
          .flatMap { value -> AnyPublisher<Action, Never> in
            throttleState.withValue {
              guard let throttleTime = $0.times[id] as! S.SchedulerTimeType? else {
                $0.times[id] = scheduler.now
                $0.values[id] = nil
                return Just(value).eraseToAnyPublisher()
              }

              let value = latest ? value : ($0.values[id] as! Action? ?? value)
              $0.values[id] = value

              guard throttleTime.distance(to: scheduler.now) < interval else {
                $0.times[id] = scheduler.now
                $0.values[id] = nil
                return Just(value).eraseToAnyPublisher()
              }

              return Just(value)
                .delay(
                  for: scheduler.now.distance(to: throttleTime.advanced(by: interval)),
                  scheduler: scheduler
                )
                .handleEvents(
                  receiveOutput: { _ in
                    throttleState.withValue {
                      $0.times[id] = scheduler.now
                      $0.values[id] = nil
                    }
                  }
                )
                .eraseToAnyPublisher()
            }
          }
      }
      .cancellable(id: id, cancelInFlight: true)
    }
  }
}

private let throttleState = LockIsolated<(times: [AnyHashable: Any], values: [AnyHashable: Any])>(
  (times: [:], values: [:])
)
