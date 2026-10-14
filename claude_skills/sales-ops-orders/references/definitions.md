# Channel values, `customer_type` and the app-user definition

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question uses `order_source` / `revenue_category` values, customer types, "loyalty orders", or app users / app purchase modes.
> Content moved verbatim from `SKILL.md` on 2026-10-14 (router split); the rules and dates inside are unchanged.

### Canonical `order_source` and `revenue_category` values (verified 2026-07-27)

Do not guess these, and do not rebuild the channel rollup yourself. Live values on a normal business day:

| `order_source` | Usual `revenue_category` | Note |
|---|---|---|
| `NULL` | In-Store (also Fundraiser, rare Third_Party) | In-store POS order |
| `Checkmate` | Third_Party | itsacheckmate aggregator feed (DoorDash/UberEats/GrubHub/Postmates) |
| `iOS` / `Android` | Digital | Native app |
| `Mobile Web` / `Web` | Digital (also Catering) | Web ordering; `Web` + Catering = online catering |
| `Outdoor Kiosk` | **In-Store** | Shared kiosk terminal — pairs with `customer_type = 'kiosk'`. Do NOT count as Digital |
| `Operator` | Catering (some Digital/In-Store) | Phone/manual order entry |
| `ezcater` | Catering | ezCater marketplace |

**Anti-pattern — do not reconstruct `revenue_category` from `destination`.** `revenue_category` is the canonical rollup and is already on `order_customer`. Hand-rolled `case when destination like '%Cater%' … end` classifiers were observed in analyst SQL 2026-07-27; they drift from the mart and are only needed on the legacy `OrderCustomer` table, which you should not be using. If a destination isn't landing in the category you expect, raise it as a `KB finding:` task instead of writing your own CASE.

### The `customer_type` rule (steward rule 2026-07-24)

`order_customer.customer_type` classifies the customer **on each order** as `person`, `kiosk`, `internal`, or `aggregator` (NULL when unidentified). **38% of identified orders belong to non-person ids** — shared outdoor-kiosk terminal accounts, employee/developer accounts, and the third-party ordering funnel (ezcater / doordash / itsacheckmate), dominated by pulse id `19192` at ~108K orders a month across 89 stores.

- **Customer-level metrics** (customer counts, frequency, retention, cohorts, LTV, first-time vs repeat) → filter `customer_type = 'person'`. Without it the numbers are materially wrong, not slightly off.
- **Sales / order / channel metrics** → do **not** filter. Those are real orders and real revenue; excluding them understates sales by ~$4.2M/month.

State which you did whenever it affects the answer.

> **⚠️ Anti-pattern — "loyalty orders" is NOT `mapped_cust_id is not null`** (observed in analyst MCP SQL 2026-08-11, labeled `loyalty_orders`). An *identified* order is not a *loyalty* order: `mapped_cust_id` is populated on kiosk, internal and aggregator orders too (38% of identified orders — the aggregator id alone is ~108K orders/month), so this definition counts DoorDash feed orders as "loyalty." Call `mapped_cust_id is not null` what it is — **identified orders** — and note that the KB has no canonical "loyalty order" metric on `order_customer` yet: loyalty *membership* lives in `claude.loyalty_user` / `account_type`, and in-store scan reporting currently lives only in the steward's QuickSight tables (`shared_datasets.qs_in_store_app_scans_by_store`, undocumented — Asana 1216920434852093). If a user asks for loyalty penetration, surface that gap instead of quietly substituting identified-order share.

**It's order-level, not customer-level** (steward decision 2026-07-27). The same `mapped_cust_id` can carry different types across its orders — June 2026: 30 ids / 108,313 orders, with `19192` splitting 107,807 `aggregator` + 196 `person`. This is deliberate: `19192` doesn't exist in `pulse.customers` (dev ticket open), so there's no reliable customer-level attribute to collapse onto. Practical effect: `count(distinct mapped_cust_id) where customer_type = 'person'` slightly overcounts. Filtering *orders* by `customer_type = 'person'` is still the correct rule. `order_sequence` applies its own customer-level guard, so sequencing and lifetime counts are unaffected.

