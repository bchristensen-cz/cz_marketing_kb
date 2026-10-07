# Gotchas checklist

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** scan before EVERY answer — this is the checklist the single file used to end with.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Gotchas checklist (scan before answering)

- **Raw `pulse.*` column types changed 2026-09-23 (steward note; standard users are unaffected).** `pulse.orders.id`, `pulse.customers.id` and `pulse.orders.brink_order_id` are now NUMERIC; `pulse.orders.is_catering`, `pulse.customers.is_catering`, `pulse.order_customers.is_loyalty_user` and the `pulse.order_payments.is_*` flags are INT64 0/1, not BOOL; `pulse.order_customers.phone` is INT64. The marts cast everything back, so `claude.order_customer.pulse_order_id` is still INT64 and `is_catering` / `is_guest_order` are still BOOLEAN. Consequences that day: the chained mart build failed 08:02–12:02 MT and was healed by a 12:17 run (no dates lost); `claude.order_payment_tender` failed to parse until a ~14:30 redeploy; `sales_ops.cust_map` will fail at 04:15 on 09-24 until its three `= false` / `= true` predicates are patched to `0` / `1`. Anyone writing steward SQL against raw Pulse: compare flags to `1`/`0` and cast ids at ingestion.

- **🚨 Never scan history for "first order ever" / "new customer" / "second order within N days"** — `customer_order_count`, `days_since_prev_order`, `first_order_date`, `lifetime_order_count` on `claude.order_customer` already carry it, and the mart's own floor is **2023-03-06**, so a `min() group by customer` from 2023 (or 2018, or 2015) returns the same population for ~2 GiB a run. 140 GiB on 2026-09-08 alone. Recipe and table in "Repeat-rate" §2.
- **"Earned" discounts = `discount_type in ('Reward Redemption','In-cart Points Redemption')`** (steward definition 2026-08-18). Both Brink ids belong: **`643571116` is a purpose-built in-store loyalty-redemption id** (the Cafe Zupas Rewards button), and 99.0–99.5% of reward lines on every id/origin resolve to a sessionM member wallet offer. `In-cart Points Redemption` carries the spend directly (`points > 0` on 100% of 33,702 lines). Earned = 103,540 lines / **−$752,606.55** of −$1,485,468.22 all discounts (50.7%), 2026-05-01 → 07-31. **Do not exclude `offer_kind = 'promotional'` rows** — a wallet offer issued rather than points-priced is still a member redemption; excluding them understates earned by −$36,798.41. `offer_kind` is a **breakdown within earned** for points-economics questions only. Full section above.
- **⚠️ Employee meals sit inside earned — 292 lines / −$4,255.83** in the window are `Reward Redemption` **and** `is_employee_meal_discount = true` (the `Team Member Meal` wallet offer). Both flags are canonical and correct; an earned-vs-employee rollup treating them as exclusive double-counts. Subtract the overlap explicitly.
- **🚨 `order_line_discount_detail.root_offer_id` mixes UPPERCASE and lowercase — `upper()` both sides of any offer join.** The sessionM arm of the `coalesce` is uppercase, the Pulse arm is lowercase, and `claude.loyalty_offer_usage` is uppercase. Joining raw matches **0 of 12,040** `Offer` lines (measured 2026-08-18) and fails silently in the direction that makes wallet offers look unresolvable. Build fix pending: `upper()` on `pd.sessionM_root_offer_id`.
- **⚠️ Wallet-offer attribution is not stable across reload widths.** Online reward `root_offer_id` coverage read 314/26,675 lines early on 2026-08-18 and 26,452/26,675 after the table was rebuilt at 17:15 MT that afternoon — same query, same window. Likely the `offer_detail` CTE's `create_date >= start_date - 60` filter, but **untested — don't repeat it as fact**. Practical rule: a coverage figure is only true as of a stated timestamp, and a low one means "check what last touched the partition" before it means "the data is missing."

- **🔴 Steward-only, and expensive: the `brink` child tables have no partitioning or clustering at all** (verified from DDL 2026-08-17). `brinkOrder` is `PARTITION BY BusinessDate`, but **`brinkOrderItem`, `brinkOrderSurcharge` and `brinkOrderDiscount` are plain unpartitioned tables keyed only on `orderId`**. Consequences, all measured 2026-08-15:
  - Looking up **one order** — `select boi.* from brink.brinkOrderItem where boi.orderId = 31418142951520` — billed **29.75 GiB**. There is no cheap single-order lookup in these tables.
  - **Filtering the parent does not prune the child.** `join brink.brinkOrder bo on bo.id = s.orderid and bo.BusinessDate > current_date - 90` still billed **30.2 GiB**, versus 29.77 GiB with no date filter at all — the predicate prunes `brinkOrder` and leaves the child full-scanned, because BigQuery cannot push a partition filter across a join. Widening 90 → 900 days cost 34.15 GiB, i.e. the date range was never the driver.
  - Four validation attempts on one afternoon billed **~124 GiB**. If you need line-level Brink truth, do it **once** into `scratch` and query that, and prefer `select` of named columns over `select *`.
  - For everyone who is not the steward this is moot — line-level questions run on `sales_ops.order_lines` / `claude.order_lines`, which *are* partitioned on `business_date`. This entry exists so the cost is a known quantity before the scan, not after.
