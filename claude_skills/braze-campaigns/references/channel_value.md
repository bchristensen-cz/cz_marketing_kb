# Channel value and channel combinations

> Part of the `braze-campaigns` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question compares channels (email vs push vs SMS) or channel combinations on value or lift.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Channel value and channel combinations (steward findings 2026-09-16)

Analysis SQL: `sql/analysis/braze_channel_value_analysis.sql`. Answers "what is a send on channel X worth" and "is email plus a text worth more than either alone".

### 1. 🚨 The descriptive channel ranking is inverted, and it will keep getting quoted

Net sales per user-day, by the channel set a person received that day, 2026-03-16 → 2026-09-14:

| Channels received | User-days | Order rate | Net sales / user-day |
|---|---:|---:|---:|
| email + sms | 23,395 | 88.50% | $27.33 |
| sms | 18,665 | 74.90% | $22.89 |
| iam | 148,712 | 50.99% | $13.61 |
| banner | 39,544 | 15.85% | $3.64 |
| push | 1,429,237 | 11.68% | $2.91 |
| email + push | 2,588,871 | 2.08% | $0.517 |
| content_card + email + push | 9,981,405 | 1.48% | $0.353 |
| **email** | **31,141,864** | **0.377%** | **$0.104** |
| content_card | 15,459,093 | 0.19% | $0.048 |
| rcs | 96,616 | 0.13% | $0.035 |

Read literally this says an SMS is worth 220x an email. It is not. **In-app message, banner, content card and SMS are gated on an ordering session**, so the exposure only reaches people already transacting. Program names give it away: SMS is one automation, `SMS_Subscription_ShortCode_New_Contact_Card_Final` (35,631 user-days, 71% order rate) — it fires when someone texts the short code at the counter. The top IAM programs are `Post_order_push_prompt` (99.25%) and `Post_order_app_download_IAM_updated` (93.66%).

**It is NOT reverse causality — test it before saying so.** Comparing `timestamp_seconds(e.time)` to `oc.order_timestamp_utc`, the exposure genuinely precedes the order on every channel (iam 97.2%, sms 95.7%, email 88.3%). The tell is the *lead time*: 70 min from an IAM to the order and 56 from a banner against 252 for email. The session-gated channels fire inside the ordering visit; exposure and order share the intent that caused both.

Email is the only channel here that reaches people who were not already ordering, which is why it looks worst and why it is the only row that survives a control group — $0.104 sits right on the $0.124 randomised control base.

### 2. SMS is not the text channel; RCS is

SMS carries **93,466 user-days over six months** against email's 65.8M, nearly all of it that one opt-in automation. Broadcast text moved to RCS on **2026-07-20**. Any question phrased as "email plus SMS" is a question about email plus RCS. Also note `banner_impression` only starts 2026-06-17 — restrict combination work to **2026-07-20 forward** so all seven channels exist.

### 3. Stacking channels onto email is not measurably better than email alone

Pooled inverse-variance, day-0, by the channels the treatment arm actually sent:

| Channel mix | Canvases | Control base | Lift/user | SE | z | Relative |
|---|---:|---:|---:|---:|---:|---:|
| email + push + content_card | 33 | $0.1230 | +$0.00604 | $0.00179 | 3.37 | +4.9% |
| email + push | 9 | $0.1307 | +$0.00469 | $0.00351 | 1.34 | +3.6% |
| email only | 3 | $0.1233 | +$0.00461 | $0.00669 | 0.69 | +3.7% |

Contrast between email-only and the three-channel stack: **+$0.0014, SE $0.0069, z = 0.21.** The 80% MDE on that contrast is **$0.019 per user per send** (15.7% of base).

⚠️ **That is a ceiling, not a zero.** $0.019 x ~1.5M users x ~90 broadcasts a year is several million dollars. "We could not measure it" is not "it does not exist" — do not let this become a reason to cut push or content card. The fix is a channel-level experiment step *inside* a canvas.

