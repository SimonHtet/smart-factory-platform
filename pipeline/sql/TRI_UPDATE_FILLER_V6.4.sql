-- ============================================================
-- TRI_UPDATE_FILLER_V6.4
-- Database : DB_BUDIBASE
-- Table    : T_M_Filler_Process
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- WHAT CHANGED IN V6.4  (2026-08-27)
-- -------------------------------------------------------
-- ROOT CAUSE of the "previous loop's feed appears in this batch" bug,
-- proven from t_log on M1, 2026-08-26 (local times; embedded times UTC):
--
--   20:02:49  _BD:STASHCNT   ...ID=6526  infeed=458457   <- stash on 6526
--   20:56:47  _FLAVORBACKFILL pid=260827-...-M1          <- batch 6539 CREATED (27 Aug)
--   20:58:42  _BDL:OPEN step=1->0 ID=6539                <- downtime on the WRONG batch
--   22:48:29  _BD:RESET      ...ID=6539  infeed=458457   <- SEGMENT on the WRONG batch
--   23:07:15  _S14:CIP=1     ...ID=6526                  <- CIP stamped 19 min LATER
--
-- `MAX(ID) WHERE End_time_CIP IS NULL` is NOT a current-batch test. The
-- next loop's row is created before this loop's CIP is stamped, so MAX(ID)
-- resolves to a FUTURE batch. The 26 Aug counter was written as a segment
-- onto the 27 Aug batch, and Step 13 folded it in.
--
-- V5.5's guard rested on the comment's assumption that "clean finishes
-- stamp End_time_CIP hours before the counter zeros". Here it was the
-- other way round, by 19 minutes.
--
-- FIX: the batch that owns the counter must be RUNNING --
--      [Splicing time 1] IS NOT NULL AND [end time] IS NULL.
-- If no batch is running, the reset is a loop boundary and nothing is
-- logged (which is the correct answer for 22:48 above).
--
-- Applied at three points:
--   1) _BD:RESET  (V5.5 segment)      -> running batch
--   2) _BD:STASHCNT (V6.2 stash)      -> running batch
--   3) _BD:SEG0 commit                -> new @GID_SEG_Z0, resolved
--      independently of @GID_Z0. V6.2 asserted the stash and the commit
--      "can never land on different rows" -- FALSE, and it is why no
--      _BD:SEG0 appears in the M1 log at all: the stash was on 6526 and
--      the commit looked on 6539, found NULL, and wrote nothing.
--
-- @GID_Z0 itself is UNCHANGED -- it drives Big_Downtime_log and carries
-- V5.6's ICIP semantics.
--
-- !! NOT FIXED HERE -- NEEDS A DECISION !!
-- The same wrong batch hit the downtime side: _BDL:OPEN went to 6539 and
-- closed at dur=18062s -- a FIVE-HOUR fake breakdown on the 27 Aug batch,
-- which was really just idle time between loops. Fixing that means
-- changing V5.6's `End_time_CIP IS NULL` discriminator, which is the
-- core of the big-downtime design, so it is deliberately left alone.
--
-- WHAT CHANGED IN V6.3  (2026-08-27)
-- -------------------------------------------------------
-- V6.2 BUG FOUND IN PRODUCTION: bogus _BD:SEG0 segments.
-- V6.2 stashed the counter on ANY exit from step 11 and committed on
-- ANY arrival at step 0, with nothing clearing the stash in between.
-- So a machine that stopped briefly in the morning and was then parked
-- at rest for a few hours -- passing through step 0 -- committed a
-- segment built from a counter value hours out of date. Step 13 folded
-- it in and [Change paper brik] came out carrying feed that belonged to
-- an earlier part of the day. temp_production_run was unaffected (it
-- reads the PLC counter directly), which is exactly the signature that
-- was observed.
--
-- V6.3 makes the segment conditional on the real breakdown PATH:
--   1) STASH narrowed to 11->8 and 11->7 only (was: any exit from 11).
--   2) NEW STASH CLEAR: any move to a step outside (0, 7, 8) discards
--      the stash -- the machine recovered, or was never down.
--   3) ->0 commit unchanged; it already requires a stash to exist.
--
--   11->8->0  /  11->7->0   -> segment            (real breakdown)
--   11->8->9->10->11        -> cleared, no segment (recovery)
--   idle/rest ->0           -> no stash, no segment
--
-- A/B/D/M only throughout, unchanged.
--
-- STILL OPEN, NOT FIXED HERE: _BD:RESET (V5.5) attaches a segment to
-- MAX(ID) WHERE End_time_CIP IS NULL, guarded only by the assumption
-- that "clean finishes stamp End_time_CIP hours before the counter
-- zeros". When CIP is late or missed, a normal end-of-loop counter
-- reset is logged as a BREAKDOWN segment against the NEXT loop's batch.
-- Separate root cause, separate fix -- see the diagnostic queries.
--
-- WHAT CHANGED IN V6.2  (2026-08-24)
-- -------------------------------------------------------
-- Motivation: the feed counter is only preserved when V5.5's
-- _BD:RESET sees the counter EDGE d.counter_infeed > 0 -> i = 0.
-- When the PLC dies outright it stops writing, and by the time it
-- writes again the counter has already climbed off zero
-- (359250 -> 1500 in one update). The edge never happens, no
-- segment is logged, and the pre-cut feed is gone. There is also
-- no CIP on that path, so nothing else closes the batch either.
--
-- Fix: stop relying on the counter edge. Watch the STEPS instead.
--
-- 1) STASH ON LEAVING STEP 11 (A/B/D/M). Any 11 -> anything-else
--    transition stashes the still-good d.counter_infeed /
--    d.counter_outfeed into BigDT_Pending_Infeed / _Outfeed.
--    Deliberately ALL exits from 11, not just 11->8 and 11->7, so
--    a straight 11->0 is covered too. OVERWRITES on every exit --
--    NOT guarded by IS NULL like BigDT_Pending_Start. A harmless
--    mini downtime early in the batch must not pin the stash to a
--    stale low value that a real outage hours later would commit.
--    Mini downtimes never reach step 0, so an uncommitted stash
--    just gets overwritten by the next exit. Costs one UPDATE per
--    stop; opens no event and changes no downtime state.
--
-- 2) COMMIT AT ->0. The existing ->0 branch now also writes the
--    stashed counters to Feed_Segment_log as Ended_By='POWERCUT',
--    then clears the stash. Inside the same
--    "NOT EXISTS ... Status='OPEN'" guard as the Big_Downtime_log
--    insert, so a 0->x->0 bounce cannot log twice.
--
-- 3) DUPLICATE GUARD, BOTH WAYS. If an outage BOTH passes through
--    step 0 AND zeroes the counter, the ->0 commit and _BD:RESET
--    would each log a segment and Step 13 would fold both. Both
--    paths capture the SAME pre-reset counter by construction, so
--    each now skips when Feed_Segment_log already holds a row for
--    this Batch_ID with that In_Feed_Seg. _BD:RESET also clears the
--    stash, so a consumed counter cannot be committed twice.
--    Caveat: two genuine breakdowns resetting at an identical
--    counter value in one batch would collapse to one segment.
--    Six-digit counters make that vanishingly unlikely.
--
-- Nothing downstream changes. V6.1's Step-13 fold already computes
-- In_Feed_MC = i.counter_infeed + SUM(Feed_Segment_log), and for
-- A/B/D/M it RE-FIRES while End_time_CIP IS NULL -- so the moment a
-- segment exists the next re-fire self-heals the total. No CIP-side
-- work is needed.
--
-- DEPLOY ORDER (V6.2):
--   1. Run V6.2_ALTER_COLUMNS.sql -- adds BigDT_Pending_Infeed /
--      _Outfeed. Additive, idempotent, no rebuild.
--   2. DROP TRIGGER [dbo].[TRI_UPDATE_FILLER_V6_2]   -- avoid double-fire
--      (V6.3 was never deployed -- V6.4 supersedes it)
--   3. Run this script (creates TRI_UPDATE_FILLER_V6_4).
--      Columns already exist from V6.2 -- the ALTER is a no-op.
--   4. NO other object changes. TRI_TEMP_PRODUCTION_RUN reads the PLC
--      counter, not cpb, so it is unaffected. TRI_CPB_FEED_GUARD
--      exempts nested writes. V_GROUP_PRODUCTION_RUN stays AS IS --
--      see the 2026-08-24 correction; do NOT gate its seg CTE.
--
-- STILL NOT FIXED: a hard cut where the PLC never writes step 0 at
-- all. No edge, no stash commit. Needs a heartbeat/staleness
-- detector on resume, not an edge trigger.
--
-- WHAT CHANGED IN V6.1  (2026-08-21)
-- -------------------------------------------------------
-- Motivation: on a power cut most machines drop 11->8->0, but some
-- (observed on M1, old hardware) drop 11->7->0. Both then need the
-- full restart ramp 0->14->1->3->4->5->6->7->8->9->10->11.
--
-- The 11->8->0 path counted only BY ACCIDENT: START stamped
-- Current_Downtime_Start at 11->8, nothing in the ramp matched an
-- ABORT (6->7 is not 8/9/10->7) or a second START (7->8 is not
-- 11->8), so the 8->9 SEGMENT on the way back logged the whole
-- outage as "step 8 dwell". The 11->7 path opened nothing at all,
-- and its 8->9 SEGMENT was correctly swallowed by the
-- "Current_Downtime_Start IS NOT NULL" guard -> outage lost.
--
-- 1) 11->7 STASH. A drop straight to 7 stashes BigDT_Pending_Start
--    and opens no mini event. Mirrors the stash the 8/9/10->7
--    ABORT already does.
--
-- 2) ->0 BIG DOWNTIME OPEN. Step 0 = powered down, and recovery
--    always needs the full restart ramp, so this is a BREAKDOWN
--    whether the machine fell through 7 or 8. Note the existing
--    7->12 OPEN is NOT reachable on a power cut -- there is no
--    step 12 anywhere in the restart ramp.
--    Start time, in priority order:
--      1. an OPEN mini event -> absorb it (roll back its seconds,
--         decrement the count) and use its start. This is the
--         11->8->0 case, moved from MINI to BIG so one physical
--         event lands in one bucket.
--      2. BigDT_Pending_Start -> the 11->7 case from (1).
--      3. GETUTCDATE() -> fell to 0 from somewhere else.
--    Closes at -> step 11 via the existing V5.6 CLOSE, unchanged.
--
-- 3) STEP-13 FEED FOLD. [Change paper brik].In_Feed_MC /
--    Out_Feed_MC now carry the TRUE batch total: the pre-reset
--    breakdown segments in Feed_Segment_log are folded into the
--    Step-13 snapshot. Base stays i.counter_* (live PLC), never
--    cpb.In_Feed_MC, so the A/B/D/M Step-13 re-fire recomputes
--    instead of accumulating onto its own previous write.
--    !! REQUIRES the paired V_GROUP_PRODUCTION_RUN change: its
--    `seg` CTE must fold segments only for batches still OPEN
--    ([end time] IS NULL), else closed batches double-count.
--    Sampling_Waste deliberately left on the raw counters --
--    Feed_Segment_log has no DE column, so folding outfeed but
--    not counter_infeed_DE would make the subtraction meaningless.
--
-- 4) EDGE OBSERVABILITY. Every exit from step 11 that is not
--    11->8 is logged to t_log as _DT:EDGE, ALL machines, no state
--    change. The big-downtime branches are scoped A/B/D/M, so this
--    is how F/G/H/K/E1/J1 surface if they use the same path.
--
-- SCOPE NOTE: (1) and (2) are scoped A%/B%/D%/M% to match every
-- other Big_Downtime_log branch. M1 is covered. If _DT:EDGE shows
-- F/G/H/K doing 11->7, the filter AND the batch selection need
-- rework -- big downtime picks its batch by End_time_CIP IS NULL,
-- which the step-13 group may never stamp.
--
-- KNOWN GAP: a HARD power cut writes nothing, so there is no ->0
-- edge to fire on and the outage is still invisible. This handles
-- the soft descent only (PLC survives long enough to write 0).
--
-- Run ONCE before deploying V6.1:
--   (nothing -- no new columns; reuses BigDT_Pending_Start)
-- Deploy: DROP TRIGGER TRI_UPDATE_FILLER_V6, run this script, then
-- apply the paired V_GROUP_PRODUCTION_RUN change.
--
-- WHAT CHANGED IN V6  (2026-07-13)
-- -------------------------------------------------------
-- 1) DE DOWNTIME SUBORDINATED TO THE FILLING STATE MACHINE.
--
--    V5.8 tracked DE as an independent edge stream. Two problems in
--    production: (a) the DE signal spikes 0-1-0-1 during filler stops,
--    inflating DE_Downtime_Count with junk micro-episodes; (b) DE and
--    filling downtime overlap incoherently, so tba_actual_downtime
--    (= total - DE) was not a clean attribution split.
--
--    V6 rule (stakeholder-approved): inside a filling downtime window
--    (11->8 ... ->11/7), DE stops being an event stream and becomes a
--    BLAME FLAG on the filling event:
--      * Any DE=1 seen during the window => the ENTIRE filling event
--        duration is credited to DE downtime as well. ONE episode,
--        same span as the filling event. Filling numbers UNCHANGED.
--      * All other DE edges inside the window are ignored (spikes
--        are swallowed silently -- no log rows, no counts).
--      * Filling END (10->11) settles the flag (see state table).
--      * Filling ABORT (8/9/10->7) discards the flag -- DE aborts
--        with filling, nothing counted (mirrors the filling rollback).
--    Outside a window (machine at 11, producing) the V5.8 standalone
--    edge logic is unchanged: 0->1 opens, 1->0 closes.
--
--    Handover ("unless the filling goes back to 11"): at filling END
--    the update row carries the live level in i.signal_DE_NotReady.
--    If DE is still down at that instant the episode is left/created
--    OPEN so the tail after resume keeps counting until the real
--    1->0 edge. Always exactly ONE episode per filling window.
--
--    STATE TABLE at filling END (10->11), flag set:
--      OPEN row exists (DE was down before the stop):
--        signal=0 now -> close it at window end (its 1->0 was
--                        swallowed); duration = its start -> now.
--        signal=1 now -> leave OPEN; real 1->0 closes it later.
--        (count stays 1 -- incremented at the original open)
--      No OPEN row (blip-only during the stop):
--        signal=0 now -> insert CLOSED row spanning the filling event
--                        (Start = now - full event duration); count++.
--        signal=1 now -> insert OPEN row starting at the filling event
--                        start; count++; real 1->0 closes it later.
--
--    Filling START (11->8) also reads i.signal_DE_NotReady: if DE is
--    already down when the filler stops (classic starvation sequence)
--    the flag is set immediately; an already-OPEN standalone episode
--    simply rides through the window and is settled at END (one
--    episode covering lead-in + window [+ tail]).
--
-- 2) STEP 13 CLOSES OPEN DE EPISODES (fix for the fallback over-count).
--    Any OPEN DE_Downtime_log row for a machine hitting Step 13 is
--    closed with duration truncated at [end time]; the truncated
--    duration is added to Total_DE_Downtime_Seconds and the batch's
--    Current_DE_Downtime_Start / DE_Flag_Current_Event are cleared.
--    Time after the production loop ends is no longer counted as DE
--    downtime (same philosophy as the mini-downtime ABORT). The 1->0
--    fallback close is kept as a safety net -- once Step 13 has closed
--    the row it finds nothing and is a no-op.
--
-- 3) LATENT STEP-FILTER PATCH (queued since 2026-07-03).
--    The Step-10 and Step-13 [Change paper brik] UPDATEs joined on
--    Machine only; a multi-machine PLC write containing machine X at
--    step 10/13 and machine Y at another step could stamp Y's batch.
--    Both UPDATEs now filter i.Machine_Step_No explicitly (the
--    [Change strip] UPDATEs always did).
--
-- KNOWN EDGE (accepted, edge-driven design): after an ABORT into the
-- big-downtime path (7->12), or after a Step-13 close-out, a DE line
-- that is STILL physically down is untracked until its next 0->1
-- edge. Same class of gap as the 2026-06-24 motor-start revision.
-- Big_Downtime_log is deliberately NOT DE-attributed in V6.
--
-- Run ONCE before deploying V6:
--   ALTER TABLE [Change paper brik] ADD DE_Flag_Current_Event BIT NULL;
--   ALTER TABLE [DE_Downtime_log]   ADD Source NVARCHAR(10) NULL;
--       -- 'SIGNAL'  = standalone edge episode (V5.8 style)
--       -- 'FILLING' = slaved to a filling downtime event
--
-- DEPLOY ORDER:
--   1. Run the two ALTER TABLEs above.
--   2. DROP TRIGGER [dbo].[TRI_UPDATE_FILLER_V5_8]   -- avoid double-fire
--   3. Run this script.  [historical -- this block documents the V6
--      deploy. For V6.2 see "DEPLOY ORDER (V6.2)" at the top.]
--   4. TRI_TEMP_PRODUCTION_RUN, TRI_CPB_FEED_GUARD: NO changes needed.
--      (FEED_GUARD exempts by TRIGGER_NESTLEVEL() > 1, so V6's writes
--      pass exactly as V5.8's did.)
--
-- ---- (history) -----------------------------------------
-- V5.8 : DE-line downtime tracking (signal_DE_NotReady edges),
--        tba_actual_downtime = total - de_downtime; motor-start gate
--        rev 06-24; Step-13 DE-infeed + Sampling_Waste snapshots
--        rev 06-29. DE edge semantics superseded by V6 rule above.
-- V5.7 : Reel -> pallet traceability ([Reel_Splice_log] on end-roll).
-- V5.6 : Big-downtime duration tracking ([Big_Downtime_log], A/B/D/M).
-- V5.5 : Big-downtime feed-counter segments ([Feed_Segment_log]).
-- V5.4 : Step 13 end_time re-log for A/D/M while End_time_CIP IS NULL
--        (B machines added 2026-06-11).
-- V5.3 : End_time_CIP = GETUTCDATE() (actual CIP time).
-- V5.2 : End Roll / Strip splice gated on Step 11.
-- V5.1 : Group M CIP online.
-- V5   : per-step downtime tracking (8/9/10 segments) + Down_log.
--
-- EVENTS HANDLED
-- -------------------------------------------------------
--   Step 10           -> Splicing loop started
--   Step 13           -> Splicing loop ended; counter snapshot;
--                        [V6] OPEN DE episodes closed at end time
--   Step 14 + CIP=1   -> CIP end (Machine A/B/D/M); 1-hr cooldown
--   counter -> 0      -> [V5.5] BIG DOWNTIME segment (A/B/D/M)
--   End roll 0->1     -> Paper roll splice; 30-s cooldown
--   Strip signal 0->1 -> Strip splice; 30-s cooldown
--   Step 11 -> 8      -> Downtime START; [V6] DE flag if DE already down
--   Step 8  -> 9      -> SEGMENT
--   Step 9  -> 10     -> SEGMENT
--   Step 10 -> 11     -> END; [V6] DE flag settlement
--   Step 8/9/10 -> 7  -> ABORT; [V6] DE flag discarded
--   DE 0->1           -> [V6] window active: set flag / else standalone OPEN
--   DE 1->0           -> [V6] window active: swallowed / else CLOSE
--
-- t_log event codes
-- -------------------------------------------------------
--   _BD:RESET                     [V5.5] big-downtime counter reset
--   _BDL:OPEN/VOID/CLOSE          [V5.6] big-downtime episodes
--   _DT:START/SEG/END/ABORT       minor stoppage events
--   _DE:START/END                 standalone DE episodes (V5.8 style)
--   _DE:FLAG                      [V6] DE seen down inside filling window
--   _DE:FILLCLOSE                 [V6] slaved episode closed at filling END
--   _DE:FILLOPEN                  [V6] slaved episode left/created OPEN at
--                                      filling END (DE still down)
--   _DE:S13CLOSE                  [V6] OPEN episode truncated at Step 13
--   _EndRoll / _ST                splice events
--   _S14                          CIP end event
-- ============================================================

USE [DB_BUDIBASE]
GO
CREATE OR ALTER TRIGGER [dbo].[TRI_UPDATE_FILLER_V6_4]
ON [dbo].[T_M_Filler_Process]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Machine               NVARCHAR(50)
    DECLARE @GID                   INT
    DECLARE @GID_ST                INT
    DECLARE @Splicing_Count        INT
    DECLARE @Splicing_Count_ST     INT
    DECLARE @LastSpliceTime        DATETIME
    DECLARE @LastStripTime         DATETIME
    DECLARE @ColumnName            NVARCHAR(50)
    DECLARE @SQL                   NVARCHAR(MAX)

    BEGIN TRANSACTION
    BEGIN TRY

        -- -------------------------------------------------------
        -- STEP 10 : Start Splicing Loop
        -- [V6] step-filter patch: i.Machine_Step_No = 10 now applied
        -- to the cpb UPDATE (was Machine-join only).
        -- -------------------------------------------------------
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 10)
        BEGIN
            UPDATE cpb
            SET [Splicing time 1] = GETUTCDATE()
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE i.Machine_Step_No = 10
            AND cpb.[Splicing time 1] IS NULL

            UPDATE cs
            SET [Splicing time 1] = GETUTCDATE()
            FROM [Change strip] cs
            JOIN (
                SELECT Machine, MAX(ID) MaxID FROM [Change strip] GROUP BY Machine
            ) x ON cs.Machine = x.Machine AND cs.ID = x.MaxID
            JOIN inserted i ON cs.Machine = i.Machine
            WHERE i.Machine_Step_No = 10
            AND cs.[Splicing time 1] IS NULL
        END

        -- -------------------------------------------------------
        -- STEP 13 : End Splicing Loop
        -- V5.4: A/B/D/M re-stamp end_time while End_time_CIP IS NULL.
        --        F/G/H/K unchanged — write once ([end time] IS NULL).
        -- [V6] step-filter patch: i.Machine_Step_No = 13 now applied.
        -- [V6] OPEN DE episodes for the machine are closed here,
        --      truncated at [end time] (= now).
        -- -------------------------------------------------------
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 13)
        BEGIN
            UPDATE cpb
            SET
                [end time]       = GETUTCDATE(),
                -- [V6.1] Fold the pre-reset breakdown segments in, so cpb
                -- carries the TRUE batch total and not just the final
                -- segment. Base is i.counter_* (live PLC), never
                -- cpb.In_Feed_MC, so the A/B/D/M Step-13 re-fire
                -- recomputes rather than accumulating onto itself.
                [In_Feed_MC]     = i.counter_infeed  + ISNULL(seg.in_seg,  0),
                [Out_Feed_MC]    = i.counter_outfeed + ISNULL(seg.out_seg, 0),
                [In_Feed_DE_MC]  = i.counter_infeed_DE,
                -- Raw on purpose: Feed_Segment_log has no DE column, so a
                -- folded outfeed minus a raw DE infeed would be meaningless.
                [Sampling_Waste] = i.counter_outfeed - i.counter_infeed_DE
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            OUTER APPLY (
                SELECT SUM(f.In_Feed_Seg)  AS in_seg,
                       SUM(f.Out_Feed_Seg) AS out_seg
                FROM [Feed_Segment_log] f
                WHERE f.Batch_ID = cpb.ID
            ) seg
            WHERE i.Machine_Step_No = 13
              AND cpb.[Splicing time 1] IS NOT NULL
              AND (
                    -- A/B/D/M: re-log while CIP has not fired
                    (
                        (cpb.Machine LIKE 'A%' OR cpb.Machine LIKE 'B%' OR cpb.Machine LIKE 'D%' OR cpb.Machine LIKE 'M%')
                        AND cpb.End_time_CIP IS NULL
                    )
                    OR
                    -- All others: write once only
                    (
                        cpb.Machine NOT LIKE 'A%'
                        AND cpb.Machine NOT LIKE 'B%'
                        AND cpb.Machine NOT LIKE 'D%'
                        AND cpb.Machine NOT LIKE 'M%'
                        AND cpb.[end time] IS NULL
                    )
                  )

            -- [V6] Close any OPEN DE episode for the machines ending
            -- their loop: production is over, so DE downtime stops
            -- accruing HERE. Duration truncated at [end time] (= now).
            -- Also sweeps orphaned OPEN rows from older batches of the
            -- same machine (late, but better than never-closed).
            -- Idempotent across A/B/D/M step-13 re-fires: only OPEN
            -- rows are touched.
            DECLARE @DEClose_S13 TABLE (Machine NVARCHAR(50), Batch_ID INT, Dur INT);

            UPDATE del
            SET End_Time         = GETUTCDATE(),
                Duration_Seconds = DATEDIFF(SECOND, del.Start_Time, GETUTCDATE()),
                Status           = 'CLOSED',
                Log_Time         = GETUTCDATE()
            OUTPUT inserted.Machine, inserted.Batch_ID, inserted.Duration_Seconds
            INTO @DEClose_S13 (Machine, Batch_ID, Dur)
            FROM [DE_Downtime_log] del
            WHERE del.Status = 'OPEN'
              AND del.Machine IN (SELECT Machine FROM inserted WHERE Machine_Step_No = 13)

            UPDATE cpb
            SET Total_DE_Downtime_Seconds = ISNULL(cpb.Total_DE_Downtime_Seconds, 0) + c.Dur,
                Current_DE_Downtime_Start = NULL,
                DE_Flag_Current_Event     = NULL
            FROM [Change paper brik] cpb
            JOIN @DEClose_S13 c ON cpb.ID = c.Batch_ID

            INSERT INTO t_log(txt)
            SELECT c.Machine + '_DE:S13CLOSE:ID=' + CAST(c.Batch_ID AS NVARCHAR) +
                   ':dur=' + CAST(c.Dur AS NVARCHAR) + 's'
            FROM @DEClose_S13 c

            -- Flag hygiene: a flag with no OPEN row (blip-only event that
            -- was aborted into the end sequence) is dead at step 13.
            UPDATE cpb
            SET DE_Flag_Current_Event     = NULL,
                Current_DE_Downtime_Start = NULL
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE i.Machine_Step_No = 13
              AND (cpb.DE_Flag_Current_Event = 1 OR cpb.Current_DE_Downtime_Start IS NOT NULL)

            UPDATE cs
            SET [end time] = GETUTCDATE()
            FROM [Change strip] cs
            JOIN (
                SELECT Machine, MAX(ID) MaxID FROM [Change strip] GROUP BY Machine
            ) x ON cs.Machine = x.Machine AND cs.ID = x.MaxID
            JOIN inserted i ON cs.Machine = i.Machine
            WHERE i.Machine_Step_No = 13
            AND cs.[end time] IS NULL
            AND cs.[Splicing time 1] IS NOT NULL
        END

        -- -------------------------------------------------------
        -- STEP 14 : CIP End (Machine A, B, D, M)
        -- V5.3 fix: End_time_CIP = GETUTCDATE() (actual CIP time).
        -- @EndTime_S14 ([end time]) retained for logging only.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted
            WHERE Machine_Step_No = 14
            AND Signal_Final_CIP = 1
            AND (Machine LIKE 'A%' OR Machine LIKE 'B%' OR Machine LIKE 'D%' OR Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_S14   NVARCHAR(50)
            DECLARE @GID_S14           INT
            DECLARE @LastLogTime_S14   DATETIME
            DECLARE @Outfeed_S14       NVARCHAR(50)
            DECLARE @EndTime_S14       DATETIME

            DECLARE step14_cursor CURSOR FOR
                SELECT DISTINCT Machine
                FROM inserted
                WHERE Machine_Step_No = 14
                AND Signal_Final_CIP = 1
                AND (Machine LIKE 'A%' OR Machine LIKE 'B%' OR Machine LIKE 'D%' OR Machine LIKE 'M%')

            OPEN step14_cursor
            FETCH NEXT FROM step14_cursor INTO @cur_Machine_S14

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_S14 = MAX(ID)
                FROM [Change paper brik]
                WHERE Machine = @cur_Machine_S14
                AND [end time] IS NOT NULL
                AND End_time_CIP IS NULL

                IF @GID_S14 IS NOT NULL
                BEGIN
                    -- [V5.6] FCIP fired -> this batch ended on purpose, not a
                    -- breakdown. Void any OPEN big-downtime row so it is NOT
                    -- counted as a loss when step 11 later resumes.
                    UPDATE [Big_Downtime_log]
                    SET Status = 'VOID', Log_Time = GETUTCDATE()
                    WHERE Batch_ID = @GID_S14 AND Status = 'OPEN'

                    IF @@ROWCOUNT > 0
                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_S14 + '_BDL:VOID:ID=' + CAST(@GID_S14 AS NVARCHAR) + ':FCIP')

                    SELECT
                        @EndTime_S14 = [end time],
                        @Outfeed_S14 = CAST([Out_Feed_MC] AS NVARCHAR(50))
                    FROM [Change paper brik]
                    WHERE ID = @GID_S14

                    SELECT @LastLogTime_S14 = MAX(Log_Time)
                    FROM [endtime_log_test]
                    WHERE Machine = @cur_Machine_S14

                    IF @LastLogTime_S14 IS NULL
                    OR DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) >= 3600
                    OR DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) < 0
                    BEGIN
                        UPDATE [Change paper brik]
                        SET End_time_CIP = GETUTCDATE()
                        WHERE ID = @GID_S14

                        INSERT INTO [endtime_log_test] (Machine, Step, Signal_CIP, Outfeed, End_Time, Log_Time)
                        VALUES (
                            @cur_Machine_S14, 14, 1,
                            @Outfeed_S14, @EndTime_S14, GETUTCDATE()
                        )

                        INSERT INTO t_log(txt)
                        VALUES (
                            @cur_Machine_S14 + '_S14:CIP=1:ID=' + CAST(@GID_S14 AS NVARCHAR) +
                            ':Outfeed=' + ISNULL(@Outfeed_S14, 'NULL') +
                            ':BatchEndTime=' + CONVERT(NVARCHAR, @EndTime_S14, 121) +
                            ':CIPTime=' + CONVERT(NVARCHAR, GETUTCDATE(), 121) + '-LOGGED'
                        )
                    END
                    ELSE
                    BEGIN
                        INSERT INTO t_log(txt)
                        VALUES (
                            @cur_Machine_S14 + '_S14:CIP=1:COOLDOWN' +
                            ':diff=' + CAST(DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) AS NVARCHAR) + 's' +
                            ':remaining=' + CAST(3600 - DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) AS NVARCHAR) + 's'
                        )
                    END
                END

                FETCH NEXT FROM step14_cursor INTO @cur_Machine_S14
            END

            CLOSE step14_cursor
            DEALLOCATE step14_cursor
        END

        -- -------------------------------------------------------
        -- [V5.5] BIG DOWNTIME : feed counter reset (A/B/D/M)
        -- Real restart = counter_infeed drops to 0 while the batch is
        -- still open (End_time_CIP IS NULL -> no FCIP yet ->
        -- breakdown / ICIP). deleted.counter_infeed holds the
        -- pre-reset value; log it as a segment so the true batch
        -- total = SUM(segments) + final counter (done in the view).
        -- Mini breakdowns (11->8->9->10) never zero the counter, so
        -- they never reach here. Clean finishes stamp End_time_CIP
        -- hours before the counter zeros, so they are excluded.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.counter_infeed > 0
            AND i.counter_infeed = 0
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_BD   NVARCHAR(50)
            DECLARE @GID_BD           INT
            DECLARE @PreInfeed_BD     BIGINT
            DECLARE @PreOutfeed_BD    BIGINT
            DECLARE @Seg_No_BD        INT

            DECLARE bd_cursor CURSOR FOR
                SELECT i.Machine, d.counter_infeed, d.counter_outfeed
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.counter_infeed > 0
                AND i.counter_infeed = 0
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN bd_cursor
            FETCH NEXT FROM bd_cursor INTO @cur_Machine_BD, @PreInfeed_BD, @PreOutfeed_BD

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- [V6.4] The batch that OWNS this counter must be RUNNING:
                -- started and not yet ended. "End_time_CIP IS NULL" is not a
                -- current-batch test -- the next loop's row can already exist
                -- while this loop's CIP is still pending, so MAX(ID) returns
                -- the WRONG (future) batch. Observed on M1 2026-08-26: counter
                -- reset 22:48 -> logged onto batch 6539 (27 Aug), while batch
                -- 6526 (26 Aug) did not get End_time_CIP until 23:07.
                -- If no batch is running this is a loop-boundary reset, not a
                -- breakdown -- @GID_BD stays NULL and nothing is logged.
                SELECT @GID_BD = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_BD
                AND [Splicing time 1] IS NOT NULL
                AND [end time] IS NULL

                IF @GID_BD IS NOT NULL
                BEGIN
                    -- [V6.2] Skip if the ->0 branch already committed this
                    -- exact counter from the stash. Both paths capture the
                    -- same pre-reset value, so equality is a safe dedupe
                    -- key -- without this, an outage that BOTH hits step 0
                    -- AND zeroes the counter logs two segments and Step 13
                    -- folds both.
                    IF NOT EXISTS (
                        SELECT 1 FROM [Feed_Segment_log]
                        WHERE Batch_ID = @GID_BD
                        AND In_Feed_Seg = @PreInfeed_BD
                    )
                    BEGIN
                        SELECT @Seg_No_BD = ISNULL(MAX(Segment_No), 0) + 1
                        FROM [Feed_Segment_log]
                        WHERE Batch_ID = @GID_BD

                        INSERT INTO [Feed_Segment_log]
                            (Machine, Batch_ID, Segment_No, In_Feed_Seg, Out_Feed_Seg, Reset_Time, Ended_By, Log_Time)
                        VALUES
                            (@cur_Machine_BD, @GID_BD, @Seg_No_BD, @PreInfeed_BD, @PreOutfeed_BD,
                             GETUTCDATE(), 'BREAKDOWN', GETUTCDATE())

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_BD + '_BD:RESET:ID=' + CAST(@GID_BD AS NVARCHAR) +
                                ':seg=' + CAST(@Seg_No_BD AS NVARCHAR) +
                                ':infeed=' + CAST(@PreInfeed_BD AS NVARCHAR) +
                                ':outfeed=' + CAST(@PreOutfeed_BD AS NVARCHAR) + '-LOGGED')
                    END
                    ELSE
                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_BD + '_BD:RESET:ID=' + CAST(@GID_BD AS NVARCHAR) +
                                ':infeed=' + CAST(@PreInfeed_BD AS NVARCHAR) + '-DUPSKIPPED')

                    -- [V6.2] This counter is now accounted for by one path
                    -- or the other. Drop the stash so it cannot be
                    -- committed again against a later outage.
                    UPDATE [Change paper brik]
                    SET BigDT_Pending_Infeed  = NULL,
                        BigDT_Pending_Outfeed = NULL
                    WHERE ID = @GID_BD
                END

                FETCH NEXT FROM bd_cursor INTO @cur_Machine_BD, @PreInfeed_BD, @PreOutfeed_BD
            END

            CLOSE bd_cursor
            DEALLOCATE bd_cursor
        END

        -- -------------------------------------------------------
        -- End Roll Signal (0 -> 1)
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Paper_Splicing_End_roll_Signal_Brik = 1
            AND d.Paper_Splicing_End_roll_Signal_Brik = 0
        )
        BEGIN
            DECLARE @cur_Machine_ER NVARCHAR(50)
            DECLARE @Outfeed_ER     BIGINT          -- [V5.7] outfeed counter at splice instant

            DECLARE endroll_cursor CURSOR FOR
                SELECT i.Machine, i.counter_outfeed
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Paper_Splicing_End_roll_Signal_Brik = 1
                AND d.Paper_Splicing_End_roll_Signal_Brik = 0
                AND i.Machine_Step_No = 11

            OPEN endroll_cursor
            FETCH NEXT FROM endroll_cursor INTO @cur_Machine_ER, @Outfeed_ER

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @cur_Machine_ER LIKE 'A%' OR @cur_Machine_ER LIKE 'B%' OR @cur_Machine_ER LIKE 'D%' OR @cur_Machine_ER LIKE 'M%'
                BEGIN
                    SELECT @GID = MAX(ID)
                    FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                    WHERE Machine = @cur_Machine_ER
                    AND End_time_CIP IS NULL
                END
                ELSE
                BEGIN
                    SELECT @GID = MAX(ID)
                    FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                    WHERE Machine = @cur_Machine_ER
                    AND [end time] IS NULL
                END

                SELECT
                    @Splicing_Count = ISNULL(Splicing_Count, 0) + 1,
                    @LastSpliceTime = Last_Splice_Time
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE ID = @GID

                IF @LastSpliceTime IS NULL
                OR DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) >= 30000
                OR DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) < -500
                BEGIN
                    UPDATE [Change paper brik]
                    SET Splicing_Count   = @Splicing_Count,
                        Last_Splice_Time = SYSDATETIME()
                    WHERE ID = @GID

                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count + 1 AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change paper brik] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID'
                    EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ER + '_EndRoll:' + CAST(@GID AS NVARCHAR) + ':' + CAST(@Splicing_Count AS NVARCHAR) + '-UPD')

                    -- [V5.7] reel boundary capture for pallet traceability.
                    -- @Splicing_Count = kth end-roll = boundary that ends reel k
                    -- and starts reel k+1. Counter only; barcode joined back in
                    -- the views (Order/Reel scanned separately by operator).
                    INSERT INTO [dbo].[Reel_Splice_log]
                        (Machine, Batch_ID, Splice_No, Counter_Outfeed, Splice_Time, Log_Time)
                    VALUES
                        (@cur_Machine_ER, @GID, @Splicing_Count, @Outfeed_ER, SYSDATETIME(), GETUTCDATE())
                END
                ELSE
                BEGIN
                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change paper brik] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID'
                    EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ER + '_EndRoll:COOLDOWN:count=' + CAST(@Splicing_Count - 1 AS NVARCHAR) +
                            ':diff=' + CAST(DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) AS NVARCHAR) + 'ms')
                END

                FETCH NEXT FROM endroll_cursor INTO @cur_Machine_ER, @Outfeed_ER
            END

            CLOSE endroll_cursor
            DEALLOCATE endroll_cursor
        END

        -- -------------------------------------------------------
        -- Strip Signal (0 -> 1)
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Strip_Splicing_Signal_Strip = 1
            AND d.Strip_Splicing_Signal_Strip = 0
        )
        BEGIN
            DECLARE @cur_Machine_ST NVARCHAR(50)

            DECLARE strip_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Strip_Splicing_Signal_Strip = 1
                AND d.Strip_Splicing_Signal_Strip = 0
                AND i.Machine_Step_No = 11

            OPEN strip_cursor
            FETCH NEXT FROM strip_cursor INTO @cur_Machine_ST

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_ST = MAX(ID)
                FROM [Change Strip] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_ST

                SELECT
                    @Splicing_Count_ST = ISNULL(Splicing_Count, 0) + 1,
                    @LastStripTime     = Last_Splice_Time
                FROM [Change Strip] WITH (UPDLOCK, HOLDLOCK)
                WHERE ID = @GID_ST

                IF @LastStripTime IS NULL
                OR DATEDIFF(MILLISECOND, @LastStripTime, SYSDATETIME()) >= 30000
                OR DATEDIFF(MILLISECOND, @LastStripTime, SYSDATETIME()) < -500
                BEGIN
                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count_ST + 1 AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change Strip] SET [' + @ColumnName + '] = GETUTCDATE(), Splicing_Count = @CNT, Last_Splice_Time = SYSDATETIME() WHERE ID = @ID AND [end time] IS NULL'
                    IF @Splicing_Count_ST = 1
                        SET @SQL = 'UPDATE [Change Strip] SET [' + @ColumnName + '] = GETUTCDATE(), Splicing_Count = @CNT, Last_Splice_Time = SYSDATETIME() WHERE ID = @ID AND [end time] IS NULL AND [Splicing time 1] IS NOT NULL'
                    EXEC sp_executesql @SQL, N'@ID INT, @CNT INT', @ID = @GID_ST, @CNT = @Splicing_Count_ST

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ST + '_ST:' + CAST(@GID_ST AS NVARCHAR) + ':' + CAST(@Splicing_Count_ST AS NVARCHAR) + '-UPD')
                END
                ELSE
                BEGIN
                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count_ST AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change Strip] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID AND [end time] IS NULL'
                    EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID_ST
                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ST + '_ST:COOLDOWN:count=' + CAST(@Splicing_Count_ST - 1 AS NVARCHAR) +
                            ':diff=' + CAST(DATEDIFF(MILLISECOND, @LastStripTime, SYSDATETIME()) AS NVARCHAR) + 'ms')
                END

                FETCH NEXT FROM strip_cursor INTO @cur_Machine_ST
            END

            CLOSE strip_cursor
            DEALLOCATE strip_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 11 -> 8 : Downtime Start
        -- [V6] also reads the live DE level: if DE is already down
        -- when the filler stops (starvation sequence), set the blame
        -- flag now. An already-OPEN standalone DE episode is NOT
        -- closed — it rides through the window and is settled at the
        -- filling END (one episode: lead-in + window [+ tail]).
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 8
            AND d.Machine_Step_No = 11
        )
        BEGIN
            DECLARE @cur_Machine_DT   NVARCHAR(50)
            DECLARE @GID_DT           INT
            DECLARE @DT_Count         INT
            DECLARE @DE_Sig_DT        INT             -- [V6] live DE level at stop

            DECLARE dt_start_cursor CURSOR FOR
                SELECT i.Machine, ISNULL(i.signal_DE_NotReady, 0)
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 8
                AND d.Machine_Step_No = 11

            OPEN dt_start_cursor
            FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT, @DE_Sig_DT

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_DT = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DT
                AND [end time] IS NULL

                IF @GID_DT IS NOT NULL
                BEGIN
                    SELECT @DT_Count = ISNULL(Downtime_Count, 0) + 1
                    FROM [Change paper brik]
                    WHERE ID = @GID_DT

                    UPDATE [Change paper brik]
                    SET Downtime_Count         = @DT_Count,
                        Current_Downtime_Start = GETUTCDATE(),
                        Current_Event_Seconds  = 0,
                        -- [V6] DE already down at the stop -> flag the event
                        DE_Flag_Current_Event  = CASE WHEN @DE_Sig_DT = 1 THEN 1
                                                      ELSE DE_Flag_Current_Event END
                    WHERE ID = @GID_DT

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_DT + '_DT:START:step=11->8:ID=' + CAST(@GID_DT AS NVARCHAR) + ':count=' + CAST(@DT_Count AS NVARCHAR))

                    IF @DE_Sig_DT = 1
                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_DT + '_DE:FLAG:atstart:ID=' + CAST(@GID_DT AS NVARCHAR))

                    INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                    VALUES (@cur_Machine_DT, 'START', 11, 8, @GID_DT, @DT_Count, NULL, NULL, GETUTCDATE())
                END

                FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT, @DE_Sig_DT
            END

            CLOSE dt_start_cursor
            DEALLOCATE dt_start_cursor
        END

        -- -------------------------------------------------------
        -- [V6.1] STEP 11 -> 7 : big-downtime stash (hardware fault)
        -- Old machines drop straight 11->7 instead of 11->8. No mini
        -- event is opened: this path needs the full restart ramp, so
        -- it is a BREAKDOWN. Just stash the stop time -- the ->0
        -- branch below opens the row. Mirrors the stash that the
        -- 8/9/10->7 ABORT performs.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 7
            AND d.Machine_Step_No = 11
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_S7 NVARCHAR(50)
            DECLARE @GID_S7         INT

            DECLARE s7_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 7
                AND d.Machine_Step_No = 11
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN s7_cursor
            FETCH NEXT FROM s7_cursor INTO @cur_Machine_S7

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_S7 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_S7
                AND End_time_CIP IS NULL

                IF @GID_S7 IS NOT NULL
                BEGIN
                    UPDATE [Change paper brik]
                    SET BigDT_Pending_Start = GETUTCDATE()
                    WHERE ID = @GID_S7
                    AND BigDT_Pending_Start IS NULL

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_S7 + '_BDL:STASH:step=11->7:ID=' + CAST(@GID_S7 AS NVARCHAR))
                END

                FETCH NEXT FROM s7_cursor INTO @cur_Machine_S7
            END

            CLOSE s7_cursor
            DEALLOCATE s7_cursor
        END

        -- -------------------------------------------------------
        -- [V6.3] STOP FROM STEP 11 : stash the feed counters (A/B/D/M)
        -- The counter is still at its full pre-stop value here. Keep
        -- it so the ->0 branch can log it as a segment even when the
        -- PLC dies and the counter-zero edge that _BD:RESET watches
        -- for never happens.
        --
        -- [V6.3] NARROWED to 11->8 and 11->7 ONLY (V6.2 stashed on any
        -- exit from 11). Together with the CLEAR block below this makes
        -- the segment conditional on the real breakdown path:
        --      11->8->0   or   11->7->0   =>  segment
        --      11->8->9->...              =>  no segment (recovery)
        --      anything ->0 with no stop  =>  no segment (planned rest)
        -- V6.2 committed on ANY arrival at step 0, so a machine parked
        -- at rest for a few hours produced a bogus _BD:SEG0 from a stale
        -- stash taken hours earlier. That is the bug this fixes.
        --
        -- OVERWRITES every time -- deliberately NOT guarded by
        -- "IS NULL" the way BigDT_Pending_Start is, so the stash always
        -- holds the counter from the MOST RECENT stop.
        --
        -- Opens no event, touches no downtime state.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 11
            AND i.Machine_Step_No IN (7, 8)
            AND d.counter_infeed > 0
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_CS NVARCHAR(50)
            DECLARE @GID_CS         INT
            DECLARE @PreIn_CS       BIGINT
            DECLARE @PreOut_CS      BIGINT
            DECLARE @StepTo_CS      INT

            DECLARE cs_cursor CURSOR FOR
                SELECT i.Machine, d.counter_infeed, d.counter_outfeed, i.Machine_Step_No
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 11
                AND i.Machine_Step_No IN (7, 8)
                AND d.counter_infeed > 0
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN cs_cursor
            FETCH NEXT FROM cs_cursor INTO @cur_Machine_CS, @PreIn_CS, @PreOut_CS, @StepTo_CS

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Same batch selection as the ->0 commit below, so the
                -- stash and the commit can never land on different rows.
                -- [V6.4] Running batch only -- see the note on @GID_BD.
                SELECT @GID_CS = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_CS
                AND [Splicing time 1] IS NOT NULL
                AND [end time] IS NULL

                IF @GID_CS IS NOT NULL
                BEGIN
                    UPDATE [Change paper brik]
                    SET BigDT_Pending_Infeed  = @PreIn_CS,
                        BigDT_Pending_Outfeed = @PreOut_CS
                    WHERE ID = @GID_CS

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_CS + '_BD:STASHCNT:step=11->' + CAST(@StepTo_CS AS NVARCHAR) +
                            ':ID=' + CAST(@GID_CS AS NVARCHAR) +
                            ':infeed=' + CAST(@PreIn_CS AS NVARCHAR) +
                            ':outfeed=' + CAST(@PreOut_CS AS NVARCHAR) + '-STASHED')
                END

                FETCH NEXT FROM cs_cursor INTO @cur_Machine_CS, @PreIn_CS, @PreOut_CS, @StepTo_CS
            END

            CLOSE cs_cursor
            DEALLOCATE cs_cursor
        END

        -- -------------------------------------------------------
        -- [V6.1] EDGE OBSERVABILITY -- no state change, ALL machines.
        -- Reveals which machines bypass step 8 on a stop. Only
        -- A/B/D/M get a Big_Downtime_log row from the branches here,
        -- so this is how F/G/H/K/E1/J1 surface if they do it too.
        -- -------------------------------------------------------
        INSERT INTO t_log(txt)
        SELECT i.Machine + '_DT:EDGE:step=11->' + CAST(i.Machine_Step_No AS NVARCHAR) + '-OBSERVED'
        FROM inserted i
        JOIN deleted d ON i.Machine = d.Machine
        WHERE d.Machine_Step_No = 11
        AND i.Machine_Step_No NOT IN (8, 11)

        -- -------------------------------------------------------
        -- [V6.3] STASH CLEAR : the machine recovered, so no segment
        -- The stash is only valid while the machine is sitting in a
        -- stopped state (7 or 8) on its way to a possible power-down.
        -- The moment it moves anywhere that is not 0/7/8 it is either
        -- recovering (8->9->10->11) or was never really down, so the
        -- stashed counter must be discarded.
        --
        -- Without this the stash is long-lived: V6.2 could take one at
        -- 09:00 during a mini stop and still commit it at 18:00 when the
        -- machine was parked for a rest, inventing a segment from a
        -- counter value hours out of date.
        --
        -- Net effect, with the narrowed stash above:
        --      11->8->0 / 11->7->0  -> segment written at ->0
        --      11->8->9->10->11     -> cleared here, no segment
        --      idle/rest ->0        -> no stash exists, no segment
        -- A/B/D/M only.
        -- -------------------------------------------------------
        DECLARE @Cleared_SC TABLE (Machine NVARCHAR(50), Batch_ID INT, Infeed BIGINT);

        ;WITH recov AS (
            SELECT DISTINCT i.Machine
            FROM   inserted i
            JOIN   deleted  d ON i.Machine = d.Machine
            WHERE  i.Machine_Step_No <> d.Machine_Step_No
            AND    i.Machine_Step_No NOT IN (0, 7, 8)
            AND    (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        ),
        tgt AS (
            SELECT cpb.ID, cpb.Machine, cpb.BigDT_Pending_Infeed,
                   rn = ROW_NUMBER() OVER (PARTITION BY cpb.Machine ORDER BY cpb.ID DESC)
            FROM   [Change paper brik] cpb
            JOIN   recov r ON r.Machine = cpb.Machine
            WHERE  cpb.End_time_CIP IS NULL
        )
        UPDATE c
        SET    c.BigDT_Pending_Infeed  = NULL,
               c.BigDT_Pending_Outfeed = NULL
        OUTPUT deleted.Machine, deleted.ID, deleted.BigDT_Pending_Infeed INTO @Cleared_SC
        FROM   [Change paper brik] c
        JOIN   tgt ON tgt.ID = c.ID AND tgt.rn = 1
        WHERE  c.BigDT_Pending_Infeed IS NOT NULL;

        IF EXISTS (SELECT 1 FROM @Cleared_SC)
            INSERT INTO t_log(txt)
            SELECT Machine + '_BD:STASHCLR:ID=' + CAST(Batch_ID AS NVARCHAR) +
                   ':infeed=' + ISNULL(CAST(Infeed AS NVARCHAR), 'NULL') + '-RECOVERED'
            FROM @Cleared_SC;

        -- -------------------------------------------------------
        -- [V5] STEP 8 -> 9 : Segment
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 8
            AND i.Machine_Step_No = 9
        )
        BEGIN
            DECLARE @cur_Machine_89   NVARCHAR(50)
            DECLARE @GID_89           INT
            DECLARE @DT_Start_89      DATETIME
            DECLARE @DT_Dur_89        INT
            DECLARE @DT_Count_89      INT
            DECLARE @DT_NewTotal_89   INT

            DECLARE dt_seg89_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 8
                AND i.Machine_Step_No = 9

            OPEN dt_seg89_cursor
            FETCH NEXT FROM dt_seg89_cursor INTO @cur_Machine_89

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_89 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_89
                AND [end time] IS NULL

                IF @GID_89 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_89 = Current_Downtime_Start,
                           @DT_Count_89 = Downtime_Count
                    FROM [Change paper brik]
                    WHERE ID = @GID_89

                    IF @DT_Start_89 IS NOT NULL
                    BEGIN
                        SET @DT_Dur_89      = DATEDIFF(SECOND, @DT_Start_89, GETUTCDATE())
                        SET @DT_NewTotal_89 = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_89), 0) + @DT_Dur_89

                        UPDATE [Change paper brik]
                        SET Total_Downtime_Seconds = @DT_NewTotal_89,
                            Current_Event_Seconds  = ISNULL(Current_Event_Seconds, 0) + @DT_Dur_89,
                            Current_Downtime_Start = GETUTCDATE()
                        WHERE ID = @GID_89

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_89 + '_DT:SEG:step=8->9:dur=' + CAST(@DT_Dur_89 AS NVARCHAR) + 's:total=' + CAST(@DT_NewTotal_89 AS NVARCHAR) + 's')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_89, 'SEGMENT', 8, 9, @GID_89, @DT_Count_89, @DT_Dur_89, @DT_NewTotal_89, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_seg89_cursor INTO @cur_Machine_89
            END

            CLOSE dt_seg89_cursor
            DEALLOCATE dt_seg89_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 9 -> 10 : Segment
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 9
            AND i.Machine_Step_No = 10
        )
        BEGIN
            DECLARE @cur_Machine_910   NVARCHAR(50)
            DECLARE @GID_910           INT
            DECLARE @DT_Start_910      DATETIME
            DECLARE @DT_Dur_910        INT
            DECLARE @DT_Count_910      INT
            DECLARE @DT_NewTotal_910   INT

            DECLARE dt_seg910_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 9
                AND i.Machine_Step_No = 10

            OPEN dt_seg910_cursor
            FETCH NEXT FROM dt_seg910_cursor INTO @cur_Machine_910

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_910 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_910
                AND [end time] IS NULL

                IF @GID_910 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_910 = Current_Downtime_Start,
                           @DT_Count_910 = Downtime_Count
                    FROM [Change paper brik]
                    WHERE ID = @GID_910

                    IF @DT_Start_910 IS NOT NULL
                    BEGIN
                        SET @DT_Dur_910      = DATEDIFF(SECOND, @DT_Start_910, GETUTCDATE())
                        SET @DT_NewTotal_910 = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_910), 0) + @DT_Dur_910

                        UPDATE [Change paper brik]
                        SET Total_Downtime_Seconds = @DT_NewTotal_910,
                            Current_Event_Seconds  = ISNULL(Current_Event_Seconds, 0) + @DT_Dur_910,
                            Current_Downtime_Start = GETUTCDATE()
                        WHERE ID = @GID_910

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_910 + '_DT:SEG:step=9->10:dur=' + CAST(@DT_Dur_910 AS NVARCHAR) + 's:total=' + CAST(@DT_NewTotal_910 AS NVARCHAR) + 's')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_910, 'SEGMENT', 9, 10, @GID_910, @DT_Count_910, @DT_Dur_910, @DT_NewTotal_910, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_seg910_cursor INTO @cur_Machine_910
            END

            CLOSE dt_seg910_cursor
            DEALLOCATE dt_seg910_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 10 -> 11 : Downtime End
        -- [V6] DE flag settlement (see state table in header):
        --   flag set + OPEN DE row  + DE=0 now -> close row at window
        --                                          end (edge was swallowed)
        --   flag set + OPEN DE row  + DE=1 now -> leave OPEN (tail counts)
        --   flag set + no OPEN row  + DE=0 now -> insert CLOSED row
        --                                          spanning the filling event
        --   flag set + no OPEN row  + DE=1 now -> insert OPEN row starting
        --                                          at the filling event start
        -- Filling numbers are NOT touched by any of this.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 10
            AND i.Machine_Step_No = 11
        )
        BEGIN
            DECLARE @cur_Machine_1011   NVARCHAR(50)
            DECLARE @GID_1011           INT
            DECLARE @DT_Start_1011      DATETIME
            DECLARE @DT_Dur_1011        INT
            DECLARE @DT_Count_1011      INT
            DECLARE @DT_NewTotal_1011   INT
            DECLARE @DE_Sig_1011        INT             -- [V6] live DE level at resume
            DECLARE @DT_EventSecs_1011  INT             -- [V6] prior segment legs
            DECLARE @DE_Flag_1011       BIT             -- [V6] blame flag
            DECLARE @FullDur_1011       INT             -- [V6] full filling event duration
            DECLARE @DE_OpenID_1011     INT
            DECLARE @DE_OpenStart_1011  DATETIME
            DECLARE @DE_CloseDur_1011   INT
            DECLARE @DE_EvStart_1011    DATETIME
            DECLARE @DE_Count_1011      INT

            DECLARE dt_end1011_cursor CURSOR FOR
                SELECT i.Machine, ISNULL(i.signal_DE_NotReady, 0)
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 10
                AND i.Machine_Step_No = 11

            OPEN dt_end1011_cursor
            FETCH NEXT FROM dt_end1011_cursor INTO @cur_Machine_1011, @DE_Sig_1011

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_1011 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_1011
                AND [end time] IS NULL

                IF @GID_1011 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_1011     = Current_Downtime_Start,
                           @DT_Count_1011     = Downtime_Count,
                           @DT_EventSecs_1011 = ISNULL(Current_Event_Seconds, 0),
                           @DE_Flag_1011      = ISNULL(DE_Flag_Current_Event, 0)
                    FROM [Change paper brik]
                    WHERE ID = @GID_1011

                    IF @DT_Start_1011 IS NOT NULL
                    BEGIN
                        SET @DT_Dur_1011      = DATEDIFF(SECOND, @DT_Start_1011, GETUTCDATE())
                        SET @DT_NewTotal_1011 = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_1011), 0) + @DT_Dur_1011

                        UPDATE [Change paper brik]
                        SET Total_Downtime_Seconds = @DT_NewTotal_1011,
                            Current_Downtime_Start = NULL,
                            Current_Event_Seconds  = NULL
                        WHERE ID = @GID_1011

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_1011 + '_DT:END:step=10->11:dur=' + CAST(@DT_Dur_1011 AS NVARCHAR) + 's:total=' + CAST(@DT_NewTotal_1011 AS NVARCHAR) + 's')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_1011, 'END', 10, 11, @GID_1011, @DT_Count_1011, @DT_Dur_1011, @DT_NewTotal_1011, GETUTCDATE())

                        -- ------------------------------------------------
                        -- [V6] DE flag settlement for this filling event.
                        -- Full event duration = prior segment legs + last leg
                        -- (Total_Downtime_Seconds got exactly this amount).
                        -- ------------------------------------------------
                        IF @DE_Flag_1011 = 1
                        BEGIN
                            SET @FullDur_1011 = @DT_EventSecs_1011 + @DT_Dur_1011

                            SELECT @DE_OpenID_1011 = MAX(ID)
                            FROM [DE_Downtime_log]
                            WHERE Batch_ID = @GID_1011 AND Status = 'OPEN'

                            IF @DE_OpenID_1011 IS NOT NULL
                            BEGIN
                                -- Episode began BEFORE the stop (starvation lead-in).
                                IF @DE_Sig_1011 = 0
                                BEGIN
                                    -- Its 1->0 edge was swallowed inside the window:
                                    -- close at window end, per "take the filling downtime".
                                    SELECT @DE_OpenStart_1011 = Start_Time
                                    FROM [DE_Downtime_log]
                                    WHERE ID = @DE_OpenID_1011

                                    SET @DE_CloseDur_1011 = DATEDIFF(SECOND, @DE_OpenStart_1011, GETUTCDATE())

                                    UPDATE [DE_Downtime_log]
                                    SET End_Time         = GETUTCDATE(),
                                        Duration_Seconds = @DE_CloseDur_1011,
                                        Status           = 'CLOSED',
                                        Log_Time         = GETUTCDATE()
                                    WHERE ID = @DE_OpenID_1011

                                    UPDATE [Change paper brik]
                                    SET Total_DE_Downtime_Seconds = ISNULL(Total_DE_Downtime_Seconds, 0) + @DE_CloseDur_1011,
                                        Current_DE_Downtime_Start = NULL
                                    WHERE ID = @GID_1011

                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLCLOSE:ID=' + CAST(@GID_1011 AS NVARCHAR) +
                                            ':dur=' + CAST(@DE_CloseDur_1011 AS NVARCHAR) + 's:absorbed')
                                END
                                ELSE
                                BEGIN
                                    -- DE still down at resume: leave OPEN, the real
                                    -- 1->0 closes it (tail after resume keeps counting).
                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLOPEN:ID=' + CAST(@GID_1011 AS NVARCHAR) + ':carried')
                                END
                            END
                            ELSE
                            BEGIN
                                -- Blip-only inside the window: ONE episode spanning
                                -- the whole filling event (stakeholder rule: any DE
                                -- blip during a filler stop blames the full stop).
                                SELECT @DE_Count_1011 = ISNULL(DE_Downtime_Count, 0) + 1
                                FROM [Change paper brik]
                                WHERE ID = @GID_1011

                                SET @DE_EvStart_1011 = DATEADD(SECOND, -@FullDur_1011, GETUTCDATE())

                                IF @DE_Sig_1011 = 0
                                BEGIN
                                    INSERT INTO [DE_Downtime_log]
                                        (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Source, Log_Time)
                                    VALUES
                                        (@cur_Machine_1011, @GID_1011, @DE_EvStart_1011, GETUTCDATE(),
                                         @FullDur_1011, 'CLOSED', 'FILLING', GETUTCDATE())

                                    UPDATE [Change paper brik]
                                    SET DE_Downtime_Count         = @DE_Count_1011,
                                        Total_DE_Downtime_Seconds = ISNULL(Total_DE_Downtime_Seconds, 0) + @FullDur_1011
                                    WHERE ID = @GID_1011

                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLCLOSE:ID=' + CAST(@GID_1011 AS NVARCHAR) +
                                            ':dur=' + CAST(@FullDur_1011 AS NVARCHAR) + 's:count=' + CAST(@DE_Count_1011 AS NVARCHAR))
                                END
                                ELSE
                                BEGIN
                                    -- DE still down at resume: open from the filling
                                    -- event start so window + tail land in ONE episode.
                                    INSERT INTO [DE_Downtime_log]
                                        (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Source, Log_Time)
                                    VALUES
                                        (@cur_Machine_1011, @GID_1011, @DE_EvStart_1011, NULL,
                                         NULL, 'OPEN', 'FILLING', GETUTCDATE())

                                    UPDATE [Change paper brik]
                                    SET DE_Downtime_Count         = @DE_Count_1011,
                                        Current_DE_Downtime_Start = @DE_EvStart_1011
                                    WHERE ID = @GID_1011

                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLOPEN:ID=' + CAST(@GID_1011 AS NVARCHAR) +
                                            ':count=' + CAST(@DE_Count_1011 AS NVARCHAR))
                                END
                            END

                            -- Flag consumed either way.
                            UPDATE [Change paper brik]
                            SET DE_Flag_Current_Event = NULL
                            WHERE ID = @GID_1011
                        END
                    END
                END

                FETCH NEXT FROM dt_end1011_cursor INTO @cur_Machine_1011, @DE_Sig_1011
            END

            CLOSE dt_end1011_cursor
            DEALLOCATE dt_end1011_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 8/9/10 -> 7 : Abort
        -- [V6] DE aborts with filling: the blame flag is discarded in
        -- the same rollback UPDATE — nothing counted, no DE row.
        -- (An OPEN standalone episode from BEFORE the window is left
        -- alone; the Step-13 close-out truncates it at [end time].)
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 7
            AND d.Machine_Step_No IN (8, 9, 10)
        )
        BEGIN
            DECLARE @cur_Machine_DTA   NVARCHAR(50)
            DECLARE @GID_DTA           INT
            DECLARE @DT_CountAbort     INT
            DECLARE @DT_EventSecs      INT
            DECLARE @DT_Start_A        DATETIME
            DECLARE @DT_StepFrom       INT

            DECLARE dt_abort_cursor CURSOR FOR
                SELECT i.Machine, d.Machine_Step_No
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 7
                AND d.Machine_Step_No IN (8, 9, 10)

            OPEN dt_abort_cursor
            FETCH NEXT FROM dt_abort_cursor INTO @cur_Machine_DTA, @DT_StepFrom

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_DTA = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DTA
                AND [end time] IS NULL

                IF @GID_DTA IS NOT NULL
                BEGIN
                    SELECT @DT_Start_A    = Current_Downtime_Start,
                           @DT_CountAbort = Downtime_Count,
                           @DT_EventSecs  = ISNULL(Current_Event_Seconds, 0)
                    FROM [Change paper brik]
                    WHERE ID = @GID_DTA

                    IF @DT_Start_A IS NOT NULL
                    BEGIN
                        UPDATE [Change paper brik]
                        SET Downtime_Count         = ISNULL(Downtime_Count, 1) - 1,
                            Total_Downtime_Seconds = ISNULL(Total_Downtime_Seconds, 0) - @DT_EventSecs,
                            Current_Downtime_Start = NULL,
                            Current_Event_Seconds  = NULL,
                            -- [V5.6] stash the 11->8 stop time before it is wiped,
                            -- so a following 7->12 can open a big-downtime row.
                            BigDT_Pending_Start    = @DT_Start_A,
                            -- [V6] DE aborts with filling.
                            DE_Flag_Current_Event  = NULL
                        WHERE ID = @GID_DTA

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_DTA + '_DT:ABORT:step=' + CAST(@DT_StepFrom AS NVARCHAR) +
                                '->7:rollback=' + CAST(@DT_EventSecs AS NVARCHAR) + 's:count=' + CAST(@DT_CountAbort AS NVARCHAR))

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_DTA, 'ABORT', @DT_StepFrom, 7, @GID_DTA, @DT_CountAbort, NULL, NULL, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_abort_cursor INTO @cur_Machine_DTA, @DT_StepFrom
            END

            CLOSE dt_abort_cursor
            DEALLOCATE dt_abort_cursor
        END

        -- -------------------------------------------------------
        -- [V5.6] STEP 7 -> 12 : Big downtime OPEN (A/B/D/M)
        -- The 11->8->7->12 path = a real big breakdown entering the
        -- ICIP/end sequence. Open a Big_Downtime_log row using the
        -- stop time stashed at the abort. Stays OPEN until step 11
        -- resume (CLOSE) or FCIP (VOID).
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 7
            AND i.Machine_Step_No = 12
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_BO   NVARCHAR(50)
            DECLARE @GID_BO           INT
            DECLARE @PendStart_BO     DATETIME

            DECLARE bo_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 7
                AND i.Machine_Step_No = 12
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN bo_cursor
            FETCH NEXT FROM bo_cursor INTO @cur_Machine_BO

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_BO = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_BO
                AND End_time_CIP IS NULL

                IF @GID_BO IS NOT NULL
                BEGIN
                    SELECT @PendStart_BO = BigDT_Pending_Start
                    FROM [Change paper brik]
                    WHERE ID = @GID_BO

                    IF @PendStart_BO IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM [Big_Downtime_log] WHERE Batch_ID = @GID_BO AND Status = 'OPEN')
                    BEGIN
                        INSERT INTO [Big_Downtime_log]
                            (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Log_Time)
                        VALUES
                            (@cur_Machine_BO, @GID_BO, @PendStart_BO, NULL, NULL, 'OPEN', GETUTCDATE())

                        UPDATE [Change paper brik]
                        SET BigDT_Pending_Start = NULL
                        WHERE ID = @GID_BO

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_BO + '_BDL:OPEN:ID=' + CAST(@GID_BO AS NVARCHAR) +
                                ':start=' + CONVERT(NVARCHAR, @PendStart_BO, 121))
                    END
                END

                FETCH NEXT FROM bo_cursor INTO @cur_Machine_BO
            END

            CLOSE bo_cursor
            DEALLOCATE bo_cursor
        END

        -- -------------------------------------------------------
        -- [V6.1] -> STEP 0 : Big downtime OPEN (power off / hard stop)
        -- Step 0 = powered down; recovery always needs the full
        -- 0->14->1->3->4->5->6->7->8->9->10->11 ramp, so this is a
        -- breakdown whether the machine dropped through 7 or 8.
        -- The 7->12 OPEN above cannot fire on a power cut: there is
        -- no step 12 in the restart ramp.
        -- Start time, in priority order:
        --   1. an OPEN mini event -> absorb it (roll back its
        --      seconds, decrement the count) and take its start.
        --      That is the 11->8->0 case, which until now counted
        --      as MINI downtime by accident via the ramp's 8->9.
        --   2. BigDT_Pending_Start -> the 11->7 case.
        --   3. GETUTCDATE() -> fell to 0 from somewhere else.
        -- Closes at -> step 11 via the V5.6 CLOSE below.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 0
            AND d.Machine_Step_No <> 0
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_Z0 NVARCHAR(50)
            DECLARE @StepFrom_Z0    INT
            DECLARE @GID_Z0         INT
            DECLARE @Start_Z0       DATETIME
            DECLARE @MiniStart_Z0   DATETIME
            DECLARE @MiniSecs_Z0    INT
            DECLARE @MiniCount_Z0   INT
            DECLARE @Pend_Z0        DATETIME
            DECLARE @PendIn_Z0      BIGINT          -- [V6.2] stashed counters
            DECLARE @PendOut_Z0     BIGINT
            DECLARE @SegNo_Z0       INT
            DECLARE @GID_SEG_Z0     INT             -- [V6.4] running batch for the segment

            DECLARE z0_cursor CURSOR FOR
                SELECT i.Machine, d.Machine_Step_No
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 0
                AND d.Machine_Step_No <> 0
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN z0_cursor
            FETCH NEXT FROM z0_cursor INTO @cur_Machine_Z0, @StepFrom_Z0

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_Z0 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_Z0
                AND End_time_CIP IS NULL

                IF @GID_Z0 IS NOT NULL
                BEGIN
                    SELECT @MiniStart_Z0 = Current_Downtime_Start,
                           @MiniSecs_Z0  = ISNULL(Current_Event_Seconds, 0),
                           @MiniCount_Z0 = Downtime_Count,
                           @Pend_Z0      = BigDT_Pending_Start
                    FROM [Change paper brik]
                    WHERE ID = @GID_Z0

                    IF @MiniStart_Z0 IS NOT NULL
                    BEGIN
                        -- Absorb the open mini event into the big one.
                        SET @Start_Z0 = @MiniStart_Z0

                        UPDATE [Change paper brik]
                        SET Downtime_Count         = ISNULL(Downtime_Count, 1) - 1,
                            Total_Downtime_Seconds = ISNULL(Total_Downtime_Seconds, 0) - @MiniSecs_Z0,
                            Current_Downtime_Start = NULL,
                            Current_Event_Seconds  = NULL,
                            DE_Flag_Current_Event  = NULL
                        WHERE ID = @GID_Z0

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_Z0 + '_DT:ABORT:step=' + CAST(@StepFrom_Z0 AS NVARCHAR) +
                                '->0:rollback=' + CAST(@MiniSecs_Z0 AS NVARCHAR) + 's-ABSORBED')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_Z0, 'ABORT', @StepFrom_Z0, 0, @GID_Z0, @MiniCount_Z0, NULL, NULL, GETUTCDATE())
                    END
                    ELSE
                        SET @Start_Z0 = ISNULL(@Pend_Z0, GETUTCDATE())

                    IF NOT EXISTS (SELECT 1 FROM [Big_Downtime_log] WHERE Batch_ID = @GID_Z0 AND Status = 'OPEN')
                    BEGIN
                        INSERT INTO [Big_Downtime_log]
                            (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Log_Time)
                        VALUES
                            (@cur_Machine_Z0, @GID_Z0, @Start_Z0, NULL, NULL, 'OPEN', GETUTCDATE())

                        UPDATE [Change paper brik]
                        SET BigDT_Pending_Start = NULL
                        WHERE ID = @GID_Z0

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_Z0 + '_BDL:OPEN:step=' + CAST(@StepFrom_Z0 AS NVARCHAR) +
                                '->0:ID=' + CAST(@GID_Z0 AS NVARCHAR) +
                                ':start=' + CONVERT(NVARCHAR, @Start_Z0, 121))

                        -- [V6.2] Commit the stashed feed counters as a
                        -- segment. This is the whole point of the stash:
                        -- on a PLC death the counter-zero edge that
                        -- _BD:RESET watches for never happens, so without
                        -- this the pre-cut feed is lost. Step 13 then
                        -- folds it via the existing OUTER APPLY, and for
                        -- A/B/D/M the re-fire self-heals In_Feed_MC.
                        --
                        -- Skips if _BD:RESET already logged this exact
                        -- counter -- both paths capture the same pre-reset
                        -- value, so equality is a safe dedupe key.
                        -- [V6.4] The stash lives on the RUNNING batch, which is
                        -- not necessarily @GID_Z0: a next-loop row can be created
                        -- between the stash and this commit, moving MAX(ID). V6.2's
                        -- claim that the two "can never land on different rows" was
                        -- wrong -- observed on M1 2026-08-26, where the stash sat on
                        -- 6526 and @GID_Z0 resolved to 6539, so the commit silently
                        -- found NULL and no segment was written at all.
                        SELECT @GID_SEG_Z0 = MAX(ID)
                        FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                        WHERE Machine = @cur_Machine_Z0
                        AND [Splicing time 1] IS NOT NULL
                        AND [end time] IS NULL

                        SELECT @PendIn_Z0  = BigDT_Pending_Infeed,
                               @PendOut_Z0 = BigDT_Pending_Outfeed
                        FROM [Change paper brik]
                        WHERE ID = @GID_SEG_Z0

                        IF @GID_SEG_Z0 IS NOT NULL
                           AND @PendIn_Z0 > 0
                           AND NOT EXISTS (
                                SELECT 1 FROM [Feed_Segment_log]
                                WHERE Batch_ID = @GID_SEG_Z0
                                AND In_Feed_Seg = @PendIn_Z0
                           )
                        BEGIN
                            SELECT @SegNo_Z0 = ISNULL(MAX(Segment_No), 0) + 1
                            FROM [Feed_Segment_log]
                            WHERE Batch_ID = @GID_SEG_Z0

                            INSERT INTO [Feed_Segment_log]
                                (Machine, Batch_ID, Segment_No, In_Feed_Seg, Out_Feed_Seg, Reset_Time, Ended_By, Log_Time)
                            VALUES
                                (@cur_Machine_Z0, @GID_SEG_Z0, @SegNo_Z0, @PendIn_Z0, @PendOut_Z0,
                                 GETUTCDATE(), 'POWERCUT', GETUTCDATE())

                            INSERT INTO t_log(txt)
                            VALUES (@cur_Machine_Z0 + '_BD:SEG0:step=' + CAST(@StepFrom_Z0 AS NVARCHAR) +
                                    '->0:ID=' + CAST(@GID_SEG_Z0 AS NVARCHAR) +
                                    ':seg=' + CAST(@SegNo_Z0 AS NVARCHAR) +
                                    ':infeed=' + CAST(@PendIn_Z0 AS NVARCHAR) +
                                    ':outfeed=' + ISNULL(CAST(@PendOut_Z0 AS NVARCHAR), 'NULL') + '-LOGGED')
                        END

                        -- Consumed either way: a stale stash must never be
                        -- committed against a later outage.
                        UPDATE [Change paper brik]
                        SET BigDT_Pending_Infeed  = NULL,
                            BigDT_Pending_Outfeed = NULL
                        WHERE ID = @GID_SEG_Z0
                    END
                END

                FETCH NEXT FROM z0_cursor INTO @cur_Machine_Z0, @StepFrom_Z0
            END

            CLOSE z0_cursor
            DEALLOCATE z0_cursor
        END

        -- -------------------------------------------------------
        -- [V5.6] -> STEP 11 : Big downtime CLOSE (resume, A/B/D/M)
        -- Production resumed and no FCIP voided the row -> real big
        -- downtime. Close the OPEN row and stamp the duration (loss).
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 11
            AND d.Machine_Step_No <> 11
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_BC   NVARCHAR(50)
            DECLARE @GID_BC           INT
            DECLARE @BDL_ID_BC        INT
            DECLARE @BDL_Start_BC     DATETIME

            DECLARE bc_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 11
                AND d.Machine_Step_No <> 11
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN bc_cursor
            FETCH NEXT FROM bc_cursor INTO @cur_Machine_BC

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_BC = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_BC
                AND End_time_CIP IS NULL

                IF @GID_BC IS NOT NULL
                BEGIN
                    SELECT @BDL_ID_BC = MAX(ID)
                    FROM [Big_Downtime_log]
                    WHERE Batch_ID = @GID_BC AND Status = 'OPEN'

                    IF @BDL_ID_BC IS NOT NULL
                    BEGIN
                        SELECT @BDL_Start_BC = Start_Time
                        FROM [Big_Downtime_log]
                        WHERE ID = @BDL_ID_BC

                        UPDATE [Big_Downtime_log]
                        SET End_Time         = GETUTCDATE(),
                            Duration_Seconds = DATEDIFF(SECOND, @BDL_Start_BC, GETUTCDATE()),
                            Status           = 'CLOSED',
                            Log_Time         = GETUTCDATE()
                        WHERE ID = @BDL_ID_BC

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_BC + '_BDL:CLOSE:ID=' + CAST(@GID_BC AS NVARCHAR) +
                                ':dur=' + CAST(DATEDIFF(SECOND, @BDL_Start_BC, GETUTCDATE()) AS NVARCHAR) + 's')
                    END
                END

                FETCH NEXT FROM bc_cursor INTO @cur_Machine_BC
            END

            CLOSE bc_cursor
            DEALLOCATE bc_cursor
        END

        -- -------------------------------------------------------
        -- [V6] DE LINE DOWN START : signal_DE_NotReady 0 -> 1
        -- Window active (Current_Downtime_Start set) -> set the blame
        -- flag only: no episode, no count (spikes collapse into one).
        -- Window inactive -> V5.8 standalone episode (unchanged),
        -- still gated on motor start ([Splicing time 1] IS NOT NULL,
        -- rev 2026-06-24) and one OPEN row per batch.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.signal_DE_NotReady = 1
            AND d.signal_DE_NotReady = 0
        )
        BEGIN
            DECLARE @cur_Machine_DE   NVARCHAR(50)
            DECLARE @GID_DE           INT
            DECLARE @DE_Count         INT
            DECLARE @DT_Active_DE     BIT             -- [V6] filling window active?
            DECLARE @Flag_DE          BIT             -- [V6] flag already set?

            DECLARE de_start_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.signal_DE_NotReady = 1
                AND d.signal_DE_NotReady = 0

            OPEN de_start_cursor
            FETCH NEXT FROM de_start_cursor INTO @cur_Machine_DE

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- [V5.8 rev 2026-06-24] Gate DE downtime on the filler having
                -- actually reached motor start (Step 10). Step 10 stamps
                -- [Splicing time 1], so [Splicing time 1] IS NOT NULL = "the
                -- production loop has started for this batch". A DE-not-ready
                -- signal during startup, BEFORE motor start, is not lost
                -- production time, so it must NOT open a DE episode.
                SELECT @GID_DE = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DE
                AND [end time] IS NULL
                AND [Splicing time 1] IS NOT NULL

                IF @GID_DE IS NOT NULL
                BEGIN
                    SELECT @DT_Active_DE = CASE WHEN Current_Downtime_Start IS NOT NULL THEN 1 ELSE 0 END,
                           @Flag_DE      = ISNULL(DE_Flag_Current_Event, 0)
                    FROM [Change paper brik]
                    WHERE ID = @GID_DE

                    IF @DT_Active_DE = 1
                    BEGIN
                        -- [V6] Inside a filling window: blame flag only.
                        -- Repeat spikes while already flagged are silent.
                        IF @Flag_DE = 0
                        BEGIN
                            UPDATE [Change paper brik]
                            SET DE_Flag_Current_Event = 1
                            WHERE ID = @GID_DE

                            INSERT INTO t_log(txt)
                            VALUES (@cur_Machine_DE + '_DE:FLAG:ID=' + CAST(@GID_DE AS NVARCHAR))
                        END
                    END
                    ELSE IF NOT EXISTS (SELECT 1 FROM [DE_Downtime_log] WHERE Batch_ID = @GID_DE AND Status = 'OPEN')
                    BEGIN
                        -- Standalone episode (filler producing, DE stalls).
                        SELECT @DE_Count = ISNULL(DE_Downtime_Count, 0) + 1
                        FROM [Change paper brik]
                        WHERE ID = @GID_DE

                        UPDATE [Change paper brik]
                        SET DE_Downtime_Count         = @DE_Count,
                            Current_DE_Downtime_Start = GETUTCDATE()
                        WHERE ID = @GID_DE

                        INSERT INTO [DE_Downtime_log]
                            (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Source, Log_Time)
                        VALUES
                            (@cur_Machine_DE, @GID_DE, GETUTCDATE(), NULL, NULL, 'OPEN', 'SIGNAL', GETUTCDATE())

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_DE + '_DE:START:ID=' + CAST(@GID_DE AS NVARCHAR) +
                                ':count=' + CAST(@DE_Count AS NVARCHAR))
                    END
                END

                FETCH NEXT FROM de_start_cursor INTO @cur_Machine_DE
            END

            CLOSE de_start_cursor
            DEALLOCATE de_start_cursor
        END

        -- -------------------------------------------------------
        -- [V6] DE LINE DOWN END : signal_DE_NotReady 1 -> 0
        -- Window active -> edge swallowed (spike; the flag decides at
        -- filling END, an OPEN lead-in episode rides through).
        -- Window inactive -> V5.8 close (unchanged): stamp duration,
        -- add to Total_DE_Downtime_Seconds. Fallback to the OPEN row's
        -- batch kept as a safety net; usually a no-op now that Step 13
        -- closes OPEN episodes at batch end.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.signal_DE_NotReady = 0
            AND d.signal_DE_NotReady = 1
        )
        BEGIN
            DECLARE @cur_Machine_DEE  NVARCHAR(50)
            DECLARE @GID_DEE          INT
            DECLARE @DE_ID_E          INT
            DECLARE @DE_Start_E       DATETIME
            DECLARE @DE_Dur_E         INT
            DECLARE @DT_Active_DEE    BIT             -- [V6] filling window active?

            DECLARE de_end_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.signal_DE_NotReady = 0
                AND d.signal_DE_NotReady = 1

            OPEN de_end_cursor
            FETCH NEXT FROM de_end_cursor INTO @cur_Machine_DEE

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_DEE = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DEE
                AND [end time] IS NULL

                SET @DT_Active_DEE = 0
                IF @GID_DEE IS NOT NULL
                    SELECT @DT_Active_DEE = CASE WHEN Current_Downtime_Start IS NOT NULL THEN 1 ELSE 0 END
                    FROM [Change paper brik]
                    WHERE ID = @GID_DEE

                -- [V6] Edge inside a filling window: swallowed (silent).
                IF @DT_Active_DEE = 0
                BEGIN
                    -- fall back to the OPEN episode's batch if the batch closed
                    IF @GID_DEE IS NULL
                        SELECT @GID_DEE = MAX(Batch_ID)
                        FROM [DE_Downtime_log]
                        WHERE Machine = @cur_Machine_DEE AND Status = 'OPEN'

                    IF @GID_DEE IS NOT NULL
                    BEGIN
                        SELECT @DE_ID_E = MAX(ID)
                        FROM [DE_Downtime_log]
                        WHERE Batch_ID = @GID_DEE AND Status = 'OPEN'

                        IF @DE_ID_E IS NOT NULL
                        BEGIN
                            SELECT @DE_Start_E = Start_Time
                            FROM [DE_Downtime_log]
                            WHERE ID = @DE_ID_E

                            SET @DE_Dur_E = DATEDIFF(SECOND, @DE_Start_E, GETUTCDATE())

                            UPDATE [DE_Downtime_log]
                            SET End_Time         = GETUTCDATE(),
                                Duration_Seconds = @DE_Dur_E,
                                Status           = 'CLOSED',
                                Log_Time         = GETUTCDATE()
                            WHERE ID = @DE_ID_E

                            UPDATE [Change paper brik]
                            SET Total_DE_Downtime_Seconds = ISNULL(Total_DE_Downtime_Seconds, 0) + @DE_Dur_E,
                                Current_DE_Downtime_Start = NULL
                            WHERE ID = @GID_DEE

                            INSERT INTO t_log(txt)
                            VALUES (@cur_Machine_DEE + '_DE:END:ID=' + CAST(@GID_DEE AS NVARCHAR) +
                                    ':dur=' + CAST(@DE_Dur_E AS NVARCHAR) + 's')
                        END
                    END
                END

                FETCH NEXT FROM de_end_cursor INTO @cur_Machine_DEE
            END

            CLOSE de_end_cursor
            DEALLOCATE de_end_cursor
        END

    COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION
        INSERT INTO t_log(txt) VALUES (ERROR_MESSAGE())
    END CATCH

END

GO
