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
    R_F2 f2 = eider_f2_scale((R_F2){ 1.5f, -2.0f }, 2.0f);
    printf("f2_scale %g %g\n", (double)f2.f_a, (double)f2.f_b);
    R_F3 f3 = eider_f3_rot((R_F3){ 1.0f, 2.0f, 3.0f });
    printf("f3_rot %g %g %g\n", (double)f3.f_a, (double)f3.f_b, (double)f3.f_c);
    R_D2 d2 = eider_d2_swap((R_D2){ 1.25, 2.5 });
    printf("d2_swap %g %g\n", d2.f_a, d2.f_b);
    R_D3 d3 = eider_d3_neg((R_D3){ 1.0, -2.0, 4.0 });
    printf("d3_neg %g %g %g\n", d3.f_a, d3.f_b, d3.f_c);
    R_FD fd = eider_fd_mix((R_FD){ 0.5f, 3.0 }, (R_FD){ 0.25f, 4.0 });
    printf("fd_mix %g %g\n", (double)fd.f_a, fd.f_b);
    R_DL dl = eider_dl_next((R_DL){ 1.0, 41 });
    printf("dl_next %g %lld\n", dl.f_a, (long long)dl.f_b);
    R_LD ld = eider_ld_next((R_LD){ 10, 1.5 });
    printf("ld_next %lld %g\n", (long long)ld.f_a, ld.f_b);
    printf("ffd_sum %g\n", eider_ffd_sum((R_FFD){ 1.0f, 2.0f, 4.0 }));
    printf("fi_sum %g\n", eider_fi_sum((R_FI){ 1.5f, 7 }));
    printf("fsum %g\n", eider_fsum(1.5f, 2.25, 0.25f));
    R_D2 mx = eider_mixf(1, (R_D2){ 10.0, 20.0 }, 2, (R_F2){ 0.5f, 0.0f }, 100);
    printf("mixf %g %g\n", mx.f_a, mx.f_b);
    printf("manyd %g\n", eider_manyd(1, 1, 1, 1, 1, 1, 1, 1, 1, (R_D2){ 2.0, 3.0 }));
    printf("nan_is %d %d\n", eider_nan_is(0.0 / 0.0) ? 1 : 0, eider_nan_is(1.0) ? 1 : 0);
    printf("f32_next %g\n", (double)eider_f32_next(2.5f));
    return 0;
}
