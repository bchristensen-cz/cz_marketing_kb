# Data Dictionary: `marketing-data-442316.edi.*` — paid media sources (windsor.ai)

**Steward-facing.** Standard users query [`claude.ad_spend_daily`](claude.ad_spend_daily.md)
and [`claude.ad_reach_weekly`](claude.ad_reach_weekly.md) instead — this file documents the
13 source tables those views sit on, and the traps the views normalise away.

Profiled end to end 2026-09-11. Every figure below was measured, not estimated.

## The pipeline

windsor.ai → `staging.edi_*` (full-refresh) → `edi.*` (scheduled query, **daily 04:01–04:02 MT**,
verified from `create_timestamp` on the TikTok snapshot table). The load deletes by observed key
set rather than by date window — see the "restate by observed key set" pattern in
`claude_skills/sales-ops-orders/SKILL.md`.

There is **no row in `etl_metadata.watermark` for edi** — that table only covers the MySQL
connections. Freshness is checked on `max(create_timestamp)` in
`edi.tiktok_daily_snapshot_history`, or on `max(date)` in any daily table.

## The 13 tables

### Daily fact tables — one per platform

| Table | Rows | Coverage | Days w/ rows | Campaigns | Accounts | Total spend |
|---|---|---|---|---|---|---|
| `facebook_daily` | 21,761 | 2024-01-01 → 2026-09-10 | 833 | 100 | `Cafe Zupas`, `Cafe Zupas Catering` | $624,090.81 |
| `google_ads_daily` | 19,362 | 2024-01-01 → 2026-09-10 | 652 | 136 | `Cafe Zupas` | $422,365.87 |
| `tiktok_daily` | 10,673 | 2024-01-01 → 2026-09-10 | 828 | 62 | `CZ Ads` | $220,013.02 |
| `snapchat_daily` | 3,273 | 2025-11-13 → 2026-09-10 | 288 | 16 | `Cafe Zupas Self Service` | $69,735.51 |
| `spotify_daily` | 44 | 2026-03-21 → 2026-05-27 | 44 | 2 | `Cafe Zupas` | $8,131.66 |

All five: partitioned on `date`, clustered on `datasource, account_name, campaign, ad_group_name`
(`ad_set` on Spotify). `datasource` is a **constant per table** (`facebook`, `google_ads`,
`snapchat`, `spotify`, `tiktok`) — it is the platform key, not a varying dimension.

**Grain is one row per (date, datasource, account_name, campaign, ad_group, ad_name, asset_group)**
— verified unique on all five tables with zero collisions. Dropping `ad_name` collapses
facebook 21,761 → 6,019 and tiktok 10,673 → 2,709, so the ad name is load-bearing.

### Weekly reach tables

| Table | Rows | Coverage | Weeks |
|---|---|---|---|
| `facebook_weekly_reach_campaign` | 647 | 2023-12-31 → 2026-09-06 | 119 |
| `facebook_weekly_reach_ad_set` | 1,005 | 2023-12-31 → 2026-09-06 | 119 |
| `tiktok_weekly_reach_campaign` | 286 | 2024-01-14 → 2026-09-06 | 115 |
| `tiktok_weekly_reach_ad_set` | 342 | 2024-01-14 → 2026-09-06 | 115 |
| `snapchat_weekly_reach_campaign` | 111 | 2025-11-09 → 2026-09-06 | 43 |
| `snapchat_weekly_reach_ad_set` | 192 | 2025-11-09 → 2026-09-06 | 43 |

Partitioned on `reach_week`. The measure column is named `campaign_reach` **on the ad-set tables
too** — it holds ad-set reach there, not campaign reach. **There is no Google Ads or Spotify
reach table.**

### Supporting tables

- **`tiktok_daily_snapshot_history`** — 18,899 rows, 2026-06-10 → 2026-09-10. `tiktok_daily`
  plus a `create_timestamp`, one snapshot per daily load, ~7 snapshots retained per date. This
  is a **restatement audit log, not a fact table.** Unioning it with `tiktok_daily` multiplies
  TikTok spend by ~7. See gotcha 2.
- **`reach_rel_date`** — a generated Sunday spine (`reach_week` DATE, `reach_year_week` STRING
  `'YYYY|WW'`) running out to 2057. Joins 1:1 to every reach table; carried into
  `claude.ad_reach_weekly` as `reach_year_week`.

## Column vocabulary — what actually differs per platform

The KB previously described a single shared vocabulary. It is not shared. Verified names:

