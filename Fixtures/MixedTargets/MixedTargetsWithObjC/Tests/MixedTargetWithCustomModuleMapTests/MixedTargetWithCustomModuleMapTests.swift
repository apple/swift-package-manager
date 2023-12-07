import XCTest
import MixedTargetWithCustomModuleMap

final class MixedTargetWithCustomModuleMapTests: XCTestCase {

    func testPublicSwiftAPI() throws {
        // Check that Swift API surface is exposed...
        let _ = NewCar()
        let _ = Engine()
    }

    func testPublicObjcAPI() throws {
        // Check that Objective-C API surface is exposed...
        let _ = MyOldCar()
        let _ = MyDriver()
        let _ = MyMachine()
    }

    func testModulePrefixingWorks() throws {
        let _ = MixedTargetWithCustomModuleMap.MyMachine()
        let _ = MixedTargetWithCustomModuleMap.NewCar()
        let _ = MixedTargetWithCustomModuleMap.Engine()
        let _ = MixedTargetWithCustomModuleMap.MyOldCar()
        let _ = MixedTargetWithCustomModuleMap.MyDriver()
    }

}
