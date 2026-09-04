---
name: ask-a-data-question
description: Turn a vague or under-specified business question into a fully-scoped one BEFORE querying, by presenting the open choices as clickable options instead of asking the user to write a better question. Use at the START of any sales, order, item, customer, loyalty, or campaign question — especially short ones like "sales by market for these items" that look complete but aren't. Pairs with sales-ops-orders, sessionm-loyalty, and braze-campaigns.
---

# Ask a data question

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

Most people are not good at writing data questions, and they shouldn't have to be. A
question like

> "sales data by market for the following items from May 3rd 2026 to June 27th 2026?
> Ultimate Grilled Cheese / Honey Bacon Club / Power Bowl / Hot Honey Cottage Cheese Bowl"

reads as complete and specific. It is neither. It contains a dimension that doesn't exist
in the warehouse, a measure with two valid meanings, an unstated catering decision, an
unstated combo decision, and four product names that each match more rows than intended.
Answered literally, it produces a clean, confident, wrong number.

**This skill's job: never make the user rewrite the question.** Resolve what you can from
the data, then present what's left as *clickable choices with their consequences shown*.
The user picks. Then you query.

## The rule

**Do the cheap discovery queries FIRST, then ask ONE question with clickable options.**

Not: ask → query. Not: query → apologise. The order is **resolve → ask once → answer**.

Discovery is cheap **if you bound it**. `store_info` is 99 rows and free. `item_name` is a
cluster field on `order_lines`, which is *not* the same as free. Asking blind is still
expensive — it costs the user a round trip and produces worse options, because you can't show
the size of a choice you haven't measured.

> ⚠️ **"`item_name` is a cluster field" was being read as "name discovery is free." It isn't —
> measured 2026-08-25.** One user's name-resolution and item-profiling queries billed
> **52.4 GB of their 62.5 GB day (84%), across 15 queries**; a second user added 11.9 GB over 8.
> Roughly **65 GB in one day** to answer "does this item exist, what is its `item_id`, and when
> did it start selling." Clustering prunes *within* the partitions you read — it does nothing
> about a `business_date >= '2023-01-01'` discovery scan, and a single
> `regexp_contains(lower(item_name), 'hot honey brisket')` over full history billed **17.7 GB**
> on its own.
>
> **Bound every discovery query, then stop using the name:**
>
> 1. **Resolve on a narrow recent window first** — 30–90 days answers "what is this called and
>    what is its `item_id`" for a live item. Widen only if it returns nothing.
> 2. **Switch to `item_id` immediately** once resolved. Never carry `regexp_contains(item_name)`
>    into the reporting query; `item_id in (…)` is exact, survives menu renames, and stops the
>    per-query regex scan. (`item_name` is not stable — the same product can appear under
>    several ids, and `item_id` is what the item-level marts key on.)
> 3. **"When did this item launch?" is a full-history question — treat it as one and say so.**
>    Run it once, on `min(business_date)` for a resolved `item_id`, not repeatedly against a
>    name pattern. Do not fish for a launch date by re-scanning history under different
>    spellings.
> 4. If the item is genuinely absent from the recent window, say "no sales in the last N days"
>    and ask before scanning history — that is a real fork, and the user usually knows.
>
> A `claude` item dimension that would make step 1 free is a logged **KB gap**, not something to
> build per-session (Asana backlog). Until it exists, the bounding rules above are the fix.

### Never ask a question the data can answer

If `store_info` has one state per store, don't ask "which stores are in the Phoenix
market" — read it. If `is_catering` is false on every matching line, don't ask about
catering — say so and move on. **Only surface a fork that is genuinely the user's call.**

> ⚠️ **Resolve catering against `order_customer`, not `order_lines` (2026-08-17).** The two
> marts disagree again: finance's definition made **store 50 (Middleton Mobile) catering**, and
> `order_lines` hasn't been given that rule — 793 orders / 30 days show `true` on one table and
> `false` on the other. So "`is_catering` is false on every matching line" can be an artefact of
> the table you asked, not a fact about the business. Check `order_customer` before telling a
> user a catering fork is dead. Resolves when the order-mart builds are chained (in flight).

