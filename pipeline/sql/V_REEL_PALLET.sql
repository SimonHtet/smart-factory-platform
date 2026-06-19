-- ============================================================
-- REEL -> PALLET TRACEABILITY VIEWS  (2026-06-17)
-- Database : DB_BUDIBASE
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- PURPOSE
-- -------------------------------------------------------
-- Reverse traceability for recall. A finished pallet is found bad ->
-- trace back to the supplier barcode (reel) that fed it, and flag every
-- pallet that reel touched.
--
-- METHOD = SUPPLIER-DECLARED PER-REEL COUNT (exact, no estimate)
-- -------------------------------------------------------
-- [Change paper brik] stores, per reel slot N (1..45):
--   [OrderN], [ReelN]          -> supplier_barcode = Order + Reel
--   [Var count N]              -> briks the SUPPLIER declares on that reel
-- Cumulative-summing the per-reel counts in reel order gives exact reel
-- boundaries -- no estimate, no live counter, no Reel_Splice_log. Works
-- retroactively on a batch already running.
--   reel seq N : end_count   = SUM(var_count for reels 1..N)
--                start_count = end_count - var_count(N)
--
-- PER-ORDER PALLET RESET (added 2026-06-17)
-- -------------------------------------------------------
-- Pallet numbers restart at 1 on every customer ORDER change; a REEL change
-- within the same order keeps counting. Implemented by subtracting the
-- order's start_count (briks before the order's first reel):
--   order_start = MIN(start_count) within the order run
--   pallet      = FLOOR((start_count - order_start)/4800)+1
--                 .. CEILING((end_count - order_start)/4800)
-- => pallet_no is NO LONGER unique per batch (pallet 3 exists in every order),
--    so v_reel_pallet_map now also exposes [order_no]. Recall lookups must
--    filter BOTH order_no and pallet_no.
-- order_run = running count of order changes (handles a repeated order value
--    appearing in two separate runs correctly).
--
-- DEDUP: the PLC repeats the same (Order,Reel) across several consecutive
-- columns while one reel runs (and repeats [Var count] with it) -> LAG-dedup
-- consecutive identical (Order,Reel) pairs, keep the first column of each run,
-- ROW_NUMBER survivors into seq = true reel order. supplier_barcode via
-- decimal(38,0) cast to kill float scientific notation.
--
-- PALLET MATH (FLOOR/CEILING so a reel straddling a pallet boundary flags
-- that pallet for BOTH reels -> recall-safe).
--
-- SCOPE (v1): Group M only (Machine LIKE 'M%'), [Product Date] >= 2026-06-16,
--             currently running batch (End_time_CIP IS NULL).
-- ASSUMPTIONS: pallet_size = 4800 (hardcoded; Product_Pallet_Spec later -- a
--             different order may have a different pallet size); [Var count N]
--             constant across a reel's duplicate columns; orders run
--             contiguously; columns [Order1..45]/[Reel1..45]/[Var count 1..45].
-- NOTE: the running (last) reel uses its FULL declared count -> safely
--       over-includes its tail pallets (the safe direction for recall).
-- ============================================================

USE [DB_BUDIBASE]
GO

