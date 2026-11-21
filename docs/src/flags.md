# Behavioural flags

Anything that changes what a model computes is a module-level `Ref`, set at run
time:

```julia
NEMX.ZBenchmark.LOSS_MODEL_FROM_XML[] = false
```

They are `Ref`s rather than keyword arguments because they apply across a whole
run and would otherwise have to be threaded through a dozen call sites. The
trade is that they are global state, so two rules apply:

1. **Every default reproduces the validated configuration.** Nothing in the
   package changes a flag implicitly.
2. **A script that changes one must print it.** All of them call
   `print_flags` after any assignment, so the log above a result records the
   configuration that produced it.

## `NEMX.ZBenchmark`

| Flag | Default | Effect |
|:-----|:--------|:-------|
| `LOSS_MODEL_FROM_XML` | `true` (env `NEMX_LOSS_XML`) | Take interconnector loss curves from the NEMDE case file rather than re-deriving them from the MMS demand coefficients |
| `BDU_CROSS_SIDE_REG_LOWER_SUBTRACT` | `true` | Subtract, rather than add, the cross-side regulation term in a bidirectional unit's lower joint-capacity constraint |
| `ZONAL_MLF_KEEP_SCALING` | `false` | Leave the energy offer stack scaled by the marginal loss factor instead of referring it to the regional reference node |
| `LAZY_LOSS_TIGHTENING` | `true` | Lazily enforce SOS2 adjacency on the loss interpolation after an LP solve |
| `LAZY_LOSS_VERBOSE` | `false` | Print per-iteration diagnostics from that tightening |
| `LOSS_TIGHTEN_TIME_LIMIT` | `30.0` | Seconds allowed per loss-adjacency re-solve; `nothing` for no limit |
| `XML_PRICES_PRESCALED` | `true` | Treat NEMDE case-file energy prices as pre-referred to the regional node |
| `FCAS_DUAL_CVP_PRIORITY` | `false` | Opt-in refinement of degenerate FCAS duals by violation-price priority. **Rejected hypothesis** — see below |
| `DIRECTED_UNIT_PRICE_RELAX` | `false` | Experimental dual-degeneracy resolution for directed units |
| `SOLVER_FACTORY` | `HiGHS.Optimizer` | Optimizer used by `dispatch!` |

### `LOSS_MODEL_FROM_XML`

The case file carries NEMDE's own per-interval loss model as
`<LossModel>/<Segment>` collections. The alternative is to re-derive the curve
from the MMS demand coefficients, which is what the reference Python
implementation does.

Take the case file's when benchmarking against published prices — it is AEMO's
own input, and using anything else measures your reconstruction of the loss model
as well as your reconstruction of the dispatch. The MMS derivation is there for
studying the loss model itself, and for periods where case files are unavailable.

### `BDU_CROSS_SIDE_REG_LOWER_SUBTRACT`

A bidirectional unit that offers lower regulation on one side and a lower
contingency service on the other is consuming the *same* downward headroom. The
sign of the cross-side term in the joint-capacity constraint decides whether the
model knows that.

Adding the term relaxes the constraint and lets the unit sell both, understating
the cost of lower services. Subtracting it is what NEMDE does. The default is
`true` (subtract), validated directly against case files: over 120 intervals and
1,532 trapezium checks, evaluated on AEMO's own published targets, the
subtracting form is exactly binding 381 times and never violated, while the
adding form never binds at all.

### `ZONAL_MLF_KEEP_SCALING`

Offers arrive from the case file referred to the regional reference node.
Ingestion multiplies by the loss factor to restore connection-point prices, and
the objective divides by the same factor to refer them back — an exact round
trip, and the validated benchmark.

Setting this to `true` skips the division, leaving the offer stack scaled. There
is exactly one reason to do that: to generate the MLF-scaled reference dispatch
that the nodal formulations are measured against, so that the comparison is not
conflating a change in network model with a change in offer convention. It is
not the benchmark, and `scripts/zbenchmark/run_zonal_benchmark.jl --keep-mlf-scaling` says
so in its output.

### `LAZY_LOSS_TIGHTENING` and `LOSS_TIGHTEN_TIME_LIMIT`

