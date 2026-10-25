#!/bin/bash
# Runs every headless test and prints one line per suite plus any failing lines. Needs Godot 4.7 as `godot` on the PATH.
#   tests/run_all.sh              everything
#   tests/run_all.sh smoke        only the groups whose name contains one of the words
# Groups:  shared (navigation, work, quarry, craft, brick: one shared world, one process), smoke, islands, cover, ramps.
# Several groups run at once. The pass/fail verdict is read from the output (a "TEST DONE"/"SUITES DONE" line and no FAIL or SCRIPT
# ERROR line), not from the exit code: Godot headless sometimes aborts while shutting down after a world was generated.
cd "$(dirname "$0")/.." || exit 1
LOG=$(mktemp -d)
declare -A SCRIPT=( [smoke]="res://tests/world_smoke_test.gd" [shared]="res://tests/run_suites.gd" [islands]="res://tests/island_seeds_test.gd" [cover]="res://tests/ground_cover_test.gd" [ramps]="res://tests/ramps_rule_test.gd" )
ALL="smoke shared islands cover ramps"   # slowest first
WANT=""
if [ $# -eq 0 ]; then WANT="$ALL"; else
  for g in $ALL; do for w in "$@"; do [[ "$g" == *"$w"* ]] && WANT="$WANT $g" && break; done; done
fi
godot --headless --path . --import >/dev/null 2>&1
run_one() {
  g=$1; script=$2; log=$3/$g.log; t0=$(date +%s)
  timeout 1800 godot --headless --path . -s "$script" > "$log" 2>&1
  t1=$(date +%s)
  bad=$(grep -c "^FAIL\|SCRIPT ERROR" "$log")
  done_line=$(grep -c "TEST DONE: passed\|SUITES DONE: 0 failed" "$log")
  if [ "$bad" -eq 0 ] && [ "$done_line" -ge 1 ]; then echo "PASS $g ($((t1 - t0)) s)"; else echo "FAIL $g ($((t1 - t0)) s)"; grep "^FAIL\|SCRIPT ERROR" "$log" | head -8; [ "$done_line" -eq 0 ] && echo "   (no completion line: it crashed or timed out)"; fi
}
export -f run_one
for g in $WANT; do echo "$g ${SCRIPT[$g]}"; done | xargs -P 3 -L1 bash -c 'run_one "$0" "$1" '"$LOG" | tee "$LOG/summary.txt"
grep -q "^FAIL" "$LOG/summary.txt" && STATUS=1 || STATUS=0
rm -rf "$LOG"
exit $STATUS
