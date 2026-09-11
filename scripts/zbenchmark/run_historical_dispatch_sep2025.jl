# =============================================================================
# run_historical_dispatch_sep2025.jl
#
# PRESERVED NAMED RUN -- the September 2025 historical dispatch benchmark.
#
# PURPOSE
#   Reproduce the September-2025 validation run of the copper-plate dispatch
#   reconstruction. Ten pseudo-random intervals are drawn from the month with a
#   fixed seed, dispatched, and every regional price is scored against AEMO's
#   published ROP for energy and all ten FCAS services.
#
#   September 2025 is the second benchmark period, and the more demanding of the
#   two: it carries bidirectional units under the post-2024 rules, the 1-second
#   FCAS services, and Basslink as a regulated interconnector rather than an
#   MNSP. Everything interval-specific is read from the data, so the same model
#   handles both months without modification -- which is the point of running
#   both.
#
# HOW IT WORKS
#   A THIN WRAPPER. It sets the September-2025 defaults as environment variables
#   and includes the general driver, run_zonal_benchmark.jl. There is one
#   implementation of the sweep, not two.
#
#   Anything given on the command line still wins, because the driver reads ARGS
#   before it reads the environment.
#
# FIXED DEFAULTS
#   MMS month       September 2025
#   interval mode   random (fixed seed, so the sample is reproducible)
#   intervals       10
#   data directory  data/nemx_2025_09
#   output tag      2025_09
#
# ARGUMENTS
#   All of run_zonal_benchmark.jl's arguments are accepted. The ones most often
#   wanted here:
#
#   Options         Default            Meaning
#   --------------  -----------------  ----------------------------------------
#   --solver=       highs              highs | ipopt | scs
#   --data-dir=     data/nemx_2025_09 MMS database and NEMDE case-file cache
#   --out-dir=      ~/.nemx/2025_09    checkpoint directory
#   --checkpoint=   25                 flush the CSVs every N intervals
#   --seed=         1                  RNG seed for the interval sample
#
#   Flags           Meaning
#   --------------  ----------------------------------------------------------
#   --download      Fetch the MMS tables and NEMDE case files first
#   --verbose-solver  Let the solver print its own progress
#
# OUTPUTS  (in --out-dir, then copied into --data-dir)
#   zonal_prices_2025_09.csv   one row per (interval, region, service)
#   zonal_energy_2025_09.csv   the energy-only subset
#
# EXAMPLES
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_sep2025.jl
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_sep2025.jl --download
#
#   # A hundred intervals instead of ten
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_sep2025.jl random 100
#
# SEE ALSO
#   run_historical_dispatch_sep2025_3day.jl -- the same month, run as 864
#   consecutive intervals over three trading days.
# =============================================================================

# --- Fixed defaults for this named run --------------------------------------
get!(ENV, "NEMX_MODE",  "random")
get!(ENV, "NEMX_N",     "10")
get!(ENV, "NEMX_START", "2025-09-01T00:05")
get!(ENV, "NEMX_YEAR",  "2025")
get!(ENV, "NEMX_MONTH", "9")
get!(ENV, "NEMX_TAG",   "2025_09")

# --- Run the general driver --------------------------------------------------
include(joinpath(@__DIR__, "run_zonal_benchmark.jl"))