### "App user" is a canonical customer definition (steward decision 2026-09-17, revised 2026-09-22)

An **app user** is a `person` customer with an **app purchase in the trailing 12 months**: at
least one **non-catering** `claude.order_customer` row (`is_catering = false`) with
`order_source in ('iOS', 'Android')` **or** `in_store_scan = 1`. The steward's stated assumption
is that an in-store loyalty scan is made with the app, so **a scan counts as an app purchase** for
this definition. State that assumption whenever the scan share matters to the answer.

> **Revision 2026-09-23 (steward): catering orders never make an app user.** The app supports
> catering ordering (about 8,000 iOS/Android catering orders a year), so 1,433 catering-only
> accounts (970 on consumer email domains, $3.0M of catering) were qualifying as app users through
> `order_source = 'iOS'` and sitting inside `app_orders_only`. The definition is about the in-store
> customer relationship, so `is_catering` orders are excluded from both halves of the test.

> **Revision 2026-09-22 (steward): opening the app is not using the app.** From 2026-09-18 to
> 09-21 the definition had a second test, a native-app `braze.app_sessionstart` in the trailing
> 90 days, and a customer who only browsed qualified as `session_only`. That test is retired.
> Sessions are still measured (`is_app_session_user`, `app_session_days_l90`) and still split
> app users into `purchase_and_session` vs `purchase_only`, but a session never makes someone an
> app user. Anything quoted between 09-18 and 09-21 (for example 468,851 app users on 09-17)
> included 23k to 51k session-only people and is not comparable to figures under this text.

The window anchors to `current_date('America/Denver')` unless the question names an as-of date,
in which case substitute that date and say so.

**Three app-purchase modes** (steward decision 2026-09-22, materialised as `app_purchase_mode`):
`app_orders_and_scans` (both in the 12 months), `app_orders_only`, `scans_only`. Mutually
exclusive. Report them alongside the headline when value is the question: on the window ending
2026-09-14 (`claude/app-segments-value-2026-09-22.md`, Analysis project) the both group was
107,377 customers at 9.54 orders and $219.56 a year ex catering, 23% of app users and 44% of
app-user restaurant sales; `app_orders_only` (139,891) and `scans_only` (170,412) were near
twins at 3.97 vs 4.03 orders and $96.69 vs $92.31 a year, and 81% of scans-only customers have
never placed an app order in their lifetime.

**Rules and gotchas**

- **It is a customer-level metric**, so `customer_type = 'person'` applies to the order side
  (kiosk, internal and aggregator ids never qualify). Report `count(distinct mapped_cust_id)`.
- **What is deliberately NOT in the definition:** native-app sessions (since 2026-09-22), in-app
  message or content card impressions and clicks, push opens, and any share-of-orders threshold.
  Keep those as engagement metrics measured *within* the app-user population. A "50%+ of orders
  via the app" cut is **not canonical**; if someone asks for it, present it as a labelled fork
  ("app-primary") and never substitute it for the definition above.
- **This is not "loyalty member", "digital customer" or "app orders".** Loyalty membership
  lives in `claude.loyalty_user`; "digital" is `revenue_category = 'Digital'`; and a
  channel question about **app orders** is `order_source in ('iOS', 'Android')` on orders,
  with no scan component and catering included unless the question excludes it. The
  scan-as-purchase assumption and the catering exclusion are for the customer definition only.
- **"App openers" / "installed but not buying"** is a real question but a different population:
  `is_app_session_user and not is_app_user` on `customer_attribute` (27,512 on the 2026-09-21
  build) plus session users with no identified order at all (~23k, only reachable through the
  Braze CTE below). On the window ending 2026-09-14, 49,236 such people existed, 6,228 (13%) had
  ordered on the web, $0.4M. Label it as its own thing, never as a kind of app user.
- **`platform` is the whole game on the Braze side** whenever sessions are measured.
  `app_sessionstart` is not app-only: the web SDK and landing pages log to the same table.
  Trailing 90 days measured 2026-09-17, `cafe_zupas` workspace: **web 1,132,440 users**,
  ios 257,285, android 63,241, landing_page 3,454. Braze platform values are **lowercase**
  (`'ios'`, `'android'`); the order-mart values are **mixed case** (`'iOS'`, `'Android'`). Join
  on `safe_cast(s.external_user_id as int64) = oc.mapped_cust_id`, never on email.
