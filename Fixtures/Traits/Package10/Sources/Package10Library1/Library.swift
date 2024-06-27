public func hello() {
    #if Package10Trait1
    print("Package10Library1 trait1 enabled")
    #else
    print("Package10Library1 trait1 disabled")
    #endif
    #if Package10Trait2
    print("Package10Library1 trait2 enabled")
    #else
    print("Package10Library1 trait2 disabled")
    #endif
}
