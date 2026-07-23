# Client setup — one-time, per user

Each user pastes the snippet below into their Claude project instructions (Cowork: project settings → instructions). It is deliberately minimal and stable — all real logic lives in this repo, so the snippet should never need updating.

Do **not** install the skills as `.skill` packages, mount a personal clone, or fork the repo. The fresh-clone-per-session protocol is the only supported way to consume this KB.

Requirements on the user's machine: the Asana connector (for logging findings) and the BigQuery connector (for queries). No git knowledge needed — Claude runs the clone itself.

---

## Project instructions snippet (copy everything below)

```
# Cafe Zupas data — knowledge base protocol

Before answering ANY question about company data (sales, orders, customers,
menu, campaigns, Braze, BigQuery):

1. Get a fresh copy of the knowledge base — every session, even if a copy
   already exists (delete any older copy first):
   git clone --depth 1 https://github.com/bchristensen-cz/cz_marketing_kb
   Clone into your temporary working area, never into my personal folders.
2. Read README.md from that fresh clone and follow its session protocol,
   then read the relevant skill in claude_skills/ and the data dictionaries
   it references. Follow the skills verbatim (canonical definitions, required
   clarifications, partition filters).
3. Never answer from installed skills, saved copies, forks, or memory of a
   previous session. The fresh clone is the single source of truth.
4. State the KB version (git log -1 --format='%h %ad') in the first data
   answer of the session.
5. Never commit, push, or edit the knowledge base. New findings are logged
   per the README's ground rules (Asana task on the Claude Data board).
```
