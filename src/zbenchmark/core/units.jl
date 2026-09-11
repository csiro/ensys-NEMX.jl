# =============================================================================
# units.jl
#
# Julia port of `nempy.historical_inputs.units.UnitData`.
#
# UnitData reads the NEMDE XML <Trade> elements (and MMS DUDETAILSUMMARY /
# DISPATCHLOAD for metadata and AGC limits) and turns them into the tidy tables
# the market model consumes. Everything is keyed by (unit, dispatch_type) so
# BIDIRECTIONAL units (BDUs — batteries bidding both a generation and a load
# side under ONE DUID) are handled like nempy handles them.
#
# get_processed_bids replicates nempy's full FCAS preprocessing pipeline:
#   1. _scaling_for_agc_enablement_limits  (AGC telemetered enablement limits)
#   2. _scaling_for_agc_ramp_rates         (SCADA ramp rates cap reg FCAS)
#   3. _scaling_for_uigf                   (UIGF caps semi-scheduled FCAS)
#   4. _enforce_preconditions_for_enabling_fcas (AEMO FCAS verification rules)
#
# NEMDE <Trade> attributes used (per service / TradeType):
#   @BandAvail1..10   MW offered into each of the 10 bands  (volume bids)
#   @PriceBand1..10   $/MWh price of each of the 10 bands   (price bids)
#   @MaxAvail         maximum availability (MW)
#   @EnablementMin/@EnablementMax/@LowBreakpoint/@HighBreakpoint  FCAS trapezium
#   @RampUpRate/@RampDnRate   bid ramp rates (MW/h — same convention as nempy)
#   @Direction        GEN/LOAD for bidirectional units' trades
# =============================================================================

# The ten band column names, defined once (NEM bids always have 10 bands).
const N_BANDS = 10
const BAND_COLS = string.(1:N_BANDS)

# Epoch flag: whether NEMDE XML energy price bands are pre-scaled by loss
# factors (true = 2024-and-earlier convention; set false for 2025+ if prices
# come through as connection-point terms). Toggle per run:
#   nemjl.XML_PRICES_PRESCALED[] = false
const XML_PRICES_PRESCALED = Ref(true)

# Use the NEMDE XML trader HMW/LMW initial conditions as the AGC enablement
# window for regulation FCAS where MMS DISPATCHLOAD has no entry. Defaults to
# TRUE (strictly a superset: DISPATCHLOAD still wins wherever it has data, so
# the 2024 benchmark is unaffected). Set false to restore DISPATCHLOAD-only.
const AGC_ENABLEMENT_FROM_XML = Ref(true)

"""
    UnitData(loader::RawInputsLoader)

Parse all per-unit inputs for the loader's current interval. Construction does
the XML parsing once; the `get_*` accessors then return tidy `DataFrame`s.
Mirrors nempy's `units.UnitData`.
"""
mutable struct UnitData
    loader::RawInputsLoader
    bids::DataFrame            # long: one row per (unit, dispatch_type, service)
    info::DataFrame            # unit, dispatch_type, region, loss_factor
    initial::DataFrame         # NEMDE initial conditions (+ AGC status, trader type)
    uigf::DataFrame            # unit, capacity (semi-scheduled forecast caps)
    fast_start::DataFrame      # fast-start inflexibility parameters
    processed::Union{Nothing,DataFrame}   # bids after FCAS preprocessing
    trapeziums::Union{Nothing,DataFrame}  # built by add_fcas_trapezium_constraints!
end

function UnitData(loader::RawInputsLoader)
    initial = _xml_initial_conditions(loader)
    trader_type = Dict(string(r.unit) => string(r.trader_type) for r in eachrow(initial))
    bids = _parse_trades(loader, trader_type)
    info = _parse_unit_info(loader, bids, initial)
    uigf = _parse_uigf(loader)
    fs = _xml_fast_start_parameters(loader)
    return UnitData(loader, bids, info, initial, uigf, fs, nothing, nothing)
end

