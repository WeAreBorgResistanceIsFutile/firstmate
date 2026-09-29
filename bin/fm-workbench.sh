#!/usr/bin/env bash
# fm-workbench.sh - the fixed-workbench pool a workbench-mode home leases from.
#
# Workbenches come and go (recruit-agent can add one), so there is no hand-kept
# list. `discover` builds the pool from IIS's applicationHost.config through
# bin/fm-workbench-lib.sh and caches it in state/workbenches. A workbench the
# captain has not confirmed is reported as `new` and must not be used until
# `confirm <id>` records the captain's word in data/workbenches-confirmed as
# id<TAB>root; a workbench whose root has changed since is `new` again.
#
# Usage:
#   fm-workbench.sh discover        refresh state/workbenches from IIS, print the pool
#   fm-workbench.sh list            print the cached pool without reading IIS
#   fm-workbench.sh confirm <id>    record the captain's confirmation of one workbench
#   fm-workbench.sh lease [--fresh] <task> <repo> [<workbench>]
#                                   lease a free, clean <root>\<repo> clone to <task>;
#                                   --fresh (a new task) refuses, exit 5, if it holds any
#   fm-workbench.sh release [--force] <task>
#                                   drop every lease <task> holds
#   fm-workbench.sh status          print every lease: workbench repo task time clone home
#   fm-workbench.sh path <workbench> <repo>
#                                   print the lease file of one repo clone
#   fm-workbench.sh check <task> <lease-file>
#                                   prove the file is a lease of <task> of this home
#                                   on a confirmed pool clone, and print that clone
#
# Pool rows: id<TAB>status<TAB>root<TAB>clone<TAB>site<TAB>url<TAB>identity,
# status is `confirmed` or `new`. A trailing `new:` line names every
# unconfirmed id. FM_IIS_APPHOST_CONFIG overrides the IIS file (tests).
#
# Leases are per repo clone and machine-wide: every firstmate home on this
# machine leases the same physical clones, so the lease files and their lock live
# in one shared folder. Which folder is a setup question for the captain, whose
# answer config/workbench-leases records (bin/fm-workbench-lib.sh ::
# fm_workbench_lease_dir); until then lease, release, status and path refuse.
# <dir>/<id>-<repo>.lease records task, the leasing home's state directory,
# workbench, repo, clone and time; a task is named by its home and its id,
# because task ids are unique only within one home. `lease` considers only
# confirmed workbenches whose <root>\<repo> is a git clone with no lease, on its
# idle branch (bin/fm-workbench-lib.sh :: fm_workbench_clone_off_idle), and with
# no uncommitted change beyond an unstaged edit of a config the clone's own
# Switch-Site.ps1 rewrites (fm_workbench_clone_dirt). A task that already holds
# a lease works in that workbench, so its next repo is leased there or not at
# all; leasing a repo the task already holds prints the existing lease. On
# success it prints `leased: <id> <repo> <clone>`. Exit 3: no workbench has a
# clone of <repo> (the captain decides where to clone it); exit 4: every clone
# is leased, dirty, off its idle branch, or unconfirmed, each reason listed. A
# lease is removed only by `release`, which refuses while the task's record
# (state/<task>.meta) still exists: a recorded task may have a live worker in the
# clone. --force releases anyway, once the worker is known to be stopped.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CACHE="$STATE/workbenches"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIRMED="$DATA/workbenches-confirmed"
APPHOST="${FM_IIS_APPHOST_CONFIG:-${WINDIR:-/c/Windows}/System32/inetsrv/config/applicationHost.config}"

# shellcheck source=bin/fm-workbench-lib.sh
. "$SCRIPT_DIR/fm-workbench-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n 's/^# \{0,1\}//; 11,25p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

# The root the cached pool records for workbench $1, or nothing.
pool_root() {  # <id>
  [ -f "$CACHE" ] && awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "$CACHE"
}

# A confirmation is the id and the root the captain confirmed together, so a
# different folder that later takes the same name is new again.
is_confirmed() {  # <id>
  local root
  root=$(pool_root "$1")
  [ -n "$root" ] && [ -f "$CONFIRMED" ] && grep -qxF "$1"$'\t'"$root" "$CONFIRMED"
}

