import Foundation

// NOTE: This target is an edge case. It's purpose may or may not be useful,
// but it shouldn't fail to build.

// This type is Objective-C compatible and used in `OldCar`.
@objc public class Bar: NSObject {
  @objc public func doStuff() {}
}

public struct Baz {
  public let bar: Bar?
  public init(bar: Bar? = nil) {
    self.bar = bar
  }
}

