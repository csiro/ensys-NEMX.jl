# =============================================================================
# network.jl
#
# MATPOWER case loading and the NEM-specific side tables (bus areas, DC links,
# participant metadata) that ride alongside it.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================


# ---------------------------------------------------------------------------
# Case loading and side tables
# ---------------------------------------------------------------------------
"Parse a `%column_names%` cell table (e.g. mpc.gen_data) from the .m file."
function _parse_side_table(mfile::String, table::String)
    txt = read(mfile, String)
    m = match(Regex("%column_names%\\s*([^\\n]*)\\n\\s*mpc\\.$table\\s*=\\s*\\{(.*?)\\n\\};", "s"), txt)
    m === nothing && return DataFrame()
    cols = split(strip(m.captures[1]))
    rows = Vector{Vector{Any}}()
    for ln in split(m.captures[2], '\n')
        s = strip(ln); isempty(s) && continue
        vals = Any[]
        for tok in eachmatch(r"'[^']*'|[^\s\t]+", s)
            t = tok.match
            push!(vals, startswith(t, "'") ? String(strip(t, '\'')) :
                        something(tryparse(Float64, t), String(t)))
        end
        length(vals) == length(cols) && push!(rows, vals)
    end
    df = DataFrame([Symbol(c) => [r[i] for r in rows] for (i, c) in enumerate(cols)]...)
    return df
end

"""
    load_network(mfile) -> (data, meta)

Parse the (fixed) snem2000 case with PowerModels and join the DUID/fuel/area
side tables. In-memory fallbacks replicate fix_snem2000.jl if the raw file is
used. `meta` carries gen_duid[i], storage rows, and per-area bus lists.
"""
function load_network(mfile::String)
    data = PM.parse_file(mfile; validate=false)
    for (i, br) in data["branch"]
        br["br_x"] == 0 && (br["br_x"] = 1e-3)
    end
    # DC-line loss sanity: the case ships loss1=0.8 on Murraylink/Directlink
    # (80% marginal losses). Under PM's model pf+pt = loss0+loss1*pf, reverse
    # flow then FABRICATES power (~700 MW free across the three links),
    # depressing coal below its down-ramp window. Cap marginal losses at 3%
    # (Basslink's own value) and drop the 1 MW standing loss.
    for (_, dc) in get(data, "dcline", Dict())
        dc["loss1"] > 0.05 && (dc["loss1"] = 0.03)
        dc["loss0"] = 0.0
    end
    PM.correct_network_data!(data)
    gd = _parse_side_table(mfile, "gen_data")
    sd = _parse_side_table(mfile, "storage_data")
    # gen index i (string) corresponds to gen_data row order = mpc.gen row order
    gen_duid = Dict{String,String}()
    gen_fuel = Dict{String,String}()
    if !isempty(gd) && "duid" in names(gd)
        order = sort(collect(keys(data["gen"])); by=x->data["gen"][x]["index"])
        for (k, gid) in enumerate(order)
            k > nrow(gd) && break
            gen_duid[gid] = String(gd.duid[k])
            gen_fuel[gid] = "fuel" in names(gd) ? String(gd.fuel[k]) : ""
        end
    end
    stor_duid = Dict{String,String}()
    if !isempty(sd) && "duid" in names(sd)
        order = sort(collect(keys(get(data, "storage", Dict()))); by=x->data["storage"][x]["index"])
        for (k, sid) in enumerate(order)
            k > nrow(sd) && break
            stor_duid[sid] = String(sd.duid[k])
        end
    end
    area_of_bus = Dict(b => Int(bus["area"]) for (b, bus) in data["bus"])
    return data, (gen_duid=gen_duid, gen_fuel=gen_fuel, stor_duid=stor_duid,
                  area_of_bus=area_of_bus)
end