-- ------------------------------------------------------------
-- VIEW A : v_reel_pallet_estimate
-- One row per reel in each running M batch.
-- Columns: id, product_id, supplier_barcode, outfeed
-- (outfeed = cumulative declared briks through the end of that reel --
--  a physical running total, does NOT reset per order.)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW [analytics].[v_reel_pallet_estimate] AS
WITH reel_raw AS (
    SELECT cpb.ID AS Batch_ID, cpb.[Product_ID] AS product_id, cpb.Machine,
           v.N, v.ord, v.reel, v.varc
    FROM [dbo].[Change paper brik] cpb
    CROSS APPLY (VALUES
        (1, cpb.[Order1], cpb.[Reel1], cpb.[Var count 1]),    (2, cpb.[Order2], cpb.[Reel2], cpb.[Var count 2]),
        (3, cpb.[Order3], cpb.[Reel3], cpb.[Var count 3]),    (4, cpb.[Order4], cpb.[Reel4], cpb.[Var count 4]),
        (5, cpb.[Order5], cpb.[Reel5], cpb.[Var count 5]),    (6, cpb.[Order6], cpb.[Reel6], cpb.[Var count 6]),
        (7, cpb.[Order7], cpb.[Reel7], cpb.[Var count 7]),    (8, cpb.[Order8], cpb.[Reel8], cpb.[Var count 8]),
        (9, cpb.[Order9], cpb.[Reel9], cpb.[Var count 9]),    (10, cpb.[Order10], cpb.[Reel10], cpb.[Var count 10]),
        (11, cpb.[Order11], cpb.[Reel11], cpb.[Var count 11]),(12, cpb.[Order12], cpb.[Reel12], cpb.[Var count 12]),
        (13, cpb.[Order13], cpb.[Reel13], cpb.[Var count 13]),(14, cpb.[Order14], cpb.[Reel14], cpb.[Var count 14]),
        (15, cpb.[Order15], cpb.[Reel15], cpb.[Var count 15]),(16, cpb.[Order16], cpb.[Reel16], cpb.[Var count 16]),
        (17, cpb.[Order17], cpb.[Reel17], cpb.[Var count 17]),(18, cpb.[Order18], cpb.[Reel18], cpb.[Var count 18]),
        (19, cpb.[Order19], cpb.[Reel19], cpb.[Var count 19]),(20, cpb.[Order20], cpb.[Reel20], cpb.[Var count 20]),
        (21, cpb.[Order21], cpb.[Reel21], cpb.[Var count 21]),(22, cpb.[Order22], cpb.[Reel22], cpb.[Var count 22]),
        (23, cpb.[Order23], cpb.[Reel23], cpb.[Var count 23]),(24, cpb.[Order24], cpb.[Reel24], cpb.[Var count 24]),
        (25, cpb.[Order25], cpb.[Reel25], cpb.[Var count 25]),(26, cpb.[Order26], cpb.[Reel26], cpb.[Var count 26]),
        (27, cpb.[Order27], cpb.[Reel27], cpb.[Var count 27]),(28, cpb.[Order28], cpb.[Reel28], cpb.[Var count 28]),
        (29, cpb.[Order29], cpb.[Reel29], cpb.[Var count 29]),(30, cpb.[Order30], cpb.[Reel30], cpb.[Var count 30]),
        (31, cpb.[Order31], cpb.[Reel31], cpb.[Var count 31]),(32, cpb.[Order32], cpb.[Reel32], cpb.[Var count 32]),
        (33, cpb.[Order33], cpb.[Reel33], cpb.[Var count 33]),(34, cpb.[Order34], cpb.[Reel34], cpb.[Var count 34]),
        (35, cpb.[Order35], cpb.[Reel35], cpb.[Var count 35]),(36, cpb.[Order36], cpb.[Reel36], cpb.[Var count 36]),
        (37, cpb.[Order37], cpb.[Reel37], cpb.[Var count 37]),(38, cpb.[Order38], cpb.[Reel38], cpb.[Var count 38]),
        (39, cpb.[Order39], cpb.[Reel39], cpb.[Var count 39]),(40, cpb.[Order40], cpb.[Reel40], cpb.[Var count 40]),
        (41, cpb.[Order41], cpb.[Reel41], cpb.[Var count 41]),(42, cpb.[Order42], cpb.[Reel42], cpb.[Var count 42]),
        (43, cpb.[Order43], cpb.[Reel43], cpb.[Var count 43]),(44, cpb.[Order44], cpb.[Reel44], cpb.[Var count 44]),
        (45, cpb.[Order45], cpb.[Reel45], cpb.[Var count 45])
    ) v(N, ord, reel, varc)
    WHERE cpb.Machine LIKE 'M%'                            -- Group M only (v1 scope)
      AND cpb.[Product Date] >= '2026-06-16'               -- from 2026-06-16
      AND cpb.End_time_CIP IS NULL                          -- currently running batch
      AND v.ord IS NOT NULL                                 -- only filled reel slots
),
reel_dd AS (
    SELECT Batch_ID, product_id, Machine, N, ord, reel, varc,
           LAG(ord)  OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_ord,
           LAG(reel) OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_reel
    FROM reel_raw
),
reel AS (
    SELECT Batch_ID, product_id, Machine,
           ROW_NUMBER() OVER (PARTITION BY Batch_ID ORDER BY N) AS seq,
           ISNULL(varc, 0) AS varc,
           CAST(CAST(ord  AS decimal(38,0)) AS varchar(50))
         + CAST(CAST(reel AS decimal(38,0)) AS varchar(50)) AS supplier_barcode
    FROM reel_dd
    WHERE prev_ord IS NULL                       -- first reel
       OR ord <> prev_ord OR reel <> prev_reel   -- reel/order actually changed
)
SELECT
    r.Batch_ID AS id,
    r.product_id,
    r.supplier_barcode,
    CONVERT(BIGINT, SUM(r.varc) OVER (PARTITION BY r.Batch_ID ORDER BY r.seq
                                      ROWS UNBOUNDED PRECEDING)) AS outfeed
