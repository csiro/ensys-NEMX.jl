# =============================================================================
# bids.jl
#
# Offer-stack helpers, generic-constraint classification, marginal-loss-factor
# bound scaling, and the CVP-priced regional balance slack.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================


# ---------------------------------------------------------------------------
# Market overlay on the PowerModels model
# ---------------------------------------------------------------------------
function _band_vols(row) Float64[coalesce(row[c], 0.0) for c in BAND_COLS] end

"""
    classify_generic(id) -> String

Classify an AEMO generic constraint by its ID, following AEMO's Constraint
Naming Guidelines. Classes:
  "thermal"    — contains '>' : avoid overloading element A on trip of B (line
                 ratings; the class a physical network model REPLACES);
  "voltage"    — contains '^' : voltage-stability limits;
  "transient"  — contains '-' after the region prefix or '*' : transient /
                 oscillatory stability;
  "unit_cap"   — starts with '#' : unit-specific caps (semi-dispatch caps,
                 runbacks) — KEEP, these act on units not the grid;
  "fcas"       — starts with F_ or D_ : FCAS requirement / regulation
                 procurement — KEEP (co-optimisation needs them);
  "other"      — discretionary ('\$'), non-conformance, ratings w/o marker.
"""
function classify_generic(id::AbstractString)
    startswith(id, "#") && return "unit_cap"
    (startswith(id, "F_") || startswith(id, "D_") || startswith(id, "F@")) && return "fcas"
    occursin(">", id) && return "thermal"
    occursin("^", id) && return "voltage"
    startswith(id, raw"$") && return "other"
    m = match(r"^[A-Z]+([>^*+-])", id)
    m !== nothing && m.captures[1] == "-" && return "transient"
    occursin("*", id) && return "transient"
    return "other"
end

"""
    _scale_gen_bounds_for_mlf!(data, mapping, mkt) -> Int

Put the network-side generator bounds into the same units as the variable they
bound, when DCP_MLF is in force.

`map_participants!` writes `pmin`/`pmax` in MARKET MW - the unit's bid envelope
and, when `hard_down=true`, its hard down-ramp floor `init - dn*5/60`. Under
DCP_MLF the linkage constraint is `pg * base == gamma * E` (A8 layer (ii)), so
the variable those bounds sit on is no longer `E` but `gamma * E`. Left
unscaled they therefore assert `E >= pmin/gamma` - with a typical `gamma` near
0.9 that inflates the down-ramp FLOOR by about 11%, and a unit whose floor is
already close to its up-ramp ceiling then has an empty feasible interval.

This was the entire DCP_MLF failure on 2025-09-02: 41 INFEASIBLE intervals in
two blocks (06:10-08:15, 20:10-21:05), i.e. exactly the morning and evening
peaks, when the fleet is most tightly ramp-bound. Plain DCP (`gamma == 1`) was
unaffected and solved all 288.

Scaling both bounds by `gamma` restores the intended meaning: the network-side
interval becomes `gamma * [pmin, pmax]`, which is precisely the image of the
market-MW interval under the linkage.
"""
function _scale_gen_bounds_for_mlf!(data::Dict, mapping, mkt)
    gammas = Dict((string(r.unit), string(r.dispatch_type)) => float(r.loss_factor)
                  for r in eachrow(mkt.unit_info))
    n = 0
    for r in eachrow(mapping)
        # Loads are excluded from the MLF linkage (see build_market_opf), so
        # their bounds are already in the right units.
        string(r.dispatch_type) == "generator" || continue
        g = get(data["gen"], string(r.gen_id), nothing)
        g === nothing && continue
        gamma = get(gammas, (string(r.unit), "generator"), 1.0)
        (gamma > 0 && gamma != 1.0) || continue
        g["pmin"] *= gamma
        g["pmax"] *= gamma
        n += 1
    end
    return n
end

