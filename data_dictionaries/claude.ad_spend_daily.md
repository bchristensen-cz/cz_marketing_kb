# Data Dictionary: `marketing-data-442316.claude.ad_spend_daily`

**One row per platform / account / campaign / ad group / ad / asset group / day.** Union view
over the five `edi.*_daily` tables. Build script:
[`sql/claude.ad_spend_daily.sql`](../sql/claude.ad_spend_daily.sql). Deployed 2026-09-11.

This is the **only** approved surface for spend, impressions, clicks, CPM, CTR, CPA and ROAS
questions. Source-table detail and the full profiling record live in
[`edi.paid_media_sources.md`](edi.paid_media_sources.md).

## Why it exists

Five platforms, five different column vocabularies, no shared spend column type, and a set of
traps (`''` instead of NULL, a duplicated `all_conversions`, a "rate" column holding dollars)
that every analyst has had to rediscover. Before this view the cross-platform spend union was
being **hand-written per session** — four times in one analysis on 2026-09-10 alone — and paid
media was listed in the KB as "any spend / ROAS / channel-performance question is currently
unanswerable". Asana 1216803727477024.

## Columns

| Column | Type | Notes |
|---|---|---|
| `business_date` | DATE | **Partition column — always filter on it.** The platform's reporting date, in the ad account's own reporting timezone. It is *not* the Cafe Zupas business date and carries no fiscal-calendar meaning. |
| `date` | DATE | Identical alias of `business_date`, kept so existing `edi`-era SQL still runs. Never group by both. |
| `platform` | STRING | `facebook`, `google_ads`, `snapchat`, `spotify`, `tiktok`. The canonical channel key. |
| `datasource` | STRING | Passthrough of the source column; same values as `platform`. |
| `account_name` | STRING | Ad account. Facebook has two: `Cafe Zupas` ($617,220) and `Cafe Zupas Catering` ($6,871, 2026-02-06 → 2026-06-02). **Catering media is inside Facebook unless you exclude it.** |
| `objective` | STRING | Facebook `objective`, TikTok `objective_type`. **NULL on every google_ads, snapchat and spotify row** — Snapchat and Spotify never populate it upstream. |
| `campaign_type` | STRING | Google only: `PERFORMANCE_MAX`, `SEARCH`, `DEMAND_GEN`, `SMART`. NULL elsewhere. |
| `campaign` | STRING | Campaign name. 100 facebook / 136 google / 62 tiktok / 16 snapchat / 2 spotify. |
| `ad_group` | STRING | Ad group, or Spotify's `ad_set`. **NULL on Google PMax rows** (they have asset groups instead) — the source stores `''` there and the view normalises it. |
| `ad_name` | STRING | Ad / creative name. NULL on Google PMax rows. |
| `asset_group` | STRING | **Google PMax only** (16,956 rows, store-named). NULL on every other platform — the source stores `''`. |
| `spend` | NUMERIC | USD. Never NULL on any platform. |
| `impressions` | INT64 | Snapchat's `total_impressions` is mapped here. |
| `clicks` | INT64 | All clicks. |
| `link_clicks` | INT64 | **Facebook only.** 100% NULL on the other four. |
| `conversions` | NUMERIC | **Canonical purchase metric** — see below. Fractional on Google only. |
| `conversion_value` | NUMERIC | Platform-attributed revenue in USD. |
| `adds_to_cart` | INT64 | **Facebook and TikTok only.** NULL on google / snapchat / spotify. |
| `landing_page_views` | INT64 | **Facebook and TikTok only.** |

### The canonical conversion definition (steward, 2026-09-11)

`conversions` is each platform's **purchase / transaction** metric, and nothing else:

| Platform | Source column |
|---|---|
| facebook | `actions_purchase` |
| google_ads | `conversions` |
| snapchat | `transactions` |
| tiktok | `conversions` |
| spotify | `conversions` (always NULL — Spotify sends no conversion data) |

`conversion_value` is the matching value column, including TikTok's and Spotify's
**`total_complete_payment_rate`, which despite the name holds dollars, not a rate**
($459,890.76 against 16,908 TikTok conversions — $27.20 average).

