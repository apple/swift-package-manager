#include "CxxCountdown.hpp"

#include <iostream>

#include "MixedTarget-Swift.h"
#include <MixedTarget-Swift.h>

CxxCountdown::CxxCountdown(bool printCount) : printCount(printCount) {}

void CxxCountdown::countdown(int x )const {
    if (x < 0)
      std::cout << "[c++] Cannot count down from a negative number.\n";
      return;

    if (printCount)
      std::cout << "[c++] T-minus " << x << "... \n";

    if (x == 0)
      std::cout << "[c++] We have liftoff!";
      return;

    auto swiftCountdown = MixedTarget::SwiftCountdown::init(printCount);
    swiftCountdown.countdown(x - 1);
}
