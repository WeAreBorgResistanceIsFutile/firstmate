# Nexon adaptation plan

This fork adapts firstmate to one Windows 11 development machine that hosts four
long-lived Nexon4 workbench clones. The goal: the captain talks to one first
mate, and the first mate dispatches Nexon4 tasks to those clones, supervises
them, and brings back Azure DevOps pull requests.

Status: **plan only.** Nothing below is implemented yet. `main` tracks
`upstream/main` unchanged; all adaptation lives on the `nexon` branch.

## Target environment

| | upstream assumes | this machine |
|---|---|---|
| OS / shell | macOS, Linux, bash | Windows 11, PowerShell primary, Git Bash available, WSL Ubuntu installed |
| session backend | tmux (default), herdr, zellij, cmux, orca | herdr 0.9.1 native Windows build installed; no tmux / zellij |
| workspaces | disposable `treehouse` worktrees | four fixed, pre-provisioned clones (below) |
| forge | GitHub via `gh` / `gh-axi` (Gerrit, GitLab partial) | on-prem Azure DevOps Server, `https://azuredevops.nexon.hu/Berlin/Nexon4/_git/<repo>` |
| delivery gate | `no-mistakes` | Nexon CLAUDE.md review chain, `complete-pr` / `bubble` skills |

### The crew: fixed workbench slots

| slot | clone | IIS site | URL | InstanceId |
|---|---|---|---|---|
| J | `C:\git\Nexon4` | `Default Web Site` (`*:80:`) | `http://localhost` | 0 |
| K | `C:\AgentK\Nexon4` | `Nexon4-AgentK` (`*:8080:`) | `http://agentk.localhost` | 1 |
| O | `C:\AgentO\Nexon4` | `Nexon4-AgentO` (`*:8081:`) | `http://localhost:8081` | 2 |
| M | `C:\AgentM\Nexon4` | `Nexon4-AgentM` (`*:8082:`) | `http://localhost:8082` | 3 |

All four share one SQL database (`.\Nexon4`) with one `MigrationHistory`.
J is a crew slot too, but it also serves `Default Web Site` for everyone on
the machine and has no `workbench.cmd` by design, so a scan of `workbench.cmd`
files can never be the source of truth for its occupancy.

## Findings that shape the design

1. **Bootstrap already runs under Git Bash.** `FM_BACKEND=herdr bin/fm-bootstrap.sh`
   completes in ~6 s with no backend error. Only tools are missing: `jq`,
   `treehouse`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, `tasks-axi`,
   `quota-axi`, `lavish-axi`. None has been installed yet; the `*-axi setup hooks`
   steps would modify the global Claude Code hook config and need explicit
   approval.
2. **Workbench identity is uncommitted local edits.** K, O and M each carry
   12–13 modified `Web.config` / `App.config` files (e.g. `InstanceId` in
   `Frontend/Source/Nexon.Web/Web.config`). Upstream refuses to spawn into a
   dirty pooled tree and, on a clean one, runs
   `git reset --hard origin/<default>` (`bin/fm-spawn.sh`, pooled-worktree
   refresh). Either path is wrong for a workbench: one blocks, the other wipes
   the IIS identity.
3. **Every clone already has `.claude/settings.local.json`.** Upstream
   overwrites it with `cat >` at spawn (Claude busy/idle hooks) and deletes it
   at teardown (`bin/fm-spawn.sh`, `bin/fm-teardown.sh`).
4. **Workspace choice is a typed shell command.** Spawn types `treehouse get`
   into the new pane and then polls the pane's cwd until it lands in an
   isolated git top-level. Separate clones pass the isolation check; there is
   no plugin hook, but a `treehouse` shim on the worker's PATH is a clean seam.
   `treehouse` has no Windows build anyway.
5. **Teardown deletes the task branch** (`checkout --detach` + `branch -D`) and
   calls `treehouse return --force`, which a shim must absorb.
6. **Workers launch with `--dangerously-skip-permissions` by default**
   (`config/claude-permission-mode`). Unacceptable with a shared database and
   the "never run `UpdateDatabase.cmd` / restore / destructive seed without
   asking" rule.