### Never ask a dead question

Check whether a fork applies before presenting it. Asking about Try 2 Combo on a question
about bowls (see below) teaches the user that the clarifications are noise.

## Step 1 — resolve the nouns

| The user said | Before asking anything, run |
|---|---|
| a product name | the `like` discovery query from `sales-ops-orders` (pre-query protocol item 5) — grouped by `item_id` **and** `item_size`, never with a size word inside the `item_name` predicate |
| a size ("mini", "large", "half", "kids", "party") | **a separate column, `item_size`** — it is not in `item_name`. See the size rule below |
| "market", "region", "area" | see the market rule below — it is **`store_state`** |
| a store by name | `select si.store_id, si.store_name, si.store_city, si.store_state from ... store_info si` |
| "delivery" | see the delivery rule below — default is `oc.destination = 'CZ Delivery'`; the third-party marketplaces are a different question |
| a category | `select distinct ol.rev_center_name` / `ol.item_type` on the date range |
| a campaign | the Braze / SessionM lookup in the relevant skill |
| a fuzzy date ("last week", "May") | resolve to explicit dates; business week is **Mon–Sat** |
| "period", "P8", "fiscal year/quarter", a holiday | `claude.date_dim` via the **`date-dimensions`** skill — resolve the fiscal window to explicit dates first. "Quarter"/"year" alone is a fork: calendar vs fiscal disagree near year-end |

### Size lives in `item_size`, never in `item_name` (steward rule 2026-08-27)

The `order_lines` build **strips the size prefix out of `item_name`**, so the phrase a user
speaks is split across two columns. `item_name = 'Mini Chocolate Strawberry Cup'` returns
**zero rows** — and a zero here is the worst possible failure, because it reads to the user
as *we don't sell that*. Match the name without the size word, then filter `item_size`.

Measured 2026-08-27, trailing 30 days, stores 1111/999 excluded:

| `item_id` | `item_name` | `item_size` | Units | Avg unit price |
|---|---|---|---|---|
| 643640578 | `Chocolate Strawberry Cup` | `Mini` | 15,550 | **$9.00** |
| 643640567 | `Chocolate Strawberry Cup` | `Regular` | 5,051 | **$14.00** |

Answering on the name alone overstates the Mini by 32.5% in units / 50.5% in gross and
quotes a $10.23 blended price the product is never sold at.

✅ **`item_size` is a clean closed domain as of 2026-08-27**: `Regular`, `Half`, `Large`,
`Kids`, `Mini`, `Party`, `Tray`, plus `Not Sized` (a real product with no size concept) and
`Not Applicable` (tip, fee, discount, promotion, gift card). No NULLs, and `Regular` means an
actual regular size — 11.7% of lines, not 76%. So a size breakout is safe to show as-is; just
filter `line_item_type in ('item','modifier')` and `Not Applicable` drops out.

⚠️ **But `item_size is null` is dead** — it returns zero rows now, which reads as "no such
thing" rather than erroring. Three different semantics shipped for this column within hours on
2026-08-27, so treat any saved query or older report touching `item_size` as suspect until
re-read. Full mechanism, the 140-of-373 name→`item_id` collision table, and the `Dubai Cup` /
`Kids Combo` twins are in `sales-ops-orders` pre-query protocol item 5.

**So on any item-specific question, size is a dimension you resolve — not a fork you ask.**
Run the discovery query grouped by `item_id` and `item_size` with the average unit price
shown, and present the *result*. If the item turns out to have one size, say nothing about
size at all (asking a dead question teaches the user the protocol is noise). If it has
more than one, the fork is clickable and its options carry the measured consequence:

> **Which Chocolate Strawberry Cup?**
> - **Mini only** — $9.00, 15,550 units in the last 30 days
> - **Full size only** (`Regular`) — $14.00, 5,051 units
> - **Both, broken out by size** *(recommended)*
> - **Both, combined** — one blended row; the $10.23 average is not a real price

