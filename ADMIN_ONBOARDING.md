# Admin onboarding — setting up a new employee with Claude data access

**Audience:** whoever holds the data-steward role (currently Brent Christensen). This is the
provisioning runbook — what *you* do before the new person can do anything.

**The user-facing half lives in [`CLIENT_SETUP.md`](CLIENT_SETUP.md)** and is deliberately not
duplicated here. Two copies of the same prompt text will drift, and drift produces inconsistent
answers that are very hard to diagnose. This document gets the person *ready* to run
`CLIENT_SETUP.md`; that file gets them *working*.

Budget about 30 minutes of your time per person, spread across two sittings (GCP propagation is
not instant).

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
        │                          claude.*      ← what employees can read
        │                          scratch       ← write, analysts only (7-day expiry)
        └── not granted ────────►  sales_ops.*, braze.*, brink.*, pulse.*,
                                   sessionM.*, and every other dataset
```

⚠️ **Read §10 before relying on that diagram.** It is the *target* state. Today the `claude`
dataset does not carry working equivalents for most of what the skills document, and `braze` isn't
covered at all — so a `claude`-only user is far more limited than this picture suggests.

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
| Your own admin rights | Claude admin + GCP IAM Admin on `marketing-data-442316` + Asana project admin | If you can't do all three, find who can before starting |
| Their role / what they'll actually ask about | Conversation with them or their manager | Determines whether they need `scratch` write access — see §3.4 |

**Decide up front whether this person should have data access at all.** Everything below is
reversible, but the cheapest access review is the one you do before granting.

---

## 2. Step 1 — Claude seat

1. Invite them in the Claude admin console using their `@cafezupas.com` address.
2. Have them install the **Claude desktop app**, not just the web app. Cowork mode (folder access,
   shell, scheduled tasks) only exists on desktop, and several of the KB workflows assume it.
3. Confirm they can sign in and send one ordinary message before you touch GCP. If SSO is broken,
   you want to know now rather than while debugging a BigQuery error.

> **Don't** let them set up a personal Anthropic account and expense it. Company data must flow
> through the org's plan so it's covered by the Anthropic commercial terms and so you can revoke
> it on offboarding.

---

## 3. Step 2 — GCP / BigQuery provisioning

**Policy: the `claude` dataset is the only company data employees read.** Not `sales_ops`, and
absolutely not `brink`, `pulse`, or `sessionM`. (Analysts also get write on `scratch` — §3.4 —
which is working space, not company data.) **See §10 first: the `claude` layer is not yet complete
enough to stand alone, so this policy currently constrains what anyone can be asked to answer.** Raw datasets carry voids, duplicates, and
grain defects that the marts already handle; a well-meaning person querying `brink.orders`
directly will produce a number that looks clean and is wrong.

### 3.1 Use a Google Group, not per-person grants

Create it once, then onboarding is a single membership add and offboarding is a single remove.

```
gcp-claude-data-users@cafezupas.com
```

If the group doesn't exist yet, create it in Google Workspace admin first, then apply the two
grants below **to the group**. Per-person IAM bindings are how permission sprawl starts — six
months from now nobody will remember why `someone@` has `dataViewer` on `pulse`.

### 3.2 Grant 1 — the ability to run queries (project level)

In GCP console → **IAM & Admin → IAM → Grant access** on project `marketing-data-442316`:

| Principal | Role | Why |
|---|---|---|
| `gcp-claude-data-users@cafezupas.com` | **BigQuery Job User** (`roles/bigquery.jobUser`) | Lets them *start* a query. Grants no data access by itself. Also carries `resourcemanager.projects.get`, so the project shows up in their tooling. |

This is the counterintuitive part: Job User lets someone start a query and read no data — it
carries no `bigquery.tables.getData`, no `bigquery.datasets.get`, no `bigquery.tables.list`. All
actual data access comes from the next grant. That separation is the wall. (It does also carry a
few Dataform permissions, so it isn't literally "nothing else," but nothing that reads warehouse
data.)

Or via CLI:

```bash
gcloud projects add-iam-policy-binding marketing-data-442316 \
  --member="group:gcp-claude-data-users@cafezupas.com" \
  --role="roles/bigquery.jobUser"
