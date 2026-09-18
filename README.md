# Logistics Billing Anomaly Agent — dbt Audit Models

A dbt project that reconciles warehouse measurements, carrier contract terms, and carrier invoice data to identify logistics billing anomalies and quantify recoverable dollars.

The project is designed for freight audit workflows where every finding should be supported by independent evidence and every recoverable dollar should be attributed exactly once.

## What this project does

The audit compares three realities for each shipment:

1. **Physical reality** — warehouse scale scans, package dimensions, geography, address metadata, and dock departure times.
2. **Contract reality** — version-controlled carrier contracts, rate cards, zone mappings, fuel indices, service commitments, and accessorial rules.
3. **Billed reality** — carrier EDI invoices, portal/PDF invoices extracted by an AI agent, and invoice-level accessorial charges.

The resulting marts apply five deterministic audit gates:

| Gate | Finding | Evidence |
| --- | --- | --- |
| 1 | `WEIGHT_INFLATION` | Carrier-billed weight exceeds the contractual billable weight beyond the rounding tolerance. |
| 2 | `BASE_RATE_OVERCHARGE` | Billed base rate or fuel charge exceeds the negotiated tariff expectation. |
| 3 | Unauthorized accessorials | Residential, address-correction, or other fees do not satisfy their contractual authorization rule. |
| 4 | `DUPLICATE_BILLING_COLLISION` | A shipment is billed multiple times or through multiple invoice channels. |
| 5 | `SLA_DELIVERY_FAILURE_REFUND` | A guaranteed service shipment was delivered outside its commitment plus the grace period. |

## Outputs

### `fct_reconciliation_marts`

A shipment-level reconciliation table with one row per `tracking_id`. It contains:

- Physical measurements and the independently derived contractual billable weight
- Contract rate, fuel, and accessorial expectations
- Primary invoice details and totals across all invoice lines/channels
- Independent flags and measurements for all five audit gates
- `total_recoverable_usd`, with non-overlapping recovery attribution
- `anomaly_codes` and `anomaly_count`
- `audit_status` and recovery-oriented `dispute_priority`

Possible audit statuses include:

- `CLEAN`
- `ANOMALY_DETECTED`
- `AWAITING_INVOICE`
- `UNRATEABLE_NO_TARIFF_MATCH`

### `fct_billing_anomalies`

A dispute-oriented table with one row per shipment per anomaly code. Each row includes:

- Gate number and anomaly code
- Recoverable dollars attributable to that finding
- A generated `dispute_evidence` sentence containing the physical, contractual, and billed evidence needed by a dispute workflow
- Shipment-level recovery and priority context

Gate 1 is retained as an explanatory reason code, but its dollars are attributed through the resulting rate variance to avoid double recovery. Gate 5 supersedes rate and fuel recovery for the same charge because a Guaranteed Service Refund returns the transportation charge in full.

## Project structure

```text
.
├── dbt_project.yml
├── profiles.yml                 # PostgreSQL profile; use with --profiles-dir .
├── requirements.txt
├── seeds/                       # Contractual ground truth
│   ├── carrier_accessorial_tariff.csv
│   ├── carrier_contract_terms.csv
│   ├── carrier_fuel_surcharge_index.csv
│   ├── carrier_rate_card.csv
│   ├── carrier_service_levels.csv
│   └── carrier_zone_matrix.csv
├── models/
│   ├── staging/                 # Typed and standardized source relations
│   ├── intermediate/            # Physical, contract, accessorial, and billing logic
│   └── marts/                   # Shipment and dispute-level audit outputs
└── tests/                       # Custom reconciliation and accounting assertions
```

## Requirements

- PostgreSQL 12+ (or a compatible supported PostgreSQL version)
- Python 3.9+
- dbt Core
- The dbt PostgreSQL adapter

The repository includes `psycopg2-binary` in `requirements.txt`. Install the dbt packages separately if they are not already available in your environment.

## Quick start

### 1. Clone and create an environment

```bash
git clone https://github.com/hchai4/logistics-billing-anomaly-agent-dbt.git
cd logistics-billing-anomaly-agent-dbt

python -m venv .venv
source .venv/bin/activate       # Windows: .venv\\Scripts\\activate
pip install -r requirements.txt
pip install dbt-core dbt-postgres
```

### 2. Configure PostgreSQL

