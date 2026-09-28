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
4. **Workbench discovery.** Workbenches come and go (`recruit-agent` can add a
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
6. **Per-repo lease** (`bin/fm-workbench.sh`): `lease <task> <repo> [<workbench>]`
   picks a workbench whose `<root>\<repo>` exists, has no live lease and is clean
   (beyond the 11 Switch-Site configs for Nexon4); writes
   `state/workbench-<id>-<repo>.lease` (task, time) under a lock; a second repo
   for the same task leases the same workbench's clone; `release <task>`;
   `status`. If no workbench has a clone of `<repo>`, it stops and reports that
   (the captain decides where to clone it — Phase 2 step 1).
7. **Spawn in workbench mode** (`bin/fm-spawn.sh`): the seam is the branch that
   types `treehouse get` and polls for an isolated worktree. Workbench mode
   replaces it with: lease → `cd` into the leased `<root>\<repo>` clone →
   assert the pane is in exactly that clone. It skips the Treehouse project lock, the pool-slot claim
   and `freshen_spawn_worktree_base` (which runs `git reset --hard`).
8. **Hooks without clobbering.** Merge the busy/idle hooks into the clone's
   existing `.claude/settings.local.json` (back it up first) instead of `cat >`;
   restore the backup byte-for-byte at cleanup.
9. **Cleanup in workbench mode** (`bin/fm-teardown.sh`): no `checkout --detach`,
   no `branch -D`, no `treehouse return`; release the lease; restore the hooks
   file.
10. **Form of address chosen by the user.** `AGENTS.md` hard-codes "captain" as
    the mandatory chat address. Replace that with the user's own choice: at
    setup (a session start whose `data/captain.md` has no form of address yet)
    the first mate asks how the user wants to be addressed — a name, a title,
    or none — and records the answer in `data/captain.md`; `AGENTS.md` then says
    "address the user the way `data/captain.md` records", with no title as the
    fallback. "Captain" stays as the internal role word in the docs.
11. **Permissions.** `config/claude-permission-mode` = `auto` (upstream defaults
    workers to `--dangerously-skip-permissions`).
12. **Smoke test.** A scout-style task on M ("summarise how X works"): no commit,
    no build. Record every Windows failure: agent liveness through herdr (only
    the root PowerShell is visible to `pane process-info`), `stat -c %a`, `ps
    -o`, `mkfifo` users (`bin/fm-pr-lib.sh`, `bin/fm-watch.sh`,
    `bin/fm-procevent.sh`).

**Exit criteria:** the lock holds; the task completes and is cleaned up; M's
clone, `workbench.cmd` and `settings.local.json` are byte-identical before and
after; every Windows failure is either fixed or listed. **Exit decision:** native
Git Bash + herdr, or move the first mate into WSL.

### Phase 2 — real tasks on every workbench

Goal: a worker takes a Nexon4 change from brief to a pushed branch with an open
Azure DevOps PR, on any free workbench, while the other workbenches keep working.

1. **First clone of a repo into a workbench** (`bin/fm-workbench.sh clone
   <workbench> <repo> <origin>`), always on the captain's word, then kept: this is
   how K, O and M get their own `EgBiztEllat`, `Berszamfejtes`, `MappingEngine`
   (today they all use J's `C:\git\<app>`), and how research on a brand-new
   repo starts. For an external repo Nexon4 runs against, the matching
   `NEXON_EGBIZTELLAT_ROOT` / `NEXON_BERSZAMFEJTES_ROOT` /
   `NEXON_MAPPINGENGINE_ROOT` line in that workbench's `workbench.cmd` is a
   captain step. Check each app's own configuration for ports or URLs that assume
   one instance.
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
  external repos as shared, not cloned. It needs to clone them per workbench and
  write the `NEXON_*_ROOT` values into `workbench.cmd`. A newly recruited
  workbench is then picked up by Phase 1 step 4's discovery.
