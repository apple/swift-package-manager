public func hello() {
    #if Package1Trait1
    print("Package1Library1 trait1 enabled")
    #else
    print("Package1Library1 trait1 disabled")
    #endif
}
