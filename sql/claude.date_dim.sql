-- claude.date_dim — authorized view over the steward's static date dimension.
-- Deployed 2026-08-05 (matches the live view definition verbatim).
-- Parent: sales_ops.date_dim — static table, 2001-01-01 → 2057-10-31, one row per date,
-- clustered on (cal_date, day_of_week_shrt, day_of_week_full). No scheduled rebuild;
-- regenerate the parent before 2057 (and before 2051 if holiday labels are needed).
-- Docs: data_dictionaries/claude.date_dim.md, claude_skills/date-dimensions/SKILL.md

create or replace view `marketing-data-442316`.claude.date_dim as
select *
from `marketing-data-442316`.sales_ops.date_dim
