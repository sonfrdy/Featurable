#if canImport(Observation)
import Observation

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@attached(extension, conformances: Observable, ObservableState)
@attached(
  member, names: named(_$id), named(_$observationRegistrar), named(_$willModify),
  named(shouldNotifyObservers))
@attached(memberAttribute)
public macro ObservableState() =
  #externalMacro(module: "FeaturableMacros", type: "ObservableStateMacro")

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_))
public macro ObservationStateTracked() =
  #externalMacro(module: "FeaturableMacros", type: "ObservationStateTrackedMacro")

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@attached(accessor, names: named(willSet))
public macro ObservationStateIgnored() =
  #externalMacro(module: "FeaturableMacros", type: "ObservationStateIgnoredMacro")
#endif
