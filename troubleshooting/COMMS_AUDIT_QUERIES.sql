-- ============================================================
-- COMMS_AUDIT_QUERIES.sql                   (2026-07-02)
-- Database : DB_BUDIBASE
-- Purpose  : Read the evidence collected by the comms-audit
--            logger. Run each block separately in SSMS.
-- ============================================================

USE [DB_BUDIBASE]
GO

-- ------------------------------------------------------------
-- Q1. HEARTBEAT GAPS -- when did OPMS go silent, per machine?
-- One HEARTBEAT per machine per minute is normal. gap_seconds
-- >> 120 while the machine was producing = comms hole.
-- Hand these windows to IT: "check the link at these times."
-- ------------------------------------------------------------
SELECT Machine, Log_Time,
       DATEDIFF(SECOND,
                LAG(Log_Time) OVER (PARTITION BY Machine ORDER BY Log_Time),
                Log_Time) AS gap_seconds,
       Step, Infeed, Outfeed
FROM dbo.Comms_Audit
WHERE Event = 'HEARTBEAT'
ORDER BY Machine, Log_Time;

-- Only the suspicious gaps (> 3 min):
WITH hb AS (
    SELECT Machine, Log_Time,
           LAG(Log_Time) OVER (PARTITION BY Machine ORDER BY Log_Time) AS prev_time
    FROM dbo.Comms_Audit
    WHERE Event = 'HEARTBEAT'
)
SELECT Machine, prev_time AS silence_start, Log_Time AS silence_end,
       DATEDIFF(SECOND, prev_time, Log_Time) AS gap_seconds
FROM hb
WHERE DATEDIFF(SECOND, prev_time, Log_Time) > 180
ORDER BY prev_time;

-- ------------------------------------------------------------
-- Q2. NULLDATA -- when did OPMS deliver the step but no counts?
-- Every row here = "at this time, this machine's row arrived
-- mid-production with empty counters." This is the direct,
-- timestamped proof that the payload was already empty when it
-- reached SQL Server -- before any trigger logic ran.
-- ------------------------------------------------------------
SELECT Machine, Step, Infeed, Outfeed, Infeed_DE, Log_Time
FROM dbo.Comms_Audit
WHERE Event = 'NULLDATA'
ORDER BY Log_Time DESC;

-- ------------------------------------------------------------
-- Q3. MULTIROW -- did OPMS bundle several machines into one
-- statement? Detail = |Machine:Step|Machine:Step|...
-- A bundle containing a machine at step 13 alongside others is
-- the exact shape that lets one machine's step 13 stamp other
-- machines' open batches (missing step filter in the trigger).
-- ------------------------------------------------------------
SELECT ID, Detail, Log_Time
FROM dbo.Comms_Audit
WHERE Event = 'MULTIROW'
ORDER BY Log_Time DESC;

-- Bundles that contained a step-13 machine (the dangerous ones):
SELECT ID, Detail, Log_Time
FROM dbo.Comms_Audit
WHERE Event = 'MULTIROW'
  AND (Detail LIKE '%:13|%' OR Detail LIKE '%:13')
ORDER BY Log_Time DESC;

-- ------------------------------------------------------------
-- Q4. CORRELATE -- match audit events against the corrupted
-- batch rows. For each batch that lost its counters, what does
-- the audit log show in the 10 minutes around its [end time]?
-- ------------------------------------------------------------
SELECT cpb.ID AS Batch_ID, cpb.Machine, cpb.[end time],
       a.Event, a.Machine AS Audit_Machine, a.Step,
       a.Infeed, a.Outfeed, a.Detail, a.Log_Time
FROM [Change paper brik] cpb
JOIN dbo.Comms_Audit a
  ON a.Log_Time BETWEEN DATEADD(MINUTE, -10, cpb.[end time])
                    AND DATEADD(MINUTE,  10, cpb.[end time])
WHERE cpb.[end time] >= '2026-07-02'
  AND (cpb.In_Feed_MC IS NULL OR cpb.Out_Feed_MC IS NULL)
ORDER BY cpb.[end time], a.Log_Time;

-- ------------------------------------------------------------
-- Q5. The corrupted rows themselves (for the incident timeline)
-- ------------------------------------------------------------
SELECT ID, Machine, [Splicing time 1], [end time],
       In_Feed_MC, Out_Feed_MC, In_Feed_DE_MC, Sampling_Waste, End_time_CIP
FROM [Change paper brik]
WHERE [end time] >= '2026-06-29'
  AND (In_Feed_MC IS NULL OR Out_Feed_MC IS NULL)
ORDER BY [end time];

-- ------------------------------------------------------------
-- Q6. Audit log volume check (should stay modest --
-- heartbeats ~= machines x 1440/day). If MULTIROW floods,
-- that by itself answers the bundling question.
-- ------------------------------------------------------------
SELECT Event, COUNT(*) AS rows_logged,
       MIN(Log_Time) AS first_event, MAX(Log_Time) AS last_event
FROM dbo.Comms_Audit
GROUP BY Event;
