# AArch64 (AAPCS64) signatures of compiler/tests/llvm/abi.ei's exports against clang's for the
# same C prototypes (the header): every parameter and result travels the same way.
# usage: a64.sh <eiderc>; needs clang with the aarch64 target (else a skip).
cd "$(dirname "$0")/../../.." || exit 1
E=${1:-target/eiderc}
case "$E" in /*) ;; *) E=$(pwd)/$E ;; esac
T=target/llvma64
rm -rf $T
mkdir -p $T
LCC=${EIDER_LLVM_CC:-clang}
printf 'int x;\n' > $T/p.c
$LCC --target=aarch64-linux-gnu -ffreestanding -c -o $T/p.o $T/p.c 2>/dev/null || { echo "skip llvm aarch64: $LCC has no aarch64 target"; exit 2; }
printf '#!/bin/sh\nexec %s --target=aarch64-linux-gnu "$@"\n' "$(command -v $LCC)" > $T/cc
chmod +x $T/cc
$E emit-header compiler/tests/llvm/abi.ei > $T/abi.h || { echo "FAIL llvm aarch64: emit-header"; exit 1; }
{ echo '#include "abi.h"'; grep '^[A-Za-z].*eider_.*(.*);' $T/abi.h | sed 's/;$/ { __builtin_trap(); }/'; } > $T/stubs.c
$LCC --target=aarch64-linux-gnu -ffreestanding -O1 -S -emit-llvm -o $T/clang.ll $T/stubs.c || { echo "FAIL llvm aarch64: clang on the header"; exit 1; }
EIDER_LLVM_CC=$(pwd)/$T/cc $E emit-llvm --lib compiler/tests/llvm/abi.ei > $T/ours.ll || { echo "FAIL llvm aarch64: emit-llvm"; exit 1; }
python3 -I - $T/ours.ll $T/clang.ll <<'EOF' || exit 1
import re, sys
def sigs(path):
    out = {}
    for l in open(path):
        m = re.match(r'define\s+(?:dso_local\s+)?(?:noundef\s+)?(?:zeroext\s+|signext\s+)?(\[2 x i64\]|\S+)\s+@(eider_\w+)\((.*)\)', l)
        if not m:
            continue
        ret, name, params = m.group(1), m.group(2), m.group(3)
        ps, depth, cur = [], 0, ''
        for ch in params:
            if ch in '([': depth += 1
            if ch in ')]': depth -= 1
            if ch == ',' and depth == 0:
                ps.append(cur.strip()); cur = ''
            else:
                cur += ch
        if cur.strip(): ps.append(cur.strip())
        types = []
        for q in ps:
            if q.startswith('[2 x i64]'): types.append('[2 x i64]'); continue
            types.append('sret' if 'sret' in q else q.split()[0])
        out[name] = (ret, types)
    return out
# a piece of up to 8 bytes is one register whatever its width
w = lambda t: 'reg' if re.fullmatch(r'i(1|8|16|32|64)', t) else t
ours, theirs = sigs(sys.argv[1]), sigs(sys.argv[2])
bad = [n for n in theirs if n not in ours or w(ours[n][0]) != w(theirs[n][0]) or [w(x) for x in ours[n][1]] != [w(x) for x in theirs[n][1]]]
for n in bad: print('FAIL llvm aarch64: %s: ours %s, clang %s' % (n, ours.get(n), theirs[n]))
if bad: sys.exit(1)
print('ok   llvm aarch64: %d exports of abi.ei pass and return as clang does for AAPCS64 (pairs, sret, pointers to copies)' % len(theirs))
EOF
rm -rf $T
