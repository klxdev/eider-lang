/* A C consumer of shapes.ei and nested.ei, built with `eiderc build --lib` (run.sh). */
#include <stdio.h>
#include "shapes.h"

/* nested.h has the same include guard as shapes.h (the recorded header form), so declare by hand */
typedef struct { int32_t x, y; } Pt;
typedef struct { Pt a, b; } Seg;
int32_t eider_seg_dx(Seg s);
Pt eider_mid(Seg s);

int main(void) {
    R_Rect r = { 3, 4 };
    printf("%lld\n", (long long)eider_area(r));
    R_Span s = { 1, 2, true };
    R_Span w = eider_widen(s, 10);
    printf("%llu %llu %d\n", (unsigned long long)w.f_lo, (unsigned long long)w.f_hi, w.f_open ? 1 : 0);
    printf("%lld\n", (long long)eider_gap(2, 9));
    printf("%s\n", eider_name());
    eider_touch();
    printf("%d %d\n", eider_is_square(r) ? 1 : 0, eider_units__twice(21));
    Seg g = { { 1, 2 }, { 5, 8 } };
    Pt m = eider_mid(g);
    printf("%d %d %d\n", eider_seg_dx(g), m.x, m.y);
    return 0;
}
