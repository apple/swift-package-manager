#include "FactorialFinder.hpp"

long FactorialFinder::factorial(int n) {
    if (n == 0 || n == 1) return 1;
    return n * factorial(n-1);
}
