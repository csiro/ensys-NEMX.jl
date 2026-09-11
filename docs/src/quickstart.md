# Quick start

Three examples, in increasing order of what they need. The first runs anywhere;
the second and third need market data (see [Market data](@ref)).

## 1. A market with no data at all

The smallest thing that prices: two generators, one region, ten-band offers.

```julia
using NEMX, DataFrames
const ZB = NEMX.ZBenchmark

# Every NEM offer carries exactly ten bands, used or not.
row(u, v) = (; unit = u, dispatch_type = "generator", service = "energy",
             (Symbol(string(i)) => (i <= length(v) ? v[i] : 0.0) for i in 1:10)...)

volumes = DataFrame([row("A", [20.0, 20.0,  5.0]),
                     row("B", [50.0, 30.0, 10.0])])
prices  = DataFrame([row("A", [50.0, 60.0, 100.0]),
                     row("B", [50.0, 55.0,  80.0])])
info    = DataFrame(unit = ["A", "B"], region = ["NSW1", "NSW1"],
                    dispatch_type = ["generator", "generator"],
                    loss_factor = [1.0, 1.0])

market = ZB.SpotMarket(market_regions = ["NSW1"], unit_info = info)
ZB.set_unit_volume_bids!(market, volumes)
ZB.set_unit_price_bids!(market, prices)
ZB.set_demand_constraints!(market, DataFrame(region = ["NSW1"], demand = [120.0]))

ZB.dispatch!(market)
```

```julia
julia> ZB.get_unit_dispatch(market)
2×4 DataFrame
 Row │ unit    dispatch_type  service  dispatch
─────┼──────────────────────────────────────────
   1 │ B       generator      energy       80.0
   2 │ A       generator      energy       40.0

julia> ZB.get_energy_prices(market)
1×2 DataFrame
 Row │ region  price
─────┼─────────────────
   1 │ NSW1       60.0
```

Cheapest first: both \$50 bands (70 MW), then B's \$55 band (30 MW), then 20 MW
of A's \$60 band. The price is the price of the band the last megawatt came
from. As a script:

```bash
julia --project=. scripts/zbenchmark/zonal_simple_example.jl
julia --project=. scripts/zbenchmark/zonal_simple_example.jl 130     # different demand
```

## 2. A real dispatch interval

With a month of AEMO data on disk, the whole assembly sequence is one call:

```julia
using NEMX, Dates
const ZB = NEMX.ZBenchmark

db     = ZB.DBManager("data/nempy_2025_09/historical_mms.db")
cache  = ZB.XMLCacheManager("data/nempy_2025_09/xml_cache")
loader = ZB.RawInputsLoader(cache, db)

ZB.set_interval!(loader, DateTime(2025, 9, 2, 12, 5))
market, inputs = ZB.dispatch_interval!(loader)

ZB.get_energy_prices(market)                 # five regional reference prices
ZB.get_regional_fcas_prices(market)          # ten FCAS services, by region
ZB.get_binding_generic_constraints(market)   # which constraints bound, and their duals
```

[`dispatch_interval!`](@ref NEMX.ZBenchmark.dispatch_interval!) runs the whole procedure: build the four input
classes, push them into the market in the order the engine requires, solve, apply
the fast-start second pass, and re-price under the over-constrained-dispatch rule
when the case file calls for it. [`build_spot_market`](@ref NEMX.ZBenchmark.build_spot_market) returns an assembled
but unsolved market if you need to intervene between the passes.

Score it against what AEMO published:

```julia
published = ZB.get_published_rops(db, DateTime(2025, 9, 2, 12, 5))
for r in eachrow(ZB.get_energy_prices(market))
    println(r.region, "  ours ", round(r.price, digits = 2),
            "   AEMO ", published[(r.region, "energy")])
end
```

Or as a sweep, with the error summary printed for you:

```bash
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl consecutive 288 2025-09-02T04:05
```

## 3. The same interval on a network

```julia
using NEMX, Dates
const NB = NEMX.NBenchmark

result = NB.solve_network_dispatch(DateTime(2025, 9, 2, 12, 5), "DCP";
                                   mfile    = "data/snem2000_fixed.m",
                                   data_dir = "data/nempy_2025_09")

result.prices          # nodal prices, and the regional reference prices
result.decomposition   # lmp = energy + congestion + loss, per region
result.binding         # the active-constraint ledger
```

The market inputs are the same objects the zonal model used. Only the network
representation changed.

Compare formulations on one interval:

```julia
NB.compare_formulations(DateTime(2025, 9, 2, 12, 5);
                        forms = ["DCP", "LPACC", "ACP"])
```

or from the command line:

```bash
julia --project=. scripts/nbenchmark/run_network_interval.jl 2025-09-02T12:05 DCP,ACP
julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 DCP
```

## What to read next

- [Market data](@ref) — how to obtain the AEMO inputs, and how big they are.
- [Prices and duals](@ref) — what the numbers coming out of these models mean,
  and the difference between a regional price and a unit's local price.
- [Behavioural flags](@ref) — every switch, its default, and why.
