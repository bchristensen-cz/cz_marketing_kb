-- =====================================================================================
-- claude_pii.order_customer: the FULL Claude-facing order view, raw identifiers included.
--
-- Created 2026-10-27 (steward decision, PII review). This file holds the ONE body of the
-- order view. claude.order_customer is a projection of this view that drops the raw
-- identifier columns (see sql/claude.order_customer.sql), so business logic lives here and
-- nowhere else. Everything that used to be true of claude.order_customer is true here:
-- one row per brink_order_id, 3 calendar years of history, stores 1111 / 999 excluded,
-- identity from sales_ops.order_sequence, lifetime columns from sales_ops.customer_attribute,
-- account_type from claude.loyalty_user.
--
-- Who may read it: the four principals that need a raw address, by dataset grant on
-- claude_pii (jspach for customer-service lookups, social-capis-job for CAPI uploads,
-- braze-cloud-data-ingestion for CDI, dbeaver-bigquery for tkxel), plus cz-dashboard-sched
-- (the nightly Braze attribution bridges orders to Braze sends by email) and the steward.
-- Standard users read claude.order_customer and never see this dataset.
--
-- Raw identifier columns carried here and dropped from claude.order_customer:
--   email, phone, acct_email, acct_phone, sm_email   (cust_map inputs from sales_ops.order_customer)
--   mapped_email                                      (the ruled person email, from order_sequence)
-- mapped_email_hash is computed HERE so both views share one recipe:
--   to_hex(sha256(lower(trim(mapped_email)))) : the same recipe as claude.guest_feedback.email_hash
--   (D-042), so a feedback-to-order join works without either side holding the address.
--
-- Authorization chain (dataset-level authorized datasets, set 2026-10-27):
--   sales_ops  authorizes claude_pii   (reads order_customer, order_sequence, customer_attribute)
--   claude     authorizes claude_pii   (reads claude.loyalty_user)
--   claude_pii authorizes claude       (claude.order_customer projects this view)
--
-- Diff the live definition before every redeploy:
--   select v.view_definition from `marketing-data-442316`.claude_pii.INFORMATION_SCHEMA.VIEWS v
--   where v.table_name = 'order_customer'
-- A column ADDED to this view appears in claude.order_customer at query time through its
-- `select * except(...)`; if the new column is an identifier it MUST be added to that except
-- list in the same deploy. Run the identifier sweep in data_dictionaries/claude.order_customer.md
-- after every redeploy of either view.
-- =====================================================================================

create or replace view `marketing-data-442316`.claude_pii.order_customer as
select
oc.* except(brink_net_sales)
, os.mapped_cust_id
, os.mapped_email
, to_hex(sha256(lower(trim(os.mapped_email)))) as mapped_email_hash
, os.mapped_email_domain
, os.mapped_cust_id_source_system
, os.mapped_cust_id_source_updated_at
, os.mapped_email_source_system
, os.mapped_email_source_updated_at
, os.customer_type
, coalesce(os.customer_order_count, 0) as customer_order_count
, coalesce(os.days_since_prev_order, 0) as days_since_prev_order
, coalesce(ca.lifetime_order_count, 0) as lifetime_order_count
, coalesce(ca.lifetime_catering_order_count, 0) as lifetime_catering_order_count
, coalesce(ca.lifetime_guest_order_count, 0) as lifetime_guest_order_count
, ca.lifetime_net_sales
, ca.lifetime_gross_sales
, ca.lifetime_avg_check
, ca.first_order_date
, ca.first_order_datetime
, ca.last_order_date
, ca.last_order_datetime
, ca.days_since_last_order
, ca.customer_tenure_days
, ca.orders_l365
, ca.net_sales_l365
, ca.catering_orders_l365
, ca.catering_net_sales_l365
, ca.is_app_user
, ca.app_user_type
, ca.app_purchase_mode
, ca.guest_status
, ca.gender
, ca.birthday
, ca.age
, lu.member_program as account_type
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
		left join `marketing-data-442316`.sales_ops.customer_attribute ca
		on ca.mapped_cust_id = os.mapped_cust_id
			left join `marketing-data-442316`.claude.loyalty_user lu
			on lu.sm_external_user_id = os.mapped_cust_id
where 1=1
and oc.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
and oc.store_id not in (1111, 999)
;


-- =====================================================================================
-- Post-deploy validation: grain must be preserved. Expect zero rows.
-- =====================================================================================
-- select
--   oc.brink_order_id
-- , count(*) as cnt
-- from `marketing-data-442316`.claude_pii.order_customer oc
-- where 1=1
-- group by 1
-- having count(*) > 1
-- order by count(*) desc
-- ;