**`all_conversions` / `all_conv_value` are deliberately not exposed.** They are byte-identical to
the purchase metric on 100% of facebook, snapchat and tiktok rows, and on Google they are a
different, ~6× larger metric that folds in store visits and calls. Carrying both would have made
cross-platform CPA a coin flip. If someone specifically needs Google's broader action set, that
is a `edi.google_ads_daily` question and must be labelled "Google all-conversions", never
"conversions".

## Verified on deploy (2026-09-11)

Row counts and all five measures tie out to the source tables **exactly** — zero difference on
every platform:

| Platform | Rows | Spend |
|---|---|---|
| facebook | 21,761 | $624,090.81 |
| google_ads | 19,362 | $422,365.87 |
| tiktok | 10,673 | $220,013.02 |
| snapchat | 3,273 | $69,735.51 |
| spotify | 44 | $8,131.66 |
| **total** | **55,113** | **$1,344,337.87** |

Partition pruning survives the union — a 10-day filter on `business_date` bills **61 KB** against
**1.76 MB** unfiltered (29×). The filter works; write it.

## Gotchas

Full detail with measurements is in [`edi.paid_media_sources.md`](edi.paid_media_sources.md).
The four that change answers most often:

1. **🚨 2024 is missing large stretches.** Facebook has zero rows 2024-04-11 → 2024-08-31;
   Google zero 2024-04-10 → 2024-11-30; TikTok zero across May–June 2024; Snapchat starts
   2025-11-13. These are backfill gaps, not dark periods. **Any YoY against 2024 is wrong.**
   First month with all four continuing platforms present: **2026-01**.
2. **🚨 TikTok conversions mature over ~a week** — 52.6% visible one day after the date, 88.0%
   by day 7 and still rising; spend is final immediately. Don't quote TikTok CPA or ROAS on a
   window ending within 3 days, and state the as-of date, because `tiktok_daily` restates in
   place. Other platforms' restatement behaviour is unmeasured.
3. **Never filter `where spend > 0`.** 1,211 Facebook rows have zero spend, impressions and
   clicks but carry real late-attributed conversions and revenue. The filter deletes them
   silently.
4. **No store key exists.** Nothing here joins to `store_id` / `store_state`. Store-level media
   numbers come from parsing Google PMax `asset_group` (store-named) or campaign names, and must
   be labelled as a name match, not a join.

Also worth knowing: `conversion_value` is **platform self-attributed**, measured by each
platform's own pixel with its own lookback window. It double counts across platforms and does not
reconcile to `claude.order_customer.net_sales`. Present it as "platform-reported", never as
incremental revenue, and never add it across platforms and compare to Brink sales.

## Standard patterns

Spend and efficiency by platform for a window:

```sql
select
v.platform as platform
, round(sum(v.spend), 2) as spend
, sum(v.impressions) as impressions
, sum(v.clicks) as clicks
, round(sum(v.conversions), 1) as conversions
, round(safe_divide(sum(v.spend), sum(v.impressions)) * 1000, 2) as cpm
, round(safe_divide(sum(v.clicks), sum(v.impressions)) * 100, 2) as ctr_pct
, round(safe_divide(sum(v.spend), sum(v.conversions)), 2) as cpa
, round(safe_divide(sum(v.conversion_value), sum(v.spend)), 2) as roas
from `marketing-data-442316`.claude.ad_spend_daily v
where 1=1
and v.business_date between @start and @end
group by v.platform
order by spend desc
```

Google PMax by store (name match, not a join — label it as such):

```sql
select
v.asset_group as store_asset_group
, round(sum(v.spend), 2) as spend
, round(sum(v.conversions), 1) as conversions
from `marketing-data-442316`.claude.ad_spend_daily v
where 1=1
and v.business_date between @start and @end
and v.platform = 'google_ads'
and v.campaign_type = 'PERFORMANCE_MAX'
and v.asset_group is not null
group by v.asset_group
order by spend desc
```

Excluding catering media:

```sql
where 1=1
and v.business_date between @start and @end
and v.account_name <> 'Cafe Zupas Catering'
```
