# CRM Identity Hygiene — Cleanup, Mapping & Merge Strategy

**Status:** DESIGN / PROPOSED — nothing built or deployed. Drafted 2026-07-28 (steward: Brent).
**Companion artifacts:** `sql/sales_ops.customer_id_map.sql`, `data_dictionaries/sales_ops.customer_id_map.md`

---

## 1. The problem in one paragraph

Guest checkout went live **2026-07-01**. Because Pulse mints a new `customer_id` for every
guest checkout, one human now generates a new customer id — and therefore a new Braze profile —
every time they order without signing in. Duplicate-id creation jumped from **~28/business day
to ~280/business day**, and from **2.6–4.2% of new customer ids to 21.9%**. Separately, the
website SDK has been creating UUID-keyed Braze profiles since 2023-05-12, and Braze now holds
**4.18M profiles against 1.37M real identified customers**. This document defines a canonical
identity layer in BigQuery, a one-time cleanup, and a daily loop that keeps Braze collapsed onto
one profile per human — with every `124 → 123` decision recorded permanently and reversibly.

---

## 2. What is actually broken (measured 2026-07-28)

All figures: `sales_ops.order_customer` `business_date` 2023-03-01 → 2026-07-25,
`store_id <> 1111`, `customer_type = 'person'`, `mapped_cust_id is not null`. Braze figures:
`braze.users`.

### 2.1 Duplicate customer identities

| Ids sharing one email | Emails | Ids | Surplus ids | Orders | Net sales |
|---|---|---|---|---|---|
| 1 | 1,202,549 | 1,202,549 | 0 | 6,435,792 | $180.7M |
| 2 | 58,645 | 117,290 | 58,645 | 532,934 | $27.3M |
| 3 | 9,363 | 28,089 | 18,726 | 115,200 | $3.80M |
| 4–5 | 3,881 | 16,633 | 12,752 | 64,483 | $1.78M |
| 6–10 | 1,075 | 7,517 | 6,442 | 29,185 | $0.71M |
| 11–25 | 85 | 1,114 | 1,029 | 4,380 | $0.08M |
| 26+ | 5 | 150 | 145 | 494 | $0.01M |

- **73,037 email clusters** hold more than one customer id.
- **97,721 surplus ids** to collapse. **539,034 orders / $21.5M net sales** currently sit on ids
  that should not be counted as separate customers.
- Deduplicating takes the person customer count from **1,373,206 → 1,275,485 (−7.1%)**. Every
  frequency, repeat-rate, retention and LTV number is wrong by roughly that much *in the
  conservative direction* — we systematically understate loyalty.
- **62,611** of the surplus ids have loyalty activity, so this is not purely an anonymous-guest
  problem.

### 2.2 Guest checkout is the accelerant — clean step change on 2026-07-01

| Month id created | New person ids | Dup of existing email | % dup |
|---|---|---|---|
| 2026-02 | 26,202 | 801 | 3.1% |
| 2026-03 | 28,590 | 847 | 3.0% |
| 2026-04 | 28,834 | 857 | 3.0% |
| 2026-05 | 27,429 | 716 | 2.6% |
| 2026-06 | 25,890 | 741 | 2.9% |
| **2026-07** | 26,315 | **5,764** | **21.9%** |

Daily detail confirms a hard switch, not a drift: 2026-06-30 = 32 dup ids, 2026-07-01 = 307,
and every business day since has run 187–328. **5,379 of July's 5,764 dup ids have exactly one
order** — the signature of guest checkout, not of real new customers.

At ~270/business day this adds **~5,700–8,200 duplicate ids per month** going forward.

### 2.3 Braze profile bloat

| Measure | Value |
|---|---|
| Profiles | 4,179,315 |
| Distinct emails | 1,746,999 |
| Profiles with **no** email | 2,364,333 (57%) |
| Emails on >1 profile | 55,889 emails / **67,983 surplus profiles** |
| Profiles created June 2026 | 412,479 |
| Profiles created July 2026 | 363,395 |
| …of those 775,874, with an email | **55,065 (7%)** |

93% of current Braze profile creation carries no email. Breakdown of profiles created since
2026-06-01:

