# `sales_ops.order_customer` — history (companion)

> **Read this when** you need the dated change log behind a column (what changed when, and why a saved query broke), or the full story of a gotcha that is now resolved or retracted. For the columns and the live gotchas, read [`sales_ops.order_customer.md`](sales_ops.order_customer.md) first. Moved verbatim from that file on 2026-10-14.

## Change-log banners (were at the top of the dictionary)

> # ⚠️ 2026-09-23 — the `pulse` dataset changed column TYPES; the build broke 08:02–12:02 MT and is fixed
>
> The Pulse feed was reloaded on 2026-09-23 and several raw columns arrived with new BigQuery types (the change landed between the 07:02 and 08:02 MT runs). Nothing in this table's schema changed, but the build script had to cast:
>
> | raw column | was | now | build change (`sql/sales_ops.order_marts.sql`) |
> |---|---|---|---|
> | `pulse.orders.id` | INT64 | **NUMERIC** | `cast(po.id as int64)` in `pulse_orders` and in `order_lines_detail` — `pulse_order_id` stays INT64 |
> | `pulse.orders.brink_order_id` | INT64 | **NUMERIC** | none needed (INT64 = NUMERIC comparison coerces) |
> | `pulse.orders.is_catering` | BOOL | **INT64** (0/1) | `case when po.is_catering = 1 then true else false end` — `is_catering` stays BOOLEAN |
> | `pulse.order_customers.is_loyalty_user` | BOOL | **INT64** (0/1) | `ocs.is_loyalty_user = 0` in the `is_guest_order` predicate (was `= false`) |
> | `pulse.order_customers.phone` | STRING | **INT64** | already `cast(ocs.phone as string)` — `phone` stays STRING |
> | `pulse.customers.id` | INT64 | **NUMERIC** | none needed (joins coerce); `pulse_customer_id` is still `pulse.orders.customer_id` (INT64) |
> | `pulse.customers.is_catering` | BOOL | **INT64** | not read by this build; **does break `sales_ops.cust_map`** — see that dictionary |
> | `pulse.customers.phone` | INT64 | **STRING** | `cast(c.phone as string)` is now a no-op — `acct_phone` stays STRING |
> | `pulse.order_payments.is_processed` etc. | BOOL | **INT64** | not read here; broke `claude.order_payment_tender` — redeployed 2026-09-23 |
>
> Run history (from `INFORMATION_SCHEMA.JOBS_BY_PROJECT`): 05:02 full-history and 07:02 succeeded on the old types; 08:02, 09:02, 10:02, 11:02 failed on `COALESCE(INT64, BOOL)` (the `is_catering` coalesce); the 11:50 / 11:58 / 12:02 attempts failed on `NUMERIC cannot be inserted into pulse_order_id`; a manual run at **12:17** and the scheduled 13:02 succeeded with the full fix. Because the intraday path reloads **today only**, the 12:17 run recovered every hour that had failed — **no business date was lost**. The `delete` at the top of each failed transaction was rolled back, so the table was never left empty for the day. **All three marts share one transaction chain, so `order_lines` and `order_line_discount_detail` were stale for the same four hours.**
>
> Lesson for the steward: the raw `pulse.*` types are not stable across feed reloads. Any build that compares a raw Pulse flag to `true`/`false`, or inserts a raw Pulse id into an INT64 column, will fail the next time the feed changes shape. Prefer `= 1` / `cast(... as int64)` at the point of ingestion.

