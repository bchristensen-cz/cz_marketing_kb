# Client setup — one-time, per user

You do **not** need to know git, SQL, or BigQuery. Claude does all of that. This page is a one-time setup you do once, then forget.

Total time: about five minutes.

Do **not** install the skills as `.skill` packages, mount a personal clone of this repo, fork it, or create your own data project with a copy of the instructions. The shared **Analysis** project plus a fresh pull of this KB every session is the only supported way to consume it — it's what guarantees everyone gets the same answer.

---

## Where you can ask data questions

Every session pulls a fresh copy of the knowledge base. In Cowork mode that happens with `git clone`; everywhere else Claude fetches the raw files straight from GitHub. Both paths are pull-based and always current.

| Where you're using Claude | Data questions work? | How the KB arrives |
|---|---|---|
| **Cowork mode, desktop app** | ✅ Yes | `git clone` (verified 2026-07-29) |
| **Regular chat, desktop app** | ✅ Yes | raw-file fetch (verified 2026-08-04) |
| **claude.ai in a web browser** | ✅ Yes | raw-file fetch (verified 2026-08-04) |
| Claude on mobile | ❓ Not yet verified | raw-file fetch — don't rely on it until the steward confirms |

**What failure looks like:** Claude tells you the knowledge base is unavailable and that it can't answer data questions. That is Claude working *correctly* — it's refusing to guess rather than answer from memory. It usually means GitHub couldn't be reached, or you're on mobile. It is never a reason to ask Claude to answer anyway.

You can still use Claude anywhere for ordinary work — writing, brainstorming, summarizing. The rules here apply only to Cafe Zupas data questions.

---

## Step 0 — Authorize your connectors first

Claude reaches company data through **connectors**. If these aren't authorized, every data question fails in a way that looks like "Claude is broken" but isn't.

You need two:

| Connector | What it's for |
|---|---|
| **BigQuery** (Google Cloud) | Running the actual queries. Required. |
| **Asana** | Logging knowledge-base findings to the Claude Data board. Required. |

Authorize them in your Claude connector settings and complete the Google sign-in prompt. **What failure looks like:** Claude says a server "requires authentication," or that it can't reach BigQuery, or it answers a data question without ever showing you SQL. If you see any of those, come back to this step — don't retry the question.

Ask Brent if you don't have BigQuery access yet; it's granted per-person.

---

## Step 1 — Join the shared "Analysis" project

Ask the data steward (Brent) for an invite to the company-wide **Analysis** project, and accept it.

That project's instructions carry the full knowledge-base protocol, maintained centrally by the steward. You don't paste anything, and you must not create a personal copy of the project — a personal copy freezes whatever the instructions said the day you made it, and stale instructions are how two people end up with different answers to the same question.

---

## Step 2 — Paste the global backstop

The Analysis project protects chats **inside** it. This step protects everything else.

Go to **Settings → General → "Instructions for Claude"** and add the block below (keep anything already there). This applies to every chat you ever start — so if you forget to open the project, the guardrails still hold.

```
# Cafe Zupas company data

For any question about Cafe Zupas business data — sales, orders, customers,
menu, items, stores, campaigns, Braze, BigQuery — the only approved source
of query logic is the knowledge base at:
https://github.com/bchristensen-cz/cz_marketing_kb

Get a fresh copy each session: git clone --depth 1 if you have a shell,
otherwise fetch the raw files from
https://raw.githubusercontent.com/bchristensen-cz/cz_marketing_kb/main/
(README.md first). Follow its README and the relevant skill in
claude_skills/ verbatim. State the KB version in your first data answer.

Never answer these questions from general knowledge, from memory of a past
session, or from a saved copy. Never guess table or column names. If you
can neither clone nor fetch the knowledge base, say so and stop — do not
query BigQuery.

This applies only to Cafe Zupas data questions; ignore it otherwise.
```

This is intentionally a **backstop, not a duplicate**. It names the repo and enforces the refusal, then hands off to the fresh pull for all real logic. Don't paste the full protocol here — two copies of the same rules will eventually drift and produce inconsistent answers that are very hard to diagnose. The full protocol lives in the Analysis project and in this repo.

It's also deliberately conditional ("only Cafe Zupas data questions"). Without that line it would fire on unrelated work — drafting an email, brainstorming a campaign name — and Claude would start pulling repositories for no reason.

---

## Step 3 — Always ask data questions inside the Analysis project

