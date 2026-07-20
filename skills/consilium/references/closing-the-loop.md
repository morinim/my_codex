# Closing The Loop

Follow-through for `execute`, `reconcile`, and `--issues`. The advisor still never edits source code.

## `execute <plan>`

Preflight:

- repo is git;
- plan exists;
- dependencies are DONE in `plans/README.md`;
- drift check passes, otherwise reconcile first.

Provision a platform-provided isolated branch workspace. If unavailable, create a named git worktree (`git worktree add -b <branch> <path>`). Verify its absolute repository root differs from the user's checkout and record that root and branch in the plan's `Execution workspace` and `Execution branch` fields. Mark the plan `IN PROGRESS` in `plans/README.md`, then dispatch the executor there. Stop before dispatch if isolation or metadata recording fails.

Retain the execution fields after completion or failure so later reconciliation can locate the workspace.

Prompt must include the full plan text, because uncommitted plans may not exist in the isolated workspace, plus:

```text
You are the executor for the implementation plan below. Follow it step by step.
Run every verification command before moving on. Touch only in-scope files. Make
only minor in-scope adjustments needed for the planned outcome and document them.
Commit changes in the isolated workspace. On STOP, halt immediately and
report without discarding changes or deleting the branch/worktree to allow debugging.

Override: do not update plans/README.md; the reviewer maintains the index.

Before reporting, check every claim against a tool result. Say plainly if any
verification failed or was skipped.
```

Required report:

```text
STATUS: COMPLETE | STOPPED
STEPS: per step - done/skipped + verification result
STOPPED BECAUSE: only if STOPPED
FILES CHANGED: list
NOTES: deviations, surprises, judgement calls
```

Review:

1. Re-run done criteria in the isolated workspace.
2. Confirm diff touches only in-scope files.
3. Read the full diff.
4. Read new tests for meaningful assertions.

Verdicts:

| Verdict | When | Action |
|---|---|---|
| APPROVE | Criteria pass, scope clean, quality holds | Mark DONE. Tell user summary, workspace path, branch, notes. Do not merge/push/commit to user branch. |
| REVISE | Fixable gaps | Send specific feedback to same executor. Max two rounds. |
| BLOCK | STOP, unrecoverable scope issue, or revisions exhausted | Mark BLOCKED, refine/rewrite plan, report reason. |

Accept documented minor in-scope adjustments. Reject undocumented changes or any unapproved change to scope or design.

## `reconcile`

Read index and all plans:

- DONE: spot-check cheap criteria and update `Verified at` when they pass.
- BLOCKED: investigate; rewrite, refresh, or reject.
- IN PROGRESS:
  1. Read `Execution workspace` and `Execution branch` from the plan. Confirm the path exists, its repository root differs from the user's checkout, and its current branch matches the recorded branch. If either field is absent or a check fails, flag the plan as stale and report the mismatch without deleting the workspace or branch.
  2. If the workspace is valid and its executor is still active, retain `IN PROGRESS` and report its state.
  3. Otherwise inspect the workspace status, commits, full diff, available executor report, and done criteria. Mark `DONE` if review passes; mark `BLOCKED` with the failed or incomplete criteria otherwise. Retain the workspace and branch.
- TODO: confirm referenced files exist and verification commands remain plausible; avoid expensive commands unless needed. If `<planned-at SHA>` exists, check committed and uncommitted drift with the plan's commands. If it does not, compare Current State directly with live code. Then resolve any mismatch using the tiers below.

  - **Tier 1 — Auto-bump**: If Current State and logic still match, update `Planned at` to `HEAD`.
  - **Tier 2 — Refresh**: For minor non-breaking drift, update only affected evidence or steps.
  - **Tier 3 — Re-plan**: If assumptions changed but the issue remains valid, rewrite the plan and retain `TODO`.
  - **Tier 4 — Retire**: If resolved or superseded, mark the plan `REJECTED`.

Report verified, refreshed, rejected, blocked, and executable plans.

## `--issues`

Only when explicitly requested:

1. Check `gh auth status` and GitHub remote.
2. Check `gh repo view --json visibility`.
3. If public, confirm before publishing sensitive findings.
4. Confirm titles if interactive.
5. Run `gh issue create --title "<plan title>" --body-file <plan file>`.
6. Add labels only if they already work.
7. Record issue URLs in plan and index.

Plan files remain the source of truth.
