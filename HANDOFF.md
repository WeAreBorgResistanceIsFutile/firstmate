# HANDOFF — Nexon adaptation of firstmate

## 0. Handoff metadata

| | |
|---|---|
| Repository | `C:\git\firstmate`, fork `https://github.com/WeAreBorgResistanceIsFutile/firstmate` (`origin`), upstream `https://github.com/kunchenguid/firstmate` (`upstream`) |
| Feature branch | `main` (the fork's `main` **is** the adapted line — DECISION-002) |
| Base branch | `upstream/main` |
| HEAD | `883e329b1cfb3f18c93ecbe312057f691e213185` — pushed, `origin/main` == `main` |
| Merge-base | `6b0f5a07fee0ac336332ccab2caa0bd07a5cf113` |
| Upstream drift | `upstream/main` has 1 commit not merged into `main` |
| Other branch | `nexon` @ `5d20cc09` (pushed) — superseded by `main`, deletable |
| Untracked | this `HANDOFF.md` |
| Generated | 2026-09-28 (eighth revision — session lock fixed on Windows (IMP-007, uncommitted); user-chosen form of address TODO-014) |
| Affected subsystems | herdr runtime backend, spawn, teardown, fork docs; planned: workbench leasing + machine-wide resource locks |
| Overall implementation status | `EXPERIMENTAL` — herdr-on-Windows runtime patch only; the workspace/lock design is agreed in conversation but **not written into the plan doc and not implemented** |

## 1. TL;DR

1. **Problem:** firstmate assumes macOS/Linux, tmux, GitHub and disposable per-task `treehouse` worktrees. This machine is Windows 11 + Azure DevOps Server, with four fixed Nexon4 workbench clones (Agents J/K/O/M), each owning an IIS identity.
2. **End state:** one first mate here dispatches tasks to the four workbenches, supervises them in herdr, coordinates machine-wide shared resources, returns Azure DevOps PRs.
3. **Big change since the first handoff:** **creating worktrees is forbidden** (DECISION-009). A task runs *inside* a workbench's own permanent clone of its repo. Workbenches are an interchangeable, **discovered** pool (a 5th can be recruited — DECISION-030); the main first mate leases one **repo clone** per task (DECISION-028) and keeps **no project clones of its own** — code knowledge comes from scouts on workbenches (DECISION-027).
4. **Every branch change in a Nexon4 clone must be followed by `Switch-Site.ps1`**; before a commit/PR, `Switch-Site.ps1 -Reset` first (INV-007, INV-008).
5. **Concurrency model agreed with the user** (§3.3): Nexon4 runs in parallel in all clones; **every workbench gets its own clones of the external repos** (DECISION-024); each external app (Bérszámfejtés, EgBizt, …) has a **per-app run lock** because of **port collision** only; builds never wait — no Nexon4 build lock, because `Build.cmd`'s kill is clone-scoped and `RegiBuild.cmd` is forbidden (DECISION-025, DECISION-026). Locks bind only firstmate-managed agents (DECISION-019).
6. **Done:** fork, tooling, herdr task panes switch PowerShell → Git Bash and report cwd (IMP-001, IMP-002).
7. **Not done:** everything in phase 2 onwards; the plan doc (`docs/nexon/adaptation-plan.md`) still describes the obsolete worktree/treehouse design (TODO-008).
8. **Key invariant:** never commit the 11 Switch-Site configs; never touch `workbench.cmd`; never touch `Default Web Site` config.
9. **Biggest risk:** upstream spawn/teardown are built around disposable worktrees (`git reset --hard`, `branch -D`, `treehouse return`, overwrite/`rm` of `.claude/settings.local.json`) — all wrong for a permanent workbench (RISK-001..003).
10. **Biggest uncertainty:** RISK-004 (Windows agent liveness in herdr); TEST-GAP-005 must confirm live that a Nexon4 `Build.cmd` run leaves external app processes alive.
11. **First step:** commit IMP-007 (session lock), then TODO-014 (form of address) and the rest of Phase 1 in `docs/nexon/adaptation-plan.md`.

## 2. Task definition

### 2.1 Problem
User request: "fork https://github.com/kunchenguid/firstmate and let's adapt it to our usecase" — use case: orchestrate Agents J/K/O/M. Upstream cannot run as shipped:
- Runtime: only herdr has a Windows build (herdr 0.9.1); its panes open PowerShell but firstmate types POSIX shell. Solved at unit level (IMP-001).
- Workspaces: upstream creates an isolated worktree per task (`treehouse get`, pooled worktrees). **Forbidden here** (DECISION-009) — a workbench clone is permanent and carries a machine-unique identity (IIS site, port, `InstanceId`, hostname) in `..\workbench.cmd` next to the clone.
- Shared machine resources: the external repos are single shared copies and their apps are single-instance; Nexon4's build kills processes at its start (§3.3). Upstream firstmate has no notion of cross-task machine locks.
- Forge: GitHub only; our repos are `https://azuredevops.nexon.hu/Berlin/Nexon4/_git/<repo>`.

### 2.2 Desired end state
- The first mate runs in this clone in a herdr pane; bootstrap is clean on Windows.
- A task is leased to one free workbench (J/K/O/M); the agent there works in that clone, running `Switch-Site.ps1 -Reset` / git op / `Switch-Site.ps1` around every branch change.
- Machine-wide locks: per-app run locks (port collision), WebCompiler first-build exclusivity, plus the single-occupancy hosts (§3.3).
- Workers open ADO PRs; merges only on the user's word via the `complete-pr` skill.

### 2.3 Scope
- `IN SCOPE`: Windows/Git Bash + herdr runtime; workbench leasing (no worktrees); resource locks; Switch-Site discipline; ADO forge; Nexon brief template; bootstrap requirements.
- `OUT OF SCOPE`: `treehouse`, `no-mistakes` (DECISION-006), any worktree creation (DECISION-009), tmux/zellij/cmux/orca, Relay, `*-axi setup hooks`.
- `UNKNOWN SCOPE`: WSL fallback; relation of `data/learnings.md` to `C:\Agents\memory\shared`.
- `OUT OF SCOPE` (added): modelling workbenches as secondmates (DECISION-020).
- `OUT OF SCOPE` (added): enforcing locks on agents running outside firstmate (DECISION-019).

### 2.4 Behavioural invariants
- **INV-001** — Non-Windows herdr backend behaviour unchanged. `CONFIRMED` — `bin/backends/herdr.sh :: fm_backend_herdr_is_windows` gates every new path.
- **INV-002** — Text sent into a herdr task pane after creation lands in bash. `CONFIRMED` for both spawn sites in `bin/fm-spawn.sh` (`fm_backend_herdr_windows_shell_prepare "$T" || exit 1`); `UNKNOWN` for panes minted elsewhere (`fm-control.sh relaunch`, secondmate paths).
- **INV-003** — `..\workbench.cmd` (outside the repo) is the single source of a clone's identity and is never modified, moved or deleted by firstmate or a worker. `CONFIRMED` — `claude-skills/plugins/nexon4-ops/skills/recruit-agent/MANUAL.md` rule 2; `Nexon4/Switch-Site.ps1` header.
  *Revision:* the first handoff treated the 11 dirty config files as irreplaceable. They are **regenerable** by `Switch-Site.ps1` from `workbench.cmd` (CONFIRMED, `Switch-Site.ps1` header). Losing them is recoverable; losing `workbench.cmd` or `.claude/settings.local.json` is not.
- **INV-004** — Never repoint/stop/reconfigure IIS `Default Web Site`; never run `Backend\UpdateDatabase.cmd`, DB restore or destructive seed without asking (shared DB). `CONFIRMED` — `C:\git\CLAUDE.md` rules 1, 4.
- **INV-005** — No Claude/Anthropic attribution in commits/PRs. `CONFIRMED` — user's global `CLAUDE.md`.
- **INV-006** — `.sh` files stay LF (`.gitattributes` `*.sh text eol=lf`, user has `core.autocrlf=true`). `CONFIRMED`.
- **INV-007** — No new worktree or clone is created for a task; work happens in the leased workbench's existing clone. `CONFIRMED` — user statement (DECISION-009).
- **INV-008** — Every branch switch/reset/checkout in a Nexon4 clone is bracketed: `Switch-Site.ps1 -Reset` → git op → `Switch-Site.ps1`. Before a commit/PR: `-Reset`, commit/push, `Switch-Site.ps1` again. The 11 configs are never committed. `CONFIRMED` — user statement; `recruit-agent/MANUAL.md` rule 7; `Switch-Site.ps1` final warning ("PR elott: .\Switch-Site.ps1 -Reset").
- **INV-009** — Resource locks (§3.3) are respected by every firstmate-managed agent: at most one run of each external app on the machine (port collision); single-occupancy hosts; WebCompiler first-build exclusivity. `CONFIRMED` requirement (user, DECISION-017/019/026); not implemented.
- **INV-010** — Workers never run `Nexon4\RegiBuild.cmd` (machine-wide `tasklist | findstr Nexon` → `taskkill` and `w3wp` kill, `RegiBuild.cmd` L29, L36); Nexon4 is built only with `Build.cmd`. `CONFIRMED` — user: \"I forbid you to run RegiBuild.cmd\" (DECISION-025).
- **INV-011** — Firstmate never keeps its own project clone (no `projects/<repo>` reference copy); code knowledge comes only from workers in workbench clones. `CONFIRMED` — user (DECISION-027).
- **INV-012** — A repo is cloned into a workbench only on the captain's explicit word; the clone is permanent and reused. `CONFIRMED` — user (DECISION-029).

## 3. Architecture and runtime model (relevant slice)

### 3.1 Upstream firstmate (as it is)
- **Spawn** (`bin/fm-spawn.sh`): creates a herdr tab, `T=<session>:<pane>`, types `cd -- <wt>` / `treehouse get`, polls `spawn_current_path` until the pane is an isolated git top-level (`spawn_worktree_isolated`), then exports and `. <launch-file>` → `claude …` with busy hooks written to `$WT/.claude/settings.local.json`.
- **Pooled worktree refresh** requires a clean tree then `git reset --hard origin/<default>` (search `reset --hard "$target"`).
- **Teardown** (`bin/fm-teardown.sh`): detaches HEAD, `branch -D`, `treehouse return --force`, `rm -f` settings.local.json.
- **Secondmates** (`.agents/skills/secondmate-provisioning/SKILL.md`): persistent homes with their own charter, backlog, project clones and worktree ship crews. **Not used for workbenches** (DECISION-020): the workbenches are interchangeable, so a pool of leased workers fits; secondmates would add a supervisor layer per workbench, fresh project clones and worktree crews, all of which conflict with INV-007.

### 3.2 Herdr on Windows (probed, `CONFIRMED`, herdr 0.9.1)
- New pane = `powershell.exe -NoExit -Command <prompt hook>` emitting OSC `9;9;<path>`.
- `pane get` → `.result.pane.foreground_cwd` always empty; `.result.pane.cwd` follows OSC 9;9 from any process.
- `pane process-info` shows only the root PowerShell (RISK-004).

```
fm-spawn -> herdr tab create (PowerShell) -> fm_backend_herdr_windows_shell_prepare
  -> pane run "& '<Git>\bin\bash.exe' --rcfile '<fm>\bin\backends\herdr-win-bashrc.sh' -i"
  -> rcfile: source ~/.bashrc; PROMPT_COMMAND = OSC 9;9 via cygpath -w; print FM_HERDR_WIN_BASH_READY
  -> pane wait-output --match FM_HERDR_WIN_BASH_READY (20 s)
  -> POSIX sends ... current_path = cygpath -u(.cwd)
```

### 3.3 Nexon machine: workbenches and shared resources (agreed with user)

| Resource | Parallel? | Rule | Evidence |
|---|---|---|---|
| Nexon4 app (IIS site per clone) | yes, all 4 | each clone its own site; a Nexon4 build does not disturb another clone's site | user; K/O/M `workbench.cmd` `NEXON_KILL_W3WP=0` |
| External app run (Bérszámfejtés, EgBizt, MappingEngine, …) | **per-app lock** — different apps may run concurrently, same app only once on the machine | take app lock before starting, release after test; the conflict is **port collision** only | user (DECISION-010, DECISION-017, DECISION-024) |
| External app build | yes, always | each workbench builds in its own clone | user (DECISION-011, DECISION-024) |
| Nexon4 build (`Build.cmd` only) | yes, always | no lock: its kill is clone-scoped and cannot reach another workbench's processes or an external app (Nexon4 depends on the apps, not vice versa); `RegiBuild.cmd` forbidden | `Build.cmd`, `Tools\Stop-CloneProcesses.ps1`; DECISION-021, DECISION-025, DECISION-026 |
| External repos `EgBiztEllat`, `Berszamfejtes`, `MappingEngine` (and any other repo) | **one permanent clone per workbench**, `<root>\<repo>`; today K/O/M have none and use J's `C:\git\<app>` | added on the captain's word (INV-012); Nexon4 finds its workbench's copy through `NEXON_*_ROOT` in `workbench.cmd` (`Tools\restart-dev-hosts.ps1 :: Resolve-ExternalRoot`) | DECISION-024, DECISION-029; TODO-011 |
| Repo clone inside a workbench | **leased per repo**: one task per `<workbench>\<repo>`; a Nexon4 task and a Bérszámfejtés task may run in the same workbench at once | lease file per clone | DECISION-028 |
| WebCompiler cache in `%TEMP%` | no | "two first builds must not run at the same time" (first = after Full `git clean`) | `recruit-agent/MANUAL.md` rule 6 |
| IntegrationEngine 8033, Licence 8001, ODataApi | single instance | existing single-occupancy rule | `C:\git\CLAUDE.md` rule 5; MANUAL.md rule 5 |

**Nexon4 `Build.cmd` kill timeline** (`C:\git\Nexon4\Build.cmd`, `CONFIRMED`):
```
L60   del build-timings.log                     (fresh per build)
L113  CsprojCheck  (may abort -> goto end, no kill ever happens)
L126  :resolveMsbuild (may abort -> goto end)
L140  echo "[time Cleanup] Kill running processes"
L141  :killW3wp            (taskkill /F /IM w3wp.exe machine-wide, only if NEXON_KILL_W3WP=1)
L142  :killCloneProcesses  -> Tools\Stop-CloneProcesses.ps1 -RepoRoot <clone>
L143  :logElapsed "Kill processes"  -> stdout "[Kill processes] elapsed: …"
                                     + append "<m>m <s>s<TAB>Kill processes" to build-timings.log
L149  :killW3wp again (Full mode, between the two git cleans)
L303  :killW3wp again (after IIS config, near end)
```
- The `Kill processes` line in `build-timings.log` is a reliable \"kill step finished\" signal. It is **no longer needed** (no Nexon4 build lock — DECISION-026), but kept here in case TEST-GAP-005 shows the kill does reach external apps. If the build aborts before L140 the line never appears.
- `Stop-CloneProcesses.ps1` stops only processes whose exe is under the clone **or** that have a module loaded from the clone (name filter `Nexon*`, `dotnet`, `MSBuild`, `VBCSCompiler`, `OutOfProcessTaskHost`, `testhost`, `vstest.console`); w3wp is out of scope. It replaced the machine-wide `tasklist | findstr Nexon` sweep (`Build.cmd` L430 comment; PR 11497, 2026-09-04). That old sweep survives only in `RegiBuild.cmd` (L29, w3wp at L36), which no other `.cmd` calls and which is forbidden (INV-010). The user's recollection \"a Nexon4 build kills every process with nexon in its name\" matches `RegiBuild.cmd`, not the current `Build.cmd`.
- The later `:killW3wp` calls (L149, L303) are machine-wide but gated by `NEXON_KILL_W3WP`; K/O/M set 0. **Agent J has no `workbench.cmd`** → default `1` (`Tools\Workbench.cmd` L146); non-elevated it is a no-op (access denied), elevated it recycles every clone's site. The user declined a change (DECISION-018) — accepted risk, RISK-010.

**Switch-Site** (`C:\git\Nexon4\Switch-Site.ps1`, `CONFIRMED`):
- No params: reads `..\workbench.cmd` (`NEXON4_URL`, `NEXON_IIS_SITE`, `NEXON_INSTANCE_ID`); rewrites 11 tracked configs: `FrontendUrl` (6 files), `InstanceId` (5 files; names the machine-wide `Nexon4.SharedMemoryCache.Instance<id>`), GuiTest URLs, `WebSiteName`. Byte-preserving (BOM, line endings).
- `-Reset`: back to shipped defaults (`http://localhost`, `Default Web Site`, `InstanceId 0`).
- No `appcmd` → no elevation needed for routine runs (`INFERRED` from reading; the one-time site creation is `Setup-Workbench-Elevated.cmd`, human, elevated).
- Does not touch 8001/8033 WCF ports nor DB connection.
- Agent J (no `workbench.cmd`) = shipped defaults → its tree stays clean. `INFERRED` (whether Switch-Site without `workbench.cmd` throws or falls back to defaults: `Switch-Site.ps1` L210 throws if values unresolved; `Import-WorkbenchDefaults` may supply defaults — not verified).

## 4. Current state of the implementation

- **IMP-001 — Git Bash in Windows task panes.** `COMPLETE` (unit). `bin/backends/herdr.sh :: fm_backend_herdr_is_windows` (uname `MINGW*|MSYS*|CYGWIN*`, override `FM_HERDR_WINDOWS`), `fm_backend_herdr_windows_shell_prepare` (overrides `FM_HERDR_WIN_BASH`, `FM_HERDR_WIN_SHELL_TIMEOUT_MS`); rcfile `bin/backends/herdr-win-bashrc.sh`; call sites in `bin/fm-spawn.sh`. INV-001/002/006. No automated tests; live probe passed. `CONFIRMED`.
- **IMP-002 — cwd tracking on Windows.** `COMPLETE` (unit). `fm_backend_herdr_current_path` falls back to `.cwd`, `cygpath -u`, strips trailing `/`. `CONFIRMED` by probe.
- **IMP-003 — Adaptation plan doc** `docs/nexon/adaptation-plan.md`. `COMPLETE` as a plan: rewritten 2026-09-28 around DECISION-009..026 — rules, resource/lock table, Phase 1 (runtime foundation + one read-only task on M) and Phase 2 (real tasks on all four workbenches) with numbered steps and exit criteria; Phase 3–4 adjusted (integrated auth). One open decision recorded there: firstmate's project directory for Nexon4 (QUESTION-012).
- **IMP-004 — Tooling.** `COMPLETE`. `jq` 1.8.2; Volta npm globals `tasks-axi` 0.2.6, `quota-axi` 0.1.55, `gh-axi` 0.1.35, `chrome-devtools-axi` 0.1.35, `lavish-axi` 0.1.79; `gh` logged in. No `setup hooks`.
- **IMP-005 — workbench workspace provider.** `PLACEHOLDER`. The old plan (treehouse shim creating worktrees) is **cancelled** (DECISION-009). Replacement design not started.
- **IMP-006 — resource lock mechanism.** `PLACEHOLDER`. Only the requirements exist (§3.3).
- **IMP-007 — Session lock on Windows.** `COMPLETE` (live-verified, **uncommitted** at this revision). Two causes, two fixes:
  1. `bin/fm-session-lock-lib.sh`: new `fm_proc_is_windows` (uname `MINGW*|MSYS*|CYGWIN*`, override `FM_PROC_WINDOWS=1|0`), `_fm_proc_windows_start_pid` (outermost MSYS ancestor via `/proc/<pid>/ppid`, then its `/proc/<pid>/winpid` — a native walk from `$$` dead-ends at exited MSYS fork stand-ins), `_fm_proc_windows_rows chain|pid` (one Windows PowerShell `Win32_Process` table read, script kept single-line and single-quoted because MSYS mangles embedded `\"`), `_fm_proc_windows_harness_alive`, `_fm_harness_ancestry_pids_windows`. Windows branches added to `fm_harness_ancestry_pids`, `fm_harness_pid_alive`, `fm_session_lock_trusted_session_id`, `fm_session_lock_inspect`; POSIX lines untouched (INV-001).
  2. `bin/fm-wake-lib.sh`: every lock is `ln -s <owner-dir> <lock>`; MSYS's default `ln -s` deep-copies, so the lock looked ownerless and `fm_lock_acquire_wait` spun forever. On `MINGW*|MSYS*` the lib exports `MSYS=winsymlinks:nativestrict` unless a `winsymlinks:` mode is already set (native symlinks work on this machine without Developer Mode).
  Evidence: `bin/fm-lock.sh` → \"lock acquired: harness pid 33620\" (this session's `claude.exe`, == `CLAUDE_PID`), repeat acquisitions confirm, `status` → held, no leftover owner dirs. `tests/fm-session-lock-ancestry.test.sh` with `FM_PROC_WINDOWS=0 MSYS=winsymlinks:nativestrict`: unit layer 7 ok; the end-to-end layer (\"the fixture hook never finished\") needs real POSIX `ps -o` process trees and cannot run under Git Bash — TEST-GAP-006. Cost: ~0.8 s per native query, ~3–12 s per full ownership check (RISK-016).
  Incident during verification: the first, hung `fm-lock.sh` survived `TaskStop` of its parent shell and kept recreating copied lock dirs with old code until killed (`taskkill`). Leftover copied dirs from before the fix may still exist in `state/` (e.g. `.turnend-claude-blocks.lock`, `.steal`, from the Stop hook at 17:19/17:29); the fixed code reclaims dead-owner dirs on next use, as it did for `.lock.acquire`.

## 5. Important runtime scenarios (target behaviour, none implemented)

- **FLOW-001 — Task on a Nexon4 workbench.** Initial: workbench X idle — Nexon4 clone on `EHR`, Switch-Site applied (DECISION-022). Trigger: first mate leases X (only a workbench with no work in flight — K and O currently have the user's work in progress). Steps: 1) lease X 2) herdr pane → Git Bash (IMP-001) 3) `cd` into X's clone (no worktree) 4) `Switch-Site.ps1 -Reset` 5) `git fetch` + create/switch task branch 6) `Switch-Site.ps1` 7) worker implements, builds (FLOW-003 if Nexon4), tests (FLOW-002 if external app) 8) `-Reset` → commit/push → `Switch-Site.ps1` 9) ADO PR 10) return Nexon4 to `EHR` with the same bracket (external repos the task touched → `main`); release lease. End state: branch pushed, workbench idle, `workbench.cmd` and `.claude/settings.local.json` untouched. INV-003/007/008.
- **FLOW-002 — External app run.** Worker acquires `app:<name>` (e.g. `app:berszamfejtes`) → starts the app from its own workbench's clone → tests → stops the app → releases. A second requester for the same app waits (port collision). Builds never wait. INV-009.
- **FLOW-003 — Nexon4 build.** Run `Build.cmd` (never `RegiBuild.cmd`, INV-010) in the workbench's own clone, no lock; a Full build additionally takes `webcompiler-first-build` (RISK-013).
- **FLOW-004 — Bash never becomes ready.** `pane wait-output` times out → prepare errors, spawn `exit 1`. Orphan tab cleanup `UNKNOWN`.
- **FLOW-005 — Crash while holding a lock.** Holder dies → lock must be recoverable (stale detection by PID/pane liveness). Mechanism `UNKNOWN`; related RISK-004.

