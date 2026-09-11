---
name: paid-media
description: How to answer paid-media questions — spend, impressions, clicks, CPM, CTR, CPA, ROAS and reach across Facebook/Meta, Google Ads, TikTok, Snapchat and Spotify — using claude.ad_spend_daily and claude.ad_reach_weekly. Use whenever a question says spend, media, ads, advertising, campaign performance, channel, CPM, CPC, CTR, CPA, ROAS, reach, frequency, impressions, PMax, or names an ad platform. Owns the 2024 coverage gaps, the TikTok conversion-maturation lag, the platform-attribution wall, and the reach non-additivity rule.
---

# Paid media (`claude.ad_spend_daily`, `claude.ad_reach_weekly`)

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

> **🆕 New 2026-09-11.** The `edi` dataset had been live since 2024 with **zero** documentation —
> "any spend / ROAS / channel-performance question is currently unanswerable from the KB" was the
> standing note in `sales-ops-orders`. Two views now cover it. Asana 1216803727477024.

Project: `marketing-data-442316`. Two approved views, fixed aliases **`ads`** and **`rch`**:

| View | Grain | Use for |
|---|---|---|
| `claude.ad_spend_daily` | 1 row per platform / account / campaign / ad group / ad / asset group / **day** | Spend, impressions, clicks, conversions, conversion value, CPM, CTR, CPC, CPA, ROAS |
| `claude.ad_reach_weekly` | 1 row per platform / campaign / reach level / **week** | Reach — facebook, snapchat, tiktok only |

Column docs, with every figure measured: [`claude.ad_spend_daily.md`](../../data_dictionaries/claude.ad_spend_daily.md),
[`claude.ad_reach_weekly.md`](../../data_dictionaries/claude.ad_reach_weekly.md), and the source
profile [`edi.paid_media_sources.md`](../../data_dictionaries/edi.paid_media_sources.md).
**Read the dictionary before writing anything non-trivial.**

The underlying `edi.*` tables are **steward-only**, like `sales_ops.*`. Business media questions
run on the two `claude` views.

## Hard rules

1. **Always filter `business_date`** (or `reach_week`). Both views pass partition pruning through
   to the source tables — verified 29× cheaper on a 10-day window. A missing filter scans
   everything.
2. **🚨 Never compare to 2024 without checking coverage.** Facebook has **zero rows**
   2024-04-11 → 2024-08-31, Google Ads **zero** 2024-04-10 → 2024-11-30, TikTok zero across
   May–June 2024, Snapchat begins 2025-11-13, Spotify exists for 44 days only. These are
   windsor.ai backfill gaps, not paused campaigns. **The first month with all four continuing
   platforms present is 2026-01.** Any YoY that reaches into 2024 must either be refused or
   stated as "platform X has no data for N of these months".
3. **🚨 TikTok conversions are not final for about a week.** 52.6% of a day's eventual
   conversions are visible one day later, 82.3% after two, 88.0% after seven and still climbing.
   Spend is final immediately. So: don't quote TikTok CPA or ROAS on a window ending within the
   last 3 days, and say what date the numbers were pulled — `tiktok_daily` restates in place, so
   the same query returns different TikTok conversions a week later. The other four platforms
   have no snapshot table, so their restatement behaviour is **unmeasured — don't assume it's
   zero**.
4. **`conversions` means the platform's purchase metric, always.** facebook `actions_purchase`,
   google `conversions`, snapchat `transactions`, tiktok `conversions`. `all_conversions` is not
   exposed: it duplicates the purchase metric on 100% of facebook/snapchat/tiktok rows, and on
   Google it is a ~6× larger figure including store visits and calls. Never mix the two in one
   comparison.
5. **🧱 Conversion value is platform-attributed, not revenue.** Each platform measures it with its
   own pixel and its own lookback, they double count each other, and none of it reconciles to
   `claude.order_customer.net_sales`. Always label it "platform-reported". **Never add
   `conversion_value` across platforms and compare it to Brink sales**, and never call any of it
   incremental.
