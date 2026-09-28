#!/usr/bin/env bash
# fm-workbench.sh - the fixed-workbench pool a workbench-mode home leases from.
#
# Workbenches come and go (recruit-agent can add one), so there is no hand-kept
# list. `discover` builds the pool from IIS's applicationHost.config through
# bin/fm-workbench-lib.sh and caches it in state/workbenches. A workbench the
# captain has not confirmed is reported as `new` and must not be used until
# `confirm <id>` records the captain's word in data/workbenches-confirmed.
#
# Usage:
#   fm-workbench.sh discover        refresh state/workbenches from IIS, print the pool
#   fm-workbench.sh list            print the cached pool without reading IIS
#   fm-workbench.sh confirm <id>    record the captain's confirmation of one workbench
#   fm-workbench.sh lease <task> <repo> [<workbench>]
#                                   lease a free, clean <root>\<repo> clone to <task>
#   fm-workbench.sh release <task>  drop every lease <task> holds
#   fm-workbench.sh status          print every lease: workbench repo task time clone
#
# Pool rows: id<TAB>status<TAB>root<TAB>clone<TAB>site<TAB>url<TAB>identity,
# status is `confirmed` or `new`. A trailing `new:` line names every
# unconfirmed id. FM_IIS_APPHOST_CONFIG overrides the IIS file (tests).
#
# Leases are per repo clone: state/workbench-<id>-<repo>.lease records task,
# workbench, repo, clone and time. `lease` considers only confirmed workbenches
# whose <root>\<repo> is a git clone with no lease and no uncommitted change
# beyond an unstaged edit of a config the clone's own Switch-Site.ps1 rewrites
# (bin/fm-workbench-lib.sh :: fm_workbench_clone_dirt). A task that already holds
# a lease works in that workbench, so its next repo is leased there or not at
# all; leasing a repo the task already holds prints the existing lease. On
# success it prints `leased: <id> <repo> <clone>`. Exit 3: no workbench has a
# clone of <repo> (the captain decides where to clone it); exit 4: every clone
# is leased, dirty, or unconfirmed, each reason listed. A lease is removed only
# by `release`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CACHE="$STATE/workbenches"
CONFIRMED="$DATA/workbenches-confirmed"
APPHOST="${FM_IIS_APPHOST_CONFIG:-${WINDIR:-/c/Windows}/System32/inetsrv/config/applicationHost.config}"

# shellcheck source=bin/fm-workbench-lib.sh
. "$SCRIPT_DIR/fm-workbench-lib.sh"

usage() {
  sed -n 's/^# \{0,1\}//; 10,17p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

is_confirmed() {  # <id>
  [ -f "$CONFIRMED" ] && grep -qxF "$1" "$CONFIRMED"
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
  printf '%s\n' "$id" >> "$CONFIRMED"
  echo "confirmed: $id"
}

LEASE_LOCK="$STATE/.workbench-lease.lock"

# Serialize every lease-file mutation. A holder that died leaves its pid behind,
# and a lock whose recorded holder is gone is taken over.
lease_lock() {
  local i holder
  mkdir -p "$STATE"
  for i in $(seq 1 100); do
    if mkdir "$LEASE_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$LEASE_LOCK/pid"
      trap 'rm -rf "$LEASE_LOCK"' EXIT
      return 0
    fi
    holder=$(cat "$LEASE_LOCK/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$LEASE_LOCK"
      continue
    fi
    sleep 0.1
  done
  echo "error: the workbench lease lock $LEASE_LOCK is held by pid ${holder:-unknown}" >&2
  return 1
}

lease_file() {  # <workbench-id> <repo>
  printf '%s/workbench-%s-%s.lease\n' "$STATE" "$1" "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
}

lease_field() {  # <lease-file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

valid_name() {  # <value>
  case "$1" in '' | *[!A-Za-z0-9._-]* | .*) return 1 ;; esac
}

# Print every lease file this home holds, one path per line.
lease_files() {
  local f
  for f in "$STATE"/workbench-*.lease; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

cmd_lease() {  # <task> <repo> [<workbench>]
  local task=$1 repo=$2 want=${3:-} f held_wb= id root clone site url identity posix dirt
  local found_clone=0 reasons=
  valid_name "$task" || { echo "error: invalid task id '$task'" >&2; return 2; }
  valid_name "$repo" || { echo "error: invalid repo name '$repo'" >&2; return 2; }
  [ -f "$CACHE" ] || { echo "error: no cached pool at $CACHE; run: fm-workbench.sh discover" >&2; return 1; }
  lease_lock || return 1
  # A task works in one workbench: a second repo leases that workbench's clone.
  while IFS= read -r f; do
    [ "$(lease_field "$f" task)" = "$task" ] || continue
    held_wb=$(lease_field "$f" workbench)
    if [ "$(lease_field "$f" repo | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
      printf 'leased: %s %s %s\n' "$held_wb" "$repo" "$(lease_field "$f" clone)"
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
    clone="$root\\$repo"
    posix=$(_fm_workbench_posix_path "$clone")
    [ -e "$posix/.git" ] || continue
    found_clone=1
    if ! is_confirmed "$id"; then
      reasons="$reasons"$'\n'"  $id: not confirmed by the captain"
      continue
    fi
    f=$(lease_file "$id" "$repo")
    if [ -f "$f" ]; then
      reasons="$reasons"$'\n'"  $id: leased by task $(lease_field "$f" task)"
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
    printf 'task=%s\nworkbench=%s\nrepo=%s\nclone=%s\nleased_at=%s\n' \
      "$task" "$id" "$repo" "$clone" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$f.tmp.$$"
    mv -f "$f.tmp.$$" "$f"
    printf 'leased: %s %s %s\n' "$id" "$repo" "$clone"
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

cmd_release() {  # <task>
  local task=$1 f released=0
  valid_name "$task" || { echo "error: invalid task id '$task'" >&2; return 2; }
  lease_lock || return 1
  while IFS= read -r f; do
    [ "$(lease_field "$f" task)" = "$task" ] || continue
    printf 'released: %s %s\n' "$(lease_field "$f" workbench)" "$(lease_field "$f" repo)"
    rm -f "$f"
    released=1
  done < <(lease_files)
  [ "$released" = 1 ] || echo "no lease held by task $task"
}

cmd_status() {
  local f any=0
  while IFS= read -r f; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$(lease_field "$f" workbench)" "$(lease_field "$f" repo)" \
      "$(lease_field "$f" task)" "$(lease_field "$f" leased_at)" "$(lease_field "$f" clone)"
    any=1
  done < <(lease_files)
  [ "$any" = 1 ] || echo "no workbench leases"
}

case "${1:-}" in
  discover) [ $# -eq 1 ] || usage; cmd_discover ;;
  list) [ $# -eq 1 ] || usage; print_pool ;;
  confirm) [ $# -eq 2 ] || usage; cmd_confirm "$2" ;;
  lease) [ $# -eq 3 ] || [ $# -eq 4 ] || usage; cmd_lease "$2" "$3" "${4:-}" ;;
  release) [ $# -eq 2 ] || usage; cmd_release "$2" ;;
  status) [ $# -eq 1 ] || usage; cmd_status ;;
  *) usage ;;
esac
