public func hello() {
    #if TRAIT_Package2Trait2
    print("Package2Library1 trait2 enabled")
    #else
    print("Package2Library1 trait2 disabled")
    #endif
}
