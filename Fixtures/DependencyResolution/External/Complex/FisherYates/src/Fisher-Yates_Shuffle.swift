#if os(macOS) || os(iOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

public extension Collection {
    func shuffle() -> [Iterator.Element] {
        var array = Array(self)
        array.shuffleInPlace()

        return array
    }
}

public extension MutableCollection {
    /// Shuffles the contents of this collection.
    mutating func shuffleInPlace() {
        let c = count
        guard c > 1 else { return }
        
        for (firstUnshuffled, unshuffledCount) in zip(indices, stride(from: c, to: 1, by: -1)) {
#if os(macOS) || os(iOS)
            let d = arc4random_uniform(numericCast(unshuffledCount))
#else
            let d = numericCast(random()) % unshuffledCount
#endif
            let i = index(firstUnshuffled, offsetBy: numericCast(d))
            swapAt(firstUnshuffled, i)
        }
    }
}

public let shuffle = false
