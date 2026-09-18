-- Pillar 2: what the contract says we owe for each package.
--
-- The rate card is looked up on the *independently derived* service, zone and
-- rating weight from int_package_physical_truth -- never on the values the
-- carrier asserted. Fuel is indexed by the week the shipment physically moved,
-- not the week it happened to be invoiced, because carriers have an incentive to
-- drift an invoice into a higher-index week.
--
-- Accessorials are deliberately absent here: whether a fee is owed depends on
-- which fees were actually billed, so that adjudication lives in
-- int_billed_accessorials.
--
-- Grain: one row per package.

with physical_truth as (

    select * from {{ ref('int_package_physical_truth') }}

),

rate_card as (

    select * from {{ ref('carrier_rate_card') }}

),

fuel_index as (

    select * from {{ ref('carrier_fuel_surcharge_index') }}

),

rated as (

    select
        physical_truth.package_id,
        physical_truth.tracking_id,
        physical_truth.carrier_code,
        physical_truth.service_level,
        physical_truth.zone,
        physical_truth.rating_weight_lbs,
        physical_truth.scan_date,

        rate_card.weight_tier_min_lbs,
        rate_card.weight_tier_max_lbs,
        rate_card.contract_base_rate_usd,

        fuel_index.week_start_date       as fuel_index_week_start_date,
        fuel_index.fuel_surcharge_pct,

        round(
            rate_card.contract_base_rate_usd * fuel_index.fuel_surcharge_pct, 2
        ) as expected_fuel_surcharge_usd,

        -- A package that cannot be rated is an audit finding in its own right:
        -- it means the tariff does not cover what we shipped.
        rate_card.contract_base_rate_usd is not null as has_rate_card_match,
        fuel_index.fuel_surcharge_pct is not null    as has_fuel_index_match

    from physical_truth

    left join rate_card
        on physical_truth.carrier_code = rate_card.carrier_code
       and physical_truth.service_level = rate_card.service_level
       and physical_truth.zone = rate_card.zone
       and physical_truth.rating_weight_lbs between rate_card.weight_tier_min_lbs
                                                and rate_card.weight_tier_max_lbs
       and physical_truth.scan_date between rate_card.effective_date
                                        and rate_card.expiration_date

    left join fuel_index
        on physical_truth.carrier_code = fuel_index.carrier_code
       and physical_truth.scan_date between fuel_index.week_start_date
                                        and fuel_index.week_end_date

)

select * from rated
