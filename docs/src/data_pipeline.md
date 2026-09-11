# The data pipeline

How a dispatch interval gets from AEMO's public archive into a solved
optimisation problem. This page is the reference for the two data sources, every
table and field the package reads, and the extraction stages between them.

## Overview

```
        NEMWeb (AEMO public archive)
                 |
        +--------+--------+
        |                 |
   MMS archive       NEMDE archive
   monthly ZIPs      daily ZIPs of
   of CSV tables     per-interval XML
        |                 |
        v                 v
   DBManager        XMLCacheManager
   SQLite mirror    file cache on disk
        |                 |
        +--------+--------+
                 |
          RawInputsLoader          <- positioned on ONE interval
                 |
   +-------------+-------------+-------------+
   |             |             |             |
 UnitData    DemandData  InterconnectorData ConstraintData
   |             |             |             |
   +-------------+------+------+-------------+
                        |
                   SpotMarket           <- the JuMP model
                        |
                   dispatch!
                        |
        dispatch quantities, prices, binding constraints
```

Two sources, because neither is sufficient alone.

The **MMS data model** is AEMO's relational publication of the market: regional
demand, published prices, unit registration, interconnector definitions and loss
models. It is authoritative for anything that describes the market's
*configuration*.

The **NEMDE case files** are the dispatch engine's own inputs, one XML document
per five-minute interval. They carry the ten-band offers, FCAS trapeziums,
initial conditions, ramp rates and generic constraints that NEMDE actually
solved with. They are what make an exact reconstruction possible rather than an
approximation.

## Source 1: the MMS data model

### Where it comes from

```
https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/
    {year}/MMSDM_{year}_{month}/MMSDM_Historical_Data_SQLLoader/
    DATA/PUBLIC_DVD_{TABLE}_{year}{month}010000.zip
```

One ZIP per table per month, each containing a single CSV. `DBManager` fetches
them, unpacks them, and loads the columns the model needs into SQLite.

### Why only some columns

Each table is declared with an explicit column list, and only those columns are
loaded. `PUBLIC_DVD_DISPATCHLOAD` alone is around 100 MB per month with dozens
of columns the dispatch model never reads. Naming the columns keeps the SQLite
mirror small enough to query quickly and makes the model's data dependencies
legible: if a column is not in the list, nothing in the package uses it.

### Row filtering

MMS tables are versioned in four different ways, and the loader knows which
applies to each:

| Filter | Rule | Used by |
|:-------|:-----|:--------|
| `:settlement_date` | rows where `SETTLEMENTDATE` equals the interval | per-interval outcome tables |
| `:start_end` | rows valid for the interval: `START_DATE <= t < END_DATE` | registration data with validity windows |
| `:effective_ver` | the latest `EFFECTIVEDATE`/`VERSIONNO` effective at or before the interval | versioned reference data |
| `:no_filter` | all rows; the table is static | pure reference tables |

Getting this wrong is a quiet failure rather than a loud one — a stale
`VERSIONNO` gives a plausible loss model for the wrong week — so the rule is
attached to the table definition rather than left to each caller.

### The tables

#### `DISPATCHREGIONSUM` — regional demand *(per interval)*

| Column | Meaning |
|:-------|:--------|
| `SETTLEMENTDATE` | Interval ending, the key for every per-interval table |
| `REGIONID` | `NSW1`, `QLD1`, `SA1`, `TAS1`, `VIC1` |
| `TOTALDEMAND` | Regional demand as published |
| `DEMANDFORECAST` | The forecast change over the interval |
| `INITIALSUPPLY` | Supply at the start of the interval |

Operational demand is built from `INITIALSUPPLY` and `DEMANDFORECAST` rather
than taken from `TOTALDEMAND`, because that is what the dispatch engine balances.

#### `DISPATCHPRICE` — published prices *(per interval)*

| Column | Meaning |
|:-------|:--------|
| `SETTLEMENTDATE`, `REGIONID` | Key |
| `ROP` | Regional Original Price for energy, \$/MWh |
| `RAISE6SECROP` … `LOWERREGROP` | ROP for each of the ten FCAS services, \$/MW |

**ROP, not RRP.** ROP is the price the dispatch produced, before the
administered-price and scaling rules that are applied afterwards. A dispatch
model compared against RRP is being scored on the model *plus* those rules. See
[Prices and duals](@ref).

#### `DUDETAILSUMMARY` — unit registration *(validity window)*

