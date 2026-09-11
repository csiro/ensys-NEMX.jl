# =============================================================================
# compare.jl
#
# `compare_formulations`: solve one interval under several power-flow
# formulations and tabulate the result.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================

"""
    compare_formulations(interval; forms, kwargs...) -> DataFrame

Run every requested formulation for one interval and tabulate objective,
losses, solve time and the five RRN prices, alongside the copper-plate
benchmark prices if `data/nempy_2024_07/bdu_prices_julia_fixed.csv` exists.
"""
function compare_formulations(interval::DateTime;
        forms::Vector{String}=["DCP", "DCP_MLF", "LPACC", "SOCWR", "QCRM", "ACP"],
        outfile::String="network_formulation_comparison.csv", kwargs...)
    mkt = load_market(interval; data_dir=get(kwargs, :data_dir, "./data/nempy_2024_07"))
    net = load_network(get(kwargs, :mfile, "./data/snem2000_fixed.m"))
    rows = DataFrame(formulation=String[], status=String[], objective=Float64[],
                     losses_mw=Float64[], solve_time_s=Float64[],
                     NSW1=Float64[], QLD1=Float64[], SA1=Float64[],
                     TAS1=Float64[], VIC1=Float64[])
    for f in forms
        @info "solving $f"
        r = try
            solve_network_dispatch(interval, f; mkt=mkt, net=net,
                                   (k => v for (k, v) in kwargs if k in (:mfile, :data_dir, :include_generic))...)
        catch err
            @warn "$f failed: $err"
            Dict{String, Any}("formulation" => f, "status" => "ERROR: $(typeof(err))")
        end
        if haskey(r, "objective")
            push!(rows, (f, r["status"], r["objective"], r["losses_mw"], r["solve_time"],
                         get(r["rrn_price"], "NSW1", NaN), get(r["rrn_price"], "QLD1", NaN),
                         get(r["rrn_price"], "SA1", NaN), get(r["rrn_price"], "TAS1", NaN),
                         get(r["rrn_price"], "VIC1", NaN)))
        else
            push!(rows, (f, r["status"], NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN))
        end
    end
    # copper-plate benchmark row
    bench = joinpath(get(kwargs, :data_dir, "./data/nempy_2024_07"), "bdu_prices_julia_fixed.csv")
    if isfile(bench)
        b = CSV.read(bench, DataFrame)
        b = b[b.time .== interval, :]
        if nrow(b) > 0
            pr = Dict(string(r.region) => float(r.price) for r in eachrow(b))
            push!(rows, ("COPPER_PLATE_BENCHMARK", "OPTIMAL", NaN, NaN, NaN,
                         get(pr, "NSW1", NaN), get(pr, "QLD1", NaN), get(pr, "SA1", NaN),
                         get(pr, "TAS1", NaN), get(pr, "VIC1", NaN)))
        end
    end
    CSV.write(outfile, rows)
    return rows
end
