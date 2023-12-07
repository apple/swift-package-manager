import XCTest
import MixedTargetWithCXX

final class MixedTargetWithCXXTests: XCTestCase {
    func testFactorial() throws {
        XCTAssertEqual(factorial(5), 120)
    }
}
