# Design: campaign-level Braze marts (`braze.cam_agg_*`)

**Status:** decisions locked 2026-07-28 — ready to build
**Author:** Brent (steward) + Claude session 2026-07-28

**Steward decisions (2026-07-28):**

| # | Decision |
|---|---|
| 1 | Tables live in the **`braze`** dataset, prefixed **`cam_agg_`**. No `sales_ops` copy, no `claude` view layer. |
| 2 | Attribution window = **72 hours**, from the analysis in §5. Stored as one declared constant. |
| 3 | Attribution rule = **last touch** before the order, within the window. |
| 4 | Content card / banner / in-app: **impressions are the exposure metric**; `send_events` kept as a separate reference column, never used as a rate denominator. |
| 5 | **`message_variation_id` stays in the L1 grain** — A/B reporting comes out of the mart, not ad-hoc SQL. |

Fact grain = day × program × channel × variation · distinct users handled with **both** HLL sketches and a user-grain layer · revenue attribution in scope for this build.

---

## 1. The problem

A "campaign" in the business sense is one program that can reach a customer through email, push, SMS, RCS, content card, banner, and in-app message. Braze writes every channel **and** every event type to its own table, so answering "how did campaign X do?" today means unioning 7 activity tables + 9 engagement tables at query time (`sql/braze_campaign_daily_activity.sql`, `sql/braze_campaign_engagements.sql`).

That works but doesn't scale as the standing answer:

| | Measured |
|---|---|
| Relevant `braze` event tables | ~800 GiB, 1.5B+ rows |
| `email_send` alone | 257.8M rows / 110.8 GiB |
| 7 days of `email_send`, 4 columns | 209 MB scanned, 14s slot |
| Programs live on a typical day | 14–18 |
| Peak day send volume (email) | ~745K |

Every campaign question re-scans the same partitions, and a campaign-lifetime question spans months of them. Meanwhile the **answer** is tiny: 7 days of email at day × program × channel grain is **114 rows**. That ratio — hundreds of MB scanned to produce ~100 rows — is the whole case for a mart.

## 2. Architecture — four layers, all in `braze`

```
braze.* raw event tables (~800 GiB)
        │
        ├─► braze.cam_agg_day_channel        day × workspace × program × channel × variation  (fact + HLL sketches)
        │        └─► braze.cam_agg_program_dim        one row per program (rebuilt from the fact)
        │
        ├─► braze.cam_agg_program_user       program × user  (exact distincts, attribution base)
        │        └─► braze.cam_agg_order_attribution  one row per attributed ORDER (additive revenue)
```

Every layer is derived, so a bad build can be dropped and rebuilt from raw without touching upstream.

**Naming / access note:** the `cam_agg_` prefix is now the wall between curated and raw inside a dataset that has no other wall. The `braze-campaigns` skill must say plainly: **campaign questions go to `braze.cam_agg_*`; the raw event tables are only for what the marts can't answer** (dispatch-level attribution, send-cohort semantics, unmodeled event types).

**Build risk to check first:** the Currents → `braze_stream` → `braze` merge job writes into this dataset. Before deploying, confirm the job targets an explicit table list and does **not** enumerate `braze` tables dynamically — a discovery-based loop would try to merge the `cam_agg_*` tables. If it does enumerate, add a prefix exclusion on the job side before the first build.

### L1 — `braze.cam_agg_day_channel` (the "balance sheet" fact)

**Grain:** `event_date` × `workspace` × `program_id` × `channel` × `message_variation_id`
**Partition:** `event_date` · **Cluster:** `program_id`, `channel`
**Size:** a few hundred rows/week even with variation in the grain. Whole history is a few MB.

Verified 2026-07-28: `message_variation_id`, `canvas_step_id` and `workspace` exist on **all 15** send/impression/engagement tables in scope, so the grain needs no per-table NULL shims.

