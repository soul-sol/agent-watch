#!/usr/bin/env bash
# Usage: worker_launch.sh <name> <logdir> -- <command...>
# Starts a worker in the background and leaves <logdir>/<name>.log, .pid, and .exit.
# Example: worker_launch.sh sol_a ./logs -- codex exec --skip-git-repo-check -C "$PWD" -m gpt-5.6-sol -s workspace-write "instruction"
set -u
name="${1:?name required}"; logdir="${2:?logdir required}"; shift 2
[[ "${1:-}" == "--" ]] && shift
mkdir -p "$logdir"
log="$logdir/$name.log"; pidf="$logdir/$name.pid"; exitf="$logdir/$name.exit"
rm -f "$exitf"
(
  "$@" > "$log" 2>&1
  echo $? > "$exitf"
) &
echo $! > "$pidf"
echo "LAUNCHED $name pid=$(cat "$pidf") log=$log"
