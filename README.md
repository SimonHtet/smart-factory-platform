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
| `TRI_UPDATE_FILLER_V5.4.sql` | Main event trigger on `T_M_Filler_Process` — splice tracking, downtime segments, CIP end time *(live)* |
| `TRI_UPDATE_FILLER_V5.3.sql` | Previous version — superseded by V5.4 |
| `TRI_TEMP_PRODUCTION_RUN.sql` | Temporary WMS-free production run tracker — Step 13 guard patched 2026-06-08; includes `TRI_UPDATE_SCANNED_BRIKS` (Step 4) for late scan support *(live)* |
| `V_GROUP_PRODUCTION_RUN.sql` | Group summary view over `temp_production_run` — A/D/M grouped, B1/B2 individual |

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

## SQL Trigger — TRI_UPDATE_FILLER_V5.4 *(live)*

Sub-second event capture for splice signals (~10ms pulse — too fast for Python polling). Runs alongside the Python pipeline on the same `T_M_Filler_Process` table.

**Events handled:**

| Transition | Event | Action |
|---|---|---|
| Step 10 | splice signal 0→1 | Write `Splicing time 1` |
| Step 13 | — | Write `end time`, `In_Feed_MC`, `Out_Feed_MC` |
| Step 14 + CIP=1 | A/D/M only | Write `End_time_CIP` (1-hour cooldown) |
| Step 11 → 8 | `START` | Increment `Downtime_Count`, stamp timer |
| Step 8 → 9 | `SEGMENT` | Log step-8 duration, reset timer |
| Step 9 → 10 | `SEGMENT` | Log step-9 duration, reset timer |
| Step 10 → 11 | `END` | Log step-10 warmup, close event |
| Step 8/9/10 → 7 | `ABORT` | Roll back via `Current_Event_Seconds` |

**Open batch detection (Step 13 guard — V5.4):**

| Machine group | Open batch condition |
|---|---|
| A / D / M | `End_time_CIP IS NULL` — batch stays open until CIP completes; Step 13 re-stamps `end time` + counters on every fire |
| F / G / H / K | `[end time] IS NULL` — write once |

> "Breakdown" in company terms means >30 min — that classification is applied at the reporting layer, not in the trigger.

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
