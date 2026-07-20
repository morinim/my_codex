# Audit playbook

A finding needs evidence. Speculation is not a finding.

## 1. Bug

Look for proven failure modes: swallowed errors, async/race issues, unsafe null or boundary handling, unhandled states, non-atomic writes, retry/idempotency bugs, repeated type-safety bypasses, and resource leaks.

## 2. Security

Report only code-backed defensive findings. Do not include runnable exploit details. Never copy secrets; cite credential type and `file:line`, then recommend removal and rotating exposed credentials.

Do not flag standard conventions or ADR-backed tradeoffs unless the implementation adds risk or the code has drifted.

Check credential handling, injection/path traversal risks, auth/authz, request validation, file uploads, dependency advisories, production config, cookies, and sensitive logs/errors.

## 3. Perf

Prefer structural wins over micro-optimisations: repeated work, poor complexity, unbounded inputs, avoidable serialisation, inefficient I/O, excessive allocation/copying, missing reuse/caching, deferrable work on critical paths, and slow verification loops.

## 4. Tests

Find risky untested behaviour: critical paths, state changes, core workflows, high-churn modules, weak or flaky tests, missing boundary coverage, and no one-command verification.

## 5. Tech-debt

Flag debt with maintenance cost: duplication, layering violations, circular dependencies, overly broad modules, dead code, stale flags, unused dependencies, oversized components, deep conditionals, inconsistent patterns, and poor abstraction boundaries.

## 6. Migration

Flag only meaningful migration pressure: unsupported platforms or runtimes, deprecated APIs with removal timelines, abandoned critical dependencies, duplicate capabilities, dependency/configuration drift, and migrations with clear blast radius.

## 7. DX

Look for broken feedback loops: missing static checks or formatting, weak local automation, slow build/test/review cycles, wrong setup docs, undocumented configuration, missing local-setting examples, missing agent instructions, and poor diagnostics.

## 8. Docs

Low priority unless cost is concrete: public APIs without docs, active architecture with no decision record, setup/API docs that are wrong.

## 9. Direction

Suggestions must be grounded in repo evidence. Generic ideas are noise.

Signals: repeated TODO/FIXME themes, stubs, stale flags, abandoned work, documented goals not reflected in implementation, no-op interfaces or configuration, asymmetric capabilities, architecture that makes an improvement unusually cheap, and manual workflows visible in docs, examples, or issues.

Direction impact is user, maintainer, or project value. Confidence is strength of grounding. Plans are usually design/spike plans.

## Finding Format

```markdown
### [CATEGORY-NN] Short imperative title

- **Evidence**: `path/file.ext:123` - what is present. Use 2-5 strongest sites.
- **Impact**: Concrete cost or failure mode.
- **Effort**: S | M | L, including tests.
- **Risk**: LOW | MED | HIGH, with why.
- **Confidence**: HIGH | MED | LOW. LOW usually becomes investigation.
- **Fix sketch**: 1-3 sentences, not a plan.
```

## Prioritisation

Rank by impact / effort, discounted by confidence and fix risk. Raise verification baselines, prerequisite tests, high-confidence security, and findings with clean verification. "Not worth doing" is valid; record why.
