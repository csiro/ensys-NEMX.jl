# =============================================================================
# config.jl
#
# Solver configuration and the formulation registry: HSL discovery, the two
# Ipopt option sets and the retry policy, the MLF price-referral switch, and the
# name -> (PowerModels type, optimizer) map.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================

# Ipopt settings for the 2000-bus market OPF. The defaults were tuned for a
# plain OPF; this model adds CVP-priced violation variables whose objective
# coefficients run to 2.6e6, so the barrier problem is badly scaled and the
# stock configuration stalled - measured over one trading day: ITERATION_LIMIT
# on 3 intervals, OTHER_ERROR on 16, and "solved to acceptable level" rather
# than converged on 39.
#   max_iter          default 3000 was reached on the peak intervals
#   mu_strategy       adaptive handles the CVP scale jump far better than the
#                     monotone default; together with max_iter this is what
#                     actually recovered the failing QC and SOC intervals
#   acceptable_tol    held AT `tol`, not loosened. Ipopt's own default is 1e-6,
#                     so relaxing it would buy termination by weakening the
#                     guarantee behind an ALMOST_LOCALLY_SOLVED return - the
#                     status would improve while the price got worse, which is
#                     precisely the wrong trade for a benchmark.
#   acceptable_*_tol  the COMPANION acceptable tolerances, which are what make
#                     "solved to acceptable level" mean anything at all. Ipopt's
#                     defaults are constr_viol 1e-2 (= 1 MW on a 100 MVA base)
#                     and dual_inf 1e10 (i.e. no bound whatsoever). We read
#                     PRICES out of the duals, so the default fallback can
#                     return numbers that look like prices and are not - and it
#                     did: every ALMOST_LOCALLY_SOLVED interval in the first
#                     sweep was certified under those defaults.
#                     constr_viol/compl_inf are set to 1e-4 (0.01 MW, a
#                     physically meaningful bound) and dual_inf to 1e2, which is
#                     ~4e-5 RELATIVE to the 2.6e6 CVP coefficients that dominate
#                     the objective gradient. An absolute dual_inf of 1e-4 was
#                     tried and is unreachable here (~1e-10 relative).
#
# HONEST CONSEQUENCE, measured: tightening these turns LPAC-C at 04:15 and
# 04:30 from ALMOST_LOCALLY_SOLVED into NUMERICAL_ERROR. Those two intervals
# need between 0.01 MW and 1 MW of constraint violation to certify, so the old
# "acceptable" status was a false certificate, not a solved interval. Reporting
# them as failures is the correct outcome even though it makes the status table
# look slightly worse; their prices (250.91, 216.81 $/MWh at the NSW reference
# node) are within a few cents of the uncertified values either way.
#
# `bound_relax_factor => 0.0` was TRIED and REVERTED. It keeps the bid and
# enablement bounds exact, which sounds strictly better, but it removes the
# cushion Ipopt uses to step around a bound and cost more than it bought:
# LPAC-C at 16:35 lost its solve. Ipopt's default relaxation is 1e-8 p.u. on a
# 100 MVA base, i.e. 1e-6 MW - immaterial against offers quoted in whole MW -
# so the default is kept and the robustness retained.
"""
    AREA_OF_REGION

Map from NEM region id to the MATPOWER `area` number carried by the network
case. The nodal model uses areas to place regional reference nodes, aggregate
regional demand and attribute interconnector flows.
"""
const AREA_OF_REGION = Dict("NSW1" => 1, "VIC1" => 2, "QLD1" => 3,
                            "SA1" => 4, "TAS1" => 5)

"""
    REGION_OF_AREA

Inverse of [`AREA_OF_REGION`](@ref).
"""
const REGION_OF_AREA = Dict(v => k for (k, v) in AREA_OF_REGION)

"""
    TAU

Dispatch interval length, in HOURS.

The ramp rates consumed here come from the market tables (bid `@RampUpRate` and
`SCADARampUpRate`), which are MW/h. This has been verified empirically twice
over: the copper-plate benchmark reproduces published prices exactly with
`rate * (5/60)` movement windows, and a unit such as YWPS4 (355 MW coal) carries
`rate = 180`, i.e. 3 MW/min — 180 MW/min would traverse the whole unit in two
minutes. Setting `TAU = 5` (treating the rates as MW/min) re-opens the 60x-loose
windows behind the original under-pricing defect. If a data source with MW/min
rates is ever added, convert at ingestion rather than changing this.
"""
const TAU = 5 / 60

