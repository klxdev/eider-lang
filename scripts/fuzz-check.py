#!/usr/bin/env python3
"""Differential fuzzing of `eiderc check --json` against the bootstrap.

Mutates v0 programs (identifiers, literals, type names, operators, small insertions) and
reports every mutant where the two compilers disagree; it is kept next to its seed (imports
are relative) as fuzz_<n>.ei. Mutants eiderc calls `unsupported`, and inputs the bootstrap
crashes on, are skipped.

  scripts/fuzz-check.py [count] [seed files...]     (after scripts/test-compiler.sh built
  SEED=n MODE=semantic|wild                          target/eiderc)
"""
import os, random, re, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
os.chdir(ROOT)
S0 = subprocess.run(['scripts/stage0.sh'], capture_output=True, text=True).stdout.strip()
NEW = './target/eiderc'
SEEDS = sys.argv[2:] or sorted(
    ['compiler/tests/check/pass/' + f for f in os.listdir('compiler/tests/check/pass')]
    + ['compiler/tests/check/fail/' + f for f in os.listdir('compiler/tests/check/fail')]
    + ['compiler/tests/ir/' + f for f in os.listdir('compiler/tests/ir') if f.endswith('.ei')]
    + ['tests/run/order.ei', 'tests/run/warehouse.ei', 'tests/run/modules.ei', 'examples/warehouse.ei'])
N = int(sys.argv[1]) if len(sys.argv) > 1 else 500
MODE = os.environ.get('MODE', 'semantic')
TOK = re.compile(r'"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*|\d+|->|=>|==|!=|<=|>=|&&|\|\||\+%|-%|\*%|\.\.|\s+|.', re.S)
TYNAMES = ['i32', 'i64', 'u8', 'u32', 'u64', 'usize', 'bool', 'str']
NUMS = ['0', '1', '2', '255', '256', '4294967296', '18446744073709551615', '18446744073709551616']
KW = ['let', 'var', 'if', 'else', 'while', 'for', 'return', 'break', 'continue', 'match', 'inout',
      'true', 'false', 'fn', 'pub', 'uses', 'io', 'clock', 'as', '_']
SUFFIX = [' + 1', ' * 300', ' / 0', ' == true', ' as u8', '.x', '[0]', '[9]', ' as usize', ' + true']
OPS = ['==', '<', '+', '-', '*', '/', '%', '&&', '||', '+%', '*%']


def semantic(toks, rnd, idents):
    i = rnd.randrange(len(toks))
    t = toks[i]
    r = rnd.random()
    if t in TYNAMES:
        toks[i] = rnd.choice(TYNAMES)
    elif re.match(r'\d+$', t):
        toks[i] = rnd.choice(NUMS)
    elif t in idents and r < 0.5:
        toks[i] = rnd.choice(idents)
    elif t in idents and r < 0.8:
        toks[i] = t + rnd.choice(SUFFIX)
    elif t in idents:
        toks[i] = rnd.choice(['inout ', '-', '!']) + t
    elif t in ('true', 'false'):
        toks[i] = rnd.choice(['true', 'false', '1', '"s"'])
    elif t in OPS:
        toks[i] = rnd.choice(OPS)
    elif t in ('let', 'var'):
        toks[i] = rnd.choice(['let', 'var'])


def wild(toks, rnd, idents):
    idx = [i for i, t in enumerate(toks) if not t.isspace()]
    i = rnd.choice(idx)
    r = rnd.random()
    if r < 0.3 and idents:
        toks[i] = rnd.choice(idents)
    elif r < 0.45:
        toks[i] = rnd.choice(NUMS)
    elif r < 0.6:
        toks[i] = rnd.choice(TYNAMES)
    elif r < 0.7:
        toks[i] = rnd.choice(KW)
    elif r < 0.8:
        toks[i] = ''
    elif r < 0.9:
        toks[i] = toks[i] + rnd.choice(SUFFIX)
    else:
        toks.insert(i, rnd.choice(['inout ', '-', '!', 'return ', 'unsafe ']))


def mutate(src, rnd):
    toks = TOK.findall(src)
    idents = [t for t in toks if re.match(r'[A-Za-z_]\w*$', t) and t not in KW + TYNAMES]
    for _ in range(rnd.randint(1, 2)):
        (wild if MODE == 'wild' else semantic)(toks, rnd, idents)
    return ''.join(toks)


def run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None, 'timeout'
    return r.stdout.strip(), r.stderr


rnd = random.Random(int(os.environ.get('SEED', '1')))
stats = {'agree': 0, 'unsupported': 0, 'disagree': 0, 'bootstrap crashed': 0}
codes = {}
for k in range(N):
    seed = rnd.choice(SEEDS)
    mut = mutate(open(seed).read(), rnd)
    path = os.path.join(os.path.dirname(seed), 'fuzz_tmp.ei')
    open(path, 'w').write(mut)
    got, gerr = run([NEW, 'check', '--json', path])
    if got is not None and '"error":"unsupported"' in got:
        stats['unsupported'] += 1
    else:
        want, werr = run([S0, 'check', '--json', path])
        if want is None or 'panicked' in werr:
            stats['bootstrap crashed'] += 1
        elif got == want and not gerr.strip():
            stats['agree'] += 1
            code = got[10:15] if got else 'ok'
            codes[code] = codes.get(code, 0) + 1
        else:
            stats['disagree'] += 1
            keep = os.path.join(os.path.dirname(seed), 'fuzz_%d.ei' % k)
            open(keep, 'w').write(mut)
            print('DISAGREE', keep)
            print('  bootstrap:', want)
            print('  eiderc:   ', got, gerr.strip()[:200])
    os.remove(path)
print(stats)
print(' '.join('%s:%d' % kv for kv in sorted(codes.items())))
sys.exit(1 if stats['disagree'] else 0)
