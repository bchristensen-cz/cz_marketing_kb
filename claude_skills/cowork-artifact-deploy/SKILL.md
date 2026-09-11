---
name: cowork-artifact-deploy
description: How to change and redeploy a Cowork artifact (item-sales-builder, journey-to-2-4dx, discount-intelligence) — the two-file deployed/template lineage, the deployed-vs-repo diff that catches drift, which sessions can actually write artifacts, and the BigQuery connector re-grant that every update clears. Use whenever an artifact's HTML, SQL, meta block or description changes, when an artifact "loads but can't query", or when a redeploy comes back blocked.
---

# Deploying a Cowork artifact

> **Freshness check:** this file must come from a clone of
> `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**.
> If you're reading it from an installed skill package, a fork, or any saved copy, stop
> and re-clone first — it may be stale.

Artifacts in scope: `item-sales-builder`, `journey-to-2-4dx`, `discount-intelligence`,
and anything else under `artifacts/` in this repo.

Every artifact exists as **two files that must move together**:

| File | Path | Distinguishing marks |
|---|---|---|
| **Template** (committed) | `artifacts/<id>.html` | `const TOOL='__BQ_TOOL__'`; **no** meta block |
| **Deploy lineage** (shipped) | `scripts/tmp/<id>.deploy.html` | resolved `const TOOL='mcp__<uuid>__execute_sql_readonly'`; meta block at line 1 |

The deploy file is the template plus exactly two additions, nothing else. For
`item-sales-builder` as of 2026-09-11 that is 36,346 → 37,038 bytes, and the `const TOOL`
line moves 185 → 193: an 8-line meta block plus a longer resolved tool id. If your delta
looks different, something else changed — go to §2.

## 0. THREE artifact stores — never cross them

1. **Cowork desktop artifacts.** `item-sales-builder` et al. Live in the desktop app's
   internal storage, **not** as a file on disk. Written only by `update_artifact` /
   `create_artifact` / `list_artifacts` in a **Cowork** session.
2. **Chat artifacts.** A desktop **Chat** session has artifact tools too, but they write
   to a different store. A Chat session cannot update a Cowork artifact — it will happily
   create a near-identical copy instead (see §1).
3. **claude.ai Artifacts.** The top-level `Artifact` tool, reachable from cloud sessions.
   A separate store again, with its own `claude.ai/code/artifact/<uuid>` URLs.

**No session can write across these boundaries.** Having artifact tools is not the same as
being able to reach *this* artifact — always confirm the tool can see the target id before
trusting it, and treat a successful "create" as a red flag when you asked for an update.

`Artifact action=list` does **not** return `item-sales-builder`. If the Cowork tools are
missing, **do not** "solve" it by publishing the HTML through the `Artifact` tool. That
creates a duplicate at a new URL, leaves the real artifact stale, and splits the lineage
permanently. A blocked redeploy is a handoff (§6), never a substitute tool.

## 1. Preflight — can this session write artifacts at all?

Check for `update_artifact` **before** doing any work. If it isn't there, `RefreshMcpTools`
will not conjure it (verified 2026-09-09, 09-10, 09-11) and neither will any permission:
no folder grant, connector grant, or admin setting exposes these tools. Don't hunt for a
setting and don't spend turns on it.

Sessions that reach the machine through the remote-devices bridge (85–87 tools: shell,
Filesystem, Desktop Commander, Windows-MCP, Braze, browser) have **not** had the artifact
tools on any attempt since 2026-09-09.

**There is no user-facing control for this.** Verified 2026-09-11 on desktop app
`1.52386.0`: the Cowork new-task screen offers only Chat/Cowork, "Project or folder",
permission mode (Auto) and the model picker. No cloud/local, machine, or execution-location
selector exists. Starting the task fresh from the desktop app produces another bridged
session — tried 2026-09-11, 85 tools, no artifact API. **Do not tell Brent to look for a
setting; there isn't one.** The last confirmed successful `update_artifact` was
**2026-08-21**, so treat this as an app-side change, not a misconfiguration.

**Chat mode is NOT the workaround — tested 2026-09-11, and it makes things worse.** A
Chat session *does* have artifact tools, so the capability is gated on the Chat/Cowork
toggle. But those tools write to the **chat artifact store**, not the Cowork one. Handed
the §6 one-liner, the Chat session read the deploy file, reproduced it byte-for-byte
(SHA256 `9a1a2308…913498`, 37,038 bytes) — and created a **brand-new chat artifact**,
leaving the real Cowork `item-sales-builder` untouched and stale. That is exactly the
duplicate-lineage failure §0 forbids, arrived at from the other direction.

So the two-store rule has a third corner: **Chat artifacts, Cowork artifacts, and
claude.ai Artifacts are three separate stores, and no session can write across them.**
Being able to create an artifact is not being able to update *that* artifact. Delete any
chat-store duplicate as soon as it appears — a stale copy that looks correct is worse than
no copy.

So: if the tools are absent, go straight to §6 and hand off. Do the §2–3 work anyway —
the diff and the two edited files are exactly what the handoff consumes.

## 2. Diff deployed vs repo BEFORE changing anything

The repo and the deployed artifact drift **both ways**, same as scheduled queries. Never
assume `artifacts/<id>.html` is what's live.

Stage the live HTML and compare:

```
device_stage_files(artifact_ids=['<id>'])
# → /mnt/user-data/uploads/cowork-artifacts/<id>/index.html
```

(this read works from a bridged session even when the write doesn't)

Exactly **two** differences are legitimate:

1. an injected `<script type="application/json" id="cowork-artifact-meta">` block near
   the top — `name`, `description`, `mcpTools`, `mcpServerNames`
2. `const TOOL='__BQ_TOOL__'` in the repo, resolved to
   `const TOOL='mcp__<server-uuid>__execute_sql_readonly'` in the deployed copy

**Anything else is real drift and must be reconciled before shipping.** Found 2026-09-09:
the repo had silently dropped the `store_id not in (1111, 999)` predicate that both
`claude` views apply, and reworded the steward-rules sentence — never redeployed. The meta
block's `description` was also still carrying the retired "week ending Saturday" wording.

**The meta block is content.** Its `description` is what users read in the artifact list.
When a definition changes (week-ending rule, catering split, measure names), the meta
`description` needs the same edit as the page body. Reviewing only the `<body>` misses it.

## 3. Apply identical edits to BOTH files

Build the deploy file **from the currently deployed HTML**, not from the repo template —
that preserves the resolved tool id and today's working state. Then apply the same edit to
the template.

> ⚠️ **Never use `Get-Content -Raw` / `Set-Content -Encoding UTF8` on these files.**
> Windows PowerShell 5.1 reads UTF-8 as ANSI and re-encodes on write, silently
> double-encoding every em dash and arrow and prepending a BOM. Verified 2026-09-11:
> that round-trip turned 80 non-ASCII bytes into 201 and grew the file 37,038 → 37,159
> while `Compare-Object` still reported the lines identical — the corruption is invisible
> to a line diff. Use `[IO.File]::ReadAllText/WriteAllText` with an explicit
> `UTF8Encoding($false)`. The repo is LF; `WriteAllText` preserves it.

```powershell
# regenerate the deploy-lineage file from the repo template after editing it
$id   = 'item-sales-builder'
$repo = 'C:\dev\cz_marketing_kb'
$enc  = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM
$livePath = "$repo\scripts\tmp\$id.deploy.html"

