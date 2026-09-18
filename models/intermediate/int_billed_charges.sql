-- Pillar 3 collapsed to the shipment: what the carrier demanded for each package
-- across every channel and every invoice.
--
-- Collapsing many charge lines onto one shipment forces a decision about which
-- line the rate and weight gates should judge. Summing the lines would be wrong:
-- a package billed twice would show double the base rate and false-positive on
-- Gate 2. So the *first-billed* line is designated primary and adjudicated by
-- Gates 1, 2, 3 and 5, while every later line is treated as duplicate exposure
-- and adjudicated by Gate 4. Each dollar is therefore attributed to exactly one
-- gate.
--
-- Grain: one row per package.

with invoice_lines as (

    select * from {{ ref('stg_carrier_invoices') }}

),

accessorials as (

    select * from {{ ref('int_billed_accessorials') }}

),

lines_with_fees as (

    select
        invoice_lines.invoice_line_id,
        invoice_lines.tracking_id,
        invoice_lines.invoice_number,
        invoice_lines.source_channel,
        invoice_lines.carrier_code,
        invoice_lines.service_level_billed,
        invoice_lines.zone_billed,
        invoice_lines.billed_weight_lbs,
        invoice_lines.billed_base_rate_usd,
        invoice_lines.billed_fuel_surcharge_usd,
        invoice_lines.billed_total_usd,
        invoice_lines.invoice_date,
        invoice_lines.delivery_timestamp,
        invoice_lines.invoice_received_at,

        coalesce(accessorials.billed_accessorial_usd, 0)
            as billed_accessorial_usd,
        coalesce(accessorials.authorized_accessorial_usd, 0)
            as authorized_accessorial_usd,
        coalesce(accessorials.unauthorized_accessorial_usd, 0)
            as unauthorized_accessorial_usd,
        coalesce(accessorials.is_unauthorized_residential_fee, false)
            as is_unauthorized_residential_fee,
        coalesce(accessorials.unauthorized_residential_fee_usd, 0)
            as unauthorized_residential_fee_usd,
        coalesce(accessorials.is_unauthorized_address_correction_fee, false)
            as is_unauthorized_address_correction_fee,
        coalesce(accessorials.unauthorized_address_correction_fee_usd, 0)
            as unauthorized_address_correction_fee_usd,
        accessorials.unauthorized_accessorial_codes

    from invoice_lines

    left join accessorials
        on invoice_lines.tracking_id = accessorials.tracking_id
       and invoice_lines.invoice_number = accessorials.invoice_number

),

sequenced as (

    select
        *,
        row_number() over (
            partition by tracking_id
            order by invoice_received_at, invoice_date, source_channel, invoice_number
        ) as billing_sequence
    from lines_with_fees

),

shipment_rollup as (

    -- Postgres does not permit COUNT(DISTINCT ...) as a window function, so the
    -- cross-channel counts Gate 4 depends on are aggregated separately and
    -- rejoined to the primary line.
    select
        tracking_id,
        count(*)                                as billed_line_count,
        count(distinct invoice_number)          as distinct_invoice_number_count,
        count(distinct source_channel)          as distinct_source_channel_count,
        sum(billed_total_usd)                   as billed_total_all_lines_usd,
        sum(unauthorized_accessorial_usd)       as unauthorized_accessorial_all_lines_usd,
        max(billed_weight_lbs)                  as max_billed_weight_lbs,
        min(delivery_timestamp)                 as first_delivery_timestamp,
        string_agg(distinct invoice_number, ' | ' order by invoice_number)
                                                as all_invoice_numbers,
        string_agg(distinct source_channel, ' | ' order by source_channel)
                                                as all_source_channels
    from lines_with_fees
    group by tracking_id

),

primary_line as (

    select * from sequenced where billing_sequence = 1

)

select
    primary_line.tracking_id,

    -- The designated primary charge: what Gates 1, 2, 3 and 5 adjudicate.
    primary_line.invoice_line_id                as primary_invoice_line_id,
    primary_line.invoice_number                 as primary_invoice_number,
    primary_line.source_channel                 as primary_source_channel,
    primary_line.carrier_code,
    primary_line.service_level_billed,
    primary_line.zone_billed,
    primary_line.invoice_date                   as primary_invoice_date,
    primary_line.billed_weight_lbs,
    primary_line.billed_base_rate_usd,
    primary_line.billed_fuel_surcharge_usd,
    primary_line.billed_accessorial_usd,
    primary_line.billed_total_usd,
    primary_line.authorized_accessorial_usd,
    primary_line.unauthorized_accessorial_usd,
    primary_line.is_unauthorized_residential_fee,
    primary_line.unauthorized_residential_fee_usd,
    primary_line.is_unauthorized_address_correction_fee,
    primary_line.unauthorized_address_correction_fee_usd,
    primary_line.unauthorized_accessorial_codes,

    -- Carrier-reported delivery. The earliest scan across channels is used so a
    -- later rebill cannot quietly restate the delivery date to escape Gate 5.
    coalesce(primary_line.delivery_timestamp, shipment_rollup.first_delivery_timestamp)
                                                as actual_delivery_timestamp,

    -- Cross-channel exposure: what Gate 4 adjudicates.
    shipment_rollup.billed_line_count,
    shipment_rollup.distinct_invoice_number_count,
    shipment_rollup.distinct_source_channel_count,
    shipment_rollup.all_invoice_numbers,
    shipment_rollup.all_source_channels,
    shipment_rollup.max_billed_weight_lbs,
    shipment_rollup.billed_total_all_lines_usd,
    shipment_rollup.unauthorized_accessorial_all_lines_usd,

    -- Every dollar billed beyond the primary charge is duplicate exposure.
    round(
        shipment_rollup.billed_total_all_lines_usd - primary_line.billed_total_usd, 2
    )                                           as duplicate_billed_amount_usd

from primary_line

inner join shipment_rollup
    on primary_line.tracking_id = shipment_rollup.tracking_id
