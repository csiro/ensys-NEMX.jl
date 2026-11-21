# MNSP link bid limits/prices (A16) — DATE-CONDITIONAL.
#
# MNSP interconnectors (Basslink, Murraylink, Terranora) are MARKET
# PARTICIPANTS: the owner bids the link's capacity in ten price/volume bands
# per region and NEMDE clears those bids like a generator's. Modelling them
# (volume cap + priced bands) is strictly more faithful, but it perturbs the
# 2024 benchmark by ~$0.01/MWh, so it is gated by interval date:
#
#   :auto  (default) -> ON for intervals from MNSP_BID_FROM, OFF before.
#   true / false     -> force on/off regardless of date.
#
# The 2024-07 benchmark therefore stays bit-identical while 2025+ runs get the
# corrected MNSP treatment. Override per run:
#   nemjl.MNSP_BID_LIMITS[] = true      # force on (e.g. to study 2024 impact)
#   nemjl.MNSP_BID_FROM[]   = DateTime(2025,1,1)
const MNSP_BID_LIMITS = Ref{Any}(:auto)
const MNSP_BID_FROM   = Ref(DateTime(2025, 1, 1))

"True when MNSP link bids should be modelled for `interval` (see MNSP_BID_LIMITS)."
function mnsp_bids_active(interval)
    v = MNSP_BID_LIMITS[]
    v isa Bool && return v
    interval === nothing && return false
    return _to_datetime(interval) >= MNSP_BID_FROM[]
end

# =============================================================================
# interconnectors.jl
#
# Julia port of `nempy.historical_inputs.interconnectors.InterconnectorData`.
#
# Interconnectors carry power between regions. Each has:
#   * a definition: from-region, to-region, import/export MW limits
#   * a LOSS MODEL: marginal losses as a function of flow, supplied by AEMO as
#     a quadratic loss equation that NEMDE linearises over a set of MW
#     breakpoints (LOSSMODEL.MWBREAKPOINT). We reproduce this as a piecewise
#     linear loss curve sampled at those breakpoints.
#
# AEMO loss equation (per interconnector):
#     losses(flow) = LOSSCONSTANT - 1
#                  + LOSSFLOWCOEFFICIENT * flow
#                  + Σ_region DEMANDCOEFFICIENT_region * regional_demand * flow
#                  + quadratic terms (captured by the breakpoint sampling)
#
# nempy returns (loss_functions, interpolation_break_points); here the loss
# function is sampled at each breakpoint to give (flow, loss) support points
# that the market model turns into a piecewise-linear (SOS2) loss curve.
# =============================================================================

"""
    InterconnectorData(loader::RawInputsLoader)

Reads interconnector definitions and the loss model for the current interval.
Mirrors `interconnectors.InterconnectorData`.
"""
mutable struct InterconnectorData
    loader::RawInputsLoader
    definitions::DataFrame      # interconnector, from_region, to_region, limits
    loss_model::DataFrame       # breakpoints + loss-equation coefficients
end

function InterconnectorData(loader::RawInputsLoader)
    defs = _build_definitions(loader)
    loss = _build_loss_model(loader, defs)
    return InterconnectorData(loader, defs, loss)
end

