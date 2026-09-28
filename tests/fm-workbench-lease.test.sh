#!/usr/bin/env bash
# tests/fm-workbench-lease.test.sh - per-repo workbench leases
# (bin/fm-workbench.sh lease|release|status, bin/fm-workbench-lib.sh ::
# fm_workbench_clone_dirt).
#
# Each case builds its own pool: workbench roots holding real git clones, a
# state/workbenches cache as discover would write it, and the captain's
# confirmations. No case reads IIS.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workbench-lease)
fm_git_identity fmtest fmtest@example.invalid
CMD="$ROOT/bin/fm-workbench.sh"

winpath() {  # <posix-path>
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# A Nexon4-shaped clone: one config Switch-Site.ps1 rewrites, one it does not.
make_nexon_clone() {  # <clone>
  local clone=$1
  fm_git_init_commit "$clone"
  mkdir -p "$clone/Frontend/Source/Nexon.Web" "$clone/Other"
  printf '<configuration />\n' > "$clone/Frontend/Source/Nexon.Web/Web.config"
  printf 'x\n' > "$clone/Other/App.config"
  cat > "$clone/Switch-Site.ps1" <<'PS'
$plan = @(
    [PSCustomObject]@{ Path = "Frontend\Source\Nexon.Web\Web.config";   OriginKeys = @("FrontendUrl") }
)
PS
  git -C "$clone" add -A
  git -C "$clone" commit -qm fixture
}

# Build a home at $1 whose pool lists each named root under $1/wb, all confirmed
# unless named in $UNCONFIRMED.
make_home() {  # <dir> <id>...
  local dir=$1 id
  shift
  mkdir -p "$dir/state" "$dir/data"
  printf '# id\troot\tclone\tsite\turl\tidentity\n' > "$dir/state/workbenches"
  : > "$dir/data/workbenches-confirmed"
  for id in "$@"; do
    mkdir -p "$dir/wb/$id"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(winpath "$dir/wb/$id")" "$(winpath "$dir/wb/$id/Nexon4")" \
      "site-$id" "http://$id.localhost" - >> "$dir/state/workbenches"
    case " ${UNCONFIRMED:-} " in *" $id "*) ;; *) printf '%s\n' "$id" >> "$dir/data/workbenches-confirmed" ;; esac
  done
}

run_in() {  # <dir> <args>...
  local dir=$1
  shift
  FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$CMD" "$@"
}

