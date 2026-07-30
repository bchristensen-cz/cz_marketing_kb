# Admin onboarding — setting up a new employee with Claude data access

**Audience:** whoever holds the data-steward role (currently Brent Christensen). This is the
provisioning runbook — what *you* do before the new person can do anything.

**The user-facing half lives in [`CLIENT_SETUP.md`](CLIENT_SETUP.md)** and is deliberately not
duplicated here. Two copies of the same prompt text will drift, and drift produces inconsistent
answers that are very hard to diagnose. This document gets the person *ready* to run
`CLIENT_SETUP.md`; that file gets them *working*.

Budget about 30 minutes of your time per person. IAM changes can take a few minutes to propagate.

---

## TL;DR — the whole job in one page

If you read nothing else, read this.

**Five things to do per person:**

| # | Do this | Where | Detail |
|---|---|---|---|
| 1 | Invite them to the Claude org | Claude admin console | §2 |
| 2 | Grant **BigQuery Job User** on project `marketing-data-442316` | GCP → IAM | §3.2 |
| 3 | Grant **MCP User** (`roles/mcp.user`, carries `mcp.tools.call`) on the same project | GCP → IAM | §3.2a |
| 4 | Grant **BigQuery Data Viewer** on dataset **`claude`** only | BigQuery → `claude` → Sharing → Permissions | §3.3 |
| 5 | Send them [`CLIENT_SETUP.md`](CLIENT_SETUP.md) | link it, don't retype it | §5 |

That's it. Asana is already shared company-wide, the source datasets are already authorized, and
nobody needs `scratch`.

**Five things that will bite you:**

1. **They must use Cowork mode in the Claude desktop app.** Data questions need `git clone`, which
   needs a shell, and only Cowork has one. Browser, mobile, and plain desktop chat all fail with
   "the knowledge base is unavailable." That message is Claude working correctly, not a bug. This is
   the #1 support call. (§2)
2. **Grant Data Viewer on the `claude` dataset, never at project level.** Every dataset in this
   project carries a `projectReaders` entry, so a project-level Data Viewer grant silently opens
   `brink`, `pulse`, and `sessionM`. (§3.3, §3.6)
3. **If you add a new source dataset later, authorize `claude` on it** or every view over it breaks
   with a permission error naming a table the user can't see. Already done for `sales_ops`,
   `sessionM`, and `braze`. (§3.3a)
4. **The `claude` views only go back to 2023-01-01** and older dates return **zero rows, not an
   error** — which reads as "no sales." (§10)
5. **`mcp.tools.call` is a separate grant from the two BigQuery ones.** Without it the BigQuery MCP
   connector authorizes fine and then fails on the first tool call — so it looks like a broken
   connector, not a missing permission. (§3.2a)

**What they can and can't answer:** orders, sales, channels, customers, menu/items, order
sequencing, lifetime customer metrics, and loyalty — yes. Campaigns/email/SMS — not yet (`braze`
views are coming). Store attributes beyond `store_id` / `store_name` — not yet.

**Before you hand it over,** skim §8 and send it to them.

---

## 0. How the system works — read this once

Understanding the shape saves you an hour of confused troubleshooting later.

```
Employee's Claude  ──(project instructions)──►  clone the KB fresh, every session
        │                                        github.com/bchristensen-cz/cz_marketing_kb
        │                                                    │
        │                                        skills + data dictionaries
        │                                        (canonical definitions, gotchas)
        ▼
   BigQuery MCP connector  ──►  marketing-data-442316
        │
        ├──► claude.*  ← the ONLY thing employees can read (read-only views)
        │       │
        │       │  claude is an authorized dataset on the three sources below,
        │       │  so its views read through on their own authority
        │       ▼
        └──► sales_ops.*   sessionM.*   braze.*     ← employees: no direct access
             brink.*  pulse.*  everything else      ← nobody queries these for answers
```

The shape to hold onto: **`claude` can read the sources; the user can only read `claude`.** That's
what lets you hand someone real numbers without handing them the raw warehouse. See §10 for which
domains are covered today.

Three ideas do all the work:

1. **The knowledge base is pulled, never installed.** Every session clones `main` fresh. Nobody
   holds a stale copy, so a fix you push is live for everyone on their next question. This is why
   you never send anyone a `.skill` file.
2. **Permissions are the real wall, instructions are the guardrail.** The prompts tell Claude
   which tables are correct; IAM makes the wrong ones *impossible*. Do both. Instructions alone
   will eventually be talked around; permissions alone produce confident wrong answers from
   undocumented tables.
3. **Findings flow back through Asana, not git.** You are the only committer. Users file
   `KB finding:` tasks. This is what keeps "the same question always gets the same answer" true.

---

## 1. Prerequisites — gather before you start

