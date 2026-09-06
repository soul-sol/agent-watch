# agent-watch

## GitHub Actions completion gate

Copy this workflow and replace the prompt with the task your Codex worker should
complete. The final gate accepts only a recorded zero exit code plus Codex's
structured `turn.completed` event.

```yaml
name: Verify agent completion

on:
  pull_request:

permissions:
  contents: read

jobs:
  agent-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Codex CLI
        run: npm install --global @openai/codex

      - id: worker
        name: Run worker and record durable evidence
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        shell: bash
        run: |
          mkdir -p .agent-watch
          set +e
          codex exec --json --skip-git-repo-check -C "$PWD" \
            "Run the requested checks and finish the task." \
            > .agent-watch/pr-check.log 2>&1 &
          pid=$!
          printf 'pid=%s\n' "$pid" >> "$GITHUB_OUTPUT"
          wait "$pid"
          printf '%s\n' "$?" > .agent-watch/pr-check.exit

      - name: Require completion evidence
        uses: soul-sol/agent-watch@v1
        with:
          name: pr-check
          pid: ${{ steps.worker.outputs.pid }}
          log: .agent-watch/pr-check.log
          kind: codex-json
          exit_file: .agent-watch/pr-check.exit
```

The action exposes `status`, `summary`, and `watch_exit_code` outputs. Unlike the
one-shot watcher, the CI gate treats `RUNNING` as a failure because completion
has not yet been proven.

**Is your background AI agent done, failed, or just stuck?** Two small POSIX shell scripts that answer that question honestly.

When you run coding agents in the background (`codex exec`, `claude -p`, `gemini`, or any CLI), the hard part is not starting them — it's knowing what happened. A worker that silently stopped to wait for approval looks exactly like a worker that is still thinking. A worker that crashed looks exactly like a worker that finished, if you only check that the process is gone.

`agent-watch` distinguishes four states — **RUNNING / DONE / FAILED / STALL** — using the only signals that don't lie: the process, the recorded exit code, and a completion marker read from the *tail* of the log.

> These scripts came out of running Claude Code and Codex workers in parallel every day.
> The incidents behind them — what the agent claimed, what actually happened, and the gate
> that catches it next time — are written up at
> [status.lifestep.io/incidents](https://status.lifestep.io/incidents/).
> The full rule set is [The CLAUDE.md Pattern Library](https://lifestep1.gumroad.com/l/claude-md-pattern-library) ($9);
> these scripts stay free and MIT either way.

## Preflight: is it the network, or the credential?

A sandboxed worker that cannot resolve DNS and a worker with a bad token fail in ways
that look almost identical once a tool re-words the error. `gh` reporting a resolution
failure reads close enough to an auth problem that a model will confidently report the
wrong cause and stop.

`worker_preflight.sh` classifies the transport layer before the worker starts, so the
agent never has to infer that distinction from tool wording.

```bash
./worker_preflight.sh              # transport only
./worker_preflight.sh --auth       # transport, then credentials if reachable
./worker_preflight.sh --host example.com --api https://example.com/health
```

| Output | Exit | Meaning |
|---|---:|---|
| `NET_DISABLED` | 3 | DNS or transport failed. Not a credential problem. |
| `API_UNAVAILABLE` | 4 | Host reachable, endpoint is not. A proxy allowlist missing this host looks exactly like this. |
| `NET_OK` | 0 | Transport proven. |
| `AUTH_OK` | 0 | Transport proven, then credentials accepted. |
| `AUTH_FAILED` | 5 | Transport proven, so a credential conclusion is finally safe to draw. |

Two rules it follows:

1. **The transport probes run with no credential in the child process.** Re-injecting a
   known-good token before proving reachability does not distinguish auth from DNS, and it
   widens the set of processes that can read the token. The parent environment is untouched.
2. **The auth probe runs only after transport is proven**, and only when you ask for it.

Nothing prints an environment value — states are printed, secrets are not.

On Codex specifically, `workspace-write` starts with network disabled. Enabling
`sandbox_workspace_write.network_access` without a proxy gives broad egress; domain rules do
not grant access by themselves. If a worker only needs one API, a proxy allowlist for those
exact endpoints is narrower than opening egress wholesale.

Credit: this separation was suggested by [@ooocooc](https://github.com/ooocooc) in
[openai/codex#42402](https://github.com/openai/codex/discussions/42402).


## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/soul-sol/agent-watch/main/worker_launch.sh
curl -fsSLO https://raw.githubusercontent.com/soul-sol/agent-watch/main/worker_watch.sh
curl -fsSLO https://raw.githubusercontent.com/soul-sol/agent-watch/main/worker_preflight.sh
chmod +x worker_launch.sh worker_watch.sh worker_preflight.sh
```

No dependencies beyond a POSIX shell and coreutils.

## Use

```bash
# 1. launch a worker in the background — records .log, .pid and .exit
./worker_launch.sh api_task ./logs -- codex exec --json --skip-git-repo-check -C "$PWD" \
  -m <MODEL> -s workspace-write "TASK: fix the billing status mapping. VERIFY: npm test -- billing. REPORT: end with DONE: <summary>."

# 2. ask what happened, any time
./worker_watch.sh api_task "$(cat logs/api_task.pid)" logs/api_task.log codex-json logs/api_task.exit
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
- **Prefer structured events when the tool has them.** `codex exec --json` emits JSONL where `turn.completed` / `turn.failed` are authoritative terminal events. Pass `codex-json` as the `kind` and the watcher reads those instead of matching prose — no false DONE when a retrieved document happens to contain a completion phrase. The text marker stays available as `codex` for older versions.
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

<!-- xlink:start -->
## Related free tools

- [XLSX Inspector](https://xlsx.lifestep.io) — check workbooks for macros, external links and hidden sheets
- [DNS and SPF Check](https://dnscheck.lifestep.io) — records, SPF, DMARC and TLS expiry
- [Email Validator](https://emailcheck.lifestep.io) — syntax, MX, disposable and role addresses
- [QR Code Generator](https://qrcode.lifestep.io) — free PNG and SVG API, no signup
- [ai-code-review-prompts](https://github.com/soul-sol/ai-code-review-prompts)
- [claude-md-patterns](https://github.com/soul-sol/claude-md-patterns)
- [claude-code-orchestration-ko](https://github.com/soul-sol/claude-code-orchestration-ko)
- [xlsx-inspector-api](https://github.com/soul-sol/xlsx-inspector-api)
- [domain-info-api](https://github.com/soul-sol/domain-info-api)
- [email-validator-api](https://github.com/soul-sol/email-validator-api)
- [qr-code-api](https://github.com/soul-sol/qr-code-api)

The paid guide collection is available at [lifestep1.gumroad.com](https://lifestep1.gumroad.com).
<!-- xlink:end -->
