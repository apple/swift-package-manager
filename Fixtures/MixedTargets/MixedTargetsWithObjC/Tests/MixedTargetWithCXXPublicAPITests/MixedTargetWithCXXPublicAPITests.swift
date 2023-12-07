import XCTest
import MixedTargetWithCXXPublicAPI

final class MixedTargetWithCXXPublicAPITests: XCTestCase {
    func testFactorial() throws {
        XCTAssertEqual(factorial(5), 120)
    }

    func testSum() throws {
        XCTAssertEqual(sum(x: 60, y: 40), 100)
    }
}
