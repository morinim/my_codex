---
name: handoff
description: Compact the current conversation into a handoff document for another agent to continue the work.
license: MPL-2.0
argument-hint: What will the next session be used for?
metadata:
  version: "1.0"
---

- Write a concise Markdown handoff document summarising the current conversation so a fresh agent can continue the work.
- Save the document to the temporary directory of the user's OS, not to the current workspace, unless the user explicitly requests a workspace path.
- If the user passed arguments, treat them as the focus of the next session and tailor the handoff accordingly.
- Don't duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.
- Redact any sensitive information, such as API keys, passwords, or personally identifiable information.
