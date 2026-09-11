# Data Dictionary: `marketing-data-442316.claude.ad_reach_weekly`

**One row per platform / campaign / reach level / week** (plus the ad set, at ad-set level).
Union view over the six `edi.*_weekly_reach_*` tables, with `reach_year_week` joined on from
`edi.reach_rel_date`. Build script:
[`sql/claude.ad_reach_weekly.sql`](../sql/claude.ad_reach_weekly.sql). Deployed 2026-09-11.

Kept separate from [`claude.ad_spend_daily`](claude.ad_spend_daily.md) on purpose: reach is
weekly, non-additive, and exists for only three of the five platforms. Joining it onto daily
spend rows would invite exactly the double counting the rule below forbids.

## Columns

| Column | Type | Notes |
|---|---|---|
| `reach_week` | DATE | **Partition column — always filter on it.** Always a **Sunday** (100% of rows). |
| `reach_year_week` | STRING | `'YYYY|WW'`, from `edi.reach_rel_date`. Never NULL on any current row. |
| `platform` | STRING | `facebook`, `snapchat`, `tiktok` only. **No Google Ads or Spotify reach exists.** |
| `datasource` | STRING | Passthrough; same values as `platform`. |
| `account_name` | STRING | Ad account. |
| `campaign` | STRING | Joins by name to `claude.ad_spend_daily.campaign` — 645/647 facebook, 111/111 snapchat, 285/286 tiktok campaign-weeks match a campaign in the daily data. |
| `ad_set` | STRING | Populated only where `reach_level = 'ad_set'`; NULL at campaign level. |
| `reach_level` | STRING | `campaign` or `ad_set`. **Always filter this.** |
| `reach` | INT64 | Unique people reached in that week at that level. Source column is `campaign_reach` on both source grains — on the ad-set tables it holds ad-set reach despite the name. Never NULL, never zero. |

## 🚨 The rule: reach is not additive

Reach is deduplicated **within one (platform, campaign, reach_week)** and nowhere else. The same
person reached by two campaigns, or in two weeks, or by two ad sets, is counted once per bucket.

Measured 2026-09-11 — ad-set reach summed to the campaign **exceeds** campaign reach on:

| Platform | Campaign-weeks | …where ad-set sum > campaign | …where equal (single ad set) | Campaign-level total | Ad-set sum |
|---|---|---|---|---|---|
| facebook | 647 | 159 | 451 | 54,454,219 | 56,248,999 |
| tiktok | 286 | 19 | 253 | 25,005,853 | 25,096,306 |
| snapchat | 111 | 38 | 66 | 5,975,351 | 6,080,685 |

So:

- **Never sum across `reach_level`** — that double counts the whole dataset.
- **Never sum reach across campaigns** to get "people reached" — overlap is unknown.
- **Never sum reach across weeks** to get a period reach — it is a weekly unique count.
- The only safe aggregate is **average or max weekly reach** for a single campaign, or a
  campaign-by-campaign listing.
- **There is no de-duplicated total-audience number in this data.** If someone asks "how many
  people did we reach in Q2", the honest answer is that the data cannot produce it; offer
  per-campaign weekly reach instead.

## Other gotchas

- **Reach weeks are Sun–Sat; the Cafe Zupas week is Mon–Sun.** `reach_week` is the **Sunday that
  starts** the reach week (windsor.ai convention). The CZ week runs Monday → Sunday and is
  labelled by its Sunday (`claude.date_dim.week_ending`, steward rule 2026-09-09), with trading
  Mon–Sat. So a reach week and a CZ week are **offset by one day and never line up**, and
  `reach_week` is emphatically not `week_ending` — it is the day *after* the CZ week it most
  nearly resembles ends. Say the weeks are offset whenever reach sits next to sales.
- **The newest week is partial** until the next load replaces it — the upstream restatement drops
  the oldest still-partial reach week each run.
- Coverage differs from spend: facebook from 2023-12-31, tiktok from 2024-01-14, snapchat from
  2025-11-09. Facebook and TikTok reach carry the same 2024 gaps as their daily tables.

## Standard pattern

Weekly reach for one campaign:

```sql
select
r.reach_week as reach_week
, r.campaign as campaign
, r.reach as reach
from `marketing-data-442316`.claude.ad_reach_weekly r
where 1=1
and r.reach_week between @start and @end
and r.reach_level = 'campaign'
and r.platform = 'facebook'
order by r.reach_week, r.campaign
```

Top campaigns by average weekly reach — note `avg`, never `sum`:

```sql
select
r.platform as platform
, r.campaign as campaign
, count(*) as weeks_live
, round(avg(r.reach), 0) as avg_weekly_reach
, max(r.reach) as peak_weekly_reach
from `marketing-data-442316`.claude.ad_reach_weekly r
where 1=1
and r.reach_week between @start and @end
and r.reach_level = 'campaign'
group by r.platform, r.campaign
order by avg_weekly_reach desc
```
