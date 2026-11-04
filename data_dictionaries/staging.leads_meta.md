# `marketing-data-442316.staging.leads_meta`

**The Facebook / Instagram lead-form leads that Brent's lead process pushes to Braze.** Documented 2026-11-04 after the first value read. Not a mart and not a `claude` object: it is the cohort list, nothing else.

| | |
|---|---|
| Type | **External table over a Google Sheet** ("meta leads from ads", tab `meta_leads`, range `A:P`). The sheet is the system of record; the BigQuery table is a window onto it |
| Who can read it | Only a principal whose BigQuery credential carries the Drive scope. **The Claude MCP connector and Brent's `bq` CLI both fail with `Permission denied while getting Drive credentials`** (2026-11-04). Read the sheet through the Google Sheets connector instead |
| Grain | One row per lead form submission (`id` = `l:<leadgen id>`) |
| Columns in the external table | `id`, `created_time` (ISO with offset), `ad_id`, `ad_name`, `adset_id`, `adset_name`, `campaign_id`, `campaign_name`, `form_id`, `form_name`, `is_organic`, `platform` (`fb` / `ig`), `email`, `full_name`, `phone_number`, `lead_status` |
| Sheet-only columns (Q:V, not in the table) | `phone` (normalised), `sent_to_braze` (timestamp the row was pushed), `alias_label`, `alias_name` (the Braze user alias the lead was created under), `first_name`, `last_name` |
| Companion | `shared_datasets.leads_store_name_map` (7 rows): form store choice to `store_name` |
| PII | Raw email, name and phone. **Never paste them into SQL** (query text sits in the job log 180 days). Hash with the `claude_pii.md` recipe, `to_hex(sha256(lower(trim(email))))` on the `cater_`-stripped address, and join on `claude.order_customer.mapped_email_hash` / `claude.loyalty_user.email_hash` |

## What is in it (measured 2026-11-04)

- 2,580 rows, 2,569 distinct emails, leads created 2025-10-14 to 2026-03-26.
- Campaigns: `FF - Lead Generation - New Stores` 1,285, `Lead Generation - New Stores 2026` 716, `FF - Lead Generation - College Stores Pre-Launch` 278, `FF - Lead Generation - U of M New Store` 244, `Lead Generation - OSU` 34, `Lead Generation - ASU` 19, blank 4. Forms: `Lead Form - New Store - Generic` 2,342, `Lead Form - U of M` 238.
- **Ties to Meta within 2% per form campaign** (Meta-reported leads: 1,287 / 278 / 236 / 34 / 18), so the sheet is complete for instant-form campaigns. `Lead Generation - New Stores 2026` reports 2,313 website (pixel) leads in Meta against 716 form rows here: only its form leads land in this sheet.
- `sent_to_braze` starts **2025-12-17** (939 earlier leads backfilled that day); after that every lead is pushed the same day it arrives.
- **Nothing after 2026-03-26.** The live campaign `FF - Lead Gen - New Stores` (since 2026-08-03, $17.6k, 7,049 Meta "lead" results) has no rows. Either its leads are website leads that never pass through this process, or the feed into the sheet stopped. Open question for the steward.

## Value read, 2026-11-04 (method)

Cohort = distinct lead emails, each at its earliest `created_time` (local date). Outcomes from `claude.order_customer` (`customer_type = 'person'`, `business_date` 2025-10-14 to yesterday) and `claude.loyalty_user`, matched on email hash:

- **new account** = `loyalty_user.registered_date >= lead date`
- **new customer** = `order_customer.first_order_date >= lead date` (the canonical first order, floor 2023-03-06)
- **revenue** = `net_sales` on person orders dated on or after the lead date, catering shown separately

Results: 889 new loyalty accounts, 702 new customers, 979 leads ordered after the lead, 5,169 orders, $118,290 net sales ($112,049 ex-catering), of which $67,348 from the 702 new customers. This is **influenced, not incremental** revenue: there is no holdout, and most leads were for new-store openings they might have visited anyway. Email match only, so a lead who orders under another address or unidentified is missed (undercount).

Mechanics used because the hashes could not go to a scratch table from the session: the 10-hex prefix of each hash plus lead date and campaign were packed as base64 bytes in the query and decoded with `from_base64` / `to_code_points` (2,569 leads, 0 prefix collisions). Never commit that payload: it is derived from customer emails.
