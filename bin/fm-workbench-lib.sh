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
