# =============================================================================
# plot_bess_event_study.jl
#
# PURPOSE
#   Draw the figure for a storage constrained-charging event: the regional price
#   a unit is SETTLED at, against the local price it is DISPATCHED against,
#   through the intervals of interest.
#
#   The point of the figure is the vertical distance between the black line and
#   the coloured ones. That gap is the exposure. On 21 November 2025 it opens by
#   about $14,012/MWh in a single interval while the unit's own local price does
#   not move at all -- which is the whole argument, made visually.
#
# INPUT
#   The CSVs written by run_bess_event_study.jl, in --data-dir:
#     bess_event_storage.csv    per-unit dispatch, cost and local price
#     bess_event_regional.csv   demand and price, by region and interval
#
# OUTPUT  (in --out-dir)
#   fig_bess_event.pdf   vector master, for inclusion in a document
#   fig_bess_event.png   600 dpi raster
#   fig_bess_event.html  interactive
#
# WHY THE PRICE AXIS IS TRANSFORMED
#   Within a single panel the prices run from the market floor (-$1000/MWh) to
#   the market cap (about $14,000/MWh). A linear axis compresses every local
#   price onto the zero line; a logarithmic axis cannot show the floor at all,
#   because it cannot show a negative number.
#
#   So the axis is SYMMETRIC-LOG: linear within +/- LINEAR_THRESHOLD of zero,
#   logarithmic outside it, and symmetric about zero. Plotly has no such axis
#   type, so the transform is applied to the DATA here and the tick positions
#   and labels are set explicitly. See `symlog_transform`.
#
# ARGUMENTS
#   Options        Env             Default              Meaning
#   -------------  --------------  -------------------  ------------------------
#   --data-dir=    NEMX_DATA_DIR   data/nempy_2025_11   where the CSVs are
#   --out-dir=     NEMX_OUT_DIR    figures              where the figure goes
#   --region=      NEMX_REGION     NSW1                 region whose price is
#                                                       drawn as the reference
#   --intervals=   NEMX_INTERVALS  2025-11-20T13:25,2025-11-21T09:10
#                                  comma-separated intervals of interest; one
#                                  panel is drawn per interval
#   --window=      NEMX_WINDOW     6                    intervals either side of
#                                                       each interval of interest
#   --threshold=   NEMX_THRESHOLD  300                  $/MWh above which an
#                                                       interval counts as
#                                                       elevated, which is how
#                                                       the units to draw are
#                                                       chosen
#   --linear-threshold=  NEMX_LINEAR_THRESHOLD  100     $/MWh below which the
#                                                       price axis is linear
#
# EXAMPLES
#   julia --project=. scripts/zbenchmark/plot_bess_event_study.jl
#   julia --project=. scripts/zbenchmark/plot_bess_event_study.jl --window=12
#   julia --project=. scripts/zbenchmark/plot_bess_event_study.jl \
#         --intervals=2025-11-25T12:15 --window=9
#
# NOTE
#   This script replaces an earlier Python/matplotlib version. It is now Julia
#   like everything else in the package, so the whole pipeline runs from one
#   toolchain and one environment.
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using PlotlyJS
using Printf

# ---------------------------------------------------------------------------
# SECTION 1.  CONFIGURATION
# ---------------------------------------------------------------------------

const DATA_DIR = resolve_input_dir(joinpath(NEMX.PKG_DIR, "data", "nempy_2025_11"))
const OUT_DIR  = resolve_output_dir(joinpath(NEMX.PKG_DIR, "figures"))
const REGION   = script_option("region", "NSW1")
const WINDOW   = script_integer(script_option("window", "6"))
const THRESHOLD = script_number(script_option("threshold", "300"))

# Price below which the axis is linear rather than logarithmic, in $/MWh.
const LINEAR_THRESHOLD = script_number(script_option("linear-threshold", "100"))

const INTERVALS = [script_datetime(text) for text in
                   script_list(script_option("intervals",
                                             "2025-11-20T13:25,2025-11-21T09:10"))]

# The market floor, in $/MWh. Drawn as a reference line, because a unit whose
# local price sits at the floor has no price-based defence left.
const MARKET_FLOOR = -1000.0

