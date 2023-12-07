import Foundation

public struct SwiftCountdown {
    private let printCount: Bool

    public init(printCount: Bool) {
      self.printCount = printCount
    }

    public func countdown(x: Int) {
      if x < 0 {
        print("[swift] Cannot count down from a negative number.")
        return
      }

      if printCount {
        print("[swift] T-minus \(x)...")
      }

      if x == 0 {
        print("[swift] We have liftoff!")
        return
      }

      let cxxCountdown = CxxCountdown(printCount)
      cxxCountdown.countdown(Int32(x) - 1)
    }
}
