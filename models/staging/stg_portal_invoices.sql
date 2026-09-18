-- Pillar 3, channel B: AI-extracted carrier portal invoices and emailed PDFs.
--
-- Reads the records the LLM extraction agent produced and standardizes them onto
-- the same contract as the EDI channel. The portal feed names its money columns
-- `base_charge` / `grand_total`; they are aliased to the canonical names here.
--
-- This channel matters disproportionately to Gate 4: a manual billing adjustment
-- PDF arriving weeks after the EDI feed already invoiced the shipment is exactly
-- how cross-channel double-dipping happens.

with source as (

    select * from {{ source('source_enterprise', 'raw_portal_extracted_invoices') }}

),

cleaned as (

    select
        'PORTAL-' || cast(portal_record_id as varchar)       as invoice_line_id,
        upper(replace(trim(tracking_id), ' ', ''))           as tracking_id,
        upper(trim(invoice_number))                          as invoice_number,

        'PORTAL_PDF_AI'                                      as source_channel,
        coalesce(upper(trim(carrier_name)), '{{ var("audit_carrier_code") }}')
                                                             as carrier_code,

        upper(trim(service_level_billed))                    as service_level_billed,
        cast(zone_billed as integer)                         as zone_billed,
        trim(dest_zip)                                       as dest_zip,

        cast(billed_weight as numeric(10, 2))                as billed_weight_lbs,
        cast(base_charge as numeric(12, 2))                  as billed_base_rate_usd,
        cast(fuel_surcharge as numeric(12, 2))               as billed_fuel_surcharge_usd,
        cast(grand_total as numeric(12, 2))                  as billed_total_usd,

        cast(invoice_date as date)                           as invoice_date,
        cast(delivery_timestamp as timestamp)                as delivery_timestamp,

        -- Portal documents do carry a genuine receipt timestamp: the moment the
        -- extraction agent parsed them.
        cast(extraction_timestamp as timestamp)              as invoice_received_at

    from source
    where tracking_id is not null

)

select * from cleaned
