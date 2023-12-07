import XCTest
import MixedTargetWithC

final class MixedTargetWithCTests: XCTestCase {
    func testFactorial() throws {
        XCTAssertEqual(factorial(5), 120)
    }
}