| Column | Meaning |
|:-------|:--------|
| `DUID` | Dispatchable unit identifier |
| `START_DATE`, `END_DATE` | Validity window for this row |
| `DISPATCHTYPE` | `GENERATOR` or `LOAD` |
| `CONNECTIONPOINTID` | Transmission connection point |
| `REGIONID` | Market region |
| `TRANSMISSIONLOSSFACTOR` | TLF |
| `DISTRIBUTIONLOSSFACTOR` | DLF |
| `SCHEDULE_TYPE` | `SCHEDULED`, `SEMI-SCHEDULED`, `NON-SCHEDULED` |
| `SECONDARY_TLF` | The TLF of a bidirectional unit's *other* side |

The combined loss factor is `TLF × DLF`. `SECONDARY_TLF` is why
[`local_prices`](@ref NEMX.ZBenchmark.local_prices) returns one row per
`(unit, dispatch_type)` and not per unit: a battery's generating and consuming
sides sit at the same connection point but carry different loss factors.

#### `DUDETAIL` — registered capacity *(versioned)*

`DUID`, `EFFECTIVEDATE`, `VERSIONNO`, `REGISTEREDCAPACITY`.

#### `INTERCONNECTOR` — topology *(static)*

`INTERCONNECTORID`, `REGIONFROM`, `REGIONTO`. Fixes the sign convention: a
positive flow runs from `REGIONFROM` to `REGIONTO`.

#### `INTERCONNECTORCONSTRAINT` — limits and loss parameters *(versioned)*

| Column | Meaning |
|:-------|:--------|
| `FROMREGIONLOSSSHARE` | Share of losses attributed to the sending region |
| `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT` | Coefficients of the loss equation |
| `ICTYPE` | `REGULATED` or `MNSP` |
| `IMPORTLIMIT`, `EXPORTLIMIT` | Static limits |

`ICTYPE` matters more than it looks. An MNSP is modelled as two directional
links with their own loss factors; a regulated interconnector is one flow
variable. Basslink was converted from MNSP to regulated during 2025, and because
the type is read from the data rather than hard-coded, the same model handles
both sides of that change.

#### `LOSSMODEL` and `LOSSFACTORMODEL` — the loss curve *(versioned)*

`LOSSMODEL` gives the MW breakpoints of the piecewise-linear loss curve
(`LOSSSEGMENT`, `MWBREAKPOINT`). `LOSSFACTORMODEL` gives the per-region demand
coefficients (`REGIONID`, `DEMANDCOEFFICIENT`) that make the curve
demand-dependent.

Reconstructing the curve from these is one of two options; the other is to read
NEMDE's own per-interval loss model out of the case file. See
`LOSS_MODEL_FROM_XML` in [Behavioural flags](@ref).

#### `MNSP_INTERCONNECTOR` — market network service providers *(versioned)*

`LINKID`, `FROMREGION`, `TOREGION`, `FROM_REGION_TLF`, `TO_REGION_TLF`,
`LHSFACTOR`, `MAXCAPACITY`. One row per directional link.

#### `DISPATCHINTERCONNECTORRES` — published flows *(per interval)*

`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`. Not an input; a cross-check. The loss
model was validated by reproducing `MWLOSSES` at the published `MWFLOW`.

#### Optional: `DISPATCHLOAD` — published unit targets *(per interval)*

Large — roughly 100 MB per month — and not in
[`REQUIRED_TABLES`](@ref NEMX.ZBenchmark.REQUIRED_TABLES), because the model
takes initial MW and SCADA ramp rates from the case file instead. Download it
when you want to compare the model's dispatch against AEMO's, which the BESS
event study does.

Key columns: `TOTALCLEARED` (the published target), `INITIALMW`, `AVAILABILITY`,
`RAMPUPRATE`, `RAMPDOWNRATE`, `SEMIDISPATCHCAP`, the FCAS enablement limits, and
the per-service actual availabilities.

#### Optional: `DISPATCHCONSTRAINT` — published constraint outcomes *(per interval)*

Also large. `CONSTRAINTID`, `RHS`, `LHS`, `MARGINALVALUE`, `VIOLATIONDEGREE`.

`MARGINALVALUE` is AEMO's own shadow price for each constraint, and it is the
strongest available check on the model's duals — the multipliers that enter the
local-price decomposition are exactly these. The BESS analysis gates on it.

### What is deliberately NOT downloaded

The MMS bid tables. In the archive they are `PUBLIC_DVD_BIDDAYOFFER`
(~160 MB/month) and `PUBLIC_DVD_BIDPEROFFER1` / `BIDPEROFFER2` (~3.5 GB **each**).