```

### 3.3 Grant 2 — read the `claude` dataset (dataset level)

**Dataset level, not project level.** A project-level `BigQuery Data Viewer` grant would expose
every dataset in the project, including the raw ones. Doing this at the dataset level is the
entire point.

BigQuery console → `marketing-data-442316` → dataset **`claude`** → **Sharing → Permissions →
Add principal**:

| Principal | Role |
|---|---|
| `gcp-claude-data-users@cafezupas.com` | **BigQuery Data Viewer** (`roles/bigquery.dataViewer`) |

Or via SQL DCL — **use this, not `bq`.** `bq add-iam-policy-binding` does not support datasets
(tables and views only), and the `bq show`/`bq update --source` route overwrites the whole ACL:

```sql
grant `roles/bigquery.dataViewer`
on schema `marketing-data-442316`.claude
to "group:gcp-claude-data-users@cafezupas.com"
```

**Authorized views do the rest.** Objects in `claude` that read from `sales_ops` must be
registered in the **source dataset's ACL** as *authorized views*. Once registered, the view reads
the underlying table on the caller's behalf — the employee never needs `sales_ops` access and
never gets it. If you add a new view to `claude` and forget to authorize it, users get a
permission error naming a table they've never heard of. That error means *you* missed a step, not
that their access is broken.

Verify authorization after adding any view:

```
BigQuery console → dataset sales_ops → Sharing → Authorized views
```

As of 2026-07-28 this list is **empty** — `sales_ops` has no authorized views registered. Expect
that to change as the `claude` interface layer gets built out; if it's still empty, no view in
`claude` is reading `sales_ops` on a user's behalf.

Two caveats worth knowing before you debug one:

- Source and view datasets must be in the **same region**.
- **De-authorizing** a view can take up to **24 hours** to propagate. Removing access is not
  instant — if you need someone cut off now, remove their group membership too.

### 3.4 Grant 3 — `scratch` write access (only if they need it)

The `sales-ops-orders` skill tells Claude to materialize intermediate results into
`marketing-data-442316.scratch` (7-day auto-expiry) rather than building views over heavy
queries. Anyone doing multi-step cohort or funnel analysis will hit this.

| Principal | Role | Scope |
|---|---|---|
| individual or group | **BigQuery Data Editor** (`roles/bigquery.dataEditor`) | dataset `scratch` **only** |

Skip it for casual users — they'll never notice. Grant it for analysts. Never grant Data Editor
anywhere else.

### 3.5 Confirm the API is enabled and propagation has finished

The BigQuery API is already on for this project, so you shouldn't need to touch it. IAM changes
usually apply in under a minute but can take a few. **If the person's first query fails with a
permission error, wait five minutes and retry once before debugging anything.** A large share of
"it's broken" reports at this stage are just propagation.

### 3.6 What you have deliberately *not* granted

Say this out loud to the new person — it prevents them from filing bugs against the design:

- No access to `sales_ops`, `brink`, `pulse`, `sessionM`, or any other dataset in the project.
  Not an oversight.
- **No access to `braze` either** — which means campaign, email, and SMS questions are currently
  out of reach for a standard user, even though the repo ships a `braze-campaigns` skill and
  README lists `braze.*` as an approved source. If this person's job involves campaign reporting,
  you need a decision before they start: grant dataset-level `dataViewer` on `braze` as an
  explicit exception, or tell them the domain is out of scope for now. Don't leave it implicit.
- Read access to `scratch` comes bundled with the Data Editor grant in §3.4 — so "the `claude`
  dataset only" is precise for *reading company data*, not literally the only dataset they can see.
- No BigQuery Admin, no dataset creation, no scheduled-query editing.

**Two standing hygiene issues on this project** (found 2026-07-28, worth fixing independent of any
onboarding):

- `sales_ops` grants READER to `hassaan.akmal@tkxel.io`, an outside developer account — the exact
  category the query-log review rules exclude.
- Every dataset, including `brink`, `pulse`, and `sessionM`, carries a `projectReaders`
  special-group READER entry. That means **any** project-level Viewer or Data Viewer binding
  silently opens all raw data. It's why §3.3 insists on dataset-level grants, and it's worth
  auditing project-level bindings before you add anyone.

---

## 4. Step 3 — Asana access

The **Claude Data** board is the users' only write path into the knowledge base.

- Workspace: `cafezupas.com`
- Project: [Claude Data](https://app.asana.com/1/47693676899341/project/1216769551099591/list)
  (project id `1216769551099591`)

Add them as a member with edit rights so Claude can create tasks on their behalf. Tell them the
convention: findings are titled `KB finding: <short title>`, and you review and merge them.

Without this, the "found something wrong?" loop dead-ends and people start keeping private
workaround queries — which is exactly the fragmentation this whole system exists to prevent.

---

## 5. Step 4 — Hand off `CLIENT_SETUP.md`

Send them the link to [`CLIENT_SETUP.md`](CLIENT_SETUP.md) and let them work through it. It takes
them about five minutes and covers, in order:

| Their step | What it is | Where the text goes in Claude |
|---|---|---|
| 0 | Authorize the **BigQuery** and **Asana** connectors | Settings → Connectors |
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

- Setting up in the **web app only**, then wondering why Cowork features are missing.
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

A job hitting `sales_ops.*`, `brink.*`, `pulse.*`, or `sessionM.*` directly means a permission
grant went to the wrong scope. Fix the IAM binding, don't just ask them to stop.

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
| "Permission denied on table `sales_ops.…`" | **Usually not a permissions bug.** The skill correctly pointed them at `sales_ops` and no working `claude` equivalent exists | §10 — tell them the question type is out of scope, or build the view. Only if the object *does* exist in `claude` is this the authorized-view gap in §3.3 |
| "Permission denied on dataset `claude`" | Missing dataset-level Data Viewer, or IAM hasn't propagated | §3.3, then wait 5 min |
| "I can't see the dataset in the Explorer pane" | Expected — a dataset grant doesn't add it to Explorer | They can still query it by full name; not a bug |
| Answers arrive with no SQL shown | Instructions didn't load, or they're outside the project | Re-check `CLIENT_SETUP.md` Steps 2 and 3; move the chat into the project |
| No commit hash in the first data answer | Project instructions didn't load, or the clone silently failed | Ask Claude to show the clone output |
| "It says the knowledge base is unavailable" | Clone failed — network, or GitHub reachability | This is *correct behavior*. Don't work around it; fix the clone |
| Claude answers instantly without asking anything | Working from a saved copy or general knowledge | Confirm no `.skill` packages installed; re-paste `CLIENT_SETUP.md` Step 2 |
| Claude brings up BigQuery on unrelated questions | Conditional line missing from the global block | Re-paste `CLIENT_SETUP.md` Step 3 exactly |
| Two people got different numbers for the same question | Almost always different scope assumptions (dates, catering, combos), not a data bug | Compare their assumption lines before suspecting the mart |
| Query is enormous / times out | Missing partition filter | The skill requires one; check the SQL for `business_date` / `BusinessDate` |

**General rule:** if the symptom is "Claude is broken," it is a connector or permission problem
about 90% of the time. Check §7 top to bottom before reading any SQL.

---

## 8. Tips and tricks — how to word questions

Give this section to the new person. It's the difference between a useful first week and a
frustrated one. The system is designed to ask clarifying questions rather than guess, so the
better your question, the fewer rounds it takes.

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
- **Expect to be asked questions instead of handed a number.** That's the system working. Each of
  those questions exists because skipping it produced a materially wrong answer before.
- **Verify before you circulate.** A number going into a board deck deserves "sanity-check this
  against a different cut" before it leaves your screen.

### Anti-patterns

- **Don't accept a bare number with no SQL and no stated assumptions.** That's the signature of a
  setup problem, not an answer.
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

1. Remove from `gcp-claude-data-users@cafezupas.com`. Once the group is in use this revokes both
   BigQuery grants at once — the reason it exists.
2. Remove any individual IAM bindings. **Check `scratch` especially** — as of 2026-07-28 it still
   carries four per-person WRITER grants (`dgetz`, `drobins`, `jelgie`, `thood`) predating the
   group, so don't assume group removal covered it.
3. Remove from the Asana **Claude Data** board.
4. Deactivate the Claude seat.
5. Check the query log for anything unexpected in their last 30 days — a good habit, not an
   accusation.
6. If they built anything worth keeping, get it into the repo *before* the account goes away.

---

## 10. Known gaps to check before you onboard anyone

Verify these are still true; they were as of 2026-07-28.

- **🛑 The `claude` dataset is not ready to be anyone's only source.** This is the blocker, not a
  caveat. As of 2026-07-28 it holds four objects — `order_customer`, `order_line_entrees`,
  `v_order_customer_catering`, `v_order_customer_third_party` — and they don't match the skills the
  user is told to follow verbatim:
  - `claude.order_customer` is a **materialized table, not an authorized view**, last modified
    **2026-07-09**, and carries the **legacy `OrderCustomer` schema the skill explicitly
    forbids** (`BusinessDate`, integer `iscatering`, `storeid`, `netsales`, `order_count`). It has
    none of the 2026-07-24/27 rebuild columns — no `business_date`, no calculated `net_sales`, no
    `customer_type`, no boolean `is_guest_order`. It also exposes legacy `netsales`, which the
    steward rule says `claude` views must never do.
  - `claude.order_line_entrees` partitions on `businessdate` (a *third* spelling), uses `order_id`
    rather than `brink_order_id`, and **has no `store_id` column at all** — so the mandatory
    `store_id <> 1111` exclusion is impossible on it.
  - `v_order_customer_catering` is a view over the stale table (`where iscatering = 1`).

  **Practical consequence: onboarding a `claude`-only user today produces confidently wrong
  answers, not permission errors** — every canonical metric definition in the skill references
  columns that don't exist there. Until the interface layer is rebuilt against the current
  `sales_ops` marts, pick one deliberately: (a) hold off on data access, (b) grant read on
  `sales_ops` as a documented temporary exception and accept the wider surface, or (c) scope the
  person to question types the current `claude` objects genuinely support. Do not just grant
  `claude` and hope.
- **`braze` is not covered at all.** README lists `braze.*` (69 tables) as approved and there's a
  full `braze-campaigns` skill, but no `claude` equivalent and no grant. Campaign/email/SMS
  questions are out of scope for a standard user. See §3.6.
- **`order_lines` still uses `BusinessDate`**, not `business_date`. Rename pending.
- **`pulse.orders` fan-out** means one `brink_order_id` can appear twice until the next full
  rebuild. Fix written, not deployed.
- **A repo commit is not a deployment.** Pushing a build script doesn't refresh the mart. Check
  `max(business_date)` before trusting a table you just changed.
- **`is_catering` doesn't flag catering-only SKUs** (e.g. `Ultimate Grilled Cheese Box` is
  `false`). Relevant if the new person's first project is catering.

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