# Resolve a trade's dispatch type: the @Direction attribute (GEN/LOAD, present on
# bidirectional units' trades) wins; otherwise default from the TraderType, the
# way nempy's xml_cache.get_unit_price_bids does.
function _trade_direction(node, duid::String, trader_type::Dict{String,String})
    d = _attr(node, "Direction")
    if !ismissing(d)
        return d == "LOAD" ? "load" : "generator"
    end
    tt = get(trader_type, duid, "GENERATOR")
    return tt == "LOAD" ? "load" : "generator"
end

# --- XML parsing -------------------------------------------------------------
# Walk every TraderPeriod -> Trade node, extracting the 10 volume bands, the 10
# price bands, the FCAS trapezium geometry, MaxAvail and the bid ramp rates.
function _parse_trades(loader::RawInputsLoader, trader_type::Dict{String,String})
    periods = _xml_trader_periods(loader)
    price_lookup = _xml_trade_prices_by_direction(loader, trader_type)
    rows = NamedTuple[]
    for tp in periods
        duid = _attr(tp, "TraderID")
        ismissing(duid) && continue
        for tr in findall(".//*[local-name()='Trade']", tp)
            ttype = _attr(tr, "TradeType")
            ismissing(ttype) && continue
            service = get(TRADE_TYPE_TO_SERVICE, ttype, nothing)
            service === nothing && continue
            dt = _trade_direction(tr, String(duid), trader_type)
            vols = [coalesce(_attrf(tr, "BandAvail$i"), 0.0) for i in 1:N_BANDS]
            prices = get(price_lookup, (String(duid), String(ttype), dt), zeros(N_BANDS))
            push!(rows, (
                unit = String(duid), dispatch_type = dt, service = service,
                ttype = String(ttype),
                max_availability = coalesce(_attrf(tr, "MaxAvail"), 0.0),
                enablement_min   = coalesce(_attrf(tr, "EnablementMin"), 0.0),
                enablement_max   = coalesce(_attrf(tr, "EnablementMax"), 0.0),
                low_break_point  = coalesce(_attrf(tr, "LowBreakpoint"), 0.0),
                high_break_point = coalesce(_attrf(tr, "HighBreakpoint"), 0.0),
                ramp_up_rate   = _attrf(tr, "RampUpRate"),     # MW/h
                ramp_down_rate = _attrf(tr, "RampDnRate"),     # MW/h
                vols = vols, prices = prices,
            ))
        end
    end
    return DataFrame(rows)
end

# Price bands keyed by (unit, TradeType, dispatch_type) so BDU gen/load price
# structures don't collide.
function _xml_trade_prices_by_direction(loader::RawInputsLoader, trader_type::Dict{String,String})
    m = loader.xml
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    out = Dict{Tuple{String,String,String},Vector{Float64}}()
    for ps in findall("//*[local-name()='TradeTypePriceStructure']", root)
        ttype = _attr(ps, "TradeType")
        ismissing(ttype) && continue
        trader = findfirst("ancestor::*[local-name()='Trader']", ps)
        trader === nothing && continue
        duid = _attr(trader, "TraderID")
        ismissing(duid) && continue
        dt = _trade_direction(ps, String(duid), trader_type)
        prices = [coalesce(_attrf(ps, "PriceBand$i"), 0.0) for i in 1:N_BANDS]
        out[(String(duid), String(ttype), dt)] = prices
    end
    return out
end