7. **Forge seam.** PR URL parsing (`fm_pr_url_parse` in `bin/fm-pr-lib.sh`)
   plus per-provider read/poll/merge branches in `bin/fm-pr-*.sh` is how GitLab
   was added; ADO fits the same pattern. PR *creation* is done by the worker,
   not by `bin/`, so the worker can use `complete-pr`. Bootstrap hard-requires
   `gh` / `gh-axi` and needs a forge-aware exemption.
8. **Secondmates are not the fit** for the fixed clones: a secondmate is a full
   sub-orchestrator home with its own crew, and retiring one deletes its home.
9. **Instruction layering.** Worker Claude sessions still load the clone's
   `CLAUDE.md` and the user's global one; firstmate adds an
   `--append-system-prompt` trust statement plus the brief. The brief's
   definition of done ("never push", `no-mistakes`, `gh-axi`) conflicts with
   the Nexon review chain and `complete-pr`.

## Phases

### Phase 1 — Windows smoke test (no forge, no Nexon4)

- Install the essential tools (`jq`, `tasks-axi`, `quota-axi`) after approval.
- Register a small repo that needs no workbench in `local-only` mode.
- Spawn one worker through herdr from Git Bash; watch it reach done and tear
  down.
- Record every POSIX failure (`stat -c %a` mode-600 checks in
  `bin/fm-pr-lib.sh`, `ps -o`, `mkfifo`).
- **Exit decision:** native Git Bash + herdr, or move the first mate into WSL.

### Phase 2 — workbench slots

- `config/workbench-slots` (new): slot id, clone path, IIS site, URL,
  InstanceId, and the list of **workbench-local paths** (the config files
  carrying identity).
- `treehouse` shim (`bin/nexon/treehouse`, put first on the worker's PATH):
  - `get` picks a free slot by lease, `cd`s the pane into it, and prints it.
  - `return` releases the lease and never removes the directory.
- Spawn patches, active only for slot workspaces:
  - The clean-tree check ignores the declared workbench-local paths.
  - Never `reset --hard`. Instead: `git fetch`, then create the task branch
    from the base the brief names (`origin/EHR` or a release branch), carrying
    the local config edits across, and refuse if any other path is dirty.
  - Merge the busy/idle hooks into the existing `settings.local.json`
    instead of overwriting it, and restore the original at teardown.
- Teardown patches: keep the task branch while its PR is open, return the
  slot to a neutral branch the captain chooses, and never delete
  settings.local.json.
- `config/claude-permission-mode` = `auto`.
- Slot-aware brief addendum: the slot's URL and InstanceId, the shared-DB
  rules, and "verify against *your* URL".
- Occupancy: single-occupancy hosts (IntegrationEngine 8033, Licence Registry
  8001) become a named lease a worker must hold before starting one.
- First live test on one slot, then all four.

### Phase 3 — Azure DevOps forge

- `fm_pr_url_parse`: recognise
  `https://<host>/<collection>/<project>/_git/<repo>/pullrequest/<n>`.
- `fm_pr_ado_read_record`, plus poll and merge branches, via the ADO REST API
  (PAT from the environment, never written into state).
- `forge=ado` project binding, and a bootstrap exemption from `gh` / `gh-axi`.
- Definition of done for `forge=ado`: the worker runs the Nexon review chain
  and opens the PR; merging goes through `complete-pr` only on captain
  approval; `bubble` stays a separate, captain-initiated task.

### Phase 4 — instruction reconciliation

- A Nexon brief template that replaces `no-mistakes` / `gh-axi` steps with the
  CLAUDE.md step list, planning gates and review chain.
- Decide how firstmate state relates to the shared agent memory
  (`C:\Agents\memory\shared`).

## Upstream sync

`main` fast-forwards from `upstream/main`. `nexon` rebases or merges onto it.
Keep patches to upstream files small and behind a `workbench` workspace kind,
so upstream churn (hundreds of commits a month) stays mergeable.

## Open decisions

- Native Git Bash vs WSL (decided by phase 1).
- Neutral branch a slot returns to after a task (`EHR`?).
- Whether K's local `CLAUDE.md` edit and untracked files count as
  workbench-local.
- ADO authentication: PAT in an environment variable vs Git Credential
  Manager.