FROM reel r
GO

-- ------------------------------------------------------------
-- VIEW B : v_reel_pallet_map
-- One row per (reel, pallet) -> the many-to-many recall surface.
-- Columns: id, product_id, order_no, supplier_barcode, pallet_no
-- Pallet numbers RESET to 1 per order_no, so recall lookups need both:
--   bad pallet: SELECT supplier_barcode FROM analytics.v_reel_pallet_map
--               WHERE id=@batch AND order_no=@order AND pallet_no=@pallet;
--   bad reel:   ... WHERE supplier_barcode=@bc;  -> every pallet it touched.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW [analytics].[v_reel_pallet_map] AS
WITH reel_raw AS (
    SELECT cpb.ID AS Batch_ID, cpb.[Product_ID] AS product_id, cpb.Machine,
           v.N, v.ord, v.reel, v.varc
    FROM [dbo].[Change paper brik] cpb
    CROSS APPLY (VALUES
        (1, cpb.[Order1], cpb.[Reel1], cpb.[Var count 1]),    (2, cpb.[Order2], cpb.[Reel2], cpb.[Var count 2]),
        (3, cpb.[Order3], cpb.[Reel3], cpb.[Var count 3]),    (4, cpb.[Order4], cpb.[Reel4], cpb.[Var count 4]),
        (5, cpb.[Order5], cpb.[Reel5], cpb.[Var count 5]),    (6, cpb.[Order6], cpb.[Reel6], cpb.[Var count 6]),
        (7, cpb.[Order7], cpb.[Reel7], cpb.[Var count 7]),    (8, cpb.[Order8], cpb.[Reel8], cpb.[Var count 8]),
        (9, cpb.[Order9], cpb.[Reel9], cpb.[Var count 9]),    (10, cpb.[Order10], cpb.[Reel10], cpb.[Var count 10]),
        (11, cpb.[Order11], cpb.[Reel11], cpb.[Var count 11]),(12, cpb.[Order12], cpb.[Reel12], cpb.[Var count 12]),
        (13, cpb.[Order13], cpb.[Reel13], cpb.[Var count 13]),(14, cpb.[Order14], cpb.[Reel14], cpb.[Var count 14]),
        (15, cpb.[Order15], cpb.[Reel15], cpb.[Var count 15]),(16, cpb.[Order16], cpb.[Reel16], cpb.[Var count 16]),
        (17, cpb.[Order17], cpb.[Reel17], cpb.[Var count 17]),(18, cpb.[Order18], cpb.[Reel18], cpb.[Var count 18]),
        (19, cpb.[Order19], cpb.[Reel19], cpb.[Var count 19]),(20, cpb.[Order20], cpb.[Reel20], cpb.[Var count 20]),
        (21, cpb.[Order21], cpb.[Reel21], cpb.[Var count 21]),(22, cpb.[Order22], cpb.[Reel22], cpb.[Var count 22]),
        (23, cpb.[Order23], cpb.[Reel23], cpb.[Var count 23]),(24, cpb.[Order24], cpb.[Reel24], cpb.[Var count 24]),
        (25, cpb.[Order25], cpb.[Reel25], cpb.[Var count 25]),(26, cpb.[Order26], cpb.[Reel26], cpb.[Var count 26]),
        (27, cpb.[Order27], cpb.[Reel27], cpb.[Var count 27]),(28, cpb.[Order28], cpb.[Reel28], cpb.[Var count 28]),
        (29, cpb.[Order29], cpb.[Reel29], cpb.[Var count 29]),(30, cpb.[Order30], cpb.[Reel30], cpb.[Var count 30]),
        (31, cpb.[Order31], cpb.[Reel31], cpb.[Var count 31]),(32, cpb.[Order32], cpb.[Reel32], cpb.[Var count 32]),
        (33, cpb.[Order33], cpb.[Reel33], cpb.[Var count 33]),(34, cpb.[Order34], cpb.[Reel34], cpb.[Var count 34]),
        (35, cpb.[Order35], cpb.[Reel35], cpb.[Var count 35]),(36, cpb.[Order36], cpb.[Reel36], cpb.[Var count 36]),
        (37, cpb.[Order37], cpb.[Reel37], cpb.[Var count 37]),(38, cpb.[Order38], cpb.[Reel38], cpb.[Var count 38]),
        (39, cpb.[Order39], cpb.[Reel39], cpb.[Var count 39]),(40, cpb.[Order40], cpb.[Reel40], cpb.[Var count 40]),
        (41, cpb.[Order41], cpb.[Reel41], cpb.[Var count 41]),(42, cpb.[Order42], cpb.[Reel42], cpb.[Var count 42]),
        (43, cpb.[Order43], cpb.[Reel43], cpb.[Var count 43]),(44, cpb.[Order44], cpb.[Reel44], cpb.[Var count 44]),
        (45, cpb.[Order45], cpb.[Reel45], cpb.[Var count 45])
    ) v(N, ord, reel, varc)
    WHERE cpb.Machine LIKE 'M%'          -- Group M only (v1 functional scope, kept)
      -- DE-SCOPED 2026-06-19: removed the two "currently-running-batch" guards
      -- so finished batches no longer disappear -> view now covers ALL HISTORY.
      --   AND cpb.[Product Date] >= '2026-06-16'   (removed)
      --   AND cpb.End_time_CIP IS NULL             (removed)
      AND v.ord IS NOT NULL
),
reel_dd AS (
    SELECT Batch_ID, product_id, Machine, N, ord, reel, varc,
           LAG(ord)  OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_ord,
           LAG(reel) OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_reel
    FROM reel_raw
),
reel AS (
    SELECT Batch_ID, product_id, Machine, ord,
           ROW_NUMBER() OVER (PARTITION BY Batch_ID ORDER BY N) AS seq,
           ISNULL(varc, 0) AS varc,
           CAST(CAST(ord AS decimal(38,0)) AS varchar(50)) AS order_no,
           CAST(CAST(ord  AS decimal(38,0)) AS varchar(50))
         + CAST(CAST(reel AS decimal(38,0)) AS varchar(50)) AS supplier_barcode
    FROM reel_dd
    WHERE prev_ord IS NULL
       OR ord <> prev_ord OR reel <> prev_reel
),
cum AS (
    SELECT Batch_ID, product_id, order_no, supplier_barcode, ord, varc, seq,
           SUM(varc) OVER (PARTITION BY Batch_ID ORDER BY seq
                           ROWS UNBOUNDED PRECEDING) AS end_count
    FROM reel
),
ordtag AS (
    SELECT *, LAG(ord) OVER (PARTITION BY Batch_ID ORDER BY seq) AS prev_ord_seq
    FROM cum
),
ordrun AS (
    SELECT *,
           SUM(CASE WHEN prev_ord_seq IS NULL OR ord <> prev_ord_seq THEN 1 ELSE 0 END)
               OVER (PARTITION BY Batch_ID ORDER BY seq ROWS UNBOUNDED PRECEDING) AS order_run
    FROM ordtag
),
rng AS (
    SELECT
        Batch_ID AS id, product_id, order_no, supplier_barcode,
        CONVERT(INT, FLOOR(((end_count - varc) - MIN(end_count - varc) OVER (PARTITION BY Batch_ID, order_run)) / 4800.0) + 1) AS start_pallet,
        CONVERT(INT, CEILING((end_count        - MIN(end_count - varc) OVER (PARTITION BY Batch_ID, order_run)) / 4800.0))     AS end_pallet
    FROM ordrun
)
SELECT rng.id, rng.product_id, rng.order_no, rng.supplier_barcode, p.pallet_no
FROM rng
CROSS APPLY (
    SELECT TOP (rng.end_pallet - rng.start_pallet + 1)
           rng.start_pallet + CONVERT(INT, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) - 1 AS pallet_no
    FROM sys.all_objects
) p
WHERE rng.end_pallet >= rng.start_pallet
GO
