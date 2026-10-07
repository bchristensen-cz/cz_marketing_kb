# Repeat-rate, first-order and time-to-second-order cohorts

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question is about new customers, repeat rate, retention, lapsed or reactivated customers, or any cohort.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Repeat-rate and time-to-second-order cohorts (rules added 2026-08-13)

These are the most-requested customer questions in the query log and the easiest to get
quietly wrong. Three rules, all observed being broken in a live analyst template on
2026-08-13.

### 1. A fixed-window repeat rate is only quotable for cohorts that have finished the window

**Right-censoring is the single largest error source in this metric class.** A 90-day repeat
rate for a cohort whose first order was three weeks ago is not a low repeat rate — it is an
unfinished measurement. Pooling matured and unmatured cohorts into one number understates it
badly, and the result looks completely plausible.

Measured 2026-08-13 on `claude.order_customer` (person only, stores 1111/999 excluded),
90-day second-order rate by first-order cohort month:

| Cohort month | Days elapsed for the newest member | Cohort n | 90-day repeat | 30-day repeat |
|---|---|---|---|---|
| 2026-04 | 105 | 28,826 | **33.6%** | 23.1% |
| 2026-05 | 75 | 27,422 | 33.2% | 23.1% |
| 2026-06 | 44 | 25,887 | 28.2% | 22.0% |
| 2026-07 | 13 | 32,806 | 16.2% | 15.7% |
| 2026-08 | 0 | 15,007 | **7.7%** | 7.7% |

**The tell that a window is unfinished is the 90-day and 30-day columns converging** (7.7 = 7.7):
when a longer window stops exceeding a shorter one, the window hasn't elapsed and neither
number is real.

> **⚠️ But do NOT read this table as "the decline is just elapsed time" — that was the first
> conclusion drawn here on 2026-08-13 and it was wrong.** Holding exposure constant at 7 days
> (first orders on or before 2026-08-06) and splitting on whether the first order was a guest
> order, the identified-customer rate **rises**: 2026-04 **11.0%** (n=28,822) → 07 **12.4%**
> (n=14,921) → 08 **14.0%** (n=3,208). Guest first orders repeat at roughly a third of that —
> **4.0%** in July (n=17,885) and **4.5%** in August (n=3,234).
>
> The headline decline is therefore a **composition change, not a behaviour change and not only
> censoring**: guest first orders are **54.5%** of the July cohort and **50.2%** of August's,
> and they barely repeat. See the structural cause in the next box. Censoring is real and still
> disqualifies immature cohorts — it just isn't what drives this particular table.
>
> Generalisable lesson: **when a rate falls, test composition before attributing it to the
> measurement.** Two plausible mechanisms were available here (unfinished window, changed mix)
> and the obvious one was not the operative one. An equal-exposure split settles it cheaply.

> **🚨 Guest checkout manufactures first-time customers — this distorts every cohort and
> new-customer count** (measured 2026-08-13). **17,887 of July's 19,273 guest orders (92.8%)
> carry `customer_order_count = 1`.** A guest order generally creates a fresh `mapped_cust_id`,
> so nearly every one presents as a brand-new customer, and a customer id that exists for a
> single order is *structurally incapable* of recording a second one. Consequences:
>
> - **"New customers" is inflated.** The July first-order cohort grew **27%** (25,887 → 32,806)
>   while total July orders **fell** (713,137 → 683,228) — more new customers on fewer orders is
>   the signature of identity fragmentation, not acquisition.
> - **Repeat and retention rates are mechanically depressed** from 2026-07-01 onward, by an
>   amount that tracks guest-checkout share rather than anything customers did.
> - **Never present a first-time-vs-repeat or cohort trend spanning 2026-07-01 without splitting
>   on `is_guest_order`** (or excluding guest first orders and saying so). A blended series across
>   that date is not comparable to itself.
>
> Root cause is the CRM identity-hygiene problem already scoped in the backlog: guest checkout
> took duplicate-id creation from ~28 to ~280 per business day (21.9% of new ids). Until
> `customer_id_map` / `canonical_cust_id` lands, `mapped_cust_id` is not a stable person key for
> post-2026-07 cohorts.
>
> **⚠️ And do not go to `pulse.*` for the guest's email — that is a wall breach, not a workaround**
> (observed again 2026-08-28, 10:04–10:18 MT: an analyst MCP session joined `pulse.order_customers` /
> `pulse.customers` in five queries to recover guest-typed emails, because guest web orders carry
> **NULL `email` and NULL `mapped_email`** on the order marts — no mart column holds the
> guest-supplied address yet, Asana 1217645882648277). **Recurred at scale 2026-08-31**: ~25 MCP
> queries in one analyst session ran a guest first-order cohort keyed on `lower(pulse.order_customers.email)`
> and joined it forward to Braze push/SMS engagement for guest-conversion lift — and the workaround
> doesn't even scale (two of the runs were killed at the 3-minute MCP timeout). The steward has an
> email-based guest identity mapping built and validated (full history, powers the Guest Checkout
> Relaunch dashboard); it is **pending deployment to the `claude` dataset** (Asana 1218000084425507).
> Until it deploys, guest-identity questions (which email placed this guest order, guest→account
> conversion by email, guest repeat behaviour across identities) are **unanswerable from the
> marts — say so and log the question as a KB finding rather than crossing the wall.**
>
> **⚠️ A third `pulse.customers` purpose appeared 2026-09-11 07:09 MT, and this one the marts
> already answer.** Two MCP queries (current year + a `date_sub(current_date(), interval 364 day)`
> YoY arm) read `pulse.customers.created_at` to build "contacts created in week W who have never
> ordered". **`claude.loyalty_user.registered_date` is the signup date** and joins to
> `order_customer.mapped_cust_id` via `sm_external_user_id` — the whole cohort runs inside
> `claude.*` for ~0.1 GiB. Recipe, measured numbers and the two caveats (it is a *loyalty* signup,
> not a Pulse contact; the newest weeks are right-censored) are in **`sessionm-loyalty`, "Signup
> cohorts"**. Reach for that before you reach for `pulse.*`.

