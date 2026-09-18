-- braze_channel_value_analysis.sql
-- Value of a Braze send by channel and channel combination.
-- Written 2026-09-16. Window: exposure 2026-03-16 to 2026-09-14 (outcome capped by
-- mapped_cust_id maturity; 2026-09-15 sat at 13.7% coverage vs a 48-57% normal band).
--
-- Track A (steps 1-4) is DESCRIPTIVE ONLY. Channel exposure is not randomly assigned and
-- in-app message / banner / SMS are gated on an ordering session, so Track A ranks
-- reachability, not value. Track B (steps 5-7) is the causal read.
--
-- All scratch tables carry a 21-day expiry. Rebuild the chain once per session; every cut
-- off the final tables then costs ~10 MB.

-- ============================================================================
-- 1. Outcome panel: customer x day net sales, non-catering, person orders only
-- ============================================================================
create or replace table `marketing-data-442316`.scratch.chan_cust_daily_net_183d
partition by business_date
cluster by mapped_cust_id
options (expiration_timestamp = timestamp_add(current_timestamp(), interval 21 day)) as
select
oc.mapped_cust_id
, oc.business_date
, count(*) as orders
, sum(oc.net_sales) as net_sales
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between date '2026-03-16' and date '2026-09-14'
and oc.mapped_cust_id is not null
and oc.customer_type = 'person'
and oc.is_catering = false
group by oc.mapped_cust_id, oc.business_date;

-- ============================================================================
-- 2. Exposure panel: user x day x channel set, all seven channels
--    ~4.2 GB. banner starts 2026-06-17, rcs starts 2026-07-20 - restrict any
--    combination analysis to 2026-07-20 forward so all channels exist.
-- ============================================================================
create or replace table `marketing-data-442316`.scratch.chan_exposure_daily_183d
partition by event_date
cluster by cust_id
options (expiration_timestamp = timestamp_add(current_timestamp(), interval 21 day)) as
with exposure as (
select distinct es.external_user_id, es.event_date, 'email' as channel from `marketing-data-442316`.braze.email_send es where es.workspace = 'cafe_zupas' and es.event_date between date '2026-03-16' and date '2026-09-14'
union all
select distinct ps.external_user_id, ps.event_date, 'push' from `marketing-data-442316`.braze.pushnotification_send ps where ps.workspace = 'cafe_zupas' and ps.event_date between date '2026-03-16' and date '2026-09-14'
union all
select distinct ss.external_user_id, ss.event_date, 'sms' from `marketing-data-442316`.braze.sms_send ss where ss.workspace = 'cafe_zupas' and ss.event_date between date '2026-03-16' and date '2026-09-14'
union all
select distinct rs.external_user_id, rs.event_date, 'rcs' from `marketing-data-442316`.braze.rcs_send rs where rs.workspace = 'cafe_zupas' and rs.event_date between date '2026-03-16' and date '2026-09-14'
union all
select distinct cs.external_user_id, cs.event_date, 'content_card' from `marketing-data-442316`.braze.contentcard_send cs where cs.workspace = 'cafe_zupas' and cs.event_date between date '2026-03-16' and date '2026-09-14'
union all
select distinct bi.external_user_id, bi.event_date, 'banner' from `marketing-data-442316`.braze.banner_impression bi where bi.workspace = 'cafe_zupas' and bi.event_date between date '2026-03-16' and date '2026-09-14'
union all
select distinct ii.external_user_id, ii.event_date, 'iam' from `marketing-data-442316`.braze.inappmessage_impression ii where ii.workspace = 'cafe_zupas' and ii.event_date between date '2026-03-16' and date '2026-09-14'
)
select
e.external_user_id
, safe_cast(e.external_user_id as int64) as cust_id
, e.event_date
, countif(e.channel = 'email') > 0 as has_email
, countif(e.channel = 'push') > 0 as has_push
, countif(e.channel = 'sms') > 0 as has_sms
, countif(e.channel = 'rcs') > 0 as has_rcs
, countif(e.channel = 'content_card') > 0 as has_content_card
, countif(e.channel = 'banner') > 0 as has_banner
, countif(e.channel = 'iam') > 0 as has_iam
, countif(e.channel in ('sms', 'rcs')) > 0 as has_text
, count(distinct e.channel) as n_channels
, array_to_string(array_agg(distinct e.channel order by e.channel), '+') as channel_set
from exposure e
where 1=1
and e.external_user_id is not null
and e.external_user_id <> ''
group by e.external_user_id, e.event_date;