# Colour-blind-safe palette (Okabe-Ito). One colour per unit, assigned in the
# order the units appear, so the assignment is deterministic across re-runs.
const UNIT_COLOURS = ["#0072B2", "#009E73", "#D55E00", "#8C6D31", "#CC79A7",
                      "#56B4E9", "#E69F00", "#000000"]

# Marker shapes, cycled alongside the colours so the series remain
# distinguishable in a black-and-white print.
const UNIT_MARKERS = ["circle", "triangle-up", "square", "triangle-down",
                      "diamond", "cross", "x", "star"]

print_banner("Storage constrained-charging event figure",
             "data dir" => DATA_DIR,
             "out dir" => OUT_DIR,
             "region" => REGION,
             "intervals of interest" => join(string.(INTERVALS), ", "),
             "window (intervals)" => WINDOW,
             "elevated-price threshold" => THRESHOLD,
             "linear threshold (\$/MWh)" => LINEAR_THRESHOLD)

# ---------------------------------------------------------------------------
# SECTION 2.  THE SYMMETRIC-LOG PRICE TRANSFORM
# ---------------------------------------------------------------------------

"""
    symlog_transform(price, linear_threshold) -> Float64

Map a price onto the symmetric-log axis used by this figure.

Within `+/- linear_threshold` the mapping is linear, so small prices are not
crushed together. Outside it the mapping is logarithmic, so the market cap and
the market floor both fit on one axis. The transform is odd -- that is,
`f(-x) == -f(x)` -- so zero stays at zero and the two halves of the axis are
mirror images.

Concretely, with `t` for the threshold:

    |p| <= t     ->  p / t
    |p| >  t     ->  sign(p) * (1 + log10(|p| / t))

so one unit of axis is the linear region, and each further unit is a decade.

# Arguments
- `price`: the price to map, in \$/MWh.
- `linear_threshold`: half-width of the linear region, in \$/MWh. Must be
  positive.

# Returns
The transformed coordinate.
"""
function symlog_transform(price::Real, linear_threshold::Real)
    if linear_threshold <= 0
        error("linear_threshold must be positive, got $linear_threshold")
    end
    magnitude = abs(price)
    if magnitude <= linear_threshold
        return price / linear_threshold
    end
    decades = 1.0 + log10(magnitude / linear_threshold)
    return sign(price) * decades
end

"""
    symlog_ticks(linear_threshold) -> (positions, labels)

Tick positions and labels for the symmetric-log price axis.

The ticks are chosen at prices a reader of a NEM price series expects to see:
the market floor, the round decades either side of zero, zero itself, and the
region of the market cap. Positions are the TRANSFORMED coordinates; labels are
the untransformed prices, thousands-separated.

# Arguments
- `linear_threshold`: the same value passed to [`symlog_transform`](@ref).

# Returns
A tuple of `(Vector{Float64}, Vector{String})`.
"""
function symlog_ticks(linear_threshold::Real)
    prices = [-1000.0, -100.0, 0.0, 100.0, 1000.0, 10000.0]
    positions = Float64[]
    labels = String[]
    for price in prices
        push!(positions, symlog_transform(price, linear_threshold))
        push!(labels, format_thousands(price))
    end
    return positions, labels
end

"""
    format_thousands(value) -> String

Format a number with a comma every three digits, e.g. `-1,000`.

Written out rather than pulled from a formatting package: this is the only
place the package needs it, and one loop is cheaper than a dependency.
"""
function format_thousands(value::Real)
    rounded = round(Int, value)
    negative = rounded < 0
    digits_text = string(abs(rounded))
    grouped = ""
    count = 0
    for index in length(digits_text):-1:1
        grouped = digits_text[index] * grouped
        count += 1
        if count % 3 == 0 && index > 1
            grouped = "," * grouped
        end
    end
    return negative ? "-" * grouped : grouped
end

# ---------------------------------------------------------------------------
# SECTION 3.  LOADING THE EVIDENCE
# ---------------------------------------------------------------------------

