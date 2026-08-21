const DAY_FMT = dateformat"yyyy-mm-dd"
const ARXIV_QUERY_DAY_FMT = dateformat"yyyymmdd"
const TIMESTAMP_FMT = dateformat"yyyy-mm-ddTHH:MM:SS"

project_root() = normpath(joinpath(@__DIR__, ".."))

data_dir() = get(ENV, "ARXIV_VIEWER_DATA_DIR", joinpath(project_root(), "data"))

db_path() = get(ENV, "ARXIV_VIEWER_DB_PATH", joinpath(data_dir(), "arxiv_viewer.sqlite"))

pdf_cache_dir() = joinpath(data_dir(), "pdfs")

summary_model() = get(ENV, "ARXIV_VIEWER_SUMMARY_MODEL", "qwen2.5:7b")

ollama_generate_url() = get(ENV, "ARXIV_VIEWER_OLLAMA_URL", "http://127.0.0.1:11434/api/generate")

pdftotext_executable() = get(ENV, "ARXIV_VIEWER_PDFTOTEXT", "pdftotext")

default_top_summary_count() = parse(Int, get(ENV, "ARXIV_VIEWER_TOP_SUMMARY_COUNT", "5"))

server_port() = parse(Int, get(ENV, "ARXIV_VIEWER_PORT", "8000"))

lookback_days() = parse(Int, get(ENV, "ARXIV_VIEWER_LOOKBACK_DAYS", "30"))

arxiv_read_timeout_seconds() = parse(Int, get(ENV, "ARXIV_VIEWER_HTTP_READ_TIMEOUT", "30"))

arxiv_connect_timeout_seconds() = parse(Int, get(ENV, "ARXIV_VIEWER_HTTP_CONNECT_TIMEOUT", "10"))

arxiv_user_agent() = get(
    ENV,
    "ARXIV_VIEWER_USER_AGENT",
    "arxiv-viewer/0.1 (+https://github.com/phajy/arxiv-viewer; local research tool)",
)

timestamp_now() = Dates.format(Dates.now(), TIMESTAMP_FMT)

date_string(value::Date) = Dates.format(value, DAY_FMT)

query_day_string(value::Date) = Dates.format(value, ARXIV_QUERY_DAY_FMT)

window_or_default(value::AbstractString) = haskey(WINDOW_LABELS, String(value)) ? String(value) : "today"

browse_mode_or_default(value::AbstractString) = String(value) in BROWSE_MODES ? String(value) : "day"

summary_count_or_default(value::AbstractString) = try
    parsed = parse(Int, String(value))
    clamp(parsed, 1, 25)
catch
    default_top_summary_count()
end

label_or_default(value::AbstractString) = String(value) in LABEL_OPTIONS ? String(value) : "interested"

label_display(value::AbstractString) = get(LABEL_DISPLAY, String(value), "+")

pdf_open_path(selection::BrowseSelection, paper_id::AbstractString) = "/pdf/open/$(selection.mode)/$(date_string(selection.anchor))/$(String(paper_id))"

abstract_summary_path(selection::BrowseSelection, paper_id::AbstractString) = "/summary/abstract/$(selection.mode)/$(date_string(selection.anchor))/$(String(paper_id))"

pdf_summary_path(selection::BrowseSelection, paper_id::AbstractString) = "/summary/pdf/$(selection.mode)/$(date_string(selection.anchor))/$(String(paper_id))"

selection_summary_path(selection::BrowseSelection, top_n::Integer) = "/summary/top/$(selection.mode)/$(date_string(selection.anchor))/$(Int(top_n))"

arxiv_html_url(paper_id::AbstractString) = "https://arxiv.org/html/$(canonical_arxiv_id(paper_id))"

maybe_string(value) = value === missing || isnothing(value) ? "" : String(value)

maybe_value(value) = value === missing || isnothing(value) ? nothing : String(value)

function html_escape(text::AbstractString)
    escaped = replace(text, '&' => "&amp;")
    escaped = replace(escaped, '<' => "&lt;")
    escaped = replace(escaped, '>' => "&gt;")
    escaped = replace(escaped, '"' => "&quot;")
    return replace(escaped, '\'' => "&#39;")
end

function compact_whitespace(text::AbstractString)
    return strip(replace(text, r"\s+" => " "))
end

function truncate_text(text::AbstractString, limit::Integer)
    normalized = compact_whitespace(text)
    ncodeunits(normalized) <= limit && return normalized
    return string(first(normalized, limit - 1), "…")
end

function parse_day_or_nothing(value::AbstractString)
    try
        return Date(String(value), DAY_FMT)
    catch
        return nothing
    end
end

safe_reference_day(reference_day::Date) = reference_day

safe_reference_day(::Nothing) = Dates.today()

function browse_selection(mode::AbstractString, anchor::Date; reference_day::Union{Nothing, Date} = nothing)
    resolved_reference_day = safe_reference_day(reference_day)
    resolved_mode = browse_mode_or_default(mode)
    resolved_anchor = min(anchor, resolved_reference_day)

    lower, upper = if resolved_mode == "day"
        (resolved_anchor, resolved_anchor)
    elseif resolved_mode == "week"
        (Dates.firstdayofweek(resolved_anchor), min(Dates.lastdayofweek(resolved_anchor), resolved_reference_day))
    else
        (Dates.firstdayofmonth(resolved_anchor), min(Dates.lastdayofmonth(resolved_anchor), resolved_reference_day))
    end

    return BrowseSelection(resolved_mode, resolved_anchor, lower, upper, resolved_reference_day)
end

function browse_selection(mode::AbstractString, anchor::AbstractString; reference_day::Union{Nothing, Date} = nothing)
    resolved_reference_day = safe_reference_day(reference_day)
    resolved_anchor = something(parse_day_or_nothing(anchor), resolved_reference_day)
    return browse_selection(mode, resolved_anchor; reference_day = resolved_reference_day)
end

function window_selection(window::AbstractString; reference_day::Union{Nothing, Date} = nothing)
    resolved_reference_day = safe_reference_day(reference_day)
    resolved_window = window_or_default(window)
    resolved_mode = resolved_window == "today" ? "day" : resolved_window
    return browse_selection(resolved_mode, resolved_reference_day; reference_day = resolved_reference_day)
end

browse_path(selection::BrowseSelection) = "/browse/$(selection.mode)/$(date_string(selection.anchor))"

refresh_path(selection::BrowseSelection) = "/refresh/$(selection.mode)/$(date_string(selection.anchor))"

label_path(selection::BrowseSelection, paper_id::AbstractString, label::AbstractString) = "/label/$(selection.mode)/$(date_string(selection.anchor))/$(String(paper_id))/$(String(label))"

function selection_title(selection::BrowseSelection)
    if selection.mode == "day"
        return "Day of $(date_string(selection.anchor))"
    elseif selection.mode == "week"
        return "Week of $(date_string(selection.lower))"
    end

    return string(Dates.monthname(month(selection.lower)), " ", year(selection.lower))
end

function selection_range_text(selection::BrowseSelection)
    selection.lower == selection.upper && return date_string(selection.lower)
    return "$(date_string(selection.lower)) to $(date_string(selection.upper))"
end

function calendar_month_label(value::Date)
    return string(Dates.monthname(month(value)), " ", year(value))
end