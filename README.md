# Smart Factory Platform

![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![SQL Server](https://img.shields.io/badge/SQL%20Server-triggers%20%2B%20analytics-CC2927)
![dbt](https://img.shields.io/badge/dbt-sqlserver-FF694B?logo=dbt&logoColor=white)
![Power BI](https://img.shields.io/badge/Power%20BI-DirectQuery-F2C811)
![scikit-learn](https://img.shields.io/badge/scikit--learn-predictive%20maintenance-F7931E?logo=scikitlearn&logoColor=white)
![Status](https://img.shields.io/badge/status-live%20in%20production-brightgreen)
![Plants](https://img.shields.io/badge/plants-3-blue)
![Machines](https://img.shields.io/badge/filler%20machines-23-blue)

End-to-end manufacturing data platform built for DairyPlus Co., Ltd. (Bangkok) — covering 23 Tetra Pak filler machines across 3 dairy production plants.

Built in-house after a vendor MES was quoted at ฿3M+ — the purchase was never needed. The production-operations core went live across all 3 plants within 6 months of an 18-month internal plan and runs daily in production; SAP raw-material integration is in progress (~50% of full scope delivered).

---

## 🏆 Achievements

- **฿3M+ vendor purchase averted** — the quoted MES was never bought; this platform replaced it
- **6 months to live** across all 3 plants, against an 18-month internal plan
- **23 machines, 1-second polling** — sub-second SQL trigger event capture alongside a Python pipeline, running daily in production
- **16+ Budibase low-code apps, 100+ daily active users** on the production floor, fed by this platform
- **Director-level KPIs** — Power BI efficiency/waste/yield dashboard reviewed weekly by management
- **Recall-grade traceability** — reel → pallet genealogy that reverse-maps any finished pallet to its supplier reels
- **Root-caused a silent data-corruption incident** — a write-audit trap caught a second writer overwriting PLC counters; hardened with a guard trigger (`TRI_CPB_FEED_GUARD`) that makes the regression impossible
- **Formalized into company SOP** — the platform's change management and architecture are codified in the official Digital Transformation SOP (DTO-SOP-001, ISO/IEC 27001 aligned), approved at management level

---

## What's in Here

| Folder | Description |
|--------|-------------|
| [`pipeline/`](pipeline/) | Python event pipeline — polls PLC data at 1-second intervals, processes machine step transitions |
| [`pipeline/sql/`](pipeline/sql/) | SQL triggers and utility scripts (see table below) |
| [`dashboard/`](dashboard/) | Power BI KPI dashboard — machine efficiency, yield, waste, reviewed at director level |
| [`notebooks/`](notebooks/) | Predictive maintenance prototype — scikit-learn on OPMS sensor data |

### SQL Files

| File | Purpose |
|------|---------|
| `TRI_UPDATE_FILLER_V6.1.sql` | V6 + **power-cut downtime capture**: a power cut drops a machine to step 0 and needs the full restart ramp, but only the `11→8→0` path was counted, and only by accident. Adds an `11→7` stash and a `→0` big-downtime OPEN, folds `Feed_Segment_log` into the Step-13 counter snapshot, and logs every non-`11→8` exit from step 11 as `_DT:EDGE`. *(latest — written 2026-08-21, **NOT deployed**; branch `v6.1-power-cut-downtime`)* |
| `TRI_UPDATE_FILLER_V6.sql` | Main event trigger on `T_M_Filler_Process` — V5.8 + **DE downtime subordinated to the filling state machine**: inside a filling-downtime window the whole stop is credited to DE as a single episode (edge spikes swallowed) instead of a noisy 0-1-0-1 stream; Step 13 closes any still-open DE episode at batch end (truncated at end time); plus a step-filter hardening patch. Changes KPI *semantics*, hence V6 not V5.9. *(live in production 2026-08-06)* |
| `TRI_UPDATE_FILLER_V5.8.sql` | V5.7 + **DE-line downtime isolation**: edge-detects the upstream feed's not-ready signal so the filler's *actual* downtime can be separated from idle time it didn't cause. Superseded by V6. |
| `TRI_UPDATE_FILLER_V5.7.sql` | V5.6 + **reel→pallet traceability capture**: logs the outfeed counter at each real reel splice to `Reel_Splice_log` for recall genealogy. Superseded by V5.8. |
| `TRI_UPDATE_FILLER_V5.6.sql` | V5.5 + big-downtime *duration* tracking (`Big_Downtime_log`): a breakdown goes `11→8→7→12→13→14` (no CIP) and aborts out of the mini-stoppage logic, so its time loss is captured separately. |
| `TRI_UPDATE_FILLER_V5.5.sql` | V5.4 + big-downtime *throughput* correction (`Feed_Segment_log`): the feed counter resets to 0 mid-batch without a CIP (`130000→0→150000`); pre-reset values are logged and re-summed so totals are correct. |
| `TRI_UPDATE_FILLER_V5.4.sql` | Splice tracking, mini-downtime segments, CIP end time — superseded |
| `DE_DOWNTIME_SETUP.sql` | One-time setup for V5.8 — creates `DE_Downtime_log` and the supporting columns. |
| `V_REEL_PALLET.sql` | Reel→pallet recall views (`v_reel_pallet_estimate`, `v_reel_pallet_map`) — see Traceability section below. |
| `TRI_TEMP_PRODUCTION_RUN.sql` | Temporary WMS-free production run tracker — Step 13 guard patched 2026-06-08; surfaces DE-downtime + actual-downtime columns (V5.8); includes `TRI_UPDATE_SCANNED_BRIKS` (Step 4) for late scan support *(live)* |
| `V_GROUP_PRODUCTION_RUN.sql` | Group summary view over `temp_production_run` — A/D/M grouped, B1/B2 individual; adds back big-downtime feed loss (V5.5), exposes big-downtime time loss (V5.6) and DE-line downtime (V5.8), each separate from mini-stoppage downtime |

**Big-downtime model (A/B/D/M, the CIP groups):** a real breakdown resets the OPMS feed counter to 0 and does an intermediate CIP (ICIP) with **no `Signal_Final_CIP`**, vs a normal finish which raises it (FCIP). `End_time_CIP IS NULL` is the single discriminator throughout — no CIP ⇒ same batch continuing (accumulate throughput + count the time loss); CIP ⇒ legitimate run end (ignore).

---

## Current Status — WMS Ingest Paused

`ingest_wms.py` is currently paused pending IT security review and formal approval under the internal change management process (DTO-SOP-001). While that's in progress, `mart_production_runs` (which depends on WMS data) is unavailable as the live Power BI source.

**Temporary solution: `analytics.temp_production_run`**

A SQL trigger (`TRI_TEMP_PRODUCTION_RUN`) on `T_M_Filler_Process` builds a WMS-free production run table in real time — tracking efficiency, waste, and downtime without the FG/WMS columns. Power BI points here until WMS ingest is restored.

Once IT approval comes through, WMS ingest resumes and Power BI reverts to `mart_production_runs_view`.

---

## Architecture

```
PLC Hardware (23 Tetra Pak fillers)
    │
    ▼
OPMS Server (172.22.x.x) — Tetra Pak proprietary system
  Collects PLC machine state in real time.
  Read-only access — OPMS writes directly into DB_BUDIBASE.dbo.T_M_Filler_Process.
    │
    ▼
WMS Server (172.22.x.x) — WMSDairyPlus2015
  Finished goods tracking — carton scanning, product resends.
  Read-only access.  [INGEST PAUSED — IT security review]
    │
    │  SQL Trigger V6                 Python ingest_wms.py
    │  fires on T_M_Filler_Process    every 5 min via Task Scheduler
    │  (event-driven, sub-second)     [PAUSED]
    ▼                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                 DB_BUDIBASE  172.22.x.x  (db_owner)            │
│                                                                 │
│  dbo.*                         analytics.*                      │
│  ──────────────────            ─────────────────────────────    │
│  T_M_Filler_Process            temp_production_run  ◄── live    │
│  [Change paper brik]           v_group_production_run           │
│  [Change strip]                raw_wms_*  (ingest landing)      │
│  Down_log          (mini)      stg_*  (dbt views)               │
│  Big_Downtime_log  (big)       mart_production_runs  (paused)   │
│  DE_Downtime_log   (DE)                                         │
│  Feed_Segment_log  (resets)                                     │
│  Reel_Splice_log   (recall)                                     │
│  t_log                                                          │
└──────────────────────┬──────────────────────────────────────────┘
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
      Power BI               Budibase Apps
      temp_production_run    16+ apps, 100+ DAU
      (temporary source)
```

---

## Data Flow

**Normal (WMS active):**
```
PLC → T_M_Filler_Process → [Change paper brik]  ─┐
WMS → raw_wms_*                                   ├─► mart_production_runs ──► Power BI
                                                  ┘   (dbt, every 10 min)
```

**Current (WMS paused):**
```
PLC → T_M_Filler_Process ──► temp_production_run ──► Power BI
         (TRI_TEMP_PRODUCTION_RUN, event-driven)
```

**Downtime + counter capture (trigger-side):**
```
                      ┌──► Down_log          mini stops      11→8→9→10→11
T_M_Filler_Process ───┼──► Big_Downtime_log  breakdowns      11→8→7→12  /  11→7→0  (V6.1)
  (TRI_UPDATE_        ├──► DE_Downtime_log   DE-line stalls  signal_DE_NotReady
   FILLER_V6.1)       └──► Feed_Segment_log  counter resets  counter_infeed → 0
                                                    │
                                                    ▼  folded in at Step 13 (V6.1)
                                    [Change paper brik].In_Feed_MC / Out_Feed_MC
```
Each log is a separate episode stream so the analytics layer can attribute loss
independently: mini stoppages, breakdowns, and DE-line stalls never double-count
each other. `Feed_Segment_log` is the only one that feeds *back* into the batch
row — V6.1 folds its pre-reset segments into the Step-13 counter snapshot.

---

## SQL Trigger — TRI_UPDATE_FILLER_V6 *(latest — live in production 2026-08-06)*

Sub-second event capture for splice signals (~10ms pulse — too fast for Python polling). Runs alongside the Python pipeline on the same `T_M_Filler_Process` table. Each version carries the ones below forward — V6 keeps everything through V5.8 (reel-splice capture V5.7, DE-line downtime isolation V5.8) and refines the DE accounting: inside a filling-downtime window the whole stop is credited to DE as one episode rather than a noisy edge stream, and Step 13 closes any still-open DE episode at batch end.

**Events handled:**

| Transition | Event | Action |
|---|---|---|
| Step 10 | splice signal 0→1 | Write `Splicing time 1` |
| Step 13 | — | Write `end time`, `In_Feed_MC`, `Out_Feed_MC` (V6.1: folds `Feed_Segment_log` in — true batch total) |
| Step 14 + CIP=1 | A/B/D/M | Write `End_time_CIP` (1-hour cooldown) |
| Step 11 → 8 | `START` | Increment `Downtime_Count`, stamp timer |
| Step 8 → 9 | `SEGMENT` | Log step-8 duration, reset timer |
| Step 9 → 10 | `SEGMENT` | Log step-9 duration, reset timer |
| Step 10 → 11 | `END` | Log step-10 warmup, close event |
| Step 8/9/10 → 7 | `ABORT` | Roll back mini-stoppage; stash stop time for big-downtime |
| counter → 0 | `_BD:RESET` (V5.5) | Log pre-reset feed to `Feed_Segment_log` (big-downtime throughput) |
| Step 7 → 12 | `_BDL:OPEN` (V5.6) | Open `Big_Downtime_log` row (big-downtime time loss starts) |
| Step 14 + CIP=1 | `_BDL:VOID` (V5.6) | FCIP ⇒ intentional end ⇒ void the open big-downtime row |
| → Step 11 | `_BDL:CLOSE` (V5.6) | Resume with no CIP ⇒ close row, stamp duration (the loss) |
| real reel splice | `_RS` (V5.7) | Log outfeed counter to `Reel_Splice_log` (`Splice_No` = kth end-roll) for recall genealogy |
| `signal_DE_NotReady` 0→1 | `_DE:START` (V5.8) | Open `DE_Downtime_log` row — upstream feed not ready, stamp start (only once past Step 10 / motor start) |
| `signal_DE_NotReady` 1→0 | `_DE:END` (V5.8) | Close row, stamp `Duration_Seconds`, add to the batch's `Total_DE_Downtime_Seconds` |
| Step 11 → 7 | `_BDL:STASH` (V6.1) | Hardware-fault drop straight to 7 — stash the stop time, open no mini event |
| → Step 0 | `_BDL:OPEN` (V6.1) | Powered down — open `Big_Downtime_log`, absorbing an open mini event if there is one |
| Step 11 → *(not 8)* | `_DT:EDGE` (V6.1) | Observability only, **all** machines — which machines bypass step 8 on a stop |

**Open batch detection (Step 13 guard — V5.4):**

| Machine group | Open batch condition |
|---|---|
| A / D / M | `End_time_CIP IS NULL` — batch stays open until CIP completes; Step 13 re-stamps `end time` + counters on every fire |
| F / G / H / K | `[end time] IS NULL` — write once |

> "Breakdown" in company terms means >30 min — that classification is applied at the reporting layer, not in the trigger.

### V6.1 — Power-Cut Downtime *(written 2026-08-21, not deployed)*

A power cut drops a machine to **step 0** and recovery needs the full restart ramp `0→14→1→3→4→5→6→7→8→9→10→11`. Only one of the two entry paths was ever counted, and only by accident:

| Path | V6 behaviour |
|---|---|
| `11→8→0→…→11` (most machines) | **Counted, accidentally.** `START` stamps the timer at `11→8`; nothing in the ramp matches an `ABORT` (`6→7` is not `8/9/10→7`) or a second `START` (`7→8` is not `11→8`), so the ramp's `8→9` `SEGMENT` logs the whole outage as "step 8 dwell". |
| `11→7→0→…→11` (older hardware, seen on M1) | **Lost.** Nothing opens at `11→7`, so the ramp's `8→9` is correctly swallowed by the `Current_Downtime_Start IS NOT NULL` guard and the outage leaves no trace. |

V6.1 routes both to `Big_Downtime_log`, since either way the machine needed a full restart:

- **`11→7`** stashes `BigDT_Pending_Start` and opens no mini event, mirroring the stash the `8/9/10→7` `ABORT` already does.
- **`→0`** opens the big-downtime row. The existing `7→12` OPEN cannot fire on a power cut — there is no step 12 anywhere in the restart ramp. Start time is taken, in order, from: an open mini event (absorbed — its seconds rolled back and its count decremented, so `11→8→0` moves MINI→BIG and one physical event lands in one bucket), else `BigDT_Pending_Start`, else now.
- Closes at `→ step 11` via the existing V5.6 `_BDL:CLOSE`, unchanged.

**Step-13 counter fold.** `In_Feed_MC` / `Out_Feed_MC` now carry the *true* batch total: the pre-reset segments in `Feed_Segment_log` are folded into the Step-13 snapshot. The base stays `i.counter_*` (live PLC) rather than `cpb.In_Feed_MC`, so the A/B/D/M Step-13 re-fire recomputes instead of accumulating onto its own previous write. `Sampling_Waste` is deliberately left on the raw counters — `Feed_Segment_log` has no DE column, so folding outfeed but not `counter_infeed_DE` would make the subtraction meaningless.

> ⚠ **Pairs with a `V_GROUP_PRODUCTION_RUN` change that is not yet written.** The view folds `Feed_Segment_log` in itself; once `[Change paper brik]` carries the total, closed batches double-count. Its `seg` CTE needs gating to open batches (`[end time] IS NULL`) — gating rather than removing, because `plant3-rt-counters` keeps `In_Feed_MC` raw mid-run for M1/M2/M3, so the view must still fold while the batch is open.

**Scope:** `A%/B%/D%/M%`, matching every other `Big_Downtime_log` branch — M1 is covered. The `_DT:EDGE` tag fires on **all** machines with no state change, so if F/G/H/K also bypass step 8 it will show up in `t_log` without a behaviour change first.

**Known gap:** a *hard* power cut writes nothing, so there is no `→0` edge to fire on and the outage stays invisible. This handles the soft descent only, where the PLC survives long enough to write step 0.

---

## Reel → Pallet Traceability (Recall Genealogy)

Reverse traceability for product recall: a bad finished pallet → the supplier reel(s) that fed it → every other pallet those reels touched. Views: `v_reel_pallet_estimate` (reel-level), `v_reel_pallet_map` (the many-to-many recall surface). Files: `V_REEL_PALLET.sql`, `TRI_UPDATE_FILLER_V5.7.sql`.

**Method — supplier-declared counts, cumulative-summed (exact, retroactive):** each reel slot on `[Change paper brik]` carries the briks the supplier declares for that reel. Cumulatively summing them gives each reel a `start_count … end_count` span; dividing by the pallet size maps it to a pallet range, using `FLOOR`/`CEILING` so a reel straddling a boundary is flagged for **both** pallets (recall-safe over-inclusion).

**Why not the live outfeed counter:** capturing the counter at each splice is more precise on waste, but the raw counter *resets* mid-run (`1 → 130k → repeat`) and depends on catching every reset — one missed reset silently points a recall at the wrong product. The supplier-count method is **monotonic by construction**: its error is small, bounded, and washes out once the warehouse real-number reconciliation takes over. **Design rule: for recall, a bounded predictable error beats a silent catastrophic one.** (The counter-at-splice variant is kept in `Reel_Splice_log` for a future counter-accurate version on a clean full batch.)

Two raw-data quirks handled in the views: the PLC repeats the same `(Order, Reel)` across consecutive columns while one reel runs (deduped via `LAG` + `ROW_NUMBER`), and pallet numbering resets per **supplier run** — a reel change within one supplier keeps counting, a supplier change restarts at 1 — so `pallet_no` is not unique per batch and recall-by-pallet filters `supplier_no` + `pallet_no` (`order_no` kept for reference).

---

## DE-Line Downtime Isolation (V5.8)

The TBA filler sits idle whenever the upstream DE line isn't ready — time that was previously buried inside total downtime and unfairly charged to the filler. V5.8 edge-detects `signal_DE_NotReady` (0=OK, 1=down) on every machine: `0→1` opens a `DE_Downtime_log` row, `1→0` closes it and accumulates the duration onto the batch. The analytics layer then computes:

```
tba_actual_downtime = total_downtime − de_downtime     (floored at 0)
```

so efficiency KPIs reflect the filler's *true* performance. Pure binary edge — no step machine, no segments — and strictly additive over V5.7. `DE_DOWNTIME_SETUP.sql` creates the log table and supporting columns; `temp_production_run` and `v_group_production_run` surface both the raw DE downtime and the corrected actual-downtime figures, kept separate from mini- and big-downtime so each loss category stays auditable.

**Motor-start gate (rev 2026-06-24):** a DE episode only opens once the filler has actually reached **Step 10 (motor start)** for the batch — detected via `[Splicing time 1] IS NOT NULL`, the same marker the Step 13 guard uses. A DE-not-ready signal raised during startup, before the production loop begins, isn't lost output and is ignored. The `1→0` close is a no-op when no episode was opened, so the guard sits entirely on the open side.

---

## 🤖 Machine Learning

### Predictive Maintenance — Breakdown Risk Scoring

[`notebooks/predictive_maintenance_prototype.ipynb`](notebooks/predictive_maintenance_prototype.ipynb)

Random Forest classifier (scikit-learn) that scores each filler machine's **breakdown risk as a continuous 0–100% probability** — shifting maintenance from reactive to proactive. Features are the same signals the live pipeline already collects:

| Feature | Source | Why it matters |
|---|---|---|
| `Running_Hour` | PLC odometer counter | Wear accumulates with runtime |
| `Heat_C` | Temperature sensor | Abnormal heat = friction or lubrication failure |
| `Vibration` | Vibration sensor | Imbalance or bearing wear shows up here first |

`predict_proba` risk scores feed a threshold-based maintenance alert (≥70% ⇒ flag for inspection), and `feature_importances_` shows which sensor signals matter most — useful for prioritising sensor calibration. Currently a prototype on simulated data; the production path (live `pyodbc` telemetry → retrain on historical breakdown labels → SQL Server Agent inference per shift → risk scores back to Power BI alert tiles) rides entirely on infrastructure that already exists in `pipeline/`.

### Jarvis for the Factory Floor — GenAI over Production Data

Databricks hackathon project: a GenAI assistant that answers natural-language questions over this platform's production data — "which machine had the most downtime last week?", "show me waste% by product" — without the asker needing SQL. Built on the same layered data model (raw signals → event processing → marts) that powers the Power BI reporting.

### Next: MLOps

Airflow and MLflow are approved under the company Digital Transformation SOP (DTO-SOP-001) — the orchestration and experiment-tracking layer for moving the predictive maintenance model from notebook prototype to scheduled, versioned production inference.

---

## mart_production_runs — Column Reference

*(Full mart available when WMS ingest is active)*

| Column | Source | Formula |
|---|---|---|
| run_key | [Change paper brik] | YYYYMMDD + machine |
| product_date | [Change paper brik] | Production date |
| plan_production_date | stg_wms_transactions | Via ReceivedNo → receive_item |
| start_time / end_time | [Change paper brik] | Splice time / end time |
| run_duration_minutes | derived | DATEDIFF(minute, start, end) |
| in_feed_mc / out_feed_mc | [Change paper brik] | TBA meter counts |
| waste_tba | derived | in_feed_mc − out_feed_mc |
| scanned_briks | [Change paper brik] | Barcode scanner total |
| waste_op | derived | scanned_briks − in_feed_mc |
| transaction_briks | stg_wms_transactions | SUM(in_carton_amount × numbit) |
| resend_briks | stg_wms_receive_item_location | SUM(resend_amount × numbit) |
| fg_briks_amount | derived | transaction_briks − resend_briks |
| waste_de | derived | out_feed_mc − fg_briks_amount |
| efficiency | derived | fg_briks_amount / (run_duration_minutes × 400) |
| downtime_count | [Change paper brik] | V5.3 trigger |
| total_downtime_seconds | [Change paper brik] | V5.3 trigger |

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Event pipeline | Python 3.12, pyodbc |
| WMS ingest | Python 3.12, pyodbc, watermark-based incremental |
| Transformation | dbt-sqlserver |
| Database | SQL Server (on-premise, 3 servers) |
| BI / Reporting | Power BI — DirectQuery |
| Orchestration | Windows Task Scheduler (Airflow planned) |
| Source data | Tetra Pak PLC → OPMS → SQL Server |