# Build the interconnector definitions with nempy's MNSP directional split.
#
# * REGULATED interconnectors (NSW1-QLD1, VIC1-NSW1, V-SA): a single bidirectional
#   "link" whose flow is metered 1:1 at each region node (loss factors 1.0),
#   generic_constraint_factor 1, limits from INTERCONNECTORCONSTRAINT.
# * MNSP interconnectors (Basslink T-V-MNSP1, Murraylink V-S-MNSP1, Terranora
#   N-Q-MNSP1): split into one UNIDIRECTIONAL link per LINKID (min 0, max
#   MAXCAPACITY), each with its own from/to region transmission loss factors
#   (FROM_REGION_TLF/TO_REGION_TLF) and a generic_constraint_factor (LHSFACTOR,
#   ±1) that maps the link flow onto the interconnector's positive direction.
#
# Columns: interconnector, link, from_region, to_region, min, max,
# from_region_loss_share, from_region_loss_factor, to_region_loss_factor,
# generic_constraint_factor, ic_from_region, ic_to_region (canonical direction
# used for loss allocation).
function _build_definitions(loader::RawInputsLoader)
    ic = _mms(loader, "INTERCONNECTOR")
    cons = _mms(loader, "INTERCONNECTORCONSTRAINT")
    mnsp = _mms(loader, "MNSP_INTERCONNECTOR")
    use_bids = mnsp_bids_active(loader.interval)
    mnsp_off = use_bids ? (try _xml_mnsp_offers(loader) catch; Dict() end) : Dict()
    cols = [:interconnector, :link, :from_region, :to_region, :min, :max,
            :from_region_loss_share, :offer_bands, :offer_prices,
            :from_region_loss_factor, :to_region_loss_factor,
            :generic_constraint_factor, :ic_from_region, :ic_to_region]
    empty_defs = DataFrame([c => (c in (:interconnector, :link, :from_region, :to_region,
                                        :ic_from_region, :ic_to_region) ? String[] :
                                  c in (:offer_bands, :offer_prices) ? Vector{Float64}[] : Float64[])
                            for c in cols]...)
    isempty(ic) && return empty_defs

    # Per-interconnector parameters and canonical direction.
    par = Dict{String,NamedTuple}()
    for r in eachrow(cons)
        par[string(r.INTERCONNECTORID)] = (
            ictype = "ICTYPE" in names(cons) ? uppercase(string(r.ICTYPE)) : "REGULATED",
            min = -coalesce(_to_float(r.IMPORTLIMIT), 0.0),
            max = coalesce(_to_float(r.EXPORTLIMIT), 0.0),
            loss_share = coalesce(_to_float(r.FROMREGIONLOSSSHARE), 0.5),
        )
    end
    region_from = Dict(string(r.INTERCONNECTORID) => string(r.REGIONFROM) for r in eachrow(ic))
    region_to   = Dict(string(r.INTERCONNECTORID) => string(r.REGIONTO)   for r in eachrow(ic))

    rows = NamedTuple[]
    # (1) Regulated interconnectors — single link, unit loss factors.
    for (icid, p) in par
        p.ictype == "REGULATED" || continue
        haskey(region_from, icid) || continue
        fr = region_from[icid]; tr = region_to[icid]
        push!(rows, (interconnector=icid, link=icid, from_region=fr, to_region=tr,
                     min=p.min, max=p.max, from_region_loss_share=p.loss_share,
                     offer_bands=Float64[], offer_prices=Float64[],
                     from_region_loss_factor=1.0, to_region_loss_factor=1.0,
                     generic_constraint_factor=1.0, ic_from_region=fr, ic_to_region=tr))
    end
    # (2) MNSP interconnectors — one unidirectional link per LINKID.
    if !isempty(mnsp)
        for r in eachrow(mnsp)
            icid = string(r.INTERCONNECTORID)
            p = get(par, icid, nothing)
            (p === nothing || p.ictype != "MNSP") && continue
            flf = coalesce(_to_float(r.FROM_REGION_TLF), 1.0)
            tlf = coalesce(_to_float(r.TO_REGION_TLF), 1.0)
            gcf = coalesce(_to_float(r.LHSFACTOR), 1.0)
            maxcap = coalesce(_to_float(r.MAXCAPACITY), 0.0)
            # Basslink's from-region loss share is not well defined in AEMO data
            # WHILE IT IS AN MNSP; nempy fixes it to 1.0. After its mid-2025
            # conversion to a regulated service this row is no longer reached
            # (ICTYPE=REGULATED takes the regulated branch above with the
            # published FROMREGIONLOSSSHARE) — do NOT force 1.0 there, or all
            # Basslink losses land in TAS and TAS prices bias high.
            share = icid == "T-V-MNSP1" ? 1.0 : p.loss_share
            # MNSP link OFFER (A16): the link's own 10-band bid, keyed by the
            # TO-region. An MNSPOffer's @RegionID is the region the owner
            # offers to DELIVER INTO, so BLNKTAS (TAS1->VIC1) takes the VIC1
            # offer and BLNKVIC (VIC1->TAS1) takes the TAS1 offer. Verified
            # against nempy (xml_cache.get_market_interconnector_link_bid_
            # availability keys to_region; interconnectors.py merges on it).
            # NOTE: nempy uses the offer as a CAP ONLY; we additionally PRICE
            # the bands, which is what NEMDE does (MNSPs clear on merit like
            # generators) and what produced the Sept-2025 accuracy gain.
            # MNSPs are market participants; their bids both CAP the link
            # (MaxAvail) and PRICE its use. Empty when MNSP_BID_LIMITS[]=false
            # or the interval has no MNSPOffer element.
            off = use_bids ? get(mnsp_off, (icid, string(r.TOREGION)), nothing) : nothing
            obands = off === nothing ? Float64[] : off.bands
            oprices = off === nothing ? Float64[] : off.prices
            omax = off === nothing ? maxcap : min(maxcap, off.max_avail)
            push!(rows, (interconnector=icid, link=string(r.LINKID),
                         from_region=string(r.FROMREGION), to_region=string(r.TOREGION),
                         min=0.0, max=omax, from_region_loss_share=share,
                         offer_bands=obands, offer_prices=oprices,
                         from_region_loss_factor=(flf <= 0 ? 1.0 : flf),
                         to_region_loss_factor=(tlf <= 0 ? 1.0 : tlf),
                         generic_constraint_factor=gcf,
                         ic_from_region=get(region_from, icid, ""),
                         ic_to_region=get(region_to, icid, "")))
        end
    end
    return isempty(rows) ? empty_defs : DataFrame(rows)
