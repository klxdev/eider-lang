# Flags for compiling AWS-LC's libcrypto with a plain C compiler (sourced by
# scripts/crypto-build.sh and scripts/update-awslc.sh). They mirror aws-lc-sys's cc builder
# (builder/cc_builder.rs in aws-lc-sys 0.47.0) for a default, non-FIPS, unprefixed build:
#   -D_XOPEN_SOURCE=700 (Linux), -DDISABLE_CPU_JITTER_ENTROPY=1 (jitterentropy is the FIPS
#   build's entropy source), AWS_LC_STDALIGN_AVAILABLE (C11), plus the feature probes the
#   build script runs (AWS_LC_BUILTIN_SWAP_SUPPORTED, HAVE_LINUX_RANDOM_H).
AWSLC_DEFS="-D_XOPEN_SOURCE=700 -DDISABLE_CPU_JITTER_ENTROPY=1 -DAWS_LC_STDALIGN_AVAILABLE=1"

# the feature probes: $1 = C compiler, $2 = a scratch directory; prints the defines
awslc_probes() {
  mkdir -p "$2"
  printf 'int main(void){return (int)__builtin_bswap16(1)+(int)__builtin_bswap32(1u)+(int)__builtin_bswap64(1u);}\n' > "$2/swap.c"
  $1 -o "$2/swap" "$2/swap.c" 2>/dev/null && printf ' -DAWS_LC_BUILTIN_SWAP_SUPPORTED=1'
  printf '#include <linux/random.h>\nint main(void){return 0;}\n' > "$2/rnd.c"
  $1 -o "$2/rnd" "$2/rnd.c" 2>/dev/null && printf ' -DHAVE_LINUX_RANDOM_H=1'
  echo
}

# include path for a source tree $1 (the vendored copy or a fetched release)
awslc_includes() {
  echo "-I$1/include -I$1/third_party/s2n-bignum/s2n-bignum-imported/include"
}