### "Market" means `store_state` (steward decision 2026-07-30)

There is **no market, region, DMA, or metro column anywhere in `sales_ops`** — verified
against `INFORMATION_SCHEMA.COLUMNS`. When a user says market, use
`sales_ops.store_info.store_state`, joined `si.store_id = ol.store_id` (or `oc.store_id`),
and **say in the answer that market = state**.

Ten values as of 2026-07-30: Utah (35 stores, 28 cities), Arizona (17), Minnesota (12),
Nevada (9), Wisconsin (8), Idaho (7), Illinois (6), Ohio (3), Texas (1), plus **one store
with a blank `store_state`** — it will form its own empty-named group in any breakdown, so
either exclude it or label it, never leave a nameless row in the output.

Caveats to state when it matters: Utah is a third of the footprint spanning Logan to
St George, so a single "Utah" row hides most of the geographic variation. If the user
wants something tighter, `store_city` is available — but note `West Valley` and
`West Valley City` are separate values for the same metro. A true metro rollup is a
**KB gap**, not something to invent per-session (Asana backlog).

### "Delivery" means CZ Delivery (steward decision 2026-08-04)

When an employee says "delivery" they mean the company's own delivery channel:

```sql
and oc.destination = 'CZ Delivery'
```

(`revenue_category = 'Digital'`.) They do **not** mean the DoorDash / UberEats / GrubHub /
Postmates marketplaces (`revenue_category = 'Third_Party'`) — even though a third-party
company physically carries CZ Delivery orders too, which is exactly how a session got this
wrong on 2026-08-03: the provider's name came up in the conversation, so the filter became
`lower(destination) like '%delivery%' or like '%doordash%'` and swept the marketplaces in.

Sizes, 2026-05-01 → 2026-07-31, stores 1111/999 excluded: **CZ Delivery 37,396 orders /
$1.49M net; marketplaces 322,728 / $9.00M** — the wrong read is ~9x the right one. Note
also that `like '%delivery%'` catches the catering delivery destinations
(`Catering Online Delivery`, `EZ Cater Delivery`, `Catering Delivery` — 14,689 / $5.13M);
that scope belongs to the **catering fork**, not this one.

If the question plausibly means third-party or "everything that gets delivered," present
the fork with these sizes in the option labels. Otherwise default to `'CZ Delivery'` and
state the resolved meaning in the answer.

### "Payment method" / "tender" means `claude.order_payment_tender.payment_tender` (steward decision 2026-08-05)

How-do-people-pay questions are answerable since 2026-08-05: join
`claude.order_payment_tender` to `claude.order_customer` on `brink_order_id` and group by
`payment_tender` (lowercase: `visa`, `mastercard`, `amex`, `discover`, `apple pay`,
`google pay`, `cash`, `gift card`, `givex`, `doordash`, `ubereats`, `grubhub`,
`postmates`, `house_account`, `discount`, `no_payment`, plus comma-joined split tenders).

Three scope points to resolve or state, beyond the standard forks:

- **Tender ≠ channel.** `doordash` as a tender is how a third-party order *pays*; if the
  user actually wants a channel split, the axis is `revenue_category`.
- **Exclude or annotate the latest loaded `business_date`** — it shows `'stripe'` as a
  placeholder network for ~10% of orders until the stripe detail loads (self-heals next
  day).
- **Amounts from this view are gross tendered (tips included), not sales.** If the user
  wants dollars by payment method, sum `oc.net_sales` grouped by `payment_tender`, and
  say so.

Full gotchas: [`data_dictionaries/claude.order_payment_tender.md`](../../data_dictionaries/claude.order_payment_tender.md).

### "Earned" / "redeemed" discounts mean the two loyalty redemption types (steward decision 2026-08-18)

**Earned = `discount_type in ('Reward Redemption', 'In-cart Points Redemption')`** on
`claude.order_line_discount_detail`. Given = everything else — marketing offers outside the
loyalty wallet, in-store promotions, third-party discounts, service recovery, manager
discretion, employee benefit.

