/* A C consumer of abi.ei built with `eiderc build --lib` (run.sh): every
   record crosses by value under the System V x86-64 ABI, as this C compiler implements it. */
#include <stdio.h>
#include "abi.h"

int main(void) {
    R_B2 b2 = { 7, true };
    printf("b2_sum %u\n", (unsigned)eider_b2_sum(b2));
    R_M12 m = eider_m12_make(200, 70000, true);
    printf("m12_make %u %u %d\n", (unsigned)m.f_a, (unsigned)m.f_b, m.f_c ? 1 : 0);
    R_M12 m2 = eider_m12_bump(m);
    printf("m12_bump %u %u %d\n", (unsigned)m2.f_a, (unsigned)m2.f_b, m2.f_c ? 1 : 0);
    R_L16 x = { -5, 0xF0 }, y = { 37, 0x0F };
    R_L16 l = eider_l16_mix(x, y);
    printf("l16_mix %lld %u\n", (long long)l.f_a, (unsigned)l.f_b);
    R_T24 t = { 1, -2, 3 };
    R_T24 t2 = eider_t24_rot(t);
    printf("t24_rot %lld %lld %d\n", (long long)t2.f_a, (long long)t2.f_b, (int)t2.f_c);
    R_M12 a = { 1, 2, false }, b = { 3, 4, true }, c = { 5, 6, false };
    R_L16 d = { 7, 8 };
    printf("many %lld\n", (long long)eider_many(a, b, c, d));
    R_Q q = { true, 40 };
    R_N n = { { 9, false }, { 11, 1000, true } };
    R_S s = { "label", 5 };
    R_N r = eider_mixed(-3, q, 250, n, s);
    printf("mixed %u %d %u %u %d\n", (unsigned)r.f_b.f_a, r.f_b.f_b ? 1 : 0, (unsigned)r.f_m.f_a, (unsigned)r.f_m.f_b, r.f_m.f_c ? 1 : 0);
    printf("eqs %d %d\n", eider_eqs(a, a) ? 1 : 0, eider_eqs(a, b) ? 1 : 0);
    printf("label %s\n", eider_label(s));
    R_Q q2 = eider_q_neg(q);
    printf("q_neg %d %lld\n", q2.f_x ? 1 : 0, (long long)q2.f_y);
    return 0;
}
