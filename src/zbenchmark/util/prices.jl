# =============================================================================
# prices.jl
#
# Price recovery and comparison helpers that every driver needed and each one
# had reimplemented: regional FCAS prices out of the solved LP, AEMO's published
# reference prices out of the MMS mirror, and the local (connection-point) price
# of an individual unit.
#
# None of these belongs in a script. They are the quantities the benchmark is
# scored on, so they are defined once, here, and tested.
# =============================================================================

"""
    DEFAULT_REGIONS

The five NEM market regions, in the order used throughout the package.
"""
const DEFAULT_REGIONS = ["QLD1", "NSW1", "VIC1", "SA1", "TAS1"]

"""
    SERVICE_ROP_COL

Map from this package's service names to the corresponding `DISPATCHPRICE`
column holding AEMO's published *ROP* — the "original" regional price, before
any post-dispatch scaling or capping. ROP is the correct comparison target for
a dispatch reconstruction: RRP has had administered-price and scaling rules
applied to it that are outside the dispatch problem.
"""
const SERVICE_ROP_COL = [
    "energy"     => :ROP,
    "raise_reg"  => :RAISEREGROP,
    "raise_6s"   => :RAISE6SECROP,
    "raise_60s"  => :RAISE60SECROP,
    "raise_5min" => :RAISE5MINROP,
    "raise_1s"   => :RAISE1SECROP,
    "lower_reg"  => :LOWERREGROP,
    "lower_6s"   => :LOWER6SECROP,
    "lower_60s"  => :LOWER60SECROP,
    "lower_5min" => :LOWER5MINROP,
    "lower_1s"   => :LOWER1SECROP,
]

"""
    as_float(x) -> Float64

Coerce a value read out of a CSV, SQLite column or DataFrame cell to `Float64`,
returning `NaN` for `missing` and for anything unparseable.

MMS tables are typed inconsistently between vintages — the same column arrives
as `Int`, `Float64`, `String` or `missing` depending on the month — so every
numeric read from published data goes through this rather than `float()`.
"""
as_float(x) = x isa Number ? float(x) :
              (x === missing ? NaN :
               (v = tryparse(Float64, string(x)); v === nothing ? NaN : v))

"""
    column_or_nan(row, name::Symbol) -> Float64

Read column `name` from a `DataFrameRow`, or `NaN` if the column is absent.

A `DataFrameRow` supports neither `get(row, :col, default)` nor indexing by a
missing column, and MMS schemas vary between vintages, so every published-data
read goes through this.
"""
column_or_nan(row, name::Symbol) =
    hasproperty(row, name) ? as_float(getproperty(row, name)) : NaN

"""
    get_regional_fcas_prices(market::SpotMarket)
        -> Dict{Tuple{String,String},Tuple{Float64,Int}}

Regional marginal FCAS prices (`\$/MW`) recovered from the solved LP, keyed by
`(region, service)`.

Regional FCAS requirements are not separate objects in this model: they are SPD
generic constraints whose left-hand side carries `RegionFactor` terms, one per
`(region, service)`. By LP duality the marginal value of one more MW of a
region's requirement for a service is

    price(region, service) = Σ over constraints  factor × constraint dual

which is the same rule that makes a regional energy price the dual of that
region's demand constraint.

# Returns
For each `(region, service)`, a tuple of the price and the number of constraint
terms that contributed to it. The count matters: it distinguishes a price of
`0.0` because nothing bound from a price of `0.0` because the model carries no
requirement for that pair at all.
"""
function get_regional_fcas_prices(market::SpotMarket)
    out = Dict{Tuple{String,String},Tuple{Float64,Int}}()
    lhs = market.generic_region_lhs
    (lhs === nothing || isempty(lhs)) && return out

    binding = get_binding_generic_constraints(market)
    isempty(binding) && return out
    duals = Dict(string(r.set) => r.dual for r in eachrow(binding))

    for r in eachrow(lhs)
        d = get(duals, string(r.set), NaN)
        isfinite(d) || continue
        f = as_float(r.factor)
        (isfinite(f) && f != 0) || continue
        key = (string(r.region), string(r.service))
        price, n = get(out, key, (0.0, 0))
        out[key] = (price + f * d, n + 1)
    end
    return out
end

"""
    get_published_rops(db::DBManager, interval::DateTime)
        -> Dict{Tuple{String,String},Float64}

AEMO's published ROP for every `(region, service)` in one dispatch interval,
read from the `DISPATCHPRICE` table of the MMS mirror.

Returns an empty dictionary if the table is absent or holds no row for the
interval, so a caller sweeping a series can score the intervals it has without
special-casing gaps.
"""
function get_published_rops(db::DBManager, interval::DateTime)
    rop = Dict{Tuple{String,String},Float64}()
    published = try
        get_table(db, "DISPATCHPRICE"; interval = interval)
    catch
        return rop
    end
    isempty(published) && return rop
    for r in eachrow(published), (service, col) in SERVICE_ROP_COL
        hasproperty(r, col) || continue
        v = as_float(r[col])
        isfinite(v) && (rop[(string(r.REGIONID), service)] = v)
    end
    return rop
