-- =====================================================================================
-- claude.guest_feedback* and claude.online_reviews — Tattle guest-feedback interface layer
-- =====================================================================================
-- Authorized views over tattle.* (loaded nightly ~05:10 MT by the Tattle loader, see
-- tattle.load_runs). Built for customer service first: look up a guest's feedback,
-- read what they wrote, see whether the store replied, and tie it to the order.
--
--   1. guest_feedback            one row per Tattle survey (contact form or experience survey)
--   2. guest_feedback_snapshots  one row per survey x category (Food Quality, Accuracy, ...)
--   3. guest_feedback_answers    one row per survey x question, PII questions removed
--   4. guest_feedback_daily      one row per store x business_date: volume, ratings, recovery funnel
--   5. online_reviews            one row per public review (Google, Yelp, Grubhub, Bing, Apple) with the reply
--
-- Facts the views rely on (measured 2026-10-20 over 2024-04-23 -> 2026-10-19, 35,609 surveys):
--   * Two kinds of survey share one table. snapshot_count > 0 = post-order EXPERIENCE SURVEY
--     (Pick-up / Dine-in / Drive-Thru / Delivery Experience questionnaires, 9,778 rows, from
--     2025-11). snapshot_count = 0 = CONTACT FORM from cafezupas.com/talk (Loyalty & App,
--     Other Feedback, Menu & Nutrition, Catering Orders, Catering Rewards & App, and the
--     retired Experience Feedback form, 2024-04 -> 2026-06-02). Contact forms are complaint
--     intake, so 65% of all rows rate 1-2; never quote the average as "guest satisfaction".
--   * An INCIDENT is opened for every survey rated 1-3 and never for 4-5 (28,621 incidents,
--     100.0% of rating <= 3). The funnel timestamps come straight from Tattle:
--     reviewed_at (Tattle "seen"), messaged_at (Tattle "replied"), resolved_at, recovered_at
--     (Tattle "recovered"). Checked against Tattle's own per-location rollup
--     tattle.location_metrics_daily: 99.4% of store-days agree on incident count.
--   * order_id is '<brink_order_id>-<brink_order_id>' on 6,390 surveys (referral_source =
--     'brink', the receipt QR). 100% join to sales_ops.order_customer.brink_order_id; 99.9%
--     on the same business_date, 99.3% on the same store.
--   * email_hash = to_hex(sha256(lower(trim(email)))), verified 6,368 / 6,368 against the
--     joined order email. phone_hash = to_hex(sha256('1' || <10 digits>)), 610 / 623 (98%).
--     Customer service looks a guest up by hashing the address in the query (see the skill).
--   * Tattle's externalId for Valley Fair is 110; the Brink store id is 10. Remapped here
--     until the loader (tattle.locations.store_id) is fixed. Every other location maps 1:1.
--   * tattle.*._raw still carries the guest's typed name and phone inside questions[].answerText.
--     The views never expose _raw. survey_questions already nulls answer_text where
--     answer_is_pii = true; guest_feedback_answers drops those rows outright.
--   * business_date = the experience date (local), not the submission date. created_at_utc is
--     the submission instant; created_at_local converts it with the store's IANA timezone
--     (America/Denver when the store is unknown).
--
-- History: Brent deployed the first guest_feedback and guest_feedback_snapshots views
-- 2026-10-09 (undocumented). This file replaces both and adds the other three, 2026-10-20.
-- =====================================================================================


