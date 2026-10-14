# Pre-query clarification protocol: stores, dates, catering, delivery

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** you are confirming scope before a query (always, for items 1-3 and 6 of the protocol in `../SKILL.md`).
> Content moved verbatim from `SKILL.md` on 2026-10-14 (router split); the rules and dates inside are unchanged.

## Pre-query clarification protocol (steward rule 2026-07-28 — MANDATORY)

**Before running the query that answers the question, confirm scope.** Every one of these has burned a real answer. Ask them together in ONE message (don't interrogate the user one item at a time), then query. If the user has already stated an item, don't re-ask it.

### 1. Store 1111 — never ask, always excluded

Test/training store 1111, plus 999 which has no `store_info` row and so forms a second unnamed group. Not a question, not a default the user can override, and don't raise it as an assumption. **Which layer you're on decides who writes the filter** (steward rule 2026-09-03):

- **`claude.*` views — do NOT add `store_id not in (1111, 999)`.** All four order views (`order_customer`, `order_lines`, `order_line_discount_detail`, `order_payment_tender`) already apply it in their `view_definition`, so the predicate is redundant noise in user-facing SQL. Just note "stores 1111/999 excluded by the view" in the assumptions line.
- **`sales_ops.*` tables (steward only) — always write `store_id not in (1111, 999)`.** Nothing upstream applies it.

#### Store 1111/999: which layer already excludes them (measured 2026-08-19)

Read from `INFORMATION_SCHEMA.VIEWS.view_definition`, not from documentation:

| Object | Excludes |
|---|---|
| `claude.order_customer` | `store_id not in (1111, 999)` ✅ |
| `claude.order_lines` | `store_id not in (1111,999)` ✅ |
| `claude.order_payment_tender` | `store_id not in (1111, 999)` ✅ (fixed 2026-08-20; was `<> 1111` only) |
| `claude.order_line_discount_detail` | `store_id not in (1111,999)` ✅ (fixed 2026-08-20; previously relied on its base build) |
| `claude.store_info` | `store_id not in (0, 901, 9001)` — a different list for a different purpose (non-store dimension rows) |
| every `sales_ops.*` table | **nothing** — the filter is entirely yours |

**✅ As of 2026-08-20 the four order views are uniform** — all exclude both stores, verified against `INFORMATION_SCHEMA.VIEWS.view_definition`. The earlier asymmetry (payment_tender excluded only 1111; discount_detail carried no predicate of its own) is closed, and the `$13.49` tie-out floor it created is gone.

**Don't write the predicate on `claude` objects** (steward rule 2026-09-03, superseding the earlier "write it anyway" guidance). The views own the exclusion; repeating it in every query taught users it was theirs to remember and cluttered the SQL the steward reads. It remains *required* on every `sales_ops` table. If a number depends on the exclusion, re-verify with `select table_name, view_definition from `marketing-data-442316`.claude.INFORMATION_SCHEMA.VIEWS` rather than trusting this table — it was asymmetric for five days in August without anything failing.

> **Store 1111 is not dormant, so this still matters.** On `sales_ops.order_customer`, 2026-07-01 → 2026-08-19: **626 orders / $17,325.14 net / 223 of them `customer_type = 'person'`**. Store 999 had **zero** orders in the same window — it is `order_lines`-only and tiny, which is exactly why it went unnoticed until 2026-07-30.
>
> Two corollaries worth keeping. **(1)** `customer_type = 'person'` does *not* substitute for the store filter — 223 of those 626 orders are person orders, so a `sales_ops` cohort filtered only on customer type still pulls the test store in. **(2)** A measurement of store 1111 taken *through* `claude.order_customer` is vacuously zero, because the view filters it out. If you are asked "is the test store still active?", that question can only be answered on `sales_ops` — a zero from the `claude` layer proves nothing about the store and everything about the view. Guard against reading a view's own filter as a fact about the world.

### 2. Date range — ask

Which dates the question covers. Never assume "last 30 days" or "this month" from silence. Also confirm the interpretation when a range is fuzzy ("May" = `2026-05-01` to `2026-05-31`; "last week" = the most recent **Mon–Sat**, see the business-week gotcha).

### 3. Catering — ask

Included or excluded, defined as **`is_catering = true` / `= false`** (BOOLEAN — `is_catering = 0` fails). Since 2026-08-17 it is finance's definition — catering destination **or** pulse catering flag **or store 50 (Middleton Mobile)** — and it selects the same orders as `revenue_category = 'Catering'`. Catering skews item questions hard: catering trays/box lunches carry the same `item_name` as the retail item at very different volumes and prices, so an unstated choice here silently changes the answer.

**⚠️ Take the catering split from `order_customer`.** `order_lines` has not been given the store-50 rule yet, so an item-level catering breakdown shows store 50 as zero catering (793 orders in the 30 days to 2026-08-16). See the gotcha.

### Store 999 joins 1111 in the exclusion list (steward rule 2026-07-30)

`store_id = 999` has **no `store_info` row**, so `store_name` and `store_state` are both NULL and it forms a second unnamed group in any store or market breakdown. It is tiny — 4 lines over 2026-05-03 → 2026-06-27 against store 1111's 24,128 — which is exactly why it survives review: it's too small to notice and too nameless to explain. Verified 2026-07-30 that 1111 and 999 are the **only** two store ids with a NULL name or state, and that `store_name` is otherwise unique across all 89 real stores (no dedup needed, no `store_id` prefix required for a readable label).

Use `and ol.store_id not in (1111, 999)` on `order_lines`, and the same on `order_customer`.

### 6. "Delivery" means CZ Delivery — never sweep in the marketplaces (steward rule 2026-08-04)

When an employee says "delivery" they mean the company's own delivery channel:

```sql
and oc.destination = 'CZ Delivery'
```

(`revenue_category = 'Digital'`.) They do **not** mean DoorDash / UberEats / GrubHub / Postmates marketplace orders (`revenue_category = 'Third_Party'`) — even though a third-party company physically carries CZ Delivery orders too. That's precisely how this burned a real answer on 2026-08-03: the delivery provider's name in the conversation pulled the marketplaces into the filter (`lower(destination) like '%delivery%' or like '%doordash%'`).

Measured 2026-05-01 → 2026-07-31, stores 1111 and 999 excluded:

| Scope | Orders | Net sales |
|---|---|---|
| `destination = 'CZ Delivery'` | 37,396 | $1.49M |
| Marketplaces (DoorDash, UberEats, GrubHub, Postmates) | 322,728 | $9.00M |
| Catering delivery destinations (`Catering Online Delivery`, `EZ Cater Delivery`, `Catering Delivery`) | 14,689 | $5.13M |

The naive LIKE read is roughly **9x** the intended number. `like '%delivery%'` also catches the catering delivery destinations — that scope is item 3's question (catering), not this one. If the user plausibly means third-party or "all delivered orders," ask, with these sizes in the option labels; when unstated and unambiguous, default to `'CZ Delivery'` and say so in the assumptions line.

Remaining defaults unless the user says otherwise: include employee-discount orders, all channels. State all assumptions in the answer when they matter.
