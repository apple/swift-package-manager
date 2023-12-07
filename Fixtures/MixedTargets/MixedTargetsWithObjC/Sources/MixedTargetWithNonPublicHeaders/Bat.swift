import Foundation

public class Bat {
  #if EXPECT_FAILURE
    // The following Objective-C types are defined in non-public headers.
    let foo: Foo? = nil
    let bar: Bar? = nil
  #endif // EXPECT_FAILURE
}
