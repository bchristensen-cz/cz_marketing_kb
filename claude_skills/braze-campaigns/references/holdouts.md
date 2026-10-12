# Holdouts, experiment steps and incrementality

> Part of the `braze-campaigns` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question involves control groups, holdouts, lift, incrementality, experiment steps, campaign control groups or sync canvases. §12 to §16 added 2026-10-12 (ledger D-034, D-035).
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Holdouts, experiment steps and incrementality (steward findings 2026-09-15)

A Canvas holdout is the only randomised evidence Braze produces, and almost everything about how it is stored is counter-intuitive. Read this whole section before quoting any lift number.

### 1. Finding holdouts: three traps

- **The step name is useless.** Over 2026-06-16 → 09-14, **137** canvases ran an experiment step (**189** distinct steps) and exactly **one** named the step legibly (`Holdout vs Treatment` on `20250821 | Meta & TikTok Audience Sync`). Everything else is `Step 6`, `Step 7` or a bare `Step`. Searching `canvas_step_name` for holdout words finds essentially nothing.
- **🚨 A name is a candidate filter, never a verdict (steward ruling 2026-10-12, ledger D-035).** Several arms named `control` were baseline creative arms that received messages: `better_in_a_bowl` (canvas `ffcfeb00`) split `control`, 553,051 users, 18.4% messaged, the same rate as its siblings; `summer_fuel` (`6b779f82`) `bowl_control` / `salad_control` / `sandwich_control`, ~97% messaged; `journey_to_3_month1` (`70fce7e9`) `Journey to 3 Control`, 97.8% messaged (measured 2025-12-29 → 2026-10-11, `cafe_zupas`). The real holdouts in those canvases are the `hold` legs. Classify every leg by what its users received:
  - **Flagged** (`in_control_group = true`): a holdout. Still report its messaged count; flagged legs measured 0 to 2 users messaged.
  - **Unflagged name match with 0 users messaged** from the same canvas at or after split entry: a holdout.
  - **Unflagged name match with users messaged**: not usable as a control. If its messaged rate matches its siblings it is a creative arm; if it is well below them it is a leaky holdout (§14). Either way it stays out of every control base.
- **`in_control_group` alone is not enough.** The holdout identity lives in `canvas_experimentstep_splitentry.experiment_split_name`, and the boolean is not reliably set. Measured 2026-09-14: **82** canvases carry `in_control_group = true`, but **2 more** carry a split literally named `Control` with the flag **false**, both of them live weather automations (`cm:weather_automation` Step 10, 21,446 users; `cm:weather_automation_free_delivery` Step 10, 30,767 users). Unflagged `control`, `hold`, `bowl_control`, `salad_control` and `sandwich_control` legs also appear inside canvases that separately *do* have a flagged Control. **Always match `in_control_group = true` OR a name regex to find candidates**, never the boolean alone, then apply the messaged check above:
  ```sql
  where 1=1
    and (se.in_control_group
      or regexp_contains(lower(coalesce(se.experiment_split_name, '')), r'holdout|(^|[^a-z])hold([^a-z_]|$)|control|ctrl|suppress|baseline'))
  ```
  The pattern changed 2026-10-12. The old `hold|control|ctrl|suppress|baseline` matched `points_threshold_*` (~1.1M sends) and `hold_the_bun_burger_bowl` when reused on step names; `hold` now needs a non-letter boundary and may not be followed by `_` (steward ruling: exclude `hold_`). Verified on literals 2026-10-12: `hold`, `Hold`, `bowl_hold`, `holdout`, `Control`, `bowl_control` match; `hold_the_bun_burger_bowl`, `points_threshold_500`, `remainder`, `creative_a` do not. `bowl_control` still matches by design, which is why the messaged check is the final word. Messaged check, core shape (`legs` = split entry per user with `min(time)`; `sends` = the email / push / SMS / RCS send union scoped to the same canvas ids):
  ```sql
  select
  l.canvas_id
  , l.canvas_step_id
  , l.experiment_split_name
  , l.in_control_group
  , count(distinct l.external_user_id) as leg_users
  , count(distinct if(s.external_user_id is not null, l.external_user_id, null)) as users_messaged_after_split
  from legs l
  	left join sends s
  	on s.canvas_id = l.canvas_id
  	and s.external_user_id = l.external_user_id
  	and s.time >= l.entry_time
  group by l.canvas_id, l.canvas_step_id, l.experiment_split_name, l.in_control_group
  ```
  `sql/analysis/braze_canvas_message_report.sql` carries the same check as `holdout_users_messaged` on its holdout rows (keyed on the email bridge, so users with no email are not checked).
