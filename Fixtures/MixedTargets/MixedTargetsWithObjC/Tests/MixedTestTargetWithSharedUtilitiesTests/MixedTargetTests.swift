import XCTest

final class MixedTargetTests: XCTestCase {

    func testSwiftUtilityIsVisible() throws {
        let _ = SwiftTestHelper()
    }

    func testObjcUtilityIsVisibile() throws {
        let _ = ObjcTestHelper()
    }

    func testOtherObjcUtilityIsVisibile() throws {
        let _ = OtherObjcTestHelper()
    }

}