"""
    BALANCE_SLACK_ENABLED

Ablation control for `_add_balance_slack!`. `true` (default) is the shipped
behaviour; `false` restores the hard bus power balance so the effect of the
slack on solver convergence can be measured rather than asserted.

Interior-point methods need a strictly feasible direction to work in. With the
balance held as a hard equality at every bus, Ipopt has none, and on the
tightest intervals its restoration phase fails outright -- returning a status
with duals that are not prices at all. The slack repairs that WITHOUT being
used: it is zero in the converged solution on every interval tested, so it
changes the search, not the answer.
"""
const BALANCE_SLACK_ENABLED = Ref(true)

"""
    _add_balance_slack!(data, mapping; cvp) -> Vector{NamedTuple}

Give the nodal power balance the same violation-priced escape valve that every
market constraint already has.

`PM.constraint_power_balance` is a HARD equality. Every other constraint in this
model carries a CVP slack, so a binding market limit produces a priced violation
and a solution; a real-power shortfall instead produced `INFEASIBLE` and no
prices at all. That is both unlike NEMDE - which prices a regional energy
deficit at `EnergyDeficitPrice` rather than failing - and actively harmful to
the AC formulations, whose interior-point solves need a non-empty feasible
region to work in.

Measured on the 2025-09-02 trading day, this was the whole of the DCP_MLF
failure: 41 intervals INFEASIBLE, in two contiguous blocks (06:10-08:15 and
20:10-21:05) that are exactly the morning and evening demand peaks. DCP solved
all 288. The mechanism is A8 layer (ii): DCP_MLF scales each generator's
injection to `gamma * E` with `gamma < 1`, which removes `(1-gamma) * sum(E)`
of injection while the bus loads stay fixed, so at peak the fleet simply cannot
cover the load and the equality has no solution.

The slack is placed at the REGIONAL REFERENCE NODES rather than at every bus,
which mirrors NEMDE (whose energy-deficit violation is regional, not nodal) and
costs ten variables instead of several thousand - material for a 2000-bus NLP.
Two one-sided dummy generators per region keep the penalty LINEAR: an injecting
gen prices a deficit, an absorbing gen prices a surplus. They are added AFTER
`map_participants!` so they can never collide with a mapped market unit, and
they are excluded from the loss accounting downstream.
"""

function _add_balance_slack!(data::Dict, mapping; verbose::Bool=false)
    BALANCE_SLACK_ENABLED[] || return NamedTuple[]
    rrn = Dict{String,Int}()
    for sub in groupby(mapping, :region)
        gens = sub[sub.dispatch_type .== "generator", :]
        isempty(gens) && continue
        rrn[string(first(sub.region))] = gens.bus[argmax(gens.cap_mw)]
    end
    isempty(rrn) && return NamedTuple[]
    nextid = maximum(parse(Int, k) for k in keys(data["gen"]); init=0)
    M = 100.0                      # p.u. on baseMVA=100 -> 10 GW each way
    out = NamedTuple[]
    for (region, bus) in sort(collect(rrn))
        for (dir, pmin, pmax) in (("deficit", 0.0, M), ("surplus", -M, 0.0))
            nextid += 1
            gid = string(nextid)
            data["gen"][gid] = Dict{String,Any}(
                "gen_bus" => bus, "index" => nextid, "gen_status" => 1,
                "pg" => 0.0, "qg" => 0.0,
                "pmin" => pmin, "pmax" => pmax,
                # Reactive output is pinned to zero: this valve exists to price
                # a REAL-power shortfall. Free reactive support at a reference
                # node would quietly repair genuine voltage/reactive
                # infeasibility in the AC formulations and hide it from the
                # status report, which is the opposite of what it is for.
                "qmin" => 0.0, "qmax" => 0.0,
                "vg" => 1.0, "mbase" => data["baseMVA"],
                "cost" => Float64[], "ncost" => 0, "model" => 2,
                "source_id" => Any["balance_slack", region, dir])
            push!(out, (region=region, bus=bus, gen_id=gid, dir=dir))
        end
    end
    verbose && @info "balance slack added at $(length(rrn)) reference nodes"
    return out
end