-- =====================================================================================
-- 1. claude.guest_feedback — one row per survey
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.guest_feedback as
with q as (
  select id, title
  from `marketing-data-442316`.tattle.questionnaires
  qualify row_number() over (partition by id order by snapshot_date desc) = 1
)
, c as (
  select id, label
  from `marketing-data-442316`.tattle.channels
  qualify row_number() over (partition by id order by snapshot_date desc) = 1
)
, a as (
  -- the categorical and free-text answers worth having on the survey row itself
  select sq.survey_id
  , max(case when sq.question_text in ("What's going on?", 'What can we help with?', 'What is your inquiry regarding?') then sq.answer_text end) as request_type
  , max(case when sq.question_text = 'What type of experience did you have today?' then sq.answer_text end) as experience_type
  , max(case when sq.question_text in ('Tell us more!', 'Please share any other feedback, comments, or concerns so that we can improve your visit next time!') then nullif(trim(sq.answer_text), '') end) as comment
  , max(case when sq.question_text = 'What is your order number?' then nullif(trim(sq.answer_text), '') end) as order_number_entered
  from `marketing-data-442316`.tattle.survey_questions sq
  where sq.answer_is_pii = false
  group by sq.survey_id
)
select
s.survey_id
, s.business_date
, d.week_ending
, case when s.store_id = 110 then 10 else s.store_id end as store_id
, si.store_name
, si.store_state as market
, si.is_comp_store
, s.tattle_location_id
, case when s.snapshot_count > 0 then 'experience survey' else 'contact form' end as feedback_type
, q.title as questionnaire
, c.label as channel
, a.request_type
, a.experience_type
, s.referral_source
, s.delivery_partner
, s.order_id
, safe_cast(split(s.order_id, '-')[safe_offset(0)] as int64) as brink_order_id
, a.order_number_entered
, s.created_at_utc
, datetime(s.created_at_utc, coalesce(si.timezone_name, 'America/Denver')) as created_at_local
, s.experience_at_local
, s.rating
, s.score
, s.rating <= 2 as is_negative
, s.flagged
, a.comment
, s.snapshot_count
, s.question_count
, s.email_hash
, s.phone_hash
, s.has_email
, s.has_phone
, i.incident_id
, i.incident_id is not null as has_incident
, case
	when i.recovered_at_utc is not null then 'recovered'
	when i.resolved_at_utc is not null then 'resolved'
	when i.messaged_at_utc is not null then 'replied'
	when i.reviewed_at_utc is not null then 'seen'
	when i.incident_id is not null then 'open'
	end as incident_status
, i.reviewed_at_utc is not null as incident_reviewed
, i.messaged_at_utc is not null as incident_messaged
, i.resolved_at_utc is not null as incident_resolved
, i.recovered_at_utc is not null as incident_recovered
, i.reviewed_at_utc as incident_reviewed_at_utc
, i.messaged_at_utc as incident_messaged_at_utc
, i.resolved_at_utc as incident_resolved_at_utc
, i.recovered_at_utc as incident_recovered_at_utc
, timestamp_diff(i.messaged_at_utc, s.created_at_utc, hour) as hours_to_reply
, i.reward_code_count
from `marketing-data-442316`.tattle.surveys s
left join `marketing-data-442316`.sales_ops.date_dim d
  on d.cal_date = s.business_date
  left join `marketing-data-442316`.sales_ops.store_info si
    on si.store_id = case when s.store_id = 110 then 10 else s.store_id end
    left join q
      on q.id = s.questionnaire_id
      left join c
        on c.id = s.channel_id
        left join a
          on a.survey_id = s.survey_id
          left join `marketing-data-442316`.tattle.incidents i
            on i.survey_id = s.survey_id
where 1=1
and (s.store_id is null or s.store_id not in (1111, 999))


-- =====================================================================================
-- 2. claude.guest_feedback_snapshots — one row per survey x category
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.guest_feedback_snapshots as
with rs as (
  -- pre-aggregated so the view stays de-correlatable (a correlated string_agg broke
  -- any query that aggregated over the view, 2026-10-20)
  select r.survey_id
  , r.snapshot_id
  , array_agg(struct(r.reason_id, r.label, r.impact) order by r.reason_id) as reasons
  , string_agg(concat(r.label, case r.impact when -1 then ' (-)' when 1 then ' (+)' else '' end), ', ' order by r.reason_id) as reason_labels
  from `marketing-data-442316`.tattle.survey_snapshot_reasons r
  group by r.survey_id, r.snapshot_id
)
select
sn.survey_id
, sn.business_date
, case when sn.store_id = 110 then 10 else sn.store_id end as store_id
, sn.snapshot_id
, sn.label as category
, sn.rating
, sn.rating <= 2 as is_negative
, nullif(trim(sn.comment), '') as comment
, sn.reason_count
, coalesce(rs.reasons, []) as reasons
, rs.reason_labels
from `marketing-data-442316`.tattle.survey_snapshots sn
left join rs
  on rs.survey_id = sn.survey_id
  and rs.snapshot_id = sn.snapshot_id
