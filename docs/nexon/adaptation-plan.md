# Nexon adaptation plan

This fork adapts firstmate to one Windows 11 development machine that hosts four
long-lived Nexon4 workbenches. The goal: the captain talks to one first mate, and
the first mate hands Nexon4 tasks to whichever workbench is free, supervises the
worker there, and brings back Azure DevOps pull requests.

Status: **Phases 1–2 planned, not implemented.** Implemented so far: Windows task
panes in herdr run Git Bash and report their working directory
(`bin/backends/herdr.sh`, `bin/backends/herdr-win-bashrc.sh`). The branch-level
record of decisions, risks and open work is `HANDOFF.md` at the repo root.

## Target environment

| | upstream assumes | this machine |
|---|---|---|
| OS / shell | macOS, Linux, bash | Windows 11, PowerShell primary, Git Bash |
| session backend | tmux (default), herdr, zellij, cmux, orca | herdr 0.9.1 native Windows build |
| workspaces | a fresh `treehouse` worktree per task | four permanent workbench clones; **no worktree is ever created** |
| forge | GitHub via `gh` / `gh-axi` | on-prem Azure DevOps Server, Windows integrated auth |
| delivery gate | `no-mistakes` | Nexon `CLAUDE.md` review chain, `complete-pr` / `bubble` skills |

### Host setup (every Windows host)

- **Install the LF `jq` wrapper.** jq for Windows writes CRLF, and firstmate's
  scripts then read values with a stray CR (see the Phase 1 Windows status).
  Put this in `~/bin/jq`, which Git Bash's profile puts first on PATH, pointing
  at that host's real `jq.exe` (`where jq` in PowerShell), then `chmod +x` it:

  ```bash
  #!/usr/bin/env bash
  exec /c/Users/<user>/AppData/Local/Microsoft/WinGet/Links/jq.exe -b "$@"
  ```

  Check it with `printf '{"a":1,"b":2}' | jq -r '.a,.b' | od -c`: the output
  must contain no `\r`.
- **Make Node 22 the Volta default and wrap the shim.** The repo pins Node 22
  in `package.json`, but Volta falls back to its machine default outside the
  clone, and Node 20 cannot load the `.ts` modules that fixtures copy into Temp.
  Run `volta install node@22.22.3` (installed tools keep their own pinned
  Node). The Volta `node` shim also drops any argument that contains a newline,
  which breaks multi-line `node -e`, so put this in `~/bin/node` and `chmod +x`
  it:

  ```bash
  #!/usr/bin/env bash
  node_exe=$(volta which node) || exit 127
  exec "$node_exe" "$@"
  ```

  Check it with `node -e 'console.log(1)` + a newline + `console.log(2)'`: it
  must print both lines.
- **Check out real symlinks.** The clone tracks four symlinks
  (`.claude/skills`, `.agents/skills/firstmate-calm`, two `.pi` modules).
  With `core.symlinks=false` they arrive as text files, and Claude Code then
  loads none of the project skills. Symlink creation must work (Developer Mode
  or the create-symlink privilege), then run `git config core.symlinks true`
  in the clone and re-check out those four paths.
- **Install actionlint.** `fm-lint` runs the workflow lint, and
  `bin/fm-install-actionlint.sh` knows only Linux and macOS. Download the
  pinned version (`bin/fm-lint-workflows.sh --required-version`) as
  `actionlint_<v>_windows_amd64.zip` from the rhysd/actionlint release, check
  its SHA-256 against that release's `checksums.txt` (whose `linux_amd64` line
  must match the installer's pin), and put `actionlint.exe` in `~/bin`.
