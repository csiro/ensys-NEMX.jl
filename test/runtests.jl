# =============================================================================
# NEMX test suite
#
# Run with:
#     julia --project=. -e 'using Pkg; Pkg.test()'
#
# Environment switches
# --------------------
#   NEMX_TEST_SLOW=1     Also run the AC and IVR formulations of the 2000-bus
#                        AC/DC case. These take 10-45 s each and add roughly two
#                        and a half minutes to the run. Off by default so the
#                        suite stays usable as a pre-commit check; on in CI.
#
#   NEMX_TEST_NETWORK=1  Also run the tests that download data from AEMO's
#                        NEMWeb portal. Off by default: they need several
#                        hundred megabytes and a working network, and a test
#                        suite should not silently depend on either.
#
# Solvers
# -------
# Only open-source solvers are used: HiGHS for linear and mixed-integer
# problems, Ipopt for the non-linear ones. Nothing here needs a licence.
#
# What is covered
# ---------------
#   test_zbenchmark.jl   Zonal market model: offer stacking, dispatch, price
#                        recovery, behavioural flags, and the packaged
#                        interval-assembly path.
#   test_nbenchmark.jl   Network layer: MATPOWER + side-table parsing, the
#                        formulation registry, constraint classification, and
#                        solver configuration.
#   test_opffcas.jl      AC/DC OPF with FCAS co-optimisation, against objective
#                        values recorded from the reference implementation.
#   test_package.jl      Package hygiene: submodule structure, exported names,
#                        docstring coverage of the public API.
# =============================================================================

using NEMX
using Test

using DataFrames
using Dates
using HiGHS
using Ipopt
using JuMP
using PowerModels
using PowerModelsACDC

const _PM = PowerModels
const _PMACDC = PowerModelsACDC

const ZB = NEMX.ZBenchmark
const NB = NEMX.NBenchmark
const OF = NEMX.OPFFCAS

# --- Solvers ----------------------------------------------------------------
"Silent LP/MIP solver used throughout the suite."
const LP_SOLVER = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)

"Silent NLP solver used for the AC and IVR formulations."
const NLP_SOLVER = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)

# --- Test data --------------------------------------------------------------
const TEST_DIR = @__DIR__
const MATPOWER_DIR = joinpath(TEST_DIR, "data", "matpower")

"Six-bus, three-region synthetic NEM case. Sub-second to solve."
const NEM6_CASE = joinpath(MATPOWER_DIR, "nem6_test.m")

"The 2000-bus synthetic NEM AC/DC case used by the OPFFCAS regression tests."
const SNEM2000_CASE = joinpath(MATPOWER_DIR, "snem2000_acdc.m")

# --- Switches ---------------------------------------------------------------
const RUN_SLOW = get(ENV, "NEMX_TEST_SLOW", "0") == "1"
const RUN_NETWORK = get(ENV, "NEMX_TEST_NETWORK", "0") == "1"

@testset "NEMX" begin
    include("test_package.jl")
    include("test_zbenchmark.jl")
    include("test_nbenchmark.jl")
    include("test_opffcas.jl")
end