-- ============================================================================
-- 3. Track A: descriptive value by channel combination
--    DO NOT PRESENT AS CHANNEL VALUE. See step 4 for why.
-- ============================================================================
select
e.channel_set
, e.n_channels
, count(*) as user_days
, count(distinct e.cust_id) as users
, round(countif(ifnull(c.orders, 0) > 0) / count(*) * 100, 4) as order_rate_pct
, round(sum(ifnull(c.net_sales, 0)) / count(*), 6) as net_sales_per_user_day
from `marketing-data-442316`.scratch.chan_exposure_daily_183d e
left join `marketing-data-442316`.scratch.chan_cust_daily_net_183d c
on c.mapped_cust_id = e.cust_id
and c.business_date = e.event_date
where 1=1
and e.cust_id is not null
group by e.channel_set, e.n_channels
having count(*) >= 5000
order by user_days desc;

-- ============================================================================
-- 4. The confound diagnostic: does the exposure precede the order, and by how long?
--    Braze side is timestamp_seconds(time) (true UTC). NEVER cast event_timestamp,
--    which is America/Denver local. Order side is order_timestamp_utc.
--
--    Measured 2026-09-16: exposure precedes the order 88-97% of the time on every
--    channel, so this is NOT reverse causality in the timestamp sense. The lead time
--    is what gives it away - 70 min for iam and 56 for banner against 252 for email.
--    The session-gated channels fire inside the ordering visit.
-- ============================================================================
with exp as (
select 'email' as channel, es.external_user_id, es.event_date, min(timestamp_seconds(es.time)) as first_exposure_utc from `marketing-data-442316`.braze.email_send es where es.workspace = 'cafe_zupas' and es.event_date between date '2026-07-20' and date '2026-09-14' group by es.external_user_id, es.event_date
union all
select 'push', ps.external_user_id, ps.event_date, min(timestamp_seconds(ps.time)) from `marketing-data-442316`.braze.pushnotification_send ps where ps.workspace = 'cafe_zupas' and ps.event_date between date '2026-07-20' and date '2026-09-14' group by ps.external_user_id, ps.event_date
union all
select 'sms', ss.external_user_id, ss.event_date, min(timestamp_seconds(ss.time)) from `marketing-data-442316`.braze.sms_send ss where ss.workspace = 'cafe_zupas' and ss.event_date between date '2026-07-20' and date '2026-09-14' group by ss.external_user_id, ss.event_date
union all
select 'rcs', rs.external_user_id, rs.event_date, min(timestamp_seconds(rs.time)) from `marketing-data-442316`.braze.rcs_send rs where rs.workspace = 'cafe_zupas' and rs.event_date between date '2026-07-20' and date '2026-09-14' group by rs.external_user_id, rs.event_date
union all
select 'content_card', cs.external_user_id, cs.event_date, min(timestamp_seconds(cs.time)) from `marketing-data-442316`.braze.contentcard_send cs where cs.workspace = 'cafe_zupas' and cs.event_date between date '2026-07-20' and date '2026-09-14' group by cs.external_user_id, cs.event_date
union all
select 'banner', bi.external_user_id, bi.event_date, min(timestamp_seconds(bi.time)) from `marketing-data-442316`.braze.banner_impression bi where bi.workspace = 'cafe_zupas' and bi.event_date between date '2026-07-20' and date '2026-09-14' group by bi.external_user_id, bi.event_date
union all
select 'iam', ii.external_user_id, ii.event_date, min(timestamp_seconds(ii.time)) from `marketing-data-442316`.braze.inappmessage_impression ii where ii.workspace = 'cafe_zupas' and ii.event_date between date '2026-07-20' and date '2026-09-14' group by ii.external_user_id, ii.event_date
)
, ord as (
select
oc.mapped_cust_id
, oc.business_date
, min(oc.order_timestamp_utc) as first_order_utc
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between date '2026-07-20' and date '2026-09-14'
and oc.mapped_cust_id is not null
and oc.customer_type = 'person'
and oc.is_catering = false
group by oc.mapped_cust_id, oc.business_date
)
select
e.channel
, count(*) as ordering_user_days
, round(countif(e.first_exposure_utc < o.first_order_utc) / count(*) * 100, 2) as pct_exposure_before_order
, round(avg(timestamp_diff(o.first_order_utc, e.first_exposure_utc, minute)), 1) as avg_minutes_exposure_to_order
from exp e
join ord o
on o.mapped_cust_id = safe_cast(e.external_user_id as int64)
and o.business_date = e.event_date
group by e.channel
order by ordering_user_days desc;

