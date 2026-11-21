# =============================================================================
# run_bess_event_nov2025_2day.jl
#
# PRESERVED NAMED RUN -- the New South Wales battery charging event,
# 20-21 November 2025, over two consecutive trading days.
#
# PURPOSE
#   Dispatch 576 CONSECUTIVE five-minute intervals -- two whole calendar days,
#   2025-11-20 00:05 to 2025-11-22 00:00 -- and write, per interval, the
#   evidence needed to explain why a storage unit was dispatched the way it was.
#
#   On each of these two days the New South Wales price reached about
#   $14,000/MWh for a single interval, and several batteries were dispatched to
#   CHARGE during it: they bought energy at close to the market cap. The
#   behaviour reads as a bidding failure and is not one, and this run produces
#   the data that shows which.
#
# WHY THE WHOLE TWO DAYS, NOT JUST THE SPIKES
#   The spike intervals alone cannot answer the question. What distinguishes a
#   unit that was constrained on from one that mis-priced its offer is whether
#   the SAME offer stack was harmless in the surrounding intervals -- so the
#   surrounding intervals have to be solved too. The run also captures the
#   rebidding that followed, which is the other half of the story.
#
# WHAT IS WRITTEN
#   bess_event_prices.csv       regional prices against AEMO's published ROP
#   bess_event_regional.csv     demand and price, by region and interval
#   bess_event_storage.csv      per-unit dispatch, cost and local price
#   bess_event_local_terms.csv  per-(unit, constraint) shadow-price terms
#   bess_event_constraints.csv  binding constraints, ours against AEMO's
#   bess_event_bids.csv         ten-band offer stacks for the storage units
#   bess_event_price_check.csv  the marginal-band diagnostic
#
# HOW IT WORKS
#   A THIN WRAPPER. It sets the defaults for this event as environment variables
#   and includes the general driver, run_bess_event_study.jl.
#
#   Anything given on the command line still wins.
#
# FIXED DEFAULTS
#   start           2025-11-20T00:05
#   intervals       576  (2 days x 288 five-minute intervals)
#   data directory  data/nemx_2025_11
#   region          NSW1
#
# ARGUMENTS
#   All of run_bess_event_study.jl's arguments are accepted.
#
#   Options         Default              Meaning
#   --------------  -------------------  --------------------------------------
#   --solver=       highs                highs | ipopt | scs
#   --data-dir=     data/nemx_2025_11    MMS database and NEMDE case-file cache
#   --out-dir=      ~/.nemx/nemx_2025_11   checkpoint directory
#   --region=       NSW1                 region of interest
#   --threshold=    300                  $/MWh above which an interval counts
#                                        as elevated for the summary
#   --checkpoint=   24                   flush the CSVs every N intervals
#
#   Flags           Meaning
#   --------------  ----------------------------------------------------------
#   --download      Fetch the MMS tables and NEMDE case files first
#   --no-download   Never download, even if the data looks missing
#
# NEXT STEP
#   julia --project=. scripts/zbenchmark/analyse_bess_event_study.jl
#   julia --project=. scripts/zbenchmark/plot_bess_event_study.jl
#
# EXAMPLES
#   julia --project=. scripts/zbenchmark/run_bess_event_nov2025_2day.jl --download
#   julia --project=. scripts/zbenchmark/run_bess_event_nov2025_2day.jl
#
#   # Just the afternoon of the first day, to check the setup
#   julia --project=. scripts/zbenchmark/run_bess_event_nov2025_2day.jl \
#         2025-11-20T13:00 12
#
# FIRST RUN
#   Pass --download. Two days of NEMDE case files are roughly 3 GB, plus a few
#   hundred megabytes of MMS tables. Both downloads are idempotent.
# =============================================================================

# --- Fixed defaults for this named run --------------------------------------
# 576 = 2 days x 288 intervals.
get!(ENV, "NEMX_START",  "2025-11-20T00:05")
get!(ENV, "NEMX_N",      "576")
get!(ENV, "NEMX_REGION", "NSW1")

# --- Run the general driver --------------------------------------------------
include(joinpath(@__DIR__, "run_bess_event_study.jl"))