# Unit metadata — one row per (unit, dispatch_type) present in the bids, with
# region and the combined loss factor. Mirrors nempy's get_unit_info: the BDU
# GENERATOR side uses SECONDARY_TLF (when present) instead of the primary TLF.
function _parse_unit_info(loader::RawInputsLoader, bids::DataFrame, initial::DataFrame)
    df = _mms(loader, "DUDETAILSUMMARY")
    isempty(df) && return DataFrame(unit=String[], dispatch_type=String[],
                                    region=String[], loss_factor=Float64[])
    tt = Dict(string(r.unit) => string(r.trader_type) for r in eachrow(initial))
    meta = Dict{String,NamedTuple}()
    for r in eachrow(df)
        tlf = coalesce(_to_float(r.TRANSMISSIONLOSSFACTOR), 1.0)
        dlf = coalesce(_to_float(r.DISTRIBUTIONLOSSFACTOR), 1.0)
        stlf = "SECONDARY_TLF" in names(df) ? _to_float(r.SECONDARY_TLF) : missing
        meta[string(r.DUID)] = (region=string(r.REGIONID), tlf=tlf, dlf=dlf, stlf=stlf)
    end
    # Directions actually present in the bids (mirrors nempy: price-bid directions).
    dirs = unique(select(bids, :unit, :dispatch_type))
    rows = NamedTuple[]
    for r in eachrow(dirs)
        u = string(r.unit); dt = string(r.dispatch_type)
        m = get(meta, u, nothing); m === nothing && continue
        is_bdu = get(tt, u, "") == "BIDIRECTIONAL"
        lf = (!ismissing(m.stlf) && dt == "generator" && is_bdu) ?
             m.stlf * m.dlf : m.tlf * m.dlf
        push!(rows, (unit=u, dispatch_type=dt, region=m.region, loss_factor=lf))
    end
    return DataFrame(rows)
end

function _parse_uigf(loader::RawInputsLoader)
    rows = NamedTuple[]
    for tp in _xml_trader_periods(loader)
        duid = _attr(tp, "TraderID"); ismissing(duid) && continue
        uigf = _attrf(tp, "UIGF")
        ismissing(uigf) && continue
        push!(rows, (unit=String(duid), capacity=uigf))
    end
    return isempty(rows) ? DataFrame(unit=String[], capacity=Float64[]) : DataFrame(rows)
end

_to_float(x) = ismissing(x) || x == "" ? missing : tryparse(Float64, string(x))

# -----------------------------------------------------------------------------
# Public accessors — names mirror nempy's UnitData methods.
# -----------------------------------------------------------------------------

"""
    get_unit_info(u::UnitData) -> DataFrame

`unit, dispatch_type, region, loss_factor` for every unit-direction with bids.
"""
get_unit_info(u::UnitData) = u.info

"""
    get_unit_bid_availability(u::UnitData) -> DataFrame

Energy `MAXAVAIL` cap per (unit, dispatch_type). Mirrors
`get_unit_bid_availability` (post-2023 behaviour: semi-scheduled units keep
their bid availability constraint alongside the UIGF constraint).
"""
function get_unit_bid_availability(u::UnitData)
    en = u.bids[u.bids.service .== "energy", :]
    return DataFrame(unit=en.unit, dispatch_type=en.dispatch_type,
                     capacity=en.max_availability)
end

"""
    get_unit_uigf_limits(u::UnitData) -> DataFrame

Unconstrained Intermittent Generation Forecast caps for SEMI-SCHEDULED units:
`unit, capacity` (from the TraderPeriod @UIGF).
"""
get_unit_uigf_limits(u::UnitData) = u.uigf

"""
    get_bid_ramp_rates(u::UnitData) -> DataFrame

Bid (offer) ramp rates in MW/h with the unit's initial output:
`unit, dispatch_type, ramp_up_rate, ramp_down_rate, initial_output`.
"""
function get_bid_ramp_rates(u::UnitData)
    en = u.bids[u.bids.service .== "energy", :]
    init = Dict(string(r.unit) => r.initial_mw for r in eachrow(u.initial))
    rows = NamedTuple[]
    for r in eachrow(en)
        im = get(init, string(r.unit), missing)
        ismissing(im) && continue        # nempy inner-joins INITIALMW
        push!(rows, (unit=string(r.unit), dispatch_type=string(r.dispatch_type),
                     ramp_up_rate=r.ramp_up_rate, ramp_down_rate=r.ramp_down_rate,
                     initial_output=im))
    end
    return DataFrame(rows)
end