- **Business questions run on the `claude` views for everyone except the steward — even for accounts whose IAM can read `sales_ops`.** A successful select from `sales_ops` is permission, not a routing signal (rule changed 2026-08-04). `Access Denied` on `sales_ops` is intended, not a broken setup. See the dataset-routing section near the top.
- **`claude` history starts 2023-01-01 and truncates silently.** The order views filter `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)`. An older range returns **zero rows, not an error** — which reads as "no sales." Check the window before reporting an empty result.
- **~~`revenue_category` means something different in `claude` than in `sales_ops`~~ — resolved 2026-08-17.** The `claude` view still forces `'Catering'` whenever `is_catering = true`, but the base build now does the same, so the two layers agree. Channel breakdowns produced **before** 2026-08-17 can still legitimately disagree across datasets (48 June 2026 orders) — state which you queried rather than reconciling them.
- **In `claude.order_customer`, `0` in a folded count column means "no upstream row," not zero orders.** `customer_order_count = 0` ⟺ unidentified (46.4% of June 2026 orders); `lifetime_order_count = 0` is broader at 51.5% — it also catches all kiosk, most internal, and most store-1111 orders, so 36,261 orders have a real sequence number but zero lifetime. Never `avg()` a lifetime column unfiltered; never present `lifetime_order_count = 0` as a cohort. The FLOAT/DATE lifetime columns are *not* coalesced and stay NULL, so the same absent customer reads `0` in one column and `NULL` in the next. Details in `data_dictionaries/claude.order_customer.md`.
- **There is no `claude.order_sequence` or `claude.customer_attribute`** — both are folded into `claude.order_customer`. Don't tell a user the data is unavailable; it's on the order view.
- **Demographics (`gender`, `birthday`, `age`) are on `claude.order_customer` since 2026-09-17 23:40 MT** (steward call; they had been `sales_ops`-only since 2026-09-15 because the view folds the attribute table in through a select list). Three rules when answering with them: (1) `gender` is lowercase two-valued (`female` / `male`, no `other` sentinel) and NULL for ~16% of customers, so quote shares on the **populated base**; (2) **`birthday` year `1950` is the app's placeholder for "year not provided"**: 54% of birthdays carry it, month and day are real, the year is not, so birthday-month work uses the whole column but anything needing the year excludes `extract(year from birthday) = 1950`; (3) **`age` is NULL on exactly those placeholder rows** and populated on the 127,906 real-year birthdays (9.6% of customers, 28% of identified person orders in a recent week), so **never compute an age from `birthday`**, read the column, and say the denominator when presenting an age split. All three are NULL on unidentified and non-person orders, like every other folded attribute.
- **A partition filter must be a constant, not a subquery — `business_date in (select business_date from d)` scans the whole table** (measured 2026-09-09: 19.1 GiB for ten business dates across `order_customer`, `order_lines` and `order_line_discount_detail`). BigQuery treats `in (select …)` as a semi-join it cannot prune on, even when the subquery is a literal `unnest([...])` CTE. Write the dates inline — `business_date in unnest([date '2026-08-07', date '2026-08-14', …])` — or bound with `between` and filter the specific days afterwards. The same rule is why `having date(min(odt)) between …` (Day 1 above) scans everything: the predicate is only knowable after the read.
- **`LIMIT` is not a cost control — a `select * … limit 10` peek at `order_customer` billed 5.29 GiB** (measured 2026-09-10, steward console; the same statement without the limit billed 14.57 GiB). BigQuery bills the columns read across the partitions scanned and applies `LIMIT` afterwards, so "just look at ten rows" costs GiB on any wide partitioned mart. To see the **shape** of a table use `INFORMATION_SCHEMA.COLUMNS` (free); to see **rows**, bound the partition first — `where business_date = current_date('America/Denver')` — and only then `limit`. Same family as the subquery-predicate entry above: predicates and clauses that look like they bound the scan and do not.
- **Looking up one order: carry its `business_date`. `brink_order_id` alone prunes nothing on `order_lines`** (measured 2026-09-22: a first-day console account paid **151.8 GiB for four lookups of a single order**, 62.1 GiB for the `select *` and ~30 GiB for each narrower rerun). `order_lines` is partitioned on `business_date` and clustered on `rev_center_name, item_name, parent_item_grp_name, parent_rev_center_name`, so `where ol.brink_order_id = ...` reads every partition of every selected column. The user had the date in the query and had commented it out (`-- and ol.business_date = '2026-09-08'`). Shape: `where ol.business_date = date '2026-09-08' and ol.brink_order_id = ...`, and join `oc` on **both** `brink_order_id` and `business_date`. If the date is unknown, look it up on `order_customer` alone first, inside a bounded range (`business_date >= date_sub(current_date('America/Denver'), interval 90 day)`; that table is clustered on `brink_order_id`), then pull the lines for that one date. Reruns are not free either: the result cache needs byte-identical text, and the fourth run differed from the third only by trailing blank lines, so it billed another 30 GiB.
- **🚨 `customer_hash.brink_order_customer_hash` is unpartitioned and unclustered** (DDL, 2026-09-10), so a `where BusinessDate >= …` on it prunes **nothing** — every read is a full table scan, whatever the predicate says. Analysts have been paying ~4.5 GiB per evaluation for a `hk` CTE that gets re-evaluated per query (51 reads / 157 GiB on 2026-09-09 alone). Until the 06:55 rebuild is partitioned, materialise the hash→order map to `scratch` **once** per session. Note this table is also the basis of an unratified second person-definition — see the identity note in the review log.
- **Two things already in the KB that keep getting re-derived (2026-09-09):** store open date is `store_info.store_open_date` — never `min(business_date) group by store_id` off the fact table; holiday exclusions are `claude.date_dim.holiday` — never a hand-typed `('07-03','07-04','07-05','12-24', …)` list, which drifts between two analysts' queries on the same day and silently omits Thanksgiving in one of them.
- **The partition column is `business_date` on every table** as of 2026-07-30. `order_lines` was rebuilt across full history that day and its `BusinessDate` column is **gone** — the long-standing two-spellings trap is closed. ⚠️ **Any saved query, template or workbook still writing `ol.BusinessDate` now fails outright** with `Unrecognized name: BusinessDate`. That is the good failure mode (loud, not silent), but it will hit the shared analyst workbook — read the error literally and swap in `business_date`.
- **`order_lines` has no `order_id`** — this now leads the gotcha list because it is the single most-repeated error in the query log: `Name order_id not found inside ol`, hit three more times on 2026-07-27/28 and **again on 2026-07-28 at 09:12** by the same analyst. The order key is `brink_order_id` on every one of these tables. The 2026-07-28 instance selected `ol.order_id` in a CTE and then joined `oc.brink_order_id = ol.order_id` — i.e. the correct column name was already in the query, on the other side of the join. Read your own join predicate before selecting.
- **Customer metrics need `customer_type = 'person'`**; sales metrics must NOT filter it. See the rule above.
- **`order_customer` emails are now lowercased at build** (fix deployed 2026-07-29 with the full-history rebuild; verified 2026-08-13: 0 non-lowercase `mapped_email` / `email` values in 365 days). `lower()` on them is a harmless no-op — keep it defensively, but the old "~17,900 overstated distinct emails" caveat no longer applies to current data. The SessionM fallback email also strips the leading `cater_` prefix, so catering logins resolve to the individual's address in `mapped_email` — when comparing to `claude.loyalty_user`, compare against its `email` column — which since the 2026-09-01 rename IS the stripped address (formerly `email_normalized`); the prefixed original is now `full_email`. Raw `pulse.*` / `braze.*` emails outside the marts still need `lower()`.
- **`oc.email` is the ORDER email; `pulse.customers.email` is canonical** (steward 2026-08-24).
  Per-order, user-supplied, fine for "which address got this receipt" and for reading the
  aggregator brand (`email like '%doordash%'` → 75,010 July orders; `mapped_email like
  '%doordash%'` → **none**, because the canonical there is `checkmate_user@cafezupas.com`).
  Never an identity, join, dedup or cohort key. `mapped_email` inherits the canonical when one
  exists (86.0% of July `person` orders) and is user-typed on the rest.
