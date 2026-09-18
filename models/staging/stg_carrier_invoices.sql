-- Pillar 3 unified: every dollar the carrier has demanded, regardless of how it
-- was transmitted.
--
-- The two channels are combined with UNION ALL rather than UNION on purpose.
-- Deduplicating here would destroy the very signal Gate 4 exists to detect: the
-- same tracking_id legitimately appearing twice, once per channel, is the
-- double-dipping evidence. Collapsing it would silently absorb the overcharge.
--
-- Grain: one row per carrier charge line.

with edi as (

    select * from {{ ref('stg_edi_invoices') }}

),

portal as (

    select * from {{ ref('stg_portal_invoices') }}

),

unioned as (

    select
        invoice_line_id,
        tracking_id,
        invoice_number,
        source_channel,
        carrier_code,
        service_level_billed,
        zone_billed,
        dest_zip,
        billed_weight_lbs,
        billed_base_rate_usd,
        billed_fuel_surcharge_usd,
        billed_total_usd,
        invoice_date,
        delivery_timestamp,
        invoice_received_at
    from edi

    union all

    select
        invoice_line_id,
        tracking_id,
        invoice_number,
        source_channel,
        carrier_code,
        service_level_billed,
        zone_billed,
        dest_zip,
        billed_weight_lbs,
        billed_base_rate_usd,
        billed_fuel_surcharge_usd,
        billed_total_usd,
        invoice_date,
        delivery_timestamp,
        invoice_received_at
    from portal

)

select * from unioned
