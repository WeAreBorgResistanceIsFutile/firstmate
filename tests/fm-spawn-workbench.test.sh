#!/usr/bin/env bash
# tests/fm-spawn-workbench.test.sh - fm-spawn in workbench mode
# (config/workspace = workbench, bin/fm-workbench.sh, bin/fm-claude-trust.sh
# --workbench-clone).
#
# Drives the real spawn path against a fake terminal whose pane already sits in
# the leased clone. Each case proves the permanent clone comes out of a spawn
# exactly as it went in: same HEAD, same Switch-Site edits, and the clone's own
# .claude/settings.local.json byte-for-byte, with the task's hooks carried in a
# firstmate-owned file passed through --settings instead.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-workbench)
fm_git_identity fmtest fmtest@example.invalid

winpath() {  # <posix-path>
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# A home in workbench mode whose pool holds one confirmed workbench `wa` with a
# Nexon4-shaped clone: a Switch-Site config edited as every served clone is, and
# a settings.local.json of its own. Prints case_dir|home|clone|fakebin|launchlog.
make_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home clone fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  clone="$case_dir/wb/wa/Nexon4"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_test_spawn_brief "$home" "$id"
  printf 'workbench\n' > "$home/config/workspace"

  fm_git_init_commit "$clone" >/dev/null
  mkdir -p "$clone/Frontend/Source/Nexon.Web" "$clone/.claude"
  printf '<configuration />\n' > "$clone/Frontend/Source/Nexon.Web/Web.config"
  cat > "$clone/Switch-Site.ps1" <<'PS'
$plan = @(
    [PSCustomObject]@{ Path = "Frontend\Source\Nexon.Web\Web.config"; OriginKeys = @("FrontendUrl") }
)
PS
  printf '.claude/settings.local.json\n' > "$clone/.gitignore"
  git -C "$clone" add -A
  git -C "$clone" commit -qm fixture
  # An idle clone: its branch is origin's default and up to date with it.
  git -C "$clone" update-ref "refs/remotes/origin/$(git -C "$clone" symbolic-ref --short HEAD)" HEAD
  git -C "$clone" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$(git -C "$clone" symbolic-ref --short HEAD)"
  printf '<configuration site="wa" />\n' > "$clone/Frontend/Source/Nexon.Web/Web.config"
  printf '{"permissions":{"allow":["Bash(git status)"]},"autoMemoryDirectory":"C:\\\\Agents\\\\memory"}\n' \
    > "$clone/.claude/settings.local.json"

  printf '# id\troot\tclone\tsite\turl\tidentity\n' > "$home/state/workbenches"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' wa "$(winpath "$case_dir/wb/wa")" "$(winpath "$clone")" \
    site-wa http://wa.localhost - >> "$home/state/workbenches"
  printf 'wa\t%s\n' "$(winpath "$case_dir/wb/wa")" > "$home/data/workbenches-confirmed"
  printf '%s\n' "$case_dir|$home|$clone|$fakebin|$case_dir/launch.log"
}

# Whole-line match: assert_grep is fixed-string, so it cannot anchor.
assert_line() {  # <line> <file> <msg>
  grep -qxF -- "$1" "$2" || fail "$3"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR CLONE FAKEBIN LAUNCHLOG <<EOF
$1
EOF
}

# Leases go to the case's own folder, never the machine's real C:\Agents\locks.
run_spawn() {  # <args>...
  : > "$LAUNCHLOG"
  : > "$CASE_DIR/pane.log"
  FM_WORKBENCH_LEASE_DIR="$CASE_DIR/locks" FM_FAKE_LAUNCH_LOG="$LAUNCHLOG" FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" fm_test_run_spawn "$HOME_DIR" "$CLONE" "$FAKEBIN" "$@"
}

