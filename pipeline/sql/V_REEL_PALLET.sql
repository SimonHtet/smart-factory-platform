-- ============================================================
-- REEL -> PALLET TRACEABILITY VIEWS  (2026-06-17)
-- Database : DB_BUDIBASE
-- Pairs with: TRI_UPDATE_FILLER_V5.7 (captures [dbo].[Reel_Splice_log])
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- PURPOSE
-- -------------------------------------------------------
-- Reverse traceability for recall. A finished pallet is found bad ->
-- trace back to the supplier barcode (reel) that fed it, and flag every
-- pallet that reel touched. Counter-based, time fully dropped.
--
-- MODEL
-- -------------------------------------------------------
-- [Change paper brik] stores, per batch, up to 45 reels loaded in order:
--   [Order1]/[Reel1] = 1st reel loaded, ... [OrderN]/[ReelN] = Nth reel.
--   supplier_barcode = Order + Reel concatenated.
-- [Reel_Splice_log] stores the live outfeed counter at each End-Roll.
--   Splice_No (k) = kth end-roll = boundary that ENDS reel k, STARTS reel k+1.
-- So reel N occupies outfeed [ boundary(k=N-1) .. boundary(k=N) ):
--   reel 1  : 0                 -> counter at splice 1
--   reel N  : counter@splice N-1 -> counter@splice N
--   running : counter@last splice -> live T_M_Filler_Process.counter_outfeed
--
-- PALLET MATH (deterministic, FLOOR/CEILING so a splice that lands mid-
-- pallet attributes that boundary pallet to BOTH reels -> recall-safe):
--   start_pallet = FLOOR(start_count / pallet_size) + 1
--   end_pallet   = CEILING(end_count  / pallet_size)
--
-- SCOPE (v1): Group M only (Machine LIKE 'M%'), [Product Date] >= today,
--             currently running batch (End_time_CIP IS NULL).
--             Widen by editing the WHERE clauses in both reel CTEs.
-- ASSUMPTIONS (v1):
--   * pallet_size hardcoded 4800. Parametrize via Product_Pallet_Spec later.
--   * RAW live counter (no V5.5 SUM(Feed_Segment_log) correction). Fine for a
--     clean run; a mid-run big-downtime counter reset would distort it -> v2.
--   * Order/Reel columns are [Order1..45]/[Reel1..45] (no space, no _No).
--     If the real names differ, fix the CROSS APPLY (VALUES ...) lists below.
--
-- Run ONCE before these views (also in the V5.7 header):
--   CREATE TABLE [dbo].[Reel_Splice_log] (
--       ID              INT IDENTITY(1,1) PRIMARY KEY,
--       Machine         NVARCHAR(50),
--       Batch_ID        INT,
--       Splice_No       INT,
--       Counter_Outfeed BIGINT,
--       Splice_Time     DATETIME,
--       Log_Time        DATETIME
--   );
-- ============================================================

USE [DB_BUDIBASE]
GO