- **🚨 Some holdouts are not experiment steps at all and are invisible to `canvas_experimentstep_splitentry`.** `20250821 | Meta & TikTok Audience Sync` splits 422,449 users ~90/10 at a step named `Holdout vs Treatment` and returns **zero rows** from that table. It is an Audience Path / decision split, visible only in `canvasstep_progression` via `next_step_id` fan-out. Its holdout leg is 39,450 users, the largest single deliberately-suppressed population in the window. **It is a sync canvas and is excluded from every incrementality read (§12)**; still live 2026-10-11 with 712,588 entrants, and the only path-split holdout found in the 2026-10-12 audit. An inventory built only off the experiment table misses it entirely. Path-split holdouts are expensive to detect (a 90-day `canvasstep_progression` sweep billed **56 GB** on 2026-09-14), so do it once per quarter, not per session.

### 2. A Braze holdout is scoped to ONE SEND, never to a campaign

This is the finding that invalidates most of what people want to ask. Holdout draws are **independent on every send**, so a multi-send campaign has no campaign-level control group.

Measured on the five Labor Day canvases, 2026-09-03 → 09-08:

| Held out of N of the 5 canvases | Users |
|---|---|
| 1 | 535,866 |
| 2 | 96,603 |
| 3 | 7,905 |
| 4 | 315 |
| 5 | **3** |

A persistent holdout would put ~180,000 in the bottom row. And **84,708 of the 179,907 held out on Sept 7 (47.1%) received a Labor Day message anyway** from a sibling canvas inside the same four days.

**Rules that follow:**
- Never quote campaign-level or flight-level incrementality off per-send holdouts. Measure the overlap first; it takes one query.
- What *does* survive is the marginal effect of an individual send. Prior exposure is balanced across arms by the independent re-randomisation, so a single send's read is clean even when the audience was hit three times that week.
- For a genuine campaign-level read, use `braze.global_holdout` or a fixed `random_bucket_number` band so the same people are suppressed for the whole flight.

### 3. Report reach next to every lift number

The experiment step usually sits at the **top** of the canvas, above the audience-path and channel routing, so the control is a random slice of *everyone* while a large share of the treatment arm is never actually reachable. On `260907 | … | LaborDayWeekend3` (2026-09-07): 1,616,819 treated, but only **850,469 (52.6%)** received an email or push. The rest were routed into a push-only branch they had no token for.

- Compare **whole arms only** (intent to treat). Never control vs recipients, openers or clickers, because that compares a random slice against a deliverability-filtered one and overstates lift badly.
- `ITT ÷ reach rate` gives the effect on those actually reached. Legitimate only when reachability is balanced across arms, which is an empirical check, not an assumption.

### 4. Auditing randomisation for free

If a holdout is a true random slice, its reach rate on a *neighbouring* canvas matches the whole file's. Measured on the Sept 7 holdout (denominator 1,796,739 entrants):

| Neighbouring send | Share of file reached | Share of Sept 7 holdout reached |
|---|---|---|
| Sept 4 | 41.73% | 41.66% |
| Sept 5 | 40.10% | 39.99% |
| Sept 3 | 39.41% | 39.41% |

Three checks within 0.1pp. Run this before trusting any arm; it costs one bounded query and it is what licenses the reach correction above.

### 5. 🚨 A single broadcast can prove nothing: the measured MDE

Measured 2026-09-15 on `260907 | … | LaborDayWeekend3`, 3-day window, catering excluded, per-arm `safe_cast` drops 6.21% vs 6.22% (symmetric):

| Arm | Joinable | Orderers | Order rate | Net sales / user | SD |
|---|---|---|---|---|---|
| Control | 168,739 | 2,146 | 1.2718% | $0.349336 | 9.4192 |
| Treatment | 1,516,284 | 19,472 | 1.2842% | $0.365776 | 10.0561 |

Difference $0.016440, SE $0.024341, **z = 0.68**. The 80% MDE is **$0.0682 per user, a 19.5% relative lift**, roughly $103,000 of incremental net sales on one send. No promotional email moves revenue 20%.

**Never report a per-campaign holdout result.** It will keep producing encouraging point estimates that mean nothing. Per-creative comparisons ("did the burger bowl email beat the cozy soup email") are dead on arrival for the same reason.

⚠️ Do not model the revenue variance analytically. A first pass at this assumed a CV of ~0.8 among orderers and produced SD ≈ $3.95 against a measured $10.06, understating the SE by more than half. Measure `var_samp` per arm.