| Group | Columns |
|---|---|
| Keys | `event_date`, `workspace`, `program_type`, `program_id`, `program_name`, `channel`, `message_variation_id`, `message_variation_name` |
| Exposure | `activity_type` (`send` / `impression`), `send_events`, `impression_events`, `delivered_events`, `unique_sent_users`, `unique_delivered_users` |
| Engagement | `opens_all`, `opens_human`, `unique_openers_human`, `clicks`, `unique_clickers`, `replies`, `unique_repliers` |
| Negative | `unsubscribes`, `bounces`, `soft_bounces`, `aborts`, `spam_reports` |
| Sketches | `sent_users_sketch`, `opener_users_sketch`, `clicker_users_sketch`, `engaged_users_sketch` (HLL++, precision 15) |
| Coverage | `unique_sent_users_matchable` (numeric `external_user_id` only) |
| Ops | `is_mature` (`event_date <= current_date - 2`), `loaded_at` |

Per decision 4, content card / banner / in-app rows carry `activity_type = 'impression'` and populate `impression_events`; `send_events` is populated for content cards (feed placement) but is **never** the denominator of a rate. Banner and in-app have no send event at all.

**Semantics to state in the dictionary:** rows are *what happened on that day*, not *the results of that day's sends*. A long-tail open on day N+10 of a day-N send lands on day N+10. Range rollups per `program_id` are therefore correct at campaign level (which is how the skill already attributes), and for single-blast campaigns the distinction is nil. Send-cohort semantics require the `dispatch_id` join and are out of scope for L1.

### L2 — `braze.cam_agg_program_dim`

One row per `workspace` × `program_id`: latest `program_name`, `program_type`, `first_activity_date`, `last_activity_date`, `active_days`, `channels_used` (array), `variation_count`, `distinct_names_seen`. Full rebuild from L1 daily — costs nothing.

Why it exists: **campaign names are not stable.** Braze lets a campaign be renamed and names get reused. Keying reporting on `program_id` with one resolved current name kills the "same campaign, two names" class of inconsistent answers; `distinct_names_seen > 1` flags when a name-based question is ambiguous.

### L3 — `braze.cam_agg_program_user`

**Grain:** `workspace` × `program_id` × `external_user_id`
**Partition:** `first_exposure_date` · **Cluster:** `program_id`, `external_user_id`

`mapped_cust_id` (`safe_cast`), `first_exposure_utc`, `last_exposure_utc`, `channels_touched` (array), `opened_human`, `clicked`, `replied`, `unsubscribed`, `attributed_orders`, `attributed_net_sales`.

The layer that gives **exact** distinct users, cross-channel reach ("who got the email *and* the push"), and the join surface to orders. A 745K-recipient blast produces 745K rows; ~4–6M rows/month.

### L4 — `braze.cam_agg_order_attribution`

**Grain:** one row per `brink_order_id` with a qualifying prior exposure.
**Partition:** `business_date` · **Cluster:** `program_id`

`brink_order_id`, `business_date`, `mapped_cust_id`, `net_sales`, winning `program_id` / `program_name` / `channel` / `message_variation_id`, `exposure_utc`, `hours_to_order`, `competing_programs`.

**Why the order-grain table is the important half:** per-program attributed revenue is *not additive*. A customer hit by an email, a push and a canvas step gets their order counted under all three, so summing across programs badly overstates. L4 resolves one last-touch winner per order, so `sum(net_sales)` by program or channel is safe and reconciles to a real slice of total net sales.

Two readings, both labelled:

- **Any-touch (L1/L3):** "of users who got campaign X, what share ordered within 72h" — right for judging one campaign, never summed across campaigns.
- **Last-touch (L4):** "how much net sales campaign X owns" — additive, sums to a channel/period total.

## 3. Refresh strategy

Rolling delete + insert on the partition column, same pattern as `sql/sales_ops.order_customer.sql` — no MERGE, no state to corrupt.

