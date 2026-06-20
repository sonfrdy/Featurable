import Featurable
import Foundation
import XCTest

#if canImport(Observation)
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@ObservableState
private struct ObservableSmokeState: Equatable {
  var count = 0
  @ObservationStateIgnored var cache = 0
  var name = ""
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@ObservableState
private struct ObservableChildState: Equatable {
  var count = 0
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@ObservableState
private enum ObservableDestinationState: Equatable {
  case none
  case child(ObservableChildState)
  case other(ObservableChildState)
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@ObservableState
private struct ObservableRowState: Equatable {
  var id = UUID()
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class ObservableStateTests: XCTestCase {
  func testStructStateCompilesAndMutates() {
    var state = ObservableSmokeState()
    state.count += 1
    state.cache += 1
    state.name = "Blob"

    XCTAssertEqual(state.count, 1)
    XCTAssertEqual(state.cache, 1)
    XCTAssertEqual(state.name, "Blob")
  }

  func testEnumStateIdentityUsesCaseTags() {
    let none = ObservableDestinationState.none
    let child = ObservableDestinationState.child(ObservableChildState())
    let other = ObservableDestinationState.other(ObservableChildState())

    XCTAssertNotEqual(none._$id, child._$id)
    XCTAssertNotEqual(child._$id, other._$id)
  }

  func testIdentityEqualForObservableCollections() {
    let rows = [ObservableRowState(), ObservableRowState()]

    XCTAssertTrue(_$isIdentityEqual(rows, rows))
    XCTAssertFalse(_$isIdentityEqual(rows, [ObservableRowState(), ObservableRowState()]))
  }
}
#endif
