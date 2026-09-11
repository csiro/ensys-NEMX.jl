# =============================================================================
# run_historical_dispatch_sep2025_3day.jl
#
# PRESERVED NAMED RUN -- three consecutive trading days, September 2025.
#
# PURPOSE
#   Dispatch 864 CONSECUTIVE five-minute intervals -- three whole trading days,
#   2025-09-01 00:05 to 2025-09-04 00:00 -- and score every regional price
#   against AEMO's published ROP.
#
#   A random sample of intervals gives an unbiased error estimate. It cannot
#   show anything that depends on the SEQUENCE, because consecutive intervals
#   are never in the sample. This run exists for the things that do:
#
#     * ramp-rate limits, which bind only relative to the previous target;
#     * storage, whose state of charge carries across intervals;
#     * fast-start units, whose inflexibility profile depends on how long they
#       have been in a mode;
#     * price spikes and the recovery that follows them, which are a
#       sequence rather than an interval.
#
#   Three days is chosen to span two full overnight troughs and three evening
#   peaks, so a diurnal pattern is visible rather than inferred.
#
# HOW IT WORKS
#   A THIN WRAPPER. It sets the defaults for the three-day run as environment
#   variables and includes the general driver, run_zonal_benchmark.jl.
#
#   Anything given on the command line still wins.
#
# FIXED DEFAULTS
#   MMS month       September 2025
#   interval mode   consecutive
#   intervals       864  (3 days x 288 five-minute intervals)
#   start           2025-09-01T00:05
#   data directory  data/nemx_2025_09
#   output tag      2025_09_3day
#
# RUNTIME
#   Each interval is an LP of moderate size, so budget a few seconds each: the
#   whole run is of the order of an hour. Results are checkpointed every
#   --checkpoint intervals, and each interval is solved in isolation, so an
#   interrupted run still leaves usable CSVs and one bad interval costs that
#   interval rather than the run.
#
# ARGUMENTS
#   All of run_zonal_benchmark.jl's arguments are accepted.
#
#   Options         Default              Meaning
#   --------------  -------------------  --------------------------------------
#   --solver=       highs                highs | ipopt | scs
#   --data-dir=     data/nemx_2025_09    MMS database and NEMDE case-file cache
#   --out-dir=      ~/.nemx/2025_09_3day checkpoint directory
#   --checkpoint=   25                   flush the CSVs every N intervals
#
#   Flags           Meaning
#   --------------  ----------------------------------------------------------
#   --download      Fetch the MMS tables and NEMDE case files first
#   --no-fast-start Skip the fast-start second pass. Faster, and NOT
#                   benchmark-valid for any interval with a starting unit.
#
# OUTPUTS  (in --out-dir, then copied into --data-dir)
#   zonal_prices_2025_09_3day.csv   one row per (interval, region, service)
#   zonal_energy_2025_09_3day.csv   the energy-only subset
#
# EXAMPLES
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_sep2025_3day.jl
#
#   # One day rather than three, to check the window first
#   julia --project=. scripts/zbenchmark/run_historical_dispatch_sep2025_3day.jl \
#         consecutive 288 2025-09-02T04:05
#
# FIRST RUN
#   Pass --download. Three trading days of NEMDE case files are roughly 4.5 GB;
#   the driver downloads the whole month's day range, so allow for more if the
#   cache is empty.
# =============================================================================

# --- Fixed defaults for this named run --------------------------------------
# 864 = 3 days x 288 intervals. Written out rather than as 3 * 288 so that the
# number in the file is the number in the log.
get!(ENV, "NEMX_MODE",  "consecutive")
get!(ENV, "NEMX_N",     "864")
get!(ENV, "NEMX_START", "2025-09-01T00:05")
get!(ENV, "NEMX_YEAR",  "2025")
get!(ENV, "NEMX_MONTH", "9")
get!(ENV, "NEMX_TAG",   "2025_09_3day")

# --- Run the general driver --------------------------------------------------
include(joinpath(@__DIR__, "run_zonal_benchmark.jl"))
