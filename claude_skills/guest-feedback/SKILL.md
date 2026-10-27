---
name: guest-feedback
description: How to query Cafe Zupas guest feedback in BigQuery — the claude.guest_feedback* and claude.online_reviews views over Tattle. Use for ANY question about guest complaints, surveys, ratings, incidents and recovery, store replies, contact-form requests (points, account, coupons, catering), public Google / Yelp / Grubhub reviews, or looking up what one guest has told us. Built for customer service first.
---

# Querying Guest Feedback (Tattle)

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first.

Project `marketing-data-442316`. Five approved views, all in the `claude` dataset. Column
docs: `data_dictionaries/claude.guest_feedback.md` (one file for all five). Read it before
writing a non-trivial query.

| View | Grain | Use for |
|---|---|---|
| `claude.guest_feedback` | 1 row per survey | The main table: who wrote in, about which store, what kind of form, rating, the comment, whether the store replied |
| `claude.guest_feedback_snapshots` | 1 row per survey x category | Food Quality / Accuracy / Speed / Hospitality / Online Ordering ratings and per-category comments (experience surveys only) |
| `claude.guest_feedback_answers` | 1 row per survey x question | Every non-PII answer, when the survey row's `request_type` / `comment` is not enough |
| `claude.guest_feedback_daily` | 1 row per store x day | Volume, average rating, recovery funnel by store and week |
| `claude.online_reviews` | 1 row per public review | Google / Yelp / Grubhub / Bing / Apple reviews and the store's public reply |

## Hard rules

1. **Never query `tattle.*` directly** for a business question. The raw tables keep the guest's typed name and phone in `_raw`, and one of the location ids is wrong (Tattle 110 = Brink 10). The views fix both.
2. **Always filter `business_date`.** Every view is partitioned on it underneath. It is the **experience date**, not the submission date.
3. **Say which rating you are quoting.** `avg_rating` over everything is a complaint-intake number (65% of rows are contact-form complaints). For "how are guests rating us", use `avg_experience_rating` from `guest_feedback_daily` or filter `feedback_type = 'experience survey'`, and remember those only exist from 2025-11-12.
4. **An incident is every survey rated 1-3.** Not a judgement, a rule (28,621 of 28,621). "Open incidents" = `incident_status = 'open'`. "Did the store reply" = `incident_messaged`. "Recovered" is Tattle's outcome and can be set without a reply; do not read it as "replied".
5. **Rates are computed after summing** (`countif(...) / count(*)`), never averaged across store rows.
6. **Never paste a list of guest emails into SQL.** Hash one address in the query (below). A list belongs in a `scratch` table, not in query text that sits in the job log for 180 days.
7. All datasets are read-only. Intermediate results go only to `marketing-data-442316.scratch`.

## Customer service recipes

**Everything one guest has told us** (hash the address in the query; the view holds only the hash). Since 2026-10-27 the same hash joins to `claude.order_customer.mapped_email_hash` and `claude.loyalty_user.email_hash`, so a feedback-to-orders or feedback-to-loyalty lookup never needs the address on either side. The address and the member's name themselves are in `claude_pii.order_customer` / `claude_pii.loyalty_user`, which only the customer-service grantee and the pipelines can read (`data_dictionaries/claude_pii.md`):

```sql
declare email string default 'guest@example.com';

select
gf.business_date
, gf.store_name
, gf.feedback_type
, gf.questionnaire
, gf.request_type
, gf.rating
, gf.comment
, gf.incident_status
, gf.incident_messaged_at_utc
, gf.brink_order_id
from `marketing-data-442316`.claude.guest_feedback gf
where 1=1
and gf.business_date >= date_sub(current_date('America/Denver'), interval 2 year)
and gf.email_hash = to_hex(sha256(lower(trim(email))))
order by gf.business_date desc
```

By phone: `gf.phone_hash = to_hex(sha256('1' || regexp_replace(phone, r'\D', '')))` (10 digits, country code added).

**The order behind a survey** (18% of surveys carry one, from the receipt QR code):

