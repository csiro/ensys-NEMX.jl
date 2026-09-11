# =============================================================================
# mapping.jl
#
# Participant-to-bus mapping and interconnector tie-line grouping: how a market
# DUID is attached to the physical network, and which branches carry each NEM
# interconnector.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================


# ---------------------------------------------------------------------------
# Participant -> bus mapping (assumption A1-A4)
# ---------------------------------------------------------------------------
_normduid(s) = uppercase(replace(String(s), r"_\d+$" => "", "_" => ""))
_dmatch(a, b) = (a == b) || (length(a) >= 4 && length(b) >= 4 &&
                (startswith(a, b) || startswith(b, a)))

"""
    map_participants!(data, meta, mkt) -> mapping::DataFrame

Attach every market participant (unit, dispatch_type) to a network bus and
replace the synthetic generation fleet by market-driven injections:
DUID match first (within the participant's area), then placement at the
region's highest-voltage generator bus. Unmatched synthetic generators keep
only their reactive capability (A2); synthetic storage becomes injection
envelopes (A3); native loads are scaled to AEMO regional demand (A4).
Each market unit becomes a PowerModels gen component whose pg the market
layer drives; the returned mapping table records unit -> (gen id, bus, how).
"""
function map_participants!(data::Dict, meta, mkt; hard_down::Bool=true)
    base = data["baseMVA"]
    # -- candidate network anchors by normalised duid ------------------------
    anchors = Dict{String,Tuple{String,String}}()   # normduid -> (kind, id)
    for (gid, d) in meta.gen_duid; anchors[_normduid(d)] = ("gen", gid); end
    for (sid, d) in meta.stor_duid; anchors[_normduid(d)] = ("storage", sid); end

    # EXTRA_ANCHORS: market DUIDs with NO synthetic generator of their own but
    # whose real network terminal is known — pinned directly (takes precedence
    # over size-rank). Added with the coal-terminal remap
    # (network/scripts/remap_coal_terminals.py): ER04 shares Eraring's bus-555
    # terminal with ER03, because the synthetic case carries a single combined
    # 'ERO3, ERO4' generator there rather than one gen per unit.
    EXTRA_ANCHORS = Dict{String,Int}("ER04" => 555)

    # region -> fallback bus: highest-baseKV bus hosting a synthetic gen
    # (bus_type 2/3 respected; vm/va left as given by the case).
    fallback = Dict{String,Int}()
    best = Dict{String,Tuple{Float64,Int}}()
    for (gid, g) in data["gen"]
        b = string(g["gen_bus"]); bus = data["bus"][b]
        r = get(REGION_OF_AREA, Int(bus["area"]), "")
        r == "" && continue
        kv = float(bus["base_kv"])
        if Int(bus["bus_type"]) in (2, 3) && (!haskey(best, r) || kv > best[r][1])
            best[r] = (kv, Int(g["gen_bus"]))
        end
    end
    for (r, t) in best; fallback[r] = t[2]; end

    used = Set{String}()                 # synthetic gens consumed by a match
    rows = NamedTuple[]
    caps = Dict((string(r.unit), string(r.dispatch_type)) =>
                coalesce(r.capacity, 0.0) for r in eachrow(mkt.avail))
    uigf = Dict(string(r.unit) => coalesce(r.capacity, 0.0) for r in eachrow(mkt.uigf))
    # HARD injection envelope = the ENERGY BAND VOLUME SUM (the only truly hard
    # bound in the market model). MaxAvail/UIGF remain SOFT overlay constraints;
    # sizing pmax from MaxAvail pre-empts their CVP escape and forces expensive
    # ramp violations instead (observed: ER02 bid MaxAvail 410 below its 675 MW
    # initial output — NEMDE rides the cheaper capacity violation down-ramp).
    bandsum = Dict{Tuple{String,String},Float64}()
    for r in eachrow(mkt.vb)
        string(r.service) == "energy" || continue
        k = (string(r.unit), string(r.dispatch_type))
        bandsum[k] = get(bandsum, k, 0.0) + sum(coalesce(r[c], 0.0) for c in BAND_COLS)
    end
    next = maximum(g["index"] for g in values(data["gen"])) + 1

    # Per-area synthetic anchor pool for SIZE-RANKED placement of units without
    # a DUID match: spreading the fleet across the synthetic generator sites
    # (largest market unit -> largest synthetic site, cycling) preserves the
    # network's geographic generation pattern; a single fallback bus per region
    # is electrically impossible for multi-GW fleets.
    pool = Dict{Int,Vector{Tuple{Float64,Int,String}}}()  # area => (pmax, bus, gid) desc
    for gid in sort(collect(keys(data["gen"])); by=x->parse(Int, x))   # deterministic
        haskey(meta.gen_duid, gid) || continue
        g = data["gen"][gid]
        b = data["bus"][string(g["gen_bus"])]
        push!(get!(pool, Int(b["area"]), []), (float(g["pmax"]), Int(g["gen_bus"]), gid))
    end
    # De-duplicate the pool BY BUS (keep the largest synthetic gen per bus):
    # a site hosting several synthetic units (e.g. Bayswater's 4 gens on one
    # 23 kV bus) otherwise appears 4x at the top of the ranking, so the 4
    # largest unmatched market units all size-rank onto that single bus,
    # recreating the very throughput pile-up this pass is meant to avoid.
    # Cycling over DISTINCT buses spreads large unmatched units geographically.
    for a in keys(pool)
        sort!(pool[a]; rev=true)
        seen = Set{Int}(); dedup = Tuple{Float64,Int,String}[]
        for e in pool[a]
            e[2] in seen && continue
            push!(seen, e[2]); push!(dedup, e)
        end
        pool[a] = dedup
    end
    pool_pos = Dict{Int,Int}(a => 0 for a in keys(pool))

    # BDU set (both directions present) for reactive-capability assignment.
    dtcount = Dict{String,Set{String}}()
    for r in eachrow(mkt.unit_info)
        push!(get!(dtcount, string(r.unit), Set{String}()), string(r.dispatch_type))
    end
    mkt_bdu_units = Set(u for (u, s) in dtcount if length(s) > 1)
    # Initial MW: prefer the BID-table initial (present for every unit with an
    # energy offer); the SCADA table misses non-telemetered units and a 0.0
    # default there silently collapsed their scaled availability to up*5/60.
    init0 = Dict(string(r.unit) => coalesce(r.initial_output, 0.0)
                 for r in eachrow(mkt.scada))
    for r in eachrow(mkt.ramp)
        ismissing(r.initial_output) && continue
        init0[string(r.unit)] = coalesce(r.initial_output, 0.0)
    end
    # Effective UP ramp rate (min of bid and SCADA, MW/h) for NEMDE-style
    # availability scaling of the HARD upper bound: NEMDE pre-processes energy
    # availability to min(MaxAvail-side caps, initial + ramp_up*5/60); doing
    # the same on pmax removes the spurious up-ramp CVP spikes seen in lossy
    # formulations (loss supply pushed units past their 5-min windows).
    # ZERO ramp rates are respected (unit frozen at its initial MW, e.g.
    # TARRALEA) — only MISSING rates leave the bound at the band envelope.
    scada_up = Dict(string(r.unit) => r.scada_ramp_up_rate for r in eachrow(mkt.scada))
    scada_dn = Dict(string(r.unit) => r.scada_ramp_down_rate for r in eachrow(mkt.scada))
    eff_up = Dict{Tuple{String,String},Union{Missing,Float64}}()
    eff_dn = Dict{Tuple{String,String},Union{Missing,Float64}}()
    for r in eachrow(mkt.ramp)
        bu = r.ramp_up_rate; su = get(scada_up, string(r.unit), missing)
        bd = r.ramp_down_rate; sd = get(scada_dn, string(r.unit), missing)
        # A10 (revised): ZERO or ABSENT rates are treated as UNLIMITED, i.e.
        # the ramp window equals the availability envelope. This deviates from
        # the copper-plate benchmark (which freezes zero-ramp units, faithfully
        # to nempy) and un-strands units like TARRALEA whose frozen initial sat
        # 0.2 MW above their bid availability.
        # ZERO rates are kept (frozen-unit semantics, as nempy/NEMDE);
        # A10: only ABSENT rates mean "window = availability envelope".
        # Frozen units get pinned to min(initial, MaxAvail) below so the
        # benchmark-faithful 0.2 MW capacity slack cannot arise here.
        eff_up[(string(r.unit), string(r.dispatch_type))] =
            ismissing(su) ? bu : (ismissing(bu) ? su : min(bu, su))
        eff_dn[(string(r.unit), string(r.dispatch_type))] =
            ismissing(sd) ? bd : (ismissing(bd) ? sd : min(bd, sd))
    end

    # First pass: DUID matches. Second pass handles the rest size-ranked.
    pending = NamedTuple[]
    for r in eachrow(mkt.unit_info)
        un = string(r.unit); dt = string(r.dispatch_type); reg = string(r.region)
        area = get(AREA_OF_REGION, reg, 0)
        cap = max(get(bandsum, (un, dt), 0.0),
                  get(caps, (un, dt), 0.0), get(uigf, un, 0.0), 1.0)
        nd = _normduid(un)
        how = ""; bus = 0; anchor = ""
        hit = get(anchors, nd, nothing)
        if hit === nothing
            for (d, kid) in anchors
                _dmatch(nd, d) || continue
                bid = kid[1] == "gen" ? data["gen"][kid[2]]["gen_bus"] :
                                        data["storage"][kid[2]]["storage_bus"]
                Int(data["bus"][string(bid)]["area"]) == area || continue
                hit = kid; break
            end
        else
            bid = hit[1] == "gen" ? data["gen"][hit[2]]["gen_bus"] :
                                    data["storage"][hit[2]]["storage_bus"]
            Int(data["bus"][string(bid)]["area"]) == area || (hit = nothing)
        end
        if hit !== nothing
            bus = hit[1] == "gen" ? Int(data["gen"][hit[2]]["gen_bus"]) :
                                    Int(data["storage"][hit[2]]["storage_bus"])
            how = "duid:" * hit[1]; anchor = hit[2]
            hit[1] == "gen" && push!(used, hit[2])
            push!(pending, (un=un, dt=dt, reg=reg, cap=cap, bus=bus, how=how, anchor=anchor))
        else
            ob = get(EXTRA_ANCHORS, uppercase(un), 0)
            if ob != 0 && haskey(data["bus"], string(ob)) &&
               Int(data["bus"][string(ob)]["area"]) == area
                push!(pending, (un=un, dt=dt, reg=reg, cap=cap, bus=ob,
                                how="override", anchor=""))
            else
                push!(pending, (un=un, dt=dt, reg=reg, cap=cap, bus=0, how="", anchor=""))
            end
        end
    end
    # size-ranked assignment of the unmatched (largest first)
    unmatched = sort([p for p in pending if p.bus == 0]; by=p -> -p.cap)
    assigned = Dict{Tuple{String,String},Tuple{Int,String,String}}()
    for p in unmatched
        area = get(AREA_OF_REGION, p.reg, 0)
        pl = get(pool, area, Tuple{Float64,Int,String}[])
        if isempty(pl)
            b = get(fallback, p.reg, 0)
            assigned[(p.un, p.dt)] = (b, "fallback", "")
        else
            pool_pos[area] = pool_pos[area] % length(pl) + 1
            e = pl[pool_pos[area]]
            assigned[(p.un, p.dt)] = (e[2], "size-rank", e[3])
        end
    end
    for p0 in pending
        un = p0.un; dt = p0.dt; reg = p0.reg; cap = p0.cap
        bus = p0.bus; how = p0.how; anchor = p0.anchor
        if bus == 0
            bus, how, anchor = get(assigned, (un, dt), (get(fallback, reg, 0), "fallback", ""))
        end
        bus == 0 && continue
        # market unit becomes a PM gen; load sides get a negative envelope.
        # Reactive capability: >=39.5% of active for generators; batteries
        # (storage-anchored or BDU) can swing 100% of active into reactive.
        gid = string(next); next += 1
        # NER S5.2.5.1 automatic access standard: reactive capability of at
        # least 39.5% of Pmax for all new generators; batteries can swing 100%.
        is_batt = startswith(how, "duid:storage") || un in mkt_bdu_units
        # Hard upper bound after NEMDE-style ramp-availability scaling
        # (generators only): pmax = min(band envelope, max(init,0) + up*5/60).
        # The DOWN side stays a SOFT ramp constraint, so bid-below-initial
        # situations (e.g. ER02) resolve through the cheaper capacity CVP
        # exactly as in the copper-plate benchmark. ZERO ramp rates freeze the
        # unit at its initial MW (e.g. TARRALEA); only MISSING rates leave the
        # bound at the band envelope.
        # A10: a unit with NO ramp data gets a ramp window equal to its full
        # availability envelope (limit = availability), i.e. no extra bound.
        up_r = get(eff_up, (un, dt), missing)
        dn_r = get(eff_dn, (un, dt), missing)
        cap_hard = cap
        pmin_hard = 0.0
        # A10 (revised): a ZERO-ramp generator is frozen; pin BOTH bounds to
        # min(initial, bid MaxAvail) so it is stranded exactly as in the
        # benchmark BUT without incurring the capacity CVP (e.g. TARRALEA:
        # bounds = 66.2 = its MaxAvail instead of init 66.4).
        maxav = get(caps, (un, dt), missing)
        if dt != "load" && !ismissing(up_r) && !ismissing(dn_r) && up_r == 0 && dn_r == 0
            pin = max(get(init0, un, 0.0), 0.0)
            ismissing(maxav) || maxav <= 0 || (pin = min(pin, maxav))
            cap_hard = pin; pmin_hard = pin
        elseif dt != "load" && !ismissing(up_r) && up_r > 0
            cap_hard = clamp(max(get(init0, un, 0.0), 0.0) + up_r * TAU, 0.0, cap)
        end
        # Hard DOWN-ramp scaling, mirroring the upper bound: generators cannot
        # fall below init - dn*5/60 within the interval. This reproduces the
        # benchmark outcome for bid-below-initial units (e.g. ER02: hard floor
        # 659.6 + soft MaxAvail 410 -> capacity CVP violated, E = 659.6, same
        # optimum as the copper plate). CAVEAT: at very low demand the summed
        # floors could exceed demand+export capability and turn a soft ramp
        # violation into infeasibility — if a lossy run reports INFEASIBLE,
        # rebuild with pmin_hard forced to 0 (see comment) and rely on the
        # soft down-ramp constraint instead.
        # HARD down floors only for DC formulations; under lossy/voltage-
        # constrained formulations (ACP/SOC/QC) summed floors + I2R losses +
        # Q-limits can be jointly INFEASIBLE (observed) — there the down-ramp
        # stays a SOFT constraint (NEMDE's own treatment) and the floor is 0.
        # A17: HARD down-floors are applied only when hard_down_ramp=true.
        # The floors were AUDITED and are individually correct (each below its
        # unit's MaxAvail) and collectively feasible (fleet forced minimum
        # 18.4 GW vs 25.5 GW demand — 7.1 GW of slack), so binding down-ramp
        # slack in a LOSSY formulation is a LOCATIONAL signal (power cannot be
        # evacuated from those buses), not a data error. Since NEMDE itself
        # treats ramp constraints as ELASTIC (CVP 20.2 M$/MW), the down-floor
        # is left SOFT by default for AC-family formulations so the solve stays
        # feasible and the violation is reported (named) instead of failing.
        if dt != "load" && !ismissing(dn_r) && dn_r > 0 && hard_down
            pmin_hard = clamp(max(get(init0, un, 0.0), 0.0) - dn_r * TAU, 0.0, cap_hard)
        end
        # Fuel/type inherited from the DUID-matched synthetic anchor so real
        # stations keep their fuel (ER01/ER02 -> Coal, TARRALEA -> Hydro).
        fuel = is_batt ? "Storage" :
               (anchor != "" && haskey(meta.gen_fuel, anchor) &&
                !isempty(meta.gen_fuel[anchor])) ? meta.gen_fuel[anchor] : "Other"
        gtype = get(Dict("Coal"=>"CT","Gas"=>"CC","Solar"=>"PV","Wind"=>"WT",
                         "Hydro"=>"HY","Storage"=>"BA","Biomass"=>"ST","Oil"=>"IC"),
                    fuel, "CC")
        # A12: reactive capability is sized from the unit's NAMEPLATE/offer
        # envelope (cap), NOT the ramp-scaled cap_hard, because synchronous
        # machines supply vars regardless of their 5-minute MW window. NER
        # S5.2.5.1 automatic access standard: +/-39.5% of Pmax; batteries and
        # BDUs (4-quadrant inverters) +/-100%. A floor of 5 MVAr keeps
        # zero-MW-envelope units (e.g. a unit bid to 0) numerically harmless.
        qr = max((is_batt ? 1.0 : 0.395) * cap, 5.0) / base
        # Warm start for NLP formulations (ACP/SOC/QC): start pg at the unit's
        # telemetered initial MW — cold starts are the main Ipopt risk here.
        pg0 = clamp(get(init0, un, 0.0), 0.0, cap_hard) / base
        dt == "load" && (pg0 = 0.0)
        # Full matpower/PowerModels field set so the mapped case remains valid
        # for load flow, OPF export (PM.export_matpower) and conversion to a
        # PowerSystems.jl System (name/fuel/type feed generator_mapping.yaml).
        data["gen"][gid] = Dict{String,Any}(
            "index"=>parse(Int, gid), "gen_bus"=>bus, "gen_status"=>1,
            "name"=>un * "_" * dt, "source_id"=>Any["gen", parse(Int, gid)],
            "fuel"=>fuel, "type"=>gtype,
            "pg"=>pg0, "qg"=>0.0, "vg"=>float(data["bus"][string(bus)]["vm"]),
            "mbase"=>base, "model"=>2, "ncost"=>2, "cost"=>[0.0, 0.0],
            "startup"=>0.0, "shutdown"=>0.0, "apf"=>0.0,
            "pc1"=>0.0, "pc2"=>0.0, "qc1min"=>0.0, "qc1max"=>0.0,
            "qc2min"=>0.0, "qc2max"=>0.0,
            "ramp_agc"=>0.0, "ramp_10"=>0.0, "ramp_30"=>0.0, "ramp_q"=>0.0,
            "pmin"=> dt == "load" ? -cap/base : pmin_hard/base,
            "pmax"=> dt == "load" ? 0.0 : cap_hard/base,
            "qmin"=>-qr, "qmax"=>qr,
            # Registered/nameplate MW this unit was sized from (audit aid).
            "registered_mw"=>cap)
        push!(rows, (unit=un, dispatch_type=dt, region=reg, gen_id=gid,
                     bus=bus, method=how, anchor=anchor, cap_mw=cap))
    end

    # A2: remove the synthetic generator fleet entirely — the market units
    # provide comparable reactive capability at the same buses (see header).
    # Buses that hosted only synthetic machines are downgraded PV->PQ so the
    # power flow has no setpoint without a source.
    market_buses = Set(rows_buses(rows))
    for gid in collect(keys(data["gen"]))
        haskey(meta.gen_duid, gid) || continue     # only original synthetics
        b = Int(data["gen"][gid]["gen_bus"])
        delete!(data["gen"], gid)
        if !(b in market_buses) && Int(data["bus"][string(b)]["bus_type"]) == 2
            data["bus"][string(b)]["bus_type"] = 1
        end
    end
    # A3: remove synthetic storage from the dispatch data entirely.
    haskey(data, "storage") && empty!(data["storage"])
    # A4: scale native loads to AEMO regional demand
    dsum = Dict(string(r.region) => float(r.demand) for r in eachrow(mkt.demand))
    tot = Dict{String,Float64}()
    for (_, ld) in data["load"]
        r = get(REGION_OF_AREA, Int(data["bus"][string(ld["load_bus"])]["area"]), "")
        tot[r] = get(tot, r, 0.0) + ld["pd"] * base
    end
    # A13: the raw snem2000 case contains 33 buses with NEGATIVE pd (embedded
    # generation netted into the load record). Scaling them amplifies the
    # negative injection and corrupts the regional total, so they are zeroed
    # BEFORE the scale factor is computed and the factor is re-derived from the
    # POSITIVE load only (regional totals still equal AEMO TOTALDEMAND).
    # Reactive demand is scaled by the same factor (constant power factor).
    for (_, ld) in data["load"]
        if ld["pd"] < 0
            ld["pd"] = 0.0; ld["qd"] = 0.0
        end
    end
    empty!(tot)
    for (_, ld) in data["load"]
        r = get(REGION_OF_AREA, Int(data["bus"][string(ld["load_bus"])]["area"]), "")
        tot[r] = get(tot, r, 0.0) + ld["pd"] * base
    end
    for (_, ld) in data["load"]
        r = get(REGION_OF_AREA, Int(data["bus"][string(ld["load_bus"])]["area"]), "")
        (haskey(dsum, r) && tot[r] > 0) || continue
        s = dsum[r] / tot[r]
        ld["pd"] *= s; ld["qd"] *= s
    end
    # A15: BOTH reference buses are RETAINED (130 mainland, 1123 Tasmania).
    # Tasmania is connected only through Basslink (a DC link), so it is an
    # ASYNCHRONOUS island needing its own angle reference; PowerModels' warning
    # about "multiple reference buses ... in the same connected component"
    # is a false positive here because calc_connected_components counts DC
    # links as connectivity while AC angle coupling does not flow through them.
    # (Demoting one to PV was tried and reverted: it would leave the Tasmanian
    # AC sub-network without a reference.)

    # A13b: 6 buses ship non-standard voltage bands (0.8-1.2) while the rest
    # use 0.9-1.1. Harmonise so AC/SOC/QC feasibility is not decided by a
    # handful of anomalously loose buses.
    for (_, b) in data["bus"]
        b["vmin"] = 0.9; b["vmax"] = 1.1
    end
    return DataFrame(rows)
