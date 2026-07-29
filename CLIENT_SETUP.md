# Client setup — one-time, per user

You do **not** need to know git, SQL, or BigQuery. Claude does all of that. This page is a one-time setup you do once, then forget.

Total time: about five minutes.

Do **not** install the skills as `.skill` packages, mount a personal clone of this repo, or fork it. The fresh-clone-per-session protocol is the only supported way to consume this KB — it's what guarantees everyone gets the same answer.

---

## Before you start — you must use Cowork mode on the Claude desktop app

**This is a hard requirement, not a preference.** Data questions only work in **Cowork mode in the Claude desktop app**.

Here's why. Every session pulls a fresh copy of the knowledge base with `git clone`, and that needs a working shell. Cowork mode has one built in. The other places you can use Claude don't:

| Where you're using Claude | Data questions work? |
|---|---|
| **Cowork mode, desktop app** | ✅ Yes — the only supported surface |
| Regular chat in the desktop app | ❌ No shell, so the clone fails |
| claude.ai in a web browser | ❌ No shell, so the clone fails |
| Claude on mobile | ❌ No shell, so the clone fails |

**What failure looks like:** Claude tells you the knowledge base is unavailable and that it can't answer data questions. That is Claude working *correctly* — it's refusing to guess. It is not a bug, and there is no workaround to ask for. Open Cowork mode on the desktop app and ask again.

You can still use Claude anywhere for ordinary work — writing, brainstorming, summarizing. The restriction applies only to Cafe Zupas data questions.

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

## Step 1 — Create a project

In the Claude **desktop app**, go to **Projects → + New Project**. Name it something like `Cafe Zupas Data`.

Note: Claude cannot see the project's name or description, so don't put instructions there — they go in Step 2.

---

## Step 2 — Paste the project instructions

Open your new project, click **Set project instructions**, and paste everything in the box below. Save.

This snippet is deliberately tiny and stable. All the real logic — table definitions, metric rules, gotchas — lives in the repo, so this should never need updating.

```
# Cafe Zupas data — knowledge base protocol

Before answering ANY question about company data (sales, orders, customers,
menu, items, stores, campaigns, Braze, BigQuery):

1. Get a fresh copy of the knowledge base — every session, even if a copy
   already exists (delete any older copy first):
   git clone --depth 1 https://github.com/bchristensen-cz/cz_marketing_kb
   Clone into your temporary working area, never into my personal folders.
2. Read README.md from that fresh clone and follow its session protocol,
   then read the relevant skill in claude_skills/ and the data dictionaries
   it references. Follow the skills verbatim (canonical definitions, the
   pre-query clarification protocol, partition filters).
3. Never answer from installed skills, saved copies, forks, or memory of a
   previous session. The fresh clone is the single source of truth.
4. State the KB version (git log -1 --format='%h %ad') in the first data
   answer of the session.
5. Never commit, push, or edit the knowledge base. New findings are logged
   per the README's ground rules (Asana task on the Claude Data board).
6. If the clone fails for any reason, STOP. Tell me the knowledge base is
   unavailable and that you can't answer data questions without it. Do not
   answer from general knowledge, do not guess table or column names, and
   do not query BigQuery. A failed clone is a hard stop, not a reason to
   improvise.
7. Always show me the SQL.
```

---

## Step 3 — Paste the global backstop

Step 2 only protects chats **inside** that project. This step protects everything else.

Go to **Settings → General → "Instructions for Claude"** and add the block below (keep anything already there). Unlike project instructions, this applies to every chat and every Cowork session you ever start — so if you forget to open the project, the guardrails still hold.

```
# Cafe Zupas company data

For any question about Cafe Zupas business data — sales, orders, customers,
menu, items, stores, campaigns, Braze, BigQuery — the only approved source
of query logic is the knowledge base at:
https://github.com/bchristensen-cz/cz_marketing_kb

Clone it fresh each session (git clone --depth 1) into temporary working
space, then follow its README and the relevant skill in claude_skills/
verbatim. State the commit hash in your first data answer.

Never answer these questions from general knowledge, from memory of a past
session, or from a saved copy. Never guess table or column names. If you
cannot clone the knowledge base, say so and stop — do not query BigQuery.

This applies only to Cafe Zupas data questions; ignore it otherwise.
```

This is intentionally a **backstop, not a duplicate**. It names the repo and enforces the refusal, then hands off to the clone for all real logic. Don't paste the full protocol here — two copies of the same rules will eventually drift and produce inconsistent answers that are very hard to diagnose. Keep the detail in Step 2 and in the repo.

It's also deliberately conditional ("only Cafe Zupas data questions"). Without that line it would fire on unrelated work — drafting an email, brainstorming a campaign name — and Claude would start cloning repositories for no reason.

---

## Step 4 — Always start your chats inside the project, in Cowork mode

Even with the Step 3 backstop, the project is where the full protocol lives. Habit still matters: **open Cowork mode, open the project, then ask.**

If you catch yourself in a plain chat, use the chat's dropdown → **Add to project** to move it, then re-ask your question. If you're in the browser or on your phone, there's nothing to move — you'll need the desktop app (see the requirement at the top).

---

## Step 5 — Verify it's working

Run these three checks once, in order. They take a couple of minutes and catch every common setup mistake.

### Check 1 — the project path

Inside your project, ask:

> sales for ultimate grilled cheese from May 3rd to June 27th

**Pass:** Claude mentions a knowledge-base version (a short commit hash like `4098868`), then **asks you clarifying questions before querying** — the date range, whether to include catering, whether to include items sold inside Try 2 Combos, and which exact product names you mean. SQL is shown when it eventually runs.

**Fail:** an immediate number with no questions, no commit hash, or no SQL. The project instructions didn't load — recheck Step 2.

**Fail, different cause:** Claude says the knowledge base is unavailable or that the clone failed. You're almost certainly not in Cowork mode — see the requirement at the top of this page.

Being asked questions instead of handed a number is the system working as designed. Those questions exist because each one has produced a materially wrong answer before — combos alone can swing an item number by ~3.5x.

### Check 2 — the backstop path

Start a **brand-new chat outside any project** and ask the same question.

**Pass:** Claude still pulls the knowledge base and still refuses to answer from general knowledge. It may be a little less thorough than inside the project, but it must not invent table names or produce a bare number.

**Fail:** Claude answers straight away, or names tables without cloning anything. The global instructions didn't take — recheck Step 3.

### Check 3 — the backstop stays quiet

In that same non-project chat, ask something unrelated:

> write me a short thank-you note to a vendor

**Pass:** you get a thank-you note, with no mention of BigQuery, git, or the knowledge base.

**Fail:** Claude tries to clone the repo or brings up data tooling. The conditional line at the end of the Step 3 block is missing or was edited — re-paste it exactly.

---

## When you find something wrong or missing

Don't edit the repo — only the data steward (Brent) commits to it. Ask Claude to log an Asana task on the **Claude Data** board titled `KB finding: <short title>`, and it'll write up what it observed. Brent reviews and merges it, and everyone's next session picks it up automatically.