test_a_scout_launches_in_the_leased_clone_and_leaves_it_untouched() {
  local rec id out status head_before settings_before settings_file launch
  id=wb-scout
  rec=$(make_case scout claude "$id")
  read_case "$rec"
  head_before=$(git -C "$CLONE" rev-parse HEAD)
  settings_before=$(cat "$CLONE/.claude/settings.local.json")

  out=$(run_spawn "$id" Nexon4 --scout)
  status=$?
  expect_code 0 "$status" "a workbench-mode scout spawn should launch"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the spawn did not report success"

  # The lease records the clone as IIS would (a Windows path), so the record
  # holds its Git Bash form, which need not spell the same as the fixture's.
  local clone_as_leased=$CLONE
  command -v cygpath >/dev/null 2>&1 && clone_as_leased=$(cygpath -u "$(winpath "$CLONE")")
  assert_line "worktree=$clone_as_leased" "$HOME_DIR/state/$id.meta" \
    "the task record does not name the leased clone $clone_as_leased: $(grep '^worktree=' "$HOME_DIR/state/$id.meta")"
  assert_line 'workspace=workbench' "$HOME_DIR/state/$id.meta" "the task record does not mark workbench mode"
  assert_line 'workbench=wa' "$HOME_DIR/state/$id.meta" "the task record does not name its workbench"
  assert_line 'workbench_repo=Nexon4' "$HOME_DIR/state/$id.meta" "the task record does not name its repo"
  assert_line "task=$id" "$CASE_DIR/locks/wa-nexon4.lease" "the clone is not leased to the task"

  assert_equals "$(git -C "$CLONE" rev-parse HEAD)" "$head_before" "the spawn moved the clone's HEAD"
  assert_contains "$(git -C "$CLONE" status --porcelain)" "Frontend/Source/Nexon.Web/Web.config" \
    "the spawn discarded the clone's Switch-Site edit"
  assert_equals "$(cat "$CLONE/.claude/settings.local.json")" "$settings_before" \
    "the spawn changed the clone's own settings.local.json"

  settings_file="$HOME_DIR/state/$id.claude-settings.json"
  assert_present "$settings_file" "the task's hooks file was not written under state/"
  jq -e '.hooks.Stop and .hooks.UserPromptSubmit and .feedbackDrafts == "off" and .attribution.commit == ""' \
    "$settings_file" >/dev/null || fail "the hooks file lacks the hooks or the launch settings: $(cat "$settings_file")"

  launch=$(cat "$LAUNCHLOG")
  assert_contains "$launch" "--settings '" "the launch passes no --settings"
  assert_contains "$launch" "$id.claude-settings.json'" "the launch does not pass the task's hooks file"
  assert_not_contains "$launch" '{"feedbackDrafts"' "the inline settings JSON was not replaced by the file"
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      # An env wrapper would drop the agent out of the pane's native process
      # tree, so the pane shell unsets the variables instead.
      assert_not_contains "$launch" "env -u CURSOR_AGENT" "the Windows workbench launch still goes through env"
      assert_line "unset CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI" "$CASE_DIR/pane.log"         "the Windows workbench pane shell did not unset the harness markers before launch"
      ;;
    *) assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI" "the launch lost its env wrapper" ;;
  esac

  # Claude on Windows keys a project as C:/dir/sub; elsewhere the plain path.
  local trust_key
  trust_key=$(cd "$CLONE" && pwd -P)
  command -v cygpath >/dev/null 2>&1 && trust_key=$(cygpath -m "$trust_key")
  jq -e --arg k "$trust_key" '.projects[$k].hasTrustDialogAccepted == true' "$HOME_DIR/user-home/.claude.json" >/dev/null ||
    fail "trust was not pre-registered under the key $trust_key: $(jq -c '.projects | keys' "$HOME_DIR/user-home/.claude.json")"

  # Cleanup keeps the clone exactly as it is and releases the lease: no
  # detach, no branch deletion, no pool return, and the clone's own settings
  # file survives byte for byte.
  local status_before
  status_before=$(git -C "$CLONE" status --porcelain)
  finish_scout "$id"
  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "cleanup of a workbench scout should succeed"$'\n'"$out"
  assert_contains "$out" "workbench clone" "cleanup did not report the kept clone"
  assert_absent "$HOME_DIR/state/$id.meta" "cleanup left the task record"
  assert_absent "$CASE_DIR/locks/wa-nexon4.lease" "cleanup left the clone leased"
  assert_absent "$settings_file" "cleanup left the task's hooks file"
  assert_equals "$(git -C "$CLONE" rev-parse HEAD)" "$head_before" "cleanup moved the clone's HEAD"
  assert_equals "$(git -C "$CLONE" symbolic-ref --short HEAD)" "$(git -C "$CLONE" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')" \
    "cleanup took the clone off its idle branch"
  assert_equals "$(git -C "$CLONE" status --porcelain)" "$status_before" "cleanup changed the clone's working tree"
  assert_equals "$(cat "$CLONE/.claude/settings.local.json")" "$settings_before" \
    "cleanup changed the clone's own settings.local.json"
  pass 'a workbench scout launches in its leased clone, and cleanup releases it untouched'
}

# A scout's deliverable: its report and a completed captain-call inventory.
finish_scout() {  # <id>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# report\n' > "$HOME_DIR/data/$1/report.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$1" --none >/dev/null || fail "could not record the scout's captain-call inventory"
}

run_teardown() {  # <args>...
  FM_WORKBENCH_LEASE_DIR="$CASE_DIR/locks" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    TMUX="${TMUX:-fake,1,0}" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" "$@" 2>&1
}