They are not needed. Every offer the model uses — the ten price and volume
bands, FCAS trapeziums, availabilities and ramp rates — is in the NEMDE case
file, at per-interval rather than per-day resolution and already in the form the
engine used. Attempting to download the bid tables is what makes a naive input
download appear to hang.

## Source 2: the NEMDE case files

### Where they come from

```
https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/NEMDE/
    {year}/NEMDE_{year}_{month}/NEMDE_Market_Data/NEMDE_Files/
    NemSpdOutputs_{year}{month}{day}_loaded.zip
```

One ZIP per calendar day, holding one XML document per five-minute interval,
named `NEMSPDOutputs_{YYYYMMDD}{NNN}00.loaded` where `NNN` is the three-digit
interval number within the market day.

`XMLCacheManager` downloads a day's ZIP, unpacks it into the cache directory,
and thereafter reads files straight off disk. A day with at least 200 cached
files is treated as complete and skipped, so re-running a download costs a
directory listing.

!!! warning "The market day is not the calendar day"
    A NEM market day runs 04:05 to 04:00. Intervals between 00:00 and 04:00 of a
    calendar day live in the **previous** day's ZIP, and
    [`populate_by_day!`](@ref NEMX.ZBenchmark.populate_by_day!) starts one day
    early to account for it. If the loader cannot find an interval, check that
    its market day is in the cache rather than its calendar day.

### Size

Roughly 1.5 GB per day unpacked. A month is 40–100 GB. Download the days you
need, not the month.

### Structure

The parts the package reads, as paths under the document root:

```
NEMSubmission/
└── NemSpdInputs/
    ├── PeriodCollection/Period/
    │   └── TraderPeriodCollection/
    │       └── TraderPeriod[@TraderID]/
    │           └── TradeCollection/
    │               └── Trade[@TradeType, @PriceBand1..10, @BandAvail1..10,
    │                         @MaxAvail, @EnablementMin, @EnablementMax,
    │                         @LowBreakpoint, @HighBreakpoint,
    │                         @RampUpRate, @RampDnRate]
    ├── TraderCollection/
    │   └── Trader/TraderInitialConditionCollection/
    │       └── TraderInitialCondition[@InitialConditionID]
    ├── GenericConstraintCollection/
    │   └── GenericConstraint[@ConstraintID, @Type, @ViolationPrice]
    │       ├── LHSFactorCollection/{TraderFactor, InterconnectorFactor, RegionFactor}
    │       └── ...
    └── InterconnectorCollection/Interconnector/LossModelCollection/
        └── LossModel/SegmentCollection/Segment[@Limit, @Factor]
```

#### `Trade` — one offer, for one unit, for one service

`@TradeType` selects the service:

| Code | Service | Code | Service |
|:-----|:--------|:-----|:--------|
| `ENOF` | energy, generator | `R5RE` | raise regulation |
| `LDOF` | energy, scheduled load | `L5RE` | lower regulation |
| `BDOF` | energy, bidirectional unit | `R1SE` | raise 1 s |
| `DROF` | wholesale demand response | `L1SE` | lower 1 s |
| `R6SE` / `L6SE` | raise / lower 6 s | `R60S` / `L60S` | raise / lower 60 s |
| `R5MI` / `L5MI` | raise / lower 5 min | | |

Each `Trade` carries ten `@PriceBand` and ten `@BandAvail` attributes — the
offer stack — plus, for an FCAS trade, the four trapezium parameters
(`@EnablementMin`, `@LowBreakpoint`, `@HighBreakpoint`, `@EnablementMax`) and
`@MaxAvail`.

#### `TraderInitialCondition` — the unit's state entering the interval

`@InitialConditionID` selects the quantity: `INITIALMW`, `SCADARAMPUPRATE`,
`SCADARAMPDNRATE`, the fast-start mode and time-in-mode, and the AGC status.

#### `GenericConstraint` — the SPD constraint set

Each carries its `@Type` (`LE`, `GE`, `EQ`), its right-hand side, its
`@ViolationPrice`, and a left-hand side built from three kinds of factor:

| Factor | Attaches to | Used for |
|:-------|:------------|:---------|
| `TraderFactor` | a unit and a service | unit terms in network and FCAS constraints |
| `InterconnectorFactor` | an interconnector | flow terms |
| `RegionFactor` | a region and a service | regional FCAS requirements |

`RegionFactor` is why regional FCAS prices are recovered as factor-weighted sums
of constraint duals rather than as duals of dedicated requirement constraints:
there are no dedicated requirement constraints. See [Prices and duals](@ref).

