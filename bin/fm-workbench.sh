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
#
# Output rows: id<TAB>status<TAB>root<TAB>clone<TAB>site<TAB>url<TAB>identity,
# status is `confirmed` or `new`. A trailing `new:` line names every
# unconfirmed id. FM_IIS_APPHOST_CONFIG overrides the IIS file (tests).
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
  sed -n 's/^# \{0,1\}//; 10,13p' "${BASH_SOURCE[0]}" >&2
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

case "${1:-}" in
  discover) [ $# -eq 1 ] || usage; cmd_discover ;;
  list) [ $# -eq 1 ] || usage; print_pool ;;
  confirm) [ $# -eq 2 ] || usage; cmd_confirm "$2" ;;
  *) usage ;;
esac
