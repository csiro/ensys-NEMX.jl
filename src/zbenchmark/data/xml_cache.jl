# =============================================================================
# xml_cache.jl
#
# Julia port of `nempy.historical_inputs.xml_cache`.
#
# For every 5-minute dispatch interval AEMO publishes a NEMDE (National
# Electricity Market Dispatch Engine) case file. The daily bundle of these XML
# files is downloaded from nemweb and cached on disk. The XML carries the
# *exact* inputs NEMDE used: each unit's 10-band bids, FCAS trapeziums,
# initial conditions (INITIALMW), ramp rates and fast-start parameters.
#
# nemweb URL template (verbatim from nempy):
#   https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/NEMDE/{year}/
#     NEMDE_{year}_{month}/NEMDE_Market_Data/NEMDE_Files/
#     NemSpdOutputs_{year}{month}{day}_loaded.zip
#
# XML structure used (paths under the case file root):
#   NEMSubmission/NemSpdInputs/PeriodCollection/Period/TraderPeriodCollection/
#     TraderPeriod[@TraderID]/TradeCollection/Trade[@TradeType, @BandAvail1..10,
#        @MaxAvail, @EnablementMin, @EnablementMax, @LowBreakpoint,
#        @HighBreakpoint, @RampUpRate, @RampDnRate, @PriceBand1..10 ...]
#   NemSpdInputs/TraderCollection/Trader/.../TraderInitialCondition
#        [@InitialConditionID="INITIALMW"/"SCADARAMPUPRATE"/...]
#
# TradeType codes:  ENOF=energy generation, LDOF=energy load,
#   R6SE/R60S/R5MI/R5RE = raise 6s/60s/5min/reg, L6SE/L60S/L5MI/L5RE = lower.
# These are mapped to nempy/this-package service names below.
# =============================================================================

const NEMDE_URL = "https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/NEMDE/{year}/" *
    "NEMDE_{year}_{month}/NEMDE_Market_Data/NEMDE_Files/" *
    "NemSpdOutputs_{year}{month}{day}_loaded.zip"

# Map NEMDE @TradeType codes -> service names used throughout NempyJL.
const TRADE_TYPE_TO_SERVICE = Dict(
    "ENOF" => "energy",        # energy offer (generator)
    "LDOF" => "energy",        # energy offer (scheduled load)
    "BDOF" => "energy",        # energy offer (bidirectional unit)
    "DROF" => "energy",        # wholesale demand response offer
    "R6SE" => "raise_6s",
    "R60S" => "raise_60s",
    "R5MI" => "raise_5min",
    "R5RE" => "raise_reg",
    "L6SE" => "lower_6s",
    "L60S" => "lower_60s",
    "L5MI" => "lower_5min",
    "L5RE" => "lower_reg",
    # 1-second very-fast services (present in recent NEMDE files):
    "R1SE" => "raise_1s",
    "L1SE" => "lower_1s",
)

"""
    XMLCacheManager(cache_folder::String)

Manage a local cache of NEMDE XML case files. Equivalent to nempy's
`xml_cache.XMLCacheManager`. The folder is created if it does not exist.
"""
mutable struct XMLCacheManager
    cache_folder::String
    interval::Union{Nothing,DateTime}
    doc::Union{Nothing,EzXML.Document}
    loaded_file::String                 # basename of the case file in memory
    function XMLCacheManager(cache_folder::String)
        isdir(cache_folder) || mkpath(cache_folder)
        new(cache_folder, nothing, nothing, "")
    end
end

