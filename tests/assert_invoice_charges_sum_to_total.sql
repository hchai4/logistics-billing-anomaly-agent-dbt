-- Pillar 3 internal arithmetic: base rate + fuel + accessorials must equal the
-- invoice total on every charge line.
--
-- This is the SQL counterpart to the agent's math verifier, and it guards the
-- integrity of the input rather than the carrier's behaviour. The portal channel
-- is AI-extracted from PDFs, so a line that does not add up usually means the
-- extraction dropped or hallucinated a charge -- and auditing a carrier against
-- a misread invoice is how an audit program loses credibility.

with charge_lines as (

    select * from {{ ref('stg_carrier_invoices') }}

),

fees_by_invoice as (

    select
        tracking_id,
        invoice_number,
        sum(accessorial_amount_usd) as accessorial_usd
    from {{ ref('stg_carrier_accessorials') }}
    group by tracking_id, invoice_number

)

select
    charge_lines.invoice_line_id,
    charge_lines.tracking_id,
    charge_lines.invoice_number,
    charge_lines.source_channel,
    charge_lines.billed_base_rate_usd,
    charge_lines.billed_fuel_surcharge_usd,
    coalesce(fees_by_invoice.accessorial_usd, 0) as accessorial_usd,
    charge_lines.billed_total_usd,
    round(
        charge_lines.billed_total_usd
        - charge_lines.billed_base_rate_usd
        - charge_lines.billed_fuel_surcharge_usd
        - coalesce(fees_by_invoice.accessorial_usd, 0)
    , 2) as unexplained_usd

from charge_lines

left join fees_by_invoice
    on charge_lines.tracking_id = fees_by_invoice.tracking_id
   and charge_lines.invoice_number = fees_by_invoice.invoice_number

where abs(
        charge_lines.billed_total_usd
        - charge_lines.billed_base_rate_usd
        - charge_lines.billed_fuel_surcharge_usd
        - coalesce(fees_by_invoice.accessorial_usd, 0)
    ) > 0.01