"""
    get_scada_ramp_rates(u::UnitData; include_initial_output=false) -> DataFrame

SCADA telemetered ramp rates (MW/h) and, optionally, INITIALMW. Rows where both
rates are missing are dropped (mirrors nempy's `get_scada_ramp_rates`).
"""
function get_scada_ramp_rates(u::UnitData; include_initial_output::Bool=false)
    df = u.initial
    keep = .!(ismissing.(df.scada_ramp_up) .& ismissing.(df.scada_ramp_down))
    df = df[keep, :]
    out = DataFrame(unit=string.(df.unit),
                    scada_ramp_up_rate=df.scada_ramp_up,
                    scada_ramp_down_rate=df.scada_ramp_down)
    include_initial_output && (out.initial_output = df.initial_mw)
    return out
end

"""
    get_initial_unit_output(u::UnitData) -> DataFrame

`unit, initial_output` (MW) at the start of the interval.
"""
get_initial_unit_output(u::UnitData) =
    DataFrame(unit=string.(u.initial.unit), initial_output=u.initial.initial_mw)

# -----------------------------------------------------------------------------
# get_processed_bids — the full nempy FCAS preprocessing pipeline.
# -----------------------------------------------------------------------------
"""
    get_processed_bids(u::UnitData) -> (volume_bids, price_bids)

Return the TEN-band volume and price bids as two wide `DataFrame`s with columns
`unit, dispatch_type, service, "1"…"10"`. Before formatting, FCAS bids are
scaled for AGC enablement limits, AGC (SCADA) ramp rates and UIGF, and the AEMO
FCAS-enablement preconditions are enforced — bids failing them are REMOVED,
exactly as nempy's `get_processed_bids` does.

Note on loss factors: nempy multiplies the XML energy prices by the combined
loss factor (undoing the XML's referral to the regional node) and the market
model then divides by the same loss factor when building the objective — the
two operations cancel, so the objective coefficients equal the raw XML prices.
We use the XML prices directly.
"""
function get_processed_bids(u::UnitData)
    b = copy(u.bids)
    b = _scaling_for_agc_enablement_limits(u, b)
    b = _scaling_for_agc_ramp_rates(u, b)
    b = _scaling_for_uigf(u, b)
    b = _enforce_preconditions_for_enabling_fcas(u, b)
    u.processed = b

    vol = DataFrame(unit=String[], dispatch_type=String[], service=String[])
    pri = DataFrame(unit=String[], dispatch_type=String[], service=String[])
    for c in BAND_COLS
        vol[!, c] = Float64[]; pri[!, c] = Float64[]
    end
    # nempy multiplies energy price bids by the combined loss factor (undoing the
    # XML's referral to the regional node); the market model then divides by the
    # same factor when building the objective. The float round-trip (p*λ)/λ is
    # NOT an exact identity, and nempy's tie-break constraints group bids by
    # EXACT cost equality — so we replicate both operations bit-for-bit.
    lf = Dict((string(r.unit), string(r.dispatch_type)) => float(r.loss_factor)
              for r in eachrow(u.info))
    for r in eachrow(b)
        push!(vol, (r.unit, r.dispatch_type, r.service, r.vols...))
        if r.service == "energy" && XML_PRICES_PRESCALED[]
            # Historical convention (verified exact for 2024): XML energy
            # prices are pre-scaled to the regional node (p_conn/λ); multiply
            # by λ to restore connection terms, the market model divides again.
            λ = get(lf, (string(r.unit), string(r.dispatch_type)), 1.0)
            push!(pri, (r.unit, r.dispatch_type, r.service, (r.prices .* λ)...))
        else
            # XML_PRICES_PRESCALED[]=false: treat XML energy prices as
            # CONNECTION-POINT prices (no pre-scaling); the market model's
            # divide-by-λ then refers them to the regional node. The Sept-2025
            # mainland bias (model ≈ ROP/λ̄, ~4.7% under) has exactly this
            # signature, suggesting AEMO stopped pre-scaling in 2025 files.
            push!(pri, (r.unit, r.dispatch_type, r.service, r.prices...))
        end
    end
    return vol, pri
end