- **`pulse.customers.primary_email` is not canonical** (steward ruling 2026-08-24) even though it
  is populated on *more* rows than `email` (1,962,081 vs 1,817,870) and fills 173,717 gaps. `email`
  is the field of record; do not substitute.
- **`order_customer` gained two columns, synced 2026-08-13**: `destination_id` (INT64, raw Brink destination id alongside `destination`) and `has_order_items` (BOOL, added 2026-08-04 — FALSE means no qualifying item rows survived the build's item filters, so `item_gross_sales` and friends are NULL on ~2.4% of rows; an audit flag, not a reporting filter). `phone` is now STRING. Both new columns flow through to `claude.order_customer`.
- **`claude.order_customer` excludes stores 1111 AND 999 at the view level** (deployed filter `and oc.store_id not in (1111, 999)` — **corrected 2026-08-17**; the 2026-08-13 entry and the repo script both said `<> 1111`, while the deployed view had always excluded both). Standard users cannot see either unnamed store; `sales_ops` tables still contain them, so the exclusion remains load-bearing there. Writing `store_id not in (1111, 999)` against the `claude` view stays correct — just expect `claude`-vs-`sales_ops` totals to differ by those stores even when neither query filters them.
- **Per-customer questions should use `sales_ops.customer_attribute`, not a hand-rolled `group by mapped_cust_id`** (new 2026-07-29). Lifetime orders, spend, AOV, recency, tenure, store affinity and trailing 30/90/365-day activity are all precomputed there — that's the whole point, so two sessions can't produce two different LTV numbers. It is already person-only (adding `customer_type = 'person'` errors), it has **no partition column**, and you must check `attribute_asof_date = yesterday` before trusting the window columns. See its section above.
- **`order_lines.item_net_sales` is usable, with a named limit** (steward ruling 2026-07-30, superseding the earlier "not computable" wording). The column is live on **both** `sales_ops.order_lines` and `claude.order_lines`, fully populated, **zero nulls**. Report it when asked; do **not** treat it as reconcilable to order-level net. Measured on Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27, non-catering, stores 1111/999 excluded:

  | Sale shape | Units | Gross | Net | Gross→net |
  |---|---|---|---|---|
  | Sold alone | 24,125 | $215,890 | $210,928 | **2.30%** |
  | In combo, paid | 47,461 | $315,280 | $304,716 | **3.35%** |
  | In combo, free slot | 37,623 | $386 | $371 | **3.83%** |

  The spread is **not constant across sale shapes**, so it is not a flat rate and the difference between gross and net cannot be described as "the discount" without evidence. Order-level discounts and promotions are still *not* allocated per item, so **`order_customer.net_sales` remains the only net figure to quote or tie out** — say that whenever you hand over `item_net_sales`. Still open: what the 2.3–3.8% actually represents, and why it is wider on combo components than on standalone lines (Asana: `KB finding: item_net_sales gross-to-net spread varies by sale shape`).
- **Net sales is the `net_sales` column** — read it directly (calculated at build since 2026-07-24; promotions term added 2026-08-21). `brink_net_sales` is the Brink-given value kept as the **steward's own cross-check — not an accuracy reference, not for reporting, and not something to measure `net_sales` against** (ruling 2026-08-21; an earlier version of this bullet quoted a 0.0025% variance against it, which was never a meaningful comparison). There is no per-item or per-modifier net in the mart any more.
- **`is_catering = false` does not exclude catering-only items** (verified 2026-07-28). `Ultimate Grilled Cheese Box` — the catering box SKU — is flagged `is_catering = false` on `order_lines`. The flag describes the *order's* catering destination, not the *item's* nature, so catering-specific SKUs leak into non-catering item mix. Check the resolved item-name list for `Box` / `Tray` / `Party` variants explicitly.
- **🚨 `order_customer` and `order_lines` disagree on catering again, since 2026-08-17.** Finance's
  definition added **store 50 (Middleton Mobile)** to `order_customer.is_catering` and to
  `revenue_category`; `order_lines` still computes its own flag from raw Brink without it. Measured
  2026-08-17 over the trailing 30 closed days: **793 orders disagree, all store 50**, `order_customer`
  true / `order_lines` false. **Catering questions go to `order_customer` until the marts are merged.**
  Any catering item mix, unit count or item-level figure from `order_lines` — including the report
  builder artifact — shows store 50 as zero catering. `order_line_discount_detail` straddles both
  (its `is_catering` comes from `order_lines`, its `revenue_category` from `order_customer`), so a
  store-50 row there can read `revenue_category = 'Catering'` with `is_catering = false`; store 50 has
  no discount lines yet, so it hasn't surfaced.

  **Third instance of one defect class**: 2026-07-24, 2026-07-31, 2026-08-17. Cause is always that
  `is_catering` is derived twice, independently, from raw Brink. The fix in flight is to chain the
  order-mart scripts into one scheduled query and have `order_lines` read header attributes from
  `order_customer` (steward taking it 2026-08-17).
- **~~`is_catering` is a superset of `revenue_category = 'Catering'`~~ — not since 2026-08-17.** The
  base build now stamps `'Catering'` on pulse-flagged and store-50 orders too, so in `sales_ops` the
  two select **identical** sets, as they already did in `claude`. Historic note: before 2026-07-24 the
  flag missed all POS-only catering (641 orders / $70.7K net in June), so pre-rebuild catering numbers
  understate; `order_lines` only caught up 2026-07-31 (+644 June orders / +$71,586 gross). If you're
  comparing against a catering number produced between 07-24 and 07-31, ask which table it came from
  before calling either one wrong.
- **Grain defect (1 order in ~50M):** `brink_order_id` 2279778269187 has two rows in `order_customer` — two pulse orders point at one Brink order, double-counting $263.99 across two customers. Immaterial to totals; use `count(distinct brink_order_id)` if exact uniqueness matters.
- **`order_sequence` history starts 2023-03-06**, not 2018. `customer_order_count = 1` means "first order since March 2023", not first-ever. Say so when presenting first-time-guest numbers.
- **`order_sequence` is a `left join`, never inner** — ~47% of orders have no `mapped_cust_id` and so no row; an inner join silently drops them.
- **`order_sequence` is NOT pre-filtered (changed 2026-07-27).** It holds every order with a `mapped_cust_id`, all customer types, and carries `customer_type` as a column. You must filter `customer_type = 'person'` yourself. Earlier versions were person-only — saved queries written against those are now wrong.
- **Sequence numbers are computed across all of a customer's orders, then you filter.** Filtering `customer_type = 'person'` selects rows but does not renumber them, so a mixed id (30 in June 2026) shows million-scale `customer_order_count` on its person rows — `19192` sits around 2.48M. Treat those as unreliable; recompute the window over person orders if you need true per-person sequencing.
- **`order_sequence.lifetime_customer_order_count` was DROPPED 2026-07-29.** Querying it now errors. Use **`customer_attribute.lifetime_order_count`** instead — but note it is person-only, excludes store 1111, and is as-of *yesterday*, so it won't tie exactly to the old column (they agreed on 99.84% of shared customers). It is the more correct figure; that's why the old one was removed.
- `order_lines.amount` sums to order gross ONLY when filtered to `line_item_type in ('item','fee','surcharge','modifier')` — tip and gift_card lines carry non-sales amounts, discounts/promotions are negative. For item mix, `item_gross_sales` on `line_item_type = 'item'` is still the measure.
- Item counts need `line_item_type = 'item'`, else modifiers ~double the count.
- **`line_item_type = 'item'` does not mean "sold standalone"** (verified 2026-07-28). It includes priced Try 2 Combo component lines, which for Ultimate Grilled Cheese were 66% of all `item` lines. Split on `composite_item_id is null` to isolate true standalone sales. See the combo line taxonomy in Recipes — an answer built on the wrong shape is off by multiples, not percentages.
- **Ask about Try 2 Combo inclusion on every soup / sandwich / salad question** before querying (pre-query protocol item 4). Combos were ~78% of Ultimate Grilled Cheese units.
- **Resolve product names with a `like` discovery query before measuring them** (pre-query protocol item 5). Never hard-code a guessed `item_name`; a near-miss returns a clean wrong number or a silent zero.
- `qty` is derived from price and approximate; fine for mix, not for inventory-grade counts.
- Line-level sums won't exactly reconcile to `order_customer` order-level sales (order-level discounts, rounding). Order-level `net_sales` from `order_customer` is the truth for sales. Quantified 2026-07-23 (post modifier-gross fix): ~1.3% of orders have no `order_lines` rows (all $0-net fully-voided orders — benign); on the rest, line reconstruction matches 99.99% of orders (aggregate within ~$1.5K on $55M/90d). Still: report sales totals from `order_customer`, not `order_lines`.
- `rev_center_name = 'Foutain Beverages'` is misspelled in source — match it as-is.
- **`is_guest_order` no longer means what this file used to say — the fix is DEPLOYED and the old "91% of all-time orders are guest" figure is dead** (re-measured 2026-08-13). That 91% was the pre-fix column, which was just an alias for `pulse_order_id is null` and carried no loyalty information at all. The deployed logic is now an explicit digital allowlist:
  ```sql
  case when ocs.is_loyalty_user = 0   -- raw flag is INT64 0/1 since 2026-09-23 (was `= false`)
        and lower(po.source) in ('mobile_web_source','web_source','ios','android','mobile_source')
       then true else false end as is_guest_order
  ```
  Measured July 2026 (683,228 orders, stores 1111/999 excluded): **19,273 guest orders = 2.8% of all orders**, zero NULLs, and **zero POS orders flagged**.
  > **⚠️ `is_guest_order = false` is NOT "logged-in order" — it is the default value.** The deployed `else false` puts three unlike populations in one bucket: 406,796 in-store POS orders (guest-ness is *undefined* there, not false), 103,337 `Checkmate` aggregator orders, and genuinely-authenticated digital orders. Reading `false` as "identified" overstates that population by roughly 10x. **Pick the denominator explicitly and state it** — July 2026: 2.8% of all orders, **14.7%** of the four digital `order_source` values that can produce a guest (131,060 = Mobile Web + Web + Android + iOS), **39.6%** of web orders (19,272 / 48,725). The last is the one operators usually mean.
  >
  > **The build script and the deployed code disagree, and the data follows the code.** The script's own comment (lines 391-392) and the design in the backlog both say POS should be **NULL** (`case when ocs.order_id is null then null else not ocs.is_loyalty_user end`) because an in-store order has no guest/member distinction to make. The committed expression has no NULL branch. So "zero NULLs" is evidence of an unimplemented spec, not of a clean column — steward decision open (Asana 1217004980903117).
  >
  > Guest checkout is **web-only in practice**: `Mobile Web` 15,804 / 31,827 (49.7%), `Web` 3,468 / 16,898 (20.5%), `Android` **1** of 13,758, `iOS` **0** of 68,577. The apps are in the allowlist but keep users signed in, so they never produce guests. `coalesce(is_guest_order, false)` (seen in analyst SQL 2026-08-13) is now a no-op, but it encodes the same false-means-not-guest assumption — drop it rather than carry it.
  >
  > **⚠️ There IS a pre-launch guest population, and day-sampling will not find it.** ~**314,900** orders are flagged guest before 2026-07-01, essentially all in **Mar–Oct 2023** (peak 2026-08 ⇒ 2023-08 at 78,468; 2023-05 32,007, -06 51,631, -07 63,237, -09 57,951). The column then goes dark from Nov 2023 (23 orders) and stays in single or double digits per month through Jun 2026 (27). So the honest statement is **"no meaningful history between Nov 2023 and Jun 2026,"** not "none before the launch" — and the 2023 population needs an explanation before any pre/post comparison leans on this column. *(Method note: this was first reported as "effectively zero before 2026-07-01" from seven sampled single days, all of which fell in 2024–2026. A monthly `having guest_true > 0` aggregate over full history found the 2023 block immediately. **Sampling days cannot support a claim about a column's whole history** — aggregate the history.)*
- `mapped_cust_id` coverage is ~53% over the last year, and only ~62% of *that* is a real person.
- **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales, order, and item metrics on all tables. No exceptions (steward rule 2026-07-23). Note `order_sequence` sequence numbers are built without that exclusion.
- Store footprint: **91 stores trading** (last 7 days, 2026-09-15) in UT, AZ, MN, NV, WI, ID, IL, OH, TX, out of 101 `store_info` rows and 77 comp. Store attributes come from `sales_ops.store_info`.
- **Trading week is Monday–Saturday; the reporting week is Monday–Sunday, labelled by its Sunday** (steward rule 2026-09-09, replaces the Saturday-label rule of 2026-07-30). All stores are closed Sunday, so "last week" still means the most recent Mon–Sat of trading and weekly *averages per trading day* divide by 6, not 7 — but the bucket and the label are the Mon–Sun week. Bucket with `date_trunc(d, week(monday))`; never a bare Sun-anchored `date_trunc(..., week)`.
- **"Week ending" means the Sunday, and is `last_day(business_date, week(monday))`** (steward rule 2026-09-09). This is identical to `claude.date_dim.week_ending`, so the business week and the fiscal week are now the **same** bucket and there is no longer a week fork. The ~4 stray Sunday lines chain-wide land in the week they belong to (the Mon–Sun that contains them), and every `business_date` in a bucket is on or before its `week_ending`. Retired expression: `date_trunc(business_date, week(sunday)) + 6` (the Saturday label) — if you meet it in older SQL or saved analyses, it bucketed identically for Mon–Sat dates and differed only on Sunday rows; relabel, don't re-derive.
- **Snap the range to whole weeks before reporting weekly** (steward rule 2026-07-30). A range whose ends fall mid-week produces a short first and last bucket that reads as a dip nobody caused — the most screenshot-ready wrong conclusion this mart can produce. Either widen to the enclosing Mon→Sun boundaries and state the dates actually used, or label the partial buckets with their day count. Never ship an unflagged part-week next to full weeks. Verified: 2026-05-04 → 2026-06-28 is exactly 8 whole weeks, 6 trading days each.
- **Year-over-year offset is 364 days, not 1 year** — `date_sub(d, interval 364 day)` (52 × 7) keeps the day-of-week aligned, which matters because trading is Mon–Sat and Sundays are zero. `date_sub(d, interval 1 year)` shifts the weekday and drags a Sunday into the comparison window. Convention observed in analyst SQL 2026-07-24.
  - **364 days preserves the weekday but NOT floating holidays** (observed 2026-09-01). The daily flash for Monday **2026-08-31** (an ordinary Monday — Labor Day 2026 is 09-07) compared against `- 364 day` = **2025-09-01, which WAS Labor Day**, so the "LY" column carried a holiday trading pattern and the YoY read as a swing nobody caused. The reverse hits a week later: Labor Day 2026 (09-07) lands on ordinary Monday 2025-09-08. Same for Memorial Day, MLK, Presidents Day, Thanksgiving/C5 and Easter-adjacent days. Before quoting a day-level or week-level YoY, join both sides to `claude.date_dim` and check `holiday` — if either side carries a label, say so in the answer and offer the holiday-to-holiday comparison as the second number. The `date-dimensions` skill's `week_beginning_ly` / `week_ending_ly` columns have the same property: they are the 364-day offset, not a holiday-aligned one. **Third option for span comparisons (seen done correctly by hand 2026-09-18): drop the union of holiday dates from BOTH years in aligned-date space** - for a TY span at `- 364 day`, exclude every aligned date where either `dd_ty.holiday` or `dd_ly.holiday` is set (2026-09-07 Labor Day *and* 2026-08-31, which is 2025-09-01 Labor Day shifted), plus the closed Jul 3-5 block, and say how many trading days remain. Use `claude.date_dim` for the list, not a hand-typed `not in (...)` - the analyst's literal list was right this time and will be wrong the first year Thanksgiving moves.
- Timezone: business runs on `America/Denver` for schedule logic; each store's local time is in `order_datetime_local` (DATETIME — **renamed from `order_datetime` base-table-wide 2026-08-20/21**, the old name no longer exists on `sales_ops.order_customer`, `sales_ops.order_lines`, or either `claude` view), UTC in `order_customer.order_timestamp_utc`.
- There is **no `order_id` column** on any of these tables — the order key is `brink_order_id` (multiple users have hit this error).
- ### ⚰️ `sales_ops.OrderCustomer` was DROPPED 2026-08-21 09:52 MT. If a query names it, the answer is the migration table below — not a workaround.

  The legacy table (schema: `netsales`, `iscatering`, `storeid`, `lifetime_order_cnt`, `first_order_datetime`, `order_count`, `mapped_domain`, `order_trans_or_cust_id`, `state`, `source`, …) is gone. `sales_ops.order_customer` (lowercase) is the only order table. Any query against the old name now fails with `Not found: Table ... OrderCustomer` — which is the point: five documented days of "do not use it" changed nothing, and the drop retired it in one.

  **Translate, don't re-point-and-hope.** Verified against deployed `INFORMATION_SCHEMA.COLUMNS` 2026-08-21:

  | Legacy column | Canonical replacement |
  |---|---|
  | `businessdate` / `BusinessDate` | `business_date` |
  | `storeid` | `store_id` |
  | `state` | `store_state` |
  | `iscatering = 0` | `is_catering = false` (INT64 → BOOL) |
  | `order_datetime` | `order_datetime_local` |
  | `mapped_domain` | `mapped_email_domain` |
  | `order_count` | `customer_order_count` (`claude.order_customer` or `order_sequence`) |
  | `lifetime_order_cnt` | `lifetime_order_count` (`claude.order_customer` or `customer_attribute`) |
  | `first_order_datetime` / `last_order_datetime` | `customer_attribute.first_order_datetime` / `.last_order_datetime` |
  | `order_trans_or_cust_id` | **No equivalent — it exists nowhere on the canonical marts.** Use the `in_store_scan` column, which is the same idea the legacy builds computed inline as `case when pulse_order_id is null and mapped_cust_id is not null then 1 else 0 end` |
  | `netsales` | **A decision, not a rename** — see below |
  | `storeid <> 1111` | `store_id not in (1111, 999)` (999 was excluded nowhere in the legacy queries) |

  ⚠️ **`netsales` is the one non-mechanical mapping.** It is the Brink-**given** net sales, whose counterpart is `brink_net_sales` — a validation field the steward rule keeps out of published output. The canonical quotable net is the calculated `net_sales`. The two differ, so mapping `netsales → net_sales` **moves every historical number** on any report that used to read the legacy column (the YoY sales dashboard among them). State which one you used.

  💡 **What the drop cost, and the process lesson.** Zero views depended on it (checked `view_definition` across all 14 datasets that have views) — the 2026-07-30 "renaming a base table drops its view" failure did not repeat. But **15 daily scheduled builds read it in live SQL** and were found only after the drop: 8 `shared_datasets` QuickSight sources including `google_offline_conversions` (which uploads to Google Ads), `sales_ops.cs_comp_points` / `cust_info` / `rfm` / `store_info`, and three `braze.*` customer-attribute builds. The dependency sweep is cheap — one `regexp_contains` over `JOBS_BY_PROJECT` for non-`SELECT` statement types, plus `view_definition` per dataset — so **run it before the drop, not after** (Asana 1217722726180551).
  - **It is now also going stale**: on 2026-07-27 its `max(business_date)` was **2026-07-25** while `order_customer` had loaded through 2026-07-27. Answers from it are silently 1–2 days short of current. Three separate users queried it during 2026-07-24 → 2026-07-26.
  - **🛑 If you are working from a saved query or a shared template, assume it targets this legacy table and rewrite it before running.** Query-log review counted **188 non-steward runs against `OrderCustomer` in the five business days 2026-07-24 → 2026-07-29**, and every one of the 115 raw-`pulse.*` wall breaches in that window came through it. The pattern is a *shared workbook* — byte-identical query text ran under two different users' accounts hours apart on 2026-07-28, eight of them inside a single minute (batch execution). Legacy schema is the tell: `businessdate`, `storeid`, `iscatering = 0`, `source`, `lifetime_order_cnt`, `first_order_datetime`. Translate to `business_date`, `store_id`, `is_catering = false`, `order_source`, and `order_sequence.lifetime_customer_order_count` — and if the template reached into `pulse.*` for identity, stop and say the mart can't answer it (Asana 1216992461499656).
  - `iscatering` on the legacy table is **INT64** (`iscatering = 0`); `is_catering` on the canonical mart is **BOOL** (`is_catering = false`). Writing `is_catering = 0` fails with `No matching signature for operator = for argument types: BOOL, INT64` (observed 2026-07-24) — a reliable sign a query was written against the legacy schema.
  - **The disagreement is now measured, not asserted** (2026-08-17 review, business date 2026-08-07, stores 1111/999 excluded, one full day): the two tables agree on 29,513 orders, but the legacy table holds **12 orders the canonical mart does not**, and **2 orders are flagged catering on one side and not the other**. Across 2026-08-04 → 2026-08-10 the legacy table runs **1–10 orders/day higher** and its `netsales` sits **$0.50–$22.00/day above** the canonical calculated `net_sales`. The gap is small enough that nobody notices and large enough that two people answering "how many orders yesterday" from the two tables get different numbers — which is exactly the failure this project exists to prevent. Do not report the difference as a rounding artifact; report the canonical mart's number.
  - **`netsales` on the legacy table is the Brink-given net sales**, the column the steward rule keeps out of the `claude` layer entirely (it is retained on `sales_ops.order_customer` as `brink_net_sales`, a validation field only). Quotable net is `order_customer.net_sales` = `gross_sales − total_discount_amount − total_promotions_amount`. A legacy query returning "net sales" is answering a different question than the marts do, on top of querying a different row set.
  - **🧊 IT STOPPED LOADING — and nothing announced it (measured 2026-08-21).** The scheduled build (`SCRIPT` → `DELETE` → `INSERT` → `UPDATE` under `bigquery-loader-sa`) ran daily at ~08:50 MT on 2026-08-16/17/18/19 and then **never fired again** — no error row, no failed job, it simply stopped. `max(BusinessDate)` is **2026-08-18**; `last_modified` is **2026-08-19 08:50 MT**. Meanwhile `sales_ops.order_customer` is current to today. **104 non-steward queries ran against the frozen table after the last load** (2026-08-19: 39 by jelgie@; 2026-08-20: 39 by dgetz@ + 26 by jelgie@), every one of them with a window whose end date was inside the missing days. This is the worst possible failure mode and the reason the retirement can't wait: while it was loading it gave *slightly different* answers, which someone might catch; now it gives *confidently incomplete* ones, and the shortfall grows one day per day. **The schedule is already off, so renaming it costs nothing** — rename to `zz_retired_OrderCustomer_20260819` so the shared workbook errors instead of answering (Asana 1217553975515537; standing lesson: guidance never retires a deprecated table that still returns plausible numbers — a rename does).
  - **⚠️ Its `order_datetime` is a TIMESTAMP holding store-local wall-clock time, so a Braze comparison type-checks with no cast at all.** Measured on BusinessDate 2026-08-15, 26,412 orders, store 1111 excluded: `order_datetime = order_timestamp_utc` on **0** of them, `timestamp_diff(order_timestamp_utc, order_datetime, hour)` spans **4 to 7 hours** — the same four live UTC offsets as the canonical mart. This makes the legacy table the **only** place the timezone error is completely silent. The `braze-campaigns` rule ("never wrap `order_datetime` in `timestamp()`") is a *cast* rule, and on this table there is nothing to wrap: `braze_ts >= oc.order_datetime` compiles clean, TIMESTAMP against TIMESTAMP, and is wrong by 4–7 hours. The legacy table carries a correct `order_timestamp_utc` alongside it, unused in every query observed. **The tell has to be the table name, not the cast.** As of the 2026-08-20/21 rename the bare cast now *errors* on all four canonical objects — which leaves `OrderCustomer` as the last surviving host for the bug.
  - **Still live, still in use — 2026-08-14** (fifth business day of recurrence in this log): two analysts hit it the same morning. One ran a 90-day cohort CTE off `OrderCustomer` and joined it to `sales_ops.order_lines` **with no partition filter on `order_lines` at all** (12.76 GiB billed for a top-15 sandwich list); the other used it for a mart-freshness check and a store-opening loyalty benchmark. The freshness check is the tell that people believe it is the live table. It is live — that is the problem, not the excuse.
- **Cohort columns live on the `claude` view, not on the `sales_ops` base table.** `customer_order_count` and `days_since_prev_order` exist on **`claude.order_customer` only**; selecting either from `sales_ops.order_customer` fails with `Name customer_order_count not found inside oc` (hit by the steward's own session 2026-08-14, verified against `INFORMATION_SCHEMA.COLUMNS` 2026-08-17). `customer_type`, `is_guest_order` and `store_state` are on both. Standard users should be on `claude.*` anyway; the trap is for anyone translating a `sales_ops`-flavoured query and assuming the base table is a superset of the view. It is not — the view adds the folded order-sequence columns.
- **`sales_ops.store_info` column names are not the obvious ones** — it's `store_state`, not `state`; `store_city`, `store_zip`, `store_address`, `store_short_name`. Full column list (16, verified 2026-09-15): `store_id`, `store_name`, `store_address`, `store_city`, `store_state`, `store_zip`, `store_phone`, `store_short_name`, `store_tz`, `store_open_date`, `is_comp_store`, `store_comp_date`, `latitude`, `longitude`, `weather_cluster_id`, `timezone_name`. **`store_comp_date` is the point-in-time comp base** and is NOT on `claude.store_info`. Join `store_info.store_id = order_customer.store_id`. Full dictionary: [`data_dictionaries/sales_ops.store_info.md`](../../../data_dictionaries/sales_ops.store_info.md). (Guessing `state` failed an analyst session 2026-07-24.)
- **"Market" means `store_state`** (steward decision 2026-07-30). There is **no** `market` / `region` / `dma` / `metro` column anywhere in `sales_ops` — verified against `INFORMATION_SCHEMA.COLUMNS`. When a user asks for anything "by market," join `store_info` and group by `si.store_state`, and **say in the answer that market = state**. Ten values, one of which is **blank** (one store has no `store_state`) — it becomes a nameless row in any breakdown, so exclude or label it. Caveat worth stating: Utah is 36 of 101 rows across 29 cities, so one "Utah" row hides most of the geographic spread. `store_city` is finer but `West Valley` and `West Valley City` are separate values for the same metro. A real metro/DMA rollup is an open KB gap — don't invent one per-session.
- **`sales_ops.order_discount` no longer exists** — verified absent from `INFORMATION_SCHEMA` on 2026-08-15; it was a BASE TABLE on 2026-08-06. It was an undocumented raw Brink passthrough (`order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, `approver_employee_id`, `source`, partitioned on the legacy `businessdate` spelling), and **`sales_ops.order_line_discount_detail` supersedes it**. A saved query against it now fails loudly with a not-found error — the good failure mode. **Don't confuse the names**: the discount mart is `order_line_discount_detail`, and users query `claude.order_line_discount_detail`. One thing the old table carried that the mart does **not** is `approver_employee_id`, the manager-discount audit trail — an open enrichment idea, not a gap anyone has asked for.
- **Employee/test exclusion:** internal accounts are identifiable via `customer_type = 'internal'` (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`) — 119 ids / 736 orders in June 2026. The new `mapped_email_domain` column closes the old `mapped_domain` mart gap on this table. Unidentified internal orders still can't be flagged.
- The old `cowork_interim` and `nces_staging` scratch datasets were dropped 2026-07-22. Any saved query referencing them must be rebuilt against the marts (materialize intermediates in `scratch` if needed).

- **Payment method / tender questions run on `claude.order_payment_tender`** (view, new
  2026-08-05) — one row per order, join on `brink_order_id`, answer column
  `payment_tender`. Never reach into `pulse.order_payments` / `brink.brinkOrderPayment`
  directly (they hold cancelled/failed/refunded/deleted rows the view filters). Freshest
  loaded day shows `'stripe'` placeholders; amounts are gross tendered, not sales; split
  tenders are comma-joined. Full gotchas: `data_dictionaries/claude.order_payment_tender.md`.

- **Discount / loyalty-giveaway questions run on `claude.order_line_discount_detail`** (new 2026-08-15).
  **One row per discount COMPONENT, not per line and not per order** — a single Brink line can
  split into several rows. `discount_amount` is the **only** summable money column (it
  reconciles to `order_lines` exactly); `count(*)` counts components; joining to
  `order_customer` requires aggregating this table to order grain first or the split
  multiplies the sales side. `discount_origin` is **not** a channel — `revenue_category` is.
  `discount_type` is an open domain with no `'Other'` bucket. **Employee / team-member meal
  questions use `is_employee_meal_discount` (new 2026-08-17), never a `discount_type` filter or
  a name pattern** — the benefit has run under four Brink programs since 2018; it replaces
  `order_customer.is_employee_discount`, **dropped from that table 2026-08-17**. **`Error` is a health signal:
  0–1 lines on a closed day, but ~76% of *today's* integrated lines until the 4am pass — never
  report today's discount mix intraday.** Full gotchas:
  `data_dictionaries/claude.order_line_discount_detail.md`.

- **In an incremental build, never window a dimension by the fact window** (rule 2026-08-15).
  `user_offers.create_date` is *issuance*, `pulse.order_discounts.created_at` is order
  *placement*, `business_date` is *fulfillment* — different clocks. Reusing `start_date` on a
  lookup CTE made `offer_name` non-deterministic by day of week (275 rows over 8 days) and
  silently dropped catering booked further out than the window. Filter lookups by the order
  keys in the window, or widen the reload and add an alarm. Wrap `delete`+`insert` in an
  explicit transaction; BigQuery scripts are not atomic. Pin `current_date('America/Denver')`
  — bare `current_date` is UTC and evening intraday runs land on the next UTC day. Full
  writeup in the section above.

- **Weather questions: the source is `marketing_ops.weather_triggers`. The four `brink.*`
  weather tables are dead or stale, and one of them is silently EMPTY** (measured 2026-08-27
  after an analyst hit them on 08-26).

  | Table | Rows | Coverage | Verdict |
  |---|---|---|---|
  | `brink.weather_data` | **0** | — | **Empty. Returns no rows, never an error.** |
  | `brink.WeatherData` | 4,201,493 | 2014-12-08 → **2026-04-25** | 4 months stale |
  | `brink.WeatherData_Staging`, `brink.WeatherDataForSchedulerProjectionsWrtMonday` | — | — | Scheduler internals, not analysis tables |
  | `marketing_ops.weather_triggers` | 45,408 | actuals 2025-05-29 → yesterday; forecasts to tomorrow, 90 store zips | **Use this** |

  Three traps, all fired in one session:

  1. **`brink.weather_data` is empty, so a weather-vs-sales query against it returns a clean,
     plausible, entirely empty result** — the same silent-zero class as
     [a stalled partition satisfying `BETWEEN`](#). The analyst read the blank output as
     "no weather effect," not "no table."
  2. **The two brink tables differ only by letter case in the table name AND in every column
     name** — `weather_data`(`business_date`, `store_id`, `temperature`, `precipmm`, `hour`)
     vs `WeatherData`(`BusinessDate`, `StoreId`, `Temperature`, `PrecipMM`, `Hour`). BigQuery
     table names are case-sensitive, so both resolve. A `union all` across them fails with
     `Unrecognized name: business_date; Did you mean BusinessDate?`, which reads like a typo
     rather than like two different tables.
  3. **Falling back from the empty table to the stale one is worse than either**, because
     `WeatherData` stops at 2026-04-25: a yesterday-vs-last-year comparison returns a
     **populated LY side and an empty CY side**, which presents as a dramatic weather change.

  `marketing_ops.weather_triggers` is keyed on **`store_zip`, not `store_id`** — join via
  `claude.store_info.store_zip`. It also carries a `record_type` of `'actual'` or
  `'forecast'`; filter it, or a "yesterday" query can pick up a forecast row.
  `sales_ops.store_info.weather_cluster` and `marketing_ops.zip_weather_cluster` group zips
  into weather regions. There is **no `claude` weather view yet** — flag it as a mart gap
  rather than routing a user to `marketing_ops` or `brink` (Asana 1217062464974534).

- **The `claude` views floor at 2023-01-01, so pre-2023 questions have no standard-user
  answer** (observed 2026-08-26: an analyst ran a 2019-01-07 → 2023-06-25 weekly net-sales
  series against `sales_ops.order_customer` directly, because that is the only place it
  exists). The floor is a rolling 3 years, so it moves every January. Multi-year trend,
  COVID-baseline and pre-opening questions all cross it. **The correct response is to say the
  range is outside the curated window and log it as a mart gap — not to fall through to
  `sales_ops`.** See Asana 1217932458641436.


## Appendix — observed but not yet canonical

### 🟡 Observed but NOT yet canonical: the internal-traffic exclusion (logged 2026-07-31)

The steward's own manual customer-behaviour SQL consistently strips three populations that this
skill's documented default **keeps**:

```sql
and coalesce(oc.source, '') <> 'Outdoor Kiosk'
and coalesce(oc.mapped_email_domain, 'b') not in ('cafezupas.com', 'tkxel.com')
```

i.e. shared kiosk terminals, employees (`cafezupas.com`) and the outsourced dev team
(`tkxel.com`). Note the null-safe `coalesce` on both — the bare `<>` / `not in` forms would drop
every NULL-domain row, which is most in-store orders.

**Do not apply this silently.** It is recorded here because it was observed repeatedly in steward
work, not because it has been ratified, and it materially changes customer counts and frequency.
Two conventions genuinely conflict: the kiosk exclusion overlaps `customer_type = 'kiosk'` (already
the canonical control), and the domain exclusion contradicts "include employee-discount orders."
If a question is about *customer behaviour* rather than *sales*, raise it as a scope choice with
the user and say which you used. Steward decision pending — Asana 1217062310224330.

**New evidence 2026-08-04 — the default drive-thru account** (observed in steward CLV-model SQL):
a third population joins the candidate exclusion set. Stores ring drive-thru orders on a shared
account with a `cafezupas.com` email, so the steward's model **nulls the identity** rather than
dropping the order:

```sql
case
  when (lower(oc.email) like '%@cafezupas.com'
        or lower(oc.mapped_email) like '%@cafezupas.com'
        or lower(oc.mapped_email_domain) = 'cafezupas.com')
   and oc.destination in ('Drive Thru', 'DT Order')
  then null else oc.mapped_cust_id
end as mapped_cust_id   -- drop the default drive-thru id, keep the order
```

Note the shape: it's an **identity fix, not an order exclusion** — sales totals keep the order;
customer counts and frequency stop attributing hundreds of orders to one phantom "customer."
Same pending decision, same Asana task.

> The legacy column name is `mapped_domain` on `sales_ops.OrderCustomer`; on the current
> `order_customer` / `claude.order_customer` it is **`mapped_email_domain`**.
