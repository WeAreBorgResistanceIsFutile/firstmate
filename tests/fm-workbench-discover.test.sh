#!/usr/bin/env bash
# tests/fm-workbench-discover.test.sh - workbench discovery from IIS
# (bin/fm-workbench-lib.sh, bin/fm-workbench.sh discover|list|confirm).
#
# The pure layer (IIS rows -> workbench rows) runs on every host. The IIS read
# needs powershell.exe, so the cases that parse a fixture applicationHost.config
# are skipped where it is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workbench-discover)
LIB="$ROOT/bin/fm-workbench-lib.sh"
CMD="$ROOT/bin/fm-workbench.sh"

# The Windows form of a fixture path, as IIS would record it.
winpath() {  # <posix-path>
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1" | tr / '\\'; fi
}

# A workbench root with a Nexon4 clone; $2 = 1 also writes a workbench.cmd.
make_workbench() {  # <root> <with-workbench-cmd> [url]
  mkdir -p "$1/Nexon4/.git" "$1/Nexon4/Frontend/Source/Nexon.Web"
  if [ "$2" = 1 ]; then
    printf '@echo off\r\nset "NEXON_IIS_SITE=x"\r\nset "NEXON4_URL=%s"\r\n' "$3" > "$1/workbench.cmd"
  fi
}

from_rows() {
  bash -c '. "$0"; fm_workbench_from_iis_rows' "$LIB"
}

test_rows_become_one_workbench_per_clone() {
  local dir out
  dir="$TMP_ROOT/pure"
  make_workbench "$dir/Default" 0
  make_workbench "$dir/AgentK" 1 http://agentk.localhost
  mkdir -p "$dir/app/Instance0/ApplicationServer"
  out=$(printf '%s\t%s\t%s\n' \
    'Default Web Site' "$(winpath "$dir/Default/Nexon4/Frontend/Source/Nexon.Web")" 'http/*:80:' \
    'Default Web Site' "$(winpath "$dir/Default/Nexon4/Frontend/Source/Nexon.Web.Windows")" 'http/*:80:' \
    'Instance0' "$(winpath "$dir/app/Instance0/ApplicationServer")" 'http/*:81:' \
    'Nexon4-AgentK' "$(winpath "$dir/AgentK/Nexon4/Frontend/Source/Nexon.Web")\\" 'http/*:8080: http/*:80:agentk.localhost' \
    | from_rows) || fail "discovery refused a valid row set"
  assert_equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2 "two clones give two workbenches"
  assert_contains "$out" "default"$'\t'"$(winpath "$dir/Default")" "the default instance is found through its site, with no workbench.cmd"
  assert_contains "$out" 'Default Web Site'$'\t''http://localhost'$'\t''-' "a workbench without workbench.cmd takes its URL from the binding"
  assert_contains "$out" 'Nexon4-AgentK'$'\t''http://agentk.localhost'$'\t''workbench.cmd' "workbench.cmd's NEXON4_URL wins over the binding"
  assert_not_contains "$out" Instance0 "an installed product is not a workbench"
  pass 'IIS rows become one workbench per Nexon4 clone'
}

test_a_served_folder_that_is_not_a_clone_is_skipped() {
  local dir out err
  dir="$TMP_ROOT/not-a-clone"
  mkdir -p "$dir/Gone/Nexon4/Frontend/Source/Nexon.Web"
  out=$(printf '%s\t%s\t%s\n' 'Nexon4-Gone' "$(winpath "$dir/Gone/Nexon4/Frontend/Source/Nexon.Web")" 'http/*:8090:' \
    | from_rows 2>"$dir.err")
  err=$(cat "$dir.err")
  assert_equals "$out" "" "a folder without .git yields no workbench"
  assert_contains "$err" "not a git clone" "the skip is reported"
  pass 'a served folder that is not a git clone is skipped with a warning'
}

test_two_roots_with_the_same_name_are_refused() {
  local dir rc=0
  dir="$TMP_ROOT/dup"
  make_workbench "$dir/a/AgentX" 0
  make_workbench "$dir/b/agentx" 0
  printf '%s\t%s\t%s\n' \
    'S1' "$(winpath "$dir/a/AgentX/Nexon4/Frontend/Source/Nexon.Web")" 'http/*:8091:' \
    'S2' "$(winpath "$dir/b/agentx/Nexon4/Frontend/Source/Nexon.Web")" 'http/*:8092:' \
    | from_rows >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "two roots named agentx were accepted; their lease files would collide"
  pass 'two workbench roots with the same name are refused'
}

test_discover_caches_and_confirm_is_durable() {
  local dir config out rc=0
  if ! command -v powershell.exe >/dev/null 2>&1; then
    pass 'discover/confirm skipped: powershell.exe is not available on this host'
    return 0
  fi
  dir="$TMP_ROOT/cmd"
  make_workbench "$dir/Default" 0
  make_workbench "$dir/AgentM" 1 http://agentm.localhost
  config="$dir/applicationHost.config"
  cat > "$config" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.applicationHost>
    <sites>
      <site name="Default Web Site" id="1">
        <application path="/"><virtualDirectory path="/" physicalPath="$(winpath "$dir/Default/Nexon4/Frontend/Source/Nexon.Web")" /></application>
        <bindings><binding protocol="http" bindingInformation="*:80:" /></bindings>
      </site>
      <site name="NoApp" id="2"><bindings><binding protocol="http" bindingInformation="*:99:" /></bindings></site>
      <site name="Nexon4-AgentM" id="3">
        <application path="/"><virtualDirectory path="/" physicalPath="$(winpath "$dir/AgentM/Nexon4/Frontend/Source/Nexon.Web")" /></application>
        <bindings><binding protocol="http" bindingInformation="*:8082:" /></bindings>
      </site>
    </sites>
  </system.applicationHost>
</configuration>
XML
  run() { FM_IIS_APPHOST_CONFIG="$config" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$CMD" "$@"; }

  out=$(run discover) || fail "discover failed on a valid IIS file"
  assert_present "$dir/state/workbenches" "discover caches the pool"
  assert_contains "$out" "default"$'\t'"new" "an unconfirmed workbench is reported as new"
  assert_contains "$out" "new: default agentm" "every unconfirmed id is named"

  run confirm nosuch >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "confirm accepted an id discovery never found"

  run confirm agentm >/dev/null || fail "confirm refused a discovered id"
  out=$(run list)
  assert_contains "$out" "agentm"$'\t'"confirmed" "a confirmed workbench stays confirmed from the cache"
  assert_contains "$out" "new: default" "the other workbench is still new"

  out=$(run discover)
  assert_contains "$out" "agentm"$'\t'"confirmed" "confirmation survives a re-discovery"
  pass 'discover caches the pool and confirm records the captain word durably'
}

test_rows_become_one_workbench_per_clone
test_a_served_folder_that_is_not_a_clone_is_skipped
test_two_roots_with_the_same_name_are_refused
test_discover_caches_and_confirm_is_durable