### 6. The pooled read is where the value is: recipe and measured result

Because assignment is re-randomised independently per send, each canvas is an independent experiment on the same population. That is exactly the condition for **inverse-variance meta-analysis**: compute the per-canvas effect and its variance, then combine.

**⚠️ Outcome windows must not overlap.** With near-daily broadcasts, 3-day windows share orders between consecutive canvases, the estimates stop being independent and the pooled SE is understated. Use a **same-day (day-0) window** as the defensible headline; treat any multi-day window as sensitivity only.

Measured 2026-09-15, 46 broadcast canvases with send dates 2026-06-16 → 09-10, 5,059,540 control and 65,093,010 treated user-exposures, catering excluded:

| Metric (day-0 window) | Control base | Pooled lift | SE | z | Relative |
|---|---|---|---|---|---|
| Net sales per user | $0.124291 | **+$0.005994** | $0.001532 | **3.91** | **+4.82%** |
| Order rate | 0.44808% | **+0.0086pp** | 0.00306pp | **2.81** | **+1.92%** |

Heterogeneity: **Cochran's Q = 43.48 on 45 df, so I² = 0**, so there is no detectable variation in effect across canvases, and the pooled estimate is a fair summary. 28 of 46 individual canvases are positive, which is what a small true effect looks like when single-canvas noise dominates.

**Program value:** 65,093,010 treated exposures × $0.005994 = **$390,189 incremental net sales over the 87-day window**, 95% CI **$194,697 to $585,635**. About **$8,483 per broadcast**. Annualised roughly $1.64M (CI $0.82M to $2.46M).

Note the revenue lift (+4.82%) runs ahead of the order-rate lift (+1.92%), implying a basket-size effect as well as an incidence effect. Not separately tested. Do not assert it without measuring AOV directly.

**Pooled MDE is ~3.4% on revenue and ~1.1% on order rate**, versus 19.5% and 6.4% for a single send. That is the whole argument for pooling.

### 7. Standardise the holdout at 10%

Holdout sizing is inconsistent and it costs real information. Over the window, 28 broadcasts used ~10% (control ≈ 176,000), 17 used ~2% (control ≈ 34,500), two used 5% and one ran 50/50. Since `n_t >> n_c`, the **control size alone drives the standard error**: a 2% canvas carries about one fifth the information of a 10% one.

Moving a 2% canvas to 10% holds out ~138,000 more people, forgoing roughly **$2,275 of net sales per send** at the measured effect size, and multiplies that canvas's weight in the pool by ~4.7x. Take that trade every time.

### 8. Scratch tables (rebuild once per session, never per query)

Built 2026-09-15, 21-day expiry. Rebuilding the chain costs ~23 GB (`holdout_legs_90d`) + ~17 GB (`holdout_arms_90d`) + ~11 GB (`holdout_canvas_stats`); querying them costs ~10 MB.

| Table | Grain |
|---|---|
| `scratch.holdout_legs_90d` | canvas × step × split × `in_control_group`, with users and date range |
| `scratch.holdout_arms_90d` | canvas × user × arm, primary experiment step only, tier-A canvases, partitioned by `arm_date` |
| `scratch.cust_daily_net_95d` | `mapped_cust_id` × `business_date`, non-catering orders and net sales |
| `scratch.holdout_canvas_stats` | canvas × arm: n, mean, `var_samp`, orderers, for both day-0 and 3-day windows |

The per-canvas effect and the pool come straight off the last one. The KB's standing warning about repeated unrolled canvas scans (~45 GB per `canvas_entry` run) applies here with force: `canvas_experimentstep_splitentry` is 119 GB and a 90-day unbounded name search bills 24 GB.

### 9. 🚨 Order-mart maturity gates the outcome window

Found 2026-09-15 while building the above. `claude.order_customer` for **2026-09-14** held 28,039 orders but only **95** carried a non-null `mapped_cust_id` (0.34%), against **48% to 57%** on every other trading day that week. The identity chain (`sales_ops.cust_map` 04:00 → `order_sequence.mapped_cust_id`) had not been applied to the previous day. Any lift analysis whose window reaches into that day silently reads near-zero orders for both arms.

