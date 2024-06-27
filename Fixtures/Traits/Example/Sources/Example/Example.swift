#if Package1
import Package1Library1
#endif
#if Package2
import Package2Library1
#endif
#if Package3
import Package3Library1
#endif
#if Package4
import Package4Library1
#endif
#if Package5
import Package5Library1
#endif
#if Package7
import Package7Library1
#endif
#if Package9
import Package9Library1
#endif
#if Package10
import Package10Library1
#endif

@main
struct Example {
    static func main() {
        #if Package1
        Package1Library1.hello()
        #endif
        #if Package2
        Package2Library1.hello()
        #endif
        #if Package3
        Package3Library1.hello()
        #endif
        #if Package4
        Package4Library1.hello()
        #endif
        #if Package5
        Package5Library1.hello()
        #endif
        #if Package7
        Package7Library1.hello()
        #endif
        #if Package9
        Package9Library1.hello()
        #endif
        #if Package10
        Package10Library1.hello()
        #endif
        #if DEFINE1
        print("DEFINE1 enabled")
        #else
        print("DEFINE1 disabled")
        #endif
        #if DEFINE2
        print("DEFINE2 enabled")
        #else
        print("DEFINE2 disabled")
        #endif
        #if DEFINE3
        print("DEFINE3 enabled")
        #else
        print("DEFINE3 disabled")
        #endif
    }
}
