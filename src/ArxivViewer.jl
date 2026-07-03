module ArxivViewer

using Dates
using Logging

using DBInterface
using EzXML
using Genie
using Genie.Renderer.Html
using Genie.Router
using HTTP
using JSON3
using SQLite

const ROUTES_REGISTERED = Ref(false)
const ARXIV_API_URL = "https://export.arxiv.org/api/query"
const ASTRO_PH_CATEGORIES = [
    "astro-ph.CO",
    "astro-ph.EP",
    "astro-ph.GA",
    "astro-ph.HE",
    "astro-ph.IM",
    "astro-ph.SR",
]
const BROWSE_MODES = ("day", "week", "month")
const WINDOW_LABELS = Dict(
    "today" => "Today",
    "week" => "This Week",
    "month" => "This Month",
)
const LABEL_OPTIONS = ["not_interested", "interested", "very_interested"]
const LABEL_DISPLAY = Dict(
    "not_interested" => "-",
    "interested" => "+",
    "very_interested" => "++",
)

struct AuthorEntry
    name::String
    affiliation::Union{Nothing, String}
end

struct BrowseSelection
    mode::String
    anchor::Date
    lower::Date
    upper::Date
    reference_day::Date
end

struct ArxivPaper
    arxiv_id::String
    title::String
    abstract::String
    published_at::String
    updated_at::String
    submitted_on::String
    primary_category::String
    doi::Union{Nothing, String}
    pdf_url::Union{Nothing, String}
    abs_url::String
    comment::Union{Nothing, String}
    journal_ref::Union{Nothing, String}
    authors::Vector{AuthorEntry}
    categories::Vector{String}
end

include("config.jl")
include("database.jl")
include("arxiv_api.jl")
include("summaries.jl")
include("web.jl")

export init_database!, refresh_recent!, start_server

end