| Item | Where it comes from | Notes |
|---|---|---|
| Employee's `@cafezupas.com` Google account | Already exists if they're onboarded to Workspace | Must be the Workspace account, not a personal Gmail |
| Claude seat | Claude Team/Enterprise admin console | Needs a free seat on the plan, or you're buying one |
| Your own admin rights | Claude admin + GCP IAM Admin on `marketing-data-442316` | If you can't do both, find who can before starting. No Asana admin needed — the board is company-wide |
| Their role / what they'll actually ask about | Conversation with them or their manager | Shapes what you tell them is in and out of scope — see §10 |

**Decide up front whether this person should have data access at all.** Everything below is
reversible, but the cheapest access review is the one you do before granting.

---

## 2. Step 1 — Claude seat

1. Invite them in the Claude admin console using their `@cafezupas.com` address.
2. **Have them install the Claude desktop app. This is mandatory, not a nicety.** The whole
   protocol depends on `git clone` running at session start, which needs a shell — and only
   **Cowork mode on the desktop app** has one. Verified 2026-07-29: a clean
   `git clone --depth 1` of the KB succeeds in the stock Cowork Linux sandbox (git 2.34.1,
   github.com reachable) with no extra MCP servers installed. It fails everywhere else:

   | Surface | Shell? | Data questions |
   |---|---|---|
   | **Cowork mode, desktop app** | yes (built in) | ✅ the only supported surface |
   | Regular chat, desktop app | no | ❌ clone fails → hard stop |
   | claude.ai in a browser | no | ❌ clone fails → hard stop |
   | Claude on mobile | no | ❌ clone fails → hard stop |

   The failure is *correct* behavior — the hard-stop rule refusing to guess — but to the user it
   reads as "Claude is broken." Say this to them up front; it's the #1 thing they'll trip over.
   **Do not** solve it by installing skills as `.skill` packages or by pasting KB content into the
   project — both break the freshness guarantee, which is the point of the whole design.

   Note for troubleshooting: don't be misled by the steward's own machine. Brent has Windows-MCP
   and Desktop Commander installed; **neither is involved** and neither is required. If you're
   diagnosing over someone's shoulder, the question is "are you in Cowork mode," not "which MCP
   servers do you have."
3. Confirm they can sign in and send one ordinary message before you touch GCP. If SSO is broken,
   you want to know now rather than while debugging a BigQuery error.

> **Don't** let them set up a personal Anthropic account and expense it. Company data must flow
> through the org's plan so it's covered by the Anthropic commercial terms and so you can revoke
> it on offboarding.

---

## 3. Step 2 — GCP / BigQuery provisioning

**Policy: the `claude` dataset is the only company data employees read.** Not `sales_ops`, and
absolutely not `brink`, `pulse`, or `sessionM`. (`scratch` is steward working space and is not
granted — §3.4.) Raw datasets carry voids, duplicates, and grain defects that the marts already
handle; a well-meaning person querying `brink.orders` directly will produce a number that looks
clean and is wrong.

Check §10 for the two remaining coverage gaps — `braze` views and store attributes — so you can set
expectations before they hit them.

### 3.1 Grants are per-person

The steward does **not** have Google Workspace admin, so there's no group to manage — all three
grants below go directly to the individual's `@cafezupas.com` address.

This works fine, but it puts the burden on discipline rather than structure:

- **Keep a running list.** Add every person you grant to the "who has access" list at the bottom of
  this section, with the date. Per-person bindings are how permission sprawl starts — a year from
  now, nobody will remember why `someone@` has `dataViewer` on something.
- **Offboarding is now three removals per person, not one.** §9 covers it. Don't skip it.
- **Audit quarterly.** Read the `claude` dataset ACL and the project IAM page and confirm every
  name still belongs. Five minutes.

> **Worth revisiting:** if you ever get Workspace admin (or can get someone who has it to make one
> group), a single `gcp-claude-data-users@cafezupas.com` group turns onboarding into one membership
> add and offboarding into one removal, and makes the audit a single page. Not a blocker — just the
> cheaper long-run shape.

#### Who has access (keep this current)

| Person | Granted | `jobUser` | `mcp.user` | `dataViewer` on `claude` | Notes |
|---|---|---|---|---|---|
| bchristensen@cafezupas.com | — | OWNER | yes | OWNER | Steward; also OWNER on source datasets |
| thood@cafezupas.com | - | standard | | standard | user |
| melspencer@cafezupas.com | - | standard | | standard | user |
| mhaacke@cafezupas.com | - | standard | | standard | user |
| salmquist@cafezupas.com | - | standard | | standard | user |
| jelgie@cafezupas.comm | - | standard | | standard | user |
| dgetz@cafezupas.com | - | standard | | standard | user |

> The `mcp.user` column was added 2026-07-30. Existing users predate the grant — **backfill it for
> anyone whose connector stops working on a tool call**, and confirm it for everyone at the next
> quarterly audit.

### 3.2 Grant 1 — the ability to run queries (project level)