print_pool() {
  local id rest new=
  [ -f "$CACHE" ] || { echo "error: no cached pool at $CACHE; run: fm-workbench.sh discover" >&2; return 1; }
  while IFS=$'\t' read -r id rest; do
    case "$id" in '#'* | '') continue ;; esac
    if is_confirmed "$id"; then
      printf '%s\tconfirmed\t%s\n' "$id" "$rest"
    else
      printf '%s\tnew\t%s\n' "$id" "$rest"
      new="$new $id"
    fi
  done < "$CACHE"
  [ -z "$new" ] || printf 'new:%s (confirm each with the captain, then: fm-workbench.sh confirm <id>)\n' "$new"
}

cmd_discover() {
  local rows pool tmp
  rows=$(fm_workbench_iis_rows "$APPHOST") || return 1
  pool=$(printf '%s\n' "$rows" | fm_workbench_from_iis_rows) || return 1
  if [ -z "$pool" ]; then
    echo "error: $APPHOST serves no Nexon4 clone; no workbench found" >&2
    return 1
  fi
  mkdir -p "$STATE"
  tmp="$CACHE.tmp.$$"
  {
    printf '# id\troot\tclone\tsite\turl\tidentity\n'
    printf '%s\n' "$pool"
  } > "$tmp"
  mv -f "$tmp" "$CACHE"
  print_pool
}

cmd_confirm() {  # <id>
  local id=$1
  [ -f "$CACHE" ] || { echo "error: no cached pool at $CACHE; run: fm-workbench.sh discover" >&2; return 1; }
  if ! cut -f1 "$CACHE" | grep -qxF "$id"; then
    echo "error: '$id' is not a discovered workbench; run: fm-workbench.sh discover" >&2
    return 1
  fi
  if is_confirmed "$id"; then
    echo "already confirmed: $id"
    return 0
  fi
  mkdir -p "$DATA"
  printf '%s\t%s\n' "$id" "$(pool_root "$id")" >> "$CONFIRMED"
  echo "confirmed: $id"
}

LEASE_DIR=
LEASE_LOCK=

# Resolve the shared lease folder, or refuse with the setup question.
need_lease_dir() {
  LEASE_DIR=$(fm_workbench_lease_dir "$CONFIG") || exit 1
  LEASE_LOCK="$LEASE_DIR/.lease.lock"
}

# The leasing home, as the resolved path of its state directory.
HOME_STATE=
LEASE_WAIT_SECONDS="${FM_WORKBENCH_LEASE_WAIT:-120}"

# Serialize every lease-file mutation across all homes. The lock is
# bin/fm-wake-lib.sh's portable lock, whose stale-holder recovery is race-safe;
# the wait is long because a lease runs git status on several large clones.
lease_lock() {
  mkdir -p "$STATE" "$LEASE_DIR" || { echo "error: cannot create the workbench lease folder $LEASE_DIR" >&2; return 1; }
  HOME_STATE=$(cd "$STATE" && pwd -P)
  if ! fm_lock_acquire_wait_max "$LEASE_LOCK" "$LEASE_WAIT_SECONDS"; then
    echo "error: the workbench lease lock $LEASE_LOCK is still held by pid ${FM_LOCK_HELD_PID:-unknown} after ${LEASE_WAIT_SECONDS}s" >&2
    return 1
  fi
  trap 'fm_lock_release "$LEASE_LOCK"' EXIT
}

lease_file() {  # <workbench-id> <repo>
  printf '%s/%s-%s.lease\n' "$LEASE_DIR" "$1" "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
}

lease_field() {  # <lease-file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

valid_name() {  # <value>
  case "$1" in '' | *[!A-Za-z0-9._-]* | .*) return 1 ;; esac
}

# Print the entry of directory $1 whose name matches $2 ignoring case, or $2.
on_disk_name() {  # <posix-dir> <name>
  local entry want
  want=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  for entry in "$1"/*; do
    [ -d "$entry" ] || continue
    if [ "$(printf '%s' "${entry##*/}" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
      printf '%s\n' "${entry##*/}"
      return 0
    fi
  done
  printf '%s\n' "$2"
}

# 0 iff lease file $1 belongs to task $2 of this home.
lease_is_ours() {  # <lease-file> <task>
  [ "$(lease_field "$1" task)" = "$2" ] && [ "$(lease_field "$1" home)" = "$HOME_STATE" ]
}

