# Item questions: combos, discount/promotion lines, names and sizes

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question names an item, a soup/sandwich/salad (Try 2 Combo), a size, or counts item units; or you report promotion or discount-program totals from `order_lines`.
> Content moved verbatim from `SKILL.md` on 2026-10-14 (router split); the rules and dates inside are unchanged.

### 4. Try 2 Combos — ask whenever the question involves soups, sandwiches, or salads

Any question naming a soup, sandwich, or salad (or the `Soups` / `Sandwiches` / `Salads` revenue centers, or `item_type = 'Entree'`) must confirm: **does the user want only items sold standalone, or also the ones bundled inside a Try 2 Combo?**

This is not a rounding difference. For Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27: **24,125 standalone vs 85,084 inside combos** — combos are ~78% of units. Answering the wrong one is off by 4x. See the combo line taxonomy below for the exact SQL, and **present the split** rather than a single blended number whenever combos are included.

**Bowls are NOT combo-eligible — don't ask the question for them** (verified 2026-07-30). `parent_rev_center_name = 'Try 2 Combo'` spans only these revenue centers over 2026-05-03 → 2026-06-27 (store 1111 excluded): `Combos` (863,383 lines), `Sandwiches` (705,355 / 14 items), `Modifiers` (684,714), `Soups` (565,433 / 14), `Salads` (465,498 / 10), `Sides/Misc Items` (114,094), `Non Food/Bev Mis` (54,845), `Desserts` (10,069). **`Bowls` never appears.** Confirmed at item level: `Power Bowl` and `Hot Honey Cottage Cheese Bowl` have **zero** `parent_rev_center_name = 'Try 2 Combo'` lines of either shape. So a question mixing sandwiches and bowls needs the combo fork asked **once and applied only to the eligible items**; say which items it affected. Asking it about a bowl is a dead question that makes the clarification protocol look like noise.

