#!/usr/bin/env bash
# nexon/windows-tests.sh - run the firstmate test suites on the Windows (Git Bash)
# setup, leaving out the suites nexon/windows-test-ignore.txt lists.
#
# Usage: nexon/windows-tests.sh [-j N] [-o DIR] [suite-name ...]
#   -j N    run N non-herdr suites at once (default 2); herdr suites always run
#           one at a time, because parallel herdr labs clobber each other
#   -o DIR  write <suite>.log files and SUMMARY there (default: a new temp dir)
#   names   run only these suites (tests/<name>.test.sh); an ignored name is
#           still left out
#
# SUMMARY gets one line per suite: <name> rc= secs= ok= skip= notok=.
# Exit status is 0 when every suite that ran exited 0.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IGNORE="$ROOT/nexon/windows-test-ignore.txt"
jobs=2 out=''
while getopts 'j:o:' opt; do
  case "$opt" in
    j) jobs=$OPTARG ;;
    o) out=$OPTARG ;;
    *) sed -n '2,13p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ -n "$out" ] || out=$(mktemp -d "${TMPDIR:-/tmp}/fm-windows-tests.XXXXXX")
mkdir -p "$out"

if [ "$#" -gt 0 ]; then
  names=$(printf '%s\n' "$@")
else
  names=$(find "$ROOT/tests" -maxdepth 1 -name '*.test.sh' -printf '%f\n' | sed 's/\.test\.sh$//' | sort)
fi
ignored=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$IGNORE" | grep -v '^$')
names=$(printf '%s\n' "$names" | grep -vxF -e "$ignored")

serial='' parallel=''
for name in $names; do
  [ -f "$ROOT/tests/$name.test.sh" ] || { echo "no such suite: $name" >&2; exit 2; }
  if grep -qE 'fm-herdr-lab|herdr_lab' "$ROOT/tests/$name.test.sh"; then
    serial+="$name"$'\n'
  else
    parallel+="$name"$'\n'
  fi
done

run_one() {  # <root> <out> <name>
  local start rc log="$2/$3.log"
  start=$(date +%s)
  (cd "$1" && timeout 3600 bash "tests/$3.test.sh") >"$log" 2>&1
  rc=$?
  printf '%s rc=%s secs=%s ok=%s skip=%s notok=%s\n' "$3" "$rc" "$(($(date +%s) - start))" \
    "$(grep -c '^ok' "$log")" "$(grep -c '^skip' "$log")" "$(grep -c '^not ok' "$log")" >>"$2/SUMMARY"
}
export -f run_one

echo "logs: $out ($(printf '%s' "$serial$parallel" | grep -c .) suites, $(printf '%s\n' "$ignored" | grep -c .) ignored)"
printf '%s' "$serial" | xargs -r -n 1 -P 1 bash -c 'run_one "$@"' _ "$ROOT" "$out" &
printf '%s' "$parallel" | xargs -r -n 1 -P "$jobs" bash -c 'run_one "$@"' _ "$ROOT" "$out" &
wait

failed=$(awk '$2 != "rc=0"' "$out/SUMMARY")
if [ -n "$failed" ]; then
  printf 'failed:\n%s\n' "$failed"
  exit 1
fi
echo "all passed"
