import XCTest
import MixedTargetWithResources

final class MixedTargetWithResourcesTests: XCTestCase {
    func testResourceCanBeAccessed() throws {
        // From Swift context...
        XCTAssertEqual(
            try SwiftResourceReader.read("foo", type: "txt"),
            "Hello world!\n"
        )

        // From Objective-C context...
        XCTAssertEqual(
            ObjcResourceReader.readResource("foo", ofType: "txt")!,
            "Hello world!\n"
        )
    }
}
