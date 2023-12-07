#include "include/find_factorial.h"

long find_factorial(int x) {
    if (x == 0 || x == 1) return 1;
    return x * find_factorial(x-1);
}