# Print every lease file on this machine, one path per line.
lease_files() {
  local f
  for f in "$LEASE_DIR"/*.lease; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

cmd_lease() {  # <fresh:0|1> <task> <repo> [<workbench>]
  local fresh=$1 task=$2 repo=$3 want=${4:-} f held_wb= id root clone site url identity posix dirt off holder name
  local found_clone=0 reasons=
  valid_name "$task" || { echo "error: invalid task id '$task'" >&2; return 2; }
  valid_name "$repo" || { echo "error: invalid repo name '$repo'" >&2; return 2; }
  [ -f "$CACHE" ] || { echo "error: no cached pool at $CACHE; run: fm-workbench.sh discover" >&2; return 1; }
  lease_lock || return 1
  # A task works in one workbench: a second repo leases that workbench's clone.
  while IFS= read -r f; do
    lease_is_ours "$f" "$task" || continue
    held_wb=$(lease_field "$f" workbench)
    if [ "$fresh" = 1 ]; then
      echo "error: task $task already holds a lease on workbench $held_wb's $(lease_field "$f" repo) clone from an earlier spawn; a new task starts with none, so release it once no worker uses the clone: fm-workbench.sh release --force $task" >&2
      return 5
    fi
    if [ "$(lease_field "$f" repo | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
      printf 'leased: %s %s %s\n' "$held_wb" "$(lease_field "$f" repo)" "$(lease_field "$f" clone)"
      return 0
    fi
  done < <(lease_files)
  if [ -n "$held_wb" ] && [ -n "$want" ] && [ "$want" != "$held_wb" ]; then
    echo "error: task $task already works in workbench $held_wb, not $want" >&2
    return 1
  fi
  [ -z "$held_wb" ] || want=$held_wb
  if [ -n "$want" ] && ! cut -f1 "$CACHE" | grep -qxF "$want"; then
    echo "error: '$want' is not a discovered workbench" >&2
    return 1
  fi
  while IFS=$'\t' read -r id root clone site url identity; do
    case "$id" in '#'* | '') continue ;; esac
    [ -z "$want" ] || [ "$id" = "$want" ] || continue
    # The folder's own spelling, not the caller's: Windows matches either,
    # but a trust key or project key written from `nexon4` would not.
    name=$(on_disk_name "$(_fm_workbench_posix_path "$root")" "$repo")
    clone="$root\\$name"
    posix=$(_fm_workbench_posix_path "$clone")
    [ -e "$posix/.git" ] || continue
    found_clone=1
    if ! is_confirmed "$id"; then
      reasons="$reasons"$'\n'"  $id: not confirmed by the captain"
      continue
    fi
    f=$(lease_file "$id" "$repo")
    if [ -f "$f" ]; then
      holder="task $(lease_field "$f" task)"
      [ "$(lease_field "$f" home)" = "$HOME_STATE" ] || holder="$holder of the home at $(lease_field "$f" home)"
      reasons="$reasons"$'\n'"  $id: leased by $holder"
      continue
    fi
    if ! dirt=$(fm_workbench_clone_dirt "$posix"); then
      reasons="$reasons"$'\n'"  $id: git cannot read $clone"
      continue
    fi
    if [ -n "$dirt" ]; then
      reasons="$reasons"$'\n'"  $id: $clone has uncommitted changes ($(printf '%s\n' "$dirt" | wc -l | tr -d ' ') paths, first: $(printf '%s\n' "$dirt" | head -n 1))"
      continue
    fi
    if ! off=$(fm_workbench_clone_off_idle "$posix"); then
      reasons="$reasons"$'\n'"  $id: git cannot read $clone"
      continue
    fi
    if [ -n "$off" ]; then
      reasons="$reasons"$'\n'"  $id: $clone is $off"
      continue
    fi
    printf 'task=%s\nhome=%s\nworkbench=%s\nrepo=%s\nclone=%s\nleased_at=%s\n' \
      "$task" "$HOME_STATE" "$id" "$name" "$clone" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$f.tmp.$$"
    mv -f "$f.tmp.$$" "$f"
    printf 'leased: %s %s %s\n' "$id" "$name" "$clone"
    return 0
  done < "$CACHE"
  if [ "$found_clone" = 0 ] && [ -z "$reasons" ]; then
    if [ -n "$want" ]; then
      echo "error: workbench $want has no clone of $repo; the captain decides where to clone it" >&2
    else
      echo "error: no discovered workbench has a clone of $repo; the captain decides where to clone it" >&2
    fi
    return 3
  fi
  echo "error: no workbench clone of $repo is free:$reasons" >&2
  return 4
}

cmd_release() {  # <task> [--force]
  local task=$1 force=${2:-} f released=0
  valid_name "$task" || { echo "error: invalid task id '$task'" >&2; return 2; }
  if [ -z "$force" ] && { [ -e "$STATE/$task.meta" ] || [ -L "$STATE/$task.meta" ]; }; then
    echo "error: task $task is still recorded ($STATE/$task.meta), so its worker may be running in the clone; stop the worker first, then: fm-workbench.sh release --force $task" >&2
    return 1
  fi
  lease_lock || return 1
  while IFS= read -r f; do
    lease_is_ours "$f" "$task" || continue
    printf 'released: %s %s\n' "$(lease_field "$f" workbench)" "$(lease_field "$f" repo)"
    rm -f "$f"
    released=1
  done < <(lease_files)
  [ "$released" = 1 ] || echo "no lease held by task $task"
}

# Prove lease file $2 is a real lease of task $1 of this home: a regular file in
# the lease folder, named for its workbench and repo, whose workbench is a
# confirmed pool row and whose clone is that row's <root>\<repo>. Prints the
# clone. Read-only, so it takes no lock.
cmd_check() {  # <task> <lease-file>
  local task=$1 file=$2 id repo root dir
  valid_name "$task" || { echo "error: invalid task id '$task'" >&2; return 2; }
  HOME_STATE=$(cd "$STATE" 2>/dev/null && pwd -P) || { echo "error: no state directory $STATE" >&2; return 1; }
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "error: '$file' is not a regular lease file" >&2
    return 1
  fi
  dir=$(cd "$(dirname "$file")" && pwd -P)
  if [ "$dir" != "$(cd "$LEASE_DIR" 2>/dev/null && pwd -P)" ]; then
    echo "error: '$file' is not in the workbench lease folder $LEASE_DIR" >&2
    return 1
  fi
  if ! lease_is_ours "$file" "$task"; then
    echo "error: '$file' names task '$(lease_field "$file" task)' of the home at '$(lease_field "$file" home)', not task '$task' of $HOME_STATE" >&2
    return 1
  fi
  id=$(lease_field "$file" workbench)
  repo=$(lease_field "$file" repo)
  if ! valid_name "$id" || ! valid_name "$repo" || [ "${file##*/}" != "$(basename "$(lease_file "$id" "$repo")")" ]; then
    echo "error: '$file' is not named for its workbench '$id' and repo '$repo'" >&2
    return 1
  fi
  if ! is_confirmed "$id"; then
    echo "error: workbench '$id' of '$file' is not confirmed by the captain" >&2
    return 1
  fi
  root=$(pool_root "$id")
  if [ -z "$root" ] || [ "$(lease_field "$file" clone)" != "$root\\$repo" ]; then
    echo "error: '$file' leases clone '$(lease_field "$file" clone)', which is not workbench $id's $repo clone" >&2
    return 1
  fi
  printf '%s\n' "$root\\$repo"
}