"""
    PKG_ROOT

Absolute path to the package root, i.e. the directory holding `Project.toml`.

Resolved from this file's own location rather than from a caller's working
directory, so anything discovered relative to the package (the optional HSL
library, bundled test cases) is found however the package was loaded. This file
sits at `<root>/src/nbenchmark/core/`, hence three levels up.
"""
const PKG_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

"""
    hsl_library_path() -> String

Locate the HSL/CoinHSL shared library, or return `""` if none is present.

Ipopt loads HSL at RUNTIME through its `hsllib` option, so no rebuild of Ipopt
or Ipopt.jl is involved: the library only has to exist and match the platform.
Search order:

1. `ENV["NEMX_HSLLIB"]`, an explicit override giving the full path to the
   library;
2. `<package root>/vendor/coinhsl/lib/libcoinhsl.<ext>` (then `libhsl.<ext>`),
   where the CoinHSL binary distribution is unpacked.

HSL is licensed by STFC and is NOT redistributable, so the library is deliberately
kept out of version control and discovered at run time; a checkout without it
falls back to MUMPS and still works, just less robustly.
"""
function hsl_library_path()
    p = get(ENV, "NEMX_HSLLIB", "")
    isempty(p) || return isfile(p) ? p : ""
    ext = Sys.isapple() ? "dylib" : (Sys.iswindows() ? "dll" : "so")
    for n in ("libcoinhsl.$ext", "libhsl.$ext")
        c = joinpath(PKG_ROOT, "vendor", "coinhsl", "lib", n)
        isfile(c) && return c
    end
    return ""
end

const _HSLLIB = hsl_library_path()

"""
Linear-solver options. MA57 is used when HSL is available and MUMPS otherwise.

The linear solver is the sparse symmetric-indefinite factorisation at the heart
of every interior-point iteration, and it is the component most implicated in
the machine-dependent AC failures: MUMPS is where "solves here, fails there" on
identical input comes from. MA57 is markedly more robust on OPF-shaped KKT
systems, so where it is present the primary solve uses it.

The RETRY deliberately uses the OTHER factorisation. A retry that changes only
the barrier strategy still runs the same factorisation over the same KKT matrix,
which is why 2025-09-03 03:10 defeated both attempts; changing the factorisation
too makes the second attempt genuinely independent of the first.
"""
_hsl_primary() = isempty(_HSLLIB) ? ("linear_solver" => "mumps",) :
                                    ("hsllib" => _HSLLIB, "linear_solver" => "ma57")
_hsl_fallback() = isempty(_HSLLIB) ? ("linear_solver" => "mumps",) :
                                     ("hsllib" => _HSLLIB, "linear_solver" => "mumps")

const _IPOPT_BASE = ("print_level" => 0, "tol" => 1e-6, "max_iter" => 10_000,
                     "acceptable_tol" => 1e-6, "acceptable_iter" => 15,
                     "acceptable_constr_viol_tol" => 1e-4,
                     "acceptable_dual_inf_tol" => 1e2,
                     "acceptable_compl_inf_tol" => 1e-4)

const _IPOPT_NLP = (_IPOPT_BASE..., "mu_strategy" => "adaptive", _hsl_primary()...)

"""
    NODAL_MLF_PRICE_REFERRAL

Whether the nodal energy objective divides offer prices by the unit's marginal
loss factor, undoing the scaling `get_processed_bids` applied and referring the
bid stack back to the regional reference node.

`get_processed_bids` multiplies case-file energy prices by lambda, so `mkt.pb`
holds CONNECTION-POINT prices. The zonal benchmark divides by lambda again,
making its objective reference-node-referred; the nodal model originally
inherited the multiplication without the division, so its bid stack carried a
per-unit lambda that the benchmark did not. Verified at coefficient level: over
3 766 non-zero energy bands at 2025-09-02 04:15, the processed price equals the
case-file price times lambda with a maximum relative deviation of 0.0, and the
nodal objective coefficient equals the zonal one times lambda exactly.

Lambda is not incidental. Over 568 unit-directions the median is 0.9815, the
range 0.7917-1.0649, 81.3% differ from 1.0 and 26.9% sit below 0.95, so the
scaling reorders merit rather than perturbing it.

`true` (default) applies the referral to EVERY formulation, so all of them share
the benchmark's bid stack and any difference between them is attributable to the
power-flow model alone. The MLF-scaled variant is not obtained by disabling this
flag per formulation but by running the zonal engine with
`ZONAL_MLF_KEEP_SCALING`, which yields the single reference series the study is
measured against.
"""
const NODAL_MLF_PRICE_REFERRAL = Ref(true)

