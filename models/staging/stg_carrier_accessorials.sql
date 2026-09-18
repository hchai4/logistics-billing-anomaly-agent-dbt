-- Pillar 3 charge-line detail: the individual accessorial fees appended to an
-- invoice. Kept at its own grain because accessorials are a repeating group --
-- a single shipment can carry a residential surcharge, an address correction
-- fee and a delivery area surcharge simultaneously, and Gate 3 has to rule on
-- each one independently.
--
-- Grain: one row per accessorial fee line per invoice.

with source as (

    select * from {{ source('source_enterprise', 'raw_carrier_accessorial_charges') }}

),

cleaned as (

    select
        trim(accessorial_charge_id)                     as accessorial_charge_id,
        upper(replace(trim(tracking_id), ' ', ''))      as tracking_id,
        upper(trim(invoice_number))                     as invoice_number,
        upper(trim(source_channel))                     as source_channel,
        cast(charge_line_number as integer)             as charge_line_number,
        upper(trim(accessorial_code))                   as accessorial_code,
        cast(accessorial_amount as numeric(12, 2))      as accessorial_amount_usd,
        cast(invoice_date as date)                      as invoice_date

    from source
    where tracking_id is not null

)

select * from cleaned
