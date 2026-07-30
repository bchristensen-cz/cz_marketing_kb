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

Discovery is cheap (`item_name` is a cluster field; `store_info` is 99 rows). Asking
blind is expensive — it costs the user a round trip and produces worse options, because
you can't show the size of a choice you haven't measured.

### Never ask a question the data can answer

If `store_info` has one state per store, don't ask "which stores are in the Phoenix
market" — read it. If `is_catering` is false on every matching line, don't ask about
catering — say so and move on. **Only surface a fork that is genuinely the user's call.**

### Never ask a dead question

Check whether a fork applies before presenting it. Asking about Try 2 Combo on a question
about bowls (see below) teaches the user that the clarifications are noise.

## Step 1 — resolve the nouns

| The user said | Before asking anything, run |
|---|---|
| a product name | the `like` discovery query from `sales-ops-orders` (pre-query protocol item 5) |
| "market", "region", "area" | see the market rule below — it is **`store_state`** |
| a store by name | `select si.store_id, si.store_name, si.store_city, si.store_state from ... store_info si` |
| a category | `select distinct ol.rev_center_name` / `ol.item_type` on the date range |
| a campaign | the Braze / SessionM lookup in the relevant skill |
| a fuzzy date ("last week", "May") | resolve to explicit dates; business week is **Mon–Sat** |

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
| Measure — units vs dollars | always for item questions | per-item **net is not computable**; dollars = `item_gross_sales` |
| Catering | always | — |
| Try 2 Combo | **only** for soups, sandwiches, salads (see below) | — |
| Which item names | whenever discovery returned >1 candidate | — |
| Channel | only if the user hints at it | default: all channels |

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

### Discount lines carry the item's own name — filter them out of discovery

A discount on an item produces a line with the **item's name** in `item_name`,
`rev_center_name = 'Discount'`, `line_item_type = 'discount'`, and `item_type` set to the
item name rather than `'Entree'`. In the discovery query these appear as a **second
candidate row for the same product**, so the user is asked to choose between two entries
that look equally real. Always add:

```sql
and ol.rev_center_name <> 'Discount'
and ol.item_type <> 'Discount'
and ol.line_item_type <> 'discount'
```

Show `item_type` alongside `rev_center_name` in the candidate list — it's how a user tells
a real entrée row from a lookalike (steward rule 2026-07-30).

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

## When done

If you learned something new during the session — a term that needed resolving, a fork
that mattered, a name that resolved badly — do **not** edit this skill or any local copy.
Create an Asana task on the **Claude Data** board (workspace cafezupas.com, project
`1216769551099591`) titled `KB finding: <short title>` with what you observed and the
proposed change. The steward reviews and merges; the next session's fresh clone benefits.