| Shape | Email? | Profiles | Notes |
|---|---|---|---|
| numeric `external_id` | no | 618,358 | app = "Cafe Zupas Website"; no device, no attributes |
| UUID `external_id` | no | 102,451 | app = "Cafe Zupas Website"; nothing else on the profile |
| numeric `external_id` | yes | 55,065 | the real ones |

### 2.4 UUID-keyed profiles (283,825 total, first seen 2023-05-12, still being created)

| Bucket | Profiles | Braze action |
|---|---|---|
| No email, no phone, no name, no events, no purchases, no aliases, no devices | 168,570 | delete |
| Email → matches an existing integer profile or a person customer | 47,521 | rename or merge onto the integer id |
| Email → no match anywhere (57,024 still `subscribed`) | 67,734 | **open decision — see §9** |

Every email-bearing UUID profile was created **before 2026-01-01**. All 2026 UUID creation is
email-less. So the mappable UUID population is a fixed legacy backlog; the ongoing flow is pure
junk and should be stopped at the source.

---

## 3. Key decision: keep email as the match key, keep `mapped_cust_id` as the canonical key

These are two different jobs and it matters that they stay separate.

**Canonical key = `mapped_cust_id` (integer).** Unchanged. It is already
`coalesce(pulse_customer_id, sm_external_user_id)`, it is already the Braze `external_id`, it is
already clustered on in `order_customer`, and every existing feed is keyed on it. We are not
introducing a new surrogate key — we are choosing *which existing id wins*.

**Match key = normalized email.** Confirmed as the right call:

- It links **99%+** of the guest-checkout duplicates by construction (that is how they were
  detected).
- Only **4,304 ids (0.3%)** have ever carried more than one email, so email is stable per id.

> **⚠️ Amended 2026-08-24 — say *which* email.** The steward's rule: `order_customer.email` is the
> **order** email (a guest may give any address for order updates); the canonical customer email is
> **`pulse.customers.email`**. The match key is the canonical one. This matters because
> `mapped_email` — the column this plan actually reads — is canonical only when the customer row
> has an email, which in July 2026 was **117,485 of 136,653 `person` orders (86.0%)**. On the other
> **19,168 (14.0%)**, spanning **17,842 customers in one month**, `mapped_email` is a *typed*
> order/booking address.
>
> Measured blast radius for those 17,842: **7,315 have an order email that equals some
> `pulse.customers.email`**, and **143** of those addresses are owned by more than one customer id.
> Matching on them is not the intended "merge the guest-checkout duplicate back onto its account" —
> it is merging on an address the surviving account never claimed, and §7.4's phone-review
> reasoning ("a wrong merge is unrecoverable in Braze") applies with equal force.
>
> **Open before any merge runs:** decide whether a cluster whose only evidence is a *typed order
> email against an email-less pulse account* auto-merges, or goes to the §7.4 review queue. Not yet
> decided. Also note `primary_email` exists on `pulse.customers` and was ruled **not** canonical
> the same day — do not quietly widen the key to `coalesce(primary_email, email)`.
- The obvious alternatives were tested and rejected:
  - **Loyalty id (`sm_external_user_id`)** — useless here. Of 5,752 July duplicate ids, only 418
    carry any loyalty id and exactly **1** shares one with the surviving id. Guest checkout means
    not signed in, so there is no loyalty link to bridge on.
  - **Phone** — 5,707 of 5,752 have a phone and 5,018 (87%) share it with the survivor, so it is
    a genuinely strong signal. It is **deliberately not** an auto-merge key: households share
    phone numbers, and a wrong merge is unrecoverable in Braze. Phone-only matches are logged to
    a review queue instead (§7.4).
  - **Composite key (email + phone, email + name, etc.)** — a composite makes the key *narrower*,
    which creates duplicates rather than resolving them. Two rows for the same person with the
    same email and a missing phone would fail to match. Composites are the wrong tool for entity
    resolution; layered match tiers are the right tool.

**Normalization rule (canonical, use verbatim):** `lower(trim(email))`. Nothing else — no
Gmail dot-stripping, no `+tag` removal, no domain aliasing. Those transforms are defensible but
they are *inferences*, and if we ever want them they belong in an explicit tier-2 rule with its
own review queue, not baked into the tier-1 key.

