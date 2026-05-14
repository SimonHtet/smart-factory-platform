{{ config(materialized='view') }}

select
    *,

    CASE
        WHEN DATEPART(week, product_date) = DATEPART(week, GETDATE())
             AND YEAR(product_date) = YEAR(GETDATE())
        THEN 'Current Week'
        ELSE 'Week ' + CAST(DATEPART(week, product_date) AS varchar)
    END                                                             as week_label,

    CASE
        WHEN CAST(product_date AS DATE) = CAST(GETDATE() AS DATE)
        THEN 'Today'
        ELSE CONVERT(varchar, CAST(product_date AS DATE), 106)
    END                                                             as date_status,

    (waste_tba + waste_op + waste_de)
        / NULLIF(CAST(fg_briks_amount AS float), 0)                as waste_pct,

    total_downtime_seconds / 60.0                                  as downtime_minutes,

    CAST(waste_tba AS float)
        / NULLIF(CAST(out_feed_mc AS float), 0)                    as waste_tba_pct

from {{ ref('mart_production_runs') }}