test_each_clone_is_leased_to_one_task() {
  local dir out rc=0
  dir="$TMP_ROOT/one-task-each"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  out=$(run_in "$dir" lease t1 Nexon4) || fail "the first lease failed"
  assert_contains "$out" "leased: wa Nexon4" "the first free clone is leased"
  assert_present "$dir/state/workbench-wa-nexon4.lease" "the lease is recorded per repo clone"
  out=$(run_in "$dir" lease t1 nexon4) || fail "a repeat lease failed"
  assert_contains "$out" "leased: wa" "a repeat lease prints the existing lease"
  out=$(run_in "$dir" lease t2 Nexon4) || fail "the second task found no clone"
  assert_contains "$out" "leased: wb Nexon4" "a second task gets the other workbench"
  out=$(run_in "$dir" lease t3 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "a third task finds every clone busy"
  assert_contains "$out" "wa: leased by task t1" "the busy reason names the holder"
  pass 'each repo clone is leased to one task at a time'
}

test_only_unstaged_switch_site_configs_count_as_clean() {
  local dir clone out rc
  dir="$TMP_ROOT/cleanliness"
  make_home "$dir" wa
  clone="$dir/wb/wa/Nexon4"
  make_nexon_clone "$clone"

  printf 'rewritten\n' > "$clone/Frontend/Source/Nexon.Web/Web.config"
  out=$(run_in "$dir" lease t1 Nexon4) || fail "an unstaged Switch-Site config blocked the lease"
  run_in "$dir" release t1 >/dev/null

  git -C "$clone" add Frontend/Source/Nexon.Web/Web.config
  rc=0; out=$(run_in "$dir" lease t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "a staged Switch-Site config is dirt"
  assert_contains "$out" "uncommitted changes" "the dirt is reported"
  git -C "$clone" reset -q

  printf 'y\n' > "$clone/Other/App.config"
  rc=0; run_in "$dir" lease t1 Nexon4 >/dev/null 2>&1 || rc=$?
  assert_equals "$rc" 4 "a config Switch-Site.ps1 does not list is dirt"
  git -C "$clone" checkout -q -- Other/App.config

  printf 'new\n' > "$clone/untracked.txt"
  rc=0; run_in "$dir" lease t1 Nexon4 >/dev/null 2>&1 || rc=$?
  assert_equals "$rc" 4 "an untracked file is dirt"
  rm -f "$clone/untracked.txt"

  run_in "$dir" lease t1 Nexon4 >/dev/null || fail "the restored clone was not leasable"
  pass 'only an unstaged edit of a Switch-Site config counts as clean'
}

test_a_task_stays_in_its_workbench_for_a_second_repo() {
  local dir out rc=0
  dir="$TMP_ROOT/second-repo"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  fm_git_init_commit "$dir/wb/wb/Payroll" >/dev/null
  run_in "$dir" lease t1 Nexon4 >/dev/null
  out=$(run_in "$dir" lease t1 Payroll 2>&1) || rc=$?
  assert_equals "$rc" 3 "the task's workbench has no clone of the second repo"
  assert_contains "$out" "workbench wa has no clone of Payroll" "the refusal names the task's workbench"
  rc=0; run_in "$dir" lease t1 Payroll wb >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit other workbench pulled the task out of its own"
  out=$(run_in "$dir" lease t2 Nexon4 wb) || fail "an explicit workbench lease failed"
  out=$(run_in "$dir" lease t2 Payroll) || fail "the second repo in the same workbench failed"
  assert_contains "$out" "leased: wb Payroll" "the second repo is leased in the task's workbench"
  pass 'a task leases its second repo in the workbench it already works in'
}

test_missing_and_unconfirmed_clones_are_refused() {
  local dir out rc=0
  dir="$TMP_ROOT/refusals"
  UNCONFIRMED=wb make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wb/Nexon4"
  out=$(run_in "$dir" lease t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "the only clone is on an unconfirmed workbench"
  assert_contains "$out" "wb: not confirmed by the captain" "the unconfirmed reason is listed"
  rc=0; out=$(run_in "$dir" lease t1 Absent 2>&1) || rc=$?
  assert_equals "$rc" 3 "no workbench has the repo"
  assert_contains "$out" "the captain decides where to clone it" "the refusal hands the clone decision to the captain"
  rc=0; run_in "$dir" lease 'bad/id' Nexon4 >/dev/null 2>&1 || rc=$?
  assert_equals "$rc" 2 "a task id that is not a plain name is refused"
  assert_absent "$dir/state/.workbench-lease.lock" "no lease lock is left behind"
  pass 'a missing repo, an unconfirmed workbench, and a bad task id are refused'
}

test_release_drops_only_that_tasks_leases() {
  local dir out
  dir="$TMP_ROOT/release"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  fm_git_init_commit "$dir/wb/wa/Payroll" >/dev/null
  run_in "$dir" lease t1 Nexon4 >/dev/null
  run_in "$dir" lease t1 Payroll >/dev/null
  run_in "$dir" lease t2 Nexon4 >/dev/null
  out=$(run_in "$dir" release t1)
  assert_contains "$out" "released: wa Nexon4" "the first repo is released"
  assert_contains "$out" "released: wa Payroll" "the second repo is released"
  out=$(run_in "$dir" status)
  assert_contains "$out" "wb"$'\t'"Nexon4"$'\t'"t2" "another task's lease survives"
  assert_not_contains "$out" "t1" "no lease of the released task remains"
  out=$(run_in "$dir" release t1)
  assert_contains "$out" "no lease held by task t1" "a second release is a no-op"
  pass 'release drops every lease of that task and nothing else'
}

test_each_clone_is_leased_to_one_task
test_only_unstaged_switch_site_configs_count_as_clean
test_a_task_stays_in_its_workbench_for_a_second_repo
test_missing_and_unconfirmed_clones_are_refused
test_release_drops_only_that_tasks_leases
