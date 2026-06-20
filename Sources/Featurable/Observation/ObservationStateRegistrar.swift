import Foundation

#if canImport(Observation)
import Observation

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct ObservationStateRegistrar: Sendable {
  public private(set) var id = ObservableStateID()
  @usableFromInline
  let registrar = ObservationRegistrar()

  public init() {}
  public mutating func _$willModify() { self.id._$willModify() }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension ObservationStateRegistrar: Equatable, Hashable, Codable {
  public static func == (_: Self, _: Self) -> Bool { true }
  public func hash(into hasher: inout Hasher) {}
  public init(from decoder: any Decoder) throws { self.init() }
  public func encode(to encoder: any Encoder) throws {}
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension ObservationStateRegistrar {
  @inlinable
  public func access<Subject: Observable, Member>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>
  ) {
    self.registrar.access(subject, keyPath: keyPath)
  }

  @inlinable
  public func mutate<Subject: Observable, Member, Value>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ value: inout Value,
    _ newValue: Value,
    _ isIdentityEqual: (Value, Value) -> Bool,
    _ shouldNotifyObservers: (Value, Value) -> Bool = { _, _ in true }
  ) {
    if isIdentityEqual(value, newValue) || !shouldNotifyObservers(value, newValue) {
      value = newValue
    } else {
      self.registrar.withMutation(of: subject, keyPath: keyPath) {
        value = newValue
      }
    }
  }

  @inlinable
  public func willModify<Subject: Observable, Member>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ member: inout Member
  ) -> Member {
    member
  }

  @inlinable
  public func willModify<Subject: Observable, Member: ObservableState>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ member: inout Member
  ) -> Member {
    member._$willModify()
    return member
  }

  @inlinable
  public func didModify<Subject: Observable, Member>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ member: inout Member,
    _ oldValue: Member,
    _ isIdentityEqual: (Member, Member) -> Bool,
    _ shouldNotifyObservers: (Member, Member) -> Bool = { _, _ in true }
  ) {
    if !isIdentityEqual(oldValue, member) {
      let newValue = member
      member = oldValue
      self.mutate(
        subject,
        keyPath: keyPath,
        &member,
        newValue,
        isIdentityEqual,
        shouldNotifyObservers
      )
    }
  }
}
#endif