where 1=1
and (sn.store_id is null or sn.store_id not in (1111, 999))


-- =====================================================================================
-- 3. claude.guest_feedback_answers — one row per survey x question, PII rows removed
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.guest_feedback_answers as
select
sq.survey_id
, sq.business_date
, case when sq.store_id = 110 then 10 else sq.store_id end as store_id
, sq.seq
, sq.question_id
, sq.question_text
, sq.answer_id
, sq.answer_id is not null as is_choice
, nullif(trim(sq.answer_text), '') as answer_text
from `marketing-data-442316`.tattle.survey_questions sq
where 1=1
and sq.answer_is_pii = false
and (sq.store_id is null or sq.store_id not in (1111, 999))


-- =====================================================================================
-- 4. claude.guest_feedback_daily — one row per store x business_date
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.guest_feedback_daily as
select
s.business_date
, d.week_ending
, case when s.store_id = 110 then 10 else s.store_id end as store_id
, si.store_name
, si.store_state as market
, count(*) as surveys
, countif(s.snapshot_count > 0) as experience_surveys
, countif(s.snapshot_count = 0) as contact_forms
, round(avg(s.rating), 2) as avg_rating
, round(avg(case when s.snapshot_count > 0 then s.rating end), 2) as avg_experience_rating
, countif(s.rating <= 2) as negative_surveys
, countif(s.rating >= 4) as positive_surveys
, countif(i.incident_id is not null) as incidents
, countif(i.reviewed_at_utc is not null) as incidents_seen
, countif(i.messaged_at_utc is not null) as incidents_replied
, countif(i.resolved_at_utc is not null) as incidents_resolved
, countif(i.recovered_at_utc is not null) as incidents_recovered
, round(avg(timestamp_diff(i.messaged_at_utc, s.created_at_utc, hour)), 1) as avg_hours_to_reply
from `marketing-data-442316`.tattle.surveys s
left join `marketing-data-442316`.sales_ops.date_dim d
  on d.cal_date = s.business_date
  left join `marketing-data-442316`.sales_ops.store_info si
    on si.store_id = case when s.store_id = 110 then 10 else s.store_id end
    left join `marketing-data-442316`.tattle.incidents i
      on i.survey_id = s.survey_id
where 1=1
and (s.store_id is null or s.store_id not in (1111, 999))
group by 1, 2, 3, 4, 5


-- =====================================================================================
-- 5. claude.online_reviews — one row per public review, latest reply attached
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.online_reviews as
with resp as (
  select rr.review_id
  , rr.response_id
  , rr.responded_at_utc
  , rr.text
  , rr.status
  from `marketing-data-442316`.tattle.online_review_responses rr
  qualify row_number() over (partition by rr.review_id order by rr.status = 'Published' desc, rr.responded_at_utc desc) = 1
)
select
r.review_id
, r.business_date
, d.week_ending
, case when r.store_id = 110 then 10 else r.store_id end as store_id
, si.store_name
, si.store_state as market
, r.tattle_location_id
, r.provider
, r.rating
, r.rating <= 2 as is_negative
, r.reviewed_at_utc
, r.reviewer
, nullif(trim(r.text), '') as review_text
, r.url
, r.response_count
, r.response_count > 0 as has_response
, resp.responded_at_utc
, resp.status as response_status
, nullif(trim(resp.text), '') as response_text
, timestamp_diff(resp.responded_at_utc, r.reviewed_at_utc, hour) as hours_to_response
from `marketing-data-442316`.tattle.online_reviews r
left join `marketing-data-442316`.sales_ops.date_dim d
  on d.cal_date = r.business_date
  left join `marketing-data-442316`.sales_ops.store_info si
    on si.store_id = case when r.store_id = 110 then 10 else r.store_id end
    left join resp
      on resp.review_id = r.review_id
where 1=1
and (r.store_id is null or r.store_id not in (1111, 999))
