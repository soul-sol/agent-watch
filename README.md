# agent-watch

**Is your background AI agent done, failed, or just stuck?** Two small POSIX shell scripts that answer that question honestly.

When you run coding agents in the background (`codex exec`, `claude -p`, `gemini`, or any CLI), the hard part is not starting them — it's knowing what happened. A worker that silently stopped to wait for approval looks exactly like a worker that is still thinking. A worker that crashed looks exactly like a worker that finished, if you only check that the process is gone.

`agent-watch` distinguishes four states — **RUNNING / DONE / FAILED / STALL** — using the only signals that don't lie: the process, the recorded exit code, and a completion marker read from the *tail* of the log.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/soul-sol/agent-watch/main/worker_launch.sh
curl -fsSLO https://raw.githubusercontent.com/soul-sol/agent-watch/main/worker_watch.sh
chmod +x worker_launch.sh worker_watch.sh
```

No dependencies beyond a POSIX shell and coreutils.

## Use

```bash
# 1. launch a worker in the background — records .log, .pid and .exit
./worker_launch.sh api_task ./logs -- codex exec --skip-git-repo-check -C "$PWD" \
  -m <MODEL> -s workspace-write "TASK: fix the billing status mapping. VERIFY: npm test -- billing. REPORT: end with DONE: <summary>."

# 2. ask what happened, any time
./worker_watch.sh api_task "$(cat logs/api_task.pid)" logs/api_task.log codex logs/api_task.exit
```

Output is one of:

```
RUNNING api_task pid=41233
DONE api_task — codex marker found
FAILED api_task — exit=1
STALL api_task — process exited without a completion conclusion
```

`STALL` is the state everyone else misses: the process is gone, the exit code is 0, and yet the worker never actually concluded — it stopped to ask a question, or died mid-thought. Treat it as "not done", relaunch with an explicit autonomy instruction, and you stop losing hours to workers that were never running.

## Why the details matter

- **Exit code is recorded to a file, not inferred.** A background process's status is gone the moment you stop waiting for it; `worker_launch.sh` writes `$?` to `<name>.exit` so the watcher can tell a clean exit from an error exit later.
- **Markers are read from the log tail only.** If your worker read a document that mentions the completion marker, it can echo that string mid-run. Matching anywhere in the file gives you a false DONE; matching in the last 40 lines does not.
- **Completion markers differ per tool.** `codex` prints a token-usage line when it finishes normally; other CLIs don't. Pass `codex` or `other` as the `kind` argument and the watcher applies the right rule — never generalize one tool's marker to another.
- **No long sleep loops.** The watcher answers once and exits, so you can call it from a poll, a Makefile, or another agent without holding a process open.

## Multi-worker board

```bash
for w in api ui migration; do
  ./worker_watch.sh "$w" "$(cat logs/$w.pid)" "logs/$w.log" other "logs/$w.exit"
done
```

Run that after every wave and you always know which worker to re-dispatch.

## Where this comes from

These scripts are the operational core of [*Solo, Like a Team — Claude Code Multi-Agent Orchestration in Practice*](https://lifestep1.gumroad.com/l/solo-like-a-team-claude-code-orchestration), a field manual for running one Claude Code session as the commander of a parallel worker pool. The book explains the incidents these rules came from — including the day a worker sat waiting for approval while its commander reported success.

Related free resources:
- [claude-code-orchestration-ko](https://github.com/soul-sol/claude-code-orchestration-ko) — Korean guide + full template set (briefs, review gate, safety denylist)
- [ai-code-review-prompts](https://github.com/soul-sol/ai-code-review-prompts) — adversarial review prompts for AI-written code

## License

MIT.
