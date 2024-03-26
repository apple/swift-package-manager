public func hello() {
    #if TRAIT_Package3Trait3
    print("Package3Library1 trait3 enabled")
    #else
    print("Package3Library1 trait3 disabled")
    #endif
}
