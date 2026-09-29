#!/usr/bin/env bash
# tests/fm-workbench-lease.test.sh - per-repo workbench leases
# (bin/fm-workbench.sh lease|release|status, bin/fm-workbench-lib.sh ::
# fm_workbench_clone_dirt, fm_workbench_clone_off_idle).
#
# Each case builds its own pool: workbench roots holding real git clones on
# their idle branch, a state/workbenches cache as discover would write it, and
# the captain's confirmations. Leases go to the case's own locks/ folder, never
# the machine's real C:\Agents\locks. No case reads IIS.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workbench-lease)
fm_git_identity fmtest fmtest@example.invalid
CMD="$ROOT/bin/fm-workbench.sh"

winpath() {  # <posix-path>
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# Make clone $1's current branch its origin's default and up to date with it,
# the state of an idle workbench clone, without a real remote.
make_idle() {  # <clone>
  local clone=$1 branch
  branch=$(git -C "$clone" symbolic-ref --short HEAD)
  git -C "$clone" update-ref "refs/remotes/origin/$branch" HEAD
  git -C "$clone" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$branch"
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
  make_idle "$clone"
}

make_plain_clone() {  # <clone>
  fm_git_init_commit "$1" >/dev/null
  make_idle "$1"
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
    case " ${UNCONFIRMED:-} " in *" $id "*) ;; *) printf '%s\t%s\n' "$id" "$(winpath "$dir/wb/$id")" >> "$dir/data/workbenches-confirmed" ;; esac
  done
}

# Run the command as the home at $1. The lease folder is the home's own unless
# LEASES names one several homes share.
run_in() {  # <dir> <args>...
  local dir=$1
  shift
  FM_WORKBENCH_LEASE_DIR="${LEASES:-$dir/locks}" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$CMD" "$@"
}

test_each_clone_is_leased_to_one_task() {
  local dir out rc=0
  dir="$TMP_ROOT/one-task-each"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  out=$(run_in "$dir" lease t1 Nexon4) || fail "the first lease failed"
  assert_contains "$out" "leased: wa Nexon4" "the first free clone is leased"
  assert_present "$dir/locks/wa-nexon4.lease" "the lease is recorded per repo clone"
  assert_contains "$(cat "$dir/locks/wa-nexon4.lease")" "home=$(cd "$dir/state" && pwd -P)" "the lease names its home"
  out=$(run_in "$dir" lease t1 nexon4) || fail "a repeat lease failed"
  assert_contains "$out" "leased: wa" "a repeat lease prints the existing lease"
  out=$(run_in "$dir" lease t2 nexon4) || fail "the second task found no clone"
  assert_contains "$out" "leased: wb Nexon4 " "a second task gets the other workbench, under the folder's own spelling"
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
  make_plain_clone "$dir/wb/wb/Payroll"
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
  assert_absent "$dir/locks/.lease.lock" "no lease lock is left behind"
  pass 'a missing repo, an unconfirmed workbench, and a bad task id are refused'
}