6. **Never filter `where spend > 0`.** 1,211 Facebook rows have zero spend, impressions and clicks
   but carry genuine late-attributed conversions and revenue. Filter on dates and dimensions.
7. **Reach is not additive** — not across campaigns, not across weeks, not across `reach_level`.
   See the reach section below.
8. **There is no store key in this data.** Nothing joins to `store_id` or `store_state`.

## Which platform label to use

`platform` values are `facebook`, `google_ads`, `snapchat`, `spotify`, `tiktok`. Users say "Meta"
and "Facebook" for the same thing — both mean `platform = 'facebook'`. Resolve the term out loud
in the answer.

**Catering media hides inside Facebook.** `account_name = 'Cafe Zupas Catering'` carries $6,871
across 2026-02-06 → 2026-06-02; everything else on Facebook is `Cafe Zupas`. Unlike the order
marts there is **no `is_catering` flag** — if the question is about core (non-catering) media,
exclude that account and say you did.

## Structure differs by platform — don't write one shape for all five

| | facebook | google_ads | snapchat | spotify | tiktok |
|---|---|---|---|---|---|
| `objective` | ✅ | — (`campaign_type` instead) | always NULL | always NULL | ✅ |
| `ad_group` | ✅ | ✅ except PMax | ✅ | ✅ (`ad_set` upstream) | ✅ |
| `asset_group` | — | ✅ PMax only | — | — | — |
| `link_clicks` | ✅ | — | — | — | — |
| `adds_to_cart`, `landing_page_views` | ✅ | — | — | — | ✅ |
| `conversions`, `conversion_value` | ✅ | ✅ | ✅ | — | ✅ |

**Google Performance Max is 85% of Google rows and $359k of $422k spend.** On PMax rows
`ad_group` and `ad_name` are NULL and `asset_group` carries the structure. A "by ad group"
breakdown of Google therefore drops almost all of it — use `asset_group` for PMax, or group by
`coalesce(ads.ad_group, ads.asset_group)` and say which is which.

**Spotify carries spend, impressions and clicks only** — no conversions at all. It cannot appear
in a CPA or ROAS comparison; show it in spend/CPM tables and note the exclusion.

## Store and market questions — regex, not a join

There is no store key. Google PMax **asset groups are store-named** and are the cleanest handle
(`Greenfield`, `McKinney`, `Las Vegas`; older era `AG-SCHAUMBURG`, `AG-COON_RAPIDS`). Google
campaign names sometimes embed the store number (`C7 | PMAX | (155) Greenfield, WI | G1`).
Facebook, TikTok and Snapchat names are **not** consistently store-named.

So any store-level or market-level media number is a **name match**, and the answer must say so:
"matched by asset-group name; campaigns without a store in the name are excluded, $X of $Y total
spend covered". Never present it as a clean store rollup. A real campaign↔store mapping is an
open backlog item.

## Reach

Reach is deduplicated **within one (platform, campaign, reach_week)** and nowhere else. Ad-set
reach summed to the campaign exceeds campaign reach on 159 of 647 facebook campaign-weeks.
Consequences:

- Always filter `rch.reach_level = 'campaign'` (or `'ad_set'`) — never both.
- Use `avg(rch.reach)` or `max(rch.reach)` per campaign. **`sum(rch.reach)` is always wrong.**
- "How many people did we reach this quarter" **cannot be answered** — there is no
  de-duplicated cross-campaign or multi-week figure. Say so and offer per-campaign weekly reach.
- `reach_week` is the **Sunday that starts** a Sun–Sat reach week; the CZ week is Mon–Sun labelled
  by its Sunday. They are offset by a day and never align with sales weeks.
- No Google Ads or Spotify reach exists. Frequency (impressions ÷ reach) can only be computed for
  facebook, snapchat and tiktok, and only within a campaign-week.

## Pattern: channel scorecard for a window

