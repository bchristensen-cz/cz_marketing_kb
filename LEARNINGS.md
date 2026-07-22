# Learnings Inbox

Inbox for new gotchas, definition questions, and data-quality findings discovered during Claude sessions. Sessions record findings here instead of editing SKILL.md or the dictionaries directly — a periodic consolidation pass reviews entries, merges the vetted ones into the skills/dictionaries, pushes to GitHub, and repackages the installed skills.

## How to add a learning (merge-conflict-safe)

**Do not append to this file.** Create a **new file per finding** under `learnings/`, named `YYYY-MM-DD-short-slug.md`. One file per finding means multiple contributors never edit the same file, so concurrent pushes don't conflict.

Each file uses this format:

```markdown
# short title
- **Date:** YYYY-MM-DD
- **Area:** sales-ops-orders | braze-campaigns | data_dictionaries | sql
- **Observed by:** who / which session
- **What:** the finding, with the query or error that surfaced it
- **Proposed change:** what to add/edit in the skill or dictionary
- **Status:** proposed | merged | rejected
```

## Consolidation rules

1. One person (the steward) merges vetted entries into SKILL.md / dictionaries — canonical files change serially, through review, never mid-session.
2. On merge, set the entry's status to `merged` (or `rejected` with a one-line reason) and delete the file in the same commit that updates the skill.
3. After pushing, repackage the `.skill` zips and reinstall so live sessions pick up the change.
4. Contributors: `git pull` before a session, commit learnings individually, push promptly.