-- ============================================================================
-- 5. Track B input: which channels each canvas actually sent on each day
--    Measured from the send tables, NOT from the ch: token in the canvas name -
--    the two disagree often (a canvas named ch:email_push routinely also fires
--    a content card).
-- ============================================================================
create or replace table `marketing-data-442316`.scratch.chan_canvas_channel_mix
options (expiration_timestamp = timestamp_add(current_timestamp(), interval 21 day)) as
with sends as (
select 'email' as channel, es.canvas_id, es.event_date, es.external_user_id from `marketing-data-442316`.braze.email_send es where es.workspace = 'cafe_zupas' and es.event_date between date '2026-06-17' and date '2026-09-14' and es.canvas_id is not null and es.canvas_id <> ''
union all
select 'push', ps.canvas_id, ps.event_date, ps.external_user_id from `marketing-data-442316`.braze.pushnotification_send ps where ps.workspace = 'cafe_zupas' and ps.event_date between date '2026-06-17' and date '2026-09-14' and ps.canvas_id is not null and ps.canvas_id <> ''
union all
select 'sms', ss.canvas_id, ss.event_date, ss.external_user_id from `marketing-data-442316`.braze.sms_send ss where ss.workspace = 'cafe_zupas' and ss.event_date between date '2026-06-17' and date '2026-09-14' and ss.canvas_id is not null and ss.canvas_id <> ''
union all
select 'rcs', rs.canvas_id, rs.event_date, rs.external_user_id from `marketing-data-442316`.braze.rcs_send rs where rs.workspace = 'cafe_zupas' and rs.event_date between date '2026-06-17' and date '2026-09-14' and rs.canvas_id is not null and rs.canvas_id <> ''
union all
select 'content_card', cs.canvas_id, cs.event_date, cs.external_user_id from `marketing-data-442316`.braze.contentcard_send cs where cs.workspace = 'cafe_zupas' and cs.event_date between date '2026-06-17' and date '2026-09-14' and cs.canvas_id is not null and cs.canvas_id <> ''
union all
select 'banner', bi.canvas_id, bi.event_date, bi.external_user_id from `marketing-data-442316`.braze.banner_impression bi where bi.workspace = 'cafe_zupas' and bi.event_date between date '2026-06-17' and date '2026-09-14' and bi.canvas_id is not null and bi.canvas_id <> ''
union all
select 'iam', ii.canvas_id, ii.event_date, ii.external_user_id from `marketing-data-442316`.braze.inappmessage_impression ii where ii.workspace = 'cafe_zupas' and ii.event_date between date '2026-06-17' and date '2026-09-14' and ii.canvas_id is not null and ii.canvas_id <> ''
)
, per_channel as (
select
s.canvas_id
, s.event_date
, s.channel
, count(distinct s.external_user_id) as users_reached
from sends s
group by s.canvas_id, s.event_date, s.channel
)
select
p.canvas_id
, p.event_date
, array_to_string(array_agg(p.channel order by p.channel), '+') as channel_mix
, count(*) as n_channels
, sum(p.users_reached) as channel_user_sum
, max(p.users_reached) as max_channel_users
from per_channel p
group by p.canvas_id, p.event_date;

