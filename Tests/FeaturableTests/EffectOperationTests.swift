@testable import Featurable
import Combine
import XCTest

final class EffectOperationTests: XCTestCase {
  @MainActor
  func testMergeDiscardsNones() async {
    var effect = Effect<Int>.none.merge(with: .none)
    switch effect.operation {
    case .none:
      break
    default:
      XCTFail("Expected .none")
    }

    effect = Effect<Int>.run { send in
      await send(42)
    }
    .merge(with: .none)

    switch effect.operation {
    case .run(_, _, let operation):
      var values: [Int] = []
      await operation(Send { values.append($0) })
      XCTAssertEqual(values, [42])
    default:
      XCTFail("Expected .run")
    }

    effect = Effect<Int>.none
      .merge(with: .run { send in
        await send(1729)
      })

    switch effect.operation {
    case .run(_, _, let operation):
      var values: [Int] = []
      await operation(Send { values.append($0) })
      XCTAssertEqual(values, [1729])
    default:
      XCTFail("Expected .run")
    }
  }

  @MainActor
  func testMergeRunEffects() async {
    let effect = Effect<Int>.run { send in
      await send(42)
    }
    .merge(
      with: .run { send in
        await send(1729)
      }
    )

    switch effect.operation {
    case .run(_, _, let operation):
      var values: [Int] = []
      await operation(Send { values.append($0) })
      XCTAssertEqual(Set(values), [42, 1729])
    default:
      XCTFail("Expected .run")
    }
  }
}