# 1. Scale regulating-FCAS enablement/break points where the AGC telemetered
#    limits (MMS DISPATCHLOAD) are more restrictive than the offer.
#    (Mutates the working copy in place — column access keeps this type-stable.)
function _scaling_for_agc_enablement_limits(u::UnitData, b::DataFrame)
    dl = _mms(u.loader, "DISPATCHLOAD")
    isempty(dl) && return b
    lim = Dict{String,NTuple{4,Float64}}()
    # XML HMW/LMW (trader initial conditions) = telemetered High/Low MW
    # operating limits, i.e. the AGC enablement window for regulation FCAS.
    # Applied MOST-RESTRICTIVE-WINS, per unit and per bound, and ONLY where the
    # value exists: the effective window is the INTERSECTION of the offered
    # trapezium enablement range and the telemetered HMW/LMW. So:
    #   effective ENABLEMENTMAX = min(offer/DISPATCHLOAD max, HMW)
    #   effective ENABLEMENTMIN = max(offer/DISPATCHLOAD min, LMW)
    # A missing HMW/LMW leaves the corresponding bound untouched; a value that
    # is LOOSER than what the offer already implies is ignored (it cannot widen
    # the window). Recorded separately from `lim` so DISPATCHLOAD keeps
    # priority for the units it covers and 2024 stays bit-identical.
    hl = Dict{String,Tuple{Union{Missing,Float64},Union{Missing,Float64}}}()
    if AGC_ENABLEMENT_FROM_XML[] && ("hmw" in names(u.initial))
        for r in eachrow(u.initial)
            h = ismissing(r.hmw) ? missing : float(r.hmw)
            l = ismissing(r.lmw) ? missing : float(r.lmw)
            (ismissing(h) && ismissing(l)) && continue
            hl[string(r.unit)] = (h, l)
        end
    end
    for r in eachrow(dl)
        lim[string(r.DUID)] = (
            coalesce(_to_float(r.RAISEREGENABLEMENTMAX), 0.0),
            coalesce(_to_float(r.RAISEREGENABLEMENTMIN), 0.0),
            coalesce(_to_float(r.LOWERREGENABLEMENTMAX), 0.0),
            coalesce(_to_float(r.LOWERREGENABLEMENTMIN), 0.0),
        )
    end
    un = b.unit; sv = b.service
    emin = b.enablement_min; emax = b.enablement_max
    lbp = b.low_break_point; hbp = b.high_break_point
    for i in 1:nrow(b)
        sv[i] in ("raise_reg", "lower_reg") || continue
        L = get(lim, string(un[i]), nothing)
        H = get(hl, string(un[i]), (missing, missing))
        (L === nothing && ismissing(H[1]) && ismissing(H[2])) && continue
        agc_max = L === nothing ? 0.0 : (sv[i] == "raise_reg" ? L[1] : L[3])
        agc_min = L === nothing ? 0.0 : (sv[i] == "raise_reg" ? L[2] : L[4])
        # HMW/LMW tighten (never widen) the enablement window, bound by bound.
        if !ismissing(H[1])
            agc_max = (agc_max > 0) ? min(agc_max, H[1]) : H[1]
        end
        if !ismissing(H[2])
            agc_min = (agc_min > 0) ? max(agc_min, H[2]) : H[2]
        end
        if agc_min > emin[i] && agc_min > 0.0
            lbp[i] += (agc_min - emin[i]); emin[i] = agc_min
        end
        if agc_max < emax[i] && agc_max > 0.0
            hbp[i] -= (emax[i] - agc_max); emax[i] = agc_max
        end
    end
    return b
end