#### Violation prices

Read per interval from the case file rather than assumed. The constraint
violation price hierarchy decides which constraint the dispatch breaks first
when it cannot satisfy them all, and it is a property of the interval.
`CVP_FACTORS` in `NEMX.ZBenchmark` holds fallbacks used only when a case file is
unavailable.

## Extraction

### Stage 1 — acquire

```julia
using NEMX, Dates
const ZB = NEMX.ZBenchmark

db    = ZB.DBManager("data/nempy_2025_09/historical_mms.db")
cache = ZB.XMLCacheManager("data/nempy_2025_09/xml_cache")

ZB.populate!(db; start_year = 2025, start_month = 9,
             end_year = 2025, end_month = 9,
             tables = vcat(ZB.REQUIRED_TABLES, "DISPATCHLOAD", "DISPATCHCONSTRAINT"))

ZB.populate_by_day!(cache; start_year = 2025, start_month = 9, start_day = 2,
                           end_year = 2025, end_month = 9, end_day = 3)
```

Both are idempotent. From a script, `--download` does the same.

### Stage 2 — position on an interval

```julia
loader = ZB.RawInputsLoader(cache, db)
ZB.set_interval!(loader, DateTime(2025, 9, 2, 12, 5))
```

`RawInputsLoader` holds both sources and a cursor. `set_interval!` parses that
interval's XML document and remembers the timestamp; the MMS side is queried
lazily, with the right filter rule per table.

### Stage 3 — build the input classes

| Class | Reads | Produces |
|:------|:------|:---------|
| `UnitData` | case-file trades and initial conditions, `DUDETAILSUMMARY`, `DUDETAIL` | offer stacks, availabilities, ramp rates, FCAS trapeziums, fast-start profiles, unit info |
| `DemandData` | `DISPATCHREGIONSUM` | regional operational demand |
| `InterconnectorData` | `INTERCONNECTOR`, `INTERCONNECTORCONSTRAINT`, `MNSP_INTERCONNECTOR`, `LOSSMODEL`, `LOSSFACTORMODEL`, or the case file | definitions and the loss model |
| `ConstraintData` | case-file generic constraints and violation prices | the constraint set, its LHS factors, and the CVPs |

Three transformations inside `UnitData` are worth knowing about, because each
would be invisible in the output if it were wrong:

**Loss-factor scaling.** Case-file energy prices are pre-referred to the
regional reference node. Ingestion multiplies by the combined loss factor to
restore connection-point prices; the objective divides by the same factor to
refer them back. The round trip is exact and is what makes the objective a
reference-node objective. `XML_PRICES_PRESCALED` governs the first half.

**FCAS trapezium construction.** `add_fcas_trapezium_constraints!` turns the
four breakpoints into the enablement constraints, and applies the preconditions
that decide whether a unit may be enabled for a service at all. It **mutates**
`UnitData`, so every FCAS getter must be called after it — which is why
[`build_spot_market`](@ref NEMX.ZBenchmark.build_spot_market) exists rather than
each script open-coding the order.

**Ramp-rate reconciliation.** The effective rate is the lesser of the bid rate
and the SCADA rate, in MW/h, over a window of `rate × 5/60`. A bidirectional
unit's composite rate spans both directions.

### Stage 4 — assemble and solve

```julia
market, inputs = ZB.dispatch_interval!(loader)
```

See [Zonal benchmarking](@ref) for what that does, pass by pass.

### Inspecting the extraction

```bash
julia --project=. scripts/zbenchmark/export_interval_csvs.jl 2025-09-02T13:25
```

writes every extracted input for one interval to CSV. This is the first thing to
run when an interval behaves unexpectedly, and what to attach to a bug report.

## Storage

| Item | Size | Committed? |
|:-----|:-----|:-----------|
| MMS SQLite mirror | ~1.4 GB per month | no |
| NEMDE case-file cache | 10–105 GB per month | no |
| Model output CSVs | ~200 MB per study | no |
| Network cases (`.m`) | 1.4 MB each | yes |

Nothing needs to live inside the package: every script takes `--data-dir`, and a
copy held elsewhere can be symlinked. See `data/README.md`.

## Provenance and reuse

All market data is AEMO's, published through NEMWeb. Cite AEMO as the source of
any market data underlying a result, and state the period — the archive is
revised, so a result is reproducible only against a stated vintage.

The synthetic 2000-bus network is not AEMO data and is not a model of the actual
transmission system; see the warning in [Market data](@ref).
