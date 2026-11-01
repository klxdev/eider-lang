#!/bin/sh
# Fuzz seed/wasm2c.c (seed/README.md): wasm2c built with ASan and UBSan translates mutants of
# the seed (or of the module given as $1): random byte flips, insertions, deletions and
# truncations, N of them (default 2000; $N). Every run must end with exit 0 (translated) or 1
# (a message: malformed or unsupported input), never a crash or a sanitizer report; and the
# first M mutants that translate (default 20; $M) are compiled with -fsanitize=undefined to
# check that the C it writes compiles. The mutations are deterministic (seeded; $SEED).
cd "$(dirname "$0")/../.." || exit 1
in=${1:-seed/eiderc.wasm}
N=${N:-2000}
M=${M:-20}
SEED=${SEED:-1}
T=target/wasm2c-fuzz
rm -rf $T
mkdir -p $T
CC=${CC:-cc}
$CC -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -o $T/wasm2c seed/wasm2c.c || { echo "FAIL build wasm2c with sanitizers"; exit 1; }
[ -f "$in" ] || { echo "FAIL fuzz: no module $in"; exit 1; }
python3 -I - "$in" "$T" "$N" "$M" "$SEED" "$CC" <<'EOF'
import os, random, subprocess, sys
src, T, N, M, seed, cc = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
data = open(src, 'rb').read()
rnd = random.Random(seed)
ok = errors = compiled = 0
env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:abort_on_error=0:exitcode=99', UBSAN_OPTIONS='halt_on_error=1:exitcode=98')
for i in range(N):
    b = bytearray(data)
    for _ in range(rnd.choice([1, 1, 2, 4, 16])):
        k = rnd.randrange(6)
        p = rnd.randrange(len(b)) if b else 0
        if k == 0 and b: b[p] ^= 1 << rnd.randrange(8)
        elif k == 1 and b: b[p] = rnd.randrange(256)
        elif k == 2: b[p:p] = bytes([rnd.randrange(256)])
        elif k == 3 and b: del b[p:p + rnd.randrange(1, 8)]
        elif k == 4: b = b[:rnd.randrange(len(b) + 1)]
        elif k == 5 and b: b[p] = rnd.choice([0x00, 0x7f, 0x80, 0xff, 0x0b, 0x40])
    f = os.path.join(T, 'm.wasm')
    open(f, 'wb').write(b)
    r = subprocess.run([os.path.join(T, 'wasm2c'), f, '-o', os.path.join(T, 'm.c')], env=env, capture_output=True)
    if r.returncode == 0:
        ok += 1
        if compiled < M:
            c = subprocess.run([cc, '-std=c11', '-fsyntax-only', '-w', os.path.join(T, 'm.c')], capture_output=True)
            if c.returncode != 0:
                open(os.path.join(T, 'bad%d.wasm' % i), 'wb').write(b)
                print('FAIL fuzz: mutant %d translated to C that does not compile (%s/bad%d.wasm)' % (i, T, i)); print(c.stderr.decode()[:2000]); sys.exit(1)
            compiled += 1
    elif r.returncode == 1 and r.stderr.startswith(b'wasm2c: '):
        errors += 1
    else:
        open(os.path.join(T, 'crash%d.wasm' % i), 'wb').write(b)
        print('FAIL fuzz: mutant %d: exit %d (%s/crash%d.wasm)' % (i, r.returncode, T, i)); print(r.stderr.decode()[:2000]); sys.exit(1)
print('ok   wasm2c fuzz: %d mutants of %s under ASan+UBSan: %d translated (%d of them compiled), %d rejected with a message' % (N, src, ok, compiled, errors))
EOF