-- ------------------------------------------------------------
-- VIEW A : v_reel_pallet_estimate
-- One row per reel in each running batch.
-- Columns: id, product_id, supplier_barcode, outfeed
-- (outfeed = cumulative outfeed at which that reel ended; live for the
--  currently running reel.)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW [analytics].[v_reel_pallet_estimate] AS
WITH splice AS (
    SELECT Batch_ID, Splice_No AS k, Counter_Outfeed AS c
    FROM [dbo].[Reel_Splice_log]
),
live AS (
    SELECT Machine, MAX(counter_outfeed) AS live_c
    FROM [dbo].[T_M_Filler_Process]
    GROUP BY Machine
),
reel AS (
    SELECT
        cpb.ID           AS Batch_ID,
        cpb.[Product_ID] AS product_id,
        cpb.Machine,
        v.N,
        CAST(CAST(v.ord  AS decimal(38,0)) AS varchar(50))
      + CAST(CAST(v.reel AS decimal(38,0)) AS varchar(50)) AS supplier_barcode
    FROM [dbo].[Change paper brik] cpb
    CROSS APPLY (VALUES
        (1, cpb.[Order1], cpb.[Reel1]),   (2, cpb.[Order2], cpb.[Reel2]),
        (3, cpb.[Order3], cpb.[Reel3]),   (4, cpb.[Order4], cpb.[Reel4]),
        (5, cpb.[Order5], cpb.[Reel5]),   (6, cpb.[Order6], cpb.[Reel6]),
        (7, cpb.[Order7], cpb.[Reel7]),   (8, cpb.[Order8], cpb.[Reel8]),
        (9, cpb.[Order9], cpb.[Reel9]),   (10, cpb.[Order10], cpb.[Reel10]),
        (11, cpb.[Order11], cpb.[Reel11]),(12, cpb.[Order12], cpb.[Reel12]),
        (13, cpb.[Order13], cpb.[Reel13]),(14, cpb.[Order14], cpb.[Reel14]),
        (15, cpb.[Order15], cpb.[Reel15]),(16, cpb.[Order16], cpb.[Reel16]),
        (17, cpb.[Order17], cpb.[Reel17]),(18, cpb.[Order18], cpb.[Reel18]),
        (19, cpb.[Order19], cpb.[Reel19]),(20, cpb.[Order20], cpb.[Reel20]),
        (21, cpb.[Order21], cpb.[Reel21]),(22, cpb.[Order22], cpb.[Reel22]),
        (23, cpb.[Order23], cpb.[Reel23]),(24, cpb.[Order24], cpb.[Reel24]),
        (25, cpb.[Order25], cpb.[Reel25]),(26, cpb.[Order26], cpb.[Reel26]),
        (27, cpb.[Order27], cpb.[Reel27]),(28, cpb.[Order28], cpb.[Reel28]),
        (29, cpb.[Order29], cpb.[Reel29]),(30, cpb.[Order30], cpb.[Reel30]),
        (31, cpb.[Order31], cpb.[Reel31]),(32, cpb.[Order32], cpb.[Reel32]),
        (33, cpb.[Order33], cpb.[Reel33]),(34, cpb.[Order34], cpb.[Reel34]),
        (35, cpb.[Order35], cpb.[Reel35]),(36, cpb.[Order36], cpb.[Reel36]),
        (37, cpb.[Order37], cpb.[Reel37]),(38, cpb.[Order38], cpb.[Reel38]),
        (39, cpb.[Order39], cpb.[Reel39]),(40, cpb.[Order40], cpb.[Reel40]),
        (41, cpb.[Order41], cpb.[Reel41]),(42, cpb.[Order42], cpb.[Reel42]),
        (43, cpb.[Order43], cpb.[Reel43]),(44, cpb.[Order44], cpb.[Reel44]),
        (45, cpb.[Order45], cpb.[Reel45])
    ) v(N, ord, reel)
    WHERE cpb.Machine LIKE 'M%'                            -- Group M only (v1 scope)
      AND cpb.[Product Date] >= CAST(GETDATE() AS DATE)    -- today onward only
      AND cpb.End_time_CIP IS NULL                          -- currently running batch
      AND v.ord IS NOT NULL                                 -- only reels actually loaded
)
SELECT
    r.Batch_ID         AS id,
    r.product_id,
    r.supplier_barcode,
    ISNULL(s_end.c, l.live_c) AS outfeed     -- boundary k=N, else live (running reel)
FROM reel r
LEFT JOIN splice s_end ON s_end.Batch_ID = r.Batch_ID AND s_end.k = r.N
LEFT JOIN live   l     ON l.Machine = r.Machine
GO

