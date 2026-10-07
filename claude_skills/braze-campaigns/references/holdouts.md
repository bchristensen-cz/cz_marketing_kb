# Holdouts, experiment steps and incrementality

> Part of the `braze-campaigns` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question involves control groups, holdouts, lift, incrementality or experiment steps.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Holdouts, experiment steps and incrementality (steward findings 2026-09-15)

A Canvas holdout is the only randomised evidence Braze produces, and almost everything about how it is stored is counter-intuitive. Read this whole section before quoting any lift number.

### 1. Finding holdouts: three traps

- **The step name is useless.** Over 2026-06-16 → 09-14, **137** canvases ran an experiment step (**189** distinct steps) and exactly **one** named the step legibly (`Holdout vs Treatment` on `20250821 | Meta & TikTok Audience Sync`). Everything else is `Step 6`, `Step 7` or a bare `Step`. Searching `canvas_step_name` for holdout words finds essentially nothing.
- **`in_control_group` alone is not enough.** The holdout identity lives in `canvas_experimentstep_splitentry.experiment_split_name`, and the boolean is not reliably set. Measured 2026-09-14: **82** canvases carry `in_control_group = true`, but **2 more** carry a split literally named `Control` with the flag **false**, both of them live weather automations (`cm:weather_automation` Step 10, 21,446 users; `cm:weather_automation_free_delivery` Step 10, 30,767 users). Unflagged `control`, `hold`, `bowl_control`, `salad_control` and `sandwich_control` legs also appear inside canvases that separately *do* have a flagged Control. **Always match `in_control_group = true` OR a name regex**, never the boolean alone:
  ```sql
  where 1=1
    and (se.in_control_group
      or regexp_contains(lower(coalesce(se.experiment_split_name, '')), r'hold|control|ctrl|suppress|baseline'))
  ```
- **🚨 Some holdouts are not experiment steps at all and are invisible to `canvas_experimentstep_splitentry`.** `20250821 | Meta & TikTok Audience Sync` splits 422,449 users ~90/10 at a step named `Holdout vs Treatment` and returns **zero rows** from that table. It is an Audience Path / decision split, visible only in `canvasstep_progression` via `next_step_id` fan-out. Its holdout leg is 39,450 users, the largest single deliberately-suppressed population in the window. An inventory built only off the experiment table misses it entirely. Path-split holdouts are expensive to detect (a 90-day `canvasstep_progression` sweep billed **56 GB** on 2026-09-14), so do it once per quarter, not per session.

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
