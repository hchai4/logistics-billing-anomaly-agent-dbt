-- Gate 3 adjudication: rules every billed accessorial fee authorized or not.
--
-- The ruling is driven by `authorization_rule` on the contracted tariff rather
-- than by hardcoded fee logic, so adding a fee type to the contract is a seed
-- change rather than a SQL change. Each fee is judged against the WMS delivery
-- address metadata, which is the evidence a carrier has to argue with:
--
--   RESIDENTIAL         is only owed if the delivery point really is residential.
--   ADDRESS_CORRECTION  is only owed if USPS CASS never validated the address.
--
-- Grain: one row per invoice per package (fees collapsed to the invoice).

with fee_lines as (

    select * from {{ ref('stg_carrier_accessorials') }}

),

tariff as (

    select * from {{ ref('carrier_accessorial_tariff') }}

),

delivery_point as (

    select
        tracking_id,
        dest_address_type,
        is_dest_address_cass_validated
    from {{ ref('stg_wms_scans') }}

),

adjudicated as (

    select
        fee_lines.accessorial_charge_id,
        fee_lines.tracking_id,
        fee_lines.invoice_number,
        fee_lines.source_channel,
        fee_lines.accessorial_code,
        fee_lines.accessorial_amount_usd,

        tariff.contract_amount_usd,
        tariff.authorization_rule,

        -- A fee with no matching tariff entry is unauthorized by definition:
        -- the carrier is charging for something we never agreed to.
        coalesce(
            case tariff.authorization_rule
                when 'ALWAYS'
                    then true
                when 'DEST_ADDRESS_TYPE_RESIDENTIAL'
                    then delivery_point.dest_address_type = 'RESIDENTIAL'
                when 'DEST_ADDRESS_NOT_CASS_VALIDATED'
                    then not delivery_point.is_dest_address_cass_validated
            end,
            false
        ) as is_authorized

    from fee_lines

    left join tariff
        on fee_lines.accessorial_code = tariff.accessorial_code

    left join delivery_point
        on fee_lines.tracking_id = delivery_point.tracking_id

),

by_invoice as (

    select
        tracking_id,
        invoice_number,

        count(*)                                as accessorial_line_count,
        sum(accessorial_amount_usd)             as billed_accessorial_usd,

        sum(case when is_authorized
                 then accessorial_amount_usd else 0 end)
                                                as authorized_accessorial_usd,
        sum(case when not is_authorized
                 then accessorial_amount_usd else 0 end)
                                                as unauthorized_accessorial_usd,

        -- Gate 3, primary finding: residential surcharge on a commercial address.
        bool_or(accessorial_code = 'RESIDENTIAL' and not is_authorized)
                                                as is_unauthorized_residential_fee,
        sum(case when accessorial_code = 'RESIDENTIAL' and not is_authorized
                 then accessorial_amount_usd else 0 end)
                                                as unauthorized_residential_fee_usd,

        -- Gate 3, secondary finding: address correction fee on a CASS-verified
        -- address.
        bool_or(accessorial_code = 'ADDRESS_CORRECTION' and not is_authorized)
                                                as is_unauthorized_address_correction_fee,
        sum(case when accessorial_code = 'ADDRESS_CORRECTION' and not is_authorized
                 then accessorial_amount_usd else 0 end)
                                                as unauthorized_address_correction_fee_usd,

        string_agg(
            distinct case when not is_authorized then accessorial_code end,
            ' | '
        )                                       as unauthorized_accessorial_codes

    from adjudicated
    group by tracking_id, invoice_number

)

select * from by_invoice
