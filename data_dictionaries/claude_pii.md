# `marketing-data-442316.claude_pii.*`

**The full Claude-facing objects, raw identifiers included.** Grant-only dataset created 2026-10-27 (steward rule, D-046). Every `claude.*` object that used to carry an email, phone or name is now a projection of its `claude_pii` twin, so the business logic exists once and `claude.*` is its redaction.

| | |
|---|---|
| Who can read it | `jspach@cafezupas.com` (customer-service lookups), `social-capis-job@` (CAPI uploads), `braze-cloud-data-ingestion@` (CDI), `dbeaver-bigquery@` (tkxel), `cz-dashboard-sched@` (nightly Braze email bridge), the steward. `cz-dashboard-deploy@` holds `metadataViewer` only, enough for `create or replace procedure` to resolve the view |
| Who cannot | every other `claude` dataViewer. `Access Denied` on `claude_pii` is the expected answer for a standard user, not a bug to route around |
| Authorized datasets | `sales_ops` and `claude` authorize `claude_pii` (its views read them); `claude_pii` authorizes `claude` (`claude.order_customer` projects `claude_pii.order_customer`) |
| Objects | `claude_pii.order_customer` (view, 81 columns), `claude_pii.loyalty_user` (table, 28 columns, rebuilt 04:30 MT) |

## `claude_pii.order_customer`

The one body of the order view: `sql/claude_pii.order_customer.sql`. Everything in `claude.order_customer.md` applies (grain, 3-year window, stores 1111/999 excluded, identity from `order_sequence`, lifetime columns as-of yesterday) plus these six columns, documented in `sales_ops.order_customer.md` and `sales_ops.order_sequence.md`:

| Column | What it is |
|---|---|
| `email`, `phone` | the ORDER email and phone, as the guest typed them |
| `acct_email`, `acct_phone` | the account on the order |
| `sm_email` | the SessionM address |
| `mapped_email` | the ruled person email (`cust_map`), stripped and lower-cased. The one to use |

`mapped_email_hash` is computed here and flows to `claude.order_customer`. `claude.order_customer` is exactly `select * except(email, phone, acct_email, acct_phone, sm_email, mapped_email) from claude_pii.order_customer`.

## `claude_pii.loyalty_user`

The full identity spine, written first by the 04:30 scheduled query `claude loyalty_user update`; `claude.loyalty_user` is `select * except(full_email, email, first_name, last_name)` of it. Column meanings are in `claude.loyalty_user.md`. Use `full_email` for SessionM identity matching, `email` for comms, `email_hash` to join the redacted tables.

## Rules

1. **`claude.*` carries keys, hashes and domains, never a raw identifier.** The post-deploy sweep in `sql/claude.order_customer.sql` (zero rows expected) is run after any redeploy of either view, because a column added to `claude_pii.order_customer` flows through `select *`.
2. **One hash recipe, three tables.** `to_hex(sha256(lower(trim(address))))` on the cater_-stripped address: `claude.order_customer.mapped_email_hash`, `claude.loyalty_user.email_hash`, `claude.guest_feedback.email_hash`. Hash a single address inside the query; a list of addresses goes in a `scratch` table, never in query text.
3. **A question that needs the address is a customer-service question.** Standard sessions answer with the hash or `mapped_cust_id` and point the asker at CS; they do not ask the steward for a grant.
4. **Deployed code** (D-044) that needs the address reads `claude_pii.*` under its own service account and that account is on the grant list above; nothing reads `sales_ops` for an address it could get here.
5. Grants are dataset-level `READER` entries on `claude_pii`, set by `C:\dev\cz_outputs\scratch\pii_2026-10-27\01_dataset_and_acl.ps1` on 2026-10-27 and visible with `bq show --format=prettyjson marketing-data-442316:claude_pii`.

## Consumers moved on 2026-10-27

| Consumer | Change |
|---|---|
| `sales_ops.customer_attribute` (05:20 scheduled query) | reads `claude_pii.order_customer` |
| `cz-dashboard` `refresh_daily` (06:00) | the two `bz_orders` blocks read `claude_pii.order_customer` (commit 78f3090) |
| `social-capis-daily` Cloud Run job | env `BQ_ORDER_DATASET=claude_pii` |
| Braze CDI `d:261016 \| n:athlete bowl` | its custom SQL must read `claude_pii.order_customer` (edited in Braze, not in this repo) |
| `jspach@` CS lookups | `claude_pii.order_customer` / `claude_pii.loyalty_user` instead of the `claude` twins |