test_cleanup_refuses_a_scout_that_changed_the_clone() {
  local rec id out status
  id=wb-changed
  rec=$(make_case changed claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" Nexon4 --scout)
  expect_code 0 $? "the workbench scout should launch"$'\n'"$out"
  finish_scout "$id"
  printf 'scout scribble\n' > "$CLONE/notes.txt"
  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup accepted a clone the scout changed"$'\n'"$out"
  assert_contains "$out" "left workbench clone" "the refusal does not name the changed clone"
  assert_contains "$out" "notes.txt" "the refusal does not show the change"
  assert_present "$HOME_DIR/state/$id.meta" "the refused cleanup removed the task record"
  assert_present "$CASE_DIR/locks/wa-nexon4.lease" "the refused cleanup released the lease"
  assert_equals "$(cat "$CLONE/notes.txt")" "scout scribble" "the refused cleanup touched the change"

  out=$(run_teardown "$id" --force)
  expect_code 0 $? "a forced cleanup should succeed"$'\n'"$out"
  assert_absent "$CASE_DIR/locks/wa-nexon4.lease" "the forced cleanup left the clone leased"
  assert_equals "$(cat "$CLONE/notes.txt")" "scout scribble" "the forced cleanup discarded the change"
  pass 'cleanup refuses a scout that changed its clone, and --force keeps the change'
}

test_a_non_claude_worker_is_refused_and_the_lease_released() {
  local rec id out status
  id=wb-codex
  rec=$(make_case codex codex "$id")
  read_case "$rec"
  out=$(run_spawn "$id" Nexon4 --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a codex worker was launched into a permanent clone"
  assert_contains "$out" "supports claude workers only" "the refusal does not name the reason"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn left a task record"
  assert_absent "$CASE_DIR/locks/wa-nexon4.lease" "a refused spawn left the clone leased"
  pass 'a non-claude worker is refused before it can touch the clone'
}

test_a_dirty_clone_is_not_leased() {
  local rec id out status
  id=wb-dirty
  rec=$(make_case dirty claude "$id")
  read_case "$rec"
  printf 'work in progress\n' > "$CLONE/README.md"
  out=$(run_spawn "$id" Nexon4 --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a clone with uncommitted work was leased"
  assert_contains "$out" "uncommitted changes" "the refusal does not name the dirt"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn left a task record"
  assert_equals "$(cat "$CLONE/README.md")" "work in progress" "the refused spawn touched the uncommitted work"
  pass 'a clone with uncommitted work is not leased'
}

test_a_path_project_argument_is_refused() {
  local rec id out status
  id=wb-path
  rec=$(make_case path claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$CLONE" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a path project argument was accepted in workbench mode"
  assert_contains "$out" "is a repo name" "the refusal does not explain the argument"
  assert_absent "$CASE_DIR/locks/wa-nexon4.lease" "a refused spawn leased the clone"
  pass 'workbench mode takes a repo name, not a path'
}

test_a_ship_and_an_unknown_workspace_are_refused() {
  local rec id out status
  id=wb-ship
  rec=$(make_case ship claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" Nexon4 --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship was launched onto the clone's idle branch"
  assert_contains "$out" "runs scouts only" "the ship refusal does not name the reason"
  assert_absent "$CASE_DIR/locks/wa-nexon4.lease" "a refused ship leased the clone"

  printf 'Workbench\n' > "$HOME_DIR/config/workspace"
  out=$(run_spawn "$id" Nexon4 --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown config/workspace value fell back to a Treehouse spawn"
  assert_contains "$out" "accepted values: treehouse, workbench" "the refusal does not name the accepted values"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn left a task record"
  pass 'a ship, and an unknown config/workspace value, are refused'
}

test_a_scout_launches_in_the_leased_clone_and_leaves_it_untouched
test_a_non_claude_worker_is_refused_and_the_lease_released
test_a_dirty_clone_is_not_leased
test_a_path_project_argument_is_refused
test_a_ship_and_an_unknown_workspace_are_refused

test_an_abort_after_the_lease_releases_it() {
  local rec id out status
  id=wb-abort
  rec=$(make_case abort claude "$id")
  read_case "$rec"
  # A relative CLAUDE_CONFIG_DIR makes the trust step refuse, after the lease.
  out=$(FM_TEST_CLAUDE_CONFIG_DIR=relative-store run_spawn "$id" Nexon4 --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "the spawn launched although the trust step refused"
  assert_contains "$out" "relative path" "the spawn did not fail at the trust step"$'\n'"$out"
  assert_absent "$HOME_DIR/state/$id.meta" "the aborted spawn left a task record"
  assert_absent "$CASE_DIR/locks/wa-nexon4.lease" "the aborted spawn left the clone leased"
  assert_absent "$HOME_DIR/state/$id.claude-settings.json" "the aborted spawn left its hooks file"
  pass 'a spawn that aborts after taking the lease releases it'
}

test_an_abort_after_the_lease_releases_it
test_cleanup_refuses_a_scout_that_changed_the_clone
