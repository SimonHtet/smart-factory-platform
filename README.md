# Smart Factory Platform

End-to-end manufacturing data platform built for DairyPlus Co., Ltd. (Bangkok) — covering 23 Tetra Pak filler machines across 3 dairy production plants.

Built in-house after a vendor MES was quoted at ฿3M+ — the purchase was never needed. The production-operations core went live across all 3 plants within 6 months of an 18-month internal plan and runs daily in production; SAP raw-material integration is in progress (~50% of full scope delivered).

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
| `TRI_UPDATE_FILLER_V5.8.sql` | Main event trigger on `T_M_Filler_Process` — V5.7 + **DE-line downtime isolation**: edge-detects the upstream feed's not-ready signal so the filler's *actual* downtime can be separated from idle time it didn't cause. *(latest)* |
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
    │  SQL Trigger V5.3               Python ingest_wms.py
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
│  Down_log                      raw_wms_*  (ingest landing)      │
│  t_log                         stg_*  (dbt views)               │
│                                mart_production_runs  (paused)   │
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

---

## SQL Trigger — TRI_UPDATE_FILLER_V5.8 *(latest)*

Sub-second event capture for splice signals (~10ms pulse — too fast for Python polling). Runs alongside the Python pipeline on the same `T_M_Filler_Process` table. Each version is strictly additive — V5.8 carries forward everything below and adds reel-splice capture (V5.7) and DE-line downtime isolation (V5.8).

**Events handled:**

| Transition | Event | Action |
|---|---|---|
| Step 10 | splice signal 0→1 | Write `Splicing time 1` |
| Step 13 | — | Write `end time`, `In_Feed_MC`, `Out_Feed_MC` |
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

**Open batch detection (Step 13 guard — V5.4):**

| Machine group | Open batch condition |
|---|---|
| A / D / M | `End_time_CIP IS NULL` — batch stays open until CIP completes; Step 13 re-stamps `end time` + counters on every fire |
| F / G / H / K | `[end time] IS NULL` — write once |

> "Breakdown" in company terms means >30 min — that classification is applied at the reporting layer, not in the trigger.

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