- **Install ShellCheck.** `fm-lint` and several suites need the pinned
  ShellCheck (`bin/fm-lint.sh --required-version`), and
  `bin/fm-install-shellcheck.sh` knows only Linux and macOS. Download
  `shellcheck-v<v>.zip` from the koalaman/shellcheck release, check its SHA-256
  against that release's asset digest (`gh api
  repos/koalaman/shellcheck/releases/tags/v<v>`, whose `linux.x86_64.tar.xz`
  digest must match the installer's pin), and put `shellcheck.exe` in `~/bin`.
- **Line endings need nothing per host.** `.gitattributes` forces LF on every
  tracked text file, so `core.autocrlf=true` no longer turns templates,
  helpers and test captures CRLF. A clone made before that rule landed must
  re-check out its CRLF files once (`git ls-files --eol | grep w/crlf`).

### The workbenches

A workbench is a root folder holding its own permanent clone of every repo it
works with (`<root>\Nexon4`, `<root>\Berszamfejtes`, …) plus, except for J, its
identity file `<root>\workbench.cmd`. The set is **not fixed**: the captain can
recruit more with the `recruit-agent` skill, so firstmate discovers workbenches
rather than hard-coding them. Today's four:

| id | Nexon4 clone | IIS site | URL | InstanceId | identity |
|---|---|---|---|---|---|
| J | `C:\git\Nexon4` | `Default Web Site` (`*:80:`) | `http://localhost` | 0 | shipped defaults, no `workbench.cmd` |
| K | `C:\AgentK\Nexon4` | `Nexon4-AgentK` (`*:8080:`) | `http://agentk.localhost` | 1 | `C:\AgentK\workbench.cmd` |
| O | `C:\AgentO\Nexon4` | `Nexon4-AgentO` (`*:8081:`) | `http://localhost:8081` | 2 | `C:\AgentO\workbench.cmd` |
| M | `C:\AgentM\Nexon4` | `Nexon4-AgentM` (`*:8082:`) | `http://localhost:8082` | 3 | `C:\AgentM\workbench.cmd` |

All share one SQL database (`.\Nexon4`, one `MigrationHistory`). Workbenches are
interchangeable: a task goes to any workbench whose clone of the task's repo is
free.

## Rules the design must keep

1. **No worktrees, no per-task clones.** A task runs in the leased workbench's
   own clone of its repo.
2. **Leases are per repo clone.** One task per `<workbench>\<repo>` at a time; K
   can run a Nexon4 task and a Bérszámfejtés task at once. A task that must also
   change a second repo (rare for Nexon4 work) leases that clone in the same
   workbench too.
3. **Firstmate keeps no project clones of its own.** Everything it needs to know
   about code comes from a worker (a scout for research) working in a workbench
   clone — the same branch a later worker would use.
4. **First clone of a repo into a workbench only on the captain's word.** A
   permanent workbench clone, not a per-task copy; later tasks reuse it.
5. **Switch-Site bracket.** Every branch switch, reset or checkout in a Nexon4
   clone is `Switch-Site.ps1 -Reset` → git operation → `Switch-Site.ps1`. Before
   a commit or push: `-Reset`, commit/push, `Switch-Site.ps1`. The 11 identity
   configs it rewrites are never committed.
6. **Never touch** `..\workbench.cmd` (identity source) or the clone's
   `.claude/settings.local.json` contents; never touch `Default Web Site`
   configuration.
7. **Idle state.** An idle workbench has its Nexon4 clone on `EHR` (Switch-Site
   applied) and its external-repo clones on `main`.
8. **Busy means dirty.** A clone with changes no firstmate task owns (today: K's
   and O's Nexon4 clones, the captain's own work) is busy and is never leased.
9. **Build with `Build.cmd` only.** `RegiBuild.cmd` is forbidden: it kills every
   `Nexon*` process and every `w3wp` on the machine.
10. **Shared database.** Never `Backend\UpdateDatabase.cmd`, a DB restore or a
   destructive seed without the captain's word.

## Machine-wide resources

| resource | rule | lock |
|---|---|---|
| Nexon4 app | one IIS site per clone, all run in parallel | none |
| Nexon4 build (`Build.cmd`) | its process kill is limited to its own clone (`Tools\Stop-CloneProcesses.ps1`) | none |
| external app run (Bérszámfejtés, EgBizt, MappingEngine) | same app once on the machine (port collision); different apps in parallel | `app:<name>` |
| external app build | each workbench builds in its own clone | none |
| Full Nexon4 build | shares the WebCompiler cache in `%TEMP%` | `webcompiler-first-build` |
| IntegrationEngine 8033, Licence 8001, ODataApi | single instance | `host:8033`, `host:8001`, `host:odata` |

Locks bind only agents firstmate manages.

## Phases

### Phase 1 — runtime foundation and one read-only task on one workbench

Goal: the first mate runs in a herdr pane on Windows, holds its session lock, and
can put a worker on workbench M, supervise it to completion and clean up —
without the worker changing anything.