## 6. Tests and verification

- No tests added/modified. Upstream bash test suite under `tests/` not run.
- **TEST-GAP-001** — herdr `current_path` on Linux after refactor. unit (WSL/CI). INV-001, IMP-002.
- **TEST-GAP-002** — FLOW-001 end to end on one workbench; verify identity configs regenerated and `workbench.cmd`/settings.local.json byte-identical. system/manual. INV-003/008.
- **TEST-GAP-003** — FLOW-004 orphan tab cleanup. integration.
- **TEST-GAP-004** — lock contention: two agents requesting the same app lock; stale-lock recovery after a crashed holder (FLOW-005). integration. INV-009, IMP-006.
- **TEST-GAP-005** — run a Nexon4 `Build.cmd` in one workbench while an external app (started from another workbench's clone) and another workbench's Nexon4 dev hosts run; confirm all survive. system/manual. DECISION-026 depends on it.
- **TEST-GAP-006** — Windows branch of `bin/fm-session-lock-lib.sh` has no automated test: add a unit case with a fake `powershell.exe` on PATH and `FM_PROC_WINDOWS=1` (rows for a bash → bash → claude chain, a dead pid, a non-harness pid). unit. IMP-007.
- **TEST-GAP-007** — `bin/fm-session-start.sh` form-of-address reminder: printed when `data/captain.md` lacks a non-empty `Form of address:` line in a primary home; absent when recorded or in a secondmate home (`data/charter.md`). Extend `tests/fm-session-start.test.sh`. unit. TODO-014.

## 7. Problems, risks, uncertainties

| ID | Severity | Type | Area | Description | Evidence | Impact | Proposed step |
|---|---|---|---|---|---|---|---|
| RISK-001 | CRITICAL | DESIGN_RISK | spawn | Pooled refresh requires clean tree then `git reset --hard origin/<default>`; spawn expects an isolated worktree | `bin/fm-spawn.sh` (search `reset --hard "$target"`, `spawn_worktree_isolated`) | Wrong for permanent workbench; blocks spawn (dirty configs) or wipes them | Workbench mode bypasses worktree/pool logic entirely (TODO-009) |
| RISK-002 | HIGH | DESIGN_RISK | spawn/teardown | `cat >"$WT/.claude/settings.local.json"` at spawn; `rm -f` at teardown | `bin/fm-spawn.sh` hook block; `bin/fm-teardown.sh` | Destroys the clone's existing file | Merge + restore (TODO-009) |
| RISK-003 | HIGH | DESIGN_RISK | teardown | Detach HEAD, `branch -D`, `treehouse return --force` | `bin/fm-teardown.sh` (search `branch -D`, `teardown_treehouse_return`) | Deletes task branch; treehouse absent | Workbench teardown = return to neutral branch with Switch-Site bracket, keep branch |
| RISK-004 | HIGH | UNKNOWN | herdr backend | Liveness via process info sees only root PowerShell | `herdr pane process-info` probe | Stale/dead misclassification; also stale-lock detection | Test in smoke run; PID file / `report-agent` |
| RISK-005 | HIGH | ASSUMPTION | permissions | Workers default to `--dangerously-skip-permissions` | `bin/fm-spawn.sh`; `docs/configuration.md` (`config/claude-permission-mode`) | Shared DB safety (INV-004) | Set `config/claude-permission-mode=auto` before any Nexon4 spawn |
| RISK-006 | MEDIUM | UNKNOWN | POSIX deps | `stat -c %a`, `ps -o`, `mkfifo` | `bin/fm-pr-lib.sh`, `bin/fm-watch.sh`, `bin/fm-procevent.sh` | Silent failures under Git Bash | Record during smoke test |
| RISK-007 | MEDIUM | ASSUMPTION | npm | Company registry served stale `quota-axi` for unpinned install | npm output | Silent old versions | Pin versions |
| RISK-008 | LOW | ASSUMPTION | node | `quota-axi` ≥22.19, `lavish-axi` ≥22; Volta default node 20.20.2 | `npm view … engines` | Possible breakage | Volta-pin node 22 if needed |
| RISK-009 | LOW | TECH_DEBT | docs | Comment in `fm_backend_herdr_current_path` says `herdr-win-bashrc` (no `.sh`) | `bin/backends/herdr.sh` | cosmetic | fix with next edit |
| RISK-010 | LOW | ASSUMPTION | Nexon4 build on J | J has no `workbench.cmd` → `NEXON_KILL_W3WP=1`; only an **elevated** J build would kill every clone's w3wp (L141, L149, L303); non-elevated it is a no-op | `Nexon4/Build.cmd :killW3wp`; `Nexon4/Tools/Workbench.cmd` L146 | Other sites recycled if J ever builds elevated | Accepted by user, no change (DECISION-018); workers do not build elevated |
| RISK-011 | LOW | TECH_DEBT | external repo clones | Today all workbenches share `C:\git\<app>`; the `recruit-agent` skill documents them as shared, not cloned | `recruit-agent/MANUAL.md` rule 5; no `NEXON_*_ROOT` in any `workbench.cmd` | Until TODO-011 is done, two workbenches touching the same external repo clobber each other | TODO-011; propose a `recruit-agent` update to the user (claude-skills repo — not edited by this work) |
| RISK-012 | LOW | DESIGN_RISK | lock hygiene | A crashed lock holder leaves an app lock held | FLOW-005 | App blocked for all workbenches | Stale detection by holder PID / pane liveness (TODO-010) |
| RISK-013 | LOW | DESIGN_RISK | WebCompiler | Shared `%TEMP%` WebCompiler cache: two first (Full) builds at once break | `recruit-agent/MANUAL.md` rule 6 | Flaky `.less` build failures | Serialise Full Nexon4 builds or give the claim a Full-build variant |
| RISK-015 | — | BUG | session lock | **Fixed** by IMP-007 (uncommitted): the Windows session lock failed with \"cannot locate harness process in ancestry\", then hung on copied symlinks | IMP-007 | — | commit IMP-007 |
| RISK-016 | MEDIUM | PERFORMANCE | session lock on Windows | Each native process query costs ~0.8 s (Windows PowerShell start + CIM); one ownership check runs several; the Stop/turn-end hooks (`fm-claude-stop-autoarm.sh`, `fm-turnend-guard.sh`) source the same library every turn | IMP-007 timings | Seconds of latency per turn end | Cache the ancestry rows per process tree, or a small native helper; measure first |
| RISK-017 | MEDIUM | UNKNOWN | other POSIX process calls | 33 `ps -o` calls across `bin/*.sh` beyond the session lock (watcher, spawn, agent-process lib) still use MSYS `ps`, which has no `-o` | `grep -rn 'ps -o' bin/*.sh` | Silent failures in liveness/supervision | Record during the Phase 1 smoke test; reuse IMP-007's helpers |

## 8. Unfinished work

- **TODO-001** — **DONE**: `main` pushed; `upstream/main` merged at `de04757b` (2 upstream commits: #6002, #6010); "Upstream sync" section of the plan follows DECISION-002.
- **TODO-002** — **CANCELLED** (DECISION-009): the treehouse shim creating worktrees.
- **TODO-003** — **DONE**: `config/workspace` = `workbench` (`bin/fm-workbench-lib.sh :: fm_workspace_mode`; `docs/configuration.md` "Workspace mode") drops `treehouse`/`no-mistakes` from bootstrap; verified: bootstrap prints no MISSING line in workbench mode, the old two lines without the file, and `CONFIG: config/workspace is invalid` for a bad value. This home has `config/workspace` = `workbench`. `bin/fm-doc-audience-check.sh` not run (needs `python3`; the machine has only `python`).
- **TODO-008** — **DONE** 2026-09-28: plan rewritten (IMP-003).
- **TODO-009** — P0. Workbench worker mode (DECISION-020, DECISION-027, DECISION-028, DECISION-030) — plan Phase 1 steps 4–9 and Phase 2 steps 2–3: `bin/fm-workbench.sh discover` (from `applicationHost.config`, as `recruit-agent -ShowOccupancy` does; J via `Default Web Site`; new workbench used only after the captain confirms), per-repo `lease`/`release`/`status`, `prepare`/`restore`; project registry without clones; spawn takes its folder from the lease and skips `treehouse get`, pooled refresh, `spawn_worktree_isolated`, `freshen_spawn_worktree_base`; settings.local.json merge + restore; teardown keeps the branch and returns the clone to `EHR` (Nexon4) / `main` (others) with the Switch-Site bracket for Nexon4. Depends on RISK-001..003. DoD: TEST-GAP-002 on one workbench.
- **TODO-010** — P1. Design the machine-wide lock mechanism (IMP-006): lock names `app:<name>` (one per external app), `webcompiler-first-build`, `host:8033`, `host:8001`, `host:odata`; storage visible to the first mate and all four workbench workers (e.g. files under `C:\Agents\locks\` with holder, PID, pane, timestamp — `INFERRED` proposal, not agreed); stale recovery (FLOW-005, RISK-012). No Nexon4 build lock (DECISION-026). Only firstmate-managed agents need to honour it (DECISION-019). DoD: TEST-GAP-004.
- **TODO-011** — P1. `bin/fm-workbench.sh clone <workbench> <repo> <origin>` (plan Phase 2 step 1), run only on the captain's word (INV-012). First use: give K, O, M their own `EgBiztEllat`, `Berszamfejtes`, `MappingEngine`; the `NEXON_*_ROOT` lines in their `workbench.cmd` are a captain step (INV-003). Also the entry point for research on a brand-new repo. DoD: `restart-dev-hosts.ps1` in K reports the roots from `..\workbench.cmd`.
- **TODO-012** — P3, `CONFIRMED` (user: \"make a note to change recruit-agent skill later\"). Update the `recruit-agent` skill (`C:\git\claude-skills\plugins\nexon4-ops\skills\recruit-agent\` — `SKILL.md`, `MANUAL.md` rule 5, `scripts/New-AgentWorkbench.ps1`) so a new workbench gets its **own** clones of `EgBiztEllat`, `Berszamfejtes`, `MappingEngine` and `workbench.cmd` gets the `NEXON_*_ROOT` values; a recruited workbench is then found by firstmate's discovery (DECISION-030). That repo is the company marketplace — change it through its own PR, not by editing the local clone in place. Not now.
- **TODO-013** — **DONE** (IMP-007), pending commit.
- **TODO-014** — P1, `CONFIRMED` (user: \"stop calling me captain\", \"ask the user at setup how to call her/him\"). `AGENTS.md` hard-codes \"captain\" as the mandatory chat address (L8–17). Make it the user's choice: when `data/captain.md` has no form of address, the first mate asks at session start and records it there; `AGENTS.md` refers to that record, fallback no title. Shared tracked material — change directly only while the fleet is empty, and keep \"captain\" as the internal role word. Plan: Phase 1 step 10.
- **TODO-004** — P1. Register a first project and run a smoke task on **one workbench** (not MappingEngine worktree mode — MappingEngine is itself a shared external repo, RISK-011). DoD: FLOW-001 completes; Windows failures recorded (RISK-004/006).
- **TODO-005** — P2. Remaining workbench details: `config/claude-permission-mode=auto` (RISK-005); refuse to lease a dirty workbench.
- **TODO-006** — P2. Phase 3 ADO forge (`bin/fm-pr-lib.sh :: fm_pr_url_parse` ADO pattern, record reader, poll/merge arms, bootstrap `gh` exemption). QUESTION-003.
- **TODO-007** — P3. Phase 4 Nexon brief template (Switch-Site bracket, lock protocol, `Build.cmd` only / never `RegiBuild.cmd` (INV-010), Nexon `CLAUDE.md` steps, `complete-pr` instead of `no-mistakes`/`gh-axi` DoD).

## 9. Entry point for the next agent

- **Read first:** this file §3.3; `C:\git\Nexon4\Switch-Site.ps1` (header); `C:\git\Nexon4\Build.cmd` L100–155 and `:killW3wp`/`:killCloneProcesses`; `C:\git\Nexon4\Tools\Stop-CloneProcesses.ps1` (header); `C:\git\claude-skills\plugins\nexon4-ops\skills\recruit-agent\MANUAL.md` §8 rules 1–9; `docs/nexon/adaptation-plan.md`; `bin/fm-spawn.sh` (search `treehouse get`, `spawn_worktree_isolated`, `reset --hard`, `settings.local.json`); `bin/fm-teardown.sh`.
- **Check first:** `git status -sb`; `git rev-list --count main..upstream/main`; `git -C /c/AgentK/Nexon4 status --short | head` (expect the 11 Switch-Site configs dirty).
- **Start with:** TODO-009 (Phase 1 steps 4-9), using `fm_workspace_mode` as the switch.
- **Do not break:** INV-003, INV-004, INV-005, INV-007, INV-008, INV-010, INV-011, INV-012.
- **Clarify before a bigger change:** RISK-004, TEST-GAP-005.
- Note: this repo's `CLAUDE.md` → `AGENTS.md` loads the first-mate persona contract. An agent developing the fork is not the first mate; do not run `bin/fm-session-start.sh` (it runs read-only anyway from a hook, lock unverified). The contract's "captain" address in chat applies to any agent reading it.
- Bash tool: a hook blocks persistent `cd` in this repo — use absolute paths or `git -C`.

## 10. Important files

| File | Symbols | Role | Related IDs |
|---|---|---|---|
| `bin/backends/herdr.sh` | `fm_backend_herdr_current_path`, `fm_backend_herdr_is_windows`, `fm_backend_herdr_windows_shell_prepare` | herdr backend + Windows patch | IMP-001/002, INV-001 |
| `bin/backends/herdr-win-bashrc.sh` | `PROMPT_COMMAND`, `FM_HERDR_WIN_BASH_READY` | pane bash rcfile | IMP-001, INV-006 |
| `bin/fm-spawn.sh` | herdr `T=` sites, `treehouse get`, pooled refresh, hook write | spawn | RISK-001/002, TODO-009 |
| `bin/fm-teardown.sh` | `teardown_treehouse_return`, `branch -D` | cleanup | RISK-003, TODO-009 |
| `bin/fm-bootstrap.sh` | `MISSING:` | toolchain gate | TODO-003 |
| `bin/fm-pr-lib.sh` | `fm_pr_url_parse` | forge seam | TODO-006 |
| `docs/nexon/adaptation-plan.md` | "Upstream sync", Phase 1–4 | plan of record (stale) | IMP-003, TODO-001/008 |
| `C:\git\Nexon4\Switch-Site.ps1` | `-Reset`, `-BaseUrl/-SiteName/-InstanceId` | clone identity repoint | INV-003/008 |
| `C:\git\Nexon4\Build.cmd` | `:killW3wp`, `:killCloneProcesses`, `:logElapsed`, `build-timings.log` | build + kill timeline | FLOW-003, RISK-010/012 |
| `C:\git\Nexon4\Tools\Stop-CloneProcesses.ps1` | `-RepoRoot`, `-NameFilter` | clone-scoped process stop | QUESTION-004 |
| `C:\git\Nexon4\Tools\Workbench.cmd` | `read`, `restore`, `NEXON_KILL_W3WP` default | reads `..\workbench.cmd` | RISK-010 |
| `C:\Agent{K,O,M}\workbench.cmd` | `NEXON_IIS_SITE`, `NEXON4_URL`, `NEXON_INSTANCE_ID`, `NEXON_KILL_W3WP=0`, `NEXON_*_ROOT` | clone identity (never edit) | INV-003 |
| `C:\git\claude-skills\plugins\nexon4-ops\skills\recruit-agent\{SKILL,MANUAL}.md` | rules 1–9 | workbench conventions | §3.3 |

## 11. Assumptions

- **ASSUMPTION-001** — herdr updates `.cwd` from OSC 9;9 emitted by a child process. `CONFIRMED` (herdr 0.9.1). If false: spawn cwd poll never converges. Verify: rerun probe after `herdr update`.
- **ASSUMPTION-002** — `cygpath -w /` + `\bin\bash.exe` gives a usable Git Bash for `--rcfile … -i`. `CONFIRMED`.
- **ASSUMPTION-003** — nested interactive bash inherits exported `PROMPT_COMMAND`. `CONFIRMED` unless a user `~/.bashrc` overwrites it (`INFERRED` risk). Less important now: no worktree subshell is needed.
- **ASSUMPTION-004** — first mate runs in its own herdr pane so workers appear in its workspace. `INFERRED` (`docs/herdr-backend.md`).
- **ASSUMPTION-005** — `Switch-Site.ps1` routine runs need no elevation. `INFERRED` (no `appcmd` in script). Verify: run in a non-elevated shell in K.
- **ASSUMPTION-006** — the `Kill processes` line in `build-timings.log` is written only after both kill calls at L141–142 finished (sequential `call`s in cmd). `CONFIRMED` by reading; the later w3wp kills (L149, L303) are ignored because K/O/M disable them (and J per RISK-010).
- ~~**ASSUMPTION-007**~~ — rejected: locks bind only firstmate-managed agents (DECISION-019).

## 12. Decisions already made

- **DECISION-001** — Fork on GitHub under `WeAreBorgResistanceIsFutile`. `CONFIRMED`.
- **DECISION-002** — Fork's `main` is the adapted line; upstream arrives by merging `upstream/main` (firstmate reports TANGLE off default branch; `/updatefirstmate` fast-forwards only the default branch). `CONFIRMED`.
- **DECISION-003** — Native Git Bash + herdr; WSL only as fallback. `CONFIRMED`.
- **DECISION-004** — Crew = Agents J, K, O, M; J included. `CONFIRMED`.
- **DECISION-005** — Git Bash in panes by patching firstmate, not herdr `terminal.default_shell`. `CONFIRMED`.
- **DECISION-006** — `treehouse` and `no-mistakes` not used. `CONFIRMED`.
- **DECISION-007** — No `*-axi setup hooks`. `CONFIRMED`.
- **DECISION-008** — ~~Smoke test on MappingEngine in worktree mode~~ — **superseded** by DECISION-009 (MappingEngine is a shared external repo, and worktrees are forbidden).
- **DECISION-009** — **Worktree creation is forbidden.** Each agent works in its own permanent workbench clone. User: "in my usecase creation of a worktree is forbidden". `CONFIRMED`. QUESTION-001 (treehouse shim approval) is thereby answered: no.
- **DECISION-010** — Per-app run lock (not one lock for all apps). User: "per-app lock". `CONFIRMED`.
- **DECISION-011** — An external app can be built while the same app runs elsewhere; external app builds never wait. `CONFIRMED` (user) — but see QUESTION-006.
- **DECISION-012** — A Nexon4 build kills processes only at its start (`Build.cmd` L140–143); the `Kill processes` line marks the end. `CONFIRMED`. Superseded in effect by DECISION-026 (no build lock needed).
- **DECISION-013** — A Nexon4 build does not disturb another clone's Nexon4 site. User. `CONFIRMED` for K/O/M (`NEXON_KILL_W3WP=0`); J see RISK-010.
- **DECISION-014** — The switch-site script is `Nexon4\Switch-Site.ps1`, bracketed with `-Reset` around git ops and commits. `CONFIRMED` (user pointed to recruit-agent skill; script read).
- **DECISION-015** — The Nexon4 build kill is clone-scoped (answer to QUESTION-004; matches `Tools\Stop-CloneProcesses.ps1`). `CONFIRMED`. Refined by DECISION-026.
- ~~**DECISION-016**~~ — secondmate model, **reversed** by DECISION-020.
- **DECISION-017** — "Running elsewhere" means a run shares no files with a build, so an app can always be built; it just cannot run twice because of **port collision** (answer to QUESTION-006). The per-app lock is therefore a run/port lock. `CONFIRMED`.
- **DECISION-018** — No change for Agent J's `NEXON_KILL_W3WP` default (answer "no" to QUESTION-007). `CONFIRMED`; interpretation "leave as is, workers don't build elevated" is `INFERRED`.
- **DECISION-019** — Locks do not need to bind agents running outside firstmate (answer "no" to QUESTION-008). `CONFIRMED`.
- **DECISION-020** — Workbenches are **workbench workers** leased from a pool by the main first mate, not secondmates (user: \"switch to workbench workers and reverse\"). Reason: the four workbenches are interchangeable; secondmates suit distinct domains and would add a supervisor layer plus clone/worktree adaptations. `CONFIRMED`.
- **DECISION-021** — Dependency direction: Nexon4 depends on Bérszámfejtés, not vice versa (user). Checked: no `Nexon4\` path references in the Berszamfejtes/EgBiztEllat/MappingEngine project files. External roots resolve env → `..\workbench.cmd` → `C:\git\<app>` (`Nexon4/Tools/restart-dev-hosts.ps1 :: Resolve-ExternalRoot`); no `workbench.cmd` sets them, so all workbenches share `C:\git\<app>`. Consequence: a clone-scoped Nexon4 build kill cannot reach an external app (DECISION-026). `CONFIRMED` (user + code); live check TEST-GAP-005.
- **DECISION-022** — Idle workbench: Nexon4 clone on `EHR`, other repos on `main` (user). The uncommitted changes in K and O are the user's in-flight work, so those workbenches are busy and cleanup never touches such changes. `CONFIRMED`.
- **DECISION-023** — ADO REST auth = Windows integrated (`Invoke-RestMethod -UseDefaultCredentials`), no PAT, no token — as the `nexon-common:complete-pr` skill does (`scripts/Complete-Pr.ps1` header: \"no PAT, no token. Do not add one.\"). Closes QUESTION-003. `CONFIRMED`.
- **DECISION-024** — Every workbench gets its **own clones** of the external repos; nothing is shared. The only cross-workbench conflict is **port collision** when the same app is started twice. User: \"each workbench should have its own clone of the repo, the single problem is that these can not be instantiated at the same time because of port collision\". Answers QUESTION-011. `CONFIRMED`.
- **DECISION-025** — `RegiBuild.cmd` is forbidden. User: \"I forbid you to run RegiBuild.cmd\". → INV-010. `CONFIRMED`.
- **DECISION-026** — No Nexon4 build lock. With `Build.cmd` only (DECISION-025), its clone-scoped kill cannot reach another workbench's processes or an external app (DECISION-021, DECISION-024). Proposed in conversation and accepted by the user's answer forbidding `RegiBuild.cmd` — `INFERRED` acceptance; TEST-GAP-005 confirms live.
- **DECISION-027** — Firstmate keeps **no project clones** (no read-only reference copy). Reason (user): with several agents working on one repo a reference copy never matches what a worker uses, and it would be needed for every repo. Code knowledge comes from workers/scouts in workbench clones; the project registry holds name, origin, description. The read-only-clone proposal is rejected. `CONFIRMED`.
- **DECISION-028** — Leases are **per repo clone** (`<workbench>\<repo>`), not per workbench. User: \"per repo, a Nexon4 project rarely modifies external repos\". A task needing a second repo leases that clone in the same workbench. `CONFIRMED`.
- **DECISION-029** — Cloning a repo into a workbench for the first time needs the captain's word each time (user: \"ask\"). Research on a brand-new repo is supported this way. `CONFIRMED`.
- **DECISION-030** — The workbench set is not fixed: the captain can recruit a 5th with the `recruit-agent` skill. Firstmate discovers workbenches from `applicationHost.config` (the source `recruit-agent -ShowOccupancy` reads without elevation; J through `Default Web Site`, never a `workbench.cmd` scan) and uses a new one only after the captain confirms. `CONFIRMED` requirement (user); discovery mechanism `INFERRED` design.
- **DECISION-031** — The user is not addressed as \"captain\" (user, 2026-09-28); how to address them is asked at setup (TODO-014). Overrides AGENTS.md's address rule under its captain-instruction precedence. `CONFIRMED`.

## 13. Questions for the user

- ~~QUESTION-002~~ → DECISION-022. ~~QUESTION-003~~ → DECISION-023. ~~QUESTION-004~~ → DECISION-015. ~~QUESTION-005~~ → DECISION-016, reversed by DECISION-020. ~~QUESTION-006~~ → DECISION-017. ~~QUESTION-007~~ → DECISION-018. ~~QUESTION-008~~ → DECISION-019. ~~QUESTION-009~~ → moot (DECISION-020). ~~QUESTION-010~~ → DECISION-021. ~~QUESTION-011~~ → DECISION-024.
- ~~QUESTION-012~~ → DECISION-027. No open questions for the user; open design watch-item: two tasks in one workbench colliding on its IIS site (plan, *Open decisions*).

## 14. Branch change map

- **herdr Windows runtime** — `bin/backends/herdr.sh`, `bin/backends/herdr-win-bashrc.sh`, `bin/fm-spawn.sh` (+2 lines): task panes switch into Git Bash with OSC 9;9 prompt; cwd from `.cwd` + `cygpath`. IMP-001/002, RISK-004/009.
- **Fork documentation** — `docs/nexon/adaptation-plan.md` (new): environment, findings, 4-phase plan — partly obsolete. IMP-003, TODO-001/008.
- No other upstream file changed.

## 15. Continuation contract

- **Preserve:** INV-001, INV-002, INV-003, INV-004, INV-005, INV-006, INV-007, INV-008, INV-009, INV-010, INV-011, INV-012.
- **Finish:** TODO-013 → TODO-001 → TODO-003 → Phase 1 rest (TODO-009 part 1) → TODO-011 → TODO-009 part 2 → TODO-010 → TODO-004 → TODO-005 → TODO-006 → TODO-007 → TODO-012.
- **Investigate:** RISK-001, RISK-002, RISK-003, RISK-004, RISK-012, ASSUMPTION-005, TEST-GAP-005.
- **Proposed first step:** Start TODO-009 with `bin/fm-workbench-lib.sh` workbench discovery from `applicationHost.config` (Phase 1 step 4), with a unit test under `tests/`.