cmd_status() {
  local f any=0
  while IFS= read -r f; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(lease_field "$f" workbench)" "$(lease_field "$f" repo)" \
      "$(lease_field "$f" task)" "$(lease_field "$f" leased_at)" "$(lease_field "$f" clone)" "$(lease_field "$f" home)"
    any=1
  done < <(lease_files)
  [ "$any" = 1 ] || echo "no workbench leases"
}

case "${1:-}" in
  discover) [ $# -eq 1 ] || usage; cmd_discover ;;
  list) [ $# -eq 1 ] || usage; print_pool ;;
  confirm) [ $# -eq 2 ] || usage; cmd_confirm "$2" ;;
  lease | release | status | path | check) need_lease_dir ;;
  *) usage ;;
esac
case "${1:-}" in
  discover | list | confirm) ;;
  lease)
    if [ "${2:-}" = --fresh ]; then
      [ $# -eq 4 ] || [ $# -eq 5 ] || usage
      cmd_lease 1 "$3" "$4" "${5:-}"
    else
      [ $# -eq 3 ] || [ $# -eq 4 ] || usage
      cmd_lease 0 "$2" "$3" "${4:-}"
    fi
    ;;
  release)
    if [ $# -eq 3 ] && [ "$2" = --force ]; then
      cmd_release "$3" --force
    else
      [ $# -eq 2 ] || usage
      cmd_release "$2"
    fi
    ;;
  status) [ $# -eq 1 ] || usage; cmd_status ;;
  path) [ $# -eq 3 ] && valid_name "$2" && valid_name "$3" || usage; lease_file "$2" "$3" ;;
  check) [ $# -eq 3 ] || usage; cmd_check "$2" "$3" ;;
  *) usage ;;
esac