| Concept | facebook | google_ads | snapchat | spotify | tiktok |
|---|---|---|---|---|---|
| date | `date` | `date` | `date` | `date` | `date` |
| ad group | `ad_group_name` | `ad_group_name` | `ad_group_name` | **`ad_set`** | `ad_group_name` |
| objective | `objective` | **`campaign_type`** | `objective` (100% NULL) | `objective_type` INT64 (100% NULL) | `objective_type` |
| impressions | `impressions` | `impressions` | **`total_impressions`** | `impressions` | `impressions` |
| conversions | **`actions_purchase`** | `conversions` | **`transactions`** | `conversions` (100% NULL) | `conversions` |
| conv. value | **`action_values_omni_purchase`** | `conversion_value` | **`transactionrevenue`** | `total_complete_payment_rate` (NULL) | **`total_complete_payment_rate`** |
| add to cart | `actions_add_to_cart` | `adds_to_cart` (NULL) | `adds_to_cart` (NULL) | `web_event_add_to_cart` (NULL) | `web_event_add_to_cart` |
| LP view | `actions_landing_page_view` | `landing_page_view` (NULL) | `landing_page_view` (NULL) | `total_landing_page_view` (NULL) | `total_landing_page_view` |

`spend` **is** universal — there is no `cost` column anywhere in `edi`.

### ⚠️ Correction to the 2026-09-10 note in `sales-ops-orders/SKILL.md`

That note records "`spend` is stored as a **STRING** (every arm is `cast(spend as float64)`)".
**Re-verified 2026-09-11 against `INFORMATION_SCHEMA.COLUMNS`: `spend` is `BIGNUMERIC` in all
five `edi.*_daily` tables and in `staging.edi_*`.** The cast is harmless but unnecessary. Types
across the daily tables: `spend`, `impressions`, `clicks` are `BIGNUMERIC` everywhere;
`link_clicks` / `adds_to_cart` / `landing_page_view` are `INT64` on google/snapchat/spotify and
`BIGNUMERIC` on facebook/tiktok — which is why a hand-rolled `union all` needs explicit casts.

Only Google's `conversions` is ever **fractional** (5,176 rows carry decimals — Google's
fractional attribution). Impressions, clicks, link clicks, adds to cart and landing page views
are whole numbers on every platform, so `claude.ad_spend_daily` types them `INT64`.

## Gotchas

### 1. 🚨 2024 is full of holes — do not run YoY against it

Measured by generating a date spine and left-joining each table:

| Platform | Missing stretch | Missing days in span |
|---|---|---|
| facebook | **2024-04-11 → 2024-08-31** (~5 months, zero rows) | 151 |
| google_ads | **2024-04-10 → 2024-11-30** (~8 months, zero rows) | 332 |
| tiktok | 2024-05 → 2024-06 zero; 2024-04 has 1 day | 156 |
| snapchat | starts 2025-11-13 — nothing earlier exists | 14 |
| spotify | 44 days only, 2026-03-21 → 2026-05-27 | — |

Facebook was Cafe Zupas's largest channel through 2024; five months of literally zero spend rows
is a **windsor.ai backfill limit, not a dark period**. Treat every one of these as missing data.
**The first month with all four continuing platforms present is 2026-01.** State the window on
any answer that reaches before it.

### 2. 🚨 TikTok conversions keep growing for a week — spend does not

From `tiktok_daily_snapshot_history`, 76–82 dates per lag, 2026-06-10 → 2026-08-31:

| Days after the date | Conversions visible, as % of the day-7 value |
|---|---|
| 1 | **52.6%** |
| 2 | 82.3% |
| 3 | 84.6% |
| 4 | 87.0% |
| 7 | **88.0%** — and still climbing when the snapshot window ends |

Spend, by contrast, is final on first capture: **$0.09 of drift across 93 days**, restated on
2 dates out of 93. Conversions were restated on **83 of 93**.

Two consequences. **(a)** TikTok CPA / ROAS for the last three days is materially overstated and
understated respectively — quote TikTok efficiency on a window ending at least 3 days ago, and
say so. **(b)** `tiktok_daily` is **restated in place**, so the same query run Monday and Friday
returns different TikTok conversions for the same past dates. That is the data behaving
correctly; it still breaks "same question, same answer" unless the as-of date is stated.

No equivalent snapshot table exists for the other four platforms, so their restatement behaviour
is **unmeasured** — do not assume they are stable.

### 3. `all_conversions` is a duplicate column on four of the five platforms

`all_conversions` equals the platform purchase metric on **100% of rows** on facebook (21,761/21,761),
snapchat (3,273/3,273) and tiktok (10,673/10,673); same for `all_conv_value`. On **Google it is a
different metric entirely** — 890 of 19,362 rows agree:

| Google metric | Total |
|---|---|
| `conversions` | 270,578.93 |
| `all_conversions` | **1,664,092.52** (6.1×) |
| `conversion_value` | $6,384,835.10 |
| `all_conv_value` | **$13,402,484.38** |

`all_conversions` on Google folds in store visits, calls and other non-primary actions. Mixing it
into a cross-platform CPA makes Google look ~6× more efficient than it is. **`claude.ad_spend_daily`
deliberately does not expose it** (steward decision 2026-09-11).

### 4. Empty string, not NULL — `is null` finds nothing

| Column | Behaviour |
|---|---|
| `asset_group_name` | `''` on **100%** of facebook / snapchat / tiktok rows, and on Google's 2,406 non-PMax rows. NULL only on spotify (INT64, all NULL). |
| `ad_group_name`, `ad_name` | `''` on Google's **16,956 PMax rows** — PMax has asset groups, not ad groups. Also NULL (genuinely) on 55 Google rows and 80 snapchat `ad_name` rows. |