# 2. Cap regulating-FCAS max availability by the SCADA ramp window (rate*5/60),
#    scaling breakpoints to preserve the trapezium slopes.
function _scaling_for_agc_ramp_rates(u::UnitData, b::DataFrame)
    scada = Dict{String,Tuple{Union{Missing,Float64},Union{Missing,Float64}}}()
    for r in eachrow(u.initial)
        scada[string(r.unit)] = (r.scada_ramp_up, r.scada_ramp_down)
    end
    un = b.unit; sv = b.service
    maxa = b.max_availability
    emin = b.enablement_min; emax = b.enablement_max
    lbp = b.low_break_point; hbp = b.high_break_point
    for i in 1:nrow(b)
        sv[i] in ("raise_reg", "lower_reg") || continue
        s = get(scada, string(un[i]), nothing); s === nothing && continue
        rate = sv[i] == "raise_reg" ? s[1] : s[2]
        (ismissing(rate) || rate == 0.0) && continue
        ramp_max = rate * (5.0 / 60.0)
        if maxa[i] > ramp_max && (lbp[i] - emin[i]) != 0.0
            m_ = maxa[i] / (lbp[i] - emin[i]); lbp[i] = ramp_max / m_ + emin[i]
        end
        if maxa[i] > ramp_max && (emax[i] - hbp[i]) != 0.0
            m_ = maxa[i] / (emax[i] - hbp[i]); hbp[i] = emax[i] - ramp_max / m_
        end
        maxa[i] = min(maxa[i], ramp_max)
    end
    return b
end

# 3. For semi-scheduled units, cap FCAS enablement max at the UIGF.
function _scaling_for_uigf(u::UnitData, b::DataFrame)
    isempty(u.uigf) && return b
    uigf = Dict(string(r.unit) => float(r.capacity) for r in eachrow(u.uigf))
    un = b.unit; sv = b.service
    emax = b.enablement_max; hbp = b.high_break_point
    for i in 1:nrow(b)
        sv[i] == "energy" && continue
        avail = get(uigf, string(un[i]), nothing); avail === nothing && continue
        if emax[i] > avail
            hbp[i] -= (emax[i] - avail); emax[i] = avail
        end
    end
    return b
end

# 4. AEMO FCAS-enablement preconditions (FCAS MODEL IN NEMDE, section 5).
#    Bids failing them are removed. Mirrors nempy's
#    _enforce_preconditions_for_enabling_fcas including its BDU-specific rules.
function _enforce_preconditions_for_enabling_fcas(u::UnitData, b::DataFrame)
    energy = b[b.service .== "energy", :]
    fcas = b[b.service .!= "energy", :]
    isempty(fcas) && return b

    # capacity limits per (unit, dispatch_type) = energy MaxAvail.
    cap = Dict{Tuple{String,String},Float64}()
    for r in eachrow(energy)
        cap[(string(r.unit), string(r.dispatch_type))] = r.max_availability
    end
    init = Dict(string(r.unit) => (mw=r.initial_mw, agc=r.agc_status,
                                   tt=string(r.trader_type)) for r in eachrow(u.initial))

    # FCAS max availability > 0 and at least one non-zero band.
    fcas = fcas[(fcas.max_availability .> 0.0) .& (maximum.(fcas.vols) .> 0.0), :]
    # capacity (own direction) >= enablement min (pass when capacity unknown).
    keep = [(c = get(cap, (string(r.unit), string(r.dispatch_type)), missing);
             ismissing(c) || c >= r.enablement_min) for r in eachrow(fcas)]
    fcas = fcas[keep, :]
    # units with initial conditions only (nempy inner-joins DISPATCHLOAD/XML ICs).
    fcas = fcas[[haskey(init, string(r.unit)) for r in eachrow(fcas)], :]
    isempty(fcas) && return vcat(energy, fcas)

    isreg(s) = s in ("raise_reg", "lower_reg")

    # Cross-side enablement bounds for the BDU regulation windows (nempy's
    # FILTERENABLMENTMAX/MIN): the load side borrows the GEN side's enablement
    # max, and the gen side borrows the LOAD side's enablement min (each falling
    # back to its own value when the other side has no matching reg bid).
    gen_reg_emax = Dict{Tuple{String,String},Float64}()
    load_reg_emin = Dict{Tuple{String,String},Float64}()
    for i in 1:nrow(fcas)
        isreg(fcas.service[i]) || continue
        key = (string(fcas.unit[i]), string(fcas.service[i]))
        if fcas.dispatch_type[i] == "generator"
            gen_reg_emax[key] = fcas.enablement_max[i]
        else
            load_reg_emin[key] = fcas.enablement_min[i]
        end
    end

    keep2 = falses(nrow(fcas))
    for i in 1:nrow(fcas)
        u_ = string(fcas.unit[i]); dt = string(fcas.dispatch_type[i])
        s_ = string(fcas.service[i])
        ic = init[u_]
        bdu = ic.tt == "BIDIRECTIONAL"; reg = isreg(s_)
        emin = fcas.enablement_min[i]; emax = fcas.enablement_max[i]
        ok = true
        if !bdu
            ok &= emax >= 0.0
            imw = ismissing(ic.mw) ? 0.0 : max(float(ic.mw), 0.0)
            imw = round(imw; digits=5)
            ok &= (emax >= imw) && (emin <= imw)
        elseif bdu && !reg
            imw = ismissing(ic.mw) ? 0.0 : round(float(ic.mw); digits=5)
            if dt == "generator"
                ok &= emax >= 0.0
                # enablement max must accommodate the LOAD side's capacity.
                cl = get(cap, (u_, "load"), missing)
                ok &= ismissing(cl) || (-cl <= emax)
            else
                ok &= emin <= 0.0
            end
            ok &= (emax >= imw) && (emin <= imw)
        else  # bdu && reg
            if dt == "generator"
                # gen-side reg: window = [load side's emin (fallback own), own emax]
                fmin_ = get(load_reg_emin, (u_, s_), emin)
                ok &= emax >= 0.0
                imw = ismissing(ic.mw) ? 0.0 : round(float(ic.mw); digits=5)
                ok &= (emax >= imw) && (fmin_ <= imw)
            else
                # load-side reg: window = [own emin, gen side's emax (fallback own)]
                fmax = get(gen_reg_emax, (u_, s_), emax)
                ok &= emin <= 0.0
                cl = get(cap, (u_, "load"), missing)
                ok &= ismissing(cl) || (-cl <= emax)
                imw = ismissing(ic.mw) ? 0.0 : round(float(ic.mw); digits=5)
                ok &= (fmax >= imw) && (emin <= imw)
            end
        end
        # AGC connection required for regulation services.
        (reg && ok) && (ok &= ic.agc != 0.0)
        keep2[i] = ok
    end
    return vcat(energy, fcas[keep2, :])
