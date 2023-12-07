import XCTest
import BasicMixedTargetWithUmbrellaHeader

final class BasicMixedTargetWithNestellaHeaderTests: XCTestCase {

    func testPublicSwiftAPI() throws {
        // Check that Swift API surface is exposed...
        let _ = Cookie()
        let _ = Coffee()
    }

    func testPublicObjcAPI() throws {
        // Check that Objective-C API surface is exposed...
        let _ = Bakery()
        let _ = Dessert()
    }

    func testModulePrefixingWorks() throws {
        let _ = BasicMixedTargetWithUmbrellaHeader.Cookie()
        let _ = BasicMixedTargetWithUmbrellaHeader.Coffee()
        let _ = BasicMixedTargetWithUmbrellaHeader.Bakery()
        let _ = BasicMixedTargetWithUmbrellaHeader.Dessert()
    }

}