```sql
select
gf.survey_id
, gf.business_date
, gf.store_name
, gf.rating
, gf.comment
, oc.order_datetime_local
, oc.revenue_category
, oc.net_sales
, oc.mapped_cust_id
from `marketing-data-442316`.claude.guest_feedback gf
join `marketing-data-442316`.claude.order_customer oc
  on oc.brink_order_id = gf.brink_order_id
  and oc.business_date between date_sub(gf.business_date, interval 1 day) and date_add(gf.business_date, interval 1 day)
where 1=1
and gf.business_date >= '2026-10-01'
and gf.brink_order_id is not null
```

**Open complaints at a store this week** (what a rep or GM should work):

```sql
select
gf.business_date
, gf.created_at_local
, gf.feedback_type
, gf.request_type
, gf.rating
, gf.comment
, gf.has_email
, gf.has_phone
from `marketing-data-442316`.claude.guest_feedback gf
where 1=1
and gf.business_date >= date_sub(current_date('America/Denver'), interval 7 day)
and gf.store_id = 123
and gf.incident_status = 'open'
order by gf.created_at_local
```

**What the contact forms are about** (request mix over a window):

```sql
select
gf.questionnaire
, gf.request_type
, count(*) as surveys
, round(avg(gf.rating), 2) as avg_rating
, countif(gf.incident_messaged) as replied
from `marketing-data-442316`.claude.guest_feedback gf
where 1=1
and gf.business_date between '2026-09-01' and '2026-09-30'
and gf.feedback_type = 'contact form'
group by 1, 2
order by surveys desc
```

**Category ratings by store** (experience surveys):

```sql
select
gf.store_name
, sn.category
, count(*) as answers
, round(avg(sn.rating), 2) as avg_rating
, round(countif(sn.rating <= 2) / count(*), 3) as negative_share
from `marketing-data-442316`.claude.guest_feedback_snapshots sn
join `marketing-data-442316`.claude.guest_feedback gf
  on gf.survey_id = sn.survey_id
  and gf.business_date = sn.business_date
where 1=1
and sn.business_date between '2026-09-01' and '2026-09-30'
group by 1, 2
order by 1, 2
```

**Recovery funnel by week** (`guest_feedback_daily`, rates after summing):

```sql
select
d.week_ending
, sum(d.surveys) as surveys
, sum(d.incidents) as incidents
, round(sum(d.incidents_replied) / sum(d.incidents), 3) as reply_rate
, round(sum(d.incidents_recovered) / sum(d.incidents), 3) as recovery_rate
, round(avg(d.avg_experience_rating), 2) as avg_experience_rating_unweighted
from `marketing-data-442316`.claude.guest_feedback_daily d
where 1=1
and d.business_date >= '2026-07-01'
group by 1
order by 1
```

(Weighted experience rating needs the survey view: `avg(rating)` where `feedback_type = 'experience survey'`.)

**Unanswered negative public reviews**:

```sql
select
r.business_date
, r.store_name
, r.provider
, r.rating
, r.reviewer
, r.review_text
, r.url
from `marketing-data-442316`.claude.online_reviews r
where 1=1
and r.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
and r.is_negative
and not r.has_response
order by r.business_date desc
```

## Pre-query clarifications (ask only when the answer changes)

- **Which kind of feedback?** Experience surveys, contact forms, public reviews, or all. A "complaints" question usually means contact forms plus negative experience surveys; a "ratings" question means experience surveys.
- **Date basis.** `business_date` is the experience date; a "this week" count of submissions should use `created_at_local`.
- **Store.** `store_id` / `store_name` / `market` are Brink-based and match `claude.store_info`.

## Known gaps (log as `KB finding:` tasks, do not improvise)

- No guest identity beyond the hashes: a feedback-to-customer join goes through `brink_order_id` (18% of surveys) or by hashing `oc.mapped_email` on the order side for a one-off.
- `tattle.menu_level_feedback_daily` (per-item feedback) and `tattle.incident_reward_codes` are empty; item-level feedback is not available yet.
- Public review text is Google and Grubhub only.
- Tattle's "satisfied" rollup does not map to any survey-level timestamp exactly.
