/* A C consumer of shapes.ei and nested.ei, built with `eiderc build --lib` (run.sh): both
   headers in one file, each with the include guard of its library (EIDER_SHAPES_H,
   EIDER_NESTED_H). */
#include <stdio.h>
#include "shapes.h"
#include "nested.h"
#include "shapes.h" /* a second include is a no-op */

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
    R_Seg g = { { 1, 2 }, { 5, 8 } };
    R_Pt m = eider_mid(g);
    printf("%d %d %d\n", eider_seg_dx(g), m.f_x, m.f_y);
    return 0;
}
