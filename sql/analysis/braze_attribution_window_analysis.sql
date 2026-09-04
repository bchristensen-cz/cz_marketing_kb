-- =============================================================================
-- braze_attribution_window_analysis.sql
-- -----------------------------------------------------------------------------
-- purpose : the three measurements behind steward decision 2 (attribution
--           window = 72 hours) in design/braze_campaign_marts_design.md.
--           kept so the decision can be re-derived, not just re-asserted.
--
-- run     : 2026-07-28. results are recorded in section 5 of the design doc.
--           dates are literals on purpose -- re-running with a different
--           window changes the numbers, so a re-run must be dated again.
--
-- headline: none of the three found a response window. the window is a
--           reporting convention chosen to minimise ambiguity, not an
--           empirical constant. label revenue "last-touch influenced sales".
--
-- 2026-09-03 correction: sections B and C originally built the braze clock as
--           cast(event_timestamp as timestamp). event_timestamp is
--           America/Denver local, not utc, so that exposure clock was 6h early
--           and the recorded percentages rest on a -6h..+66h window, not
--           0..72h. the sql below now uses timestamp_seconds(time) (true utc).
--           the numbers in the comments are the ORIGINAL 2026-07-28 run and
--           have NOT been re-derived -- re-run and re-date before citing them.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A. is there a post-send spike at day grain?
--    exposed cohort (one blast) vs braze.global_holdout, order rate per 1k
--    result: flat ~4.3-5.2x ratio on every day, before AND after the send.
--            day 0 and day 1 are LOWER than the pre-period. the gap measures
--            list membership, not campaign effect -> the global holdout can
--            NOT serve as a lift control.
-- -----------------------------------------------------------------------------
with cohort as (
select distinct safe_cast(es.external_user_id as int64) as mapped_cust_id
from `marketing-data-442316`.braze.email_send es
where 1=1
and es.event_date = date '2026-07-20'
and es.workspace = 'cafe_zupas'
and safe_cast(es.external_user_id as int64) is not null
)

, holdout as (
select distinct safe_cast(gh.external_id as int64) as mapped_cust_id
from `marketing-data-442316`.braze.global_holdout gh
where safe_cast(gh.external_id as int64) is not null
)

, orders as (
select
  oc.mapped_cust_id
, oc.business_date
, oc.net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between date '2026-07-06' and date '2026-07-27'
and oc.store_id <> 1111
and oc.customer_type = 'person'
and oc.mapped_cust_id is not null
)

, exposed_daily as (
select
  date_diff(o.business_date, date '2026-07-20', day) as day_offset
, count(distinct o.mapped_cust_id)                   as orderers
, round(sum(o.net_sales), 0)                         as net_sales
from orders o
  join cohort c
    on c.mapped_cust_id = o.mapped_cust_id
group by 1
)

, holdout_daily as (
select
  date_diff(o.business_date, date '2026-07-20', day) as day_offset
, count(distinct o.mapped_cust_id)                   as orderers
from orders o
  join holdout h
    on h.mapped_cust_id = o.mapped_cust_id
group by 1
)

select
  e.day_offset
, e.orderers                                                                  as exposed_orderers
, round(1000 * e.orderers / (select count(*) from cohort), 2)                  as exposed_per_1k
, round(1000 * h.orderers / (select count(*) from holdout), 2)                 as holdout_per_1k
, round(1000 * e.orderers / (select count(*) from cohort)
      - 1000 * h.orderers / (select count(*) from holdout), 2)                 as lift_per_1k
, e.net_sales
from exposed_daily e
  left join holdout_daily h
    on h.day_offset = e.day_offset
where e.day_offset between -14 and 7
order by e.day_offset
;
-- note: sundays are absent from the output -- the stores are closed. useful
-- sanity check that the join and the offsets are right.


-- -----------------------------------------------------------------------------
-- B. how much does the window width actually buy?
--    every july person-order matched back to its most recent exposure across
--    the four direct channels. content card / banner / in-app are excluded on
--    purpose: a content card "send" is a feed placement, not an exposure, and
--    141M of them would swamp the last-touch winner.
--    result: 3d = 80.8% attributable at 1.99 competing programs
--            7d = 83.7% attributable at 3.76 competing programs
--            -> +2.9pp coverage for 2x the ambiguity. window = 72h.
-- -----------------------------------------------------------------------------
with exposure as (
select time, external_user_id, coalesce(nullif(campaign_id, ''), canvas_id) as program_id
from `marketing-data-442316`.braze.email_send
where event_date between date '2026-06-25' and date '2026-07-27' and workspace = 'cafe_zupas'
union all
select time, external_user_id, coalesce(nullif(campaign_id, ''), canvas_id) as program_id
from `marketing-data-442316`.braze.pushnotification_send
where event_date between date '2026-06-25' and date '2026-07-27' and workspace = 'cafe_zupas'
union all
select time, external_user_id, coalesce(nullif(campaign_id, ''), canvas_id) as program_id
from `marketing-data-442316`.braze.sms_send
where event_date between date '2026-06-25' and date '2026-07-27' and workspace = 'cafe_zupas'
union all
select time, external_user_id, coalesce(nullif(campaign_id, ''), canvas_id) as program_id
from `marketing-data-442316`.braze.rcs_send
where event_date between date '2026-06-25' and date '2026-07-27' and workspace = 'cafe_zupas'
)

