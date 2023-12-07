import XCTest
import MixedTargetWithCXXPublicAPIAndCustomModuleMap

final class MixedTargetWithCXXPublicAPIAndCustomModuleMapTests: XCTestCase {
    func testFactorial() throws {
        XCTAssertEqual(factorial(5), 120)
    }

    func testSum() throws {
        XCTAssertEqual(sum(x: 60, y: 40), 100)
    }
}