In GCP console → **IAM & Admin → IAM → Grant access** on project `marketing-data-442316`:

| Principal | Role | Why |
|---|---|---|
| `newperson@cafezupas.com` | **BigQuery Job User** (`roles/bigquery.jobUser`) | Lets them *start* a query. Grants no data access by itself. Also carries `resourcemanager.projects.get`, so the project shows up in their tooling. |

This is the counterintuitive part: Job User lets someone start a query and read no data — it
carries no `bigquery.tables.getData`, no `bigquery.datasets.get`, no `bigquery.tables.list`. All
actual data access comes from the next grant. That separation is the wall. (It does also carry a
few Dataform permissions, so it isn't literally "nothing else," but nothing that reads warehouse
data.)

Or via CLI:

```bash
gcloud projects add-iam-policy-binding marketing-data-442316 \
  --member="user:newperson@cafezupas.com" \
  --role="roles/bigquery.jobUser"
```

### 3.2a Grant 2 — the ability to call MCP tools (project level)

Same IAM page, same project:

| Principal | Role | Why |
|---|---|---|
| `newperson@cafezupas.com` | **MCP User** (`roles/mcp.user`) | Carries `mcp.tools.call` — the permission the BigQuery MCP connector needs to invoke a tool at all. Without it the connector authorizes cleanly and then fails on every call. |

```bash
gcloud projects add-iam-policy-binding marketing-data-442316 \
  --member="user:newperson@cafezupas.com" \
  --role="roles/mcp.user"
```

**Why this is easy to miss:** it is orthogonal to the two BigQuery grants. Someone can hold
`jobUser` *and* `dataViewer` on `claude`, sail through the connector's Google sign-in, and still be
unable to run a single question — because the failure happens one layer earlier, at the MCP tool
call, before any SQL is submitted. The error text points at MCP rather than at BigQuery, so it reads
as "the connector is broken." Grant all three at the same time and you never see it.

Like `jobUser`, this grants no data access on its own. It is the ability to *invoke*; §3.3 is the
only thing that lets anything be *read*.

### 3.3 Grant 3 — read the `claude` dataset (dataset level)

**Dataset level, not project level.** A project-level `BigQuery Data Viewer` grant would expose
every dataset in the project, including the raw ones. Doing this at the dataset level is the
entire point.

BigQuery console → `marketing-data-442316` → dataset **`claude`** → **Sharing → Permissions →
Add principal**:

| Principal | Role |
|---|---|
| `newperson@cafezupas.com` | **BigQuery Data Viewer** (`roles/bigquery.dataViewer`) |

Or via SQL DCL — **use this, not `bq`.** `bq add-iam-policy-binding` does not support datasets
(tables and views only), and the `bq show`/`bq update --source` route overwrites the whole ACL:

```sql
grant `roles/bigquery.dataViewer`
on schema `marketing-data-442316`.claude
to "user:newperson@cafezupas.com"
```

### 3.3a Authorize `claude` on every source dataset — ✅ already done, but read this once

> **Status 2026-07-29 — nothing to do for a new person.** `claude` is registered as an **authorized
> dataset** (`targetTypes: ["VIEWS"]`) on all three sources: **`sales_ops`**, **`sessionM`**, and
> **`braze`**. Verified in the live ACLs. This section matters when you add a *new source dataset*,
> not when you add a person.

Dataset access to `claude` is *not* enough on its own — this is worth understanding because it's the
most confusing error class in the system.

A view in `claude` that reads `sales_ops` or `sessionM` is, by default, a **plain view**: BigQuery
evaluates it with the **caller's** credentials against the underlying tables. So a `claude`-only
employee querying `claude.order_customer` gets:

```
Access Denied: Table marketing-data-442316:sales_ops.order_customer:
User does not have permission to query table ...
```

Registering the view changes whose authority does the underlying read. Once registered, the source
read happens on the *view's* authority — the employee needs only `jobUser` + `dataViewer` on
`claude`, and still cannot see or query `sales_ops` directly. That's the wall working as designed.

**Authorize the whole `claude` dataset, not view by view.** An *authorized dataset* covers every
current and future view in `claude`, so you never have to repeat this when you add a mart — which is
why it's already handled for the three current sources. When you add a **new** source dataset:

```
BigQuery console → dataset <new_source> → Sharing → Authorize datasets
  → add marketing-data-442316.claude
```

This is safe because only the steward can write to `claude` — it *is* the curated interface layer,
so granting it blanket read on the sources doesn't widen anyone's access.

**Verify** — the source dataset's ACL should contain a `dataset` entry pointing at `claude`:

```
BigQuery console → dataset <source> → Sharing → Authorize datasets
```

**The rule to remember:** *any time a `claude` view reads a dataset that isn't already authorized,
every user hits a permission error naming a table they can't see.* That error means you missed this
step — it is never a sign the user's access is wrong. Most likely trigger: the upcoming `braze`
views (source already authorized, so they should just work) or any new source added later.

