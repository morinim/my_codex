# Closing The Loop

Follow-through for `execute`, `reconcile`, and `--issues`. The advisor still never edits source code.

## `execute <plan>`

Preflight:

- repo is git;
- plan exists;
- dependencies are DONE in `plans/README.md`;
- drift check passes, otherwise reconcile first.

Dispatch one `self` subagent with `Workspace` mode set to `branch`. If `Workspace` mode set to `branch` is unavailable in the environment, manually isolate the execution: create a named git worktree (`git worktree add -b <branch> <path>`), run the subagent execution context in that directory, and verify that the executor's repository root path differs from the user workspace path. Decline execution if strict workspace isolation is unavailable. Use the default model or the specified model.

Prompt must include the full plan text, because uncommitted plans may not exist in the isolated workspace, plus:

```text
You are the executor for the implementation plan below. Follow it step by step.
Run every verification command before moving on. Touch only in-scope files. Do not
improvise. Commit changes in the isolated workspace. On STOP, halt immediately and
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
| APPROVE | Criteria pass, scope clean, quality holds | Mark DONE. Tell user summary, workspace path if available, branch, notes. Do not merge/push/commit to user branch. |
| REVISE | Fixable gaps | Send specific feedback to same executor. Max two rounds. |
| BLOCK | STOP, unrecoverable scope issue, or revisions exhausted | Mark BLOCKED, refine/rewrite plan, report reason. |

Documented deviations may be acceptable. Undocumented deviations fail review.

## `reconcile`

Read index and all plans:

- DONE: spot-check cheap criteria; mark verified.
- BLOCKED: investigate; rewrite, refresh, or reject.
- stale IN PROGRESS: flag and inspect known isolated workspace.
- TODO: run basic verification (confirm referenced files exist and verification commands are still plausible from current manifests/config, resolving issues via refresh, rewrite, reject, or block depending on the cause; do not run expensive commands unless needed). For plans that pass, check for drift (first verify if `<planned-at SHA>` exists in the local git repository using `git cat-file -e <planned-at SHA>^{commit}`; if it does not exist, fallback to evaluating committed changes against the merge-base or the parent commit that does exist, otherwise check drift by evaluating committed changes using `git diff --stat <planned-at SHA>..HEAD -- <in-scope paths>` and uncommitted changes using `git diff --stat -- <in-scope paths>`). For plans with drift:

  Perform a **Tiered Reconciliation**:
  - **Tier 1 (Auto-bump)**: If snippets/files match and logic is unchanged, bump `Planned at` commit SHA to `HEAD` in-place.
  - **Tier 2 (Refresh)**: For minor/non-breaking drift (formatting, line offsets), update only affected snippets/steps in the plan.
  - **Tier 3 (Re-plan)**: If assumptions are invalidated but issue is valid, rewrite plan (status remains `TODO`).
  - **Tier 4 (Retire)**: If the issue is already resolved or superseded, mark plan `REJECTED`.

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
