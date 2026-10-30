#include <stdio.h>
#include <string.h>
#include "mathlib.h"

int main(void) {
    printf("%d\n", eider_add(40, 2));
    R_Vec2 a = { 1, 2 }, b = { 3, 4 };
    printf("%lld\n", (long long)eider_dot(a, b));
    printf("%d\n", eider_is_even(10) ? 1 : 0);
    printf("%s\n", eider_greeting());
    printf("%d\n", eider_checked_div(7, 2));
    return 0;
}