end

# Build the interconnector loss curve, sampling AEMO's loss FUNCTION at the
# LOSSMODEL breakpoints. This is a faithful port of nempy's `create_loss_functions`
# and `_create_function`:
#
#     loss(flow) = (loss_constant − 1 + demand_offset)·flow
#                  + (flow_coefficient / 2)·flow²
#
#     demand_offset = Σ_region DEMANDCOEFFICIENT_region · loss_function_demand_region
#     loss_function_demand = INITIALSUPPLY + DEMANDFORECAST   (NOT TOTALDEMAND)
#
# The earlier version omitted the `·flow` on the linear term and the whole
# quadratic term, and used TOTALDEMAND — so losses were wrong (and, because the
# curve degenerated, not added to the model at all). Getting this right is what
# separates regional prices: the marginal loss factor at the solved flow sets the
# price ratio between connected regions.
"""
Source the interconnector loss curve from NEMDE's OWN per-interval loss model
(the `<LossModel>/<Segment>` collections in the case file) instead of
re-deriving it from the MMS demand coefficients.

`true` (DEFAULT since the September-2025 loss validation) reproduces NEMDE's
published `InterconnectorSolution/@Losses` exactly. Set `NEMX_LOSS_XML=0`, or
`nemjl.LOSS_MODEL_FROM_XML[] = false`, to fall back to the MMS derivation.

Validation that promoted this to the default (22 matched September-2025
intervals, 1 210 price comparisons, same intervals both ways):

| metric                     | MMS derivation | NEMDE XML curves |
|----------------------------|----------------|------------------|
| energy MAE (`\$/MWh`)         | 1.7125         | < 0.0001         |
| energy max abs error       | 15.84          | 0.00094          |
| FCAS MAE (`\$/MW`)            | 0.0510         | 0.0295           |
| FCAS max abs error         | 10.09          | 3.78             |
| QLD lower-service FCAS MAE | 0.2817         | 0.0990           |

July-2024 is unchanged to 7 decimal places: mean price error
-0.0798602820 (MMS) vs -0.0798602591 (XML), a shift of 2e-8 `\$/MWh`. Its binding
flows sit where the two curves agree, so the change is confined to the
intervals the MMS derivation actually got wrong. NOTE this is no longer
BIT-identical to the reference implementation, which is expected: the model now
matches AEMO's own loss model rather than nempy's re-derivation of it.

The MMS derivation's residual is a purely LINEAR error in the demand-dependent
coefficient — measured at 0.014 MW per MW of flow on V-SA, i.e. up to 14.8 MW
across its range — which the NEMDE segments make unnecessary because they
already embed that interval's demand term.
"""
const LOSS_MODEL_FROM_XML = Ref(get(ENV, "NEMX_LOSS_XML", "1") == "1")

function _build_loss_model(loader::RawInputsLoader, defs::DataFrame)
    if LOSS_MODEL_FROM_XML[]
        try
            xlm = _xml_loss_model(loader)
            if !isempty(xlm)
                rows = NamedTuple[]
                for sub in groupby(_mms(loader, "LOSSMODEL"), :INTERCONNECTORID)
                    ic = string(first(sub.INTERCONNECTORID))
                    haskey(xlm, ic) || continue
                    md = xlm[ic]
                    bps = sort(collect(coalesce.(_to_float.(sub.MWBREAKPOINT), 0.0)))
                    length(bps) < 2 && continue
                    for lr in eachrow(defs[string.(defs.interconnector) .== ic, :])
                        gcf = coalesce(_to_float(lr.generic_constraint_factor), 1.0)
                        for f in bps
                            push!(rows, (interconnector=ic, link=string(lr.link),
                                         break_point=f * gcf, loss=xml_loss_at(md, f)))
                        end
                    end
                end
                # Interconnectors absent from the XML (e.g. the notional SNOWY1 /
                # V-SN) still need their MMS curve, so fall through for those.
                if !isempty(rows)
                    have = Set(r.interconnector for r in rows)
                    mmsdf = _build_loss_model_mms(loader, defs)
                    extra = mmsdf[.!in.(string.(mmsdf.interconnector), Ref(have)), :]
                    return vcat(DataFrame(rows), extra; cols=:union)
                end
            end
        catch err
            @warn "XML loss model unavailable; falling back to the MMS derivation" err
        end
    end
    return _build_loss_model_mms(loader, defs)