```sql
select
ads.platform as platform
, round(sum(ads.spend), 2) as spend
, sum(ads.impressions) as impressions
, sum(ads.clicks) as clicks
, round(sum(ads.conversions), 1) as conversions
, round(safe_divide(sum(ads.spend), sum(ads.impressions)) * 1000, 2) as cpm
, round(safe_divide(sum(ads.clicks), sum(ads.impressions)) * 100, 2) as ctr_pct
, round(safe_divide(sum(ads.spend), sum(ads.clicks)), 2) as cpc
, round(safe_divide(sum(ads.spend), sum(ads.conversions)), 2) as cpa
, round(safe_divide(sum(ads.conversion_value), sum(ads.spend)), 2) as roas
from `marketing-data-442316`.claude.ad_spend_daily ads
where 1=1
and ads.business_date between @start and @end
group by ads.platform
order by spend desc
```

## Pattern: top campaigns on one platform

```sql
select
ads.campaign as campaign
, round(sum(ads.spend), 2) as spend
, round(sum(ads.conversions), 1) as conversions
, round(safe_divide(sum(ads.spend), sum(ads.conversions)), 2) as cpa
from `marketing-data-442316`.claude.ad_spend_daily ads
where 1=1
and ads.business_date between @start and @end
and ads.platform = 'facebook'
and ads.account_name <> 'Cafe Zupas Catering'
group by ads.campaign
order by spend desc
```

## Pattern: spend next to sales (state the attribution wall)

Spend has no store key, so the only honest join to sales is **chain-wide by date**. Aggregate each
side to the date grain first, then join — never join the views row to row.

```sql
with media as (
select
ads.business_date as business_date
, round(sum(ads.spend), 2) as spend
from `marketing-data-442316`.claude.ad_spend_daily ads
where 1=1
and ads.business_date between @start and @end
group by ads.business_date
)
, sales as (
select
oc.business_date as business_date
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between @start and @end
and oc.is_catering = false
group by oc.business_date
)
select
m.business_date as business_date
, m.spend as spend
, s.net_sales as net_sales
from media m
  join sales s
    on s.business_date = m.business_date
order by m.business_date
```

This is a **correlation, not attribution**. Say that in the answer. Do not divide net sales by
spend and call it ROAS.

## Pre-query clarification protocol (additions)

On top of `ask-a-data-question`, resolve these before running a media query:

1. **Window** — and check it against the coverage table. If it reaches before 2026-01, name which
   platforms are missing months.
2. **Platforms** — all five, or named ones? Spotify has no conversions; Google and Spotify have no
   reach.
3. **Catering** — include or exclude `Cafe Zupas Catering` (Facebook only)?
4. **Which efficiency metric** — CPM/CTR (delivery) or CPA/ROAS (platform-attributed)? If the
   latter, warn on the attribution wall and, for TikTok, on the maturation lag.

## SQL style (steward rule — MANDATORY)

Same rules as every other skill: see "SQL style" in
[`sales-ops-orders/SKILL.md`](../sales-ops-orders/SKILL.md). Fully qualified tables with backticks
around the **project only**, an alias on every column reference, lowercase, stacked select list
with leading commas and the first field flush with `select`, `from` / `group by` / `order by`
values on the keyword line, `where 1=1` with one `and` per line. Fixed aliases here:
`ad_spend_daily` → **`ads`**, `ad_reach_weekly` → **`rch`**.

## Known gaps / not yet answerable

- **Store-level media performance** — no store key; only a name regex on Google PMax asset groups.
- **True incrementality or blended CAC** — platform attribution only; nothing ties a media
  impression to a Brink order.
- **Cross-platform de-duplicated reach or frequency** — no shared audience key.
- **Google Ads and Spotify reach** — no reach tables exist upstream.
- **Restatement behaviour for facebook / google / snapchat / spotify** — only TikTok has a
  snapshot history. Unknown, not zero.
- **Pre-2026 completeness** — see rule 2. Log any windsor.ai backfill for the 2024 gaps as a
  pipeline item, not a query problem.