end

"""
    add_fcas_trapezium_constraints!(u::UnitData)

Build the (scaled, filtered) FCAS trapezium table from the processed bids.
Must be called AFTER `get_processed_bids` (mirrors nempy's call-order rule).
"""
function add_fcas_trapezium_constraints!(u::UnitData)
    u.processed === nothing &&
        error("Call get_processed_bids before add_fcas_trapezium_constraints!.")
    f = u.processed[u.processed.service .!= "energy", :]
    u.trapeziums = DataFrame(unit=f.unit, dispatch_type=f.dispatch_type,
                             service=f.service, max_availability=f.max_availability,
                             enablement_min=f.enablement_min,
                             low_break_point=f.low_break_point,
                             high_break_point=f.high_break_point,
                             enablement_max=f.enablement_max)
    return u
end

function _require_trapeziums(u::UnitData)
    u.trapeziums === nothing &&
        error("Call add_fcas_trapezium_constraints! before this accessor.")
    return u.trapeziums
end

"""
    get_fcas_max_availability(u::UnitData) -> DataFrame

`unit, dispatch_type, service, max_availability` (post-scaling).
"""
function get_fcas_max_availability(u::UnitData)
    t = _require_trapeziums(u)
    return t[:, [:unit, :dispatch_type, :service, :max_availability]]
end

"""
    get_fcas_regulation_trapeziums(u::UnitData) -> DataFrame

Trapeziums for the REGULATION services (`raise_reg`, `lower_reg`).
"""
function get_fcas_regulation_trapeziums(u::UnitData)
    t = _require_trapeziums(u)
    return t[in.(t.service, Ref(["raise_reg", "lower_reg"])), :]
end

"""
    get_contingency_services(u::UnitData) -> DataFrame

Trapeziums for the CONTINGENCY services (1s/6s/60s/5min raise & lower).
"""
function get_contingency_services(u::UnitData)
    cont = ["raise_6s", "raise_60s", "raise_5min", "raise_1s",
            "lower_6s", "lower_60s", "lower_5min", "lower_1s"]
    t = _require_trapeziums(u)
    return t[in.(t.service, Ref(cont)), :]
