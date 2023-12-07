import XCTest
import BasicMixedTarget

final class BasicMixedTargetTests: XCTestCase {

    func testPublicSwiftAPI() throws {
        // Check that Swift API surface is exposed...
        let _ = NewCar()
        let _ = Engine()
    }

    func testPublicObjcAPI() throws {
        // Check that Objective-C API surface is exposed...
        let _ = OldCar()
        let _ = Driver()
        let _ = CarPart()
    }

    func testModulePrefixingWorks() throws {
        let _ = BasicMixedTarget.NewCar()
        let _ = BasicMixedTarget.Engine()
        let _ = BasicMixedTarget.OldCar()
        let _ = BasicMixedTarget.Driver()
        let _ = BasicMixedTarget.CarPart()
    }

}