So `where ad_group_name is null` returns 55 Google rows and misses 16,956. `claude.ad_spend_daily`
applies `nullif(x, '')` so `is null` behaves.

### 5. Zero-delivery rows carry real conversions — `where spend > 0` drops them

| Platform | Rows with spend = impressions = clicks = 0 | …of which carry conversions |
|---|---|---|
| facebook | 2,633 (12.1%) | **1,211** |
| tiktok | 3,920 (36.7%) | 1 |
| google / snapchat / spotify | 0 | 0 |

The 1,211 Facebook rows are late-attributed conversions landing on an ad that served nothing that
day. Filtering `spend > 0` silently deletes them. Filter on the dimension you mean
(`campaign`, date range), not on spend.

A milder version: 315 facebook / 336 tiktok / 435 google rows have zero spend **with** impressions
(delivery credited to an adjacent day, or free placements). There are **zero** rows anywhere with
spend but no impressions. Three Google rows have `clicks > impressions`.

### 6. Reach is not additive, at any level

Ad-set reach summed to the campaign exceeds campaign reach on **159 of 647** facebook
campaign-weeks, **19 of 286** tiktok, **38 of 111** snapchat; it is equal only where the campaign
has a single ad set. Totals: facebook 56,248,999 (ad set) vs 54,454,219 (campaign).

Reach is deduplicated **within one (platform, campaign, reach_week)** and nowhere else. Summing
across campaigns, across weeks, or across `reach_level` counts the same person many times. There
is no de-duplicated total-audience number in this dataset.

### 7. Reach weeks start Sunday; the CZ business week is Mon–Sat

`reach_week` is a **Sunday** on 100% of rows in all six tables. It does not align with the Cafe
Zupas Mon–Sat business week, nor with `claude.date_dim.week_ending`. Never join reach weeks to a
sales week without saying they are offset.

### 8. There is no store key anywhere in `edi` — and media is not reported by store

No `store_id`, no `store_state`, nothing that joins to `store_info` or the order marts.
**Steward decision 2026-09-11: that is fine — media is not reported by store**, and a
campaign↔store mapping is explicitly not on the roadmap. Paid media is answered at chain,
platform, campaign and ad level.

Recorded here only so nobody mistakes a city in a name for a location dimension:

- **Google PMax asset groups are store-named** and are the cleanest handle — `Greenfield`,
  `McKinney`, `Las Vegas`, `AG-SCHAUMBURG`, `AG-COON_RAPIDS`. Two naming eras: `AG-CITY_NAME`
  (2024-12 → 2025-11) and plain city names (2026-02 →).
- Google **campaign** names also carry them — `C7 | PMAX | (155) Greenfield, WI | G1` embeds the
  store number; `PMAX-IL-VERNON_HILLS` does not.
- Facebook / TikTok / Snapchat campaign and ad-group names are **not** consistently store-named.

These names are **campaign structure, not geography.** A name-matched "by store" number would
cover only the fraction of spend whose campaigns happen to be named after a city and would read
as a complete breakdown — which is why the 2026-09-10 new-store analysis had to hand-roll an
ad-group regex. Don't repeat it: answer by campaign or by asset group, and call it that.

## Platform-level benchmarks (whole history, as of 2026-09-11)

Sanity anchors only — these are **platform self-reported, self-attributed** figures, not Brink
net sales. Never present `conversion_value` as incremental revenue.

| Platform | CPM | CTR | CPA | ROAS |
|---|---|---|---|---|
| facebook | $5.07 | 0.50% | $4.33 | 5.97 |
| google_ads | $12.05 | 2.10% | $1.56 | 15.12 |
| snapchat | $3.40 | 0.19% | $3.53 | 10.39 |
| tiktok | $4.99 | 0.42% | $13.01 | 2.09 |
| spotify | $6.27 | 0.04% | — | — (no conversion data) |

Google's CPA/ROAS is flattered by PMax counting in-store/local actions even in the narrow
`conversions` column. TikTok's is depressed by the maturation lag in gotcha 2.

## Objective / campaign type values

| Platform | Field | Values (by spend) |
|---|---|---|
| facebook | `objective` | `OUTCOME_SALES` $435k, `OUTCOME_AWARENESS` $138k, `OUTCOME_ENGAGEMENT` $32k, `OUTCOME_LEADS` $13k, `LINK_CLICKS` $6k, plus `APP_INSTALLS` / `CONVERSIONS` / `POST_ENGAGEMENT` residue |
| google_ads | `campaign_type` | `PERFORMANCE_MAX` $359k, `SEARCH` $61k, `DEMAND_GEN` $2.3k, `SMART` $475 |
| tiktok | `objective_type` | `WEB_CONVERSIONS` $134k, `VIDEO_VIEWS` $47k, `REACH` $19k, `TRAFFIC` $13k, `LEAD_GENERATION` $6k, `ENGAGEMENT` $941 |
| snapchat | `objective` | **100% NULL** |
| spotify | `objective_type` | **100% NULL** (INT64) |