-- ------------------------------------------------------------
-- VIEW B : v_reel_pallet_map
-- One row per (reel, pallet) -> the many-to-many recall surface.
-- Columns: id, product_id, supplier_barcode, pallet_no
-- A bad pallet:  SELECT supplier_barcode FROM analytics.v_reel_pallet_map
--                WHERE id = @batch AND pallet_no = @pallet;
-- A bad reel:    ... WHERE supplier_barcode = @bc;  -> every pallet it touched.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW [analytics].[v_reel_pallet_map] AS
WITH splice AS (
    SELECT Batch_ID, Splice_No AS k, Counter_Outfeed AS c
    FROM [dbo].[Reel_Splice_log]
),
live AS (
    SELECT Machine, MAX(counter_outfeed) AS live_c
    FROM [dbo].[T_M_Filler_Process]
    GROUP BY Machine
),
reel AS (
    SELECT
        cpb.ID           AS Batch_ID,
        cpb.[Product_ID] AS product_id,
        cpb.Machine,
        v.N,
        CAST(CAST(v.ord  AS decimal(38,0)) AS varchar(50))
      + CAST(CAST(v.reel AS decimal(38,0)) AS varchar(50)) AS supplier_barcode
    FROM [dbo].[Change paper brik] cpb
    CROSS APPLY (VALUES
        (1, cpb.[Order1], cpb.[Reel1]),   (2, cpb.[Order2], cpb.[Reel2]),
        (3, cpb.[Order3], cpb.[Reel3]),   (4, cpb.[Order4], cpb.[Reel4]),
        (5, cpb.[Order5], cpb.[Reel5]),   (6, cpb.[Order6], cpb.[Reel6]),
        (7, cpb.[Order7], cpb.[Reel7]),   (8, cpb.[Order8], cpb.[Reel8]),
        (9, cpb.[Order9], cpb.[Reel9]),   (10, cpb.[Order10], cpb.[Reel10]),
        (11, cpb.[Order11], cpb.[Reel11]),(12, cpb.[Order12], cpb.[Reel12]),
        (13, cpb.[Order13], cpb.[Reel13]),(14, cpb.[Order14], cpb.[Reel14]),
        (15, cpb.[Order15], cpb.[Reel15]),(16, cpb.[Order16], cpb.[Reel16]),
        (17, cpb.[Order17], cpb.[Reel17]),(18, cpb.[Order18], cpb.[Reel18]),
        (19, cpb.[Order19], cpb.[Reel19]),(20, cpb.[Order20], cpb.[Reel20]),
        (21, cpb.[Order21], cpb.[Reel21]),(22, cpb.[Order22], cpb.[Reel22]),
        (23, cpb.[Order23], cpb.[Reel23]),(24, cpb.[Order24], cpb.[Reel24]),
        (25, cpb.[Order25], cpb.[Reel25]),(26, cpb.[Order26], cpb.[Reel26]),
        (27, cpb.[Order27], cpb.[Reel27]),(28, cpb.[Order28], cpb.[Reel28]),
        (29, cpb.[Order29], cpb.[Reel29]),(30, cpb.[Order30], cpb.[Reel30]),
        (31, cpb.[Order31], cpb.[Reel31]),(32, cpb.[Order32], cpb.[Reel32]),
        (33, cpb.[Order33], cpb.[Reel33]),(34, cpb.[Order34], cpb.[Reel34]),
        (35, cpb.[Order35], cpb.[Reel35]),(36, cpb.[Order36], cpb.[Reel36]),
        (37, cpb.[Order37], cpb.[Reel37]),(38, cpb.[Order38], cpb.[Reel38]),
        (39, cpb.[Order39], cpb.[Reel39]),(40, cpb.[Order40], cpb.[Reel40]),
        (41, cpb.[Order41], cpb.[Reel41]),(42, cpb.[Order42], cpb.[Reel42]),
        (43, cpb.[Order43], cpb.[Reel43]),(44, cpb.[Order44], cpb.[Reel44]),
        (45, cpb.[Order45], cpb.[Reel45])
    ) v(N, ord, reel)
    WHERE cpb.Machine LIKE 'M%'                            -- Group M only (v1 scope)
      AND cpb.[Product Date] >= CAST(GETDATE() AS DATE)    -- today onward only
      AND cpb.End_time_CIP IS NULL                          -- currently running batch
      AND v.ord IS NOT NULL
),
rng AS (
    SELECT
        r.Batch_ID AS id, r.product_id, r.supplier_barcode,
        CONVERT(INT, FLOOR(ISNULL(s_start.c, 0)        / 4800.0) + 1) AS start_pallet,
        CONVERT(INT, CEILING(ISNULL(s_end.c, l.live_c) / 4800.0))     AS end_pallet
    FROM reel r
    LEFT JOIN splice s_start ON s_start.Batch_ID = r.Batch_ID AND s_start.k = r.N - 1
    LEFT JOIN splice s_end   ON s_end.Batch_ID   = r.Batch_ID AND s_end.k   = r.N
    LEFT JOIN live   l       ON l.Machine = r.Machine
)
SELECT rng.id, rng.product_id, rng.supplier_barcode, p.pallet_no
FROM rng
CROSS APPLY (
    SELECT TOP (rng.end_pallet - rng.start_pallet + 1)
           rng.start_pallet + CONVERT(INT, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) - 1 AS pallet_no
    FROM sys.all_objects
) p
WHERE rng.end_pallet >= rng.start_pallet
GO