"""
    read_event_csv(name) -> DataFrame

Read one of the event-study CSVs from the data directory.

# Throws
`ErrorException` naming the missing file and the script that writes it, because
"file not found" on its own does not tell an operator what to run.
"""
function read_event_csv(name::AbstractString)
    path = joinpath(DATA_DIR, name)
    if !isfile(path)
        error("missing $path -- run scripts/zbenchmark/run_bess_event_study.jl first")
    end
    return CSV.read(path, DataFrame)
end

storage_frame  = read_event_csv("bess_event_storage.csv")
regional_frame = read_event_csv("bess_event_regional.csv")

# The CSV round trip leaves the interval as text; parse it once, here.
storage_frame.interval  = DateTime.(SubString.(string.(storage_frame.time), 1, 19))
regional_frame.interval = DateTime.(SubString.(string.(regional_frame.time), 1, 19))

reference_prices = sort(regional_frame[regional_frame.region .== REGION, :], :interval)

"""
    units_to_draw(storage) -> Vector{String}

Which units the figure shows: those dispatched to charge in an interval whose
regional price exceeded the elevated-price threshold.

Chosen from the data rather than listed by hand, so the figure follows the
event rather than an assumption about it.
"""
function units_to_draw(storage::DataFrame)
    caught = storage[storage.charging .& (storage.rrp .> THRESHOLD), :]
    if isempty(caught)
        return String[]
    end
    # Deepest charge first, so the most heavily affected unit takes the first
    # colour and the legend reads in order of severity.
    ranked = combine(groupby(caught, :unit), :net_mw => minimum => :deepest)
    sort!(ranked, :deepest)
    return String.(ranked.unit)
end

const DRAWN_UNITS = units_to_draw(storage_frame)

if isempty(DRAWN_UNITS)
    println("No storage unit charged in an interval above \$", THRESHOLD,
            "/MWh in this data set -- there is nothing to draw.")
    exit(0)
end

@printf("  units drawn (%d): %s\n\n", length(DRAWN_UNITS), join(DRAWN_UNITS, ", "))

# ---------------------------------------------------------------------------
# SECTION 4.  BUILDING ONE PANEL
# ---------------------------------------------------------------------------

"""
    panel_traces(centre, panel_index) -> Vector{GenericTrace}

Every trace for the panel centred on one interval of interest.

The panel spans `WINDOW` intervals either side of `centre`. It carries:

  * the regional reference price, in black, which is what every unit is settled at;
  * each drawn unit's local price, in colour, which is what it was dispatched
    against;
  * a filled marker on each interval in which that unit was dispatched to
    charge;
  * the market floor, as a dotted reference line.

# Arguments
- `centre`: the interval of interest.
- `panel_index`: 1 for the first panel, 2 for the second, and so on. Only the
  first panel's traces appear in the legend, so that a five-unit legend is not
  repeated once per panel.

# Returns
The traces, ready to add to a subplot.
"""
function panel_traces(centre::DateTime, panel_index::Integer)
    span = Minute(5 * WINDOW)
    first_interval = centre - span
    last_interval = centre + span
    show_legend = (panel_index == 1)
    traces = GenericTrace[]

    # --- the regional reference price ---------------------------------------
    inside = (reference_prices.interval .>= first_interval) .&
             (reference_prices.interval .<= last_interval)
    reference = reference_prices[inside, :]
    push!(traces, scatter(x = reference.interval,
                          y = [symlog_transform(p, LINEAR_THRESHOLD)
                               for p in reference.price],
                          mode = "lines",
                          name = REGION * " regional price",
                          legendgroup = "reference",
                          showlegend = show_legend,
                          line = attr(color = "black", width = 2.4),
                          hovertemplate = "%{x|%H:%M}<extra>regional</extra>"))

    # --- the market floor ----------------------------------------------------
    floor_position = symlog_transform(MARKET_FLOOR, LINEAR_THRESHOLD)
    push!(traces, scatter(x = [first_interval, last_interval],
                          y = [floor_position, floor_position],
                          mode = "lines",
                          name = "market floor",
                          legendgroup = "floor",
                          showlegend = show_legend,
                          line = attr(color = "#888888", width = 0.9,
                                      dash = "dot"),
                          hoverinfo = "skip"))

    # --- one unit at a time --------------------------------------------------
    for (position, unit) in enumerate(DRAWN_UNITS)
        colour = UNIT_COLOURS[1 + (position - 1) % length(UNIT_COLOURS)]
        marker = UNIT_MARKERS[1 + (position - 1) % length(UNIT_MARKERS)]

        selected = (storage_frame.unit .== unit) .&
                   (storage_frame.interval .>= first_interval) .&
                   (storage_frame.interval .<= last_interval)
        series = sort(storage_frame[selected, :], :interval)
        if isempty(series)
            continue
        end

        # A unit on which no constraint binds has a local price equal to the
        # regional price, so its line would sit exactly under the black one and
        # look like a missing series. Dash it, and say so in the caption.
        no_constraint_binds = all(abs.(series.adjustment) .< 1e-9)
        line_style = no_constraint_binds ? "dash" : "solid"

        push!(traces, scatter(x = series.interval,
                              y = [symlog_transform(p, LINEAR_THRESHOLD)
                                   for p in series.local_price_cp_load],
                              mode = "lines",
                              name = unit,
                              legendgroup = unit,
                              showlegend = show_legend,
                              line = attr(color = colour, width = 1.4,
                                          dash = line_style),
                              hovertemplate = "%{x|%H:%M}<extra>" * unit * "</extra>"))

        charging = series[series.net_mw .< -1.0e-6, :]
        if !isempty(charging)
            push!(traces, scatter(x = charging.interval,
                                  y = [symlog_transform(p, LINEAR_THRESHOLD)
                                       for p in charging.local_price_cp_load],
                                  mode = "markers",
                                  name = unit * " charging",
                                  legendgroup = unit,
                                  showlegend = false,
                                  marker = attr(color = colour, size = 7,
                                                symbol = marker,
                                                line = attr(color = "white",
                                                            width = 1.0)),
                                  hovertemplate = "%{x|%H:%M} charging<extra>" *
                                                  unit * "</extra>"))
        end
    end

    return traces
