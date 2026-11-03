#!/bin/sh
# Task benchmarks (docs/runtime.md "Tasks: measured", docs/design/lightweight-tasks.md):
#   sh scripts/task-bench.sh [N]       N blocked tasks (default 100000)
# builds tests/bench/scale/tasks_scale.ei and tests/bench/tasks.ei and prints, for tasks and for
# OS threads (EIDER_TASKS=threads): the time per spawn, the memory per blocked task, the time to
# release and join them, the warm spawn+join cost, and the wall time of tests/bench/tasks.ei.
# The thread runs fail past the system's thread limit; that is a result.
cd "$(dirname "$0")/.." || exit 1
N=${1:-100000}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
E=${EIDER:-scripts/ei}
$E build tests/bench/scale/tasks_scale.ei -o "$T/scale" || exit 1
$E build tests/bench/tasks.ei -o "$T/tasks" || exit 1
ms() { s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); echo $(((e - s) / 1000000)); }
for mode in tasks threads; do
  echo "== $mode, $N tasks"
  if [ $mode = threads ]; then EIDER_TASKS=threads; else EIDER_TASKS=; fi
  export EIDER_TASKS
  [ $mode = tasks ] && unset EIDER_TASKS
  TASKS=$N "$T/scale" 2>&1
  echo "tests/bench/tasks.ei: $(ms "$T/tasks") ms"
done
echo "== tasks, 256 KiB stacks, $N tasks"
unset EIDER_TASKS
EIDER_TASK_STACK=262144 TASKS=$N "$T/scale" 2>&1
