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
elif [[ "$kind" == "codex" ]]; then
  if tail -n 40 "$log" | grep -q "tokens used"; then
    echo "DONE $name — codex marker found"
    exit 0
  fi
else
  if tail -n 40 "$log" | grep -q "DONE"; then
    echo "DONE $name — exit=0 and conclusion found; inspect result body"
    tail -n 12 "$log"
    exit 0
  fi
  if tail -n 40 "$log" | grep -q "FAILED"; then
    echo "FAILED $name — worker reported failure"
    tail -n 12 "$log"
    exit 2
  fi
fi

echo "STALL $name — process exited without a completion conclusion"
tail -n 12 "$log"
exit 2
