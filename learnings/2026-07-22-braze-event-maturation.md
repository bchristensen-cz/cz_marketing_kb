# Braze same-day events mature over ~2 days
- **Date:** 2026-07-22
- **Area:** braze-campaigns
- **Observed by:** Jamie / daily-review sessions (observed July 2026, pre-KB)
- **What:** Braze event tables (`email_send`, `app_sessionstart`, etc.) backfill for ~2 days; same-day reads ran 20-25% low. Skill mentions `load_watermark` but not the maturation magnitude.
- **Proposed change:** Add to braze-campaigns Caveats: treat the most recent 1-2 event days as partial; label them, and never compare a just-loaded day against matured days.
- **Status:** proposed