-- ============================================================================
-- 6. Track B: pooled inverse-variance lift by channel mix, day-0 window
--    Reads scratch.holdout_canvas_stats (built by the holdout chain - see the
--    braze-campaigns skill, "Scratch tables"). Day-0 only: with near-daily
--    broadcasts a multi-day window shares orders between consecutive sends and
--    understates the pooled SE.
--
--    Measured 2026-09-16:
--      email+push+content_card  33 canvases  +$0.00604  se 0.00179  z 3.37  +4.9%
--      email+push                9 canvases  +$0.00469  se 0.00351  z 1.34  +3.6%
--      email only                3 canvases  +$0.00461  se 0.00669  z 0.69  +3.7%
--    Contrast email-only vs the three-channel stack: +$0.0014, se $0.0069, z 0.21.
--    80% MDE on that contrast is $0.019/user/send (15.7% of base) - a ceiling,
--    not evidence that push and content card are worthless.
-- ============================================================================
with arms as (
select
s.canvas_id
, s.canvas_name
, s.send_date
, max(if(s.in_control_group, s.n, null)) as n_c
, max(if(s.in_control_group, s.mean_ns_d0, null)) as mean_c
, max(if(s.in_control_group, s.var_ns_d0, null)) as var_c
, max(if(not s.in_control_group, s.n, null)) as n_t
, max(if(not s.in_control_group, s.mean_ns_d0, null)) as mean_t
, max(if(not s.in_control_group, s.var_ns_d0, null)) as var_t
from `marketing-data-442316`.scratch.holdout_canvas_stats s
group by s.canvas_id, s.canvas_name, s.send_date
)
, eff as (
select
case
	when m.channel_mix like '%content_card%' and m.channel_mix like '%push%' then 'email+push+content_card'
	when m.channel_mix = 'email+push' then 'email+push'
	when m.channel_mix = 'email' then 'email only'
	else ifnull(m.channel_mix, 'unmapped')
end as mix_group
, a.canvas_id
, a.n_c
, a.n_t
, a.mean_c
, a.mean_t - a.mean_c as delta
, a.var_t / a.n_t + a.var_c / a.n_c as var_delta
from arms a
left join `marketing-data-442316`.scratch.chan_canvas_channel_mix m
on m.canvas_id = a.canvas_id
and m.event_date = a.send_date
where 1=1
and a.n_c is not null
and a.n_t is not null
)
select
e.mix_group
, count(*) as canvases
, sum(e.n_c) as control_exposures
, sum(e.n_t) as treated_exposures
, round(sum(e.mean_c * e.n_c) / sum(e.n_c), 6) as control_base_ns
, round(sum(e.delta / e.var_delta) / sum(1 / e.var_delta), 6) as pooled_delta
, round(sqrt(1 / sum(1 / e.var_delta)), 6) as pooled_se
, round((sum(e.delta / e.var_delta) / sum(1 / e.var_delta)) / sqrt(1 / sum(1 / e.var_delta)), 2) as z
from eff e
group by e.mix_group
order by canvases desc;

-- ============================================================================
-- 7. The email x text 2x2 factorial
--    On 2026-09-04 and 2026-09-07 an email_push canvas and an RCS canvas each ran
--    on the same day with its OWN independent holdout draw. Every person in both
--    canvases is therefore randomly assigned to one of four cells.
--
--    The RCS canvases are NOT in scratch.holdout_arms_90d (that roster is tier-A
--    only), so pull their arms straight from canvas_experimentstep_splitentry.
--    Always match in_control_group OR the name regex - the boolean alone misses
--    legs literally named Control.
-- ============================================================================
create or replace table `marketing-data-442316`.scratch.chan_text_arms
options (expiration_timestamp = timestamp_add(current_timestamp(), interval 21 day)) as
select
se.canvas_id
, se.canvas_name
, se.event_date as arm_date
, se.external_user_id
, safe_cast(se.external_user_id as int64) as cust_id
, logical_or(se.in_control_group or regexp_contains(lower(ifnull(se.experiment_split_name, '')), r'hold|control|ctrl|suppress|baseline')) as is_control
from `marketing-data-442316`.braze.canvas_experimentstep_splitentry se
where 1=1
and se.workspace = 'cafe_zupas'
and se.event_date between date '2026-09-03' and date '2026-09-08'
and se.canvas_id in ('cc1824e5-13f1-4c28-b4b8-bfbaafebf8b2', 'f6b0b1b0-352d-4622-8bb8-fe4ea6d25392')
group by se.canvas_id, se.canvas_name, se.event_date, se.external_user_id;

