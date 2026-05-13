# Smart Factory Platform

End-to-end manufacturing data platform built for DairyPlus Co., Ltd. (Bangkok) — covering 23 Tetra Pak filler machines across 3 dairy production plants.

Built in-house to replace a ฿1M+ vendor quote for custom MES trigger logic and reporting. Delivered in 6 months against an 18-month vendor timeline.

---

## What's in Here

| Folder | Description |
|--------|-------------|
| [`pipeline/`](pipeline/) | Python event pipeline — replaces SQL Server triggers, polls PLC data at 1-second intervals, processes machine step transitions |
| [`dashboard/`](dashboard/) | Power BI KPI dashboard — machine efficiency, yield per batch, waste analysis, reviewed weekly at director level |

---

## Architecture

```
PLC Hardware (23 Tetra Pak fillers)
    │
    ▼
SQL Server — T_M_Filler_Process
    │                         │
    ├── SQL Trigger (V4)       │  Python pipeline
    │   step transitions       │  1-second poll loop
    │   downtime logging       │
    ▼                         ▼
Processed tables          KPI Dashboard (Power BI DirectQuery)
  [Change paper brik]     efficiency, yield, waste %, batch analysis
  [Change strip]
  [Down_log]   ← downtime events (START / END / ABORT per batch)
  t_log        ← general audit trail
  endtime_log_test
```

---

## Pipeline

Replaces SQL Server triggers that caused race conditions and row locking under concurrent PLC writes at scale. The Python process owns the state machine explicitly — polling, diffing, routing events to handlers with in-memory cooldowns.

→ See [`pipeline/`](pipeline/) for full details.

---

## SQL Trigger — TRI_UPDATE_FILLER_V4

For events that require sub-second capture (splice signals pulse in ~10ms — too fast for a 1-second Python poll), a SQL trigger runs alongside the Python pipeline. V4 adds downtime tracking on top of the splice/CIP logic from V3.

**Downtime events logged to `[Down_log]`:**

| Transition | Event | What's recorded |
|---|---|---|
| Step 11 → 8 | `START` | Machine, Batch_ID, stop count |
| Step 8 → any (not 7) | `END` | Duration in seconds, cumulative total |
| Step 8 → 7 | `ABORT` | Batch abandoned — downtime data nullified |

> `[Down_log]` is a structured audit table — queryable per machine/batch unlike the raw text in `t_log`. "Breakdown" in company terms means >30 min; that classification is applied at the reporting layer from `Total_Downtime_Seconds`.

→ See [`pipeline/sql/TRI_UPDATE_FILLER_V4.sql`](pipeline/sql/TRI_UPDATE_FILLER_V4.sql)

---

## Dashboard

Power BI report tracking production KPIs across all machines and plants. Data sourced directly from the factory SQL Server database.

**KPIs tracked:**
- Machine efficiency (FG output / TBA running hour)
- Yield per batch (actual vs. expected)
- Waste volume and category breakdown
- Waste percentage trended over time

→ See [`dashboard/`](dashboard/) for screenshots and DAX measures.

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Event pipeline | Python 3.12, pyodbc |
| Database | SQL Server (on-premise, 3 plants) |
| BI / Reporting | Power BI Desktop + Gateway |
| Source data | Tetra Pak PLC → SQL Server |
| Deployment | Windows Task Scheduler |
