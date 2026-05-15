with deduped as (
    select distinct
        ReceivedNo, ProductId, ProductionDate, InCartonAmount,
        CreateDate, MachineCode, GroupCode, filler_code
    from {{ source('analytics', 'raw_wms_transactions') }}
    where filler_code != 'Z2'
)

select
    t.ReceivedNo                                                as received_no,
    t.ProductId                                                 as product_id,
    t.ProductionDate                                            as production_date,
    t.InCartonAmount                                            as in_carton_amount,
    t.CreateDate                                                as create_date,
    t.MachineCode                                               as machine_code,
    t.GroupCode                                                 as group_code,
    t.filler_code,
    ri.plan_production_date,
    CONVERT(varchar, CAST(ri.plan_production_date as date), 112)
        + t.filler_code                                         as run_key,
    TRY_CAST(t.InCartonAmount as decimal(18,2))
        * TRY_CAST(mp.numbit as decimal(18,2))                  as total_briks_amount
from deduped t
left join {{ ref('stg_wms_receive_item') }} ri
    on t.ReceivedNo = ri.received_no
left join {{ source('analytics', 'raw_wms_mst_product') }} mp
    on t.ProductId = mp.ProductId
