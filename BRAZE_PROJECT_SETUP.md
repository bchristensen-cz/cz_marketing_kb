# Braze projects: how to query Braze data (project-instructions snippet)

For the steward. This is the canonical copy of the instruction block that goes into the
**Braze Canvas Creation** project's instruction box (and any other Braze-focused project
that needs historical Braze data). Same model as the Analysis snippet at the bottom of
`CLIENT_SETUP.md`: pointing-first, so the real logic arrives with the fresh pull and
cannot drift. **A repo commit does not update the project's instruction box.** If this
block changes, re-paste it into the project the same day.

The block is longer than the Analysis snippet on purpose. A Braze project also has the
Braze MCP connector and the Braze dashboard in front of it, so it needs a few hard
backstops that hold even before the skill has been read: the ones that produce a wrong
number silently rather than an error. Every backstop line below is a pointer to a rule
in `claude_skills/braze-campaigns/`; on any conflict, the skill wins.

---

```
# Cafe Zupas Braze data - knowledge base protocol

This project builds and edits Braze canvases and campaigns. Two different jobs,
two different sources:

- Building or inspecting canvas and campaign objects (steps, segments, templates,
  live configuration, sending): use the Braze MCP connector.
- Any NUMBER about Braze (sends, deliveries, opens, clicks, engagement rates, what
  ran on which days, audience reach, holdouts, lift, attributed orders or sales,
  subscription changes): the only approved source of query logic is the knowledge
  base at https://github.com/bchristensen-cz/cz_marketing_kb, run against BigQuery.

Before answering ANY question in the second group:

1. Get a fresh copy of the knowledge base every session, even if a copy exists:
   - With a shell (Cowork): delete any older copy, then
     git clone --depth 1 https://github.com/bchristensen-cz/cz_marketing_kb
     into the temporary working area, never into my personal folders.
   - Without a shell (regular chat): fetch the raw files from
     https://raw.githubusercontent.com/bchristensen-cz/cz_marketing_kb/main/
     starting with README.md.
2. Read, in this order, from the fresh copy only: README.md,
   decisions/DECISIONS.md, claude_skills/ask-a-data-question/SKILL.md,
   claude_skills/braze-campaigns/SKILL.md, then
   claude_skills/braze-campaigns/references/caveats.md (every Braze question),
   plus whichever other references the SKILL.md table triggers: holdouts.md
   (control groups, lift, incrementality), currents_integrity.md (counts look
   low or a day looks missing), channel_value.md (email vs push vs text),
   canvas_message_report.md (canvas-level reporting, automated vs broadcast),
   writing_out.md (pushing data to Braze or Google Ads). Column documentation is
   data_dictionaries/braze_data_dictionary.md and data_dictionaries/braze/.
3. Start from the validated templates sql/braze_campaign_daily_activity.sql
   (what ran when, by channel) and sql/braze_campaign_engagements.sql
   (engagement and engagement rate). Never hand-roll the cross-channel unions.
4. State the KB version in the first data answer of the session (short sha and
   commit date) and always show the SQL, in the steward's format from the README.
5. Never commit, push or edit the knowledge base. Findings go to an Asana task on
   the Claude Data board titled "KB finding: <short title>".
6. If the knowledge base can be neither cloned nor fetched, STOP and say so. Do
   not answer from general knowledge, do not guess table or column names, do not
   query BigQuery.

Backstops that hold even before the skill is read (the skill wins on conflict):

- Project marketing-data-442316, dataset braze. Filter the partition column
  event_date on every table, always. Filter workspace = 'cafe_zupas' unless the
  catering workspace is explicitly asked for, and say which workspace an answer
  covers.
- event_timestamp is a DATETIME in America/Denver local time, NOT UTC. The epoch
  column time is the only true UTC clock: use timestamp_seconds(time). Never wrap
  event_timestamp in timestamp() or cast(... as timestamp). On the order side use
  order_timestamp_utc for any time comparison and order_datetime_local only to
  show a human a local time.
- The customer id is external_user_id (a STRING). Join to orders with
  safe_cast(external_user_id as int64) = oc.mapped_cust_id, never a plain cast,
  and report how many ids the safe_cast dropped (per arm in any experiment).
  braze.users keys on external_id, not external_user_id, and is unpartitioned:
  touch it once per analysis. Never bridge Braze to orders through email for
  customer counts or ad hoc analysis.
- Event counts are count(distinct id), never count(*). User counts are
  count(distinct external_user_id). Headline engagement rates use is_human
  (machine opens and suspected bot clicks excluded); keep the all-events rate
  only to reconcile against the Braze dashboard, which counts everything.
- Text messaging is mostly RCS now (about 4x SMS). Any SMS or text question
  must include the rcs_* tables or it undercounts badly.
- Tables prefixed canvas_* carry canvas identity only, campaigns_* carry campaign
  identity only, and channel event tables (email_send, pushnotification_send, ...)
  carry both. Use the program_id coalesce from the skill to line them up.
- In-app messages and banners have no send event; impressions are the exposure.
- The last 1 to 2 event days are still backfilling (about 20 to 25% low). Label
  them immature and never compare a fresh day to matured days.
- Attribution is ledger decision D-026: an order is credited to the most recent
  qualifying email, push, SMS or RCS send to the same email in the 24 hours
  before order_timestamp_utc, 48 hours for Saturday sends. Call it "attributed"
  or "influenced", never "incremental". Any other window must be labelled as a
  different number.
- A Braze holdout is drawn per send, not per campaign. Find control legs with
  in_control_group OR the name regex in holdouts.md, and never quote
  campaign-level incrementality from per-send holdouts.
- "What is live right now?" is answered from a cheap channel table
  (pushnotification_send, contentcard_send, inappmessage_impression), once per
  session, never by scanning canvas_entry with no date bound.
- The order side of any join is claude.order_customer or claude.order_lines.
  Never pulse.*, brink.*, sessionM.* or the legacy sales_ops.OrderCustomer.
- The only writable dataset is marketing-data-442316.scratch (7-day expiry).
  Query results, exports and analysis files never go into a clone of the
  knowledge base; they go to a separate outputs folder.
- A Braze dashboard figure and a BigQuery figure are different metrics with
  different exclusions. Never present one as a check on the other without
  saying which is which.
```

---

## Why these backstops and not the whole skill

The Analysis snippet is deliberately tiny because the Analysis project only ever reads
BigQuery and the skills arrive with the pull. A Braze project is different in two ways:
it has a second data source (the Braze MCP connector and the dashboard) that will happily
answer "how did this canvas do" with numbers built on different exclusions, and its users
ask the three questions that have produced silently wrong answers most often in the query
log: the Denver-local `event_timestamp` cast (6 to 7 hours early), the email identity
bridge, and the unbounded `canvas_entry` scan. Each backstop names the trap in one line
and leaves the measurement, the dates and the exceptions to the skill.

Everything else (templates, column names, the steward SQL layout, the pre-query
clarification protocol, the holdout regex, the maturation check against
`braze.load_watermark`) is intentionally not repeated here. Two copies of a rule drift.

## Verifying the project is wired up

Inside the Braze Canvas Creation project, ask:

> how many people opened the last points statement email, and what was the open rate

Pass: Claude states a KB commit hash, asks which workspace and date range (or resolves
them against the data), shows SQL that filters `event_date` and `workspace`, counts
`distinct id` / `distinct external_user_id`, and reports a human open rate with the
all-opens rate alongside it. Fail: a number with no hash and no SQL, or a figure read off
the Braze dashboard presented as the answer.
