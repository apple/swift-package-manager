import XCTest
import MixedTargetWithNoPublicObjectiveCHeaders

final class MixedTargetWithNoPublicObjectiveCHeadersTests: XCTestCase {

    func testPublicSwiftAPI() throws {
        // Check that Swift API surface is exposed...
        let _ = Bar()
        let _ = Baz()
        let _ = MixedTargetWithNoPublicObjectiveCHeaders.Bar()
        let _ = MixedTargetWithNoPublicObjectiveCHeaders.Baz()
    }

    #if EXPECT_FAILURE
    func testObjcAPI() throws {
        // No Objective-C API should be exposed...
        let _ = OnLoadHook()
    }
    #endif

}
