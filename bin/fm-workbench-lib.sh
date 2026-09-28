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
# An application whose folder is not a git clone is skipped with a warning; two
# roots with the same name are refused, because the id names lease files.
fm_workbench_from_iis_rows() {
  local site physical bindings lower suffix clone root id url identity posix_clone out ids
  suffix=$(printf '%s' "$FM_WORKBENCH_WEB_SUFFIX" | tr '[:upper:]' '[:lower:]')
  out=
  ids=' '
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
    id=$(printf '%s' "${root##*\\}" | tr '[:upper:]' '[:lower:]')
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
