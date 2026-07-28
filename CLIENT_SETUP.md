# Client setup — one-time, per user

You do **not** need to know git, SQL, or BigQuery. Claude does all of that. This page is a one-time setup you do once, then forget.

Total time: about five minutes.

Do **not** install the skills as `.skill` packages, mount a personal clone of this repo, or fork it. The fresh-clone-per-session protocol is the only supported way to consume this KB — it's what guarantees everyone gets the same answer.

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

In Claude, go to **Projects → + New Project**. Name it something like `Cafe Zupas Data`.

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
7. Always show me the SQL you ran.
```

---

## Step 3 — Always start your chats inside that project

This is the one thing that actually goes wrong.

Project instructions only load for chats **inside** the project. If you start a normal chat, Claude never pulls the knowledge base, and it may confidently invent table names and give you a wrong number that looks completely reasonable.

So: open the project first, then ask. If you catch yourself in a plain chat, use the chat's dropdown → **Add to project** to move it, then re-ask your question.

---

## Step 4 — Verify it's working

Ask your new project something simple, like:

> sales for ultimate grilled cheese from May 3rd to June 27th

**Working correctly** — Claude will:

- mention the knowledge base version (a short commit hash like `ec9e1c2`)
- **ask you clarifying questions before querying** — the date range, whether to include catering, whether to include items sold inside Try 2 Combos, and which exact product names to use
- show you the SQL

**Not working** — Claude gives you a number immediately with no clarifying questions, or no SQL, or no commit hash. That means the instructions didn't load. Re-check Steps 2 and 3.

Being asked questions instead of handed a number is the system working as designed. Those questions exist because each one has produced a materially wrong answer before — combos alone can swing an item number by 4x.

---

## When you find something wrong or missing

Don't edit the repo — only the data steward (Brent) commits to it. Ask Claude to log an Asana task on the **Claude Data** board titled `KB finding: <short title>`, and it'll write up what it observed. Brent reviews and merges it, and everyone's next session picks it up automatically.