Both Brink ids are loyalty ids: **`643571116` is the purpose-built in-store Cafe Zupas Rewards
id** and fires only on a member wallet redemption (99.0–99.5% of reward lines carry a sessionM
`root_offer_id`), while `In-cart Points Redemption` carries the point spend directly
(`points > 0` on 100% of lines). Earned is **−$752,606.55 of −$1,485,468.22** all discounts
over 2026-05-01 → 07-31 (50.7%).

**Do not narrow it.** A wallet offer that was issued rather than points-priced is still a
member redemption. Excluding `offer_kind = 'promotional'` understates earned by −$36,798.41.

**No fork to present** — the split is decided, not a user choice. State the resolved meaning in
the answer: *"earned = redeemed through the loyalty program; marketing offers outside the
wallet, promotions and manager discounts are excluded."*

**One follow-up is worth asking**, but only when the question is about **points cost, points
liability, or what points bought** — that wants the `points_purchase` subset of earned
(−$243,048.45), not all of it. Anything phrased as redemptions, giveaway, or discount spend
wants all of earned.

Full definition, the `upper()` join trap on `root_offer_id`, the employee-meal overlap, and the
pre-2024 window rule are in [`sales-ops-orders`](../sales-ops-orders/SKILL.md) and
[`data_dictionaries/claude.order_line_discount_detail.md`](../../data_dictionaries/claude.order_line_discount_detail.md).

## Step 2 — ask once, with clickable options

Use `AskUserQuestion`. **Every option label must carry its consequence**, drawn from the
discovery queries you just ran. "Include combos" is a bad option. "Include combos —
Ultimate Grilled Cheese is 71% combo units, so this roughly triples the number" is a
good one. The user is picking between outcomes, not between vocabulary.

Rules:

1. **One message, all forks.** Never interrogate one item at a time.
2. **Recommend a default** and mark it `(Recommended)` — put it first. Most users want
   the conventional read and just need to not be silently wrong.
3. **Show sizes.** Pull the real numbers into the option descriptions.
4. **Don't offer a fork that's locked.** Store 1111, `net_sales` definition, `person`
   filter for customer metrics — these are steward rules, not preferences. Apply them
   and note them in the assumptions line.
5. **Skip forks the user already settled.** If they gave explicit dates, don't ask dates.

### The standard fork set for item / sales questions

| Fork | Ask when | Locked answer |
|---|---|---|
| Date range | always, unless explicit | — |
| Breakdown dimension | the user named a fuzzy one ("market", "area") | — |
| Measure — units vs dollars | **don't ask — default to units** (see below) | dollars are opt-in and warned; dollars = `item_gross_sales`. `item_net_sales` is reportable on request but never reconciles to order-level net |
| Catering | always | — |
| Try 2 Combo | **only** for soups, sandwiches, salads (see below) | — |
| Which item names | whenever discovery returned >1 candidate | — |
| **Item size** | whenever a resolved item spans more than one `item_size` — **resolve it first, then fork on what you measured**; never ask when the item has one size | breakout by size is the recommended option; a combined row blends price points |
| Channel | only if the user hints at it | default: all channels |

### A filter and a breakout are two different questions — never one control

Learned the hard way 2026-07-30. A user asked to *"include catering but don't break out catering data."* The tool already did exactly that — its **Include catering** option filters and never groups. The user still had to say it, which means the control read as a breakout. That is a design failure, not a user failure.

Every attribute has two independent jobs:

| | Question it answers | Example |
|---|---|---|
| **Filter** | what gets counted | catering: exclude / include / only |
| **Breakout** | how the answer is split | catering as its own row or column |

Collapse them into one control and you get a dropdown that silently answers a question the user didn't ask. Keep them separate — in a clarifying question, in an artifact, and in your own SQL — and phrase each so its job is obvious ("this only decides what's *counted*"). The same applies to combo handling: *filter* to standalone-only is a different request from *breaking out* alone-vs-combo, and the old builder had them fused into one three-way toggle.

