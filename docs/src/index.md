# NEMX.jl

Market dispatch and network-constrained optimal power flow for the Australian
National Electricity Market.

NEMX does three things, which share a data layer and a set of conventions but
are useful separately.

It **reconstructs** AEMO's five-minute regional dispatch from published data,
closely enough to reproduce its prices. It **lifts** the identical market inputs
onto a physical network model and re-solves them as an optimal power flow, across
the whole PowerModels formulation family. And it **models** AC/DC optimal power
flow with co-optimised frequency control ancillary services.

The second of those is the reason the package exists. A zonal market model and a
nodal one usually differ in two ways at once — the network representation *and*
the market data — which makes any difference between their prices
uninterpretable. Here the market inputs are held byte-identical and only the
network representation varies, so a difference in price is attributable to that
change and to nothing else.

## Where to start

| If you want to | Read |
|:---------------|:-----|
| Install and run something immediately | [Installation](@ref) then [Quick start](@ref) |
| Understand how the pieces fit together | [Architecture](@ref) |
| Reproduce AEMO's published prices | [Zonal benchmarking](@ref) |
| Get nodal prices and a congestion decomposition | [Network-resolved dispatch](@ref) |
| Co-optimise energy and FCAS on an AC/DC network | [OPF with FCAS](@ref) |
| Know what a switch does before you flip it | [Behavioural flags](@ref) |
| Run something from the command line | [Scripts](@ref) |

## The three submodules

```@docs
NEMX
```

| Submodule | Folder | Role |
|:----------|:-------|:-----|
| `NEMX.ZBenchmark` | `src/zbenchmark/` | Zonal (copper-plate) dispatch reconstruction |
| `NEMX.NBenchmark` | `src/nbenchmark/` | Network-resolved nodal dispatch |
| `NEMX.OPFFCAS` | `src/opffcas/` | AC/DC OPF with FCAS co-optimisation |

They are separate modules rather than one flat namespace so that a name defined
for one cannot silently collide with a name defined for another. Nothing stops
you bringing a submodule's exports into scope:

```julia
using NEMX.ZBenchmark      # dispatch!, get_energy_prices, ... unqualified
```

## Design commitments

These are the rules the package holds itself to. They are worth stating because
they constrain what it will do, not only what it can.

**Defaults reproduce the validated configuration.** Every behavioural switch is
a module-level `Ref` whose default is the setting that reproduces published
prices. Nothing in the package changes one implicitly. A result is therefore
reproducible from the flag values recorded beside it, and scripts print their
whole configuration before doing any work.

**A quantity that is not identifiable is reported as such.** The Queensland
lower 6 s and 60 s FCAS prices are the standing example: their constraints are
structurally identical, so the dispatch pins only the sum of their duals and the
split between them is an artefact of which vertex the solver stopped at. The
benchmark scores the sum and says why.

**Nothing is dropped to make a result look better.** The plotting scripts mark
out-of-scale points at the frame edge rather than deleting them, and show a
non-converged interval as a gap rather than interpolating across it.

**No licensed solver is required.** HiGHS, Ipopt and SCS cover everything.

## Scope and limits

The synthetic 2000-bus network shipped with the package approximates the NEM's
structure and is not a model of the actual transmission system. Quantities
computed on it — nodal prices, congestion rents, loss components — are
properties of that model. They are useful for comparing formulations against
each other on identical inputs, which is what the package is for; they are not
measurements of the real network.

## Acknowledgements

The zonal reconstruction follows the modelling approach of
[nempy](https://github.com/UNSW-CEEM/nempy). The network layer is built on
[PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl) and
[PowerModelsACDC.jl](https://github.com/Electa-Git/PowerModelsACDC.jl). Market
data is AEMO's, published through NEMWeb.
