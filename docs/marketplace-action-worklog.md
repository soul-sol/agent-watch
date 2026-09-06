# GitHub Marketplace action worklog

## Goal and scope

Expose the existing `worker_watch.sh` behavior as a composite GitHub Action that
acts as a completion-evidence gate. The action accepts only values already
supported by the script: worker name, numeric PID, log path, marker kind, and
exit-code file path.

The gate succeeds only for `DONE`. It fails for `RUNNING`, `FAILED`, and `STALL`
so a CI job cannot pass before completion evidence exists. It does not launch an
agent, invent a new completion marker, or make network requests.

## Acceptance and validation

- Root `action.yml` has a Marketplace-specific name, one-sentence description,
  branding, documented inputs, and documented outputs.
- README starts with a copyable workflow using `soul-sol/agent-watch@v1`.
- `.github/workflows/selftest.yml` runs the local action for both accepted and
  rejected evidence.
- YAML metadata parses, shell syntax checks pass, and local positive/negative
  gate equivalents return the expected exit codes.

## Source and ledger status

The GitHub clone attempt was blocked by sandbox DNS. Implementation used the
clean local clone whose `origin` is `https://github.com/soul-sol/agent-watch.git`
at commit `20747493cccd2312606084b82f778e8d8871df3d`. Remote freshness could not be
checked in this environment.

Project-Tree sync to `https://project-tree.lifestep.io` was attempted before
implementation and failed because DNS resolution is disabled (`http_status=000`).
This document is the required repository-local fallback record.