"""
    populate_by_day!(m; start_year, start_month, start_day, end_year, end_month, end_day)

Download and unzip every daily NEMDE bundle in the inclusive date range into
the cache folder. Mirrors `XMLCacheManager.populate_by_day`. Each daily zip
expands to ~288 XML files (one per 5-minute interval) and is large (~1.5 GB/day
uncompressed), hence the data-volume warning in the example script.
"""
function populate_by_day!(m::XMLCacheManager; start_year, start_month, start_day,
                          end_year, end_month, end_day, verbose::Bool=true)
    # Start ONE day early: the NEM "market day" runs 04:05→04:00, so intervals
    # between 00:00 and 04:00 of `start_day` live in the PREVIOUS calendar day's
    # NemSpdOutputs zip. nempy's populate_by_day does the same (start − 1 day).
    d = Date(start_year, start_month, start_day) - Day(1)
    dend = Date(end_year, end_month, end_day)
    while d <= dend
        # Skip days already in the cache (a market day is complete when its
        # 04:05-next-04:00 case files are present; use a 200-file heuristic so
        # partial days are re-fetched). Only missing days are downloaded, so
        # re-running the populate call fills gaps without re-downloading.
        ymd = Dates.format(d, dateformat"yyyymmdd")
        have = count(f -> startswith(f, "NEMSPDOutputs_" * ymd), readdir(m.cache_folder))
        if have >= 200
            verbose && @info "NEMDE files for $d already cached ($have files) — skipping"
        else
            verbose && @info "Downloading NEMDE files for $d"
            try
                _download_nemde_day!(m, d)
            catch err
                @warn "Failed to download NEMDE bundle for $d: $err"
            end
        end
        d += Day(1)
    end
    return m
end

function _download_nemde_day!(m::XMLCacheManager, d::Date)
    url = replace(NEMDE_URL,
        "{year}" => string(year(d)),
        "{month}" => lpad(month(d), 2, '0'),
        "{day}" => lpad(day(d), 2, '0'))
    # User-Agent avoids AEMO's 403; daily bundles are large so allow long reads.
    resp = HTTP.get(url, NEMWEB_HEADERS; status_exception=false, redirect=true,
                    retry=true, retries=3, read_idle_timeout=600, connect_timeout=30)
    resp.status == 200 || error("nemweb returned HTTP $(resp.status) for $url")
    # The daily zip extracts to per-interval case files named
    # `NEMSPDOutputs_YYYYMMDDNNN00.loaded` (NNN = 3-digit interval number).
    # These ARE the XML — extension `.loaded`, not `.xml`. Extract ALL of them
    # (and recurse into any nested zips), exactly like nempy's z.extractall.
    _extract_all!(resp.body, m.cache_folder)
end

# Recursively extract a zip (in memory) into `folder`, flattening to basenames.
# Nested zips (some daily bundles wrap each interval in its own zip) are opened
# and their contents extracted too.
function _extract_all!(zip_bytes::Vector{UInt8}, folder::String)
    r = ZipFile.Reader(IOBuffer(zip_bytes))
    try
        for f in r.files
            name = basename(f.name)
            isempty(name) && continue            # skip directory entries
            data = read(f)
            if endswith(lowercase(name), ".zip")
                _extract_all!(data, folder)        # nested zip -> recurse
            else
                open(joinpath(folder, name), "w") do io
                    write(io, data)
                end
            end
        end
    finally
        close(r)
    end
end

# AEMO names each interval file `NEMSPDOutputs_{YYYYMMDD}{NNN}00.loaded`, where
# the 3-digit interval number NNN counts 5-minute intervals from 04:00 of the
# market day (interval 1 = 04:05, interval 288 = 04:00 next day) and "00" is a
# literal trailing field. Verified against nempy:
#   load_interval('2024/07/10 12:05:00') -> 'NEMSPDOutputs_2024071009700.loaded'
# (2024-07-10, interval 097, +"00").
function _interval_number(t::DateTime)
    market_day = (hour(t) < 4 || (hour(t) == 4 && minute(t) == 0)) ? Date(t) - Day(1) : Date(t)
    base = DateTime(year(market_day), month(market_day), day(market_day), 4, 0, 0)
    n = round(Int, (t - base) / Millisecond(5 * 60 * 1000))
    return market_day, n
end

function _interval_filename(t::DateTime)
    market_day, n = _interval_number(t)
    ymd = Dates.format(market_day, dateformat"yyyymmdd")
    return "NEMSPDOutputs_$(ymd)$(lpad(n, 3, '0'))00.loaded"
end