1. **Session lock on Windows.** *(Done 2026-09-28, not yet merged.)* The lock
   failed with "cannot locate harness process in ancestry", leaving the first
   mate permanently read-only: Git Bash's `ps` has no `-o`, and the native
   `claude.exe` is not an MSYS process. `bin/fm-session-lock-lib.sh` now reads
   native Windows pids from `Win32_Process` (one Windows PowerShell query per
   question, starting from the outermost MSYS ancestor because MSYS fork/exec
   leaves exited stand-ins in the native chain). Acquiring then hung: every
   firstmate lock is a symlink, and MSYS's default `ln -s` copies instead;
   `bin/fm-wake-lib.sh` now exports `MSYS=winsymlinks:nativestrict`. Cost: each
   check takes about 1 s; the per-turn hooks that use this library pay it too.
2. **Bootstrap for this machine.** *(Done 2026-09-28.)* `config/workspace` =
   `workbench` (resolved by `bin/fm-workbench-lib.sh :: fm_workspace_mode`,
   documented in `docs/configuration.md` "Workspace mode") drops `treehouse` and
   `no-mistakes` from bootstrap's required tools; later steps use the same
   switch for spawn and cleanup.
3. **Upstream sync.** *(Done 2026-09-28: `upstream/main` merged at `de04757b`.)*
4. **Workbench discovery.** *(Done 2026-09-28, except the session-start
   refresh: `bin/fm-workbench.sh discover|list|confirm`,
   `tests/fm-workbench-discover.test.sh`; on this machine it finds `git` (J),
   `agentk`, `agento`, `agentm`.)* Workbenches come and go (`recruit-agent` can add a
   fifth), so there is no hand-kept list. `bin/fm-workbench.sh discover` builds
   the list from the same source `recruit-agent` uses — `applicationHost.config`
   → each Nexon4 application's `physicalPath` → its clone → the parent folder is
   the workbench root, `..\workbench.cmd` (if any) its identity; readable without
   elevation (`New-AgentWorkbench.ps1 -ShowOccupancy` does the same read). J is
   found through `Default Web Site`, never through a `workbench.cmd` scan. The
   result is cached in `state/workbenches` and refreshed at session start; a
   newly found workbench is reported to the captain and used only after the
   captain confirms it.
5. **Projects without clones.** The project registry records name, origin URL
   and a one-line description only; firstmate keeps no clone in `projects/`.
   Intake matches a request against that list; anything that needs reading code
   becomes a scout on a workbench. The worker start script takes its folder from
   the lease, not from `projects/`.
6. **Per-repo lease** *(Done 2026-09-28: `tests/fm-workbench-lease.test.sh`;
   the tolerated configs are read from each clone's own `Switch-Site.ps1`,
   12 today; a lease ends only by `release` — stale-lease detection is open.)*
   (`bin/fm-workbench.sh`): `lease <task> <repo> [<workbench>]`
   picks a workbench whose `<root>\<repo>` exists, has no live lease, is clean
   (beyond the Switch-Site configs for Nexon4) and sits on its idle branch
   (origin/HEAD, not ahead of it); writes `<id>-<repo>.lease` (task, home, time)
   under a lock in one machine-wide folder shared by every firstmate home
   *(2026-09-29, captain: shared folder, not primary-home-only; its location is
   a setup question recorded in `config/workbench-leases`, suggested
   `C:\Agents\locks\workbench`)*; a second repo for the same task leases the same
   workbench's clone; `release [--force] <task>` (refuses while the task is
   still recorded); `status`. The dirt probe runs `git --no-optional-locks`, so
   it never takes another agent's `index.lock`. If no workbench has a clone of `<repo>`, it stops and reports that
   (the captain decides where to clone it — Phase 2 step 1).
7. **Spawn in workbench mode** *(Done 2026-09-29, not live-tested:
   `tests/fm-spawn-workbench.test.sh`.)* (`bin/fm-spawn.sh`): the seam is the branch that
   types `treehouse get` and polls for an isolated worktree. Workbench mode
   replaces it with: lease → `cd` into the leased `<root>\<repo>` clone →
   assert the pane is in exactly that clone. It skips the Treehouse project lock, the pool-slot claim
   and `freshen_spawn_worktree_base` (which runs `git reset --hard`). The
   project argument is a repo name (`--workbench <id>` pins one); Claude trust
   is pre-registered through `fm-claude-trust.sh --workbench-clone`, whose
   scope proof is the task's lease; claude workers only, and scouts only until
   step 2 of Phase 2 creates the task branch (a ship would commit onto `EHR`).
   An unknown `config/workspace` value stops the spawn.