The checked-in `profiles.yml` reads these environment variables and provides local defaults:

| Variable | Default | Description |
| --- | --- | --- |
| `POSTGRES_HOST` | `localhost` | PostgreSQL host |
| `POSTGRES_PORT` | `5432` | PostgreSQL port |
| `POSTGRES_USER` | `postgres` | Database user |
| `POSTGRES_PASSWORD` | `postgres` | Database password |
| `POSTGRES_DB` | `logistics_db` | Database name |

Create the database if necessary, then export credentials for your environment:

```bash
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres
export POSTGRES_DB=logistics_db
```

The dbt profile targets the `analytics` schema and configures four threads. Models are organized into `staging`, `intermediate`, and `marts` schemas; seeds are loaded into the `contract` schema according to `dbt_project.yml`.

### 3. Load contract seeds

Contractual data is version-controlled in `seeds/` because tariffs and contract terms are audit evidence. Load it with:

```bash
dbt seed --profiles-dir .
```

### 4. Verify the connection and build the project

```bash
dbt debug --profiles-dir .
dbt build --profiles-dir .
```

`dbt build` runs models and tests in dependency order. To run individual stages:

```bash
dbt run  --profiles-dir .
dbt test --profiles-dir .
```

To rebuild only the final audit outputs:

```bash
dbt build --profiles-dir . --select fct_reconciliation_marts fct_billing_anomalies
```

## Source data contract

Before running the models, populate the `source_enterprise` schema in `logistics_db` with these raw source tables:

- `raw_wms_package_scans` — one row per package, including certified weight, dimensions, ZIPs, address classification, CASS validation, service level, and dock departure time
- `raw_edi_ups_invoices` — EDI 210 invoice charge records
- `raw_portal_extracted_invoices` — AI-extracted portal/PDF invoices and billing adjustments
- `raw_carrier_accessorial_charges` — one row per invoice accessorial charge

The source definitions and column-level tests are documented in `models/staging/_sources.yml`. The three source pillars join through normalized `tracking_id` values. ZIP3 values are intentionally handled as strings so leading zeroes are preserved.

## Audit configuration

The main audit tolerances and carrier selection are configured in `dbt_project.yml`:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `weight_variance_tolerance_lbs` | `1.0` | Allows normal whole-pound rating round-up. |
| `base_rate_variance_tolerance_usd` | `0.05` | Allows small rate-card rounding differences. |
| `fuel_variance_tolerance_usd` | `0.25` | Allows fuel surcharge rounding differences. |
| `sla_grace_minutes` | `15` | Absorbs carrier/WMS clock skew. |
| `audit_carrier_code` | `UPS` | Carrier whose contract governs the audit. |

Override a variable for a run when appropriate:

```bash
dbt build --profiles-dir . --vars '{"audit_carrier_code": "UPS", "sla_grace_minutes": 30}'
```

## Data quality tests

In addition to schema tests for keys, nullability, accepted values, and relationships, the project includes custom assertions that protect the financial integrity of the audit:

- Invoice base rate + fuel + accessorials equals the invoice total
- Clean shipments reconcile to zero variance
- Anomaly codes match the anomaly count
- Shipment-level recovery equals the sum of anomaly-level recovery
- No recovery component is negative

A failing custom test returns the offending records so the source data or audit logic can be investigated.

## Design principles

- **Do not trust the invoice for evidence used to challenge the invoice.** Zones, weights, rate tiers, and SLA clocks are derived from physical and contractual data wherever possible.
- **Keep duplicate billing visible.** EDI and portal records are deliberately unioned without deduplication so cross-channel billing becomes an auditable Gate 4 signal.
- **Preserve un-invoiced shipments.** The physical shipment is the spine of the reconciliation, so missing invoices surface as `AWAITING_INVOICE` rather than disappearing.
- **Version contract truth.** Changes to seed tariffs are reviewable through Git history.
- **Recover each dollar once.** Recovery attribution is reconciled between the shipment-level and anomaly-level marts.

## Development workflow

After changing SQL, YAML, seeds, or audit variables:

```bash
dbt deps --profiles-dir .
dbt seed --profiles-dir .
dbt build --profiles-dir .
```

Review generated artifacts under `target/` locally; they are ignored by Git. Do not commit database credentials or `.env` files.

## License

No license file is currently included. Add a license before distributing or reusing this project publicly.