### When the same request comes back a third time, generalise the axis

Also 2026-07-30. The item builder was asked for market, then week-ending + store name, then more. None of those were new features — they were the same feature (group by something) unable to hold more than one value. The tell that you're patching the wrong axis: **each new request is the same verb with a different noun.** When you see that, widen the axis (make grouping a set) rather than adding another option to a fixed list. Adding the option ships faster and guarantees a fourth request.

### Answer item questions in UNITS by default — dollars are opt-in (steward rule 2026-07-30)

**Combo pricing makes per-item dollar totals misleading**, so don't reach for dollars just
because someone said "sales." Report units, and offer dollars as a follow-up with the
caveat attached.

Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27, non-catering, store 1111 excluded:

| Sale shape | Units | Gross | **Per unit** |
|---|---|---|---|
| Sold alone | 24,125 | $215,890 | **$8.95** ← the menu price |
| In a combo, paid | 47,461 | $315,280 | **$6.64** ← allocated, 26% below menu |
| In a combo, free | 37,623 | $386 | **$0.01** |
| **Blended** | **109,209** | **$531,556** | **$4.87** |

A naive average price is **46% below the menu price**, and it moves with combo mix rather
than with anything anyone changed. Two items with identical menu prices will show different
"average prices" purely because one is bundled more often.

Rules:

- **Default to units.** They're unambiguous across all three shapes.
- **If the user explicitly asks for dollars or revenue**, give `item_gross_sales` and say in
  the same breath that combo components are booked at an allocated price, not the menu
  price, and that this is *gross* — order-level discounts and promotions are not allocated
  per item, so it will not tie to net sales.
- **If they want a revenue number to quote or reconcile**, that is not an item question —
  point them at order-level `net_sales` from `order_customer` and say why.
- **Never compute an "average item price"** by dividing item gross by units without stating
  the combo mix. It is the single most quotable wrong number this mart can produce.

The `artifacts/item-sales-builder.html` report builder enforces exactly this: units by
default, dollars behind a checkbox that surfaces the warning. **Chat answers and the tool
must agree.**

### Try 2 Combo applies to soups, sandwiches, and salads — NOT bowls (verified 2026-07-30)

`parent_rev_center_name = 'Try 2 Combo'` over 2026-05-03 → 2026-06-27, store 1111
excluded, spans these revenue centers only:

| `rev_center_name` | Lines | Distinct items |
|---|---|---|
| Combos | 863,383 | 1 |
| Sandwiches | 705,355 | 14 |
| Modifiers | 684,714 | 90 |
| Soups | 565,433 | 14 |
| Salads | 465,498 | 10 |
| Sides/Misc Items | 114,094 | 3 |
| Non Food/Bev Mis | 54,845 | 1 |
| Desserts | 10,069 | 1 |

**`Bowls` does not appear.** Confirmed at the item level: `Power Bowl` and
`Hot Honey Cottage Cheese Bowl` have **zero** `parent_rev_center_name = 'Try 2 Combo'`
lines of either shape. So for a bowl, the combo fork has one possible answer and must not
be asked. For a sandwich in the same question, it must be. **A mixed-item question needs
the fork asked once and applied only to the eligible items** — and the answer should say
which items it affected.

> **⚠️ Zero combo lines ≠ zero modifier lines** (corrected 2026-07-30). Bowls *do* appear
> as zero-priced `modifier` lines — 5,615 over that window — but all of them are
> `is_catering = true` under `parent_rev_center_name = 'Box Lunches'`. They're invisible
> under `is_catering = false`, which is precisely how the first draft of this note reached
> the wrong conclusion. Qualify every combo-slot test with
> `parent_rev_center_name = 'Try 2 Combo'`. **The general lesson is the one that matters:
> a "zero" you found while a filter was applied is not a zero.**

### Discount and promotion lines carry names that look like items — filter both out of discovery

