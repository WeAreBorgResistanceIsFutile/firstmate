#!/usr/bin/env bash
# Workspace-mode resolution for fixed-workbench fleets.
#
# The optional local, gitignored config/workspace selects where ship and scout
# workers do their work. docs/configuration.md "Workspace mode" owns the
# accepted values and what each one changes.
#
#   treehouse (also the absent-file default)  a fresh Treehouse worktree per task
#   workbench                                  a leased clone in a fixed workbench;
#                                              treehouse and no-mistakes are not used
#
# This file is sourced by scripts and has no side effects on source.

# Print the resolved workspace mode for config dir $1, or print a diagnostic to
# stderr and return 1 for a value that is neither accepted token.
fm_workspace_mode() {  # <config-dir>
  local file=$1/workspace token
  if [ ! -e "$file" ]; then
    printf '%s\n' treehouse
    return 0
  fi
  if ! token=$(tr -d '[:space:]' < "$file" 2>/dev/null); then
    echo "error: $file is unreadable; accepted values: treehouse, workbench" >&2
    return 1
  fi
  case "$token" in
    treehouse | workbench)
      printf '%s\n' "$token"
      ;;
    *)
      echo "error: $file holds '$token'; accepted values: treehouse, workbench" >&2
      return 1
      ;;
  esac
}

# --- lease folder ------------------------------------------------------------
#
# Every firstmate home on the machine leases the same physical clones, so the
# leases live in one folder they all share. Where that folder is, is a setup
# question for the captain: config/workbench-leases holds the answer (a Windows
# or Git Bash path), and the same folder must be named in every home.
# FM_WORKBENCH_LEASE_DIR overrides it (tests).

FM_WORKBENCH_LEASE_DIR_SUGGESTED='C:\Agents\locks\workbench'

# Print the lease folder as a Git Bash path for config dir $1, or print a
# diagnostic to stderr and return 1 when the captain has not chosen one yet.
fm_workbench_lease_dir() {  # <config-dir>
  local file=$1/workbench-leases dir
  if [ -n "${FM_WORKBENCH_LEASE_DIR:-}" ]; then
    printf '%s\n' "$FM_WORKBENCH_LEASE_DIR"
    return 0
  fi
  dir=
  [ ! -f "$file" ] || dir=$(tr -d '\r' < "$file" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}')
  if [ -z "$dir" ]; then
    echo "error: $file is not set; ask the captain which folder every firstmate home on this machine shares for workbench leases (suggested: $FM_WORKBENCH_LEASE_DIR_SUGGESTED), then write that path there" >&2
    return 1
  fi
  _fm_workbench_posix_path "$dir"
}

# --- workbench discovery -----------------------------------------------------
#
# Workbenches are not a hand-kept list: recruit-agent can add one at any time.
# The one source that cannot drift is IIS's own applicationHost.config, the same
# file New-AgentWorkbench.ps1 -ShowOccupancy reads without elevation: every
# site -> application -> virtual directory -> physicalPath. A Nexon4 clone is a
# physicalPath ending in \Frontend\Source\Nexon.Web; the clone's parent folder
# is the workbench root, and <root>\workbench.cmd (when present) its identity.
# The default instance has no workbench.cmd by design and is found through its
# site like every other, never through a workbench.cmd scan.

FM_WORKBENCH_WEB_SUFFIX='\Frontend\Source\Nexon.Web'

