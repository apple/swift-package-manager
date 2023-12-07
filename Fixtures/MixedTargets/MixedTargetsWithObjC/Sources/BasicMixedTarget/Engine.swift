import Foundation

// This type is Objective-C compatible and used in `OldCar`.
// FIXME(ncooke3): When Swift compiler's header generation logic is updated,
// subclass type from Objective-C.
// @objc public class Engine: CarPart {}
@objc public class Engine: NSObject {}