> **Rebuilt 2026-07-24** (full history). Breaking changes — update any saved query:
> - `businessdate` → **`business_date`** (partition column)
> - `net_sales` is now the **calculated** net; the Brink-given value moved to **`brink_net_sales`** (steward's cross-check, not an accuracy reference). As built 2026-08-21 the expression is `gross_sales + discount_amount + promotions_amount` — **plus**, because both discount columns are stored negative. There is no `total_promotions_amount` column; an earlier revision of this line named one.
> - **dropped**: `item_net_sales`, `item_netsales_with_mods`, `mods_net_sales`
> - **`is_catering` redefined** — destination-based catering is now flagged (was silently false)
> - **new `customer_type`** — required filter for customer metrics
> - `order_count` / `days_since_prev_order` **moved out** to `sales_ops.order_sequence` (and `order_count` renamed `customer_order_count`)
>
> **Further changes 2026-07-27:**
> - `is_guest_order` is now **BOOLEAN**, not INTEGER — `is_guest_order = 1` fails, use `= true`
> - **new `mapped_email_domain`**; `mapped_email` gained a SessionM loyalty-email fallback
> - `customer_type` aggregator matching widened to ezcater / doordash / itsacheckmate, and is explicitly **order-level** — see the note below the values table
>
> **Further changes synced 2026-08-13** (found deployed in the console script; full history rebuilt — `has_order_items` is populated back to 2018):
> - **new `destination_id`** (INT64) — raw Brink destination id, alongside `destination`
> - **new `has_order_items`** (BOOL, added 2026-08-04) — audit flag; FALSE = order kept by the build but carrying no qualifying item rows (~2.4% of recent rows)
> - `phone` is now **STRING** (cast at build)
> - `email` and `mapped_email` are **lowercased at build**, and the SessionM fallback email is trimmed and stripped of its leading `cater_` prefix — the email-casing gotchas below are ✅ resolved
>
> **Further changes 2026-08-17** (deployed + full history rebuilt; verified by steward query the same day):
> - **`is_employee_discount` DROPPED** — the column no longer exists on the table. Its replacement is `order_line_discount_detail.is_employee_meal_discount`, which is line-level, never NULL, and covers all four eras of the benefit. Any query naming `oc.is_employee_discount` now errors
> - **`is_catering` widened**: store 50 (Middleton Mobile) is now unconditionally catering, per finance's definition
> - **`revenue_category` aligned to `is_catering`**: pulse-flagged catering and store 50 both resolve to `'Catering'` in the base table. The two are now **equivalent sets** in `sales_ops` — they were not before
> - **`destination` / `destination_id` overridden for store 50 only**: `'Middleton Mobile Catering'` / `999999999`. Every other store keeps its raw Brink id and name
>
> **Steward clarification 2026-08-24 — `email` is the ORDER email, not the customer's email.**
> A guest may give us any address at checkout so we can send updates about *that order*, so
> `email` is a per-order contact field and is **never** an identity key. The canonical customer
> email is **`pulse.customers.email`**, which reaches this mart only as the *first* fallback of
> `mapped_email`. Measurements and consequences: "Order email vs canonical email" under Gotchas.

> **⚠️ PENDING change 2026-08-26 — the 4am reload becomes a FULL-HISTORY refresh.** Steward change, prompted by learning that Pulse rewrites `pulse.order_customers` history when accounts are merged. The three windowed 4am branches (8 day / 5 week / ~13 month) are commented out and replaced by a single `when run_hour = 4 then '2018-08-07'`. Intraday (8am-11pm, today only) and the 0-3 / 5-7 skip are unchanged.
>
> **It was NOT live as of 2026-08-26 13:49 MT.** Every scheduled run through 13:02 that day carried the 8-day text (18,479 chars; the `'2018-08-07' --` marker absent), verified against `JOBS_BY_PROJECT` query text rather than the console. A DTS save does not appear in job history until the next fire — **read the job text before asserting what the build does.**
>
> **Cost is a non-issue: +7 GiB on one run per day.** Measured 2026-08-26 — the full-history select dry-runs at **22.18 GiB** against **14.92 GiB actually billed** by that morning's real 8-day 4am run (36 s wall, 3,133 slot-seconds). ~+49%, ~$0.05/day on demand. The reason it is so cheap is worth knowing: **the build was never mostly window-bounded.** `brinkOrderItem`, `brinkOrderItemModifier`, `brinkOrderDiscount`, `brinkOrderPromotion`, `brinkOrderGiftCard`, `brinkItems`, `brinkDestinations`, `pulse.customers` and `pulse.order_customers` carry **no date predicate at all** — they are filtered only by join to `brink_order`, so they are scanned in full every hour already. Only `brinkOrder`, `brinkOrderPayment`, `pulse.orders` and the four `sessionM.*` tables widen with `start_date`. Same fact explains why an 8-day run (14.92 GiB) and a today-only run (14.73 GiB) bill almost identically.
>
> **⚠️ But the drift it is meant to repair measures ~17 orders in 51M.** The mart's old partitions were last fully rebuilt 2026-08-20/21, so this is ~6 days of accumulation. Compared against `pulse.orders` / `pulse.order_customers` as they stood 2026-08-26, across all **50,985,194** mart rows: `pulse_customer_id` disagrees on **6**, `mapped_cust_id` **6**, `mapped_email` **16**, `email` **2**, `phone` **2**; **0** vanished pulse rows, **0** changed dedupe winners, **1** late-appearing pulse row. Retroactive rewriting of the per-order pulse tables is not happening at material scale. Rate implies ~3 orders/day, ~1,000/year.
>
> **🚨 And the merge case the change was made for is NOT fixed by widening the window, because the build never reads the merge signal.** `pulse.orders`, `pulse.order_customers` and `pulse.customers` all carry a `deleted_at` column (`pulse.orders` also has `modified_time` and `delete_queue`), and the build filters **none of them**. Measured 2026-08-26: **6,061 mart orders / 1,884 distinct customers / $163,845.84 net sales**, `business_date` 2023-03-22 -> 2026-08-25, are attributed to `pulse.customers` rows with `deleted_at` set — and on **all 6,061** the `mapped_email` was taken from that deleted row. Re-running the identical SELECT over eight years re-reads the same deleted rows and writes the same values. A full refresh converges the mart on *whatever pulse says today*; it cannot repoint a merged customer, because nothing in the build knows who the survivor is. **Widening a window only repairs drift in the columns the build actually reads.**
>
> Only **57 of those 1,884** deleted customers have a live `pulse.customers` row sharing their email, so the population is mostly **plain deletions, not merges** (`deleted_at` first seen 2023-06-26, most recent 2026-08-25). That makes the filter a steward call rather than a bug fix: `deleted_at is null` would NULL out identity on 6,061 historical orders instead of moving them to a survivor. Separately worth deciding whether retaining those 1,884 addresses back to 2023 is intended.
>
> **Targeted restatement is the cheap equivalent of the full refresh.** `pulse.orders` and `pulse.order_customers` both carry `updated_at`. Measured over the 7 days to 2026-08-26, **outside** the current 8-day window: **1,179** `pulse.orders` rows and **11** `pulse.order_customers` rows were updated, spanning **50 distinct `business_date` partitions**. Restating those 50 partitions captures everything a full refresh would, at roughly 1/1,000th of the rewrite — and leaves the mart as the durable copy of history (see consequence 1).
>
> **Three consequences of the wider window, in priority order.**
>
> 1. **The mart stops being the durable copy of history.** Under an 8-day window `sales_ops.order_customer` retained eight years even if raw Brink lost or regressed an old partition. Under a daily full refresh, all 50,985,194 rows are deleted and rebuilt from raw at 04:02 every morning, so the mart is only as complete as `brink.brinkOrder` is at that moment, and the recovery path for a bad morning shrinks to BigQuery's 7-day time travel. Verified 2026-08-26 that Brink is currently complete and duplicate-free (234,314 rows from 2018-08-07; 4.5M-8.3M/yr; `count(distinct id)` = `count(*)` in every year), so this is a **dependency change, not a present defect** — but it makes an `assert` on post-insert row count / `max(business_date)` before `commit` load-bearing rather than tidy (Asana 1216955196273978 escalates accordingly).
> 2. **Reload widths across the four order marts are no longer symmetric.** Measured live 2026-08-26: `order_customer` all history, `order_line_discount_detail` 120 days at 4am, `order_lines` **8 days**. Previously all of them moved on the same window shape, so a restatement propagated. Now any change `order_customer` makes to a partition older than 8 days is invisible to `order_lines` until its monthly 380-day branch, and invisible to pre-2025 history permanently. Same class as catering disagreement #3, and it turns the chaining item (Asana 1217564375242412) from an improvement into the fix.
> 3. **The `:02 / :07 / :12` stagger was sized for a 36-second build.** If order_customer is still inside its transaction at :07, `order_lines` reads the pre-commit snapshot — consistent (thanks to the transaction) but built from the *pre-refresh* order_customer, which silently defeats that morning's restatement. Watch wall time against the 5-minute gap.

> **✅ Correction 2026-08-26 — the untransacted `delete`+`insert` is ALREADY FIXED in production, and this repo did not know.** Commit e94ada5 (2026-08-25 12:24 MT) documented `order_customer`'s rebuild as untransacted and named it the root cause of the `order_lines` deletions. The deployed script gained `begin transaction` / `commit transaction` **38 minutes later**: first scheduled run carrying it is **2026-08-25 13:02 MT** (text 18,428 -> 18,479 chars), and `order_lines` gained its own at **2026-08-25 13:07** (13,263 -> 13,302 chars). `order_line_discount_detail` already had one. Verified across 25 / 25 / 48 consecutive runs through 2026-08-26 13:02. `sql/sales_ops.order_customer.sql` in this repo still has **no transaction** and still shows the three windowed 4am branches — it is two changes behind deployed. *(Resolved 2026-09-08: the repo now carries the deployed chained script as `sql/sales_ops.order_marts.sql`; the standalone file is a retired pointer.)*

## Resolved and retracted gotchas (were under ## Gotchas)

- **✅ RESOLVED 2026-08-20 — `order_timestamp_utc` was NULL for stores missing a `timezone_name`**
  (Asana 1217684772713570). Built as `timestamp(order_datetime, s.timezone_name)`; BigQuery's
  `timestamp()` returns NULL on a NULL timezone instead of erroring, so newly-opened stores
  dropped silently out of every UTC-based analysis. The dimension is fixed and guarded, and the
  **10,771 already-materialized orders ($211,336.89) were repaired in place** with
  `set order_timestamp_utc = timestamp(order_datetime, timezone_name)` — the build formula
  verbatim — rather than by a 17-day mart reload, which would have exposed this table's
  untransacted delete+insert to concurrent readers and dragged
  `order_line_discount_detail` along with it.
  **Lesson: fixing the dimension did not fix this column.** It is materialized, and the daily
  reload restates only 8 days. Any fact column derived from a dimension attribute needs its own
  backfill decision.
- **🔻 RETRACTED same day — the "permanent NULL floor" on unclosed orders is gone, and it was
  never permanent.** Earlier on 2026-08-20 this entry said `order_timestamp_utc` and
  `order_datetime` are NULL together whenever `ClosedTime` is NULL (1,374 such orders over
  2026-08-01 → 08-20) and called that an irreducible floor. It wasn't a floor, it was a missing
  `coalesce`. The same-day rebuild changed the expression to
  `coalesce(bo.ClosedTime, bo.OpenedTime)` with a final `datetime(bo.businessdate)` fallback, and
  the full refresh brought both columns to **0 NULLs across 439,473 orders** (2026-08-01 → 08-19,
  stores 1111/999 excluded). **So `countif(order_timestamp_utc is null) = 0` IS now a valid health
  check** — no carve-out needed.
  Lesson worth keeping: I described a defect as a property of the data one hour and it was fixed
  the next. Date every measured claim, and prefer "as of <timestamp>, N rows" to "this can never
  be zero."
- **✅ RESOLVED — `mapped_email` and `email` are now lowercased at build** (fix deployed
  2026-07-29 with the full-history rebuild; verified 2026-08-13: **0 non-lowercase values in
  365 days** on both columns). `lower(mapped_email)` in queries is now a harmless no-op — fine
  to keep writing defensively, no longer load-bearing.

  <details><summary>What it looked like before the fix (audited 2026-07-29)</summary>

  | Column (365d) | Non-null | NOT lowercase | Distinct raw | Distinct lowered | Casing dupes |
  |---|---|---|---|---|---|
  | `mapped_email` | 4,462,505 | 180,079 (4.04%) | 1,047,296 | 1,029,353 | **17,943** |
  | `email` | 3,392,624 | 183,466 (5.41%) | 884,293 | 883,175 | 1,118 |
  | `mapped_email_domain` | 4,462,505 | **0** | 22,342 | 22,342 | 0 ✅ |

  `count(distinct mapped_email)` overstated by ~17,900; 5,604 emails had one person split
  across multiple `mapped_cust_id`s by letter case alone. Root cause was Pulse (8.7%
  non-lowercase) — Braze and SessionM emails were already 100% clean. See
  `design/crm_identity_hygiene_plan.md` §3.

  </details>

  Related normalization: the SessionM fallback email also strips the leading **`cater_`**
  prefix (and trims), so catering logins resolve to the individual account's address in
  `mapped_email`. Compare against `claude.loyalty_user.email`, which since the 2026-09-01 rename is
  also stripped (the prefixed original is now `full_email`).

- **✅ RESOLVED 2026-07-29 — `customer_type` matching is now case-insensitive on all five
  branches** (all compare against `lower(...)`; verified no reclassification — case-sensitive
  and case-insensitive counts matched exactly, so the fix was purely defensive). The risk was
  a partner sending `EZCater@…` silently classifying as `person`.

- **✅ RESOLVED 2026-07-29 — SessionM `user_id` is now lowercased on all three
  `all_trans_users` branches** (`user_point_transactions`, `transaction_discounts`,
  `transaction_payments`) and in `sm_external_user_map`. Before the fix only the discounts
  branch was normalised, costing ~155 loyalty links/month.

- **✅ `is_guest_order` FIXED 2026-07-29 — it previously meant "POS order", not "guest".**

  The build read `case when ocs.is_loyalty_user is null then true else false end`. But
  `pulse.order_customers.is_loyalty_user` is a **non-nullable boolean** — 4,224,215 true /
  3,669,122 false / **0 null** — so `is null` could only fire when the pulse row was *absent*.
  The column was an exact alias for `pulse_order_id is null`.

  | June 2026 (store 1111 excluded) | Orders |
  |---|---|
  | All orders | 713,139 |
  | POS-only (`pulse_order_id is null`) | 425,630 |
  | Flagged `is_guest_order = true` | **425,630** — identical set |
  | Digital orders flagged guest | **0** |
  | Loyalty-scanned POS orders flagged guest | 94,754 ($2.21M net) |

  Every real digital guest was labelled a member; 94,754 loyalty scanners were labelled guests.
  **Any pre-2026-07-29 analysis that split on `is_guest_order` split on channel, not loyalty.**

  **New definition (steward):** a guest order is **first-party digital** *and* non-loyalty.
  Both halves matter — third-party and kiosk orders are non-loyalty by construction, not by
  guest choice.

  ```sql
  ocs.is_loyalty_user = 0   -- raw column is INT64 0/1 since 2026-09-23; was `= false`
  and lower(po.source) in ('mobile_web_source','web_source','ios','android','mobile_source')
  ```

  **The match is case-insensitive on purpose.** Full history holds exactly 10 distinct
  `po.source` values and one of them is `IOS` — a single order on 2023-06-14 that a
  case-sensitive in-list drops. That is the same failure class as the case-**sensitive**
  aggregator branches in `customer_type` (documented below): one oddly-cased value from
  upstream silently changes an order's classification.

  | Guest-eligible | Orders | Excluded | Orders |
  |---|---|---|---|
  | `iOS` | 2,094,394 | `checkmate` | 2,519,649 |
  | `mobile_web_source` | 950,282 | `Outdoor Kiosk` | 900,124 |
  | `web_source` | 898,673 | `operator` | 73,832 |
  | `Android` | 467,369 | `ezcater` | 19,149 |
  | `mobile_source` | 1,518 | | |
  | `IOS` | 1 | | |

  July 2026 (07-01 → 07-28), non-loyalty share by raw `po.source`:

  | `po.source` | Orders | Non-loyalty | % | Guest-eligible |
  |---|---|---|---|---|
  | `checkmate` | 90,834 | 90,834 | 100% | no — third party |
  | `ezcater` | 1,118 | 1,118 | 100% | no — third party |
  | `Outdoor Kiosk` | 34,024 | 30,165 | 88.7% | no — in-store terminal |
  | `operator` | 1,869 | 0 | 0% | no — call center |
  | `mobile_web_source` | 28,878 | **14,040** | **48.6%** | **yes** |
  | `web_source` | 15,983 | **3,186** | **19.9%** | **yes** |
  | `iOS` | 62,692 | 62 | 0.1% | yes |
  | `Android` | 12,668 | 32 | 0.3% | yes |

  **Guest checkout is a web / mobile-web feature.** The native apps sit at 0.1–0.3%
  non-loyalty — they still require login. July guest orders: **17,320**. Including
  `Outdoor Kiosk` would have added 30,165 in-store terminal orders and made the metric
  meaningless; that exclusion is the judgment call most likely to be questioned, and this is
  the reason.

  `iOS` and `Android` are genuine **raw** `po.source` values, not only the cleaned
  `order_source` labels. `mobile_source` is the legacy iOS value (1,518 orders, 2023 only) and
  is included so a full-history rebuild doesn't drop it.

  **FALSE is a catch-all, not "was a member."** It covers POS orders, third-party, kiosk,
  operator, *and* digital loyalty orders. Never read `is_guest_order = false` as "loyalty
  member" — for that, test loyalty directly (`sm_external_user_id is not null`,
  `mapped_cust_id`, or `claude.loyalty_user`). A guest *rate* must be computed against a
  first-party-digital denominator, not all orders.

  ⚠️ **The near-miss:** an interim fix added `ocs.order_id is not null` to the old predicate.
  That removes the only case that ever satisfied `is null`, so the column would have been
  `false` on **every order** — verified 0 matching rows across all 7,893,337
  `pulse.order_customers` rows. When a boolean column looks wrong, check the source column's
  null rate before patching the null test.

  Independent validation of the launch date: overall non-loyalty share of pulse orders holds
  flat at 49–51% Jan–Jun 2026, then steps to **56.2% in July** — driven entirely by
  `mobile_web_source` going to 48.6%. Guest checkout went live 2026-07-01.

