# =============================================================================
# test_package.jl
#
# Package-level hygiene. None of this exercises a model; it checks that the
# package is put together the way the documentation says it is, so that a
# refactor which silently drops a submodule or an exported name fails here
# rather than in a user's script.
# =============================================================================

@testset "package" begin

    @testset "version" begin
        v = NEMX.version()
        @test v isa VersionNumber
        @test v >= v"0.2.0"
    end

    @testset "paths resolve independently of the working directory" begin
        # PKG_DIR must point at the package root wherever julia was started.
        @test isdir(NEMX.PKG_DIR)
        @test isfile(joinpath(NEMX.PKG_DIR, "Project.toml"))
        @test isdir(joinpath(NEMX.PKG_DIR, "src"))
        # Each submodule resolves its own assets the same way.
        @test isdir(NB.PKG_ROOT)
        @test realpath(NB.PKG_ROOT) == realpath(NEMX.PKG_DIR)
        @test isdir(OF.SCENARIO_DIR)
    end

    @testset "submodules are present and distinct" begin
        for m in (ZB, NB, OF)
            @test m isa Module
        end
        @test parentmodule(ZB) === NEMX
        @test parentmodule(NB) === NEMX
        @test parentmodule(OF) === NEMX
    end

    @testset "public API is exported" begin
        # A representative name from each layer of each submodule. If any of
        # these disappears, downstream code breaks, so the test is deliberately
        # specific rather than a count.
        for name in (:SpotMarket, :dispatch!, :get_energy_prices,
                     :build_spot_market, :dispatch_interval!, :local_prices,
                     :DBManager, :XMLCacheManager, :RawInputsLoader)
            @test name in names(ZB)
        end
        for name in (:load_network, :solve_network_dispatch, :FORMULATIONS,
                     :classify_generic, :compare_formulations)
            @test name in names(NB)
        end
        @test isdefined(OF, :run_acdcopfcas)
        @test isdefined(OF, :build_acdcopfcas)
        @test isdefined(OF, :process_scenario_data!)
    end

    @testset "public API is documented" begin
        # Documenter's `strict` mode catches missing docstrings for anything in
        # an @docs block; this catches the ones nobody remembered to list.
        undocumented = Symbol[]
        for (m, names_) in ((ZB, (:build_spot_market, :dispatch_interval!,
                                  :local_prices, :get_regional_fcas_prices,
                                  :get_published_rops, :unit_constraint_terms)),
                            (NB, (:hsl_library_path,)),
                            (OF, (:process_scenario_data!,
                                  :load_security_constrained!)))
            for n in names_
                b = Docs.Binding(m, n)
                isempty(Docs.doc(b).content) && push!(undocumented, n)
            end
        end
        @test isempty(undocumented)
    end

    @testset "security-constrained extras are opt-in" begin
        # The files exist in the tree but are not on the default load path,
        # because they need an unregistered dependency.
        scopf = joinpath(NEMX.PKG_DIR, "src", "opffcas", "scopf")
        @test isdir(scopf)
        @test isfile(joinpath(scopf, "scopfcas_bf.jl"))
        @test !isdefined(OF, :build_master_scopfcas_bf)
        @test isdefined(OF, :load_security_constrained!)
    end

end
