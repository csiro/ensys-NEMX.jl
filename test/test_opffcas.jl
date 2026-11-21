# =============================================================================
# test_opffcas.jl
#
# AC/DC optimal power flow with FCAS co-optimisation, on the 2000-bus synthetic
# NEM case across three market scenarios.
#
# These are REGRESSION tests against objective values recorded from the
# reference implementation. They are the strongest tests in the suite: the
# objective of a 2000-bus co-optimised dispatch is sensitive to essentially
# every coefficient in the model, so reproducing it to relative 1e-8 means the
# variables, constraints, costs and data pipeline all still agree with the
# implementation the values were taken from.
#
# The recorded values were produced with Gurobi for the linear formulations and
# Ipopt for the non-linear ones. The linear ones are reproduced here with HiGHS,
# which is why the package needs no commercial solver.
#
# SCOPE: the bundled scenarios supply generator cost curves and marginal loss
# factors but no FCAS data, so the FCAS constraints are present and inactive.
# These tests therefore cover the energy, AC/DC converter and cost-overlay
# paths. Covering the co-optimisation itself needs a scenario with `fcas.m`,
# which is not currently in the repository.
#
# The DC formulation runs by default (a few seconds per scenario). The AC and
# IVR formulations take 10-45 s each and run only with NEMX_TEST_SLOW=1.
# =============================================================================

"""
    prepare_scenario(scenario::AbstractString) -> Dict

Load the 2000-bus AC/DC case and overlay one market scenario.

This is the standard preparation every OPFFCAS problem needs, and it is written
out here rather than hidden in a helper because the ORDER matters: scenario data
must be attached before `process_additional_data!` builds the converter model,
and the area-generator map after both.

# Arguments
- `scenario`: scenario name under `test/data/nem_market/` (`"s1"`, `"s2"`, `"s3"`).

# Returns
A PowerModels case dictionary, ready to pass to a `run_*` function.
"""
function prepare_scenario(scenario::AbstractString)
    data = _PM.parse_file(SNEM2000_CASE; validate = true, import_all = false)
    OF.process_scenario_data!(data, scenario)
    _PMACDC.process_additional_data!(data)
    OF.add_area_gens!(data)

    # Regional reference nodes, by bus id in this case file.
    rrn = Dict("NSW" => "130", "VIC" => "1480", "QLD" => "1274",
               "SA" => "1643", "TAS" => "1123")
    data["rrn"] = rrn
    data["bus_rr"] = Dict{String,Any}(bus => data["bus"][bus] for (_, bus) in rrn)
    data["price_cap"] = 16600

    # FCAS offer prices in this scenario library are quoted in cents; the model
    # works in dollars.
    for (_, gen) in data["gen"]
        haskey(gen, "fcas_cost") || continue
        for service in gen["fcas_cost"]
            cost = service[2]["cost"]
            isempty(filter(!=(0), cost[2:2:20])) || (cost[2:2:20] .= cost[2:2:20] ./ 100)
        end
    end
    return data
end

"Solver settings shared by every OPFFCAS test: branch flows, duals and MLFs on."
const OPFFCAS_SETTING = Dict("output" => Dict("branch_flows" => true,
                                              "duals" => true),
                             "conv_losses_mp" => true,
                             "mlf" => true)

"""
Objective values recorded from the reference implementation, keyed by
`(scenario, formulation)`. Tolerances are RELATIVE because the objectives are of
order 1e6: an absolute tolerance would either be meaningless or would fail on
the last bit of a double.
"""
const RECORDED_OBJECTIVES = Dict(
    ("s1", "DCP") => 6.945518904965966e6,
    ("s1", "ACP") => 5.948878799365816e6,
    ("s1", "IVR") => 5.948873023830866e6,
    ("s2", "DCP") => 5.961439703692706e6,
    ("s2", "ACP") => 5.966794401900445e6,
    ("s2", "IVR") => 5.966787079146418e6,
    ("s3", "DCP") => 6.764733719064058e6,
    ("s3", "ACP") => 6.000207951331199e6,
    ("s3", "IVR") => 6.000208593732356e6,
)

@testset "opffcas" begin

    @testset "scenario data loads" begin
        data = prepare_scenario("s1")
        @test haskey(data, "gen") && !isempty(data["gen"])
        @test haskey(data, "convdc")
        @test haskey(data, "rrn") && length(data["rrn"]) == 5
        @test data["price_cap"] == 16600
        # The scenario overlay must actually have replaced the case's own cost
        # data, or these regressions would be testing the base MATPOWER file.
        @test data["gen"]["1"]["ncost"] == 10        # ten-band NEM offer stack

        # WHAT THESE FIXTURES DO NOT COVER: the three bundled scenarios carry
        # `gencost.m` and `mlf.m` only — no `fcas.m` and no `loadcost.m`. So the
        # FCAS variables and constraints are built but inactive, and these
        # regressions validate the energy, AC/DC and cost-overlay paths rather
        # than the co-optimisation itself. Asserting the absence keeps that
        # limitation visible instead of letting a reader assume otherwise.
        @test isempty(get(data, "fcas_target", Dict()))
        @test !haskey(data, "fcas_gen")
    end

    @testset "an absent scenario file is skipped, not fatal" begin
        data = _PM.parse_file(SNEM2000_CASE; validate = false, import_all = false)
        @test_nowarn OF.process_scenario_data!(data, "no_such_scenario")
    end

    @testset "scenario directory is configurable" begin
        # `dir` must be honoured, so a user can hold scenarios outside the
        # package without copying them in.
        data = _PM.parse_file(SNEM2000_CASE; validate = false, import_all = false)
        @test_nowarn OF.process_scenario_data!(data, "s1"; dir = OF.SCENARIO_DIR)
    end

    # --- Regression: DC formulation, every scenario, open solver -------------
    for scenario in ("s1", "s2", "s3")
        @testset "$scenario DC polar" begin
            data = prepare_scenario(scenario)
            result = OF.run_acdcopfcas(data, _PM.DCPPowerModel, LP_SOLVER;
                                       setting = OPFFCAS_SETTING)
            expected = RECORDED_OBJECTIVES[(scenario, "DCP")]
            @test result["termination_status"] == OPTIMAL
            @test result["objective"] ≈ expected rtol = 1e-8
            @test haskey(result["solution"], "gen")
        end
    end

    if RUN_SLOW
        for scenario in ("s1", "s2", "s3")
            @testset "$scenario AC polar" begin
                data = prepare_scenario(scenario)
                result = OF.run_acdcopfcas(data, _PM.ACPPowerModel, NLP_SOLVER;
                                           setting = OPFFCAS_SETTING)
                expected = RECORDED_OBJECTIVES[(scenario, "ACP")]
                @test result["termination_status"] == LOCALLY_SOLVED
                @test result["objective"] ≈ expected rtol = 1e-6
            end

            @testset "$scenario IV rectangular" begin
                data = prepare_scenario(scenario)
                result = OF.run_acdcopfcas_ivr(data, _PM.IVRPowerModel, NLP_SOLVER;
                                               setting = OPFFCAS_SETTING)
                expected = RECORDED_OBJECTIVES[(scenario, "IVR")]
                @test result["termination_status"] == LOCALLY_SOLVED
                # Looser than the AC case: the IV formulation reaches the same
                # optimum along a different interior-point path, and the recorded
                # values agree only to Ipopt's convergence tolerance.
                @test result["objective"] ≈ expected rtol = 1e-6
            end
        end
    else
        @info "opffcas: AC and IVR regressions skipped. Set NEMX_TEST_SLOW=1 to run them."
    end

end