end

rows_buses(rows) = ((r.bus for r in rows))

# Tie-line groups per NEM interconnector (assumption A5).
function _tie_groups(data, meta)
    groups = Dict{String,Vector{Tuple{String,String,Int,Int}}}()  # ic => [(kind,id,fbus,tbus)]
    pair_of = Dict((1,2)=>"VIC1-NSW1", (2,1)=>"VIC1-NSW1",
                   (1,3)=>"NSW1-QLD1", (3,1)=>"NSW1-QLD1",
                   (2,4)=>"V-SA",      (4,2)=>"V-SA")
    for (bid, br) in data["branch"]
        br["br_status"] == 0 && continue
        fa = Int(data["bus"][string(br["f_bus"])]["area"])
        ta = Int(data["bus"][string(br["t_bus"])]["area"])
        fa == ta && continue
        ic = get(pair_of, (fa, ta), nothing); ic === nothing && continue
        push!(get!(groups, ic, []), ("branch", bid, br["f_bus"], br["t_bus"]))
    end
    # dclines by MW rating (PM stores p.u.): 500 Basslink, 220 Murraylink,
    # 180 Directlink/Terranora.
    base = data["baseMVA"]
    for (did, dc) in get(data, "dcline", Dict())
        cap = abs(float(dc["pmaxf"])) * base
        ic = cap > 400 ? "T-V-MNSP1" : cap > 200 ? "V-S-MNSP1" : "N-Q-MNSP1"
        push!(get!(groups, ic, []), ("dcline", did, dc["f_bus"], dc["t_bus"]))
    end
    return groups
end

# Positive-direction reference of each NEM interconnector (from region ->).
const IC_FROM = Dict("VIC1-NSW1"=>2, "NSW1-QLD1"=>1, "V-SA"=>2,
                     "T-V-MNSP1"=>5, "V-S-MNSP1"=>2, "N-Q-MNSP1"=>1)
