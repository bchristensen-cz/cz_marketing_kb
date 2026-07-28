# Design: campaign-level Braze marts (`braze_campaign_*`)

**Status:** proposed — steward review before any build script is written
**Author:** Brent (steward) + Claude session 2026-07-28
**Scope decisions taken 2026-07-28:** fact grain = day × program × channel · distinct users handled with **both** HLL sketches and a user-grain layer · **revenue attribution in scope for this build** · design doc first, SQL after sign-off.

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

## 2. Proposed architecture — four layers

```
braze.* event tables (raw, ~800 GiB)
        │
        ├─► L1  braze_campaign_day_channel   day × workspace × program × channel   (fact + HLL sketches)
        │        └─► L2  braze_program_dim   one row per program (rebuilt from L1)
        │
        ├─► L3  braze_program_user           program × user   (exact distincts, attribution base)
        │        └─► L4  braze_order_attribution   one row per attributed ORDER (additive revenue)
```

Each layer is derived, so a bad build can be dropped and rebuilt from raw without touching upstream.

### L1 — `braze_campaign_day_channel` (the "balance sheet" fact)

**Grain:** `event_date` × `workspace` × `program_id` × `channel`
**Size:** ~100–150 rows/week. Whole history fits in a few MB.
**Partition:** `event_date` · **Cluster:** `program_id`, `channel`

Columns (proposed):

| Group | Columns |
|---|---|
| Keys | `event_date`, `workspace`, `program_type`, `program_id`, `program_name`, `channel` |
| Exposure | `activity_type` (`send` / `impression`), `send_events`, `delivered_events`, `unique_sent_users`, `unique_delivered_users` |
| Engagement | `opens_all`, `opens_human`, `unique_openers_human`, `clicks`, `unique_clickers`, `replies`, `unique_repliers` |
| Negative | `unsubscribes`, `bounces`, `soft_bounces`, `aborts`, `spam_reports` |
| Sketches | `sent_users_sketch`, `opener_users_sketch`, `clicker_users_sketch`, `engaged_users_sketch` (HLL++, precision 15) |
| Coverage | `unique_sent_users_matchable` (numeric `external_user_id` only) |
| Ops | `is_mature` (event_date ≤ current_date − 2), `loaded_at` |

**Semantics to state in the dictionary:** rows are *what happened on that day*, not *the results of that day's sends*. A long-tail open on day N+10 of a day-N send lands on day N+10. Range rollups per `program_id` are therefore correct at campaign level (which is how the skill already attributes), and for single-blast campaigns the distinction is nil. Send-cohort semantics require the `dispatch_id` join and are explicitly out of scope for L1.

### L2 — `braze_program_dim`

One row per `workspace` × `program_id`: latest `program_name`, `program_type`, `first_activity_date`, `last_activity_date`, `active_days`, `channels_used` (array), `distinct_names_seen`. Full rebuild from L1 daily — costs nothing.

Why it exists: **campaign names are not stable**. Braze lets a campaign be renamed and names get reused across programs. Keying reporting on `program_id` with a single resolved current name kills the "same campaign, two names" class of inconsistent answers. `distinct_names_seen > 1` flags the renames so we know when a name-based question is ambiguous.

### L3 — `braze_program_user`

**Grain:** `workspace` × `program_id` × `external_user_id`
**Partition:** `first_exposure_date` · **Cluster:** `program_id`, `external_user_id`

`mapped_cust_id` (`safe_cast`), `first_exposure_utc`, `last_exposure_utc`, `channels_touched` (array), `opened_human`, `clicked`, `replied`, `unsubscribed`, `attributed_orders`, `attributed_net_sales`.

This is the layer that gives **exact** distinct users, cross-channel reach ("who got the email *and* the push"), and the join surface to orders. Order of magnitude: a 745K-recipient blast produces 745K rows; ~4–6M rows/month.

### L4 — `braze_order_attribution`

**Grain:** one row per `brink_order_id` that has a qualifying prior exposure.
**Partition:** `business_date` · **Cluster:** `program_id`

`brink_order_id`, `business_date`, `mapped_cust_id`, `net_sales`, winning `program_id` / `program_name` / `channel`, `exposure_utc`, `hours_to_order`, `competing_programs` (how many other programs also had a live touch).

**Why an order-grain table is the important half of this design:** per-program attributed revenue is *not additive*. In the 7-day-window prototype below, a single customer exposed to an email, a push, and a canvas step gets their order counted under all three, so summing `attributed_net_sales` across programs badly overstates. L4 resolves one winner per order (proposed rule: **last touch before the order, within the window**), which means `sum(net_sales)` by program or channel is safe and reconciles to a real slice of total net sales.

Keep both readings and label them:

- **Any-touch (L1/L3):** "of users who got campaign X, what share ordered within 7 days" — right for judging a single campaign, never summed across campaigns.
- **Last-touch (L4):** "how much net sales does campaign X own" — additive, sums to a channel/period total.

## 3. Refresh strategy

Rolling delete + insert on the partition column, same pattern as `sales_ops.order_customer` — no MERGE, no state to corrupt.

| Layer | Lookback window | Why |
|---|---|---|
| L1 | last **4 days** daily; **35 days** Monday; **380 days** on the 1st | Braze events backfill ~2 days (documented: same-day reads run 20–25% low). 4 days = maturation + buffer. |
| L2 | full rebuild | Reads only L1. |
| L3 | last **14 days** by `first_exposure_date` | Exposure can mature (4d) and the engagement/order flags keep changing through the 7-day attribution window. |
| L4 | last **14 days** by `business_date` | A late-arriving exposure can change an order's winning program up to 7 days after the order. |