Also: canvases were not randomly assigned to channel mixes, so a *difference* between these rows would be observational. The *absence* of one is the safer read.

### 4. Derive the channel mix from the send tables, never from the canvas name

The `ch:` token in a canvas name disagrees with what was actually sent, often. `d:260819 | ... | ch:email_push | cm:cozy_soup` fired a content card too; `260903 | ... | email_push | LaborDayWeekendThurs` sent no push at all. Build the mix by unioning the seven send tables on `canvas_id` + `event_date` (step 5 of the analysis SQL).

### 5. ✅ The email x text 2x2 — the one combination design that exists

On **2026-09-04** and **2026-09-07** an email/push canvas and an RCS canvas each ran on the same day, and **each drew its own independent holdout**. Everyone in both canvases is randomly assigned to one of four cells. This is the only design in the warehouse that can answer a combination question.

The RCS canvases (`cc1824e5-13f1-4c28-b4b8-bfbaafebf8b2` Sept 7, `f6b0b1b0-352d-4622-8bb8-fe4ea6d25392` Sept 4) are **not in `scratch.holdout_arms_90d`** — that roster is tier-A only. Pull them from `canvas_experimentstep_splitentry` directly.

Pooled over both days, control base $0.235:

| Effect | Estimate | SE | z | Relative | 80% MDE |
|---|---:|---:|---:|---:|---:|
| Text (RCS) | +$0.0578 | $0.0268 | 2.16 | +24.6% | $0.075 (31.9%) |
| Email | +$0.0071 | $0.0268 | 0.26 | +3.0% | $0.075 (31.9%) |
| **Interaction** | **−$0.0188** | **$0.0536** | **−0.35** | −8.0% | $0.150 (63.8%) |

**The channels add, they do not multiply.** No synergy, no cannibalisation. A person who gets both is worth about what the two are worth separately.

⚠️ **Two sends only.** The text effect is nominally significant at z = 2.16 but sits *below* its own 80% power threshold — the exact shape of an encouraging point estimate that shrinks later. And the RCS audience is 333k opt-ins who order at twice the file's rate ($0.235 base vs $0.124); their responsiveness is not the file's. The email effect reading +3.0% rather than +4.8% is not a contradiction: this subsample's MDE is 31.9%.

### 6. The independence audit is free, and so is the placebo

The cell counts prove independence on their own: of the 33,049 held out of the Sept 7 text send, 9.92% were also held out of the email send; of the 299,148 who got the text, 9.97% were. **0.05pp on a 10% draw.** Sept 4 matches within 0.09pp.

Manipulation check: email reach 76.4% / 76.0% across text arms, text reach 83.1% / 83.3% across email arms. (Note 76% email reach here against 52.6% for the whole file on the same send — RCS subscribers are a far more complete-profile population.)

Placebo: run the same four cells on a pre-period day. Sept 1 returns an interaction of **+$0.015** against Sept 7's **−$0.022**. The estimate is the size of its own noise, which is what licenses calling the interaction flat rather than negative.

### 7. The both-held cell is the binding constraint

With a 10% holdout on each of two canvases the both-held cell is **1% of the overlap** — 3,279 people on Sept 7 — and it contributes **78% of the interaction's variance**. Everything else is rounding.

- **Raise both holdouts to 20% on paired sends.** The cell goes to 4%, interaction SE falls $0.0536 → $0.0333, a 43% improvement from one send, for about $1,900 of forgone net sales.
- **~20 paired send-days** gets the interaction to a 20% detectable effect; **~9 RCS broadcasts** with holdouts gets the text main effect to 15%. One quarter at current cadence, not one year.

### 8. Still unmeasurable: iam, banner, content card alone, sms

None has a holdout isolating the channel, and the first three are structurally blocked — the experiment step sits above the channel routing, so control users carry no branch label, and an impression requires an app session. Fix forward by routing first and running an experiment step inside each branch, or by stamping a custom attribute at each routing step. Until then their Track A numbers describe their audience, not their effect. Do not promise a value for them.
