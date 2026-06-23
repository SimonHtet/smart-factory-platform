select
    id,
    [Product Date]                          as product_date,
    [Product_ID]                            as product_id,
    [Machine]                               as machine,
    [In_Feed_MC]                            as in_feed_mc,
    [Out_Feed_MC]                           as out_feed_mc,
    CASE
        WHEN [end time] IS NULL THEN [In_Feed_MC] + 150 - [Out_Feed_MC]
        ELSE [In_Feed_MC] - [Out_Feed_MC]
    END                                    as waste_tba,
    [Splicing time 1]                       as start_time,
    [end time]                              as end_time,
    [total_Var_Brik]                        as scanned_briks,
    [End_time_CIP]                          as end_time_cip,
    ISNULL([Downtime_Count], 0)             as downtime_count,
    ISNULL([Total_Downtime_Seconds], 0)     as total_downtime_seconds,
    -- V5.8: DE-line downtime (DE stall that idles the TBA filler, not the
    -- filler's own fault). Isolated so total can be split into tba-actual vs DE.
    ISNULL([DE_Downtime_Count], 0)          as de_downtime_count,
    ISNULL([Total_DE_Downtime_Seconds], 0)  as total_de_downtime_seconds,
    CONVERT(varchar, [Product Date], 112) + [Machine]  as run_key
from {{ source('dbo', 'Change paper brik') }}
where [Product Date] is not null
  and [Machine] is not null