test_release_drops_only_that_tasks_leases() {
  local dir out
  dir="$TMP_ROOT/release"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  make_plain_clone "$dir/wb/wa/Payroll"
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

test_a_clone_off_its_idle_branch_is_not_leased() {
  local dir clone out rc
  dir="$TMP_ROOT/idle-branch"
  make_home "$dir" wa
  clone="$dir/wb/wa/Nexon4"
  make_nexon_clone "$clone"

  git -C "$clone" switch -qc feature/x
  rc=0; out=$(run_in "$dir" lease t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "a clone on a task branch is not free"
  assert_contains "$out" "on feature/x, not its idle branch" "the refusal names the branch"
  git -C "$clone" switch -q -

  git -C "$clone" commit -q --allow-empty -m local
  rc=0; out=$(run_in "$dir" lease t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "a clone with an unpushed commit is not free"
  assert_contains "$out" "1 commit(s) ahead of origin/" "the refusal names the unpushed commit"
  make_idle "$clone"

  git -C "$clone" symbolic-ref --delete refs/remotes/origin/HEAD
  rc=0; out=$(run_in "$dir" lease t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "a clone whose idle branch is unknown is not free"
  assert_contains "$out" "origin/HEAD is not set" "the refusal names the missing origin/HEAD"
  make_idle "$clone"

  run_in "$dir" lease t1 Nexon4 >/dev/null || fail "the idle clone was not leasable"
  pass 'a clone off its idle branch, ahead of it, or without one is not leased'
}

test_leases_are_shared_by_every_home() {
  local shared out rc=0
  shared="$TMP_ROOT/shared-locks"
  make_home "$TMP_ROOT/home-a" wa
  make_nexon_clone "$TMP_ROOT/home-a/wb/wa/Nexon4"
  make_home "$TMP_ROOT/home-b" wa
  rm -rf "$TMP_ROOT/home-b/wb"
  cp "$TMP_ROOT/home-a/state/workbenches" "$TMP_ROOT/home-b/state/workbenches"
  cp "$TMP_ROOT/home-a/data/workbenches-confirmed" "$TMP_ROOT/home-b/data/workbenches-confirmed"
  LEASES=$shared run_in "$TMP_ROOT/home-a" lease t1 Nexon4 >/dev/null || fail "the first home could not lease"
  out=$(LEASES=$shared run_in "$TMP_ROOT/home-b" lease t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 4 "a second home leased a clone the first home holds"
  assert_contains "$out" "leased by task t1 of the home at" "the refusal names the other home"
  out=$(LEASES=$shared run_in "$TMP_ROOT/home-b" release t1)
  assert_contains "$out" "no lease held by task t1" "a same-named task of another home released the lease"
  out=$(LEASES=$shared run_in "$TMP_ROOT/home-a" status)
  assert_contains "$out" "wa"$'\t'"Nexon4"$'\t'"t1" "the first home's lease did not survive"
  pass 'every home leases from one machine-wide folder, and a task is named by its home'
}

test_release_refuses_a_recorded_task() {
  local dir out rc=0
  dir="$TMP_ROOT/release-recorded"
  make_home "$dir" wa
  make_nexon_clone "$dir/wb/wa/Nexon4"
  run_in "$dir" lease t1 Nexon4 >/dev/null
  printf 'kind=scout\n' > "$dir/state/t1.meta"
  out=$(run_in "$dir" release t1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a recorded task's lease was released"
  assert_contains "$out" "release --force t1" "the refusal does not name the forced release"
  assert_present "$dir/locks/wa-nexon4.lease" "the refused release dropped the lease"
  out=$(run_in "$dir" release --force t1) || fail "a forced release failed"
  assert_contains "$out" "released: wa Nexon4" "the forced release did not drop the lease"
  pass 'release refuses while the task is recorded, and --force overrides it'
}

test_the_lease_folder_is_the_captains_setup_answer() {
  local dir out rc=0
  dir="$TMP_ROOT/setup-answer"
  make_home "$dir" wa
  make_nexon_clone "$dir/wb/wa/Nexon4"
  mkdir -p "$dir/config"
  out=$(FM_WORKBENCH_LEASE_DIR='' FM_CONFIG_OVERRIDE="$dir/config" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" "$CMD" lease t1 Nexon4 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a lease was taken with no lease folder chosen"
  assert_contains "$out" "ask the captain which folder" "the refusal does not ask the setup question"
  printf '%s\r\n' "$(winpath "$dir/chosen")" > "$dir/config/workbench-leases"
  FM_WORKBENCH_LEASE_DIR='' FM_CONFIG_OVERRIDE="$dir/config" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" "$CMD" lease t1 Nexon4 >/dev/null || fail "the chosen lease folder was not used"
  assert_present "$dir/chosen/wa-nexon4.lease" "the lease is not in the chosen folder"
  pass 'the lease folder is the captain'"'"'s setup answer, recorded in config/workbench-leases'
}

test_each_clone_is_leased_to_one_task
test_only_unstaged_switch_site_configs_count_as_clean
test_a_task_stays_in_its_workbench_for_a_second_repo
test_missing_and_unconfirmed_clones_are_refused
test_release_drops_only_that_tasks_leases
test_a_clone_off_its_idle_branch_is_not_leased
test_leases_are_shared_by_every_home
test_release_refuses_a_recorded_task

test_the_lease_folder_is_the_captains_setup_answer

test_check_proves_only_a_genuine_lease() {
  local dir lease out rc
  dir="$TMP_ROOT/check"
  make_home "$dir" wa
  make_nexon_clone "$dir/wb/wa/Nexon4"
  run_in "$dir" lease t1 Nexon4 >/dev/null
  lease="$dir/locks/wa-nexon4.lease"
  out=$(run_in "$dir" check t1 "$lease") || fail "a genuine lease failed the check"
  assert_equals "$out" "$(winpath "$dir/wb/wa")\Nexon4" "the check prints the leased clone"

  rc=0; out=$(run_in "$dir" check t2 "$lease" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "another task's lease passed the check"
  assert_contains "$out" "not task 't2'" "the wrong-task refusal names the task"

  mkdir -p "$dir/elsewhere"
  cp "$lease" "$dir/elsewhere/wa-nexon4.lease"
  rc=0; out=$(run_in "$dir" check t1 "$dir/elsewhere/wa-nexon4.lease" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a copy outside the lease folder passed the check"
  assert_contains "$out" "not in the workbench lease folder" "the outside-folder refusal is named"

  sed 's#^clone=.*#clone=C:\Other\Nexon4#' "$lease" > "$dir/locks/wa-payroll.lease"
  rc=0; run_in "$dir" check t1 "$dir/locks/wa-payroll.lease" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a lease file not named for its repo passed the check"
  rm -f "$dir/locks/wa-payroll.lease"

  sed -i 's#^clone=.*#clone=C:\Other\Nexon4#' "$lease"
  rc=0; out=$(run_in "$dir" check t1 "$lease" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a lease on a clone outside the pool passed the check"
  assert_contains "$out" "which is not workbench wa's Nexon4 clone" "the off-pool refusal is named"
  pass 'check accepts only a lease of this task of this home, in the lease folder, on a pool clone'
}

test_a_fresh_lease_refuses_an_earlier_spawns_lease() {
  local dir out rc=0
  dir="$TMP_ROOT/fresh"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  run_in "$dir" lease t1 Nexon4 >/dev/null
  out=$(run_in "$dir" lease --fresh t1 Nexon4 2>&1) || rc=$?
  assert_equals "$rc" 5 "a fresh lease adopted an earlier lease of the same task"
  assert_contains "$out" "release --force t1" "the refusal does not say how to clear it"
  assert_present "$dir/locks/wa-nexon4.lease" "the refusal dropped the earlier lease"
  out=$(run_in "$dir" lease --fresh t2 Nexon4) || fail "a fresh lease of a new task failed"
  assert_contains "$out" "leased: wb Nexon4" "a fresh lease of a new task takes a free clone"
  pass 'a fresh lease refuses, and keeps, a lease an earlier spawn of the task left'
}

test_concurrent_leases_get_different_clones() {
  local dir a b
  dir="$TMP_ROOT/concurrent"
  make_home "$dir" wa wb
  make_nexon_clone "$dir/wb/wa/Nexon4"
  make_nexon_clone "$dir/wb/wb/Nexon4"
  run_in "$dir" lease t1 Nexon4 > "$dir/t1.out" 2>&1 &
  a=$!
  run_in "$dir" lease t2 Nexon4 > "$dir/t2.out" 2>&1 &
  b=$!
  wait "$a" || fail "a concurrent lease failed: $(cat "$dir/t1.out")"
  wait "$b" || fail "a concurrent lease failed: $(cat "$dir/t2.out")"
  [ "$(sed -n 's/^leased: \([^ ]*\) .*/\1/p' "$dir/t1.out")" != "$(sed -n 's/^leased: \([^ ]*\) .*/\1/p' "$dir/t2.out")" ] ||
    fail "two concurrent leases got the same clone"
  assert_absent "$dir/locks/.lease.lock" "the lease lock was left behind"
  pass 'two concurrent leases serialize on the lock and get different clones'
}

test_check_proves_only_a_genuine_lease
test_a_fresh_lease_refuses_an_earlier_spawns_lease
test_concurrent_leases_get_different_clones