-- The four cells. Run per arm_date, then pool the two days by inverse variance.
-- Measured 2026-09-16, pooled over both days, control base $0.235:
--   text (RCS) main effect  +$0.0578  se $0.0268  z  2.16   80% MDE $0.075
--   email main effect       +$0.0071  se $0.0268  z  0.26   80% MDE $0.075
--   interaction             -$0.0188  se $0.0536  z -0.35   80% MDE $0.150
-- The channels ADD. No synergy, no cannibalisation.
with t as (
select
ta.arm_date
, ta.cust_id
, logical_or(ta.is_control) as text_control
from `marketing-data-442316`.scratch.chan_text_arms ta
where 1=1
and ta.cust_id is not null
group by ta.arm_date, ta.cust_id
)
, e as (
select
ha.arm_date
, ha.cust_id
, logical_or(ha.in_control_group) as email_control
from `marketing-data-442316`.scratch.holdout_arms_90d ha
where 1=1
and ha.arm_date in (date '2026-09-04', date '2026-09-07')
and ha.cust_id is not null
group by ha.arm_date, ha.cust_id
)
, paired as (
select
t.arm_date
, t.cust_id
, t.text_control
, e.email_control
from t
join e
on e.cust_id = t.cust_id
and e.arm_date = t.arm_date
)
select
p.arm_date
, case when p.email_control then 'email_held' else 'email_sent' end as email_arm
, case when p.text_control then 'text_held' else 'text_sent' end as text_arm
, count(*) as n
, round(avg(ifnull(c.net_sales, 0)), 6) as mean_ns
, round(var_samp(ifnull(c.net_sales, 0)), 4) as var_ns
, countif(ifnull(c.orders, 0) > 0) as orderers
from paired p
left join `marketing-data-442316`.scratch.chan_cust_daily_net_183d c
on c.mapped_cust_id = p.cust_id
and c.business_date = p.arm_date
group by p.arm_date, email_arm, text_arm
order by p.arm_date, email_arm, text_arm;

-- ============================================================================
-- 8. Verification: independence audit, manipulation check and pre-period placebo
--    Run this before trusting any 2x2 cut. Measured 2026-09-07:
--      independence  9.92% of text-held were email-held vs 9.97% of text-sent (0.05pp)
--      manipulation  email reach 76.4%/76.0% by text arm; text reach 83.1%/83.3% by email arm
--      placebo       Sep 1 interaction +$0.015 against a Sep 7 interaction of -$0.022,
--                    i.e. the estimate is the size of its own noise
-- ============================================================================
with t as (
select
ta.arm_date
, ta.cust_id
, logical_or(ta.is_control) as text_control
from `marketing-data-442316`.scratch.chan_text_arms ta
where 1=1
and ta.cust_id is not null
and ta.arm_date = date '2026-09-07'
group by ta.arm_date, ta.cust_id
)
, e as (
select
ha.arm_date
, ha.cust_id
, logical_or(ha.in_control_group) as email_control
from `marketing-data-442316`.scratch.holdout_arms_90d ha
where 1=1
and ha.arm_date = date '2026-09-07'
and ha.cust_id is not null
group by ha.arm_date, ha.cust_id
)
, paired as (
select
t.cust_id
, t.text_control
, e.email_control
from t
join e
on e.cust_id = t.cust_id
and e.arm_date = t.arm_date
)
, reached as (
select
x.cust_id
, logical_or(x.has_email) as got_email
, logical_or(x.has_rcs or x.has_sms) as got_text
from `marketing-data-442316`.scratch.chan_exposure_daily_183d x
where 1=1
and x.event_date = date '2026-09-07'
and x.cust_id is not null
group by x.cust_id
)
select
case when p.email_control then 'email_held' else 'email_sent' end as email_arm
, case when p.text_control then 'text_held' else 'text_sent' end as text_arm
, count(*) as n
, round(countif(ifnull(r.got_email, false)) / count(*) * 100, 2) as pct_reached_email
, round(countif(ifnull(r.got_text, false)) / count(*) * 100, 2) as pct_reached_text
, round(avg(ifnull(pre.net_sales, 0)), 6) as placebo_mean_ns_sep01
from paired p
left join reached r
on r.cust_id = p.cust_id
left join `marketing-data-442316`.scratch.chan_cust_daily_net_183d pre
on pre.mapped_cust_id = p.cust_id
and pre.business_date = date '2026-09-01'
group by email_arm, text_arm
order by email_arm, text_arm;