end

# ---------------------------------------------------------------------------
# SECTION 5.  ASSEMBLING THE FIGURE
# ---------------------------------------------------------------------------

const PANEL_COUNT = length(INTERVALS)
const TICK_POSITIONS, TICK_LABELS = symlog_ticks(LINEAR_THRESHOLD)

figure = make_subplots(rows = 1, cols = PANEL_COUNT,
                       shared_yaxes = true,
                       horizontal_spacing = 0.045,
                       # `subplot_titles` takes a 1-by-columns MATRIX, not a
                       # vector: one title per grid cell.
                       subplot_titles = reshape(
                           [Dates.format(t, "e d u yyyy — HH:MM") for t in INTERVALS],
                           1, PANEL_COUNT))

# Shaded bands, collected across panels and applied in one call (see below).
const SHADED_BANDS = Any[]

for (panel_index, centre) in enumerate(INTERVALS)
    for trace in panel_traces(centre, panel_index)
        add_trace!(figure, trace, row = 1, col = panel_index)
    end

    # Shade the interval of interest itself, so the eye goes there first.
    #
    # Collected here and applied once, after the loop: `relayout!` REPLACES the
    # `shapes` list rather than appending to it, so adding them one at a time
    # inside the loop would leave only the last.
    push!(SHADED_BANDS,
          attr(type = "rect", xref = "x$(panel_index)", yref = "paper",
               # Half a five-minute interval, expressed in seconds because
               # `Minute` takes an integer.
               x0 = centre - Second(150), x1 = centre + Second(150),
               y0 = 0, y1 = 1,
               fillcolor = "#000000", opacity = 0.07,
               layer = "below", line = attr(width = 0)))
end

relayout!(figure, shapes = SHADED_BANDS)

