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
- **Nothing after 2026-03-26, but the leads still reach Braze.** The sheet stopped; the process now lands every lead in Braze as the custom event `social_signup` (resolved 2026-11-04, see below). The live campaign `FF - Lead Gen - New Stores` (since 2026-08-03) shows up there as 5,984 Meta sign-ups from 2026-08-01 to 2026-11-04.

## The Braze side: `social_signup` event and `signup_info` attribute (the better cohort source)

- **`braze.customevent` where `name = 'social_signup'`** (workspace `cafe_zupas`): first event 2025-10-22, still daily. `properties` JSON carries `signup_platform` (`fb`, `ig`, `tiktok`, `snapchat`, occasionally `ig_2` / `ig_3` / blank), `signup_form` (store name) and `signup_campaign`. 26,047 events / 13,377 Braze users to 2026-11-04. **About half the events have no `external_user_id`** (the profile was alias-only when the event fired); map `user_id` to `braze.users.braze_id` to get the current `external_id`.
- **`braze.users.custom_attributes.signup_info`**: object with the same three keys, on 13,102 profiles. 12,088 also have the event; 1,014 have the attribute only and therefore **no sign-up date** (`created_at` is the original profile date, back to 2023, so never use it as a lead date).
- Union of both: 14,391 Braze profiles, 13,037 numeric `external_id`s (join `safe_cast(external_id as int64) = claude.order_customer.mapped_cust_id`, the KB rule), 1,282 with no `external_id`, 72 non-numeric.
- Separate, not part of this process: `new_location_email_signup_<store>` events (store landing pages, `signup_platform = 'store_landing_page'`).
- **Cost:** a `name = 'social_signup'` filter on `braze.customevent` from 2025-10-01 bills ~21.5 GB per run (the name does not prune). Pull the cohort once per session.
- **`signup_form` to store (steward mapping, read from his 2026-11-12 query).** `signup_form` is free text typed per lead form, so one store carries several values and nothing in the marts maps it. Normalize with `lower(trim(json_value(properties, '$.signup_form')))`, then: `'university of minnesota'`, `'lead form - u of m'`, `'lead form - u of m_2'`, `'lead form - u of m_3'`, `'2025-11 u of m new store opening'` = 186; `'arizona state university'` = 188; `'ohio state university'` = 187; `'ammon'` = 190; `'fort apache'` = 189; `'mckinney'`, `'lead form - mckinney'` = 193; `'oconomowoc'`, `'waukesha county'` = 194; `'rexburg'` = 197; `'santan village'` = 191; `'ocotillo'` = 192; `'signal butte'` = 198; `'tooele'` = 199; `'westgate'` = 196. Anything else stays NULL: list the unmapped values (`group by signup_form`) before quoting a per-store figure, because every new opening adds new form names. Platform grouping he used: `tiktok`, `snapchat`, everything else (`fb`, `ig`, `ig_2`, `ig_3`, blank) = `meta`. Lead date = the user's first `social_signup` per form.

Value read 2026-11-04 on the event cohort (12,023 customers, sign-up date = first `social_signup`, person orders 2025-10-01 to yesterday): 1,746 new customers, 1,270 existing, 10,680 orders and $227,015 net after sign-up ($131,821 from the new customers). Meta $156,036 (1,173 new), TikTok $56,829 (481 new), Snapchat $804 (8 new), blank platform $13,346. Attribute-only profiles add $24,932 since 2025-10-01 (undated). No catering orders match by id (catering logins are separate accounts). Influenced, not incremental.

## Value read, 2026-11-04 (method)

Cohort = distinct lead emails, each at its earliest `created_time` (local date). Outcomes from `claude.order_customer` (`customer_type = 'person'`, `business_date` 2025-10-14 to yesterday) and `claude.loyalty_user`, matched on email hash:

- **new account** = `loyalty_user.registered_date >= lead date`
- **new customer** = `order_customer.first_order_date >= lead date` (the canonical first order, floor 2023-03-06)
- **revenue** = `net_sales` on person orders dated on or after the lead date, catering shown separately

Results: 889 new loyalty accounts, 702 new customers, 979 leads ordered after the lead, 5,169 orders, $118,290 net sales ($112,049 ex-catering), of which $67,348 from the 702 new customers. This is **influenced, not incremental** revenue: there is no holdout, and most leads were for new-store openings they might have visited anyway. Email match only, so a lead who orders under another address or unidentified is missed (undercount).

Mechanics used because the hashes could not go to a scratch table from the session: the 10-hex prefix of each hash plus lead date and campaign were packed as base64 bytes in the query and decoded with `from_base64` / `to_code_points` (2,569 leads, 0 prefix collisions). Never commit that payload: it is derived from customer emails.

## Incrementality status (2026-11-04)

- **No holdout exists anywhere in the lead path.** Every lead canvas since 2025-10 runs a single variant with no control group: `251025 | Automated | Custom | Canvas | Store_Opening_Leads` (12,894 entries), `25121 | Automated | Trigger | Webhook Social Account Creation`, `251121 | ... | Ad_Leads_$1_Off_Dirty_Sodas`, and the per-store opening broadcasts (`a:store_leads_<store>`, `a:<store>_social_signups`). Finding this cost a 124 GB scan of `braze.canvas_entry` over 13 months; filter by `canvas_id` once known.
- Meta reports the account and `FF - Lead Gen - New Stores` (120251520923500205) as eligible for self-serve Conversion Lift (checked 2026-11-04).
- Until a holdout reads, quote break-even incrementality (spend / (new customers x first-year net value)) rather than a point estimate.
