import Combine

#if swift(>=6)
@preconcurrency import Dispatch
#else
import Dispatch
#endif

struct UIScheduler: Scheduler, Sendable {
  typealias SchedulerOptions = Never
  typealias SchedulerTimeType = DispatchQueue.SchedulerTimeType

  static let shared = Self()

  var now: SchedulerTimeType { DispatchQueue.main.now }
  var minimumTolerance: SchedulerTimeType.Stride { DispatchQueue.main.minimumTolerance }

  func schedule(options: SchedulerOptions? = nil, _ action: @escaping () -> Void) {
    if DispatchQueue.getSpecific(key: key) == value {
      action()
    } else {
      DispatchQueue.main.schedule(action)
    }
  }

  func schedule(
    after date: SchedulerTimeType,
    tolerance: SchedulerTimeType.Stride,
    options: SchedulerOptions? = nil,
    _ action: @escaping () -> Void
  ) {
    DispatchQueue.main.schedule(after: date, tolerance: tolerance, options: nil, action)
  }

  func schedule(
    after date: SchedulerTimeType,
    interval: SchedulerTimeType.Stride,
    tolerance: SchedulerTimeType.Stride,
    options: SchedulerOptions? = nil,
    _ action: @escaping () -> Void
  ) -> any Cancellable {
    DispatchQueue.main.schedule(
      after: date,
      interval: interval,
      tolerance: tolerance,
      options: nil,
      action
    )
  }

  private init() {
    DispatchQueue.main.setSpecific(key: key, value: value)
  }
}

private let key = DispatchSpecificKey<UInt8>()
private let value: UInt8 = 0
