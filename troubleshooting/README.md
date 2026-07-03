# Troubleshooting

Diagnostic tooling for production incidents. Everything in here is **temporary
instrumentation** — deploy it to collect evidence, remove it when the case closes.
Canonical production SQL stays in `pipeline/sql/`.

---

## Case 2026-07: Step-13 counters going NULL

**Status:** OPEN — comms and V5.8 cleared; second-writer trap deployed, awaiting
next incident.

### Symptom

Since ~2026-06-30, batches on some machines (G3, G1, F3, M1; F4 on 2026-07-02)
end with `[end time]` written but `In_Feed_MC` / `Out_Feed_MC` / `In_Feed_DE_MC`
NULL. On 2026-06-30 a step-13 event on F4 coincided with data appearing on G3,
which had no step-13 signal.

### Timeline of what was ruled in / out

**1. Comms (OPMS → T_M_Filler_Process) — CLEARED (2026-07-03).**
The `Comms_Audit` instrumentation (see below) collected a full production day.
Readout: heartbeats healthy with counters present *before and after* the bad
stamps; **Q2 NULLDATA = zero rows** (OPMS never delivered an empty payload);
partial-payload census (infeed NULL + outfeed present) = zero. The data was
good on the wire — the loss happens inside the database, after a good stamp.

**2. V5.8 trigger — CLEARED as the cause (2026-07-03). The smoking gun:**
batch `260701-27We3-F4` ended with `Sampling_Waste = 921` but In/Out/DE
counters all NULL. The Step-13 UPDATE writes all five columns atomically from
one `inserted` row, and `Sampling_Waste = counter_outfeed − counter_infeed_DE`.
For SW to be non-NULL, both source counters were non-NULL in that firing —
which means that firing *wrote* real values into the counter columns. They are
NULL. **A single statement cannot produce this row.** Therefore at least two
writes touched it: a good step-13 stamp (wrote everything, incl. SW=921), then
a **separate, later write** that NULLed the three counters without touching SW.
Nothing in the trigger pipeline writes those counters without also writing SW
(grep-verified) → **the second writer is external to the pipeline.**

**Why only some machines** (answers "if the trigger were wrong it would hit all
machines"):
- **Gate asymmetry:** A/B/D/M re-stamp on every step 13 until CIP → self-heal;
  F/G/H/K are write-once → they keep the damage. M1 failed because CIP closed
  its heal window after the last good stamp.
- **F4 is the only DE-wired machine** → the only machine where `Sampling_Waste`
  is ever non-NULL → the only place the overwrite leaves a fingerprint. On
  F3/M1/G* the identical overwrite just looks like "all counters NULL". F4
  isn't behaving differently; it's the only witness.

**3. Prime suspect: an external writer to `[Change paper brik]`.**
Most likely a Budibase form/automation saving **stale row state** — a row
loaded while the batch was open (counters still NULL), saved after step 13, so
it writes the NULLs back. It skips `Sampling_Waste` / `In_Feed_DE_MC` if the
form schema predates those columns (added 2026-06-29), which also matches
incidents starting ~06-30. Operators already write `[Change paper brik]`
post-production (brik scans → `total_Var_Brik`; that's why
`TRI_UPDATE_SCANNED_BRIKS` exists).

### Active trap — `CPB_WRITE_AUDIT.sql`

Deployed 2026-07-03. `TRI_CPB_WRITE_AUDIT` on `[Change paper brik]` logs every
change to the five step-13 columns (old → new) plus the caller's identity —
`APP_NAME()`, `SUSER_SNAME()`, `HOST_NAME()` — into `dbo.CPB_Write_Audit`. A
trigger runs in the writer's own session, so these report *who wrote*, not the
trigger. Own TRY/CATCH, logs only on change, safe long-term.

**Verdict query (run after the next incident):**

```sql
SELECT * FROM dbo.CPB_Write_Audit
WHERE New_InFeed IS NULL AND Old_InFeed IS NOT NULL
ORDER BY Log_Time DESC;
```

A row showing `Old_InFeed = <value> → New_InFeed = NULL` with an `App_Name` /
`Login_Name` / `Host_Name` that isn't the OPMS writer closes the case.
**Attribution limit:** identifies the application / login / host, not the human
— Budibase uses one shared DB login, so a Budibase hit is resolved to app/user
by matching the timestamp against Budibase's own audit log.

### Comms audit — archived, kept as evidence

The comms-audit instrumentation (`COMMS_AUDIT_SETUP.sql`,
`TRI_UPDATE_FILLER_V5.8_COMMS_AUDIT.sql`, `COMMS_AUDIT_QUERIES.sql`) is what
cleared the comms path. The instrumented trigger was **removed 2026-07-03** —
the canonical `pipeline/sql/TRI_UPDATE_FILLER_V5.8.sql` was re-deployed
(`CREATE OR ALTER`, live-safe). The `dbo.Comms_Audit` **table is kept** as the
timestamped proof that comms was healthy, for any hand-off to IT / the OPMS
owner.

| Event | Meaning | Points at |
|---|---|---|
| `HEARTBEAT` | 1 row/machine/minute while OPMS writes. Gaps = OPMS silent. | Network / OPMS |
| `NULLDATA` | Machine mid-production (step 8–13) arrived with NULL counters. | Network / OPMS |
| `MULTIROW` | One statement touched >1 machine row (bundled write). | Cross-machine stamp mechanism |

### Latent trigger weakness (not the cause of this case)

The Step-13 / Step-10 `[Change paper brik]` UPDATEs join `inserted` without
filtering `i.Machine_Step_No` (the `[Change strip]` twins in the same blocks do
filter it — an accidental omission). A multi-machine statement containing one
machine at step 13 would stamp every open batch in it. This is **unreachable in
practice as long as `MULTIROW` stays empty** in `Comms_Audit`. Worth fixing at
the next V5.8 touch regardless: add the step filter to both cpb UPDATEs, and
optionally gate the `[end time]` stamp on `i.counter_infeed IS NOT NULL`
(payload gate) so a single bad payload cannot burn a write-once F/G/H/K batch.

### Deploy order (SSMS)

**Trap (current):**
1. `CPB_WRITE_AUDIT.sql` — creates `dbo.CPB_Write_Audit` (step 1) and the audit
   trigger (step 2). No dependency on the OPMS write path; safe to deploy live.

**Comms audit (archived — only if re-opening the comms angle):**
1. `COMMS_AUDIT_SETUP.sql` — creates `dbo.Comms_Audit`. ⚠️ Must run **before**
   the instrumented trigger, which references the table (otherwise OPMS writes
   fail with an invalid-object error).
2. `TRI_UPDATE_FILLER_V5.8_COMMS_AUDIT.sql` — `CREATE OR ALTER` of the live
   trigger (canonical V5.8 + audit block, own TRY/CATCH).
3. Read with `COMMS_AUDIT_QUERIES.sql` (Q1 gaps, Q2 empty payloads, Q3 bundles,
   Q4 correlation).
4. Remove by re-running `pipeline/sql/TRI_UPDATE_FILLER_V5.8.sql`.

### Hand-off targets

- **Budibase / app owner (prime):** once `CPB_Write_Audit` names the app,
  review the form/automation bound to `[Change paper brik]` that saves whole
  rows, and stop it writing the counter columns (or refresh its schema so it
  round-trips all five columns).
- **IT / network & OPMS owner:** comms is cleared for this case, but the
  `Comms_Audit` archive (Q1/Q2 timestamps) is retained if the symptom ever
  proves to have a comms component.