| Layer | Lookback | Why |
|---|---|---|
| `cam_agg_day_channel` | **4 days** daily · **35 days** Monday · **380 days** on the 1st | Braze events backfill ~2 days (same-day reads run 20–25% low). 4 days = maturation + buffer. |
| `cam_agg_program_dim` | full rebuild | Reads only L1. |
| `cam_agg_program_user` | **10 days** by `first_exposure_date` | Exposure matures (4d) and the engagement/order flags keep changing through the 72h window. |
| `cam_agg_order_attribution` | **10 days** by `business_date` | A late-arriving exposure can change an order's winning program up to 72h after the order. |

The L3/L4 windows shrink from the 14 days originally proposed because the attribution window is now 72h, not 7 days (4d maturation + 3d window + 3d buffer).

**Schedule:** daily ~**5:00am MT**, after the 4am `order_customer` 8-day reload — so L4 never attributes against orders that are about to be rewritten. Deeper Monday/monthly reloads inherit the trigger pattern already in `sql/sales_ops.order_customer.sql`.

**Cost:** the daily 4-day window is roughly 2–5 GB scanned across all channels and event types (extrapolated from 209 MB for 7 days × 4 columns of `email_send`) — cents per day. The Monday 35-day pass is ~20–40 GB. A *single* analyst question on a quarter-long campaign today can scan more than a month of the mart's total refresh cost.

**Do not use views for L1/L3.** A view over these unions re-scans raw on every query and returns none of the savings. Materialize.

## 4. Validated findings — mart mechanics

All measured against production 2026-07-28.

**a) Summing daily distinct users is off by 3.5x.** 7 days of email sends, per day × program:

```
sum of daily distinct users : 3,057,890
true distinct over the range:   865,355
```

The single biggest trap in any pre-aggregated campaign table, and the reason a naive daily fact returns wrong "users reached" answers the moment someone rolls up a week.

**b) HLL++ sketches solve it to within 1%.** Merging stored per-row sketches over the same 7 days: **872,570 vs 865,355 exact — +0.83% error** at precision 15. L3 stays available whenever a number has to be exact.

```sql
-- stored per fact row
, hll_count.init(external_user_id, 15) as sent_users_sketch
-- any rollup
, hll_count.merge(sent_users_sketch)   as unique_sent_users
```

**c) 6.8% of recipients can never be tied to orders.** On 2026-07-20, 50,769 of 743,284 distinct `external_user_id` values were non-numeric (UUID-shaped), so no `mapped_cust_id`. Hence `unique_sent_users_matchable` alongside `unique_sent_users`: conversion rates divide by the matchable base, and the coverage number travels with the answer. Also why `safe_cast` is mandatory — a plain `cast` aborts the query.