end

"""
    unit_constraint_terms(market::SpotMarket)
        -> (contributions, binding)

Per-unit shadow-price terms of the local price.

`contributions[unit]` is a vector of `(set, factor, dual, factor * dual)`, one
entry per generic constraint carrying an **energy** factor for that unit with a
non-zero dual. Only energy factors enter: an FCAS factor prices reserve, not the
energy a unit is dispatched to produce or consume. `binding[set]` records
whether the constraint was actually binding, so a real contribution can be told
apart from a residual dual on a slack constraint.
"""
function unit_constraint_terms(market::SpotMarket)
    unit_lhs = market.generic_unit_lhs
    gc = get_binding_generic_constraints(market)
    duals = isempty(gc) ? Dict{String,Float64}() :
            Dict(string(r.set) => as_float(r.dual) for r in eachrow(gc))
    binding = isempty(gc) ? Dict{String,Bool}() :
              Dict(string(r.set) => Bool(r.binds) for r in eachrow(gc))

    contributions = Dict{String,Vector{Tuple{String,Float64,Float64,Float64}}}()
    (unit_lhs === nothing || isempty(unit_lhs)) && return contributions, binding

    for r in eachrow(unit_lhs)
        string(r.service) == "energy" || continue
        f = as_float(r.factor)
        (isfinite(f) && f != 0) || continue
        set = string(r.set)
        d = get(duals, set, NaN)
        (isfinite(d) && d != 0) || continue
        push!(get!(contributions, string(r.unit),
                   Tuple{String,Float64,Float64,Float64}[]), (set, f, d, f * d))
    end
    return contributions, binding
end

"""
    local_prices(market::SpotMarket, unit_info::DataFrame) -> DataFrame

The local (connection-point) energy price of every unit, with the
shadow-price adjustment that produced it.

A participant is *settled* at its region's reference price but *dispatched*
against its local price. Writing the Lagrangian of the dispatch LP, an interior
offer band of unit `u` prices at

    π_u = λ_r(u) + Σ_c f_uc μ_c

where `λ_r` is the regional demand-constraint dual, `f_uc` the unit's factor in
generic constraint `c`, and `μ_c` that constraint's dual. The identity holds for
generation and load bands alike — the direction's sign is carried inside the LP,
in the `-1` with which load energy enters both the regional balance and the
constraint left-hand sides, not in the price.

The engine's objective is written in **reference-node** dollars (it divides the
connection-point bid stack by the unit's loss factor), so `π_u` as computed
above is a reference-node price; multiplying by the loss factor puts it at the
connection point, which is the basis on which offers are submitted.

# Arguments
- `market`: a solved `SpotMarket`.
- `unit_info`: the frame returned by [`get_unit_info`](@ref), which supplies each
  unit-direction's region and loss factor.

# Returns
One row per `(unit, dispatch_type)` — not per unit. A bidirectional unit's two
sides share a reference-node local price but carry *different* loss factors (the
generator side takes `SECONDARY_TLF`), so collapsing the directions would quote
a charging battery's price on its discharging loss factor.

Columns: `unit`, `dispatch_type`, `region`, `loss_factor`, `rrp`, `adjustment`,
`local_price_ref`, `local_price_cp`, `n_constraint_terms`, `n_binding`, and the
single largest contributing term as `top_set`, `top_factor`, `top_dual`,
`top_contribution`.
"""
function local_prices(market::SpotMarket, unit_info::DataFrame)
    contributions, binding = unit_constraint_terms(market)
    rrp = Dict{String,Float64}()
    for r in eachrow(get_energy_prices(market))
        isfinite(r.price) && (rrp[string(r.region)] = float(r.price))
    end

    rows = NamedTuple[]
    seen = Set{Tuple{String,String}}()
    for r in eachrow(unit_info)
        unit = string(r.unit)
        dt = hasproperty(r, :dispatch_type) ? string(r.dispatch_type) : "generator"
        (unit, dt) in seen && continue
        push!(seen, (unit, dt))

        region = string(r.region)
        λ = as_float(r.loss_factor)
        reference = get(rrp, region, NaN)
        terms = get(contributions, unit, Tuple{String,Float64,Float64,Float64}[])
        adjustment = isempty(terms) ? 0.0 : sum(t[4] for t in terms)
        n_binding = count(t -> get(binding, t[1], false), terms)
        top = isempty(terms) ? ("", NaN, NaN, 0.0) :
              terms[argmax([abs(t[4]) for t in terms])]
        ref_price = reference + adjustment

        push!(rows, (unit = unit, dispatch_type = dt, region = region,
                     loss_factor = λ, rrp = reference, adjustment = adjustment,
                     local_price_ref = ref_price, local_price_cp = ref_price * λ,
                     n_constraint_terms = length(terms), n_binding = n_binding,
                     top_set = String(top[1]), top_factor = as_float(top[2]),
                     top_dual = as_float(top[3]),
                     top_contribution = as_float(top[4])))
    end
    return DataFrame(rows)
end
