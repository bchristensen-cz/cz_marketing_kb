# Data Dictionary: `marketing-data-442316.claude.guest_feedback*` and `claude.online_reviews`

Five authorized views over the `tattle` dataset (Tattle, the guest-feedback platform).
Build script: [`sql/claude.guest_feedback.sql`](../sql/claude.guest_feedback.sql). Deployed
2026-10-20 (replaces the undocumented `guest_feedback` / `guest_feedback_snapshots` views of
2026-10-09). Skill: `claude_skills/guest-feedback/`.

| View | Grain | Rows (2026-10-20) | History |
|---|---|---|---|
| `claude.guest_feedback` | 1 row per Tattle survey | 35,609 | 2024-04-23 onward |
| `claude.guest_feedback_snapshots` | 1 row per survey x category | 48,927 | 2025-11-12 onward (experience surveys only) |
| `claude.guest_feedback_answers` | 1 row per survey x question (PII questions removed) | 89,526 | 2024-04-23 onward |
| `claude.guest_feedback_daily` | 1 row per store x business_date | 24,749 | 2024-04-23 onward |
| `claude.online_reviews` | 1 row per public review | 27,864 | 2024-05-01 onward |

All five are partitioned on `business_date` underneath. **Always filter `business_date`.**
Store 1111 / 999 rows are excluded in the definitions. The Tattle loader runs nightly at
about 05:10 MT (`tattle.load_runs`: `nightly-core` reloads the last 3 days of surveys and
incidents, `nightly-reviews` the last 7 days of reviews, `nightly-aggregates` 14 days of
location metrics), so a survey submitted today appears tomorrow morning.

## What Tattle holds, in one paragraph

One `surveys` table carries two different things. **Experience surveys** (`feedback_type =
'experience survey'`, `snapshot_count > 0`) are the post-order Pick-up / Dine-in / Drive-Thru /
Delivery Experience questionnaires that started 2025-11, with a 1-5 rating per category
(Food Quality, Accuracy, Speed of Service, Hospitality, Online Ordering, plus Atmosphere and
Cleanliness for dine-in, Meal Packaging for delivery) and a free-text comment per category.
**Contact forms** (`feedback_type = 'contact form'`, `snapshot_count = 0`) are the
cafezupas.com/talk forms: Loyalty & App, Other Feedback, Menu & Nutrition, Catering Orders,
Catering Rewards & App, and the retired Experience Feedback form (2024-04 to 2026-06-02).
A contact form has a multiple-choice `request_type` and a free-text `comment`. Contact
forms are complaint intake, so the overall rating distribution is 1: 51%, 2: 14%, 3: 15%,
4: 7%, 5: 13% and **the average rating is not a satisfaction score**. Every survey rated
1-3 opens an **incident** (28,621 of 28,621 rated 1-3; 0 of 6,988 rated 4-5), which is
Tattle's guest-recovery workflow: a manager sees it, replies, and Tattle records recovery.

## `claude.guest_feedback` columns