**d) The attribution join works and is cheap.** Day × program × channel, `safe_cast(external_user_id as int64)` to `order_customer.mapped_cust_id`, `store_id <> 1111`, `customer_type = 'person'`: **202 MB scanned, 18s slot** for a week of sends. Both documented conversions required (`safe_cast` for the id, and `timestamp_seconds(time)` for the Braze clock — **not** `cast(event_timestamp as timestamp)`, which this prototype used and which is 6–7 h early because `event_timestamp` is America/Denver local, not UTC; corrected 2026-09-03, see the skill's Time columns). `first_exposure_utc` / `last_exposure_utc` / `exposure_utc` in the L3/L4 specs above must be built from `timestamp_seconds(time)`, and the section-5 window percentages need a re-run on the corrected clock before the mart is built.

## 5. The attribution-window analysis (decision 2)

Three independent measurements. **None of them found a response window** — which is itself the finding, and it changed the recommendation from 7 days to 3.

### 5a. No post-send spike exists at day grain

Cohort = all 669K recipients of the 2026-07-20 email blast; control = `braze.global_holdout`; order rate per 1,000 users by day offset:

| Day offset | Exposed /1k | Holdout /1k | Ratio |
|---|---|---|---|
| −14 | 10.36 | 1.98 | 5.2x |
| −7 | 8.69 | 1.90 | 4.6x |
| **0 (send)** | **8.05** | **1.69** | **4.8x** |
| +1 | 7.66 | 1.79 | 4.3x |
| +3 | 7.99 | 1.88 | 4.3x |
| +7 | 7.52 | 1.61 | 4.7x |

The exposed cohort sits at a flat ~4.3–5.2x the holdout on **every day, before and after the send**. Day 0 and day 1 are *lower* than the pre-period. Both series drift down ~10%/week together (mid-July seasonality — visible in the holdout too, so it isn't cohort-specific). Sundays are absent from the series because the stores are closed, which is a useful sanity check that the join is right.

Two conclusions: the exposed/holdout gap measures **who is on the email list** (engaged customers vs a random bucket of all profiles, many dormant), not campaign effect — so **the global holdout cannot serve as a lift control**. And with blasts going to nearly the whole list every 1–4 days, every day is day 0 of something; no decay curve can be recovered at day grain.

### 5b. A click doesn't produce a burst either

56,638 email clicks in July, hours from click to next order:

| Within | 6h | 1d | 2d | 3d | 5d | 7d | 14d |
|---|---|---|---|---|---|---|---|
| Ordered | 1.3% | 2.9% | 3.9% | 4.7% | 5.9% | 7.0% | 9.7% |

Accumulation is near-linear at ~0.5–0.7%/day with **no knee**. That is the shape of baseline ordering behaviour (an engaged customer orders roughly every two weeks anyway), not of a click-driven visit. Only 9.7% of clicks are followed by any order within 14 days.

### 5c. So choose the window on ambiguity, not on response

191,015 person-orders in July, matched back to the most recent exposure across email / push / SMS / RCS:

| Window | Orders attributable | Avg competing programs |
|---|---|---|
| 1 day | 68.9% | — |
| 2 days | 77.2% | — |
| **3 days** | **80.8%** | **1.99** |
| 5 days | 83.0% | — |
| 7 days | 83.7% | 3.76 |
| never (no exposure in 14d) | 14.3% | — |

Going 3 → 7 days buys **2.9 points** of coverage and **doubles** the number of programs competing for each order. The curve is flat past day 3 and the ambiguity is not. **72 hours** it is.

### 5d. Required labelling, and the gap this leaves

68.9% of orders already have an exposure within 24 hours because the list is messaged near-daily. Last-touch attribution here is therefore largely "which campaign happened to fire most recently." The mart's revenue columns must be labelled **last-touch influenced sales** in the dictionary and in every answer — never "incremental," "driven by," or "generated by."

**Gap to log:** true incrementality needs **per-campaign holdouts configured in Braze** (a random control slice excluded from that specific campaign). The global holdout can't do it, as 5a shows. Nothing in this build produces an incrementality number, and the skill should refuse to imply one.

## 6. Build order

1. Confirm the Currents merge job won't touch `cam_agg_*` tables (§2 build risk).
2. `sql/braze.cam_agg_day_channel.sql` + dictionary → re-verify the 3.5x and HLL findings hold on full history.
3. `sql/braze.cam_agg_program_dim.sql` + dictionary.
4. `sql/braze.cam_agg_program_user.sql` + dictionary.
5. `sql/braze.cam_agg_order_attribution.sql` + dictionary — reconcile last-touch attributed net sales against total person-order net sales for a known blast before publishing.
6. Rewrite `claude_skills/braze-campaigns/SKILL.md`: campaign questions go to `braze.cam_agg_*`; raw unions retained only for dispatch-level and send-cohort questions; the influenced-vs-incremental labelling rule stated as canonical.
7. Schedule at 5am MT with a freshness assertion (`max(event_date)`, `is_mature`) so a stale mart can't silently answer a question.

## 7. What this fixes

Same question, same answer — one definition of program identity, one engagement-rate denominator, one attribution rule and window, one honest treatment of distinct users. Analysts stop rebuilding 16-table unions by hand, campaign-lifetime questions get cheap, and maturation, matchability and the influenced-not-incremental caveat become columns and documented rules instead of things a session has to remember to mention.
