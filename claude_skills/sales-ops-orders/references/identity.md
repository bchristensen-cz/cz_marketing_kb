# Guest checkout gap and SessionM identity health check

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question involves guest orders, loyalty identity coverage, or identified-% looks off.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Guest checkout (launched 2026-06-25) — known gap

Guest checkout (web/mobile-web ordering without signing in) went live around **2026-06-25**, with the first orders landing **2026-06-29**. A guest-checkout order looks like this on `order_customer`:

```sql
and oc.order_source in ('Web', 'Mobile Web')   -- `source` on the legacy table
and oc.email is null
and oc.mapped_email is null
```

> **Corrected 2026-07-28.** This block previously said `order_source in ('mobile_web_source', 'web_source')`. **Those values do not exist** — the filter silently returned **zero rows**, so any answer built on it reported "no guest-checkout orders" rather than failing. The real values are `'Web'` and `'Mobile Web'` (verified against `business_date = 2026-07-27`, and they always matched `data_dictionaries/sales_ops.order_customer.md`). If you produced a guest-checkout number before this date, recheck it.
>
> **Blast radius (measured 2026-07-29):** the bad filter ran **118 times** across two analysts between 2026-07-24 and 2026-07-28 (jelgie@ 69, dgetz@ 49), zero times on 2026-07-29 — so the correction took. It sat inside a CTE feeding a guest-checkout arm that was `union all`'d to a known-customer arm in a weekly second-order report, so **every run returned a full, plausible result set with the guest arm contributing nothing.** No error, no empty output, just a number understated by the entire guest population. Lesson: when a `union all` arm can go empty, check each arm's row count independently before trusting the total (Asana 1216992671864463).
>
> **Where the bad values came from** — they are the *raw pulse* values. `sql/sales_ops.order_customer.sql` lines 358–359 map `po.source = 'mobile_web_source' → 'Mobile Web'` and `'web_source' → 'Web'`. Someone documented the upstream side of the mapping instead of the mart side. General lesson: **filter values you write must come from the mart's own dictionary, never from a build script's source expressions** — the whole point of the mart is that it renamed them.

**The mart carries no email or identity for these orders**, so you cannot tell a brand-new guest from a lapsed known customer using the approved tables alone. The two known workarounds both leave the walls and are therefore **not approved for business answers**:

1. `pulse.order_customers.email` joined on `cast(oc.pulse_order_id as string) = cast(po.order_id as string)` (note the cast — the types differ).
2. Braze `customevent` where `name = 'guest_email_from_order'`, `$.order_id` in `properties`; also `users.custom_attributes.guest_test_email`.

If a question needs guest-checkout identity, say the mart can't answer it and point at Asana 1216806056925588 (cohort mart with guest-checkout linkage). Three separate analysts hand-rolled workaround #1 on 2026-07-24.

## SessionM identity health check (defect fixed 2026-07-29 — check still recommended)

A defect that nulled `sm_external_user_id` on whole business dates was found and fixed on
2026-07-29 (`create_date > start_date` → `>=`). All affected dates are repaired and verified.
Full audit: `design/sessionm_identity_pipeline_audit.md`.

**Keep running the detector before customer-grain answers covering recent dates.** The failure
mode is worth guarding against because it is invisible in every financial number — sales, order
counts and channel mix all looked completely normal while person orders fell ~38%. Only
customer-grain metrics broke: customer counts, first-time vs repeat, retention, recency,
lifetime counts, and everything in `customer_attribute`.

```sql
select
oc.business_date
, count(*) as all_orders
, countif(oc.sm_external_user_id is not null) as sm_linked
, countif(os.customer_type = 'person') as person_orders  -- 2026-09-08: customer_type moved to order_sequence
, round(100 * countif(oc.sm_external_user_id is not null) / count(*), 1) as pct_sm_linked
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
and oc.store_id not in (1111, 999)
group by 1
order by 1
```

Healthy is **~28–33%**. Under 15% on a **completed** day means that date is corrupted — **say so
in the answer and exclude or caveat those dates** rather than reporting the number as-is.

> ### 🔑 Exclude today — SessionM merges once per day at 04:07 MT; yesterday is complete from the 05:02 rebuild
>
> **Today's date will always read ~0–2% `pct_sm_linked` and that is normal.** SessionM ingestion
> is three scheduled steps — S3→GCS transfer 03:45, GCS→`staging.sm_*` loader 03:55,
> `staging`→`sessionM.*` merge **04:07** (all MT; re-sequenced 2026-09-08/09) — followed by
> `claude.loyalty_user` 04:30, the **full-history `order_customer` + `order_sequence` rebuild at
> 05:02**, and `customer_attribute` 05:20. Yesterday therefore has its ~30% loyalty identity from
> ~05:10 MT; the hourly intraday runs (08:02–23:02) reload **today only**.
>
> - **Never apply the 15% rule to the current business date** — guaranteed false positive.
>   Yesterday is fair game after ~05:15 MT.
> - **Never answer a customer-grain question about today.** Customer counts, `mapped_cust_id`,
>   first-time vs repeat, `in_store_scan`, and anything from `order_sequence` /
>   `customer_attribute` are ~98% under-identified for today. Answer through yesterday and say why.
> - **If yesterday reads under 15% after 05:15 MT**, the three SessionM steps have probably fallen
>   out of order (it happened 2026-09-05 → 09-08: merge before loader, `sessionM.*` one day stale,
>   yesterday at 0.0%). Check `LOAD` vs `MERGE` times for `bigquery-loader-sa` on
>   `JOBS_BY_PROJECT` before blaming the order_customer script — full write-up in
>   `data_dictionaries/sales_ops.order_customer.md` § "SessionM loads once per day".
> - **If a settled day reads ~14% identified with `countif(pulse_order_id is not null) = 0`, it is
>   the PULSE orders feed, not SessionM** (happened 2026-09-15 → at least 09-18). Normal settled days
>   run ~55% identified = ~40% Pulse (digital + POS account lookups) + ~30% SessionM scans, overlapping.
>   The signature: `sm_external_user_id` normal (~4,050/day), `pulse_order_id` / `pulse_customer_id` /
>   `order_source` all 0, `is_guest_order` all NULL, and channel mix collapses to 100% "in-store" while
>   net sales stay right (Brink). Diagnosis: `pulse.orders` `max(created_at)` stalls while
>   `pulse.order_customers` stays current, and on `JOBS_BY_PROJECT` the compute SA
>   (`286373888726-compute@`) nightly ~01:35 MT loader runs its `orders_stg` LOAD + `orders` MERGE on
>   good days and **skips both with no BigQuery error** on bad days (85 tables touched instead of 87) —
>   the fault is upstream of BigQuery, in the extractor. Downstream: every customer-grain figure,
>   `order_source` channel mix, guest checkout, `customer_attribute`, Braze CDI and the social CAPI /
>   Google offline-conversion uploads are wrong for the gap days. Because the 5am chained run reloads
>   full history, the marts self-heal the morning after `pulse.orders` is backfilled — nothing to
>   re-run on our side; re-quote the gap days then.
> - **Sales, order counts and channel mix for today are fine** — those come from Brink, which
>   loads intraday every hour.
