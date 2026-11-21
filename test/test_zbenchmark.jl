# =============================================================================
# test_zbenchmark.jl
#
# The zonal market model. These tests are built on synthetic markets rather than
# on downloaded AEMO data, so they are fast, deterministic, and runnable on a
# machine that has never seen NEMWeb.
#
# The synthetic cases are chosen so the correct answer is known by hand: with a
# monotone offer stack and a single region, the price is the price of the band
# the last megawatt came from, and each unit's dispatch is the cumulative volume
# up to that point. Anything the model gets wrong about stacking, sign
# conventions or dual recovery shows up as a mismatch against arithmetic.
# =============================================================================

"""
    bid_row(unit, service, prices_or_volumes; dispatch_type = "generator")

Build one row of a ten-band bid table.

Every NEM offer carries exactly ten bands. Tests usually want two or three, so
this fills the rest with zeros rather than making each test write them out.
"""
function bid_row(unit, service, values; dispatch_type = "generator")
    padded = [i <= length(values) ? float(values[i]) : 0.0 for i in 1:ZB.N_BANDS]
    return (; unit, dispatch_type, service,
            (Symbol(string(i)) => padded[i] for i in 1:ZB.N_BANDS)...)
end

"""
    two_unit_market(; demand = 120.0)

The smallest market that prices: two generators in one region, three bands each.

Unit A offers 20 MW at \$50, 20 MW at \$60 and 5 MW at \$100.
Unit B offers 50 MW at \$50, 30 MW at \$55 and 10 MW at \$80.
"""
function two_unit_market(; demand = 120.0)
    volumes = DataFrame([bid_row("A", "energy", [20.0, 20.0, 5.0]),
                         bid_row("B", "energy", [50.0, 30.0, 10.0])])
    prices = DataFrame([bid_row("A", "energy", [50.0, 60.0, 100.0]),
                        bid_row("B", "energy", [50.0, 55.0, 80.0])])
    info = DataFrame(unit = ["A", "B"], region = ["NSW1", "NSW1"],
                     dispatch_type = ["generator", "generator"],
                     loss_factor = [1.0, 1.0])
    market = ZB.SpotMarket(market_regions = ["NSW1"], unit_info = info)
    ZB.set_unit_volume_bids!(market, volumes)
    ZB.set_unit_price_bids!(market, prices)
    ZB.set_demand_constraints!(market, DataFrame(region = ["NSW1"],
                                                 demand = [demand]))
    return market
end

"Net energy dispatch per unit, from a solved market."
function net_dispatch(market)
    out = Dict{String,Float64}()
    for r in eachrow(ZB.get_unit_dispatch(market))
        string(r.service) == "energy" || continue
        sign = string(r.dispatch_type) == "load" ? -1.0 : 1.0
        out[string(r.unit)] = get(out, string(r.unit), 0.0) + sign * float(r.dispatch)
    end
    return out
end

