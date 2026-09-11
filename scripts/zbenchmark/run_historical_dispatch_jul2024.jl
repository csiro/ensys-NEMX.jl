# =============================================================================
# run_historical_dispatch_jul2024.jl
#
# PRESERVED NAMED RUN -- the July 2024 historical dispatch benchmark.
#
# PURPOSE
#   Reproduce the original July-2024 validation run of the copper-plate
#   dispatch reconstruction. Ten pseudo-random intervals are drawn from the
#   month with a fixed seed, dispatched, and every regional price is scored
#   against AEMO's published ROP for energy and all ten FCAS services.
#
#   This month is the reference implementation's own benchmark period. It is
#   kept as a named script, rather than left as a set of arguments someone has
#   to remember, so that "run the July 2024 benchmark" is one command and always
#   means the same thing.
#
# HOW IT WORKS
#   This is a THIN WRAPPER. It sets the defaults for the July-2024 run as
#   environment variables and then includes the general driver,
#   run_zonal_benchmark.jl. There is one implementation of the sweep, not two,
#   so a fix to the driver reaches this script automatically.
#
#   Anything passed on the command line still wins: an explicit --option or a
#   positional argument overrides the default set here, because the driver reads
#   ARGS before it reads the environment.
#
# FIXED DEFAULTS
#   MMS month       July 2024
#   interval mode   random (a fixed seed, so the sample is reproducible)
#   intervals       10
#   data directory  data/nempy_2024_07
#   output tag      2024_07
#
# ARGUMENTS
#   All of run_zonal_benchmark.jl's arguments are accepted. The ones most often
#   wanted here:
#
#   Options         Default            Meaning
#   --------------  -----------------  ----------------------------------------
#   --solver=       highs              highs | ipopt | scs
#   --data-dir=     data/nempy_2024_07 MMS database and NEMDE case-file cache
#   --out-dir=      ~/.nemx/2024_07    checkpoint directory
#   --checkpoint=   25                 flush the CSVs every N intervals
#   --seed=         1                  RNG seed for the interval sample
#
#   Flags           Meaning
#   --------------  ----------------------------------------------------------
#   --download      Fetch the MMS tables and NEMDE case files first
#   --verbose-solver  Let the solver print its own progress
#
# OUTPUTS  (in --out-dir, then copied into --data-dir)
#   zonal_prices_2024_07.csv   one row per (interval, region, service)
#   zonal_energy_2024_07.csv   the energy-only subset
#
# EXAMPLES
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_jul2024.jl
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_jul2024.jl --download
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_jul2024.jl --solver=highs
#
#   # More intervals than the default ten, by overriding the positional argument
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_jul2024.jl random 50
#
# FIRST RUN
#   Pass --download. The July-2024 MMS tables are a few hundred megabytes and
#   the NEMDE case files are roughly 1.5 GB per day. Both downloads are
#   idempotent, so an interrupted one resumes by re-running.
# =============================================================================

# --- Fixed defaults for this named run --------------------------------------
# `get!` rather than plain assignment: an operator who has already exported one
# of these in the shell means it, and should not be overridden by the script.
get!(ENV, "NEMX_MODE",  "random")
get!(ENV, "NEMX_N",     "10")
get!(ENV, "NEMX_START", "2024-07-01T00:05")
get!(ENV, "NEMX_YEAR",  "2024")
get!(ENV, "NEMX_MONTH", "7")
get!(ENV, "NEMX_TAG",   "2024_07")

# --- Run the general driver --------------------------------------------------
include(joinpath(@__DIR__, "run_zonal_benchmark.jl"))
