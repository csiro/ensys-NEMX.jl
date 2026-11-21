# =============================================================================
# run_network_day_20250902.jl
#
# PRESERVED NAMED RUN -- one full trading day on the network model,
# 2025-09-02 04:05 to 2025-09-03 04:00.
#
# PURPOSE
#   Solve 288 CONSECUTIVE five-minute intervals -- one whole NEM trading day --
#   on the network-resolved nodal dispatch, across every power-flow formulation,
#   and write the price series, the LMP decomposition and the active-constraint
#   ledger.
#
#   This is the reference network day. The window sits inside the cached
#   September-2025 span used by the zonal benchmark, so the nodal and zonal runs
#   are comparable interval for interval, which is the whole point: the market
#   inputs are identical and only the network representation differs.
#
#   The sweep also runs the MLF-scaled zonal reference for the same intervals,
#   so the nodal results have a like-for-like baseline rather than being
#   compared against a run using a different offer convention.
#
# HOW IT WORKS
#   A THIN WRAPPER. It sets this day's defaults as environment variables and
#   includes the general driver, run_network_day.jl. Anything given on the
#   command line still wins.
#
# FIXED DEFAULTS
#   start           2025-09-02T04:05  (the start of the NEM trading day)
#   intervals       288
#   formulations    DCP,LPACC,SOCWR,QCRM,ACP
#   data directory  data/nemx_2025_09
#   network case    data/snem2000_fixed.m
#
# RUNTIME
#   DCP is an LP and takes seconds per interval. ACP and the convex relaxations
#   are 2000-bus non-linear programs taking tens of seconds each, so the full
#   formulation list over 288 intervals is an OVERNIGHT job.
#
#   Validate the window with DC first:
#     julia --project=. scripts/nbenchmark/run_network_day_20250902.jl 2025-09-02T04:05 288 DCP
#
# ARGUMENTS
#   All of run_network_day.jl's arguments are accepted.
#
#   Positional      Default                    Meaning
#   --------------  -------------------------  ------------------------------
#   1               2025-09-02T04:05           first interval
#   2               288                        number of intervals
#   3               DCP,LPACC,SOCWR,QCRM,ACP   formulations
#
#   Options         Default                    Meaning
#   --------------  -------------------------  ------------------------------
#   --data-dir=     data/nemx_2025_09          MMS database and case-file cache
#   --mfile=        data/snem2000_fixed.m      the network case
#   --checkpoint=   12                         flush every N intervals (an hour)
#
#   Flags           Meaning
#   --------------  ----------------------------------------------------------
#   --with-lmp      Also write the full per-bus LMP series. About 2000 rows per
#                   interval per formulation, so off by default.
#
# SOLVERS
#   Each formulation carries its own solver in NEMX.NBenchmark.FORMULATIONS: an
#   LP formulation gets HiGHS, a non-linear one gets Ipopt. Change a
#   formulation's solver in that registry rather than by a flag here, because
#   mixing them is never what is wanted.
#
# OUTPUTS  (in --data-dir, stamped 20250902_0405)
#   network_day_prices_*.csv         regional reference prices, losses, status
#   network_day_decomposition_*.csv  lmp = energy + congestion + loss
#   network_day_fcas_prices_*.csv    regional FCAS requirement duals
#   network_day_binding_*.csv        active-constraint shadow-price ledger
#   network_day_participant_*.csv    per-participant local prices
#   network_day_benchmark_*.csv      the MLF-scaled zonal reference run
#
# NEXT STEP
#   julia --project=. scripts/nbenchmark/plot_network_day.jl
#
# EXAMPLES
#   julia --project=. scripts/nbenchmark/run_network_day_20250902.jl
#   julia --project=. scripts/nbenchmark/run_network_day_20250902.jl 2025-09-02T04:05 288 DCP
# =============================================================================

# --- Fixed defaults for this named run --------------------------------------
get!(ENV, "NEMX_NET_START", "2025-09-02T04:05")
get!(ENV, "NEMX_NET_N",     "288")
get!(ENV, "NEMX_NET_FORMS", "DCP,LPACC,SOCWR,QCRM,ACP")

# --- Run the general driver --------------------------------------------------
include(joinpath(@__DIR__, "run_network_day.jl"))
