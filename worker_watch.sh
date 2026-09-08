#!/usr/bin/env bash
set -u

# Usage: worker_watch.sh <name> <pid> <log> <kind> <exit-file>
# kind: codex-json | codex | other
#   codex-json : parse `codex exec --json` JSONL terminal events (most robust)
#   codex      : legacy text marker (`tokens used`) for older Codex versions
#   other      : process exit + a DONE/FAILED conclusion the agent was asked to print
# Pass through the .pid/.log/.exit left by worker_launch.sh unchanged.
# Search for markers only at the "end" of the log, because the same phrases may be echoed from documents read by the worker.
name="${1:?name required}"
pid="${2:?pid required}"
log="${3:?log required}"
kind="${4:?kind required}"
exit_file="${5:?exit-file required}"

if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
  echo "STALL $name — invalid pid record"
  exit 2
fi

if kill -0 -- "$pid" 2>/dev/null; then
  echo "RUNNING $name pid=$pid"
  exit 0
fi

if [[ ! -f "$log" ]]; then
  echo "STALL $name — log missing"
  exit 2
fi

if [[ ! -f "$exit_file" ]]; then
  echo "STALL $name — process exited but exit code is unavailable"
  tail -n 12 "$log"
  exit 2
fi

exit_code=$(tr -d '[:space:]' < "$exit_file")
if [[ ! "$exit_code" =~ ^[0-9]+$ ]]; then
  echo "STALL $name — invalid exit code record"
  tail -n 12 "$log"
  exit 2
fi

if [[ "$exit_code" != "0" ]]; then
  echo "FAILED $name — exit=$exit_code"
  tail -n 12 "$log"
  exit 2
fi

if [[ "$kind" == "codex-json" ]]; then
  # codex exec --json emits JSONL; the terminal events are authoritative.
  # Scan the tail for the last turn.* event rather than matching prose.
  last_event=$(tail -n 200 "$log" | grep -oE '"type":"turn\.(completed|failed)"' | tail -n 1)
  if [[ "$last_event" == *"turn.completed"* ]]; then
    echo "DONE $name — codex turn.completed"
    exit 0
  fi
  if [[ "$last_event" == *"turn.failed"* ]]; then
    echo "FAILED $name — codex turn.failed"
    tail -n 12 "$log"
    exit 2
  fi
  if tail -n 200 "$log" | grep -q '"type":"error"'; then
    echo "FAILED $name — codex error event"
    tail -n 12 "$log"
    exit 2
  fi
elif tail -n 40 "$log" | grep -q "FAILED"; then
  echo "FAILED $name — worker reported failure"
  tail -n 12 "$log"
  exit 2
fi

# A missing marker is not a STALL.
#
# The process exited with code 0 and printed no failure signal. That is a
# completion *candidate*: the commander still has to read the result body, but
# the watcher must not invent a stall. Requiring a tool-specific marker is what
# made an earlier version report normal GLM and agy runs as stalled, because
# `tokens used` is a Codex-only string.
#
# Markers are recorded as diagnostics and never change the disposition.
marker="none"
if [[ "$kind" == "codex-json" ]]; then
  marker="no terminal turn.* event in tail (log may be truncated)"
elif [[ "$kind" == "codex" ]] && tail -n 40 "$log" | grep -q "tokens used"; then
  marker="codex 'tokens used' seen"
elif tail -n 40 "$log" | grep -q "DONE"; then
  marker="conclusion line seen"
fi

echo "DONE $name — exit=0; read the result body before accepting (diagnostic: $marker)"
tail -n 12 "$log"
exit 0
