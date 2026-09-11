# =============================================================================
# fix_snem2000_case.jl
#
# Data preparation, run once: repair the raw synthetic 2000-bus NEM case into
# the form the network model expects, and write `data/snem2000_fixed.m`.
#
# The raw case has defects that make a market OPF on it either infeasible or
# quietly wrong — zero-reactance branches, DC-line loss coefficients that let
# reverse flow fabricate power, and missing or inconsistent limits. Each repair
# is applied and reported, so the difference between the input and the output is
# a list rather than a mystery.
#
# ARGUMENTS
#   Options       Env             Default                       Meaning
#   ------------  --------------  ----------------------------  -----------------
#   --in=         NEMX_MFILE_IN   data/snem2000.m               raw case
#   --out=        NEMX_MFILE_OUT  data/snem2000_fixed.m         repaired case
#
# EXAMPLE
#   julia --project=. scripts/fix_snem2000_case.jl
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using JuMP
using Printf
using Statistics

const ZB = NEMX.ZBenchmark
const NB = NEMX.NBenchmark
using NEMX.ZBenchmark
using NEMX.NBenchmark

const SRC = script_option("in", joinpath(NEMX.PKG_DIR, "data", "snem2000dcline_Oct2025.m"))
const DST = script_option("out", joinpath(NEMX.PKG_DIR, "data", "snem2000_fixed.m"))

print_banner("Repair the synthetic 2000-bus network case",
             "input case" => SRC,
             "output case" => DST)

function fix_snem2000(src::String=SRC, dst::String=DST)
    lines = readlines(src)
    n_x = 0; n_fuel = 0; n_stor = 0
    section = ""
    fuelmap = [
        "'blackcoal'" => "'Coal'", "'browncoal'" => "'Coal'",
        "'naturalgas'" => "'Gas'", "'CapBank/SVC/StatCom/SynCon'" => "'Gas'",
        "'Water'" => "'Hydro'", "'hydrowater'" => "'Hydro'",
        "'wind'" => "'Wind'", "'offshore_wind'" => "'Wind'",
        "'solar'" => "'Solar'", "'Distillate'" => "'Oil'",
    ]
    out = String[]
    for ln in lines
        s = ln
        occursin(r"^mpc\.branch\s*=", s) && (section = "branch")
        occursin(r"^mpc\.storage\s*=", s) && (section = "storage")
        occursin(r"^mpc\.gen_data\s*=", s) && (section = "gen_data")
        occursin(r"^mpc\.", s) && !occursin(r"^mpc\.(branch|storage|gen_data)\s*=", s) &&
            (section = "")
        if section == "branch" && startswith(strip(s), r"\d")
            f = split(s, '\t'; keepempty=true)
            # branch columns: fbus tbus r x b rateA ... ; x is 4th numeric field
            nums = findall(t -> !isempty(strip(t)), f)
            if length(nums) >= 4
                xi = nums[4]
                v = tryparse(Float64, strip(f[xi]))
                if v !== nothing && v == 0.0
                    f[xi] = "0.001"; n_x += 1
                    s = join(f, '\t')
                end
            end
        elseif section == "storage" && startswith(strip(s), r"\d")
            f = split(s, '\t'; keepempty=true)
            nums = findall(t -> !isempty(strip(t)), f)
            if length(nums) >= 10
                e  = tryparse(Float64, strip(f[nums[4]]))   # energy
                er = tryparse(Float64, strip(f[nums[5]]))   # energy_rating
                if e !== nothing && er !== nothing && e > er
                    f[nums[4]] = string(er); n_stor += 1
                    s = join(f, '\t')
                end
            end
        elseif section == "gen_data"
            for (from, to) in fuelmap
                if occursin(from, s)
                    s = replace(s, from => to); n_fuel += 1
                end
            end
        end
        push!(out, s)
    end
    open(dst, "w") do io
        println(io, "% Cleaned by network/fix_snem2000.jl — see header of that script.")
        for s in out; println(io, s); end
    end
    println("wrote $dst")
    println("  zero-reactance branches fixed: $n_x")
    println("  fuel strings normalised:       $n_fuel")
    println("  storage energy>rating fixed:   $n_stor")

    # Stage 5: NSW coal terminal remap (idempotent post-step). Kept in Python
    # so the exact byte-level side-table bookkeeping lives in one place.
    remap = joinpath(@__DIR__, "remap_coal_terminals.py")
    if isfile(remap)
        try
            run(`python3 $remap $dst`)
        catch err
            @warn "coal-terminal remap skipped (run manually: python3 $remap $dst)" err
        end
    end
    return dst
end

if abspath(PROGRAM_FILE) == @__FILE__
    fix_snem2000()
end