| Column | Type | Notes |
|---|---|---|
| `survey_id` | INT64 | Tattle survey id, unique |
| `business_date` | DATE | **The experience date** (local), from `experience_at_local`, not the submission date. Partition column |
| `week_ending` | DATE | Sunday, from `date_dim` |
| `store_id` | INT64 | Brink store id. Tattle's id 110 (Valley Fair) is remapped to Brink 10 in the view; see gotchas. Never NULL as of 2026-10-20 |
| `store_name`, `market`, `is_comp_store` | | From `store_info`; `market` = `store_state` (full state name) |
| `tattle_location_id` | INT64 | Tattle's own location id |
| `feedback_type` | STRING | `'experience survey'` or `'contact form'` (see above) |
| `questionnaire` | STRING | Form title: Pick-up Experience, Dine-in Experience, Drive-Thru Experience, Delivery Experience, Loyalty & App, Other Feedback, Menu & Nutrition, Catering Orders, Catering Rewards & App, Experience Feedback (retired) |
| `channel` | STRING | Tattle channel of the experience survey: Take-Out, Dine-In, Drive-Thru, Delivery. NULL on contact forms |
| `request_type` | STRING | Contact-form choice. Loyalty & App / Catering Rewards & App: Points, Other/Questions, Managing your account, Coupons/Offers, Points & CZ Dollars, Redeeming; Other Feedback / Experience Feedback: I had an unsatisfactory experience., I have a question., I have a suggestion., I had a great experience!; Menu & Nutrition: Menu, Nutrition, Ingredients, Allergens, Other; Catering Orders: Recent Order, Catering Quote, Questions, Concerns, Other. NULL on experience surveys |
| `experience_type` | STRING | Retired Experience Feedback form only: Online Order, In-person for to-go, In-person for Dine In, Delivery, Curbside |
| `referral_source` | STRING | `'brink'` when the survey came from the receipt QR code (6,390 rows, these carry `order_id`); otherwise NULL |
| `delivery_partner` | STRING | NULL on every row so far |
| `order_id` | STRING | Tattle's string, `'<brink_order_id>-<brink_order_id>'` |
| `brink_order_id` | INT64 | Parsed from `order_id`. **Joins 100% to `claude.order_customer.brink_order_id`** (99.9% on the same `business_date`, 99.3% on the same store); 18% of surveys have one |
| `order_number_entered` | STRING | What the guest typed into "What is your order number?" on a contact form. Free text: receipt numbers, Pulse order numbers, "N/A", sentences. Useful to a rep, never a join key |
| `created_at_utc` | TIMESTAMP | Submission instant |
| `created_at_local` | DATETIME | Submission in the store's IANA timezone (`America/Denver` when the store is unknown) |
| `experience_at_local` | DATETIME | When the guest said the experience happened (local) |
| `rating` | INT64 | 1-5 overall. On an experience survey it is Tattle's roll-up of the category ratings; on a contact form the guest picks it |
| `score` | INT64 | Tattle's 0-100 score. Contact forms map 1-5 to 0/25/50/75/100; experience surveys carry Tattle's weighted score |
| `is_negative` | BOOL | `rating <= 2` |
| `flagged` | BOOL | Tattle flag (165 rows) |
| `comment` | STRING | The free-text answer ("Tell us more!" on contact forms, "Please share any other feedback..." on experience surveys). Present on 85% of rows. **May contain anything the guest typed, including their own name or phone** |
| `snapshot_count`, `question_count` | INT64 | How many category rows / question rows the survey has |
| `email_hash`, `phone_hash` | STRING | SHA-256 hex. `email_hash = to_hex(sha256(lower(trim(email))))`, verified on 6,368 of 6,368 order-joined rows. `phone_hash = to_hex(sha256('1' || <10 digits>))`, verified on 610 of 623 (the rest are formatting cases). Never NULL for email; `has_phone` says whether the phone hash is real |
| `has_email`, `has_phone` | BOOL | Whether the guest left one |
| `incident_id`, `has_incident` | | Incident opened for the survey (every rating 1-3) |
| `incident_status` | STRING | Derived, highest stage reached: `recovered` > `resolved` > `replied` > `seen` > `open`; NULL when no incident (rating 4-5) |
| `incident_reviewed` / `_messaged` / `_resolved` / `_recovered` | BOOL | The four Tattle stage flags |
| `incident_*_at_utc` | TIMESTAMP | The four Tattle stage timestamps |
| `hours_to_reply` | INT64 | `messaged_at - created_at` in hours. Quartiles over all history: 0 / 41 / 137 / 697 hours, so quote the median, not the mean |
| `reward_code_count` | INT64 | Reward codes attached to the incident; 0 on every row so far (`tattle.incident_reward_codes` is empty) |

### The incident stages, as measured against Tattle's own rollup

`tattle.location_metrics_daily` is Tattle's per-location per-day funnel. Over all history the
survey-level timestamps reproduce it: `reviewed_at` = Tattle "seen" (25,912 vs 25,850),
`messaged_at` = Tattle "replied" (25,698 vs 25,694), `recovered_at` = Tattle "recovered"
(14,552 vs 14,542). `resolved_at` (3,117) is close to but not the same as Tattle
"satisfied" (2,154). Incident counts agree on 99.4% of store-days (20,557 of 20,685); the
mart holds 83 more incidents than the rollup, so a tie-out to Tattle's dashboard will be
within 0.3%. **`recovered_at` is set on 515 incidents that were never messaged**, so
"recovered" is Tattle's own outcome, not a reply flag; use `incident_messaged` for "did
the store reply".

