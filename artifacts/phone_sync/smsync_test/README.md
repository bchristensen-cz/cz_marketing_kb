# SMSync test files — Braze → SessionM phone sync (built 2026-09-04)

Four small `_user_update.csv` drops, run **in order, one at a time**, each verified before the next.
Rows for the same user must never share a file: SMSync splits files into 10,000-line chunks processed by
parallel workers, so within-file ordering is not guaranteed. Only `external_id` and `phone_numbers` are
sent (the guide: "if an attribute is included in one payload, it must be included in all payloads").
`lookup_key` defaults to `external_id`, which is what we want.

Test subject: Ashley (external_id 12520552, SessionM user 61af8800-016d-11f1-8e6c-443aac110010), baseline
phone 8016689089. Fictional numbers 8015550100/01/02 (reserved 555-01xx) are verified absent from both systems.
The 19 other rows in t1 are **real phase-3 adds** from `scratch.sessionm_phone_sync_plan` — users with no
phone in SessionM whose Braze number is held by nobody — so t1 is production work, not fake data on customers.

| File | Precondition (API, from the batch script pattern) | Row(s) | Passes if |
|---|---|---|---|
| t1_add | PUT Ashley `phone_numbers: []` | Ashley → [8015550100]; 19 real adds | all 20 users show exactly the one number — **PASSED 2026-09-04 (SM Sync job 90035, 34 s)** |
| t2_replace | t1 verified | Ashley → [8015550101] | Ashley = [8015550101] only → **replace**. If both numbers → **merge** → the 832 phase-2 replaces stay on the API |
| t3_clear | t2 verified | Ashley → [] | Ashley empty → the 33K phase-1 removals can go by file. If unchanged → removals stay on the API |
| t4_conflict | PUT Ashley [8015550102] via API; fill in the second test profile's external_id | second profile → [8015550102] | row rejected and reported. If the second profile GETs back with the number, or Ashley lost it, SMSync moves numbers silently — do **not** use it for anything but phase 3 |

Finish: PUT Ashley back to [8016689089] via the API. Mark the 19 real rows `succeeded` in the plan table (action_ids 34297–34319 range, listed in t1) once verified.

Verify each step with `GET /priv/v1/apps/{key}/users/{sessionm user_id}` (read-only) — or wait for the next
morning's `sessionM.user_phone_numbers` load.

## Filename
`new_<api_key>_<timestamp>_<file_set_name>_user_update.csv`, timestamp `YYYYMMDDHHmmSS`, `file_set_name`
as configured by SessionM. Render it in PowerShell (key never leaves the machine):

```powershell
$kv=@{}; (Get-Content C:\dev\cz_marketing_kb\.env.local.gitignore) | % { if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') { $kv[$matches[1]]=$matches[2].Trim().Trim('"') } }
$set = 'REPLACE_WITH_FILE_SET_NAME'
$ts  = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
Copy-Item .\artifacts\phone_sync\smsync_test\t1_add_user_update.csv ("new_{0}_{1}_{2}_user_update.csv" -f $kv['SESSIONM_API_KEY_V1'], $ts, $set)
```
Open question for SessionM: is the `api_key` in the filename the same v1 app key we use for the REST API, and
where is the S3 drop / how are per-row rejections reported.
