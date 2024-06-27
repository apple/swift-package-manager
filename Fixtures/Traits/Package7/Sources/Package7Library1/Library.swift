#if Package7Trait1
import Package8Library1
#endif

public func hello() {
    #if Package7Trait1
    print("Package7Library1 trait1 enabled")
    Package8Library1.hello()
    #else
    print("Package7Library1 trait1 disabled")
    #endif
}
