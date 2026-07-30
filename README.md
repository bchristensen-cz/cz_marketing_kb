# Cafe Zupas Marketing Knowledge Base

Shared repository of data dictionaries, skills, and SQL for interfacing with Cafe Zupas data via Claude. The goal: **the same question always gets the same answer**, no matter who asks.

## How to use with Claude — session protocol (required)

This KB is **pull-based**: every Claude session works from a fresh clone of `main`, pulled at the start of that session. No installed skill packages, no forks, no saved local copies.

**Requires Cowork mode in the Claude desktop app.** The clone needs a shell, and that's the only surface that has one — regular desktop chat, claude.ai in a browser, and mobile all fail. Verified 2026-07-29: a clean shallow clone succeeds in the stock Cowork sandbox with no extra MCP servers. Outside Cowork, rule 5 below fires and no data question can be answered. That's intended: see `CLIENT_SETUP.md`.

1. **Fresh clone, every session** (the repo is public; a shallow clone takes seconds):
   ```
   git clone --depth 1 https://github.com/bchristensen-cz/cz_marketing_kb
   ```
   Clone into the session's temporary working area. If an older copy exists, delete it first.
2. Read this README, then the relevant skill in `claude_skills/`, then the data dictionaries it references — from the fresh clone only.
3. **State the KB version** in the first data answer of the session (`git log -1 --format='%h %ad'`), so stale copies are visible.
4. Users never push, fork, or edit this repo. Findings go to the steward via Asana (see Ground rules).
5. **A failed clone is a hard stop.** If the clone doesn't succeed, say the KB is unavailable and stop — do not answer from general knowledge, do not guess table or column names, and do not query BigQuery. There is deliberately no local fallback: the walls in these skills (approved tables only, canonical definitions, partition filters, the pre-query clarification protocol) exist precisely because unguided querying of this warehouse produces confident wrong answers. Answering without the KB is worse than not answering.

The one-time setup each user needs is the project-instructions snippet in `CLIENT_SETUP.md` — it's deliberately tiny and never changes, so it can't go stale.

Provisioning a new person (Claude seat, BigQuery access, Asana, verification, question-wording tips) is the steward's runbook in `ADMIN_ONBOARDING.md`.

## Structure

```
claude_skills/        Skills — how to query each domain (canonical definitions, joins, gotchas)
  sales-ops-orders/   Order & sales data (order_customer, order_lines, order_sequence)
  braze-campaigns/    Marketing campaign activity & engagement (braze dataset)
  sessionm-loyalty/   Loyalty — points, offers, campaign participation (claude.loyalty_*)
data_dictionaries/    Column-level documentation per table
sql/                  Build scripts for data marts + validated query templates
```

## Ground rules

1. Only query tables documented here. Upstream raw datasets (`brink.*`, `pulse.*`, `sessionM.*`) contain voids, duplicates, and traps — the marts exist so nobody has to relearn them.
2. Always filter on the partition column — these tables are large. It's `business_date` on `order_customer` and `order_sequence`, `BusinessDate` on `order_lines` (rename pending).
3. Use the canonical metric definitions in the skills. Don't invent alternate logic.
4. Write ALL SQL in the steward's format (see "SQL style" in `claude_skills/sales-ops-orders/SKILL.md`): fully qualified table names with backticks around the project only (`` `marketing-data-442316`.sales_ops.order_customer oc ``) **and a table alias on every column reference**, lowercase whenever possible, fixed aliases (`oc` = `order_customer`, `ol` = `order_lines`), leading commas, `where 1=1` + one `and` per line, joins with `on` lined up beneath them and one extra indent per successive join. The steward diagnoses user-generated SQL — it must be instantly readable in his layout.
5. Found a gap or a new gotcha? **Don't edit the repo** — only the data steward (Brent) commits. Log it as an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`), titled `KB finding: <short title>`, with what you observed (including the query) and the proposed change. The steward reviews, merges vetted findings into the repo, and pushes — the next session's clone picks it up automatically.

## Approved tables

> **Which dataset can you read?** Standard access is `dataViewer` on the **`claude` dataset only** — `sales_ops` returns `Access Denied` for everyone but the steward. If that's you, use `claude.order_customer` and `claude.order_lines` (views over the `sales_ops` tables below) and read `data_dictionaries/claude.order_customer.md` first: the views restrict history to a rolling 3 years, redefine `revenue_category`, and fold in the `order_sequence` / `customer_attribute` columns with `coalesce(…, 0)` traps. The `sales_ops` rows below document the canonical definitions that both sides share.

| Table | Grain | Use for |
|---|---|---|
| `marketing-data-442316.claude.order_customer` | 1 row per order | **Standard users' order table.** Everything below plus sequencing, lifetime metrics, `account_type` |
| `marketing-data-442316.claude.order_lines` | 1 row per line element | **Standard users' line table.** Exposes `business_date` (renamed from `BusinessDate`) |
| `marketing-data-442316.sales_ops.order_customer` | 1 row per order | Sales, orders, channels, customers, loyalty |
| `marketing-data-442316.sales_ops.order_lines` | 1 row per line element | Menu mix, items, modifiers, combos |
| `marketing-data-442316.sales_ops.order_sequence` | 1 row per identified-person order | Order sequencing, first-time vs repeat, recency, lifetime counts |
| `marketing-data-442316.sales_ops.store_info` | 1 row per store | Store attributes (name, state, timezone) |
| `marketing-data-442316.braze.*` (69 tables) | 1 row per message event | Campaign activity & engagement — use the `braze-campaigns` skill's templates, don't hand-roll unions |
| `marketing-data-442316.claude.loyalty_user` | 1 row per loyalty member | Loyalty identity, program (catering vs individual), tiers |
| `marketing-data-442316.claude.loyalty_points_balance` | 1 row per member per point account | Current points balance, outstanding liability |
| `marketing-data-442316.claude.loyalty_points_expiring` | 1 row per member per expiry date | Points about to expire, expiration forecasting |
| `marketing-data-442316.claude.loyalty_points_activity` | 1 row per point transaction | Points issued / redeemed / expired over time |
| `marketing-data-442316.claude.loyalty_offer_usage` | 1 row per offer issued to a member | Offer & reward redemption rates |
| `marketing-data-442316.claude.loyalty_campaign_participation` | 1 row per campaign event | Loyalty campaign participation, achievements — **always filter `create_date`** |

Loyalty questions use the `sessionm-loyalty` skill. Note the partition columns differ by domain:
`business_date` (order_customer, order_sequence), `BusinessDate` (order_lines), `create_date`
(loyalty_campaign_participation), and `activity_date` for filtering loyalty_points_activity.

More marts are being added in the `claude` dataset — documented here as they land.