8. **Hooks without clobbering.** *(Decided 2026-09-29, captain: replaced by
   `--settings`, done with step 7.)* The busy/idle hooks, `feedbackDrafts` and
   attribution go into a firstmate-owned `state/<id>.claude-settings.json`
   passed with `claude --settings`; the clone's `.claude/settings.local.json` is
   never written, so there is nothing to back up or restore. Merging into that
   file was rejected: Claude reloads it, so any other session in the clone
   would fire the task's hooks. A relaunch retires the state file, never the
   clone's (`fm-control-lib.sh :: fm_control_harness_wiring_paths`). Live check
   still open: hooks passed with `--settings` fire alongside the clone's own.
9. **Cleanup in workbench mode** *(Done 2026-09-29, not live-tested:
   `tests/fm-spawn-workbench.test.sh`.)* (`bin/fm-teardown.sh`): no `checkout --detach`,
   no `branch -D`, no `treehouse return`, no `rm` of the clone's
   `.claude/settings.local.json`, and no process sweep by working directory
   (other agents work in the clone; only the task's temp root is swept); the
   lease is released once the endpoint is closed, and
   `state/<id>.claude-settings.json` removed. A scout that left the clone dirty
   or off its idle branch refuses cleanup; `--force` cleans up the task and
   leaves the clone as it is. Scouts only, as spawn.
10. **Form of address chosen by the user.** `AGENTS.md` hard-codes "captain" as
    the mandatory chat address. Replace that with the user's own choice: at
    setup (a session start whose `data/captain.md` has no form of address yet)
    the first mate asks how the user wants to be addressed — a name, a title,
    or none — and records the answer in `data/captain.md`; `AGENTS.md` then says
    "address the user the way `data/captain.md` records", with no title as the
    fallback. "Captain" stays as the internal role word in the docs.
11. **Permissions.** `config/claude-permission-mode` = `auto` (upstream defaults
    workers to `--dangerously-skip-permissions`).
12. **Smoke test.** *(Done 2026-09-29.)* A scout-style task on M ("summarise how X works"): no commit,
    no build. Record every Windows failure: agent liveness through herdr (only
    the root PowerShell is visible to `pane process-info`), `stat -c %a`, `ps
    -o`, `mkfifo` users (`bin/fm-pr-lib.sh`, `bin/fm-watch.sh`,
    `bin/fm-procevent.sh`).

**The 2026-09-29 review of steps 4–8** is fixed: `--no-optional-locks` dirt
probe; machine-wide leases whose folder is a setup question
(`config/workbench-leases`); the idle-branch rule; scouts only; `release`
refusing a recorded task; an unknown `config/workspace` stopping the spawn; no
duplicated workbench keys on relaunch; `fm-workbench.sh check` as the one proof
of a genuine lease, used by the trust step and the spawn's clone check; the
trust key converted with `cygpath -m`; the repo folder's on-disk spelling in
the lease; confirmations stored as id and root; discovery listing a
twice-served clone once and skipping an unusable root name; `lease --fresh`
closing the spawn's lease-leak windows. Still open: a workbench relaunch test.

**Windows (Git Bash) status, 2026-09-29.** Fixed in the product:
`fm_pr_file_mode_matches` (NTFS synthesizes POSIX modes, so the mode half of
the private-file checks is skipped there; type, device and link count still
apply); `fm_procevent_pgid` reads `/proc/<pid>/pgid` where `ps -o` is missing;
the process-event launch-confirm window defaults to 30 s on Git Bash (a runner
needs about 10 s to claim); herdr's pane walk uses Win32_Process; workbench
spawns send `unset` instead of the `env -u` wrapper that dropped claude out of
the pane's process tree. Fixed in the tests (`tests/lib.sh`): native symlinks
(`MSYS=winsymlinks:nativestrict`), `/mingw64/bin` in the minimal PATH,
`fm_test_mode_is`, `fm_test_ps`, `fm_test_isolated_path`, and a probe that
skips cases needing an unreadable file. Suites run clean on Git Bash:
`fm-backend-herdr`, `fm-spawn-workbench`, `fm-check-unregister`,
`fm-mail-check` (2 skips), `fm-procevent-when`, `fm-turnend-guard` (1 skip),
`fm-claude-stop-autoarm` (its
blocking arm fixture now waits for the superseding hook instead of a fixed 6 s,
which a slow host outlasted).

Fixed in the product, 2026-10-01: `fm-mail.sh` poll strips the CR Windows
Python prints, which had corrupted the mailbox generation and so every mail
wake key; `fm_lock_acquire_wait` returns failure once the lock's parent
directory is gone instead of retrying forever - a watcher whose state
directory was deleted mid-pass hung there for good (upstream has the same
race, but a Linux pass is too short to hit it).

Fixed in the product, 2026-10-02: Git for Windows' grep 3.0 strips a CR unless
given `-U` (`fm-ensure-agents-md.sh`'s CRLF probe) and aborts on every `-iF`
(`fm-dispatch-resolve.sh` folds case with `tr` instead); Git Bash collapses
`\\`+letter in an argument to a native program, so jq filters avoid backslash
escapes (`[[:space:]]` instead of `\\s`); `fm-pending-reply-lib.sh`'s sender
identity reads `/proc` where `ps -o` is missing, so a missed report's recovery
is sent at all; the Lavish board listener matches the session store's Windows
spelling of the board path. The inactive-outcome scan budget defaults to 45 s
(ceiling 90 s) on Git Bash, where one child's state read takes 8-33 s. Herdr
lab sessions (`fm-herdr-lab.sh`) run with a lab-only config whose
`terminal.default_shell` is Git Bash, plus an exported `PROMPT_COMMAND` for
herdr's OSC 9;9 cwd tracking; the backend's shell switch skips a pane that is
already Git Bash.

Scope: only this fork's Windows setup is supported - the herdr backend, the
claude, codex and pi harnesses, and local second mates - not everything
firstmate supports on Linux and macOS. Upstream files stay as close to upstream
as possible so the fork keeps merging cleanly. Run the suites with
`nexon/windows-tests.sh`. A suite for an unsupported feature (other backends,
other harnesses, remote second mates, the Ruby-parsed CI workflow check) is
listed in `nexon/windows-test-ignore.txt` with its reason, never edited or
skipped inside the upstream test file; a suite mixing supported and unsupported
cases stays in the run.

Known and not fixed:
- **Fork cost.** Each subshell costs about 40 ms, so everything is 10-50× slower
  than on Linux: the turn-end guard about 3 s, one watcher PR-poll validation
  cycle close to a minute, the herdr suite 26 minutes. Nothing breaks, but PR
  polling on Windows needs a fork-lean validation path before Phase 3 relies
  on it. Test time budgets are raised on Windows, not removed.
- **Session start is close to its bound.** On 2026-10-01 firstmate's own
  session start truncated at 120 s under test load and took 5 minutes on an
  idle machine (network checks alone 98 s, off the startup path). The
  turn-end guard's 15 s fresh-epoch and 800 ms sync wait may be too tight on
  Windows as well.
- **Ownership checks are vacuous.** Git Bash reports every file as owned by
  the current user, so `-O` checks (e.g. `fm-claude-trust`) always pass.
- **Path aliases defeat the lock.** A lock taken through
  `/c/Users/<u>/AppData/Local/Temp/...` writes a `/tmp/...` owner link, so
  its read-back fails and the acquire never succeeds; firstmate's own paths
  have no such alias, but a home under the temp directory would.
- **jq for Windows writes CRLF.** Git Bash drops only a trailing CR, so every
  line but the last of a multi-line `jq -r` result keeps one (a PR head commit
  then fails validation). About 60 `bin/` scripts read jq output; only the herdr
  backend wraps it in `jq -b`. Worked around per machine, not in the product: a
  `~/bin/jq` wrapper (first on Git Bash's PATH) that execs the real `jq.exe -b`.
  Each Windows host needs it (see Host setup).
- **Unreadable files cannot be made.** A Git Bash shell ignores `chmod 0000`
  and even an NTFS deny rule, so about 19 test files' "unreadable file" cases
  skip on this host. Likewise `chmod 0500` does not make a directory read-only,
  so `fm-procevent`'s three write-failure steps skip
  (`fm_test_readonly_dirs_supported`).
- **No herdr push wake.** `bin/backends/herdr-eventwait.py` reads herdr's
  `pane.agent_status_changed` stream over the session's Unix socket, and
  Windows CPython has no `socket.AF_UNIX`. The subscriber returns "event path
  unusable" and the watcher falls back to polling, so a worker blocked on the
  captain is noticed at the stale-pane timer (about 4 minutes), not
  sub-second. A reader in pwsh (.NET `UnixDomainSocketEndPoint`) would restore
  it; `fm-backend-herdr-eventwait-smoke` is ignored until then.
- **Other POSIX mode checks** outside `fm-pr-lib.sh` (`fm-bootstrap.sh`,
  `fm-fleet-snapshot.sh`, `fm-config-inherit-lib.sh`) still compare `stat -c %a`
  and will refuse on NTFS when their paths are reached.
- **Wrapper launches hide the agent.** The account-pin `env -u` shed and the
  `config/launch-env-allowlist` `env -i … /bin/sh -c` launch would drop claude
  out of the herdr pane tree the same way `env -u` did; neither is configured
  here.
- **OpenCode primary plugins** (`.opencode/plugins/`) spawn `bin/*.sh` directly,
  which Windows cannot execute (`EFTYPE`), and treat that spawn error as a pass,
  so on Windows the OpenCode turn-end guard silently never runs;
  `fm-primary-watch-arm.js` also calls `ps -o ppid=`. Off the Phase 2 path
  (Claude is the primary); the test case skips on Windows.
- **Isolated-PATH test cases** outside `fm-turnend-guard` (19 sites in 9 files)
  still pass only a fakebin PATH; they need `fm_test_isolated_path` when those
  suites are run.
- **Extension host** (`bin/fm-extension.mjs`) spawns `.sh` adapters directly
  (`EFTYPE` on Windows) and bounds a stalled adapter by POSIX process-group
  kill, which Windows lacks. Unused here, so its suite is ignored; a port needs
  bash-launched adapters and a `taskkill /T` tree kill.
- **`/calm` doorbell** verdicts read the record by its Git Bash `/tmp/...`
  path, which Node cannot open, so those lines would show raw. `/calm` is
  unused here and its suites are ignored.
- **Clone-refresh allowance** at session start is max(20, 5 + 3 × clones)
  seconds, tuned for Linux fetch speed. A timeout only skips the refresh.
  Measure it once Phase 2 clones are registered; `FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`
  overrides it.

**Exit criteria:** the lock holds; the task completes and is cleaned up; M's
clone, `workbench.cmd` and `settings.local.json` are byte-identical before and
after; every Windows failure is either fixed or listed. **Exit decision:** native
Git Bash + herdr, or move the first mate into WSL.

### Phase 2 — real tasks on every workbench

Goal: a worker takes a Nexon4 change from brief to a pushed branch with an open
Azure DevOps PR, on any free workbench, while the other workbenches keep working.

1. **First clone of a brand-new repo into a workbench** (`bin/fm-workbench.sh
   clone <workbench> <repo> <origin>`), always on the captain's word, then kept:
   how research on a repo no workbench has yet starts. The external repos Nexon4
   runs against (`EgBiztEllat`, `Berszamfejtes`, `MappingEngine`) are not cloned
   here: `recruit-agent` is their single owner (decided 2026-10-01, see
   *Follow-ups outside this repo*). Check each new app's own configuration for
   ports or URLs that assume one instance.
2. **Prepare the task branch** (`bin/fm-workbench.sh prepare <task> <base>`, run
   by spawn): refuse if the clone is dirty (beyond the 11 Switch-Site configs for
   Nexon4); for Nexon4 `Switch-Site.ps1 -Reset`, `git fetch`, create the task
   branch from `origin/<base>` (`EHR` or the release branch the brief names),
   `Switch-Site.ps1`; for other repos `git fetch` and branch from `origin/main`
   unless the brief names another base.
3. **Return to idle** (`bin/fm-workbench.sh restore <task>`, run by cleanup):
   only after the landed-work check passes or the PR is open and pushed;
   Nexon4: `-Reset`, `git switch EHR` and fast-forward, `Switch-Site.ps1`; other
   repos: `git switch main` and fast-forward; then release the lease. The task branch is kept. Anything it
   did not create is left alone; unexpected changes stop cleanup with a report.
4. **Machine-wide locks** (`bin/fm-lock-resource.sh`, new): `acquire|release|
   status <name>` for the names in *Machine-wide resources*; lock files under
   `C:\Agents\locks\` with holder task, workbench, PID and time; a lock whose
   holder is gone is reclaimable; `acquire` can wait with a timeout.
5. **Workbench worker instructions** (brief addendum): the workbench's URL,
   InstanceId and site; the Switch-Site bracket before every commit/push; take
   `app:<name>` before starting an external app and release it after;
   `Build.cmd` only, never `RegiBuild.cmd`; shared-DB rules; verify against
   *this* workbench's URL. PR creation by the worker through its own tools; merge
   only through `complete-pr` on the captain's word.
6. **Delivery.** The worker pushes and opens the Azure DevOps PR itself and
   reports its URL. Until Phase 3 firstmate cannot poll that PR, so ready-for-
   review is reported to the captain from the worker's report.
7. **Live tests:** one Nexon4 task on M; then two tasks at once in different
   workbenches, one running Bérszámfejtés while the other builds Nexon4
   (confirms the clone-scoped kill leaves the app alive); then a Nexon4 task and
   a Bérszámfejtés task at once in the **same** workbench; then all free clones.

**Exit criteria:** tasks finish on at least two workbenches at once; each
workbench is back on `EHR` with its identity intact; lock contention and a
crashed-holder recovery behave as specified.

### Phase 3 — Azure DevOps forge

- `fm_pr_url_parse` (`bin/fm-pr-lib.sh`): recognise
  `https://<host>/<collection>/<project>/_git/<repo>/pullrequest/<n>`.
- ADO read, poll and merge branches in `bin/fm-pr-*.sh` via the REST API with
  Windows integrated auth (`-UseDefaultCredentials`, as `complete-pr` does) — no
  token stored anywhere.
- `forge=ado` project binding and a bootstrap exemption from `gh` / `gh-axi`.
- Merge only on the captain's word, through `complete-pr`; `bubble` stays a
  separate, captain-initiated task.

### Phase 4 — instruction reconciliation

- A Nexon brief template replacing the `no-mistakes` / `gh-axi` steps with the
  Nexon `CLAUDE.md` step list, planning gates and review chain.
- How firstmate's `data/learnings.md` relates to the shared agent memory
  (`C:\Agents\memory\shared`).

## Upstream sync

The fork's `main` is the adapted line; upstream arrives by `git merge
upstream/main`. Firstmate treats its own checkout off the default branch as a
tangle, and `/updatefirstmate` fast-forwards only the default branch, so the
adaptation cannot live on a side branch. Keep patches to upstream files small and
behind the workbench mode, so upstream churn stays mergeable.

## Open decisions

- Native Git Bash vs WSL (decided by the Phase 1 smoke test).
- Two tasks in one workbench share its IIS site and database identity; if a
  Bérszámfejtés task needs to test against the workbench's Nexon4 site while a
  Nexon4 task there is mid-build, they collide. Expected to be rare; watch for it
  in the Phase 2 live tests before adding any rule.

## Follow-ups outside this repo

- The `recruit-agent` skill (`claude-skills`, plugin `nexon4-ops`) documents the
  external repos as shared, not cloned. Decided 2026-10-01: it becomes the
  single owner of each workbench's own `EgBiztEllat`, `Berszamfejtes` and
  `MappingEngine` clones, on by default (`-SkipExternalClones` opts out), and
  writes `NEXON_EGBIZTELLAT_ROOT` / `NEXON_BERSZAMFEJTES_ROOT` /
  `NEXON_MAPPINGENGINE_ROOT` into `workbench.cmd`. Nexon4 already reads them
  (`Tools\restart-dev-hosts.ps1`, `Tools\Workbench.cmd`), so only the skill
  changes:
  - `New-AgentWorkbench.ps1`: the three repos (Azure DevOps origins, branch
    `main`) cloned beside the product clone after the claude-skills clone,
    skipped when present, `core.longpaths`, no credential prompt; reachability
    probed up front with the Nexon4 probe; the three variables written by
    `Write-WorkbenchCmd`, kept from an existing claim on re-run, and checked
    through `cmd.exe` by `Assert-WorkbenchUsable`; the generated CLAUDE.md
    stops calling them shared.
  - `MANUAL.md`: the `workbench.cmd` template, the resolution check, and the
    "shared, not cloned" rule; `SKILL.md`: one overview line.
  - K, O and M are backfilled by re-running with `-SkipClone`, one workbench
    at a time and never mid-task (captain step).
  Own clones do not lift the port rule: each external app still runs once per
  machine under `app:<name>`; only Nexon4 itself (one IIS site per clone) runs
  in every workbench at once. A newly recruited workbench is picked up by
  Phase 1 step 4's discovery.