**Schedule:** daily ~**5:00am MT**, after the 4am `order_customer` 8-day reload — so L4 never attributes against orders that are about to be rewritten. Deeper Monday/monthly reloads inherit the same trigger pattern already in `sql/sales_ops.order_customer.sql`.

**Cost:** the daily 4-day window is roughly 2–5 GB scanned across all channels and event types (extrapolated from the measured 209 MB for 7 days × 4 columns of `email_send`) — cents per day. The Monday 35-day pass is ~20–40 GB. Compare against today's state, where a *single* analyst question on a quarter-long campaign can scan more than a month of the mart's total refresh cost.

**Do not use views for L1/L3.** Per the read-only/steward rule, a view over these unions re-scans raw on every query and gives back none of the savings. Materialize.

## 4. Validated findings from the 2026-07-28 prototypes

Everything below was run against production, not assumed.

**a) Summing daily distinct users is off by 3.5x.** 7 days of email sends, per day × program:

```
sum of daily distinct users : 3,057,890
true distinct over the range:   865,355
```

This is the single biggest trap in any pre-aggregated campaign table and the reason a naive daily fact would produce wrong "users reached" answers the moment someone rolls up a week.

**b) HLL++ sketches solve it to within 1%.** Merging the stored per-row sketches over the same 7 days returned **872,570 vs 865,355 exact — +0.83% error** at precision 15. Precision 17–18 tightens it further at a modest storage cost; L3 remains available whenever a number has to be exact.

```sql
-- stored per fact row
, hll_count.init(external_user_id, 15) as sent_users_sketch
-- any rollup
, hll_count.merge(sent_users_sketch)   as unique_sent_users
```

**c) 6.8% of send recipients can't be tied to orders.** On 2026-07-20, 50,769 of 743,284 distinct `external_user_id` values were non-numeric (UUID-shaped) and so have no `mapped_cust_id`. This is why L1 carries `unique_sent_users_matchable` alongside `unique_sent_users` — any conversion rate must divide by the matchable base, and the coverage number has to travel with the answer. (It's also why `safe_cast` is mandatory; a plain `cast` aborts the query.)

**d) The global holdout is a clean control group.** Of 743,284 send recipients on 2026-07-20, exactly **1** appears in `braze.global_holdout` (147,450 users). Suppression is working, so a holdout-based lift metric is viable: compare exposed order rate against the holdout order rate for the same window. Proposed as a **phase 3** addition (`braze_holdout_daily`, one row per day: holdout users, orderers, net sales) rather than part of this build.

**e) The attribution join works and is cheap.** 7-day window, day × program × channel, joining `safe_cast(external_user_id as int64)` to `order_customer.mapped_cust_id` with `store_id <> 1111` and `customer_type = 'person'`: **202 MB scanned, 18s slot**, ~4% conversion on the big blasts. Both documented casts were required (`safe_cast` for the id, `cast(event_timestamp as timestamp)` for the DATETIME/TIMESTAMP mismatch).

## 5. Open decisions for the steward

1. **Where do these live?** The 2026-07-22 rule says `claude` is an interface layer of views over `sales_ops` tables, materializing in `claude` only for expensive aggregations or marts with no `sales_ops` parent. These qualify either way. **Recommendation:** materialize in `sales_ops` (keeps all build scripts pointed at one dataset), expose thin authorized views in `claude`.
2. **Attribution window: 7 days?** Proposed default 7, stored as a single declared constant so it can be changed and rebuilt. Cafe Zupas visit frequency may argue for 3 or 14 — worth one analysis before it's frozen, because changing it later invalidates published numbers.
3. **Attribution rule: last touch?** Alternative: first touch, or channel-priority (SMS > email > push). Last touch is conventional and easy to explain; the decision matters more than the choice, so it should be written into the dictionary as canonical either way.
4. **`contentcard_send` vs `contentcard_impression`.** 141.4M sends vs 1.4M impressions — a content card "send" is a feed placement, not a viewing. Recommendation: L1 carries content card impressions as the exposure metric and keeps `send_events` for reference, with the asymmetry documented next to banner/in-app (which have no send at all).
5. **Should L1 keep `message_variation_id`?** Deferred out of the grain per today's decision. Adding it later is a rebuild, not a redesign — but A/B reporting will need it eventually.

## 6. Build order once approved

1. `sql/sales_ops.braze_campaign_day_channel.sql` + dictionary → validate the 3.5x/HLL findings hold on full history.
2. `sql/sales_ops.braze_program_dim.sql` + dictionary.
3. `sql/sales_ops.braze_program_user.sql` + dictionary.
4. `sql/sales_ops.braze_order_attribution.sql` + dictionary — reconcile last-touch attributed net sales against total net sales for a known blast before publishing.
5. Rewrite `claude_skills/braze-campaigns/SKILL.md` to point campaign questions at the marts, keeping the raw union templates only for questions the marts can't answer (variation-level, dispatch-level, send-cohort).
6. Schedule at 5am MT; add a freshness assertion (`max(event_date)` and `is_mature`) so a stale mart can't silently answer a question.

## 7. What this fixes

Same question, same answer — the marts hold one definition of program identity, one engagement-rate denominator, one attribution rule, and one honest treatment of distinct users. Analysts stop rebuilding 16-table unions by hand, campaign-lifetime questions get cheap, and the maturation and matchability caveats become columns instead of things a session has to remember to mention.