- **Before setting an outcome window, check `countif(mapped_cust_id is not null) / count(*)` by `business_date`** and stop the window at the last day inside the normal band. On 2026-09-15 that was **2026-09-12**, capping usable send dates at 09-10.
- Separately: **stores are closed Sunday**, so Sundays carry roughly 7 to 10 orders chain-wide. A Friday or Saturday send's multi-day window includes a dead day. Symmetric across arms so it does not bias, but it dilutes power ,  another reason day-0 is the better window.
- Generalisable: *a mart being populated is not the same as a mart being joined.* Row counts looked normal on 09-14; only the join key was missing.

### 10. What cannot be extracted (stop promising these)

- Per-campaign or per-creative reads. MDE 19.5%.
- Campaign-level incrementality for any multi-send flight. No persistent holdout exists.
- **Per-branch reads within a canvas**, unless the audience-path conditions are reconstructable as SQL. The holdout sits above the routing, so control users carry no branch label. If the branch logic lives only in the Braze UI, it is unrecoverable from Currents. Fix forward by stamping a custom attribute at each routing step, or by routing first and running an experiment step inside each branch.

### 11. The accidental frequency experiment (open opportunity)

Nobody designed this. With ~one broadcast per day and an independent 7% to 10% holdout each time, **each person's actual exposure count in a given week is randomly assigned**. 640,692 distinct people were held out of at least one Labor Day canvas alone. That is a valid instrument for a dose-response curve: the marginal value of the 5th broadcast in a week versus the 3rd, the frequency at which marginal revenue goes to zero, and whether higher frequency raises unsubscribes enough to offset marginal orders. The roster in §8 is already the input. Logged as a KB gap; not yet built.

### 12. 🚨 Sync canvases are out of every incrementality read (steward ruling 2026-10-12, ledger D-034)

Sync canvases push audiences to ad platforms and send no messages, so a holdout inside one measures the ad audience, not Braze messaging. Exclude them from holdout lift, pooled reads and holdout inventories:

```sql
and not regexp_contains(lower(coalesce(canvas_name, '')), r'(^|[^a-z])sync([^a-z]|$)')
```

The boundary keeps `async` / `synchrony` out and catches both the `Audience Sync` and the `ch:sync` naming. Ten canvases matched in `canvas_entry` over 2025-12-29 → 2026-10-11: `13d70795` Meta & TikTok Audience Sync, `e3b3d5d8` First 91 Days, `9b7a072d` Minnesota Favorites, `102dd876` Has 2 Purchases, `0252c9a5` Installed App, `c5ecbd84` Reward Members w and w/o App, `badf8f7a` `cm:whole_list_to_platforms`, `d0ffca70` `cm:vto_custs`, `c25678fd` `cm:salad_custs`, `59a77ce4` `cm:cup_bowl_chipotle_custs_sync`. That listing billed 122 GB because `canvas_entry` does not prune on canvas filters; do not repeat it per question. **Naming rule: a new sync canvas must carry `sync` in its name** or the rule cannot see it.

### 13. Canvas-level Control variants live only in `canvas_entry` (found 2026-10-12)

A canvas's Variant settings can carry a Control variant. Those users are flagged `canvas_entry.in_control_group = true` and **never appear in `canvas_experimentstep_splitentry`**, so the canvas message report and `scratch.holdout_*` miss them. Cases over 2025-12-29 → 2026-10-11:

- `af863b6e` `journey_to_3_2to3_month1_automated`: Control is **intended** (steward, 2026-10-12), but its allocation changed mid-flight: ~75% of entries Feb to Jun (March 12,523 Control vs 4,282 variant), ~46% July, ~10% from August (August 1,244 vs 11,515, matching today's 90/10 setting). **Read those periods separately. Pooling across the change confounds time with arm.**
- `5b7fe716` `journey_to_3_1to2_month3` (old version): 492 Control users through 2026-02-09, none since.

A complete inventory needs a `canvas_entry` leg. It costs ~66 to 131 GB per pass (filtering on `canvas_id` does not prune), so run it quarterly with the path-split sweep in §1, never per question. New canvases use the experiment-step control (§16), not a variant.

### 14. Leaky holdouts: run the messaged check before using any leg (found 2026-10-12)

`summer_fuel` (`6b779f82`, `d:260618 | a:all | ch:email_push | cm:summer_fuel`) has nested `hold` legs under its creative split that received messages: step `3a297164` 80 of 788 users (10.2%), `89015562` 56 of 320 (17.5%), `bb80816f` 30 of 203 (14.8%). The other `hold` legs checked (protein bowl, double_protein, summer combos, better_in_a_bowl) were 0%. Likely canvas re-entry or a later step reaching them; not yet investigated. A holdout that receives messages understates lift, so an unflagged leg is used only when its messaged count is 0 (§1).

### 15. Campaign control groups: `campaigns_enrollincontrol` (recipe from KB finding 2026-08-20, audited 2026-10-12)

Campaigns (not canvases) write their built-in Control Group to `braze.campaigns_enrollincontrol`. These are real simultaneous randomised controls: on the Mobile_Web downloadapp campaign (`c442a0d3-fed0-4b80-8683-5a13ad5dc9ce`) 897 impressed vs 377 control users, **zero overlap**, ~70/30 enrolment on every day of the flight. Audit 2025-12-29 → 2026-10-11: browse abandonment 22,604 control users since 2026-07-17, add-to-cart abandonment 5,171, the downloadapp family, post-order app-download IAMs, Labor Day IAM 6,431. No campaign variant named holdout or control sent anything outside this table, apart from one-send internal content-card tests. **Neither the canvas message report nor the dashboard reads this table yet.**

Recipe for a lift read:

1. **Legs.** Exposed = each user's first exposure (`*_send`, or `inappmessage_impression` for IAM) on the `campaign_id`; Control = first `campaigns_enrollincontrol` row for the same `campaign_id`. Assert zero overlap and check the daily split ratio before trusting the legs.
2. **Per-user clock.** Each user's window starts at their own exposure or enrolment (`timestamp_seconds(time)`), never a calendar window.
3. **Maturity truncation.** Keep only users whose window has fully elapsed, and stop at the order-mart maturity limit (§9). On the Mobile_Web campaign this cut 899/378 to 231/109 for a 14-day window. The loss is not optional.
4. **MDE next to the result.** At 231/109 with SD ≈ $26 of 14-day net sales per user, the 80%-power MDE was $8.46/user, 46% of the control mean. A null at that size is uninformative and a point estimate is not a finding.
5. **Heavy right tail.** Cap or winsorise and always show the median. On the same campaign the whole headline gap (−$2.22/user, p = 0.49) traced to one $183.37 order in a 65-order control arm. Four defensible specs (72h all users +$0.89, 7d matured −$0.29, 14d matured −$2.22, 14d all users +$0.59) gave two signs and nothing significant.
6. **Label** it "lift vs. Braze control group", with n, window, CI and MDE. This is a holdout read, so "incremental" is allowed here and only here.

Automated campaigns (abandonment, app download, birthday, post-order IAM) are the best candidates: volume keeps building, which is where the power comes from.

### 16. The holdout standard for new canvases and campaigns (adopted 2026-10-12)

Full playbook with the audit behind it: [Braze Holdout Playbook](https://claude.ai/code/artifact/4eb8bf14-1c58-4ce6-8f3d-8c04c2da51a2). The rules a reader needs:

- **One holdout per canvas or campaign, 10% by default** (§7). Canvas: a single Experiment Paths step **first**, built-in control option on, above any audience path, channel routing or creative test. Campaign: the built-in Control Group. No nested second holdout, no Audience Path / Decision Split holdout, no canvas-level Control variant (§13).
- **Automations** keep the 10% holdout on permanently and never change the percentage mid-flight (§13 shows what that costs). Raising to 20% for a flow that collects fewer than ~2,000 holdout users a quarter is a rule of thumb, not yet measured.
- **Names**, so a name means one thing:

| Thing | Name | Never |
|---|---|---|
| Experiment step holding the control | `holdout_split` | `Step 6`, `Step` |
| Path that receives nothing | `holdout` | `hold`, `remainder`, `Path 2` |
| Baseline creative arm | `creative_a` | `control`, `baseline`, `bowl_control` |
| Other creative arms | `creative_b`, `creative_c`, ... | `Path 1` |
| Offer test arms | `offer_none`, `offer_500pts`, ... | `No Offer`, `500 Points` |
| Flight band segment | `flight_holdout_<yymmdd>_<flight>` | anything without the date |

  Add an `ho:<pct>` token (e.g. `ho:10`) to the canvas or campaign name beside `st:` and `cm:` so the holdout size reads without a scan. Sync canvases carry `sync` (§12).
- **Flight-level questions** ("did the Labor Day campaign work") need the same people held out of every send: a `random_bucket_number` band excluded from every canvas and campaign in the flight, a different band per flight, logged in a roster (flight, band, dates, owner). Keep the per-send holdouts on; they still feed the pool. The owned bucket assignment in D-024 is still pending, so the band lives in Braze segments until then.
- **After the first send:** holdout users messaged = 0%, and holdout share within 0.5 points of the setting.
