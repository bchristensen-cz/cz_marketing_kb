-- =============================================================================
-- new_store_loyalty_benchmark.sql
-- -----------------------------------------------------------------------------
-- purpose : the "new store loyalty accounts" board slide. cumulative new-to-
--           brand accounts by weeks since opening, for each current-year
--           opening, read against the median build of the 12 non-campus
--           2023-2024 openings at the same store age.
--
-- metric  : an account is counted at the store that ACQUIRED it --
--           customer_order_count = 1 means that order was the customer's first
--           ever. one row per customer chain-wide, so a customer can never be
--           counted at two stores and never in two weeks. this is why the
--           running total is built from the acquisition week rather than from
--           a weekly count(distinct mapped_cust_id), which double counts every
--           returning guest.
--
-- weeks   : CHANGED 2026-10-22. weeks are now anchored to the MON-SUN FISCAL
--           CALENDAR, not to each store's open-date anniversary. under the old
--           anchor a store's week ran from its opening weekday, so a period end
--           (always a sunday) fell mid store-week and the store's final bucket
--           was partial while the benchmark bucket it was compared against was
--           whole. that understated the youngest stores by 6-8% -- ocotillo
--           read -36% on the old anchor and -30% on this one. every store and
--           every benchmark store now closes each week on the same sunday and
--           carries the same partial opening-week stub, so the comparison is
--           like for like. week numbers happened not to move at the p9 cut.
--
-- cohort  : benchmark = 172, 171, 178, 173, 174, 177, 175, 176, 181, 180, 182,
--           183. excluded on purpose: 169 syracuse (opened 2023-03-03, before
--           the 2023-03-06 order_sequence floor, so its first-order flag is
--           not trustworthy), 50 middleton mobile (not a store), 185 brookfield
--           and 184 surprise (dec-2024 openings, both open into the holiday
--           trough). steward call 2026-09-16.
--
-- focus   : current-year openings. add each new store here as it opens. a store
--           that opened after as_of is simply excluded by its own week count.
--
-- as_of   : set to the period end being reported. p9 fy2026 = 2026-09-27.
--
-- caution : day 60 is a DAY count, not a week count, so it is unaffected by the
--           anchor change. a store under 60 days old at as_of has no day-60
--           read and must show blank on the slide, never a partial one.
-- =============================================================================

declare as_of date default '2026-09-27';

with stores as (
	select
	  s.store_id
	, s.store_name
	, s.store_open_date
	, case when s.store_id in (190, 189, 193, 194, 197, 191, 192) then 'focus' else 'benchmark' end as cohort
	, date_diff(date_trunc(as_of, week(monday)), date_trunc(s.store_open_date, week(monday)), week) + 1 as week_at_as_of
	, date_diff(as_of, s.store_open_date, day) as days_open_at_as_of
	from `marketing-data-442316`.claude.store_info s
	where 1=1
	and s.store_id in (172, 171, 178, 173, 174, 177, 175, 176, 181, 180, 182, 183, 190, 189, 193, 194, 197, 191, 192)
)
, acq as (
	select
	  oc.store_id
	, oc.mapped_cust_id
	, min(oc.business_date) as acq_date
	from `marketing-data-442316`.claude.order_customer oc
		join stores s
		on s.store_id = oc.store_id
		and oc.business_date >= s.store_open_date
	where 1=1
	and oc.business_date between '2023-06-22' and as_of
	and oc.mapped_cust_id is not null
	and oc.customer_type = 'person'
	and oc.customer_order_count = 1
	group by
	  oc.store_id
	, oc.mapped_cust_id
)
, aged as (
	select
	  s.store_id
	, s.store_name
	, s.cohort
	, s.week_at_as_of
	, s.days_open_at_as_of
	, date_diff(a.acq_date, s.store_open_date, day) as days_since_open
	, date_diff(date_trunc(a.acq_date, week(monday)), date_trunc(s.store_open_date, week(monday)), week) + 1 as weeks_since_open
	from acq a
		join stores s
		on s.store_id = a.store_id
)
, spine as (
	select
	  s.store_id
	, s.store_name
	, s.cohort
	, wk as weeks_since_open
	from stores s
	, unnest(generate_array(1, least(s.week_at_as_of, 60))) as wk
)
, weekly as (
	select
	  g.store_id
	, g.weeks_since_open
	, count(*) as new_accts
	from aged g
	group by
	  g.store_id
	, g.weeks_since_open
)
, curve as (
	select
	  p.store_id
	, p.store_name
	, p.cohort
	, p.weeks_since_open
	, sum(ifnull(w.new_accts, 0)) over (partition by p.store_id order by p.weeks_since_open rows between unbounded preceding and current row) as cum_accts
	from spine p
		left join weekly w
		on w.store_id = p.store_id
		and w.weeks_since_open = p.weeks_since_open
)
, bench as (
	select distinct
	  c.weeks_since_open
	, percentile_cont(c.cum_accts, 0.5) over (partition by c.weeks_since_open) as bench_median
	from curve c
	where 1=1
	and c.cohort = 'benchmark'
)
select
  c.store_name
, c.weeks_since_open
, c.cum_accts
, cast(round(b.bench_median) as int64) as bench_median
, round(safe_divide(c.cum_accts, b.bench_median) - 1, 4) as vs_bench
from curve c
	join bench b
	on b.weeks_since_open = c.weeks_since_open
where 1=1
and c.cohort = 'focus'
order by
  c.store_name
, c.weeks_since_open
;
