# Market data

Both benchmark models read AEMO's published data. This page covers what is
needed, how much of it there is, and how to get it.

## The two sources

| Source | What it carries | Size |
|:-------|:----------------|:-----|
| **MMS data model** | Regional demand, published prices (`DISPATCHPRICE`), unit registration and loss factors, interconnector definitions and loss models, published unit targets (`DISPATCHLOAD`) and constraint outcomes (`DISPATCHCONSTRAINT`) | ~1.4 GB per month, mirrored into SQLite |
| **NEMDE case files** | The exact inputs NEMDE used for each five-minute interval: ten-band offers, FCAS trapeziums, initial conditions, ramp rates, fast-start parameters, generic constraints and their violation prices | ~1.5 GB per day |

The case files are what make an exact reconstruction possible: they are the
dispatch engine's own inputs rather than a reconstruction of them.

## Downloading

Every script that needs market data takes `--download`, which fetches what is
missing and nothing that is not:

```bash
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl random 10 --download \
      --year=2025 --month=9
```

Both downloads are idempotent. A month already mirrored is skipped; a market day
with at least 200 cached case files is treated as complete and skipped. So an
interrupted download resumes by re-running the same command, and re-running a
completed one costs a directory listing.

In Julia directly:

```julia
using NEMX, Dates
const ZB = NEMX.ZBenchmark

db    = ZB.DBManager("data/nemx_2025_09/historical_mms.db")
cache = ZB.XMLCacheManager("data/nemx_2025_09/xml_cache")

ZB.populate!(db; start_year = 2025, start_month = 9, end_year = 2025, end_month = 9,
             tables = vcat(ZB.REQUIRED_TABLES, "DISPATCHLOAD", "DISPATCHCONSTRAINT"))

ZB.populate_by_day!(cache; start_year = 2025, start_month = 9, start_day = 2,
                           end_year = 2025, end_month = 9, end_day = 3)
```

`REQUIRED_TABLES` is the small set the model actually needs — a few megabytes.
`DISPATCHLOAD` and `DISPATCHCONSTRAINT` are large and optional; add them when you
want to compare your dispatch and duals against AEMO's published ones, which the
event-study workflow does.

!!! note "Download only the days you need"
    A month of case files is 40–100 GB. `populate_by_day!` takes an explicit day
    range for exactly this reason. If you are studying one interval, download one
    day.

!!! warning "The market day is not the calendar day"
    A NEM market day runs 04:05 to 04:00. Intervals between 00:00 and 04:00 of a
    calendar day live in the *previous* day's case-file bundle, and
    `populate_by_day!` starts one day early to account for this. If you request
    an interval and the loader cannot find it, check that its market day is in
    the cache.

## Where the data lives

Nothing requires it to sit inside the package. Every script takes `--data-dir`:

```bash
julia --project=. scripts/nbenchmark/run_network_day.jl --data-dir=/mnt/bigdisk/nem/nemx_2025_09
```

To make the default paths work against a copy held elsewhere, symlink rather
than duplicate:

```bash
mkdir -p data/nemx_2025_09
ln -s /mnt/bigdisk/nem/nemx_2025_09/xml_cache         data/nemx_2025_09/xml_cache
ln -s /mnt/bigdisk/nem/nemx_2025_09/historical_mms.db data/nemx_2025_09/historical_mms.db
```

`data/` is not tracked by git — see `data/README.md` and the root `.gitignore`
for exactly what is and is not committed.

## Reading one interval

```julia
loader = ZB.RawInputsLoader(cache, db)
ZB.set_interval!(loader, DateTime(2025, 9, 2, 12, 5))

units  = ZB.UnitData(loader)            # offers, availability, ramp, FCAS
demand = ZB.DemandData(loader)          # regional operational demand
ic     = ZB.InterconnectorData(loader)  # definitions and the loss model
cons   = ZB.ConstraintData(loader)      # generic constraints, violation prices
```

Or dump the lot to CSV for inspection:

```bash
julia --project=. scripts/zbenchmark/export_interval_csvs.jl 2025-09-02T13:25
```

which is the right first step when an interval behaves unexpectedly, and what to
attach to a bug report.

## The network case

The nodal model needs a MATPOWER case with NEM side tables — `mpc.gen_data` and
`mpc.storage_data` carrying participant DUIDs, and bus `area` numbers matching
`NEMX.NBenchmark.AREA_OF_REGION`. Two are committed with the package:

| File | For |
|:-----|:----|
| `data/snem2000_fixed.m` | `NEMX.NBenchmark` — HVDC links as DC lines |
| `data/snem2000_acdc_fixed.m` | `NEMX.OPFFCAS` — HVDC links as converters |

Both are ~1.4 MB, and are inputs to the package rather than downloaded data,
which is why they are tracked.

!!! warning "The 2000-bus case is synthetic"
    It approximates the NEM's structure and is not a model of the actual
    transmission system. Nodal prices, congestion rents and loss components
    computed on it are properties of that model. They are meaningful for
    comparing formulations against one another on identical inputs — which is
    what the package is for — and are not measurements of the real network.

A six-bus fixture, `test/data/matpower/nem6_test.m`, is committed for the tests:
three regions, an AC tie, a DC link, a battery, and DUID side tables. It exists
so the network layer can be exercised in under a second.

## Data-layer API