"""
    load_interval!(m::XMLCacheManager, interval) -> XMLCacheManager

Load the cached NEMDE XML for a dispatch `interval` (a `DateTime` or AEMO time
string) into memory, ready for the unit/interconnector parsers. Searches the
cache folder for the matching file by interval number, falling back to a glob
on the interval timestamp.
"""
function load_interval!(m::XMLCacheManager, interval)
    t = _to_datetime(interval)
    m.interval = t
    target = _interval_filename(t)                       # canonical name
    direct = joinpath(m.cache_folder, target)
    file = isfile(direct) ? direct : _search_cache(m, t)
    if file === nothing
        error("No cached NEMDE case file for interval $t.\n" *
              "Expected a file named '$target' in $(m.cache_folder).\n" *
              "Download/unzip that day's NemSpdOutputs_*_loaded.zip (see " *
              "MANUAL_DOWNLOAD.md), or call populate_by_day! for that date.")
    end
    m.doc = EzXML.readxml(file)
    m.loaded_file = basename(file)
    return m
end

"""
    xml_is_ocd(m) -> Bool

True when the interval's case file is the over-constrained-dispatch (OCD) rerun
variant. Mirrors nempy's `is_over_constrained_dispatch_rerun`, which checks for
'OCD' in the loaded FILE NAME (AEMO only publishes an `_OCD` case file when the
rerun process was actually used).
"""
xml_is_ocd(m::XMLCacheManager) = occursin("OCD", m.loaded_file)

"""
    xml_is_intervention(m) -> Bool

True when the interval was subject to an AEMO intervention (the case file then
carries TWO PeriodSolution elements: intervention and what-if). Mirrors nempy's
`is_intervention_period`. During interventions the pricing (what-if) run uses
the `WhatIf*` initial conditions.
"""
function xml_is_intervention(m::XMLCacheManager)
    m.doc === nothing && return false
    root = EzXML.root(m.doc)
    return length(findall("//*[local-name()='PeriodSolution']", root)) > 1
end

# Fallback: scan the cache (recursively) for the interval's case file. Matches
# the canonical name first, then any file containing the YYYYMMDDNNN stem, so
# the primary `.loaded` file is preferred over its `_OCD.loaded` rerun variant.
function _search_cache(m::XMLCacheManager, t::DateTime)
    market_day, n = _interval_number(t)
    ymd = Dates.format(market_day, dateformat"yyyymmdd")
    stem = "NEMSPDOutputs_$(ymd)$(lpad(n, 3, '0'))"      # without the trailing 00
    best = nothing
    for (root, _, fs) in walkdir(m.cache_folder)
        for f in fs
            occursin(stem, f) || continue
            p = joinpath(root, f)
            # Prefer the non-OCD primary file.
            if !occursin("_OCD", f)
                return p
            end
            best = something(best, p)
        end
    end
    return best
end

# -----------------------------------------------------------------------------
# Low-level XML extraction helpers.
#
# We use XPath via EzXML to pull <Trade> elements and trader initial
# conditions. Attribute access tolerates missing attributes (returns missing).
# -----------------------------------------------------------------------------
_attr(node, name) = haskey(node, name) ? node[name] : missing
_attrf(node, name) = (v = _attr(node, name); ismissing(v) ? missing : parse(Float64, v))

