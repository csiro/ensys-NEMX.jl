# =============================================================================
# test_nbenchmark.jl
#
# The network layer. The full nodal dispatch needs a downloaded market interval
# and the 2000-bus case, so what is covered here without either is everything
# between the MATPOWER file and the market overlay: case parsing, the NEM side
# tables, region/area mapping, constraint classification, and solver
# configuration.
#
# The fixture is `nem6_test.m` — six buses across three regions, with an AC tie,
# a DC link, a battery and DUID side tables. It exists to make these paths
# testable in under a second.
# =============================================================================

@testset "nbenchmark" begin

    @testset "case and side tables" begin
        data, meta = NB.load_network(NEM6_CASE)

        @test length(data["bus"]) == 6
        @test length(data["gen"]) == 3
        @test length(data["branch"]) == 4
        @test length(get(data, "dcline", Dict())) == 1
        @test length(get(data, "storage", Dict())) == 1

        # DUIDs come out of `mpc.gen_data` in mpc.gen row order.
        @test sort(collect(values(meta.gen_duid))) ==
              ["NSWGEN1", "QLDGEN1", "VICGEN1"]
        @test collect(values(meta.stor_duid)) == ["QLDBESS1"]
        @test sort(unique(values(meta.area_of_bus))) == [1, 2, 3]
        @test length(meta.area_of_bus) == 6

        # Fuel is carried through when the side table has the column.
        @test meta.gen_fuel[first(k for (k, v) in meta.gen_duid if v == "NSWGEN1")] == "Coal"
    end

    @testset "DC-line losses are capped on load" begin
        # `load_network` clamps marginal DC losses at 3% and zeroes the standing
        # loss, because a loss1 near one lets reverse flow fabricate power.
        data, _ = NB.load_network(NEM6_CASE)
        for (_, dc) in data["dcline"]
            @test dc["loss1"] <= 0.03 + 1e-12
            @test dc["loss0"] == 0.0
        end
    end

    @testset "zero-reactance branches are repaired" begin
        data, _ = NB.load_network(NEM6_CASE)
        @test all(br["br_x"] != 0 for (_, br) in data["branch"])
    end

    @testset "the parsed case solves a plain DC OPF" begin
        data, _ = NB.load_network(NEM6_CASE)
        # PowerModels' stock `build_opf` has no storage variables, so the check
        # runs on a storage-free copy. The market OPF handles storage itself.
        data["storage"] = Dict{String,Any}()
        result = _PM.solve_opf(data, _PM.DCPPowerModel, LP_SOLVER)
        @test result["termination_status"] == OPTIMAL
        @test result["objective"] > 0
        # Generation must cover the 270 MW of case load plus the DC link's
        # marginal losses, and cannot exceed load by more than those losses.
        served = sum(g["pg"] for (_, g) in result["solution"]["gen"]) * data["baseMVA"]
        @test served >= 270.0 - 1e-6
        @test served <= 270.0 * 1.03
    end

    @testset "region and area maps" begin
        @test NB.AREA_OF_REGION == Dict("NSW1" => 1, "VIC1" => 2, "QLD1" => 3,
                                        "SA1" => 4, "TAS1" => 5)
        @test all(NB.REGION_OF_AREA[v] == k for (k, v) in NB.AREA_OF_REGION)
        @test length(NB.REGION_OF_AREA) == 5
    end

    @testset "interval length is in hours" begin
        # TAU is the single most consequential scalar in the model: treating the
        # MW/h ramp rates as MW/min re-opens a 60x-loose movement window.
        @test NB.TAU ≈ 5 / 60 atol = 1e-12
    end

    @testset "formulation registry" begin
        @test issubset(["DCP", "DCP_MLF", "LPACC", "SOCWR", "QCRM", "ACP"],
                       collect(keys(NB.FORMULATIONS)))
        for (name, (model_type, optimizer_factory)) in NB.FORMULATIONS
            @test model_type <: _PM.AbstractPowerModel
            @test optimizer_factory isa Function
        end
        @test NB.FORMULATIONS["DCP"][1] === _PM.DCPPowerModel
        @test NB.FORMULATIONS["ACP"][1] === _PM.ACPPowerModel
    end

    @testset "generic-constraint classification" begin
        # The classifier drives the binding-constraint ledger, so each family
        # needs a worked example rather than a smoke test.
        @test NB.classify_generic("F_Q++BCDM_L6") == "fcas"
        @test NB.classify_generic("#BARKIPS1_D_E") == "unit_cap"
        @test NB.classify_generic("N>>NIL_060_051") == "thermal"
        @test NB.classify_generic("") isa String
    end

    @testset "solver configuration" begin
        # HSL is optional and licence-restricted; its absence must be a fallback
        # to MUMPS, not an error.
        path = NB.hsl_library_path()
        @test path isa String
        @test isempty(path) || isfile(path)

        @test NB.NODAL_MLF_PRICE_REFERRAL[] === true
        @test NB.BALANCE_SLACK_ENABLED[] === true
        @test NB.NLP_RETRY_ENABLED[] === true
    end

    @testset "entry points exist with the documented signatures" begin
        @test hasmethod(NB.load_network, Tuple{String})
        @test hasmethod(NB.solve_network_dispatch, Tuple{DateTime,String})
        @test hasmethod(NB.compare_formulations, Tuple{DateTime})
        @test hasmethod(NB.load_market, Tuple{DateTime})
    end

end
