import Foundation
import ClangTarget

@objc public class NewBoat: Vessel {
    
    func checkForLifeJackets() {
        if hasLifeJackets {
            print("Life jackets on board!")
        } else {
            print("Life jackets missing!")
        }
    }

}
