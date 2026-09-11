# Zonal benchmarking

The workflow for reconstructing AEMO's regional dispatch and measuring how
closely it reproduces published prices.

## The pipeline

```
NEMWeb  ──►  MMS mirror (SQLite)  ──┐
                                    ├──►  RawInputsLoader  ──►  input classes
NEMWeb  ──►  NEMDE case cache     ──┘         set_interval!       UnitData
                                                                  DemandData
                                                                  InterconnectorData
                                                                  ConstraintData
                                                                        │
                                                   build_spot_market ───┤
                                                                        ▼
                                                                   SpotMarket
                                                                        │
                                                       dispatch! ───────┤
                                                                        ▼
                                              dispatch, prices, binding constraints
```

## One interval

```julia
using NEMX, Dates
const ZB = NEMX.ZBenchmark

db     = ZB.DBManager("data/nempy_2025_09/historical_mms.db")
cache  = ZB.XMLCacheManager("data/nempy_2025_09/xml_cache")
loader = ZB.RawInputsLoader(cache, db)

ZB.set_interval!(loader, DateTime(2025, 9, 2, 12, 5))
market, inputs = ZB.dispatch_interval!(loader)
```

### What `dispatch_interval!` actually does

Worth knowing, because the order is not arbitrary and because the two-pass
structure surprises people.

1. Build the four input classes and read the violation prices.
2. Push offers, capability, FCAS and network constraints into the market. Order
   matters here: `add_fcas_trapezium_constraints!` mutates `UnitData` in place
   and must precede every FCAS getter, and ramp constraints must be set before
   the joint-ramping constraints that reuse the same SCADA rates.
3. **Solve once**, without fast-start units held to their inflexibility profiles.
4. Use that solve to classify each fast-start unit's end mode, re-impose the
   ramp and joint-ramping constraints under `"fast_start_second_run"`, and
   **solve again**. A single-pass solve is not benchmark-valid for any interval
   with a starting fast-start unit.
5. If the case file's own flag calls for it, re-price under the
   over-constrained-dispatch rule: relax each violated constraint's right-hand
   side by its violation plus a cent and re-price, with no clamping.

`build_spot_market` stops after step 2 if you need to intervene.

## A sweep

```bash
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl consecutive 288 2025-09-02T04:05
```

writes two CSVs and prints an error summary by service. Use `random` mode for an
unbiased error estimate over a month and `consecutive` when the sequence matters
— ramping, storage state, an event study.

```bash
# Ten pseudo-random intervals from a month, downloading what is missing
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl random 10 --download --year=2025 --month=9
```

## Reading the results

`zonal_prices_<tag>.csv` carries one row per `(interval, region, service)` with
the modelled price, AEMO's ROP, the error, and `n_terms`.

Two things to keep in mind when interpreting it.

**Score against ROP, not RRP.** ROP is the price before the administered-price
and scaling rules applied after dispatch. Comparing against RRP measures the
model plus those rules.

**Score the Queensland lower 6 s / 60 s pair jointly.** Their constraints are
structurally identical, so the problem pins only the sum of their duals. The
script prints both the separate and the joint error; a large separate error next
to a near-zero joint one is the signature of the non-identifiable split, not a
defect. See [Prices and duals](@ref).

## Figures

```bash
julia --project=. scripts/zbenchmark/plot_zonal_benchmark.jl
```

Out-of-scale points are marked at the frame edge rather than deleted, and a
missing interval appears as a gap rather than being interpolated across.

## The MLF-scaled variant

One special run exists for the nodal comparison:

```bash
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl consecutive 288 2025-09-02T04:05 \
      --keep-mlf-scaling --tag=2025_09_mlf
```

This leaves the offer stack scaled by the marginal loss factor instead of
referring it back to the reference node, matching the convention the nodal
formulations use. It exists so that a nodal-versus-zonal comparison is not
conflating a change in network model with a change in offer convention. It is
**not** the benchmark; the default is.

## Common problems

**"No such interval"** — the interval's *market* day (04:05 to 04:00) is not in
the cache. Download the day before the calendar day you want.

**Prices that are exactly the market cap across every region** — a constraint has
been violated and the energy-deficit valve has priced. Look at
`get_binding_generic_constraints(market)` for a dual at the violation price.

**A slow interval** — the loss-adjacency tightening has gone to a MIP. It is
bounded by `LOSS_TIGHTEN_TIME_LIMIT`; if the bound is hit the model falls back to
the LP relaxation and still returns valid duals.
