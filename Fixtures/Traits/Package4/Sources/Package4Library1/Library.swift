public func hello() {
    #if TRAIT_Package4Trait1
    print("Package4Library1 trait1 enabled")
    #else
    print("Package4Library1 trait1 disabled")
    #endif
}