Interconnector losses are a piecewise-linear interpolation whose weights must be
adjacent (SOS2). Enforcing that up front makes every interval a MIP; enforcing it
lazily — solve the LP, find the links whose weights came back non-adjacent, add
the binaries only for those, re-solve — keeps almost every interval an LP.

Non-adjacent weights fabricate losses, which is profitable only at negative
prices, so turning the tightening off is valid for isolating the pure LP
relaxation while debugging and **not** valid for benchmark prices in exactly the
case the tightening exists to fix.

AEMO's loss curves carry 60–120 breakpoints per link, and when several links need
tightening at once the resulting MIP can fail to close. The time limit bounds it:
if the limit is hit, the model reverts to the LP relaxation for that interval and
still returns valid duals, rather than returning `NaN` or pricing off a poor
incumbent. That makes a long run deterministic in wall-clock terms.

### `FCAS_DUAL_CVP_PRIORITY` — a rejected hypothesis

This one is documented at length because the temptation to enable it is real.

Where two FCAS requirement constraints are degenerate, allocating dual mass in
descending violation-price order reproduces AEMO's published split on the
interval the rule was derived from. It was then falsified by a 1,000-interval
sweep: overall FCAS disparity *increased*, Tasmanian lower-regulation mismatches
appeared where there had been none, and the Queensland mismatch it was meant to
fix persisted. It had been over-fitted to a single interval.

The code is kept as a diagnostic for identifying degenerate requirement groups.
It is not called from `dispatch!`, and the flag defaults to `false`.

## `NEMX.NBenchmark`

| Flag | Default | Effect |
|:-----|:--------|:-------|
| `NODAL_MLF_PRICE_REFERRAL` | `true` | Refer offer prices to the regional reference node by dividing by the unit's marginal loss factor, matching the zonal objective |
| `BALANCE_SLACK_ENABLED` | `true` | Add violation-priced one-sided slack generators at each regional reference node |
| `NLP_RETRY_ENABLED` | `true` | On a failed AC solve, retry once with a different barrier strategy *and* a different linear solver |

### `BALANCE_SLACK_ENABLED`

Two one-sided dummy generators at each regional reference node, priced at the
regional demand violation price. Without them, an interval that cannot balance on
the network model returns `INFEASIBLE` and yields nothing. With them, it prices —
and the slack's own dispatch tells you how much energy was missing and where,
which is a diagnosis rather than a failure.

### `NLP_RETRY_ENABLED`

A retry that changes only the barrier strategy runs the same factorisation over
the same KKT matrix. Changing the linear solver as well makes the second attempt
genuinely independent of the first, which is what recovers intervals that
defeated both halves of a naive retry.

The retry re-attaches the optimizer with `JuMP.set_optimizer`. Passing an
`optimizer` keyword to `optimize_model!` does nothing once a model already holds
one — it is ignored, and the model is silently re-solved with the original. That
is worth knowing because a retry that quietly does nothing looks exactly like a
retry that did not help.

## `NEMX.OPFFCAS`

| Setting | Default | Effect |
|:--------|:--------|:-------|
| `SCENARIO_DIR` | `<package>/test/data/nem_market` | Where `process_scenario_data!` looks for scenarios |
| `MARKET_DATA_DIR` | `~/nem_market_data` | Where the scenario-building helpers read raw AEMO CSVs and write `.m` files |

Both are overridable per call with a `dir` keyword, so a one-off does not have to
mutate global state.

## Environment variables

| Variable | Read by | Effect |
|:---------|:--------|:-------|
| `NEMX_LOSS_XML` | `ZBenchmark` | Initial value of `LOSS_MODEL_FROM_XML` (`"1"` = true) |
| `NEMX_HSLLIB` | `NBenchmark` | Full path to a CoinHSL library, overriding the search |
| `NEMX_NO_DISPLAY` | `OPFFCAS` | Suppress figure display even in an interactive session |
| `NEMX_TEST_SLOW` | tests | Run the AC and IVR regressions |
| `NEMX_TEST_NETWORK` | tests | Run the tests that download from AEMO |

Scripts add their own; see [Scripts](@ref).