- **✅ `mapped_cust_id` IS the right join key to `claude.loyalty_user`** (verified 2026-07-29
  against the live deduped view). `pulse_customer_id` and `sm_external_user_id` are the **same
  id space**, not two — of 142,386 June orders carrying both, **142,127 (99.8%) hold an
  identical value**. Only 259 differ, and just 26 of those resolve to a loyalty account.

  `mapped_cust_id` also covers materially more than `sm_external_user_id`: **27,953** June
  orders are pulse-identified with no SessionM id, and the order email agrees with the matched
  loyalty account on **26,632 (95.3%)** of them. Joining on `sm_external_user_id` silently
  drops all of those.

  ⚠️ **Do not "correct" this on the basis of an email-mismatch count.** Of the 7,568 June
  orders where `lower(mapped_email) <> loyalty_user.email`, **7,088 (93.7%) are the `cater_`
  prefix and nothing else**: the build's `sm_external_user_map` strips it
  (`regexp_replace(..., r'^cater_', '')`) while `loyalty_user.email` retains it, so
  `mapped_email` equals the stripped address exactly. **Compare against the stripped column** —
  since 2026-09-01 that is `loyalty_user.email` (the prefixed original is `full_email`).** Only 480 are genuinely different addresses — and the `sm_external_user_id` join
  carries 6,275 mismatches of its own, so the key is not the cause.

  *(An earlier revision of this file asserted the opposite. It reached that conclusion by
  attributing the whole email-mismatch count to the join key without testing whether the two
  ids were actually distinct, or whether the documented `cater_` normalization explained the
  gap. Both checks reverse the finding.)*

- **✅ Grain defect RESOLVED 2026-07-29 by the full-history rebuild.** `brink_order_id` 2279778269187 (2024-09-17, store 154) previously had **two** rows: two pulse orders (4545135, 4608051) pointing at the same Brink order, double-counting $263.99 across two customers. The `pulse_orders` CTE dedupes on `brink_order_id`; the earlier `partition by po.id` was a no-op because `po.id` was already unique. **Verified 2026-07-29 across the whole table: 50,315,908 rows, 50,315,908 distinct `brink_order_id`, 0 duplicates.** The grain is now exactly one row per Brink order and `count(*)` is safe.
  - **Tiebreak direction is HIGHEST pulse id** — `qualify row_number() over(partition by po.brink_order_id order by po.id desc) = 1`. **Steward-confirmed 2026-07-29:** an earlier statement that "lowest pulse id wins" was incorrect and is retracted; highest is the rule. A brink↔pulse order map table to replace the arbitrary tiebreak is still open (Asana 1216938720407007).
