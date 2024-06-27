#if Package5Trait1
import Package6Library1
#endif

public func hello() {
    #if Package5Trait1
    print("Package5Library1 trait1 enabled")
    Package6Library1.hello()
    #else
    print("Package5Library1 trait1 disabled")
    #endif
}