A discount on an item produces a line with the **item's name** in `item_name`,
`rev_center_name = 'Discount'`, `line_item_type = 'discount'`, and (since 2026-07-30)
`item_type = 'Discount'`. In the discovery query these appear as a **second candidate row
for the same product**, so the user is asked to choose between two entries that look
equally real.

**Promotion lines do the same thing as of 2026-07-31.** They now carry the *promotion's*
name — `Free Try 2 Combo`, `Free Mini Strawberry Cup`, `Free Dubai Cup` — so a search for
"try 2 combo" or "strawberry" returns a promotion as if it were a menu item, and it also
passes the standalone-sale test. All three markers read `'Promotion'` (a second build pass
that day added `rev_center_name`; earlier the same day it was NULL there). Always add:

```sql
and ifnull(ol.item_type, '') not in ('Discount','Promotion')
and ifnull(ol.rev_center_name, '') not in ('Discount','Promotion')
and ifnull(ol.line_item_type, '') not in ('discount','promotion')
```

Show `item_type` alongside `rev_center_name` in the candidate list — it's how a user tells
a real entrée row from a lookalike (steward rule 2026-07-30).

> **The reusable lesson: an upstream fix can create a downstream trap.** Naming promotions
> was strictly an improvement to the promotion data — and it moved 240K rows out of "NULL,
> invisible" into "looks like a menu item." When a build script starts populating a column
> that used to be empty, ask what *else* reads that column before calling the change safe.

## Step 3 — answer with the scope visible

Every answer states, in one line near the top:

- the dataset (`claude` or `sales_ops`) and the KB commit hash
- the resolved meaning of any fuzzy term ("market = store_state")
- the date range as explicit dates
- the choices the user made (catering, combos, item list)
- the locked rules applied (store 1111 excluded, gross not net)

Then the number, then the SQL.

## Worked example

**User asks:** "sales data by market for the following items from May 3rd 2026 to June
27th 2026? Ultimate Grilled Cheese / Honey Bacon Club / Power Bowl / Hot Honey Cottage
Cheese Bowl"

**What you do before saying anything:**

1. Check for a market column → none exists → market = `store_state`.
2. Run the `like` discovery on the four names. Result (that window, store 1111 excluded):

| Wanted | Also matches |
|---|---|
| Ultimate Grilled Cheese (110,699 lines) | Ultimate Grilled Cheese Box (43), Brisket Grilled Cheese (104,946), Grilled Cheese Sandwich — kids (93,433) |
| Honey Bacon Club (111,833) | Honey Bacon Club Box (92), Honey Bacon Club Sand — Party Trays (73) |
| Power Bowl (84,790) | TRAY Power Bowl (1) |
| Hot Honey Cottage Cheese Bowl (84,905) | a `Discount`-type row (319) |

3. Note the two sandwiches are combo-eligible and the two bowls are not.

**Then ask once** — four options groups: which item names to include (exact four vs.
include the catering Box/Tray SKUs), measure (units, dollars, or both), catering
(exclude / include / catering only), and combo handling for the two sandwiches only
(split standalone vs combo `(Recommended)`, standalone only, combined).

**Then answer.** With market = state, non-catering, sandwiches split and bowls
standalone-only, the four items did **$3.14M** of item gross over that window, 40% of it
in Utah. Ultimate Grilled Cheese in Utah: 10,307 standalone units against 25,647 priced
combo components — i.e. answering "standalone only" without asking would have understated
that item by about 71%.

## Installing the report builder (Cowork artifact)

The repo ships a persistent click-to-run report page at
[`artifacts/item-sales-builder.html`](../../artifacts/item-sales-builder.html) — a general
report builder over `claude.order_lines`, not just an item report (rebuilt 2026-07-30; the
filename and artifact id are kept for continuity so existing pinned pages keep working).

What it covers:

| | |
|---|---|
| **Items** | optional — search resolves names against live data; leave empty for all items |
| **Time grain** | none / week ending (Saturday) / day / month / quarter / year, with snap-to-whole-weeks |
| **Break out by** | any combination, in the order clicked: market, store, item, item category, menu section, menu group, item size, catering, sale shape |
| **Filters** | catering (exclude / include / only) and combo handling (all / alone / in-combo) — **independent of** whether either is broken out |
| **Measures** | units (default), orders, item gross sales, item net sales — multi-select, each with its warning |

Locked rules are applied and listed on the page: stores 1111 and 999 excluded, null-safe
discount exclusions, 10,000-row cap with a truncation warning. The generated SQL is always
shown and copyable, and results export to CSV.

**Its answers must match yours.** If you answer one of these questions in chat, use the
same expressions — particularly `week_ending` and the null-safe discount filters. (Stores
1111/999 are excluded by the `claude` views themselves; neither the tool nor your chat SQL
needs to write the predicate — steward rule 2026-09-03.) A tool and a chat answer that
disagree is worse than either one alone.

**It does not arrive by cloning.** Cloning gives an inert HTML file in a temp folder.
Cowork artifacts live in a per-user manifest, so the page has to be registered inside the
user's own session.

**Install it when the user asks for a report builder, a dashboard, a reusable report, or
"something I can run myself."** Don't install it unprompted.

Steps:

1. Read `artifacts/item-sales-builder.html` from **this session's fresh clone**.
2. Replace the placeholder **`__BQ_TOOL__`** with the *fully-qualified name of the BigQuery
   read-only query tool available in this session* — something shaped like
   `mcp__<connector-id>__execute_sql_readonly`. **Use your own session's tool name; never
   copy one out of documentation or a previous session.**
3. Write the substituted HTML to your working directory and call `create_artifact` with
   `id: "item-sales-builder"` and that same tool name in `mcp_tools`.
4. Tell the user it's pinned and re-openable, and that it re-queries live on each open.

> **Why the placeholder exists.** Connector ids are assigned **per user**. A hardcoded id
> works for exactly one person and fails for everyone else — and it fails *after the page
> renders correctly*, so it looks like a data problem rather than a setup problem. The page
> carries a guard: if `__BQ_TOOL__` was never substituted it disables its own buttons and
> says so, rather than presenting an empty report.

If `create_artifact` isn't available in the session, say so plainly — the user is likely not
in Cowork mode — and fall back to answering the question in chat with this skill's normal
clickable-choices flow. Don't paste raw HTML into the conversation as a substitute.

## What not to do

- **Don't guess and caveat.** "Assuming market means state…" buried under a number the
  user will screenshot is not a clarification. Ask.
- **Don't ask more than once** unless the user's answer opens a genuinely new fork.
- **Don't ask about locked rules.** Store 1111 is not a preference.
- **Don't offer a fork you haven't measured.** Options without sizes are guesses dressed
  as choices.
- **Don't return $0 or an empty table as an answer.** Zero rows means the name, the date
  window, or the dataset floor is wrong (`claude` history starts 2023-01-01 and truncates
  silently). Say so and widen.
- **Don't run SQL the user pastes without checking it** (steward rule 2026-08-05). Pasted
  SQL referencing `pulse.*`, `sessionM.*`, `staging.*`, `brink.*`, `braze_stream.*` or the
  legacy `OrderCustomer` table is a wall violation regardless of who wrote it. Say why,
  then offer the mart translation — the marts answer the common workbook questions
  (cohorts via `customer_order_count`, offers via `claude.loyalty_offer_usage`, promotions
  via `line_item_type = 'promotion'`). Observed 2026-08-04: 75 raw-dataset queries ran
  MCP-labeled through two analyst sessions this way.

## When done

If you learned something new during the session — a term that needed resolving, a fork
that mattered, a name that resolved badly — do **not** edit this skill or any local copy.
Create an Asana task on the **Claude Data** board (workspace cafezupas.com, project
`1216769551099591`) titled `KB finding: <short title>` with what you observed and the
proposed change. The steward reviews and merges; the next session's fresh clone benefits.