# Print a path Git Bash can test, from a Windows path IIS recorded.
_fm_workbench_posix_path() {  # <windows-path>
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Print one row per virtual directory in applicationHost.config $1:
#   site<TAB>physicalPath<TAB>protocol/bindingInformation[ ...]
# Returns 1 with a diagnostic when the file cannot be read or parsed.
fm_workbench_iis_rows() {  # <applicationHost.config>
  local config=$1 winpath script
  if [ ! -r "$config" ]; then
    echo "error: cannot read IIS configuration $config" >&2
    return 1
  fi
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "error: powershell.exe is required to read $config" >&2
    return 1
  fi
  winpath=$config
  command -v cygpath >/dev/null 2>&1 && winpath=$(cygpath -w "$config")
  # ChildNodes and LocalName rather than property access: PowerShell's XML
  # adapter surfaces attributes as properties, and a site added without
  # /physicalPath has no <application> child at all.
  # read -d '' rather than $(cat <<...): bash scans a heredoc inside a command
  # substitution for its quotes, and this PowerShell carries a literal `t.
  local rows
  IFS= read -r -d '' script <<'PS' || true
$ErrorActionPreference = 'Stop'
function Kids($n, $name) { if ($null -eq $n) { return }
  foreach ($c in $n.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $name) { $c } } }
$x = [xml](Get-Content -LiteralPath $env:FM_WB_APPHOST -Raw -Encoding UTF8)
foreach ($s in (Kids $x.configuration.'system.applicationHost'.sites 'site')) {
  $b = @(foreach ($bs in (Kids $s 'bindings')) { foreach ($bn in (Kids $bs 'binding')) {
    $bn.GetAttribute('protocol') + '/' + $bn.GetAttribute('bindingInformation') } }) -join ' '
  foreach ($a in (Kids $s 'application')) { foreach ($v in (Kids $a 'virtualDirectory')) {
    $p = $v.GetAttribute('physicalPath')
    if ($p) { [Console]::Out.Write($s.GetAttribute('name') + "`t" + $p + "`t" + $b + "`n") } } } }
PS
  if ! rows=$(FM_WB_APPHOST=$winpath powershell.exe -NoProfile -NonInteractive -Command "$script" 2>/dev/null); then
    echo "error: cannot parse IIS configuration $config" >&2
    return 1
  fi
  printf '%s\n' "$rows" | tr -d '\r' | sed '/^$/d'
}