# Axis styling.
#
# Set field by field, through PlotlyJS's underscore syntax, so that the values
# MERGE into the axis objects `make_subplots` built. Passing a whole `attr(...)`
# for `xaxis2` would REPLACE that object, discarding the `domain` and `anchor`
# that put the second panel to the right of the first -- which silently draws
# both panels on top of each other.
for panel_index in 1:PANEL_COUNT
    suffix = panel_index == 1 ? "" : string(panel_index)
    x_axis = "xaxis" * suffix
    y_axis = "yaxis" * suffix

    settings = Dict{Symbol,Any}()
    for (axis, is_x) in ((x_axis, true), (y_axis, false))
        settings[Symbol(axis, "_showgrid")]   = true
        settings[Symbol(axis, "_gridcolor")]  = "#E4E4E4"
        settings[Symbol(axis, "_gridwidth")]  = 0.6
        settings[Symbol(axis, "_showline")]   = true
        settings[Symbol(axis, "_linecolor")]  = "#444444"
        settings[Symbol(axis, "_linewidth")]  = 0.8
        settings[Symbol(axis, "_ticks")]      = "outside"
        settings[Symbol(axis, "_zeroline")]   = !is_x
    end

    settings[Symbol(x_axis, "_tickformat")]  = "%H:%M"
    settings[Symbol(x_axis, "_title_text")]  = "interval ending"

    settings[Symbol(y_axis, "_zerolinecolor")] = "#AAAAAA"
    settings[Symbol(y_axis, "_zerolinewidth")] = 0.6
    settings[Symbol(y_axis, "_tickmode")]      = "array"
    settings[Symbol(y_axis, "_tickvals")]      = TICK_POSITIONS
    settings[Symbol(y_axis, "_ticktext")]      = TICK_LABELS
    settings[Symbol(y_axis, "_range")]         =
        [symlog_transform(-2200.0, LINEAR_THRESHOLD),
         symlog_transform(45000.0, LINEAR_THRESHOLD)]
    settings[Symbol(y_axis, "_title_text")]    =
        panel_index == 1 ? "price (\$/MWh)" : ""

    relayout!(figure; settings...)
end

relayout!(figure,
          template = "plotly_white",
          font = attr(family = "Times New Roman, Times, serif", size = 12,
                      color = "#111111"),
          width = 1000, height = 420,
          margin = attr(l = 78, r = 24, t = 58, b = 96),
          legend = attr(orientation = "h", x = 0.5, xanchor = "center",
                        y = -0.24, yanchor = "top",
                        bgcolor = "rgba(255,255,255,0.94)",
                        bordercolor = "#444444", borderwidth = 0.8),
          hovermode = "x unified")

# ---------------------------------------------------------------------------
# SECTION 6.  WRITING THE FIGURE
# ---------------------------------------------------------------------------

const BASE_PATH = joinpath(OUT_DIR, "fig_bess_event")

savefig(figure, BASE_PATH * ".pdf"; width = 1000, height = 420)
savefig(figure, BASE_PATH * ".png"; width = 1000, height = 420, scale = 4)
open(BASE_PATH * ".html", "w") do io
    PlotlyBase.to_html(io, figure.plot)
end

println("Wrote:")
for extension in ("pdf", "png", "html")
    println("  ", BASE_PATH, ".", extension)
end

# ---------------------------------------------------------------------------
# SECTION 7.  THE CAPTION
#
# Written alongside the figure so that the two cannot drift apart, and so the
# reader of the document does not have to reconstruct what the dashed line means.
# ---------------------------------------------------------------------------

const CAPTION_PATH = joinpath(OUT_DIR, "fig_bess_event_caption.tex")

open(CAPTION_PATH, "w") do io
    println(io, "% Auto-generated by scripts/zbenchmark/plot_bess_event_study.jl")
    println(io, "\\caption{Regional price against local price through the ",
                "storage charging event.")
    println(io, "Black is the ", REGION, " regional reference price, at which every ",
                "unit is settled;")
    println(io, "the coloured traces are the units' local prices, at which they ",
                "are dispatched,")
    println(io, "quoted at each unit's connection point. Filled markers mark the ",
                "intervals in")
    println(io, "which a unit was dispatched to charge. The price axis is ",
                "symmetric-log: within")
    println(io, "\\\$", format_thousands(LINEAR_THRESHOLD), "/MWh of zero it is ",
                "linear, and outside it logarithmic, because")
    println(io, "the prices in a single panel span the market floor to the market ",
                "cap. A dashed")
    println(io, "trace is a unit on which no constraint binds: its local price ",
                "equals the regional")
    println(io, "price, so it lies exactly beneath the black line.}")
end

println("  ", CAPTION_PATH)