, exp_clean as (
select
  safe_cast(e.external_user_id as int64) as mapped_cust_id
, timestamp_seconds(e.time)              as exposure_utc
, e.program_id
from exposure e
where 1=1
and e.program_id is not null
and safe_cast(e.external_user_id as int64) is not null
)

, orders as (
select
  oc.brink_order_id
, oc.mapped_cust_id
, oc.order_timestamp_utc
, oc.net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between date '2026-07-01' and date '2026-07-27'
and oc.store_id <> 1111
and oc.customer_type = 'person'
and oc.mapped_cust_id is not null
)

, joined as (
select
  o.brink_order_id
, o.net_sales
, timestamp_diff(o.order_timestamp_utc, max(e.exposure_utc), hour)               as hours_since_last_exposure
, count(distinct case when timestamp_diff(o.order_timestamp_utc, e.exposure_utc, hour) between 0 and 72
                      then e.program_id end)                                     as programs_within_3d
, count(distinct case when timestamp_diff(o.order_timestamp_utc, e.exposure_utc, hour) between 0 and 168
                      then e.program_id end)                                     as programs_within_7d
from orders o
  left join exp_clean e
    on e.mapped_cust_id = o.mapped_cust_id
    and e.exposure_utc <= o.order_timestamp_utc
    and e.exposure_utc >= timestamp_sub(o.order_timestamp_utc, interval 336 hour)
group by o.brink_order_id, o.net_sales, o.order_timestamp_utc
)

select
  count(*)                                                              as person_orders
, round(100 * countif(hours_since_last_exposure is null) / count(*), 1) as pct_no_exposure_14d
, round(100 * countif(hours_since_last_exposure <= 24) / count(*), 1)   as pct_within_1d
, round(100 * countif(hours_since_last_exposure <= 48) / count(*), 1)   as pct_within_2d
, round(100 * countif(hours_since_last_exposure <= 72) / count(*), 1)   as pct_within_3d
, round(100 * countif(hours_since_last_exposure <= 120) / count(*), 1)  as pct_within_5d
, round(100 * countif(hours_since_last_exposure <= 168) / count(*), 1)  as pct_within_7d
, round(avg(programs_within_3d), 2)                                     as avg_competing_programs_3d
, round(avg(programs_within_7d), 2)                                     as avg_competing_programs_7d
from joined
;


-- -----------------------------------------------------------------------------
-- C. does a CLICK produce a burst? (a click is real intent, so this isolates
--    the response window in a way an always-on send calendar cannot)
--    result: 1.3% @6h, 2.9% @1d, 4.7% @3d, 7.0% @7d, 9.7% @14d -- near-linear
--            at ~0.5-0.7%/day with NO knee. that is baseline ordering
--            behaviour, not click-driven response.
-- -----------------------------------------------------------------------------
with clicks as (
select
  safe_cast(ec.external_user_id as int64) as mapped_cust_id
, timestamp_seconds(ec.time)             as click_utc
from `marketing-data-442316`.braze.email_click ec
where 1=1
and ec.event_date between date '2026-07-01' and date '2026-07-20'
and ec.workspace = 'cafe_zupas'
and safe_cast(ec.external_user_id as int64) is not null
)

, orders as (
select
  oc.mapped_cust_id
, oc.order_timestamp_utc
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between date '2026-07-01' and date '2026-07-27'
and oc.store_id <> 1111
and oc.customer_type = 'person'
and oc.mapped_cust_id is not null
)

, first_order as (
select
  c.mapped_cust_id
, c.click_utc
, min(timestamp_diff(o.order_timestamp_utc, c.click_utc, hour)) as hours_to_order
from clicks c
  left join orders o
    on o.mapped_cust_id = c.mapped_cust_id
    and o.order_timestamp_utc >= c.click_utc
    and o.order_timestamp_utc < timestamp_add(c.click_utc, interval 336 hour)
group by c.mapped_cust_id, c.click_utc
)

select
  count(*)                                                       as clicks
, round(100 * countif(hours_to_order is not null) / count(*), 1)  as pct_ordered_in_14d
, round(100 * countif(hours_to_order <= 6)   / count(*), 1)       as pct_within_6h
, round(100 * countif(hours_to_order <= 24)  / count(*), 1)       as pct_within_1d
, round(100 * countif(hours_to_order <= 48)  / count(*), 1)       as pct_within_2d
, round(100 * countif(hours_to_order <= 72)  / count(*), 1)       as pct_within_3d
, round(100 * countif(hours_to_order <= 120) / count(*), 1)       as pct_within_5d
, round(100 * countif(hours_to_order <= 168) / count(*), 1)       as pct_within_7d
, round(100 * countif(hours_to_order <= 336) / count(*), 1)       as pct_within_14d
from first_order
;