> **⚠️ "Zero combo lines" does NOT mean "zero modifier lines"** (corrected 2026-07-30 — the first draft of this note got it wrong and it's worth keeping the correction visible). Bowls **do** appear as zero-priced `line_item_type = 'modifier'` lines: 5,615 over 2026-05-03 → 2026-06-27 (Power Bowl 3,833, Hot Honey Cottage Cheese Bowl 1,782), **every one of them `is_catering = true` with `parent_rev_center_name = 'Box Lunches'`**. They are invisible under `is_catering = false`, which is exactly how the wrong conclusion was reached. **So the taxonomy row "Combo slot (zero-priced) = `line_item_type = 'modifier'`" is incomplete as written** — always qualify it with `parent_rev_center_name = 'Try 2 Combo'`, or Box Lunch units silently land in the combo bucket the moment catering is included.

### Discount AND promotion lines masquerade as items — exclude both from item reports (steward rule 2026-07-30, extended 2026-07-31)

A discount applied to an item produces a line carrying **the item's own name** in `item_name`, with `line_item_type = 'discount'`. Over 2026-05-03 → 2026-06-27 the four-item test set had 319 such lines: $0 gross but **319 units**. *(Historical behavior — the discount half of the name collision was fixed upstream 2026-08-12; see the box below. The unit-count inflation still applies to both line types.)*

Two consequences. They inflate any unit count not filtered to `line_item_type in ('item','modifier')`. And, more insidiously, they surfaced as a **separate candidate row in the name-discovery query** (protocol item 5) — so a user resolving "Hot Honey Cottage Cheese Bowl" saw two entries for one product with no way to tell which is real.

> **✅ Partly fixed upstream 2026-07-30.** The build script now stamps discount lines consistently: `rev_center_name`, `item_type`, `parent_rev_center_name` and `parent_item_grp_name` are **all `'Discount'`**. Verified live — all 113,136 discount lines in that window carry the identical set. Previously `item_type` held the *item's name*, which is why it couldn't be filtered on. It can now. `item_name` still carries the item's name by design, so the discovery-query collision remains and the filters below are still required.

> **🆕 2026-07-31 — promotion lines joined the problem.** The build now resolves promotion names from `brink.brinkPromotions`, so a promotion line carries `item_name = 'Free Try 2 Combo'` / `'Free Mini Strawberry Cup'` / `'Grand Opening 100%'` where it used to carry NULL. It also carries `qty = 1` and `item_gross_sales = 0`, and it **passes the standalone-sale test** — `parent_rev_center_name` and `rev_center_name` are both `'Promotion'`, so a sale-shape breakdown files promotions under "sold alone" exactly as discount lines already did. Volume over 2026-05-03 → 2026-06-27: 1,111 lines / 1,111 phantom units.
>
> A **second pass the same day** added `rev_center_name = 'Promotion'`, so all three markers now agree and any of them excludes promotions. Earlier on 2026-07-31 `rev_center_name` was NULL on these rows and only `item_type` / `line_item_type` worked — if you are reading a result set or a saved query from that window, that's why.

> **✅ 2026-08-12 — the discount half of the name collision is fixed upstream (full history restated).** Discount lines now carry the discount **program** name in `item_name` (`SessionM Loyalty`, `Online Discount`, …), resolved from `brink.brinkDiscounts` per (id, store); the redeemed item's name lives only in `description`. The name-discovery query no longer surfaces phantom *discount* rows for a product. Verified live 2026-08-12: 0 blank `item_name`; ~3–7% of a day's discount lines fall back to the order-level name and then the generic `'Discount'` (missing/blank master rows). **Promotion lines still collide** — everything in the 2026-07-31 box above still applies to them — and both line types still inflate unfiltered unit counts, so the three-marker exclusion below is still required verbatim. Side effect worth knowing: `description` on team-member discount lines can carry an **employee's personal name** — don't surface it in shared reports without checking.

Filter them in **both** the discovery query and the metric query:

```sql
and ifnull(ol.item_type, '') not in ('Discount','Promotion')
and ifnull(ol.rev_center_name, '') not in ('Discount','Promotion')
and ifnull(ol.line_item_type, '') not in ('discount','promotion')
```

Since the 2026-07-30/31 fixes, `item_type not in ('Discount','Promotion')` is a reliable test on its own — but keep all three conditions: they're free, and they still hold for any pre-fix data you compare against.

> **⚠️ Wrap every string exclusion in `ifnull` — the bare form silently drops rows** (steward rule 2026-07-30). `col <> 'Discount'` evaluates to NULL, not TRUE, on a NULL `col`, and BigQuery's `WHERE` treats NULL as false. Those rows vanish with no warning. Re-measured 2026-07-31 over 2026-05-03 → 2026-06-27 (stores 1111 and 999 excluded, 10,018,577 lines): **`item_type` 0 nulls, `parent_rev_center_name` 0, `item_name` 0, `rev_center_name` 2** (both surcharge lines — stamped `'Surcharge'` by the second pass, so **0** as of 2026-08-12). The earlier counts (1,111 / 1,113 / 497) were *all* unnamed promotion lines; the 2026-07-31 build named them and then stamped their revenue center, which removed the cause on every column. **Keep the `ifnull` habit anyway** — it costs nothing, and the next upstream gap will arrive unannounced. Note also how fast these numbers moved: the same column went 1,113 nulls → 1,113 → 2 inside one day, which is why a skill should date every measured claim rather than state it as a property of the table. The same trap sits inside combo-shape logic: `parent_rev_center_name = rev_center_name` is NULL-unsafe, so use `ifnull(ol.parent_rev_center_name, '') = ifnull(ol.rev_center_name, '')` when testing for a standalone line.

### Promotion reporting is now answerable (new 2026-07-31)

"What did we give away on promotion X?" used to be unanswerable from the marts — 71.4% of promotion lines (171,522 of 240,191 in full history) had a NULL name because `brinkOrderPromotion.Name` is mostly empty. The build now joins the `brinkPromotions` name master on **(promotion id, store)**; names are store-specific, so an id-only join would mislabel. Promotion value = `sum(ol.amount)` (negative), **not** `item_gross_sales` (always 0). Full history back to 2018-08-28; 4 lines in all history have no master row and read `'Promotion'`.

```sql
select
ol.description as promotion_name
, count(*) as lines
, round(sum(ol.amount), 2) as promotion_amount
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start_date and @end_date
and ol.line_item_type = 'promotion'
and ol.store_id not in (1111, 999)
group by 1
order by promotion_amount
```

### Discount-program reporting is now answerable (new 2026-08-12)

Same shape as promotion reporting, but group by **`item_name`** — on discount lines it now carries the program name from the `brink.brinkDiscounts` master. Do **not** group by `description` for program-level questions: it holds the free-text POS name (often the redeemed item, sometimes an employee's personal name — don't surface it unchecked).

```sql
select
ol.item_name as discount_program
, count(*) as lines
, round(sum(ol.amount), 2) as discount_amount
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start_date and @end_date
and ol.line_item_type = 'discount'
and ol.store_id not in (1111, 999)
group by 1
order by discount_amount
```

Full history restated, so this works back to 2018. ~3–7% of a day's lines land in the generic `'Discount'` bucket (missing or blank master rows) — say so when a user needs exact program totals.

> **🆕 Superseded for most questions by `claude.order_line_discount_detail` (2026-08-15).** The recipe
> above still works and is the cheapest way to get a raw program total, but it can't tell you
> *how* a discount was redeemed — points vs reward vs offer, which offer, in-store vs
> integrated. Use `claude.order_line_discount_detail` for anything past a flat program total. See the
> section below.


### 5. Named products — resolve the name against the data FIRST, then confirm

When the user asks about a specific product by name, **do not guess the string and go straight to the metric query.** `item_name` values don't match how people speak, one spoken name can span several rows (sizes, catering variants, LTO renames, seasonal spellings), and a wrong guess returns a clean-looking wrong number — or zero rows presented as "no sales."

Run a cheap discovery query first, show the user the list, and get confirmation:

```sql
select
ol.item_name
, ol.item_size
, ol.item_id
, ol.rev_center_name
, ol.item_type
, count(*) as lines
, sum(ol.qty) as units
, round(sum(ol.item_gross_sales), 0) as gross_sales
, round(sum(ol.item_gross_sales) / nullif(sum(ol.qty), 0), 2) as avg_unit_price
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id not in (1111, 999)
and lower(ol.item_name) like '%grilled cheese%'   -- broadest distinctive fragment, lowercased
group by 1, 2, 3, 4, 5
order by lines desc
```

- Match on the **shortest distinctive fragment**, lowercased on both sides. `like '%ultimate grilled cheese%'` misses `Ultimate Grilled Cheese Box`; `like '%grilled cheese%'` finds the family.
- `item_name` is a **cluster field** — these filters are cheap. Still filter `business_date`.
- **Group by `item_id` and `item_size`, and show the average unit price.** One `item_name` routinely covers several products; the price column is what makes a wrong pick visible to the user. See the size rule immediately below.
- Show the candidates with their volumes, sizes, prices and revenue centers so the user can see what they're choosing between, then ask which to include. Zero rows = say so and widen the fragment; never report `$0`.
- Only after the list is confirmed, run the metric query against the agreed **`item_id in (...)`** set (fall back to `item_name` + `item_size` only if the ids weren't resolved).

**Worked example (verified 2026-07-28, 2026-05-03 → 2026-06-27, store 1111 excluded).** "Grilled cheese" resolves to **four** different items, which is exactly why this step exists:

| `item_name` | Standalone | Combo component | Bundle slot ($0)\* |
|---|---|---|---|
| `Brisket Grilled Cheese` | 28,891 | 44,874 | 31,181 |
| `Ultimate Grilled Cheese` | 24,125 | 47,461 | 39,113 |
| `Grilled Cheese Sandwich` | **52** | 28,340 | 65,041 |
| `Ultimate Grilled Cheese Box` | 43 | — | — |

\* All zero-priced `modifier` lines, both catering flags — i.e. Try 2 Combo **plus** Box Lunches. The Try 2 Combo–only subset for Ultimate Grilled Cheese is 37,623 (the figure used in the taxonomy below); the remaining 1,490 are Box Lunches. Scope your `parent_rev_center_name` filter deliberately.

Note `Grilled Cheese Sandwich` is effectively a **combo-only item** — 52 standalone lines against 93K combo appearances. If a user says "grilled cheese" and you silently pick one name, you can be off by an order of magnitude or answer about the wrong sandwich entirely.

**Also: `Ultimate Grilled Cheese Box` carries `is_catering = false`** despite being the catering box product. So `is_catering = false` does **not** reliably strip catering-only SKUs — the catering question (item 3) and the name question (item 5) are independent, and you need both.

> **Catering ITEM ≠ catering ORDER — and there is no canonical item-side flag (first live demand 2026-09-02).** "How many trays did we sell the week before Labor Day, outside catering?" was answered three ways in one session: `rev_center_name = 'Party Trays & Food'`, `item_size in ('Party','Tray')`, and `lower(item_name) like '%tray%'`, then joined to `order_customer` with `revenue_category <> 'Catering'` to keep only regular-channel orders. Each arm returns a different population. Until an `is_catering_item` column exists (Asana 1218146236424381), use the rev-center list — `Party Trays & Food`, `Box Lunches`, `Cater Desserts`, `Cater Beverages` — as the item-side definition, exclude Discount/Promotion lines as usual, and say in the answer which side (order or item) the word "catering" applied to.

#### Size is a separate column — and `item_name` is not a product (steward rule 2026-08-27)

**The build strips the size prefix out of `item_name` and parks it in `item_size`.** In
`sql/sales_ops.order_lines.sql` the published `item_name` is the size-stripped
`item_grp_name` (line 395), and the prefix regex is
`^(REG|Mini|LG|PRTY|HALF|Kids|LARGE|Medium|Tray|QUART) `. So the name a user speaks and the
string in the column are **not the same string**:

| Predicate | Result |
|---|---|
| `ol.item_name = 'Mini Chocolate Strawberry Cup'` | **zero rows** — reads as "no sales" |
| `lower(ol.item_name) like '%chocolate strawberry%'` | the family, sizes visible |
| `ol.item_name = 'Chocolate Strawberry Cup' and ol.item_size = 'Mini'` | ✅ the product |

**Never put a size word inside an `item_name` predicate.** Match the name without it, then
filter `item_size`. A user asking about the "mini chocolate strawberry cup" is naming two
columns, not one — and the failure mode is a silent zero, which the user reads as the item
not existing.

**Worked example — Mini Chocolate Strawberry Cup** (re-measured 2026-09-11, trailing 30 days
**2026-08-12 → 2026-09-10**, sellable lines, stores 1111/999 excluded):

| `item_id` | `item_name` | `item_size` | Units | Item gross | Avg unit price |
|---|---|---|---|---|---|
| 643640578 | `Chocolate Strawberry Cup` | `Mini` | 15,717 | $141,453 | **$9.00** |
| 643640567 | `Chocolate Strawberry Cup` | `Regular` | 5,241 | $73,374 | **$14.00** |
| | | *name only* | *20,958* | *$214,827* | *$10.25* |

Answering on the name alone overstates the Mini by **33.3% in units / 51.9% in gross**, and
reports a blended **$10.25** price for a product sold at $9.00 and $14.00 and never at
$10.25. Both ids have sold since **February 2025** — not an LTO artifact, and nothing about
the name hints that it splits.

> **Both prices and the split are stable.** First measured 2026-08-27 (30 days to 08-26):
> 15,550 / 5,051 units, same $9.00 and $14.00, blended $10.23. Two weeks later the unit mix
> and the blend have barely moved. This is a permanent property of the catalogue, not a
> window artifact — don't re-derive it per question.
>
> **643640567 is `Regular`, and has been since the 2026-08-27 rebuild.** Anything still
> describing the full-size cup as NULL-sized predates that rebuild and is wrong in the
> opposite direction now: `item_size = 'Regular'` finds it, and `item_size is null` finds
> nothing at all (see the dead-filter warning below).

> ✅ **`item_size` has no NULLs and `Regular` means an actual regular size (rebuilt
> 2026-08-27 12:35 MT).** The column is a closed 9-value domain resolved in four steps:
>
> ```sql
> case
> 	when l.line_item_type not in ('item', 'modifier') then 'Not Applicable'
> 	when l.item_size is not null                      then l.item_size
> 	when f.family_has_sizes                           then 'Regular'
> 	else 'Not Sized'
> end as item_size
> ```
>
> where `family_has_sizes` comes from the **item master** (`brink_items`), not from the fact
> rows — so the value does not depend on how wide that run's reload was. Distribution
> re-measured 2026-09-11 over **2026-09-04 → 2026-09-10** (stores 1111/999 excluded); the
> 2026-08-20 → 08-26 shares from the original measurement are shown beside it:
>
> | `item_size` | Lines | Share | (08-20→26) | Names | Means |
> |---|---|---|---|---|---|
> | `Not Sized` | 757,187 | 60.8% | 62.5% | 245 | a real product with no size concept (chips, bottled drink, cookie) |
> | `Half` | 166,038 | 13.3% | 13.0% | 27 | |
> | **`Regular`** | **147,932** | **11.9%** | 11.7% | 41 | base size of a family that *has* other sizes, or a genuine `REG` prefix |
> | `Kids` | 71,751 | 5.8% | 5.1% | 28 | |
> | `Large` | 55,046 | 4.4% | 4.4% | 40 | |
> | `Not Applicable` | 38,888 | 3.1% | 2.6% | 26 | not a product line — tip, fee, discount, promotion, gift card, surcharge |
> | `Mini` | 7,013 | 0.6% | 0.5% | **2** | still only `Chocolate Strawberry Cup` and `Dubai Cup` |
> | `Party` | 751 | 0.1% | — | 7 | |
> | `Tray` | 15 | 0.0% | — | 4 | |
>
> Every share is within ~1 point of the original, so treat these as the settled shape rather
> than a moving number. **A size breakout is safe to present unlabelled** — `Regular` is ~12%,
> not 76%, and the two non-size states are named rather than hidden inside it. Filter
> `line_item_type in ('item','modifier')` for any size analysis and `Not Applicable` disappears.

> ⚠️ **Three semantics shipped for this column on 2026-08-27, hours apart.** NULL-for-unparsed
> (until ~10:53 MT), then `coalesce(..., 'Regular')` which made `Regular` **76.3%** of lines
> (10:53 → 12:35), then the CASE above. A query written against any earlier version still runs
> and returns a different number, silently. In particular **`item_size is null` is dead** — it
> returns zero rows rather than the unsized items, so it reads as "no such thing" instead of
> erroring. If you are handed a saved query or an older report that touches `item_size`,
> re-read it before trusting the number.
>
> **Why `family_has_sizes` reads the item master and not the facts** (measured before the fix):
> deriving it from `order_lines_detail` bounds it by the run's reload window, so the same item
> got different labels depending on which run wrote the partition — full-history CTAS most
> generous, 8-day narrower, intraday narrowest. On a one-day window **11 of 316 names / 2,645
> of 212,311 lines (1.25%)** flipped `Regular` → `Not Sized`: `Brisket Grilled Cheese` plus
> most fountain and bottled beverages, i.e. families whose sized variant simply does not sell
> every day. The item-master version misses **none** of the families the 30-day facts find and
> adds **11** more (a Half on the menu is a size whether or not one sold). **The general rule:
> never derive a dimension's meaning from the fact window — a dimension must not change
> because a reload was narrower.**
>
> **The reusable lesson (third instance in this KB): an upstream fix creates a downstream
> trap** — and the second fix can create its own. Filling a formerly-NULL column changed what
> every existing filter included; naming the unparsed case `Regular` then overloaded a label 22
> item names already meant something specific by. Both were improvements. Both moved millions
> of rows into a bucket something else was already reading.

**Size is necessary but not sufficient — `item_id` is the product key.** Re-measured
2026-09-11 over **2026-08-12 → 2026-09-10**, 374 `item_name` values on sellable lines
(discount/promotion markers excluded); the 2026-08-27 figures are in brackets:

| | Names | Share of names | Share of units |
|---|---|---|---|
| Span more than one `item_id` | **142** [140] | 38.0% [37.5%] | **50.6%** [50.1%] |
| …of which split by `item_size` | 49 [49] | 13.1% | 21.3% [21.0%] |
| …of which split by something **other** than size | **93** [91] | 24.9% | — |

Half the volume in the mart sits under a name that is not unique to one product, and size
explains only a third of those splits — and both figures have held steady across two
independent windows two weeks apart. Resolve to `item_id`; treat size as the most common
reason a name needs resolving, not the only one.

Two more instances of the same collision, so it is a pattern and not one dessert
(same window, re-verified 2026-09-11):

- **`Dubai Cup`** — identical shape: id 643640588 `Mini` **$12.00** (14,948 units), id
  643640587 `Regular` **$18.00** (4,638). `Mini` still exists on exactly these two names.
- **`Kids Combo`** — the same collision with no size story: id 643647054 is the `Kids`
  **$0.00** bundle slot (46,653 units), id 642361971 is the `Regular` **$7.26** paid combo
  (39,844). One name, two things, and a units count on the name double-counts every kids
  meal — here that is 86,497 where the real paid figure is 39,844.

**A size word can still survive inside `item_name`** — 14 names in the window carry one,
because the strip runs once and is case-sensitive: `PRTY TRAY Avocado Caesar Salad` loses
`PRTY` (→ `item_size = 'Party'`) and keeps `TRAY`; `Kids Combo` is special-cased to no
parsed size; and lines that miss the item master fall back to `description`, which was never
stripped (`Mini Chocolate Chips` — a Mini whose `item_size` is decided by its family, not by
the word in its name). So matching the bare name is right — but
**the absence of a size word in a name is not evidence the item has no sizes.** Check
`item_size` every time.

**`item_name` is not trimmed — two live SKUs carry a trailing space** (measured 2026-09-05,
stores 1111/999 excluded): `'Apple Juice '` (id 643636585, 839 lines that day) and
`'Strawberry Daiquiri Mocktail '` (ids 643644616 / 643644617, 73 lines). `item_name = 'Apple
Juice'` returns **zero rows** and reads as "we don't sell it" — the same failure mode as the
size strip. Resolve names with `lower(item_name) like '%…%'` or `trim(item_name)`, and once
resolved **filter on `item_id`**, never on the bare name. The analyst who found it wrapped every
`item_name` in `trim()` for a whole session (2026-09-08); the build should strip it once instead
(logged as a build fix). Same table, same lesson as `Foutain Beverages`: the `rev_center_name`
typo is a real value and must be matched as spelled.