end

# -----------------------------------------------------------------------------
# Fast-start dispatch inflexibility profiles (two-run process).
# -----------------------------------------------------------------------------
"""
    get_fast_start_profiles_for_dispatch(u::UnitData; unconstrained_dispatch=nothing)

First run (no dispatch given): returns `unit, current_mode, min_loading`.
Second run (pass the first run's `get_unit_dispatch` result): evolves each
fast-start unit's mode over the 5-minute interval (committing mode-0 units with
non-zero unconstrained dispatch) and returns
`unit, end_mode, time_in_end_mode, mode_two_length, mode_four_length,
min_loading, time_since_end_of_mode_two`. Mirrors nempy's `_update_modes`.
"""
get_fast_start_profiles_for_dispatch(u::UnitData; unconstrained_dispatch=nothing) =
    _fast_start_profiles(u.fast_start; unconstrained_dispatch=unconstrained_dispatch)

function _fast_start_profiles(fast_start::DataFrame; unconstrained_dispatch=nothing)
    fs = copy(fast_start)
    isempty(fs) && return fs
    if unconstrained_dispatch === nothing
        return fs[:, [:unit, :current_mode, :min_loading]]
    end
    ud = unconstrained_dispatch[unconstrained_dispatch.service .== "energy", :]
    # Net energy dispatch per unit (gen − load for BDUs; single row otherwise).
    disp = Dict{String,Float64}()
    for r in eachrow(ud)
        sgn = ("dispatch_type" in names(ud) && string(r.dispatch_type) == "load") ? -1.0 : 1.0
        disp[string(r.unit)] = get(disp, string(r.unit), 0.0) + sgn * r.dispatch
    end
    rows = NamedTuple[]
    for r in eachrow(fs)
        haskey(disp, string(r.unit)) || continue    # nempy inner-joins dispatch
        d = disp[string(r.unit)]
        time_left = 5.0
        t_in_mode = float(r.time_in_current_mode)
        mode = Int(r.current_mode)
        tsem2 = missing            # time since end of mode two
        # Commitment: a mode-0 fast-start unit that the unconstrained run
        # dispatched (in EITHER direction) starts its inflexibility profile.
        # The magnitude matters, not the sign — our net-dispatch convention
        # makes load-side dispatch negative, and `d > 0` silently exempted
        # every fast-start PUMP from commitment (observed 2025-09-01 09:05:
        # PUMP2 pumped 244 MW freely while NEMDE held it in mode 1 at zero,
        # lifting all five regional prices by ~$65/MWh).
        if mode == 0 && abs(d) > 0.0
            mode = 1
        end
        if mode == 1 && (r.mode_one_length - t_in_mode < time_left)
            time_left -= (r.mode_one_length - t_in_mode)
            mode = 2; t_in_mode = 0.0
        end
        if mode == 2 && (r.mode_two_length - t_in_mode < time_left)
            time_left -= (r.mode_two_length - t_in_mode)
            mode = 3; t_in_mode = 0.0
            tsem2 = time_left
        end
        if mode == 3 && (r.mode_three_length - t_in_mode < time_left)
            time_left -= (r.mode_three_length - t_in_mode)
            mode = 4; t_in_mode = 0.0
        end
        time_in_end_mode = t_in_mode + time_left
        mode == 0 && (time_in_end_mode = 0.0)
        (mode == 4 && time_in_end_mode > r.mode_four_length) &&
            (time_in_end_mode = float(r.mode_four_length))
        push!(rows, (unit=string(r.unit), min_loading=float(r.min_loading),
                     current_mode=Int(r.current_mode), end_mode=mode,
                     time_in_end_mode=time_in_end_mode,
                     mode_two_length=float(r.mode_two_length),
                     mode_four_length=float(r.mode_four_length),
                     time_since_end_of_mode_two=tsem2))
    end
    return isempty(rows) ? DataFrame() : DataFrame(rows)
end
