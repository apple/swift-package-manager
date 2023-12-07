import Foundation

// This type is intentionally *NOT* Objective-C compatible.
public class NewCar {
    // `Engine` is defined in Swift.
    var engine: Engine? = nil
    // The following types are defined in Objective-C.
    var driver: Driver? = nil

    public init() {}
}