- **Materialised on `sales_ops.customer_attribute` since 2026-09-18, revised 2026-09-22:**
  `is_app_user`, `app_user_type` (`purchase_and_session` / `purchase_only` / NULL),
  `app_purchase_mode` (`app_orders_and_scans` / `app_orders_only` / `scans_only` / NULL),
  `is_app_purchaser` (now identical to `is_app_user`), `is_app_session_user`, `app_orders_l12m`,
  `in_store_scans_l12m`, `app_session_days_l90`, the three `last_*_date` columns and two lifetime
  counts, rebuilt daily at 05:20 MT with windows anchored on `attribute_asof_date`. Use the table
  for segmentation of known customers; use the query below when the as-of date is not yesterday.
  **`is_app_user`, `app_user_type` and `app_purchase_mode` are also on `claude.order_customer`**,
  so standard users can split orders by app-user status directly: all three are **NULL on
  unidentified and non-person orders**, so filter `oc.is_app_user is true` and pair any "not an
  app user" read with `oc.customer_type = 'person'`.
- **The scan-as-app assumption, measured 2026-09-17:** 8.1% of customers who scanned in-store
  in the trailing 90 days had no native-app session in the window, versus 1.3% of customers
  who placed an app order (the Braze identification baseline). About 7,000 scanners are
  therefore counted as app users without the app being visible in Braze. Intentional; state it
  when the scan share drives the answer.
- **Pulse feed gaps blank the app-order half.** `order_source` comes from `pulse.orders`; when
  that feed stalls (2026-09-15 to 09-21) app orders read as unidentified in-store orders and only
  scans survive, so app-user counts and `app_purchase_mode` drift toward `scans_only` until the
  marts heal. Check `countif(pulse_order_id is not null)` by day before quoting a recent window.

**Canonical query** (one row per app user; the session CTE is descriptive and does not add rows):

```sql
with app_purchasers as (
select
oc.mapped_cust_id as mapped_cust_id
, countif(oc.order_source in ('iOS', 'Android')) as app_orders
, countif(oc.in_store_scan = 1) as in_store_scans
, max(oc.business_date) as last_app_purchase_date
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 12 month)
and oc.mapped_cust_id is not null
and oc.customer_type = 'person'
and oc.is_catering = false
and (oc.order_source in ('iOS', 'Android') or oc.in_store_scan = 1)
group by oc.mapped_cust_id
)
, app_sessions as (
select
safe_cast(s.external_user_id as int64) as mapped_cust_id
, count(distinct s.event_date) as session_days
, max(s.event_date) as last_session_date
from `marketing-data-442316`.braze.app_sessionstart s
where 1=1
and s.event_date >= date_sub(current_date('America/Denver'), interval 90 day)
and s.workspace = 'cafe_zupas'
and s.platform in ('ios', 'android')
and safe_cast(s.external_user_id as int64) is not null
group by 1
)
select
ap.mapped_cust_id as mapped_cust_id
, ap.app_orders as app_orders
, ap.in_store_scans as in_store_scans
, case
	when ap.app_orders > 0 and ap.in_store_scans > 0 then 'app_orders_and_scans'
	when ap.app_orders > 0 then 'app_orders_only'
	else 'scans_only'
	end as app_purchase_mode
, se.mapped_cust_id is not null as is_app_session_user
, case when se.mapped_cust_id is not null then 'purchase_and_session' else 'purchase_only' end as app_user_type
, coalesce(se.session_days, 0) as session_days
, ap.last_app_purchase_date as last_app_purchase_date
, se.last_session_date as last_session_date
from app_purchasers ap
	left join app_sessions se
	on se.mapped_cust_id = ap.mapped_cust_id
```

Headline: `count(*)` over that result is the app-user count. The join is a `left join` on purpose
(it was a `full outer join` under the 2026-09-18 text); the partition filters are constant
expressions on purpose (a value pulled from a CTE would not prune either table).