## `claude.guest_feedback_snapshots`

One row per survey x category for experience surveys. `category` is Food Quality, Speed of
Service, Accuracy (every survey), Hospitality (most), Online Ordering (pick-up and
delivery), Atmosphere and Cleanliness (dine-in), Meal Packaging (delivery). `rating` 1-5,
`comment` is the category's free text (67% filled), `reasons` is an array of
`(reason_id, label, impact)` where `impact` is Tattle's sign (-1 / 0 / +1) and `reason_labels`
is the same as a string, e.g. `Value (-)`. Reason labels are one per category (Value,
Complete Order, Efficiency, Friendliness, Order Process, Dining Room, Restaurant Ambiance,
Presentation), so the signal is in `impact` and `rating`, not the label. Average category
ratings over all history: Accuracy 2.36, Food Quality 2.51, Speed of Service 3.07,
Atmosphere 3.09, Meal Packaging 3.19, Hospitality 3.22, Cleanliness 3.38, Online Ordering 3.57.

## `claude.guest_feedback_answers`

One row per survey x question, in Tattle order (`seq`). `is_choice` marks multiple-choice
answers (`answer_id` present); the rest are free text. **Rows whose question asks for name
or phone are removed entirely** (Tattle's `answer_is_pii`), which is why a contact form with
`question_count = 5` shows 3 rows here. Use it when the survey row's `request_type` /
`comment` / `order_number_entered` are not enough.

## `claude.guest_feedback_daily`

Store x day roll-up of the survey view: `surveys`, `experience_surveys`, `contact_forms`,
`avg_rating`, `avg_experience_rating` (experience surveys only, the one worth trending),
`negative_surveys` (<= 2), `positive_surveys` (>= 4), `incidents`, `incidents_seen` /
`_replied` / `_resolved` / `_recovered`, `avg_hours_to_reply`. Sums tie to the survey view
exactly (35,609 / 28,621 / 25,698 / 14,552). Rates are computed after summing, never
averaged across rows.

## `claude.online_reviews`

Public reviews Tattle aggregates: GOOGLE 22,486, YELP 3,124, GRUBHUB 1,761, BING 260,
APPLE 233 (through 2026-02). `rating` is FLOAT 1-5. `review_text` is present on Google and
Grubhub only (Yelp, Bing and Apple arrive without text). `reviewer` is the public display
name. `response_count` / `has_response` / `response_text` / `response_status` /
`responded_at_utc` carry the store's public reply (the latest `Published` one; a review can
have up to 57 response rows, which are reply threads). 55% of reviews have a reply; 61% of
Google reviews. `business_date` is the review date in UTC.

## Gotchas

- **Rating is not satisfaction.** 65% of rows are contact-form complaints. Trend
  `avg_experience_rating` (experience surveys) or a category rating; say which.
- **Experience surveys only exist from 2025-11-12.** A rating trend across 2025 mixes the
  retired Experience Feedback contact form (complaints) with the new surveys.
- **`business_date` is the experience date.** A guest who submits on Monday about Saturday
  lands on Saturday. Recovery timing uses `created_at_utc`.
- **Store 110 is Valley Fair's Tattle id; Brink is 10.** Remapped in every view. Until the
  loader is fixed (`tattle.locations.store_id`), a query on `tattle.*` directly must do the
  same or 248 surveys lose their store name.
- **The raw tables carry PII.** `tattle.surveys._raw` and `tattle.incidents._raw` keep the
  guest's typed name and phone inside `questions[].answerText`, and `survey_questions`
  keeps the rows (with `answer_text` nulled). The views never expose `_raw`; do not read it
  to answer a question. Free-text `comment` fields can still contain whatever the guest
  typed.
- **Looking a guest up means hashing in the query.** There is no email column. See the
  skill for the two-line pattern.
- **`delivery_partner`, `reward_code_count`, `tattle.menu_level_feedback_daily`,
  `tattle.incident_reward_codes`** are empty or constant so far; not worth a column in a
  report.
- **Order join window.** `brink_order_id` is unique only with `business_date`; join
  `claude.order_customer` with `oc.business_date between gf.business_date - 1 and
  gf.business_date + 1` (99.9% land on the same date, the rest the day after).
