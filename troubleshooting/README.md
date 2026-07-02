# Troubleshooting

Diagnostic tooling for production incidents. Everything in here is **temporary
instrumentation** — deploy it to collect evidence, remove it when the case closes.
Canonical production SQL stays in `pipeline/sql/`.

---

## Case 2026-07: Step-13 data loss (OPMS → T_M_Filler_Process comms)

**Status:** OPEN — evidence collection.

### Symptom

Since ~2026-06-30, batches on some machines (G3, G1, F3, M1) end with
`[end time]` written but `In_Feed_MC` / `Out_Feed_MC` / `In_Feed_DE_MC` NULL.
On 2026-06-30 a step-13 event on F4 coincided with data appearing on G3,
which had no step-13 signal.

### What is already established

- The Step-13 snapshot writes `[end time]` (from the clock) and the counters
  (copied from `T_M_Filler_Process`) **in one statement** — so "end time yes,
  counters no" proves the statement fired while the source counters were NULL.
  The trigger copied an empty payload; it did not skip columns.
- No error strings in `t_log` → the trigger executed cleanly (no rollback).
- The OPMS operator screen showed correct values during the incidents → the
  PLC/OPMS side is healthy; the fault is in the OPMS → SQL write path
  (OPMS host → DB host). IT suspects network comms; confirmed nothing yet
  because spot checks always land while the link is healthy.
- Latent trigger weakness (fix drafted, **not deployed**): the Step-13/Step-10
  `[Change paper brik]` updates join `inserted` without filtering
  `i.Machine_Step_No`, so a multi-machine statement containing one machine at
  step 13 would stamp every open batch in the statement (candidate explanation
  for the F4→G3 event). Needs MULTIROW evidence to confirm before patching.

### The three loggers (`dbo.Comms_Audit`)

| Event | Meaning | Points at |
|---|---|---|
| `HEARTBEAT` | 1 row/machine/minute while OPMS writes. **Gaps = OPMS silent.** | Network / OPMS |
| `NULLDATA` | Machine mid-production (step 8–13) arrived with NULL counters. **Empty payload on arrival.** | Network / OPMS |
| `MULTIROW` | One statement touched >1 machine row (bundled write / reconnect flush). | Explains the F4→G3 mechanism; decides the trigger patch |

### Deploy (SSMS, in this order)

1. **`COMMS_AUDIT_SETUP.sql`** — creates `dbo.Comms_Audit` + index.
   ⚠️ **Must run BEFORE step 2** — the instrumented trigger references the
   table; deploying the trigger without it will make OPMS writes fail.
2. **`TRI_UPDATE_FILLER_V5.8_COMMS_AUDIT.sql`** — `CREATE OR ALTER` of the live
   trigger. Identical to `pipeline/sql/TRI_UPDATE_FILLER_V5.8.sql` plus the
   audit block (own TRY/CATCH; production logic untouched).
3. Let it run through at least one full production day / one comms incident.
4. Read evidence with **`COMMS_AUDIT_QUERIES.sql`** (Q1 gaps, Q2 empty
   payloads, Q3 bundles, Q4 correlation with corrupted batches).

### Remove

1. Re-run `pipeline/sql/TRI_UPDATE_FILLER_V5.8.sql` (canonical trigger).
2. Keep or drop `dbo.Comms_Audit` (keep = evidence archive).

### Hand-off targets

- **IT / network:** Q1 silence windows + Q2 timestamps → "check the
  OPMS ↔ DB server link at these exact times."
- **OPMS owner / Tetra Pak:** "When tag quality goes bad or the DB connection
  drops, does the writer write NULL into `T_M_Filler_Process`, and does it
  rewrite all machine rows on reconnect?" Q2/Q3 output is the supporting
  evidence.
- **Internal (trigger hardening):** if Q3 shows step-13 bundles → deploy the
  step-filter + payload-gate patch to V5.8 (drafted, pending this evidence).