Even with the Step 2 backstop, the project is where the full protocol lives. Habit: **open the Analysis project, then ask.** Cowork or regular chat both work.

If you catch yourself in a plain chat, use the chat's dropdown → **Add to project** to move it into Analysis, then re-ask your question.

---

## Step 4 — Verify it's working

Run these three checks once, in order. They take a couple of minutes and catch every common setup mistake.

### Check 1 — the project path

Inside the Analysis project, ask:

> sales for ultimate grilled cheese from May 3rd to June 27th

**Pass:** Claude mentions a knowledge-base version (a short commit hash like `4098868`), then **asks you clarifying questions before querying** — the date range, whether to include catering, whether to include items sold inside Try 2 Combos, and which exact product names you mean. (In Cowork the choices arrive as clickable options; in regular chat they're plain-text questions. Both are correct.) SQL is shown when it eventually runs.

**Fail:** an immediate number with no questions, no commit hash, or no SQL. You're probably not inside the Analysis project — move the chat there and re-ask. If it still fails *inside* the project, tell the steward: the project's instructions may have been changed.

**Fail, different cause:** Claude says the knowledge base is unavailable. GitHub may be unreachable, or you're on a surface that isn't supported yet (see the table at the top).

Being asked questions instead of handed a number is the system working as designed. Those questions exist because each one has produced a materially wrong answer before — combos alone can swing an item number by ~3.5x.

### Check 2 — the backstop path

Start a **brand-new chat outside any project** and ask the same question.

**Pass:** Claude still pulls the knowledge base and still refuses to answer from general knowledge. It may be a little less thorough than inside the project, but it must not invent table names or produce a bare number.

**Fail:** Claude answers straight away, or names tables without pulling anything. The global instructions didn't take — recheck Step 2.

### Check 3 — the backstop stays quiet

In that same non-project chat, ask something unrelated:

> write me a short thank-you note to a vendor

**Pass:** you get a thank-you note, with no mention of BigQuery, git, or the knowledge base.

**Fail:** Claude tries to pull the repo or brings up data tooling. The conditional line at the end of the Step 2 block is missing or was edited — re-paste it exactly.

---

## When you find something wrong or missing

Don't edit the repo — only the data steward (Brent) commits to it. Ask Claude to log an Asana task on the **Claude Data** board titled `KB finding: <short title>`, and it'll write up what it observed. Brent reviews and merges it, and everyone's next session picks it up automatically.

---

## For the steward — the canonical project-instructions snippet

Users never paste this. It lives in the shared **Analysis** project's instruction box, deployed by the steward; the canonical copy is kept here so git stays the source of truth. **A repo commit does not update the project's instruction box** — if this block ever changes, re-paste it into the project the same day. It is deliberately tiny and pointing-only (all real logic lives in the repo and arrives via the fresh pull), so it should almost never change.

```
# Cafe Zupas data — knowledge base protocol

Before answering ANY question about company data (sales, orders, customers,
menu, items, stores, campaigns, Braze, BigQuery):

1. Get a fresh copy of the knowledge base — every session, even if a copy
   already exists:
   - If you have a shell (Cowork): delete any older copy, then
     git clone --depth 1 https://github.com/bchristensen-cz/cz_marketing_kb
     into your temporary working area, never into my personal folders.
   - If you have no shell (regular chat): fetch the raw files from
     https://raw.githubusercontent.com/bchristensen-cz/cz_marketing_kb/main/
     starting with README.md.
2. Read README.md from that fresh copy and follow its session protocol,
   then read the relevant skill in claude_skills/ and the data dictionaries
   it references. Follow the skills verbatim (canonical definitions, the
   pre-query clarification protocol, partition filters).
3. Never answer from installed skills, saved copies, forks, or memory of a
   previous session. The fresh copy is the single source of truth.
4. State the KB version in the first data answer of the session:
   git log -1 --format='%h %ad' with a shell, or fetch
   https://api.github.com/repos/bchristensen-cz/cz_marketing_kb/commits/main
   and report the short sha and commit date.
5. Never commit, push, or edit the knowledge base. New findings are logged
   per the README's ground rules (Asana task on the Claude Data board).
6. If you can neither clone nor fetch the knowledge base, STOP. Tell me the
   knowledge base is unavailable and that you can't answer data questions
   without it. Do not answer from general knowledge, do not guess table or
   column names, and do not query BigQuery. A failed pull is a hard stop,
   not a reason to improvise.
7. Always show me the SQL.
```
