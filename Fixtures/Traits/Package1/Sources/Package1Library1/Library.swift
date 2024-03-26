public func hello() {
    #if TRAIT_Package1Trait1
    print("Package1Library1 trait1 enabled")
    #else
    print("Package1Library1 trait1 disabled")
    #endif
}