"""
    _IPOPT_NLP_RETRY

Fallback barrier configuration, used once when the primary solve returns a
genuine failure (see `NLP_RETRY_ENABLED`).

It differs from `_IPOPT_NLP` in the two parameters that decide which numerical
path the solver takes: the barrier update and, where HSL is available, the
linear solver. The primary configuration uses the adaptive barrier and MA57;
this one reverts to the monotone barrier, pushes the starting point further
inside its bounds, and factorises with MUMPS. The point is not that either
choice is better -- it is that a failure on this problem is a property of the
path taken, not of the interval, so the retry has to be genuinely INDEPENDENT
of the first attempt. Changing only the barrier strategy was not enough:
2025-09-03 03:10 failed both attempts while returning a point within
`\$1.74/MWh` of the consensus of the three relaxations.
"""
const _IPOPT_NLP_RETRY = (_IPOPT_BASE..., "mu_strategy" => "monotone",
                          "bound_push" => 1e-2, "bound_frac" => 1e-2,
                          _hsl_fallback()...)

"""
    NLP_RETRY_ENABLED

Retry an interior-point solve once, along a different barrier path, when the
first attempt fails outright.

The AC formulations occasionally return `OTHER_ERROR` or `NUMERICAL_ERROR` on a
2000-bus market OPF whose objective spans offer prices of order 1e2 and CVP
coefficients of 2.6e6. Investigated on three such intervals (2025-09-02 06:40
and 23:10, 2025-09-03 03:10), the failures proved NOT to be properties of the
interval: every one of them converges standalone, under the old and new solver
settings alike, with and without the balance slack, and in the driver's full
six-formulation sequence. What differs is the numerical path -- Ipopt with MUMPS
is sensitive to the build and to BLAS threading -- so the same input can solve
on one machine and fail restoration on another.

A retry is therefore the appropriate remedy: it costs nothing on the ~97% of
intervals that already converge, and it gives the failures a second, different
path rather than discarding the interval. The retry result is kept even if it
also fails, because a failed first attempt leaves duals that are not prices, and
because the downstream extraction reads values and duals from the JuMP model --
so `res` and the model must describe the same solve. Both statuses are recorded
in the result (`status`, `first_status`, `solve_attempts`), so a retry is never
silent.
"""
const NLP_RETRY_ENABLED = Ref(true)

"A solve is usable if the solver certified it; everything else is retried."
_solve_ok(st) = string(st) in ("OPTIMAL", "LOCALLY_SOLVED", "ALMOST_LOCALLY_SOLVED")


"Formulation registry: name => (PowerModels type, optimizer factory)."
const FORMULATIONS = Dict(
    "DCP"     => (PM.DCPPowerModel,    () -> optimizer_with_attributes(HiGHS.Optimizer, "output_flag"=>false)),
    "DCP_MLF" => (PM.DCPPowerModel,    () -> optimizer_with_attributes(HiGHS.Optimizer, "output_flag"=>false)),
    "ACP"     => (PM.ACPPowerModel,    () -> optimizer_with_attributes(Ipopt.Optimizer, _IPOPT_NLP...)),
    # LPAC-C is convex/linear in theory, but PM's implementation registers NL
    # expressions for the cosine relaxation — solve with Ipopt.
    "LPACC"   => (PM.LPACCPowerModel,  () -> optimizer_with_attributes(Ipopt.Optimizer, _IPOPT_NLP...)),
    "SOCWR"   => (PM.SOCWRPowerModel,  () -> optimizer_with_attributes(Ipopt.Optimizer, _IPOPT_NLP...)),
    "QCRM"    => (PM.QCRMPowerModel,   () -> optimizer_with_attributes(Ipopt.Optimizer, _IPOPT_NLP...)),
    "SDPWRM"  => (PM.SDPWRMPowerModel, () -> optimizer_with_attributes(SCS.Optimizer, "verbose" => 0,)),   # needs an SDP solver (SCS/Clarabel); guarded
)
