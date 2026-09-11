# Prices and duals

Every price this package produces is a dual variable of an optimisation problem.
This page says which one, and what each means — including the distinction that
does most of the explanatory work, between the price a participant is *settled*
at and the price it is *dispatched* against.

## Regional energy price

The dual of a region's demand balance constraint: the marginal cost of one more
megawatt of demand in that region.

```julia
ZB.get_energy_prices(market)      # one row per region
```

In this package's convention a dual is `∂(objective)/∂(right-hand side)`, so the
regional price is positive when supply is costly, and the sign works out the same
way everywhere else on this page.

## Regional FCAS prices

FCAS requirements are not separate objects in the model. They are SPD generic
constraints whose left-hand sides carry `RegionFactor` terms, one per
`(region, service)`. By duality the marginal value of one more megawatt of a
region's requirement for a service is

```math
\text{price}(r, s) = \sum_c f_{r,s,c} \, \mu_c
```

summed over constraints, exactly the rule that makes a regional energy price the
dual of that region's demand constraint.

```julia
ZB.get_regional_fcas_prices(market)   # Dict((region, service) => (price, n_terms))
```

`n_terms` is the number of constraint terms that contributed. It matters: it
distinguishes a price of `0.0` because nothing bound from a price of `0.0`
because the model carries no requirement for that pair at all.

## Local prices, and why they differ from regional ones

A participant is **settled** at its region's reference price. It is
**dispatched** against a different number.

Write the dispatch LP with regional balance `Σ σ_u D_u = d_r` carrying dual
`λ_r`, and generic security constraints `g_c(D) ⋚ RHS_c` carrying duals `μ_c`,
where unit `u` enters constraint `c` with factor `f_uc`. Stationarity of an
interior offer band gives that band's price as

```math
\pi_u = \lambda_{r(u)} + \sum_c f_{uc}\, \mu_c
```

the unit's **local price**: the regional price plus the shadow-price adjustment
of every binding constraint that carries it.

Two consequences follow, and together they explain a great deal of apparently
perverse dispatch.

**The two prices are unbounded apart.** A transient-stability or thermal
constraint that binds hard drives `|μ_c|` to whatever it takes to clear, and the
identity then places `π_u` arbitrarily far below `λ_r` for a unit whose
generation loads that constraint. Nothing in the market design bounds the gap,
and settlement follows `λ_r` regardless.

**For a load the dispatch test inverts.** A load band states a willingness to
pay, so bands fill from the highest price down and a band is taken while
`p_band > π_u`. A band priced at \$0/MWh — the most conservative offer a
generator can make short of the floor — is, for a load facing a local price of
`-\$40/MWh`, an instruction to consume.

The identity holds for generation and load bands alike. The direction's sign is
carried inside the LP, in the `-1` with which load energy enters both the
regional balance and the constraint left-hand sides, not in the price.

```julia
locals = ZB.local_prices(market, ZB.get_unit_info(inputs.units))
```

### Reference node or connection point

The engine's objective is written in **reference-node** dollars: it divides the
connection-point offer stack by the unit's loss factor. So `π_u` as computed
above is a reference-node price, and multiplying by the loss factor puts it at
the connection point, which is the basis on which offers are submitted and on
which market software quotes a local price.

`local_prices` returns both, as `local_price_ref` and `local_price_cp`. They are
the same number in different units, not competing conventions.

It returns one row per `(unit, dispatch_type)` rather than per unit, because a
bidirectional unit's two sides share a reference-node local price but carry
*different* loss factors — the generator side takes `SECONDARY_TLF`. Collapsing
the directions would quote a charging battery's price on its discharging loss
factor.

## Nodal prices and their decomposition

The network model gives a price at every bus, and splits it:

```math
\lambda_i = \lambda^{E} + \lambda^{C}_i + \lambda^{L}_i
```

into an energy component (common to the region), a congestion component (the
shift-factor-weighted sum of binding branch and security constraint duals) and a
loss component. `solve_network_dispatch` returns this as `result.decomposition`,
and the constraints behind the congestion term as `result.binding`.

## When a dual is not identifiable

Some duals are not pinned by the problem. The standing example is the Queensland
lower 6 s and 60 s FCAS pair: `F_Q++BCDM_L6` and `F_Q++BCDM_L60` are structurally
identical — one interconnector factor on the same flow, one regional factor, the
same right-hand side. The shared flow variable's stationarity condition gives one
equation in two multipliers, so the problem pins only `μ_6 + μ_60`. The split
between them is free along a segment whenever no unit is strictly marginal in
one of the services, and which end of that segment you get is a property of the
solver's basis, not of the market.

The package does not encode a tie-break rule for this. Twenty binding intervals
were tested against candidate rules and several published prices fell strictly
*inside* the admissible interval, so any rule would fit the sample rather than
the mechanism. The benchmark scores the **sum**, which is the identifiable
quantity, and reports the separate values beside it. A large separate error next
to a near-zero joint error is the signature of the split, not a defect.

`run_zonal_benchmark.jl` prints both.

## Comparing against AEMO

Score against **ROP**, not RRP. ROP is the "original" regional price, before the
administered-price and scaling rules that are applied after dispatch and are
outside the dispatch problem. Comparing a dispatch model against RRP measures
the model plus those rules.

## A caution on validating price identities

It is tempting to check the local-price identity by finding units dispatched
strictly inside an offer band and asserting that the band's price equals the
local price. That test is **not valid as stated**, and the package's own scripts
say so where they report it.

Band interiority is necessary for strict marginality and far from sufficient. A
unit sitting inside a band may still be pinned by a ramp-rate limit, a bid
capacity or UIGF cap, an FCAS joint-capacity or trapezium constraint, or a
tie-break equality — each of which contributes a dual that the identity above
does not carry. The residual then measures the omitted duals rather than an error
in the identity, and its dominant mode sits at the offer floor: the fingerprint
of a ramp-limited unit dispatched partway into a floor-priced band.

The check that *is* valid, and that the scripts gate on, compares our
constraint duals directly against AEMO's published `MARGINALVALUE`. Those are
exactly the multipliers the decomposition uses, and AEMO publishes its own value
for each one.
