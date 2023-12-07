import XCTest
import MixedTargetWithCustomModuleMapAndResources

final class MixedTargetWithCustomModuleMapAndResourcesTests: XCTestCase {

    func testPublicSwiftAPI() throws {
        // Check that Swift API surface is exposed...
        let _ = NewCar()
        let _ = Engine()
    }

    func testPublicObjcAPI() throws {
        // Check that Objective-C API surface is exposed...
        let _ = OldCar()
        let _ = Driver()
    }

    func testModulePrefixingWorks() throws {
        let _ = MixedTargetWithCustomModuleMapAndResources.NewCar()
        let _ = MixedTargetWithCustomModuleMapAndResources.Engine()
        let _ = MixedTargetWithCustomModuleMapAndResources.OldCar()
        let _ = MixedTargetWithCustomModuleMapAndResources.Driver()
    }

}