#### The `lower()` is not cosmetic — it is worth 5,604 clusters (measured 2026-07-29)

Anyone tempted to simplify the key to a raw email comparison should see this first. Casing
across the identity sources:

| Source | Non-null emails | NOT lowercase | Distinct raw | Distinct lowered | Casing dupes |
|---|---|---|---|---|---|
| `braze.users.email` | 1,817,431 | **0** | 1,748,877 | 1,748,877 | **0** |
| `sessionM.users.email` | 1,775,708 | **0** | 1,769,996 | 1,769,996 | **0** |
| `pulse.customers.email` | 1,781,555 | **155,743 (8.7%)** | 1,746,151 | 1,742,168 | **3,983** |

**Pulse is the only system that doesn't normalize.** Braze and SessionM are already 100%
lowercase, so every casing duplicate in the warehouse originates in Pulse and flows through
`order_customer.mapped_email`, which the build does **not** lower (see the gotcha in
`data_dictionaries/sales_ops.order_customer.md`).

Impact on this plan's clustering, measured over person customers with an email:

| Measure | Value |
|---|---|
| Person customers with an email | 1,375,606 |
| Distinct **raw** `mapped_email` | 1,283,037 |
| Distinct **lowered** `mapped_email` | 1,277,400 |
| Clusters merged by lowering alone | **5,637** |
| Emails where **casing alone** splits one person across several `mapped_cust_id`s | **5,604** |
| Emails with multiple `mapped_cust_id`s from *any* cause | 73,429 |

So **7.6% of all duplicate clusters (5,604 of 73,429) exist purely because of letter case.** A
case-sensitive match key would silently fail to merge every one of them, and — worse — would
report success, because the clusters it *did* find would all look valid. This is the single
cheapest 7.6% of the duplicate problem to solve, and it is already in the rule above. Keep it.

> **✅ Fixed at source 2026-07-29.** `order_customer` now applies `lower()` to `mapped_email`
> and the whole table was rebuilt. Verified: 0 non-lowercase values, and
> `count(distinct mapped_email)` = `count(distinct lower(mapped_email))` = 1,029,384 (365d),
> so the 17,943 phantom identities are gone. The input to this plan is now clean; the
> `lower()` in the rule above is retained as a guarantee rather than a repair.
>
> **`trim()` verified unnecessary but harmless** (2026-07-29): `pulse.customers.email` has
> **zero** rows with leading/trailing whitespace, and `count(distinct lower(email))` already
> equals `count(distinct lower(trim(email)))` at 1,742,168. Keep `trim()` in the canonical rule
> as belt-and-braces — it changes no clusters today and costs nothing.

**Survivor rule:** earliest `first_order_date`, tie-broken by lowest `mapped_cust_id`. Once
assigned, a canonical id is **sticky** — it never changes because a new id appeared (§6.2).

---

## 4. Architecture: BigQuery owns identity, Braze consumes it

```
  brink / pulse / sessionM
            │
            ▼
  sales_ops.order_customer            (hourly, unchanged — no dependency on the map)
            │
            ▼
  sales_ops.customer_id_map           ← THE crosswalk. Sticky, incremental MERGE.
            ├── customer_id_map_history      (append-only lineage: every 124→123 ever)
            └── braze_identity_action_log    (every API call, request + response)
            │
            ├──► claude.* authorized views   (analysts get canonical_cust_id for free)
            ├──► sales_ops.customer_attribute (aggregate on canonical_cust_id, not cust_id)
            └──► Braze worker (Cloud Run)    (merge / rename / remove / delete)
```

Two non-negotiables in this shape:

1. **`order_customer` does not join the map.** The map is derived *from* `order_customer`, so
   putting `canonical_cust_id` in the hourly build would be circular. Canonicalization happens
   one layer up, in the `claude` views and in `customer_attribute`. No rebuild of the 50M-row
   fact table is required to ship this.
2. **Braze is downstream, never a source of identity truth.** Braze merges are not reflected in
   Currents (§8.3), which is where `braze.*` comes from — so BigQuery has to hold the lineage or
   it is lost.

---

## 5. Tables

Full DDL in `sql/sales_ops.customer_id_map.sql`. Summary:

| Table | Grain | Purpose |
|---|---|---|
| `sales_ops.customer_id_map` | 1 row per `cust_id` ever seen | current mapping: `cust_id → canonical_cust_id` |
| `sales_ops.customer_id_map_history` | 1 row per mapping assignment | append-only. `valid_from` / `valid_to`, `change_reason`. **This is the "never lose that 124 → 123" guarantee.** |
| `sales_ops.braze_identity_action_log` | 1 row per API call attempt | action, payload, HTTP status, response, batch, attempt #. Brent's "tracked in GCP" requirement. |
| `sales_ops.braze_uuid_profile_map` | 1 row per UUID `external_id` | UUID → resolved integer id, or `no_map` |
| `sales_ops.v_braze_identity_queue` | view | what the worker should do next, already batched |

Singletons get a row too (`cust_id = canonical_cust_id`, `match_key = 'singleton'`). A map that
covers only duplicates forces every consumer to write a `coalesce`, and someone will forget.

---

## 6. Mapping logic

### 6.1 Clustering

```
normalized_email = lower(trim(mapped_email))
cluster          = all person mapped_cust_ids sharing one normalized_email
email per id     = most recent non-null mapped_email, ordered by order_datetime desc,
                   brink_order_id desc   (same tie-break convention as order_sequence)
```

Ids with no email at all (844 SessionM in-store scanners) are singletons by definition — they
cannot be clustered and must not be guessed at.

### 6.2 Stickiness — the rule that makes this safe

A canonical id, once assigned and acted on in Braze, is a **published fact**. Re-deriving the
whole map from scratch each day would let canonical ids drift, and a drifting canonical id means
Braze merges pointing in contradictory directions on successive days — unrecoverable.

So the build is an incremental `MERGE`, not a `create or replace`:

1. New id, new email → becomes its own canonical.
2. New id, email already in the map → adopts the **existing** canonical, regardless of dates.
3. Two existing clusters collide (an id's latest email changes to another cluster's email) →
   the **older canonical wins**; the losing canonical and its whole cluster are re-pointed, and
   every affected row gets a history entry with `change_reason = 'cluster_absorbed'`.
4. Chains are resolved recursively so `canonical_cust_id` is always a root. An id that points at
   a non-canonical id is a build failure, not a valid state (assertion in §10).
5. An id already merged away in Braze can **never** become a canonical again
   (`braze_state = 'merged_away'` blocks promotion). Braze merges are irreversible; the map has
   to respect that.

This is the opposite of the `customer_attribute` decision (full rebuild daily, deliberately).
The difference: `customer_attribute` holds *derived measures*, which should be recomputed. The
map holds *decisions already executed against an external system*, which must not be.

---

## 7. Initial cleanup (one-time backfill)

### 7.1 Phase 0 — build and freeze the map (no writes to Braze)

Run the build, review, publish. Reviewable output: 73,037 clusters, 97,721 planned merges,
plus these sanity gates before anything touches Braze:

- Clusters of ≥11 ids (85 + 5 = 90 clusters, 1,174 ids) get **eyes on them**. A single email with
  26+ customer ids is more likely a shared/ops address than one very loyal human, and those are
  exactly the merges you cannot undo.
- Reconcile: sum of orders/net sales per canonical id must equal the sum over its members. The
  map redistributes, it never creates or destroys.

### 7.2 Phase 1 — Braze actions for the 97,721 duplicate ids

The right API call depends on which side already has a profile. Measured cross-tab:

| Survivor has profile | Loser has profile | Action | Loser ids |
|---|---|---|---|
| no | **yes** | `POST /users/external_ids/rename` — rename loser's `external_id` to the survivor id | **54,469** |
| no | no | none (profile will be created by the attribute export) | 28,748 |
| yes | no | none (loser never reached Braze) | 8,635 |
| yes | yes | `POST /users/merge` — merge loser into survivor | 5,869 |

The dominant case is counter-intuitive and worth stating plainly: **the surviving customer
usually has no Braze profile while the duplicate does.** That is the pre-November-2023 sync gap
already documented in `sales_ops.customer_attribute.md` — survivors are old customers Braze never
received; losers are recent guest-checkout ids that Braze does receive.