"""
    xml_trader_periods(m) -> Vector{EzXML.Node}

Return all `TraderPeriod` nodes (one per unit with offers) for the loaded
interval. These carry the `TradeCollection` of 10-band bids per service.
"""
function xml_trader_periods(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    # The TraderPeriod nodes live under NemSpdInputs/PeriodCollection.
    return findall("//*[local-name()='TraderPeriod']", root)
end

"""
    xml_trade_prices(m) -> Dict{Tuple{String,String},Vector{Float64}}

Extract the 10 PRICE bands per (TraderID, TradeType). In the NEMDE XML prices
are NOT on the period `Trade` element (which only holds the `BandAvail` volumes)
— they live under each trader's price structure:

    TraderCollection/Trader[@TraderID]/TradePriceStructureCollection/
      TradePriceStructure/TradeTypePriceStructureCollection/
        TradeTypePriceStructure[@TradeType, @PriceBand1..@PriceBand10]

Returns a lookup keyed by (unit, NEMDE TradeType code) → [price1 … price10].
"""
function xml_trade_prices(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    out = Dict{Tuple{String,String},Vector{Float64}}()
    for ps in findall("//*[local-name()='TradeTypePriceStructure']", root)
        ttype = _attr(ps, "TradeType")
        ismissing(ttype) && continue
        # Walk up to the owning <Trader> to get its TraderID.
        trader = findfirst("ancestor::*[local-name()='Trader']", ps)
        trader === nothing && continue
        duid = _attr(trader, "TraderID")
        ismissing(duid) && continue
        prices = [coalesce(_attrf(ps, "PriceBand$i"), 0.0) for i in 1:10]
        out[(duid, ttype)] = prices
    end
    return out
end

"""
    xml_violation_prices(m) -> Dict{String,Float64}

Read the constraint VIOLATION PRICES (in `\$/MW`) that NEMDE used for this interval
from the case-solution element of the XML. nempy reads these same attributes;
they map to the soft-constraint slack penalties in the optimiser. Each must be
well above the market price cap so constraints are respected. Returns whatever is
present; callers merge over the [`CVP_FACTORS`](@ref) fallbacks.

Attribute map (NEMDE @attr -> NempyJL key):
  @EnergyDeficitPrice -> regional_demand   @InterconnectorPrice -> interconnector
  @GenericConstraintPrice -> generic_constraint  @RampRatePrice -> ramp_rate
  @CapacityPrice -> unit_capacity   @UIGFSurplusPrice -> uigf
  @ASMaxAvailPrice -> fcas_max_avail   @ASProfilePrice -> fcas_profile
  @FastStartPrice -> fast_start   @VoLL -> voll   @TieBreakPrice -> tiebreak
"""
function xml_violation_prices(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    # The case-solution element is the one carrying @VoLL.
    node = findfirst("//*[@VoLL]", root)
    node === nothing && return Dict{String,Float64}()
    attrmap = (
        "regional_demand"    => "EnergyDeficitPrice",
        "interconnector"     => "InterconnectorPrice",
        "generic_constraint" => "GenericConstraintPrice",
        "ramp_rate"          => "RampRatePrice",
        "unit_capacity"      => "CapacityPrice",
        "uigf"               => "UIGFSurplusPrice",
        "fcas_max_avail"     => "ASMaxAvailPrice",
        "fcas_profile"       => "ASProfilePrice",
        "fast_start"         => "FastStartPrice",
        "voll"               => "VoLL",
        "tiebreak"           => "TieBreakPrice",
    )
    out = Dict{String,Float64}()
    for (k, a) in attrmap
        v = _attrf(node, a)
        ismissing(v) || (out[k] = v)
    end
    return out
end

"""
    xml_generic_constraints(m) -> (constraints, trader, interconnector, region)

Extract the GENERIC (network / security / FCAS-requirement) constraints that
NEMDE actually invoked for this interval, straight from the case file. These are
the constraints that set most NEM regional prices — omitting them is why an
unconstrained merit-order model under-prices and shows no regional separation.

Real XML hierarchy (verified against nempy's xml_cache navigation):

  NEMSPDCaseFile
  ├── NemSpdInputs
  │   └── GenericConstraintCollection
  │       └── GenericConstraint  @ConstraintID @Type(LE/GE/EQ) @ViolationPrice
  │           └── LHSFactorCollection
  │               ├── TraderFactor        @TraderID @TradeType @Factor
  │               ├── InterconnectorFactor @InterconnectorID @Factor
  │               └── RegionFactor        @RegionID @TradeType @Factor
  └── NemSpdOutputs
      └── PeriodSolution
          └── ConstraintSolution  @ConstraintID @RHS @Intervention

TWO things that previously broke this:
  1. RHS must come from ConstraintSolution (the solved RHS for the interval),
     filtered to @Intervention == '0' (the non-intervention pricing run that ROP
     is taken from) — NOT from the inputs GenericConstraint (which has no @RHS).
  2. The factor elements live INSIDE each GenericConstraint and do not carry
     their own @ConstraintID, so they must be read as descendants of their
     parent constraint, inheriting that constraint's id.

Returns four tidy `DataFrame`s:
  constraints : set, rhs, type, violation_price   (only invoked constraints)
  trader      : set, unit, service, factor
  interconnector : set, interconnector, factor
  region      : set, region, service, factor
"""
function xml_generic_constraints(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)

    # (1) RHS for each invoked constraint, from the non-intervention solution.
    rhs_map = Dict{String,Float64}()
    for cs in findall("//*[local-name()='ConstraintSolution']", root)
        interv = _attr(cs, "Intervention")
        (ismissing(interv) || interv == "0") || continue   # keep Intervention 0
        cid = _attr(cs, "ConstraintID"); ismissing(cid) && continue
        r = _attrf(cs, "RHS"); ismissing(r) && continue
        rhs_map[cid] = r
    end

    crows = NamedTuple[]; trows = NamedTuple[]; irows = NamedTuple[]; rrows = NamedTuple[]
    # (2) Walk the constraint DEFINITIONS; emit only those that were invoked
    #     (present in rhs_map). Factors are descendants of each constraint node.
    for gc in findall("//*[local-name()='GenericConstraint']", root)
        cid = _attr(gc, "ConstraintID"); ismissing(cid) && continue
        haskey(rhs_map, cid) || continue
        push!(crows, (
            set = cid,
            rhs = rhs_map[cid],
            type = coalesce(_attr(gc, "Type"), "LE"),        # LE / GE / EQ
            violation_price = coalesce(_attrf(gc, "ViolationPrice"), 0.0),
        ))
        for f in findall(".//*[local-name()='TraderFactor']", gc)
            tt = _attr(f, "TradeType")
            service = ismissing(tt) ? "energy" : get(TRADE_TYPE_TO_SERVICE, tt, "energy")
            push!(trows, (set=cid, unit=coalesce(_attr(f, "TraderID"), ""),
                          service=service, factor=coalesce(_attrf(f, "Factor"), 0.0)))
        end
        for f in findall(".//*[local-name()='InterconnectorFactor']", gc)
            push!(irows, (set=cid, interconnector=coalesce(_attr(f, "InterconnectorID"), ""),
                          factor=coalesce(_attrf(f, "Factor"), 0.0)))
        end
        for f in findall(".//*[local-name()='RegionFactor']", gc)
            tt = _attr(f, "TradeType")
            service = ismissing(tt) ? "energy" : get(TRADE_TYPE_TO_SERVICE, tt, "energy")
            push!(rrows, (set=cid, region=coalesce(_attr(f, "RegionID"), ""),
                          service=service, factor=coalesce(_attrf(f, "Factor"), 0.0)))
        end
    end

    cdf(rows, cols) = isempty(rows) ? DataFrame([c => Float64[] for c in cols]...) : DataFrame(rows)
    return (cdf(crows, [:set, :rhs, :type, :violation_price]),
            cdf(trows, [:set, :unit, :service, :factor]),
            cdf(irows, [:set, :interconnector, :factor]),
            cdf(rrows, [:set, :region, :service, :factor]))
end

"""
    xml_loss_model(m::XMLCacheManager) -> Dict{String,NamedTuple}

NEMDE's OWN per-interval interconnector loss model, keyed by interconnector:
`(lower_limit, share, segments)` where `segments` is a vector of
`(limit_mw, factor)` pairs.

The case file carries the loss model NEMDE actually solved with:

    <Interconnector InterconnectorID="V-SA">
      <LossModel LossLowerLimit="1051" LossShare="0.82" ...>
        <SegmentCollection>
          <Segment Limit="-1043" Factor="-0.1234"/> ...

`Factor` is the MARGINAL loss (dLoss/dFlow) on the segment ending at `Limit`,
and the segments already incorporate that interval's demand-dependent term — so
the loss curve is the integral of the factors anchored at ZERO flow, with NO
further demand adjustment. Reconstructing this way reproduces NEMDE's published
`InterconnectorSolution/@Losses` EXACTLY (verified to 5 decimals on all six
interconnectors across intervals in both July-2024 and September-2025), whereas
re-deriving the linear term from the MMS demand coefficients leaves a purely
linear error — measured at 0.014 MW per MW of flow on V-SA, i.e. up to 14.8 MW.

`LossModelID` is a version stamp shared by every interconnector in the file, so
the models MUST be read as children of their parent `Interconnector` element,
not looked up by that id.
"""
function xml_loss_model(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    out = Dict{String,NamedTuple}()
    for lm in findall("//*[local-name()='LossModel']", root)
        icn = findfirst("ancestor::*[local-name()='Interconnector']", lm)
        icn === nothing && continue
        icid = _attr(icn, "InterconnectorID"); ismissing(icid) && continue
        segs = Tuple{Float64,Float64}[]
        for s in findall(".//*[local-name()='Segment']", lm)
            lim = _attrf(s, "Limit"); fac = _attrf(s, "Factor")
            (ismissing(lim) || ismissing(fac)) && continue
            push!(segs, (float(lim), float(fac)))
        end
        isempty(segs) && continue
        sort!(segs; by = first)
        out[String(icid)] = (lower_limit = -coalesce(_attrf(lm, "LossLowerLimit"), 0.0),
                             share       = coalesce(_attrf(lm, "LossShare"), 0.5),
                             segments    = segs)
    end
    return out
end

"""
    xml_loss_at(model, flow) -> Float64

Loss (MW) at `flow` from an `xml_loss_model` entry: the integral of the segment
factors from zero flow to `flow`.
"""
function xml_loss_at(model, flow::Real)
    upto(z) = begin
        s = 0.0; x = model.lower_limit
        for (lim, fac) in model.segments
            z <= x && break
            hi = min(z, lim)
            hi > x && (s += fac * (hi - x))
            x = lim
        end
        s
    end
    return upto(float(flow)) - upto(0.0)
end

"""
    xml_mnsp_offers(m) -> Dict{Tuple{String,String},NamedTuple}

Parse the MNSP (market network service provider) OFFERS for the interval.
An MNSP interconnector is a MARKET PARTICIPANT: its owner bids the link's
capacity in ten price/volume bands per region, and NEMDE clears those bids
exactly like a generator's. Without them an MNSP flows freely to its
registered MAXCAPACITY on inter-regional spread alone, which over-states
flow and collapses the price separation the bids create.

XML layout:
  NemSpdInputs/PeriodCollection/Period/InterconnectorPeriodCollection/
    InterconnectorPeriod[@InterconnectorID, @MNSP=1]/MNSPOfferCollection/
      MNSPOffer[@RegionID, @MaxAvail, @BandAvail1..10, @RampUpRate, @RampDnRate]
  NemSpdInputs/InterconnectorCollection/Interconnector/
    MNSPPriceStructureCollection/MNSPPriceStructure/
      MNSPRegionPriceStructureCollection/
        MNSPRegionPriceStructure[@RegionID, @PriceBand1..10]

Returns (interconnector, region) => (max_avail, bands, prices, ramp_up, ramp_down).
"""
function xml_mnsp_offers(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    prices = Dict{Tuple{String,String},Vector{Float64}}()
    for ps in findall("//*[local-name()=\'MNSPRegionPriceStructure\']", root)
        rg = _attr(ps, "RegionID"); ismissing(rg) && continue
        icn = findfirst("ancestor::*[local-name()=\'Interconnector\']", ps)
        icn === nothing && continue
        icid = _attr(icn, "InterconnectorID"); ismissing(icid) && continue
        prices[(String(icid), String(rg))] =
            [coalesce(_attrf(ps, "PriceBand$i"), 0.0) for i in 1:N_BANDS]
    end
    out = Dict{Tuple{String,String},NamedTuple}()
    for off in findall("//*[local-name()=\'MNSPOffer\']", root)
        rg = _attr(off, "RegionID"); ismissing(rg) && continue
        ipn = findfirst("ancestor::*[local-name()=\'InterconnectorPeriod\']", off)
        ipn === nothing && continue
        icid = _attr(ipn, "InterconnectorID"); ismissing(icid) && continue
        k = (String(icid), String(rg))
        out[k] = (max_avail = coalesce(_attrf(off, "MaxAvail"), 0.0),
                  bands = [coalesce(_attrf(off, "BandAvail$i"), 0.0) for i in 1:N_BANDS],
                  prices = get(prices, k, zeros(N_BANDS)),
                  ramp_up = _attrf(off, "RampUpRate"),
                  ramp_down = _attrf(off, "RampDnRate"))
    end
    return out
end

"""
    xml_initial_conditions(m) -> DataFrame

Extract per-unit NEMDE initial conditions. nempy reads these InitialConditionID
values: INITIALMW (the unit's MW output at the start of the interval, used for
ramp limits), RAMPUPRATE / RAMPDOWNRATE (the telemetered SCADA ramp rates,
MW/min) and AGCSTATUS. Mirrors nempy's `get_unit_initial_conditions`.
"""
function xml_initial_conditions(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    traders = findall("//*[local-name()='Trader']", root)
    # During interventions the pricing (ROP) run uses the what-if initial MW.
    init_id = xml_is_intervention(m) ? "WHATIFINITIALMW" : "INITIALMW"
    rows = NamedTuple[]
    for tr in traders
        duid = _attr(tr, "TraderID")
        ismissing(duid) && continue
        ic = Dict{String,Float64}()
        # NOTE: the element is TraderInitialCondition (SINGULAR), nested in a
        # TraderInitialConditionCollection.
        for cond in findall(".//*[local-name()='TraderInitialCondition']", tr)
            id = _attr(cond, "InitialConditionID")
            val = _attrf(cond, "Value")
            (ismissing(id) || ismissing(val)) && continue
            ic[uppercase(id)] = val
        end
        # nempy's InitialConditionID mapping: INITIALMW='InitialMW' (or
        # 'WhatIfInitialMW' during interventions), RAMPUPRATE='SCADARampUpRate',
        # RAMPDOWNRATE='SCADARampDnRate', AGCSTATUS='AGCStatus'.
        # SCADA ramp rates are in MW/h (like the bid @RampUpRate) — verified
        # against nempy which applies rate*(dispatch_interval/60) windows.
        push!(rows, (
            unit = duid,
            trader_type = coalesce(_attr(tr, "TraderType"), ""),
            initial_mw = get(ic, init_id, get(ic, "INITIALMW", missing)),
            # HMW/LMW: telemetered High/Low MW operating limits. These are the
            # AGC ENABLEMENT window for regulation FCAS (the energy range over
            # which the reg trapezium is valid) — the XML equivalent of
            # DISPATCHLOAD's RAISEREG/LOWERREG ENABLEMENTMAX/MIN, but present
            # for far more units (343 vs 111 in 2025-09). NOT dispatch caps:
            # verified 98 units cleared ABOVE their HMW in 2025-09-10 09:00.
            hmw = get(ic, "HMW", missing),
            lmw = get(ic, "LMW", missing),
            scada_ramp_up = get(ic, "SCADARAMPUPRATE", missing),   # MW/h
            scada_ramp_down = get(ic, "SCADARAMPDNRATE", missing), # MW/h
            agc_status = get(ic, "AGCSTATUS", 0.0),
        ))
    end
    return DataFrame(rows)
end

"""
    xml_fast_start_parameters(m) -> DataFrame

Per-unit fast-start dispatch-inflexibility-profile parameters, read from the
Trader attributes `@MinLoadingMW @CurrentMode @CurrentModeTime @T1..@T4`.
`@WhatIfCurrentMode(Time)` overrides apply when present (mirrors nempy's
`get_unit_fast_start_parameters`). Only traders WITH a @CurrentMode attribute
(i.e. fast-start units) are returned.
"""
function xml_fast_start_parameters(m::XMLCacheManager)
    m.doc === nothing && error("No interval loaded; call load_interval! first.")
    root = EzXML.root(m.doc)
    rows = NamedTuple[]
    for tr in findall("//*[local-name()='Trader']", root)
        duid = _attr(tr, "TraderID")
        (ismissing(duid) || ismissing(_attr(tr, "CurrentMode"))) && continue
        cm  = _attrf(tr, "WhatIfCurrentMode");     ismissing(cm)  && (cm  = _attrf(tr, "CurrentMode"))
        cmt = _attrf(tr, "WhatIfCurrentModeTime"); ismissing(cmt) && (cmt = _attrf(tr, "CurrentModeTime"))
        push!(rows, (
            unit = duid,
            min_loading = coalesce(_attrf(tr, "MinLoadingMW"), 0.0),
            current_mode = Int(coalesce(cm, 0.0)),
            time_in_current_mode = coalesce(cmt, 0.0),
            mode_one_length   = coalesce(_attrf(tr, "T1"), 0.0),
            mode_two_length   = coalesce(_attrf(tr, "T2"), 0.0),
            mode_three_length = coalesce(_attrf(tr, "T3"), 0.0),
            mode_four_length  = coalesce(_attrf(tr, "T4"), 0.0),
        ))
    end
    return isempty(rows) ? DataFrame(unit=String[], min_loading=Float64[], current_mode=Int[],
                                     time_in_current_mode=Float64[], mode_one_length=Float64[],
                                     mode_two_length=Float64[], mode_three_length=Float64[],
                                     mode_four_length=Float64[]) : DataFrame(rows)
end
