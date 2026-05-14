with deduped as (
    select distinct
        ProductionDate, ProductId, recall_amount as resend_amount,
        MachineCode, GroupCode, filler_code, CreateDate
    from {{ source('analytics', 'raw_wms_receive_item_location') }}
    where filler_code != 'Z2'
)

select
    d.ProductionDate                                            as production_date,
    d.ProductId                                                 as product_id,
    d.resend_amount,
    d.MachineCode                                               as machine_code,
    d.GroupCode                                                 as group_code,
    d.filler_code,
    d.CreateDate                                                as create_date,

    CONVERT(varchar, CAST(d.ProductionDate as date), 112)
        + d.filler_code                                         as recall_run_key,

    CONVERT(varchar, CAST(d.CreateDate as date), 112)
        + d.filler_code                                         as resend_run_key,

    TRY_CAST(d.resend_amount as decimal(18,2))
        * TRY_CAST(mp.numbit as decimal(18,2))                  as resend_briks_amount

from deduped d
left join {{ source('analytics', 'raw_wms_mst_product') }} mp
    on d.ProductId = mp.ProductId
