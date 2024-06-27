# libSwiftPM - SwiftPM as a Library

**NOTE: The libSwiftPM API is currently _unstable_ and may change at any time.**

SwiftPM has a library based architecture and the top-level library product is
called `libSwiftPM`. Other packages can add SwiftPM as a package dependency and
create powerful custom build tools on top of `libSwiftPM`.

A subset of `libSwiftPM` that includes only the data model (without SwiftPM's
build system) is available as `libSwiftPMDataModel`.  Any one client should
depend on one or the other, but not both.

The SwiftPM repository contains an [example](https://github.com/swiftlang/swift-package-manager/tree/master/Examples/package-info) that demonstrates the use of
`libSwiftPM` in a Swift package. Use the following commands to run the example
package:

```sh
$ git clone https://github.com/swiftlang/swift-package-manager
$ cd swift-package-manager/Examples/package-info
$ swift run
```