Three caveats worth knowing before you debug one:

- Source and view datasets must be in the **same region** (all of these are `US` — fine).
- **De-authorizing a dataset** can take up to **24 hours** to propagate. This does *not* apply to
  revoking a person — to cut someone off now, remove both of their IAM bindings (§9), which takes
  effect in minutes.
- Authorizing a dataset does **not** grant the user anything on the source. It only lets views in
  `claude` read through. The employee still can't query `sales_ops` by name.

### 3.4 `scratch` write access — don't grant it

**Nobody needs this. Skip it.** Three grants (§3.2, §3.2a and §3.3) are the complete provisioning
set.

Background, so you know what you're saying no to: the `sales-ops-orders` skill tells Claude to
materialize intermediate results into `marketing-data-442316.scratch` (7-day auto-expiry) rather
than building views over heavy queries. That's a steward-workflow convenience for multi-step cohort
and funnel work, not something a normal user hits. If someone ever genuinely needs it, the grant is
**BigQuery Data Editor** (`roles/bigquery.dataEditor`) on dataset `scratch` **only** — and it should
be a deliberate, logged exception, never part of the default onboarding.

Never grant Data Editor anywhere else.

### 3.5 Confirm the API is enabled and propagation has finished

The BigQuery API is already on for this project, so you shouldn't need to touch it. IAM changes
usually apply in under a minute but can take a few. **If the person's first query fails with a
permission error, wait five minutes and retry once before debugging anything.** A large share of
"it's broken" reports at this stage are just propagation.

### 3.6 What you have deliberately *not* granted

Say this out loud to the new person — it prevents them from filing bugs against the design:

- No **direct** access to `sales_ops`, `braze`, `brink`, `pulse`, `sessionM`, or any other dataset.
  Not an oversight. They read those sources *only* through `claude` views, and only the columns and
  date range those views expose.
- No write access anywhere — including `scratch` (§3.4).
- No BigQuery Admin, no dataset creation, no scheduled-query editing.

Note the distinction that trips people up: `claude` **is** authorized to read `sales_ops`,
`sessionM`, and `braze` (§3.3a). The *user* is not. A user typing
`select * from sales_ops.order_customer` gets denied; the same data reached through
`claude.order_customer` works. That's the design, not an inconsistency.

**Two standing hygiene issues on this project** (found 2026-07-28, worth fixing independent of any
onboarding):

- `sales_ops` grants READER to `hassaan.akmal@tkxel.io`, an outside developer account — the exact
  category the query-log review rules exclude. `sessionM` grants READER +
  `roles/bigquery.user` to `drobins@cafezupas.com` directly; now that `claude.loyalty_*` exists,
  check whether that can be dropped.
- Every dataset, including `brink`, `pulse`, and `sessionM`, carries a `projectReaders`
  special-group READER entry. That means **any** project-level Viewer or Data Viewer binding
  silently opens all raw data. It's why §3.3 insists on dataset-level grants, and it's worth
  auditing project-level bindings before you add anyone.

---

## 4. Step 3 — Asana — ✅ nothing to grant

The **Claude Data** board is already **shared company-wide**, so there's no per-person step here.