end

function _build_loss_model_mms(loader::RawInputsLoader, defs::DataFrame)
    lm = _mms(loader, "LOSSMODEL")
    lf = _mms(loader, "LOSSFACTORMODEL")
    cons = _mms(loader, "INTERCONNECTORCONSTRAINT")

    rows = NamedTuple[]
    isempty(lm) && return DataFrame(interconnector=String[], break_point=Float64[],
                                    loss=Float64[])

    # loss_function_demand per region = INITIALSUPPLY + DEMANDFORECAST.
    rs = _mms(loader, "DISPATCHREGIONSUM")
    lfd = Dict{String,Float64}()
    for r in eachrow(rs)
        lfd[string(r.REGIONID)] = coalesce(_to_float(r.INITIALSUPPLY), 0.0) +
                                  ("DEMANDFORECAST" in names(rs) ?
                                   coalesce(_to_float(r.DEMANDFORECAST), 0.0) : 0.0)
    end

    # Loss-equation coefficients per interconnector.
    coeff = Dict{String,NamedTuple}()
    for r in eachrow(cons)
        coeff[string(r.INTERCONNECTORID)] = (
            loss_constant = coalesce(_to_float(r.LOSSCONSTANT), 1.0),
            flow_coeff    = coalesce(_to_float(r.LOSSFLOWCOEFFICIENT), 0.0),
        )
    end

    # Demand-dependent offset per interconnector: Σ demand_coeff · loss_function_demand.
    offset = Dict{String,Float64}()
    for r in eachrow(lf)
        ic = string(r.INTERCONNECTORID)
        dc = coalesce(_to_float(r.DEMANDCOEFFICIENT), 0.0)
        offset[ic] = get(offset, ic, 0.0) + dc * get(lfd, string(r.REGIONID), 0.0)
    end

    # One loss curve per LINK (mirrors nempy's get_interconnector_loss_model):
    # for MNSP links the interconnector's breakpoints are multiplied by the
    # link's generic_constraint_factor (±1) so the curve lives in the LINK's own
    # flow domain, and the loss is evaluated at (link_flow * gcf) — i.e. at the
    # interconnector-frame flow. Losses are then allocated between the LINK's
    # from/to regions by from_region_loss_share (1.0 for Basslink links).
    for sub in groupby(lm, :INTERCONNECTORID)
        ic = string(first(sub.INTERCONNECTORID))
        haskey(coeff, ic) || continue
        c = coeff[ic]
        constant = c.loss_constant - 1.0 + get(offset, ic, 0.0)
        bps = sort(collect(coalesce.(_to_float.(sub.MWBREAKPOINT), 0.0)))
        length(bps) < 2 && continue
        links = defs[string.(defs.interconnector) .== ic, :]
        for lr in eachrow(links)
            gcf = coalesce(_to_float(lr.generic_constraint_factor), 1.0)
            for f in bps
                # nempy's exact loss function evaluated at interconnector flow f;
                # the link-frame breakpoint is f*gcf (gcf^2 = 1).
                loss = constant * f + (c.flow_coeff / 2.0) * f^2
                push!(rows, (interconnector=ic, link=string(lr.link),
                             break_point=f * gcf, loss=loss))
            end
        end
    end
    return isempty(rows) ? DataFrame(interconnector=String[], link=String[],
                                     break_point=Float64[], loss=Float64[]) : DataFrame(rows)
end

"""
    get_interconnector_definitions(d::InterconnectorData) -> DataFrame

`interconnector, from_region, to_region, min, max, from_region_loss_share`.
Mirrors `get_interconnector_definitions`.
"""
get_interconnector_definitions(d::InterconnectorData) = d.definitions

"""
    get_interconnector_loss_model(d::InterconnectorData) -> (loss_functions, break_points)

Return the piecewise-linear loss support points. `loss_functions` and
`break_points` together let the market model build a convex piecewise-linear
loss curve via SOS2 weights. Mirrors `get_interconnector_loss_model`.
"""
function get_interconnector_loss_model(d::InterconnectorData)
    # Both returned objects are slices of the same support-point table; kept as
    # two values to match nempy's (loss_functions, interpolation_break_points).
    loss_functions = d.loss_model
    break_points = d.loss_model[:, [:interconnector, :break_point]]
    return loss_functions, break_points
end