# Print the site URL one IIS binding list describes: the first http binding,
# with an empty host meaning localhost and port 80 left implicit.
_fm_workbench_binding_url() {  # <protocol/bindingInformation ...>
  local binding info port host
  for binding in $1; do
    case "$binding" in http/*) ;; *) continue ;; esac
    info=${binding#http/}
    port=${info#*:}; port=${port%%:*}
    host=${info##*:}
    [ -n "$host" ] || host=localhost
    if [ "$port" = 80 ]; then
      printf 'http://%s\n' "$host"
    else
      printf 'http://%s:%s\n' "$host" "$port"
    fi
    return 0
  done
  return 1
}

# Print the value of `set "NAME=value"` in workbench.cmd $1, the same line shape
# Build.cmd and Switch-Site.ps1 parse.
_fm_workbench_cmd_value() {  # <workbench.cmd> <name>
  local pattern
  pattern='s/^[[:space:]]*@\{0,1\}set[[:space:]]\{1,\}"\{0,1\}NAME=\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p'
  tr -d '\r' < "$1" | sed -n "${pattern/NAME/$2}" | tail -n 1
}

# Read fm_workbench_iis_rows output on stdin and print one row per workbench:
#   id<TAB>root<TAB>clone<TAB>site<TAB>url<TAB>identity
# id is the root folder's lowercased name, identity is `workbench.cmd` or `-`.
# An application whose folder is not a git clone is skipped with a warning, a
# root a second site also serves is listed once, a root whose name is not a
# plain id is skipped with a warning, and two roots with the same name are
# refused, because the id names lease files.
fm_workbench_from_iis_rows() {
  local site physical bindings lower suffix clone root id url identity posix_clone out ids roots
  suffix=$(printf '%s' "$FM_WORKBENCH_WEB_SUFFIX" | tr '[:upper:]' '[:lower:]')
  out=
  ids=' '
  roots=$'\n'
  while IFS=$'\t' read -r site physical bindings; do
    [ -n "$physical" ] || continue
    physical=${physical%\\}
    lower=$(printf '%s' "$physical" | tr '[:upper:]' '[:lower:]')
    case "$lower" in *"$suffix") ;; *) continue ;; esac
    clone=${physical:0:$((${#physical} - ${#FM_WORKBENCH_WEB_SUFFIX}))}
    root=${clone%\\*}
    # IIS records the drive letter in either case; the root is one folder.
    case "$root" in [a-z]:*) root=$(printf '%s' "${root:0:1}" | tr '[:lower:]' '[:upper:]')${root:1} ;; esac
    case "$clone" in [a-z]:*) clone=$(printf '%s' "${clone:0:1}" | tr '[:lower:]' '[:upper:]')${clone:1} ;; esac
    posix_clone=$(_fm_workbench_posix_path "$clone")
    if [ ! -e "$posix_clone/.git" ]; then
      echo "warning: site '$site' serves $clone, which is not a git clone; skipped" >&2
      continue
    fi
    # Two sites can serve one clone; it is still one workbench.
    lower=$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')
    case "$roots" in *$'\n'"$lower"$'\n'*) continue ;; esac
    roots="$roots$lower"$'\n'
    id=$(printf '%s' "${root##*\\}" | tr '[:upper:]' '[:lower:]')
    # The id names lease files and travels in space-separated output.
    case "$id" in
      '' | *[!a-z0-9._-]* | .*)
        echo "warning: workbench root $root has no usable id ('$id': letters, digits, '.', '_', '-' only); skipped" >&2
        continue
        ;;
    esac
    case "$ids" in
      *" $id "*)
        echo "error: two workbench roots are both named '$id' (second: $root); workbench ids must be unique" >&2
        return 1
        ;;
    esac
    ids="$ids$id "
    identity=-
    url=
    if [ -f "$(_fm_workbench_posix_path "$root")/workbench.cmd" ]; then
      identity=workbench.cmd
      url=$(_fm_workbench_cmd_value "$(_fm_workbench_posix_path "$root")/workbench.cmd" NEXON4_URL)
    fi
    [ -n "$url" ] || url=$(_fm_workbench_binding_url "$bindings") || url=-
    out+="$id"$'\t'"$root"$'\t'"$clone"$'\t'"$site"$'\t'"$url"$'\t'"$identity"$'\n'
  done
  printf '%s' "$out"
}

# --- lease cleanliness ---------------------------------------------------------
#
# A workbench clone is leased only when it is clean, with one exception: a
# Nexon4 clone carries the configs Switch-Site.ps1 rewrites from workbench.cmd,
# which are modified in every served clone by design. The clone's own
# Switch-Site.ps1 is the single list of them, so a change to that list needs no
# change here. Only an unstaged modification of one of them is tolerated; a
# staged one could be committed and is dirt like any other.

# Print the repo-relative paths (forward slashes) Switch-Site.ps1 in clone $1
# rewrites, or nothing when the clone has no Switch-Site.ps1.
fm_workbench_switch_site_paths() {  # <posix-clone>
  local script=$1/Switch-Site.ps1
  [ -f "$script" ] || return 0
  tr -d '\r' < "$script" \
    | sed -n 's/^[[:space:]]*\[PSCustomObject\]@{[[:space:]]*Path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    | tr '\\' /
}

# Print one line per path that makes clone $1 unleasable, as `XY path`; print
# nothing for a clean clone. Returns 1 when git cannot read the clone.
fm_workbench_clone_dirt() {  # <posix-clone>
  local clone=$1 tolerated status entry xy path skip=0
  tolerated=$(fm_workbench_switch_site_paths "$clone")
  # -z so a path with spaces arrives unquoted; the NULs become newlines inside
  # the pipeline because a command substitution drops NUL bytes.
  # --no-optional-locks: the probe runs on clones other agents are working in,
  # and a plain status takes .git/index.lock to refresh the index.
  status=$(set -o pipefail; git --no-optional-locks -C "$clone" status --porcelain -z 2>/dev/null | tr '\0' '\n') || return 1
  while IFS= read -r entry; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    [ -n "$entry" ] || continue
    xy=${entry:0:2}
    path=${entry:3}
    case "$xy" in R* | C*) skip=1 ;; esac
    if [ "$xy" = ' M' ] && [ -n "$tolerated" ] && printf '%s\n' "$tolerated" | grep -qxF "$path"; then
      continue
    fi
    printf '%s %s\n' "$xy" "$path"
  done <<EOF2
$status
EOF2
}

# --- idle branch ---------------------------------------------------------------
#
# An idle clone sits on its origin's default branch (origin/HEAD: EHR for Nexon4,
# main elsewhere) with no commit origin lacks. A clone left on a task branch, or
# on the captain's own work, is not free even when its tree is clean.

# Print why clone $1 is not on its idle branch, or nothing when it is. Returns 1
# when git cannot read the clone.
fm_workbench_clone_off_idle() {  # <posix-clone>
  local clone=$1 idle current ahead
  idle=$(git --no-optional-locks -C "$clone" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || {
    printf '%s\n' "origin/HEAD is not set, so its idle branch is unknown (git remote set-head origin -a)"
    return 0
  }
  current=$(git --no-optional-locks -C "$clone" symbolic-ref -q --short HEAD 2>/dev/null) || current=
  if [ "$current" != "${idle#origin/}" ]; then
    printf 'on %s, not its idle branch %s\n' "${current:-a detached HEAD}" "${idle#origin/}"
    return 0
  fi
  ahead=$(git --no-optional-locks -C "$clone" rev-list --count "$idle..HEAD" 2>/dev/null) || return 1
  [ "$ahead" = 0 ] || printf '%s is %s commit(s) ahead of %s\n' "$current" "$ahead" "$idle"
}