- Workspace: `cafezupas.com`
- Project: [Claude Data](https://app.asana.com/1/47693676899341/project/1216769551099591/list)
  (project id `1216769551099591`)

What you *do* still owe the new person is the **convention**, because access without knowing the
protocol is useless:

> Found something wrong or missing? Don't try to fix it yourself and don't keep a private
> workaround query. Ask Claude to log a task on the Claude Data board titled
> `KB finding: <short title>`, with what you saw and the query. Brent reviews it, merges it into the
> knowledge base, and everyone's next session picks up the fix automatically.

They do need to have **authorized the Asana connector** in their own Claude settings for this to
work — that's `CLIENT_SETUP.md` Step 0, on their side, not an admin grant.

This loop is the reason the system stays accurate. Without it people quietly build their own
spreadsheets, which is exactly the fragmentation the whole project exists to prevent.

---

## 5. Step 4 — Hand off `CLIENT_SETUP.md`

Send them the link to [`CLIENT_SETUP.md`](CLIENT_SETUP.md) and let them work through it. It takes
them about five minutes and covers, in order:

| Their step | What it is | Where the text goes in Claude |
|---|---|---|
| 0 | Authorize the **BigQuery** and **Asana** connectors (both required — Asana is how they file findings) | Settings → Connectors |
| 1 | Create a project, e.g. `Cafe Zupas Data` | Projects → + New Project |
| 2 | Paste the **KB protocol block** | That project → *Set project instructions* |
| 3 | Paste the **global backstop block** | Settings → General → *Instructions for Claude* |
| 4 | Habit: start chats inside the project | — |
| 5 | Run the three verification checks | — |

The exact prompt text lives only in `CLIENT_SETUP.md`. Don't paste it into emails, Slack, or a
Google Doc — the moment a second copy exists, someone will onboard from the stale one.

### The two paste locations, and why there are two

This is the question people ask most, so answer it pre-emptively:

- **Project instructions (Step 2)** hold the full protocol — clone fresh, read the README and
  skills, state the commit hash, show the SQL, hard-stop on clone failure. They apply only inside
  that project.
- **Global instructions (Step 3)** are a deliberately thinner *backstop* for when someone forgets
  to open the project. They name the repo and enforce the refusal, then hand off.

Resist every request to "just put the whole thing in global instructions so I don't need the
project." Two full copies of the same rules drift, and the failure mode is silent: two people get
different answers and neither can tell which is stale.

### Things they'll get wrong

- **Asking data questions outside Cowork mode** — in the browser, on their phone, or in a plain
  desktop chat. They'll get "the knowledge base is unavailable" and report it as a bug. See §2
  step 2; this is the most common onboarding failure.
- Skipping connector authorization and reporting "Claude is broken." Check §7 first.
- Editing the prompt blocks to be "cleaner." The conditional last line of the global block
  (*"applies only to Cafe Zupas data questions"*) is load-bearing — without it Claude tries to
  clone a repo when they ask for help writing a thank-you note.
- Installing skills as `.skill` packages because it feels tidier. This breaks the freshness
  guarantee. Tell them explicitly not to.

---

## 6. Step 5 — Verify from your side

Don't take "it works" on faith. Two checks:

**Check A — watch it in the query log.** After they run their first real question, their job
should appear in the daily query-log review (or query it directly). Confirm the job carries the
`goog-mcp-server: true` label and reads from `claude.*`:

```sql
select
  creation_time
, user_email
, job_id
, labels
, total_bytes_processed
, query
from `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
where 1=1
and creation_time >= timestamp_sub(current_timestamp(), interval 1 day)
and user_email = 'newperson@cafezupas.com'
order by creation_time desc
```

A job whose SQL names `sales_ops.*`, `brink.*`, `pulse.*`, or `sessionM.*` **directly** — rather than
reaching them through a `claude` view — means a grant went to the wrong scope. Fix the IAM binding,
don't just ask them to stop. (Referencing `claude.order_customer` is correct and expected, even
though it reads `sales_ops` underneath.)

**Check B — ask them to paste you their Check 1 result** from `CLIENT_SETUP.md` §5. You're
looking for two things: a **commit hash** in the answer, and **clarifying questions asked before
the query ran**. If they got an instant bare number with no hash and no questions, the project
instructions didn't load.

Be a little generous on which questions get asked. That test prompt already supplies a date range,
and the protocol tells Claude not to re-ask something the user already stated — so a correct
session may skip the date question and only raise catering, combos, and product-name resolution.
Absence of *all* questions is the failure signal; absence of one isn't.

---

## 7. Troubleshooting — symptom to cause

Note on step numbers: rows below say **"`CLIENT_SETUP.md` Step N"** for the user's own steps, to
keep them distinct from this document's §2–§5 "Step 1–4" headings.

| What they report | Most likely cause | Fix |
|---|---|---|
| "Claude says a server requires authentication" | Connector not authorized | `CLIENT_SETUP.md` Step 0; complete the Google sign-in prompt |
| "Access Denied: User does not have `bigquery.jobs.create`" | Missing project-level Job User | §3.2 |
| Connector authorizes fine, then every question fails before any SQL runs — error mentions **MCP** or `mcp.tools.call`, not BigQuery | Missing `roles/mcp.user` | §3.2a. Reads as a broken connector; it's a missing grant |
| "Permission denied on table `X`" **while querying a `claude` view** | A source dataset isn't authorized for `claude`. Shouldn't happen for `sales_ops`/`sessionM`/`braze` — suspect a newly added source | §3.3a |
| "Permission denied on table `sales_ops.…`" while querying `sales_ops` **by name** | Working as designed, or the skill pointed them at something with no `claude` equivalent | §10 — tell them it's out of scope; don't grant `sales_ops` |
| "No sales" / zero rows for an older period | The `claude` views only go back to **2023-01-01**, and truncation is silent | §10 — confirm the date range is inside the window |
| A number doesn't match one the steward produced | Often the `revenue_category` override, or the 3-year window | §10 — compare which side of `claude` each query ran on |
| "Permission denied on dataset `claude`" | Missing dataset-level Data Viewer, or IAM hasn't propagated | §3.3, then wait 5 min |
| "I can't see the dataset in the Explorer pane" | Expected — a dataset grant doesn't add it to Explorer | They can still query it by full name; not a bug |
| Answers arrive with no SQL shown | Instructions didn't load, or they're outside the project | Re-check `CLIENT_SETUP.md` Steps 2 and 3; move the chat into the project |
| No commit hash in the first data answer | Project instructions didn't load, or the clone silently failed | Ask Claude to show the clone output |
| "It says the knowledge base is unavailable" | **Almost always: they're not in Cowork mode.** No shell → no clone. Otherwise network/GitHub reachability | §2 step 2. This is *correct behavior*. Move them to Cowork mode on desktop; never work around it by pasting KB content in |
| Claude answers instantly without asking anything | Working from a saved copy or general knowledge | Confirm no `.skill` packages installed; re-paste `CLIENT_SETUP.md` Step 2 |
| Claude brings up BigQuery on unrelated questions | Conditional line missing from the global block | Re-paste `CLIENT_SETUP.md` Step 3 exactly |
| Two people got different numbers for the same question | Almost always different scope assumptions (dates, catering, combos), not a data bug | Compare their assumption lines before suspecting the mart |
| Query is enormous / times out | Missing partition filter | The skill requires one; check the SQL for `business_date` / `business_date` |

**General rule:** if the symptom is "Claude is broken," it is a Cowork-mode, connector, or permission
problem the large majority of the time. Work down the table above before reading any SQL.

---

## 8. Tips and tricks — how to word questions

Give this section to the new person. It's the difference between a useful first week and a
frustrated one. The system is designed to ask clarifying questions rather than guess, so the
better your question, the fewer rounds it takes.

### First — where the numbers actually come from

You don't need this to use the system, but it explains why Claude behaves the way it does, and it's
the context that stops people mistrusting a correct answer.

**The path a question takes:**

1. **You ask in plain English**, inside your Claude project, in Cowork mode.
2. **Claude pulls the knowledge base** — a fresh copy of the shared repo, every session. That repo
   holds the *definitions*: what "net sales" means, which tables are approved, which traps to avoid,
   what to ask you before querying. Nobody's Claude keeps its own copy, which is why two people
   asking the same question get the same answer.
3. **Claude writes SQL** and runs it against **BigQuery**, our data warehouse, in the Google Cloud
   project `marketing-data-442316`. It shows you that SQL every time.
4. **You get the number, plus the assumptions** it rests on.

**What's underneath, in order of trust:**

- **Brink** is the point-of-sale system and the **single source of truth for money** — sales,
  discounts, tax, tips. Every financial figure traces to Brink.
- **Pulse** handles digital ordering (app, web, catering) and supplies order and customer metadata.
  It is *never* used to compute financials.
- **SessionM** is the loyalty platform — points, offers, tiers, membership.
- **Braze** is the messaging platform — email and SMS campaign activity.

Those four raw feeds land in BigQuery hourly, and they are **messy**: voided orders, duplicate rows,
the same customer under several IDs, columns that mean different things than their names suggest.
Nobody should be querying them directly, and access is deliberately closed.

**So instead you query curated tables.** Brent maintains a cleaned layer where the voids are
removed, duplicates collapsed, identities stitched together, and every metric has one agreed
definition. Your access points at a set of read-only views (the `claude` dataset) built on top of
that layer. You can't reach the raw data even if you ask — and that's the feature, not a limitation:
it's what makes the answer you get the same answer your colleague gets.

**Two consequences worth internalizing:**

- **Freshness:** data is current as of the top of the current hour. Today's numbers are still moving;
  yesterday and earlier are stable. Loyalty data loads once a day, so today's loyalty identity
  coverage is thin by design.
- **History:** the views cover **2023-01-01 forward**. Ask about 2022 and you get zero rows, which
  looks like "no sales" but means "outside the window." Ask Claude to confirm the range if a result
  looks suspiciously empty.

If a number looks wrong, the productive question is *"what assumptions did you make and can I see
the SQL?"* — not *"is the data broken?"* It usually isn't; it's usually a scope difference, and the
four items below are almost always the culprit.

### When your question is vague — what should happen

Vague questions are fine. "How are sales doing?" is a perfectly reasonable thing to ask, and you
shouldn't have to think like an analyst to get an answer.

But a vague question has no single correct answer — "how are sales doing" could mean this week vs
last, this month vs last year, with or without catering, all channels or just in-store. So there's a
firm rule, and **you should hold Claude to it**:

> When a question is vague, Claude must either **ask you** which scope you meant, or **state every
> assumption it made** — plainly, up front, not buried at the end. Never a bare number.

A good response to "how are sales doing?" looks like one of these:

- *"Quick check on scope before I run it: which period, and should catering be in or out?"* — or —
- *"Here's net sales for the last full business week (Mon 2026-07-20 – Sat 2026-07-25), all
  channels including catering, all stores except the 1111 test store, compared to the prior week.
  Say the word if you meant a different cut."*

**What to push back on:** a single number with no stated period, no mention of catering, and no SQL.
If you get that, reply *"what assumptions did you make?"* — and if it happens repeatedly, something
in the setup is wrong (see §7).

**Why this is strict.** Every assumption on that list has silently produced a materially wrong
answer before. The rule exists so that two people asking the same loose question either get the same
number or get told exactly how their numbers differ.

### The four things that change the answer most

State them and you'll usually get a number on the first pass.

1. **Dates.** Always explicit. "May" is ambiguous (this May? fiscal?). Say
   `2026-05-01 to 2026-05-31`. Note that the business week runs **Monday–Saturday** here, so
   "last week" is not what your calendar app means.
2. **Catering — in or out.** Catering trays carry the same item names as retail items at wildly
   different volumes and prices. Leaving this unsaid silently changes item answers.
3. **Try 2 Combos** — on any soup, sandwich, or salad question. Say whether you want standalone
   sales, combo-bundled sales, or both split out. This is not a rounding difference: for Ultimate
   Grilled Cheese over eight weeks it was 24,125 standalone vs 85,084 inside combos — combos were
   ~78% of units. Wrong choice = wrong by ~3.5x.
4. **Customers or orders.** "How many customers" and "how many orders" have different filters.
   Customer-level metrics exclude non-person accounts (kiosk terminals, employee accounts,
   third-party funnels — about 38% of identified orders). Sales metrics don't. Say which you mean.

### Question patterns that work

You don't *have* to ask this way — vague is allowed, per the rule above. This is just how to skip
the clarifying round when you already know what you want.

| Instead of | Ask |
|---|---|
| "How are sales doing?" | "Net sales by week, 2026-06-01 to 2026-07-26, excluding catering" |
| "What's our best seller?" | "Top 10 items by gross sales for June 2026, retail only, combos split out" |
| "How many customers do we have?" | "Distinct identified customers who ordered in June 2026" |
| "Is digital growing?" | "Orders and net sales by `revenue_category`, monthly, Jan–Jun 2026" |
| "Why did sales drop?" | "Net sales by store, week of 2026-07-13 vs the prior week — biggest decliners first" |

### Habits worth building

- **Say the metric name if you know it.** "Net sales," "average check," "first-time orders" all
  have single canonical definitions. Using them skips a round of clarification.
- **Ask for the SQL and skim it.** It's shown by default. You don't need to write SQL to notice
  that the date range is wrong or catering is included.
- **Ask one question at a time for anything non-trivial.** Compound questions ("sales and top
  items and new customers by store") produce one giant query that's hard to sanity-check.
- **Ask Claude to explain a definition before you argue with a number.** "How is net sales
  calculated here?" resolves most disagreements in one message.
- **Say the shape you want** — table, chart, spreadsheet, deck, or a file saved somewhere.
  Otherwise you get prose.
- **Verify before you circulate.** A number going into a board deck deserves "sanity-check this
  against a different cut" before it leaves your screen.

### Anti-patterns

- **Don't accept a bare number with no SQL and no stated assumptions** — see the vague-question rule
  above. That's the signature of a setup problem, not an answer.
- **Don't ask Claude to query the raw datasets** even if you suspect a mart is wrong. File a
  `KB finding:` task instead — that's how the fix reaches everyone.
- **Don't paste a number from a past session and ask Claude to extend the analysis.** Definitions
  change (`order_customer` was rebuilt across all history on 2026-07-24). Re-run the base number.
- **Don't hand-roll a metric Claude says is already defined.** If `revenue_category` isn't
  landing the way you expect, that's a finding to file, not a `CASE` statement to write.
- **Don't keep a private "good query" file.** If it's better than what the KB does, the KB should
  have it. File the finding.

---

## 9. Offboarding — the reverse checklist

Do this the same day they leave or change roles. Access nobody remembers granting is the whole
problem.

Because grants are per-person (§3.1), there are **three** IAM removals — miss any one and access
partially survives.

1. **Remove `roles/bigquery.jobUser`** on project `marketing-data-442316` (GCP → IAM). Without this
   they can't run any query, even with dataset access.
2. **Remove `roles/mcp.user`** on the same project. Cutting this alone is the fastest way to stop
   the connector working, but it is not sufficient on its own — it blocks the MCP path, not
   BigQuery access by other means.
3. **Remove `roles/bigquery.dataViewer`** on dataset `claude` (BigQuery → `claude` → Sharing →
   Permissions).
4. **Update the access table in §3.1** so the list stays honest.
5. Deactivate the Claude seat. (No Asana step — the board is company-wide.)
6. Check `scratch` while you're in there. It carries four per-person WRITER grants
   (`dgetz`, `drobins`, `jelgie`, `thood`) that predate this runbook; nobody should need write
   access (§3.4), so clear any that belong to the departing person.
7. Check the query log for anything unexpected in their last 30 days — a good habit, not an
   accusation.
8. If they built anything worth keeping, get it into the repo *before* the account goes away.

```bash
# 1 and 2, if you prefer the CLI
gcloud projects remove-iam-policy-binding marketing-data-442316 \
  --member="user:departing@cafezupas.com" \
  --role="roles/bigquery.jobUser"

gcloud projects remove-iam-policy-binding marketing-data-442316 \
  --member="user:departing@cafezupas.com" \
  --role="roles/mcp.user"
```

```sql
-- 3, via SQL DCL
revoke `roles/bigquery.dataViewer`
on schema `marketing-data-442316`.claude
from "user:departing@cafezupas.com"
```

---

## 10. Scope and gaps — what to tell them is in and out

Verified live 2026-07-29. Re-check before onboarding; this layer is moving fast.

### In scope today

| Domain | Views | Notes |
|---|---|---|
| Orders, sales, channels, customers | `claude.order_customer` | One row per order |
| Menu mix, items, modifiers, combos | `claude.order_lines` | One row per line element |
| Order sequencing + lifetime customer metrics | folded into `claude.order_customer` | See below |
| Loyalty — points, offers, tiers, campaigns | `claude.loyalty_*` (6 views) | Live since 2026-07-28 |

**`order_customer` now carries the sequencing and lifetime columns**, so there's no separate
`order_sequence` view to grant or explain. Folded in: `customer_order_count`,
`days_since_prev_order` (from `sales_ops.order_sequence`); `lifetime_order_count`,
`lifetime_catering_order_count`, `lifetime_guest_order_count`, `lifetime_net_sales`,
`lifetime_gross_sales`, `lifetime_avg_check`, `first_order_date`, `last_order_date`,
`days_since_last_order`, `customer_tenure_days` (from `sales_ops.customer_attribute`); plus
`account_type` (from `claude.loyalty_user.member_program`). First-time vs repeat, recency, and LTV
questions all work from the one view.

### Not in scope yet

- **Campaigns / email / SMS.** `braze` is authorized as a source but the `claude` braze views aren't
  built yet. Coming soon. Until then, say so plainly rather than letting someone discover it.
- **Store attributes** beyond `store_id` and `store_name` — no `store_info` view. State, timezone,
  and other attributes aren't reachable. Covers most practical needs already.
- **Store-level loyalty reporting** — the SessionM `store_id` → Brink store number mapping is
  unresolved.

### Gotchas to state up front

- **History starts 2023-01-01, and truncation is silent.** Both order views filter
  `>= date_trunc(date_sub(current_date, interval 3 year), year)`. A 2022 question returns **zero
  rows, not an error** — reads as "no sales." Check this first on any suspiciously empty result. The
  steward querying `sales_ops` sees full history, so expect numbers that don't reconcile with a
  user's.
- **`revenue_category` in `claude` is not the same as in `sales_ops`.** The view overrides it:
  `case when is_catering = true then 'Catering' else revenue_category end`. So for `claude` users,
  `revenue_category = 'Catering'` and `is_catering = true` are equivalent — the documented
  superset/subset gotcha is collapsed away. This is a *simplification for users*, but it means a
  steward query on `sales_ops` and a user query on `claude` can legitimately split catering
  differently. Know which side you're on before you call one wrong.
- **Zero doesn't always mean zero.** The sequencing and lifetime columns are `coalesce(…, 0)`, so an
  unidentified order shows `customer_order_count = 0` and `lifetime_order_count = 0`. That means
  "no customer attached," not "a customer with no orders." Filtering `customer_order_count = 1` for
  first-time orders is right; treating `0` as a real count is not.
- **`order_lines` exposes `business_date`** (the `BusinessDate` spelling was retired in the 2026-07-30 rebuild). `claude` users get the
  consistent spelling; SQL copied from the skill, which documents `sales_ops`, needs adjusting.
- ~~`pulse.orders` fan-out duplicating orders~~ — **resolved 2026-07-29** by the full-history
  rebuild. Spot-checked through the view: June 2026 returns 713,575 rows = 713,575 distinct
  `brink_order_id`, 0 duplicates. One row per order holds.
- **A repo commit is not a deployment.** Pushing a build script doesn't refresh the mart or redeploy
  a view. Check `max(business_date)` before trusting something you just changed.
- **`is_catering` doesn't flag catering-only SKUs** (e.g. `Ultimate Grilled Cheese Box` is `false`).
  Relevant if the new person's first project is catering.

---

## 11. If you're inheriting the steward role

Read `CLAUDE.md` in the steward's working copy — it's gitignored and local, so ask for it
directly. It covers the recurring duties this document doesn't:

- The **daily query-log review** (scheduled task, weekdays 9:30am MT) and its inclusion rules.
- Reviewing and merging incoming `KB finding:` Asana tasks.
- Owning the build scripts in `sql/` and the scheduled queries behind them.
- Being the **only committer** to this repo.

The single most important habit to inherit: when a session teaches you something — a gotcha, a
definition, a data-quality finding — write it into the skill or dictionary and push it *that
session*. The system's value is entirely in how current this repo is.