Rules:

- **Only include cohorts where `date_diff(current_date, cohort_end, day) >= window_days`.** For a
  90-day metric as of 2026-08-13, the newest quotable cohort is first orders on or before
  **2026-05-15**. Truncate the cohort list — don't caveat it and ship it anyway.
- **Never let a cohort window end in the future.** Observed 2026-08-13: an analyst template
  hard-coded `between date('2026-06-15') and date('2026-09-13')` — a month past today — so the
  cohort was inherently a third unmeasurable, and the single pooled rate it returned blended
  28% cohorts with 8% cohorts.
- If someone wants recent-cohort signal, give them a **shorter window that has elapsed** (7- or
  14-day repeat) rather than a censored 90-day figure. Say which window you used.

> **🚨 A year-over-year repeat rate must censor BOTH years identically (observed 2026-08-25).**
> The live analyst template grew a YoY arm and got this exactly backwards. The LY cohort anchors
> on `date_sub(current_date(), interval 364 day)` and its 91-day forward window has **fully
> elapsed**; the CY cohort's forward window runs to `date_add(current_date(), interval 91 day)`
> — **91 days into the future**. So a matured LY number is being compared against a
> right-censored CY number.
>
> CY reads low *by construction*, the gap is entirely an artefact, and the output is worse than
> a plain wrong number: it arrives pre-loaded with a story ("repeat rate is down versus last
> year") that a reader has no way to distinguish from a real decline.
>
> **Rule: apply the same elapsed-days test to every year in the comparison, and truncate both to
> the shorter one.** For a 90-day metric, if CY's newest quotable cohort is 2026-05-15, then LY's
> cohort must be cut at the matching relative position too — not left to run to its natural,
> fully-matured end. Then say in the answer which cohort end-dates each year used.
>
> Same tell as the single-year case: **if the longer window stops exceeding the shorter one in
> either year, that year is unfinished.** Check it per year, not once for the query.
>
> (Padding a forward-looking CTE's window past today is harmless on its own — there are no rows
> there. It becomes a defect the moment the two sides of a comparison are padded differently.)

### 2. 🚨 HARD RULE: never scan history to find a customer's first order (steward rule 2026-09-09)

**"First order ever", "new customer", "days to second order", "lapsed / reactivated" are
already columns.** There is no question in this family that needs a `min(...) group by
customer` over the table, and every such scan is billed in full because the only partition
filter it can carry is "everything".

| Question | Use this — one bounded pass | Never this |
|---|---|---|
| New customers in a window | `customer_order_count = 1` with `business_date between @s and @e` | `min(business_date) group by mapped_cust_id` over history |
| Their first-order date / store / channel | the `= 1` row itself (it *is* the first order) — or `first_order_date` | `array_agg(... order by business_date limit 1)` over history |
| Second order within N days | `customer_order_count = 2 and days_since_prev_order <= N` and `date_sub(business_date, interval days_since_prev_order day) between @s and @e` (recovers the cohort date from the second order — no self-join) | `eord`/`sec` self-join, 470-day cohort scanned from 2023 |
| Lifetime orders / tenure | `lifetime_order_count`, `first_order_date`, `customer_tenure_days` (as-of yesterday) | `count(*) over (partition by …)` over history |
| Lapsed / reactivated | `days_since_prev_order >= 180` on the reactivating order | `lag()` over full history |

**Why a history scan cannot even beat the columns:** `order_sequence` and
`customer_attribute.first_order_date` both start on **2023-03-06** (measured 2026-09-09 —
`min(business_date)` / `min(first_order_date)`; the identity mapping has no earlier floor). A
hand-rolled `min()` over `order_customer` from any date **is the same population**, just paid for
again. The analyst tracker that scans `between date('2023-03-06') and current_date()` is not
"going deeper than the mart" — it is re-deriving the mart's own floor.

**Cost, measured on the query log (2026-08-31 → 09-08):** the `with eord as (…)` tracker ran
**70× on 2026-09-08 at ~2 GiB per execution ≈ 140 GiB**, and **188 of the analyst's 2,350
queries since 08-10 reached back 3+ years (323 GiB)** — all but ~15 of them were first-order
floors, not questions about old years. The bounded shapes above read the cohort window only
(tens of MiB).

> **The rule landed 2026-09-09 and the tracker still ran on 2026-09-11** (07:09:35 MT, one
> execution, `with eord as (…)` scanning `between date('2023-03-06') and current_date()`). Once,
> not seventy times, so the rule is working — but it is not self-enforcing, and the shape survives
> in whatever template the analyst is pasting from. Rewriting that template at source is the open
> fix (Asana 1217645792289097); until it lands, expect this shape to reappear and replace it with
> the bounded form rather than just noting it.
>
> **Related, same tracker, measured 2026-09-11/13: the metric drifts between runs.** The
> "new customers and banked second orders since 2026-06-15" question ran nine times over the two
> days with **four different definitions** — `countif(customer_order_count = 1)` in some runs and
> `count(distinct oc.mapped_cust_id)` in others; `days_since_prev_order <= 90` sometimes inside the
> `or` branch and sometimes only in the outer predicate (which changes which first orders enter the
> cohort at all); and "banked through yesterday" written three ways (`business_date <
> current_date`, `<= date_sub(current_date, 1)`, `< date_sub(current_date, 1)` — the last is two
> days ago, not one). Same question, different answers, no way for the reader to tell which run
> they got. **Name the definition once and quote the boundary in the answer**: cohort = first
> orders in [start, end], banked = `customer_order_count = 2 and days_since_prev_order <= N` with
> the cohort date recovered by `date_sub(business_date, interval days_since_prev_order day)`, and
> "through yesterday" = `business_date <= date_sub(current_date('America/Denver'), interval 1 day)`.
> A canonical first-order-cohort mart is the durable fix (Asana 1217493799685485).
>
> One harmless artefact in the same template, so nobody re-derives it: the filter
> `lower(coalesce(oc.mapped_email, oc.email)) <> 'nan'` matches **nothing**. Measured 2026-09-14
> over 2026-06-15 → 09-13, stores 1111/999 excluded, 2,095,686 orders: **zero** `'nan'` values in
> `email`, `mapped_email`, or the coalesce. It is a pandas-export leftover, not a real sentinel.

`customer_order_count = 1` on `claude.order_customer` already marks a customer's first order,
and `days_since_prev_order` on the `= 2` row already gives days-to-second — both folded in
from `order_sequence`, both person-filterable via `customer_type`. Use them.

```sql
-- New customers by week, and % with a 2nd order within 30 days — ONE pass, cohort window only
select
date_trunc(oc.business_date, week(monday)) as cohort_week
, countif(oc.customer_order_count = 1) as new_customers
, countif(oc.customer_order_count = 2 and oc.days_since_prev_order <= 30) as second_within_30
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between @cohort_start and date_add(@cohort_end, interval 30 day)
and (oc.customer_order_count = 1
	or (oc.customer_order_count = 2
		and date_sub(oc.business_date, interval oc.days_since_prev_order day) between @cohort_start and @cohort_end))
and oc.customer_type = 'person'
and oc.is_catering = false
group by 1
order by 1
```

Caveats that travel with the columns: `customer_order_count` counts **all** of a customer's
orders (catering, store 1111) before the view filters them, so a visible sequence can skip
numbers; `lifetime_*` / `first_order_date` are as-of yesterday; and only cohorts whose window
has closed are quotable (§1). If a question truly needs pre-2023-03-06 history, say that the
identity mapping does not exist there and log it as a gap — do not scan.

The anti-pattern (live 2026-08-13, ~8 queries): a `min(order_datetime) group by email` CTE over
`sales_ops.order_customer` **with no `business_date` filter at all** — an unbounded scan of a
**13.2 GiB / 50.7M-row** table (logical size, measured 2026-08-13; it is rebuilt hourly, so
re-measure before quoting), repeated per query, to re-derive a column that already exists. Deriving
"first ever order" *feels* like it needs full history, which is exactly why this template never
got a partition filter. It doesn't: `customer_attribute.first_order_datetime` is precomputed per
customer with no partition column to filter, and the sequencing columns are on the order grain.

> ⚠️ The folded sequencing columns (`customer_order_count`, `days_since_prev_order`) live on
> **`claude.order_customer`**, not on `sales_ops.order_customer` — selecting them there fails with
> `Name customer_order_count not found inside oc`. On the `sales_ops` side they're in
> `sales_ops.order_sequence`.

Also: cohorts keyed on `lower(coalesce(mapped_email, email))` instead of `mapped_cust_id` are a
recurring defect (2026-08-11, -12, -13). Email is not the canonical identity key —
`mapped_cust_id` is — and an email-keyed cohort silently merges the duplicate-identity clusters
the CRM hygiene project exists to resolve. Emails are now lowercased at build, so the old
`lower()` justification for keying on email no longer applies either.

**And there is a second, sharper reason (steward 2026-08-24): `oc.email` is the ORDER email, not
the customer's email.** A guest may give us any address at checkout so we can send updates about
*that order*; the canonical customer email is `pulse.customers.email`, which reaches the mart only
as the first fallback of `mapped_email`. So `email` is *always* user-typed, and `mapped_email` is
canonical only when the customer row has one — on **19,168 of 136,653 July 2026 `person` orders
(14.0%)** it does not, and `mapped_email` is a typed order/booking address instead. Of the 17,842
customers behind that 14%, **7,315 have an order email equal to some `pulse.customers.email`** and
**143** of those addresses are owned by more than one id. An email-keyed cohort does not merely
merge known duplicates — it can merge strangers on an address the account never claimed. Use
`mapped_cust_id`. Full measurement in `data_dictionaries/sales_ops.order_customer.md` →
"Order email vs canonical email".

### 3. Customer cohorts require `customer_type = 'person'`

Every metric in this section is customer-level, so hard rule 6 applies without exception. A
cohort built without it pulls the aggregator id (~108K orders/month) and shared kiosk terminals
into "new customers." Observed missing from all 12 cohort queries on 2026-08-13.

### 4. 🚨 `net_sales between 3 and 200` is NOT a canonical filter — it is an undeclared population change (observed 2026-08-27)

**32 of one analyst's 156 MCP queries on 2026-08-27** carried
`and o.net_sales between 3 and 200` on the order CTE feeding campaign-lift and repeat-rate
measurements. It appears nowhere in this KB, has never been ratified by the steward, and is
never mentioned in the answers it produces. Measured on `claude.order_customer`,
2026-08-01 → 08-26, person / non-catering / stores 1111+999 excluded (199,451 orders):

| | Orders | Share |
|---|---|---|
| `net_sales < 3` | 7,420 | 3.72% |
| `net_sales > 200` | 236 | 0.12% |
| **Excluded in total** | **7,656** | **3.84% of orders, 1.32% of net sales** |

Two separate problems, and the small headline percentage is what hides them:

1. **It is not an outlier filter, it is a segment filter.** The `< 3` tail is 97% of what it
   removes, and a sub-$3 order is overwhelmingly a **fully-discounted or fully-redeemed
   order** — exactly the loyalty and offer behaviour a campaign test is trying to detect.
   Dropping it removes the treated group's most likely response before the lift is computed.
   The `> 200` tail is 236 orders and does essentially nothing; the bound is doing no real
   outlier work in either direction.
2. **It is applied asymmetrically by accident.** In the observed template the bound sits on
   the orders CTE only, so it silently reshapes both the numerator and the denominator of a
   rate, while the Braze-side arm definition is untouched. If one arm redeems more, that arm
   loses more orders.

**Rules:** don't add a value bound to an order population unless the question asked for one.
If a genuine outlier concern exists, say so, bound only the tail you can justify, and **state
the bound and its row count in the answer**. A filter that changes the population and is not
named in the output is indistinguishable from a wrong number to whoever reads it. If someone's
saved template carries this bound, that is a rewrite, not a caveat (same disposition as the
`lower(email)` bridge above).