@testset "zbenchmark" begin

    @testset "helpers" begin
        @test ZB.as_float(3) === 3.0
        @test ZB.as_float("2.5") === 2.5
        @test isnan(ZB.as_float(missing))
        @test isnan(ZB.as_float("not a number"))

        row = DataFrame(a = [1.5], b = ["7"])[1, :]
        @test ZB.column_or_nan(row, :a) === 1.5
        @test ZB.column_or_nan(row, :b) === 7.0
        @test isnan(ZB.column_or_nan(row, :absent))

        @test ZB.DEFAULT_REGIONS == ["QLD1", "NSW1", "VIC1", "SA1", "TAS1"]
        @test length(ZB.SERVICE_ROP_COL) == 11        # energy + ten FCAS services
        @test first(ZB.SERVICE_ROP_COL) == ("energy" => :ROP)
    end

    @testset "single-region dispatch and price" begin
        market = two_unit_market()
        ZB.dispatch!(market)

        dispatch = net_dispatch(market)
        # Cheapest-first: both \$50 bands (70 MW), then B's \$55 band (30 MW),
        # then 20 MW of A's \$60 band. A = 20 + 20, B = 50 + 30.
        @test dispatch["A"] ≈ 40.0 atol = 1e-6
        @test dispatch["B"] ≈ 80.0 atol = 1e-6
        @test sum(values(dispatch)) ≈ 120.0 atol = 1e-6

        prices = ZB.get_energy_prices(market)
        @test nrow(prices) == 1
        @test prices.region[1] == "NSW1"
        # The marginal megawatt comes from A's second band.
        @test prices.price[1] ≈ 60.0 atol = 1e-6
    end

    @testset "price follows the marginal band" begin
        # Move demand into each band in turn; the price must be that band's.
        for (demand, expected) in ((60.0, 50.0), (100.0, 55.0),
                                   (120.0, 60.0), (130.0, 80.0))
            market = two_unit_market(demand = demand)
            ZB.dispatch!(market)
            @test ZB.get_energy_prices(market).price[1] ≈ expected atol = 1e-6
        end
    end

    @testset "loads withdraw" begin
        # A scheduled load in the same region must raise the megawatts the
        # generators have to serve, and so the price.
        volumes = DataFrame([bid_row("A", "energy", [20.0, 20.0, 5.0]),
                             bid_row("B", "energy", [50.0, 30.0, 10.0]),
                             bid_row("L", "energy", [15.0]; dispatch_type = "load")])
        prices = DataFrame([bid_row("A", "energy", [50.0, 60.0, 100.0]),
                            bid_row("B", "energy", [50.0, 55.0, 80.0]),
                            bid_row("L", "energy", [500.0]; dispatch_type = "load")])
        info = DataFrame(unit = ["A", "B", "L"], region = fill("NSW1", 3),
                         dispatch_type = ["generator", "generator", "load"],
                         loss_factor = [1.0, 1.0, 1.0])
        market = ZB.SpotMarket(market_regions = ["NSW1"], unit_info = info)
        ZB.set_unit_volume_bids!(market, volumes)
        ZB.set_unit_price_bids!(market, prices)
        ZB.set_demand_constraints!(market,
            DataFrame(region = ["NSW1"], demand = [105.0]))
        ZB.dispatch!(market)

        dispatch = net_dispatch(market)
        # The load is willing to pay \$500, far above any offer, so it takes its
        # full 15 MW; generation must then cover 105 + 15 = 120 MW.
        @test dispatch["L"] ≈ -15.0 atol = 1e-6
        @test dispatch["A"] + dispatch["B"] ≈ 120.0 atol = 1e-6
        @test ZB.get_energy_prices(market).price[1] ≈ 60.0 atol = 1e-6
    end

    @testset "bid capacity binds" begin
        # Demand of 110 MW leaves headroom: B alone offers 90 MW, so capping A
        # at 25 MW is still feasible. That matters, because both the capacity
        # and the demand balance are SOFT constraints and the demand violation
        # price (2.6e6) dwarfs the capacity one (5e3) — an infeasible cap is
        # simply violated rather than enforced, which would test nothing.
        market = two_unit_market(demand = 110.0)
        ZB.set_unit_bid_capacity_constraints!(market,
            DataFrame(unit = ["A"], dispatch_type = ["generator"],
                      capacity = [25.0]))
        ZB.dispatch!(market)
        dispatch = net_dispatch(market)
        @test dispatch["A"] <= 25.0 + 1e-6
        @test dispatch["A"] + dispatch["B"] ≈ 110.0 atol = 1e-6
    end

    @testset "an infeasible cap is violated, not enforced" begin
        # The complement of the case above, asserted rather than left implicit:
        # capacities are priced, not hard, so when respecting one would leave
        # demand unserved the LP pays the capacity violation price instead.
        market = two_unit_market(demand = 120.0)     # B offers only 90 MW
        ZB.set_unit_bid_capacity_constraints!(market,
            DataFrame(unit = ["A"], dispatch_type = ["generator"],
                      capacity = [25.0]))
        ZB.dispatch!(market)
        dispatch = net_dispatch(market)
        @test dispatch["A"] > 25.0                   # cap breached
        @test dispatch["A"] + dispatch["B"] ≈ 120.0 atol = 1e-6   # demand met
    end

    @testset "loss factors refer offers to the reference node" begin
        # With ZONAL_MLF_KEEP_SCALING off (the default), the objective divides
        # the offer stack by the loss factor, so a unit with a loss factor below
        # one is dearer at the reference node than its as-bid price suggests.
        # Flipping the flag must change the price; leaving it must not.
        original = ZB.ZONAL_MLF_KEEP_SCALING[]
        try
            volumes = DataFrame([bid_row("A", "energy", [100.0]),
                                 bid_row("B", "energy", [100.0])])
            prices = DataFrame([bid_row("A", "energy", [50.0]),
                                bid_row("B", "energy", [52.0])])
            info = DataFrame(unit = ["A", "B"], region = ["NSW1", "NSW1"],
                             dispatch_type = ["generator", "generator"],
                             loss_factor = [0.90, 1.00])
            solved = Dict{Bool,Float64}()
            for keep in (false, true)
                ZB.ZONAL_MLF_KEEP_SCALING[] = keep
                market = ZB.SpotMarket(market_regions = ["NSW1"], unit_info = info)
                ZB.set_unit_volume_bids!(market, volumes)
                ZB.set_unit_price_bids!(market, prices)
                ZB.set_demand_constraints!(market,
                    DataFrame(region = ["NSW1"], demand = [150.0]))
                ZB.dispatch!(market)
                solved[keep] = ZB.get_energy_prices(market).price[1]
            end
            # Referred: A costs 50/0.9 = 55.6 at the reference node, so B at 52
            # is cheaper and sets the price. Unreferred: A at 50 is cheaper.
            @test solved[false] ≈ 55.5556 atol = 1e-3
            @test solved[true] ≈ 52.0 atol = 1e-6
            @test solved[false] != solved[true]
        finally
            ZB.ZONAL_MLF_KEEP_SCALING[] = original
        end
    end

    @testset "behavioural flags have their documented defaults" begin
        # Defaults are load-bearing: they are what reproduces published prices.
        @test ZB.BDU_CROSS_SIDE_REG_LOWER_SUBTRACT[] === true
        @test ZB.ZONAL_MLF_KEEP_SCALING[] === false
        @test ZB.LAZY_LOSS_TIGHTENING[] === true
        @test ZB.XML_PRICES_PRESCALED[] === true
        @test ZB.FCAS_DUAL_CVP_PRIORITY[] === false
        @test ZB.DIRECTED_UNIT_PRICE_RELAX[] === false
        @test ZB.LOSS_TIGHTEN_TIME_LIMIT[] == 30.0
    end

    @testset "no interconnectors is a legal market" begin
        # A regression guard. `_add_interconnectors!` used to return one value on
        # this path while `dispatch!` destructured two, so any market with no
        # interconnector at all threw a BoundsError. Real NEM intervals always
        # have five; synthetic ones need not.
        market = two_unit_market()
        @test isempty(market.interconnectors)
        @test_nowarn ZB.dispatch!(market)
        @test isfinite(ZB.get_energy_prices(market).price[1])
    end

    @testset "local price identity" begin
        # With no binding generic constraint the local price is the regional
        # price, referred to the connection point by the loss factor.
        market = two_unit_market()
        ZB.dispatch!(market)
        info = DataFrame(unit = ["A", "B"], region = ["NSW1", "NSW1"],
                         dispatch_type = ["generator", "generator"],
                         loss_factor = [0.95, 1.00])
        locals = ZB.local_prices(market, info)
        @test nrow(locals) == 2
        for r in eachrow(locals)
            @test r.adjustment == 0.0
            @test r.n_binding == 0
            @test r.local_price_ref ≈ 60.0 atol = 1e-6
            @test r.local_price_cp ≈ 60.0 * r.loss_factor atol = 1e-6
        end

        contributions, binding = ZB.unit_constraint_terms(market)
        @test isempty(contributions)
        @test isempty(binding)
    end

    @testset "FCAS price recovery with no requirements" begin
        market = two_unit_market()
        ZB.dispatch!(market)
        @test isempty(ZB.get_regional_fcas_prices(market))
    end

    @testset "assembly path is exported and callable" begin
        # The full path needs downloaded data; what is checked here is that the
        # packaged entry points exist with the documented signatures, so a
        # refactor cannot quietly drop them.
        @test hasmethod(ZB.build_spot_market, Tuple{ZB.RawInputsLoader})
        @test hasmethod(ZB.dispatch_interval!, Tuple{ZB.RawInputsLoader})
        @test fieldnames(ZB.MarketInputs) ==
              (:units, :demand, :interconnectors, :constraints, :cvp)
    end

    if RUN_NETWORK
        @testset "AEMO download and a real interval" begin
            dir = mktempdir()
            db = ZB.DBManager(joinpath(dir, "mms.db"))
            cache = ZB.XMLCacheManager(joinpath(dir, "xml"))
            interval = DateTime(2025, 9, 2, 12, 5)
            ZB.populate!(db; start_year = 2025, start_month = 9,
                         end_year = 2025, end_month = 9)
            ZB.populate_by_day!(cache; start_year = 2025, start_month = 9,
                                start_day = 2, end_year = 2025, end_month = 9,
                                end_day = 2)
            loader = ZB.RawInputsLoader(cache, db)
            ZB.set_interval!(loader, interval)
            market, _ = ZB.dispatch_interval!(loader)
            prices = ZB.get_energy_prices(market)
            @test nrow(prices) == 5
            @test all(isfinite, prices.price)
            published = ZB.get_published_rops(db, interval)
            for r in eachrow(prices)
                key = (r.region, "energy")
                haskey(published, key) || continue
                @test r.price ≈ published[key] atol = 1.0
            end
        end
    end

end
