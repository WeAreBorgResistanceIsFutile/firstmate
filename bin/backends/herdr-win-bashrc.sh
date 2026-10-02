# shellcheck shell=bash
# Nexon fork: rcfile for the Git Bash that runs inside a herdr task pane on
# Windows. Started by fm_backend_herdr_windows_shell_prepare in herdr.sh.
# shellcheck source=/dev/null
[ -f ~/.bashrc ] && . ~/.bashrc
# Herdr's Windows build learns a pane's directory only from OSC 9;9, which it
# injects into its PowerShell prompt; a child bash has to emit it itself.
# Exported so a nested interactive shell (a task's worktree subshell) keeps
# reporting.
export PROMPT_COMMAND='printf "\033]9;9;%s\033\\" "$(cygpath -w "$PWD")"'
printf 'FM_HERDR_WIN_BASH_READY\n'