`rename` is the correct instrument for that 54,469: it moves the existing profile (with all its
engagement history) onto the canonical id, costs **no data points and no MAU**, and leaves the old
id alive as a *deprecated* external id so any in-flight feed keyed on it keeps working. Clean up
the deprecated ids later with `/users/external_ids/remove` — **never** `/users/delete`, which
would destroy the profile.

**Ordering within a cluster matters.** If the survivor has no profile and two or more losers do:
rename the richest loser profile onto the survivor id **first**, then merge the remaining loser
profiles into it. Reverse that order and the rename fails with "new_external_id is already in
use."

Call volume: (54,469 renames ÷ 50) + (5,869 merges ÷ 50) ≈ **1,207 requests**. Against rename's
1,000 req/min and merge's 20,000 req/min this is minutes of work — throttle it anyway and run it
in batches so failures are inspectable.

### 7.3 Phase 2 — UUID profiles

1. **47,521 mappable** → `rename` where the integer id has no profile, `merge` where it does.
2. **168,570 with no email and no other signal** → `POST /users/delete`, logged row by row.
3. **67,734 with an email but no map** → see §9, decision 1. Do not delete these in the same
   pass as (2).

### 7.4 Phase 3 — phone review queue

Materialize (don't act on) email-distinct / phone-identical pairs. Expected scale from the July
sample: ~13% of duplicates would be *missed* by email alone but caught by phone. Review a sample
of 200 by hand before deciding whether phone ever becomes an auto-merge tier.

---

## 8. Ongoing daily loop

### 8.1 Sequence

```
04:00  order_customer daily reload (existing)
05:00  customer_attribute rebuild (planned)          ← must aggregate on canonical_cust_id
05:30  customer_id_map incremental MERGE + history
06:00  Braze identity worker drains v_braze_identity_queue
06:30  reconciliation assertions; alert on any failure
```

Steady-state volume: ~270 new duplicate ids per business day → ~6 merge/rename requests per day.
Trivial. The whole point of doing it daily is that the queue never grows large enough to be scary.

### 8.2 Idempotency

Every queue row carries `(cust_id, canonical_cust_id, action, map_version)`. The worker writes to
`braze_identity_action_log` **before** the call and updates it after. A replay after a crash
re-reads the log and skips anything already `succeeded`. A `202` from Braze means *accepted*, not
*applied* — the worker must verify asynchronously via `/users/export/ids`, not assume.

### 8.3 The Braze gotcha that shapes this whole design

> Braze: "User merges won't be reflected for the Messaging History tab, Segment Extensions,
> Query Builder, and Currents."

`braze.*` in BigQuery comes from Currents. So **a merge in Braze does not stitch our event
history in BigQuery.** Post-cleanup, `braze.email_open` and friends will still carry the loser's
`external_user_id` forever. Any engagement query has to join through `customer_id_map` to roll up
to the canonical id. This is the single most important thing to document in the
`braze-campaigns` skill when this ships.

Also: on merge, Braze **keeps the target's existing custom attributes** and only fills in ones
the target was missing. It does not recompute them. Our attribute export must re-push the
canonical profile after a merge, or the survivor keeps stale values.

---

## 9. Open decisions (need Brent's call before Phase 2/3)

1. **The 67,734 UUID profiles with an email but no customer id.** 57,024 are still `subscribed`
   and 54,565 are distinct addresses. These are website visitors who gave an email and never
   ordered — i.e. leads. The stated rule ("if no map then remove") would delete them.
   *Recommendation: don't delete in this pass.* Rename them into a reserved synthetic id range
   (or keep them as-is, tagged) so they stay marketable, and revisit once someone owns the
   lead-nurture question. Deleting is one API call and permanently unrecoverable.
2. **The 618,358 numeric email-less website profiles/month.** Out of scope per Brent ("ignore no
   email profiles") — but they are the bulk of MAU/data-point consumption. Recommend at minimum
   sizing the billing impact with Braze before letting another quarter of them accrue.
3. **Prevention at the source.** Cleanup is post-creation by necessity, but the *UUID* flow is
   preventable: the website SDK should not call `changeUser()` with a generated UUID for an
   anonymous visitor — Braze already tracks anonymous users by `braze_id`, and calling
   `changeUser` with a throwaway value is what creates a permanent orphan profile. One ticket to
   the web team stops ~50K/month of new junk. Guest checkout duplicates are *not* preventable
   without a Pulse-side change to reuse the existing customer record on email match; worth
   raising with the dev team as the real fix.
4. **Deprecated external id removal window.** Recommend 30 days after a successful rename, then
   `/users/external_ids/remove`. Needs confirmation that no CDI feed or legacy app build still
   references the old ids.

---

## 10. Verification & monitoring

Assertions to run after every build; any non-zero result is a build failure, not a warning.

```sql
-- 1. No mapping chains: every canonical_cust_id must itself be canonical
select count(*) as broken_chains
from `marketing-data-442316`.sales_ops.customer_id_map m
left join `marketing-data-442316`.sales_ops.customer_id_map c
  on c.cust_id = m.canonical_cust_id and c.is_canonical
where c.cust_id is null;

-- 2. One canonical per email cluster
select count(*) as split_clusters from (
  select match_email from `marketing-data-442316`.sales_ops.customer_id_map
  where match_email is not null
  group by 1 having count(distinct canonical_cust_id) > 1
);

-- 3. Conservation: orders and net sales are redistributed, never created or lost
with mapped as (
  select m.canonical_cust_id, oc.brink_order_id, oc.net_sales
  from `marketing-data-442316`.sales_ops.order_customer oc
  join `marketing-data-442316`.sales_ops.customer_id_map m on m.cust_id = oc.mapped_cust_id
  where oc.business_date between '2023-03-01' and current_date()
    and oc.store_id <> 1111 and oc.customer_type = 'person'
)
select count(distinct brink_order_id) as orders, round(sum(net_sales),2) as net_sales from mapped;
-- must equal the same aggregate computed without the join

-- 4. No id that was merged away in Braze has been promoted back to canonical
select count(*) as illegal_promotions
from `marketing-data-442316`.sales_ops.customer_id_map
where is_canonical and braze_state = 'merged_away';

-- 5. Queue is draining
select action, status, count(*) as n
from `marketing-data-442316`.sales_ops.braze_identity_action_log
where date(requested_at) >= current_date() - 7
group by 1,2 order by 1,2;
```

Ongoing dashboard metrics: new duplicate ids/day (target: falls to ~0 once Pulse reuses records),
queue depth, merge failure rate, canonical customer count vs raw id count.

---

## 11. Sequence of work

| # | Step | Blocked by |
|---|---|---|
| 1 | Review this plan; settle §9 decisions | — |
| 2 | Deploy `customer_id_map` + history + log tables; run backfill; freeze for review | 1 |
| 3 | Hand-review the 90 clusters with ≥11 ids | 2 |
| 4 | Point `customer_attribute` at `canonical_cust_id`; add `canonical_cust_id` to the `claude` views | 2 |
| 5 | Build the Braze identity worker (Cloud Run + Scheduler, `users.merge` + `users.external_ids.rename` API key scopes) | 2 |
| 6 | Phase 1: 54,469 renames + 5,869 merges, batched, verified | 3, 5 |
| 7 | Phase 2: UUID resolution + deletes | 5, §9.1 |
| 8 | Document the Currents/merge gotcha in the `braze-campaigns` skill | 6 |
| 9 | Dev tickets: web SDK `changeUser` fix; Pulse guest-checkout record reuse | 1 |
| 10 | Phase 3: phone review queue | 6 |

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| Braze merge is irreversible | BigQuery holds full lineage in `customer_id_map_history`; merges only ever fire from a reviewed, frozen map; large clusters hand-reviewed first |
| Shared household/ops email over-merges | Email-only tier 1; clusters ≥11 ids reviewed manually; phone stays a review queue, never auto |
| Merged event history invisible in `braze.*` | Documented; all engagement queries join through the map |
| Canonical id drift breaks prior merges | Stickiness rule + `merged_away` promotion block + chain assertion |
| Stale custom attributes on survivors after merge | Attribute export re-pushes any canonical id whose cluster changed |
| Rename fails mid-cluster ("id already in use") | Per-cluster ordering: rename before merge; `rename_errors` inspected per batch and retried |
| Deleting the 67,734 email-bearing UUID leads | Held out of the delete pass pending decision §9.1 |