# carry forward the meta block + resolved tool id from the live copy
$live = [IO.File]::ReadAllText($livePath, [Text.Encoding]::UTF8)
$meta = [regex]::Match($live, '(?s)^.*?</script>\r?\n').Value
$tool = [regex]::Match($live, "const TOOL='([^']+)'").Groups[1].Value

$tpl  = [IO.File]::ReadAllText("$repo\artifacts\$id.html", [Text.Encoding]::UTF8)
$out  = $meta + (($tpl -replace '(?s)^<!DOCTYPE html>\r?\n?', '') -replace '__BQ_TOOL__', $tool)
[IO.File]::WriteAllText($livePath, $out, $enc)
```

Round-trip check — rebuilding from an unchanged template must be **byte**-identical to the
live copy (verified 2026-09-11 on `item-sales-builder`: 37,038 bytes, 80 non-ASCII, exact).
Compare bytes, not lines:

```powershell
$a=[IO.File]::ReadAllBytes($rebuilt); $b=[IO.File]::ReadAllBytes($livePath)
"non-ascii: $(($a|?{$_ -gt 127}).Count) vs $(($b|?{$_ -gt 127}).Count)"
"identical: $(-not (Compare-Object $a $b))"
```

Sanity-check before shipping — the deploy file must have **no** `__BQ_TOOL__` left and
**exactly one** meta block:

```powershell
Select-String "$repo\scripts\tmp\$id.deploy.html" -Pattern '__BQ_TOOL__','cowork-artifact-meta','const TOOL'
```

**Editing the repo copy alone is drift.** A fix to `artifacts/*.html` only counts once
it's redeployed. Fix and redeploy in the same pass, or log it as pending in the CLAUDE.md
backlog — never leave it implicit.

## 4. Deploy, then commit

Hand the **deploy-lineage** file to `update_artifact` as-is. Commit the **template** plus
the same edits. Both, same pass.

## 5. Re-grant the BigQuery connector — every single time

**An update clears the artifact's connector grants.** The page then loads normally and
every query fails. The meta block ships with `"mcpTools": []` / `"mcpServerNames": []`;
re-granting BigQuery in the desktop UI is what repopulates it.

Say this in the **same message** as the redeploy, before the user goes looking. An
artifact that "loads but returns nothing" after a deploy is this, not a SQL bug — check
the grant before debugging the query.

## 6. Blocked-session handoff

When `update_artifact` is absent, do everything except the deploy:

1. Run §2 and §3 — reconcile drift, produce both edited files
2. Leave the deploy file at `C:\dev\cz_marketing_kb\scripts\tmp\<id>.deploy.html`
3. Commit the template
4. Hand Brent this one-liner for a session that has the tools:

> Update the Cowork artifact `<id>` in place with the contents of
> `C:\dev\cz_marketing_kb\scripts\tmp\<id>.deploy.html` — use it exactly as-is.
> Don't edit anything.

5. Remind him about §5

Don't re-litigate the missing tool, and don't offer the claude.ai `Artifact` tool as a
substitute (§0).

## 7. Verify without a browser

The artifact can't be opened from a bridged session, so verify statically:

```powershell
# JS parses?
node --check <extracted script block>
# emitted SQL is valid and cheap?  run it dry-run through BigQuery
```

Extract the `<script>` blocks, `node --check` each one, then run the SQL the generator
emits through BigQuery as a dry run. That catches the two failure modes that actually
ship: a syntax error that blanks the page, and a query that references a dropped column.

Cross-check any metric definition the artifact hard-codes against
[`sales-ops-orders`](../sales-ops-orders/SKILL.md) — the artifact is a *consumer* of those
definitions and must not invent its own. `is_catering` in particular has drifted three
times; derive, don't restate.

## Checklist

- [ ] §1 preflight — `update_artifact` present, or handoff planned
- [ ] §2 deployed-vs-repo diff clean (only meta block + resolved tool id)
- [ ] meta `description` reviewed alongside the body
- [ ] §3 both files edited identically; no `__BQ_TOOL__` in the deploy file
- [ ] §3 encoding — rebuilt file has the **same non-ASCII byte count**, no BOM (never `Set-Content -Encoding UTF8`)
- [ ] §7 `node --check` clean; emitted SQL dry-runs
- [ ] deployed **and** template committed in the same pass
- [ ] §5 connector re-grant stated in the same message
