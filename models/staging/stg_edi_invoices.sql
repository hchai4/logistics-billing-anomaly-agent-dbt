-- Pillar 3, channel A: automated EDI 210 freight invoice transmissions.
--
-- Casts and standardizes the raw EDI billing lines onto the shared carrier
-- invoice contract so they can be unioned with the portal channel. The EDI feed
-- names its money columns `base_rate` / `total_billed_amount`; those are aliased
-- to the canonical names here so downstream SQL never has to care which channel
-- a charge arrived through.

with source as (

    select * from {{ source('source_enterprise', 'raw_edi_ups_invoices') }}

),

cleaned as (

    select
        trim(edi_record_id)                                 as invoice_line_id,
        upper(replace(trim(tracking_id), ' ', ''))          as tracking_id,
        upper(trim(carrier_invoice_id))                     as invoice_number,

        'UPS_EDI'                                           as source_channel,
        '{{ var("audit_carrier_code") }}'                   as carrier_code,

        upper(trim(service_level_billed))                   as service_level_billed,
        cast(zone_billed as integer)                        as zone_billed,
        trim(dest_zip)                                      as dest_zip,

        cast(billed_weight as numeric(10, 2))               as billed_weight_lbs,
        cast(base_rate as numeric(12, 2))                   as billed_base_rate_usd,
        cast(fuel_surcharge as numeric(12, 2))              as billed_fuel_surcharge_usd,
        cast(total_billed_amount as numeric(12, 2))         as billed_total_usd,

        cast(invoice_date as date)                          as invoice_date,
        cast(delivery_timestamp as timestamp)               as delivery_timestamp,

        -- EDI has no document-received timestamp, so the invoice date anchors
        -- billing chronology. Used downstream to pick the first-billed line.
        cast(invoice_date as timestamp)                     as invoice_received_at

    from source
    where tracking_id is not null

)

select * from cleaned
