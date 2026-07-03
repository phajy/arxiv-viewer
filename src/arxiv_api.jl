const XPATH_NO_NAMESPACES = ()

function xpath_findall(xpath::AbstractString, document::EzXML.Document)
    return EzXML.findall(String(xpath), document.node, XPATH_NO_NAMESPACES)
end

function xpath_findall(xpath::AbstractString, node)
    return EzXML.findall(String(xpath), node, XPATH_NO_NAMESPACES)
end

function first_node(node, xpath::AbstractString)
    matches = xpath_findall(xpath, node)
    return isempty(matches) ? nothing : first(matches)
end

function first_text(node, xpath::AbstractString)
    match = first_node(node, xpath)
    match === nothing && return nothing
    return compact_whitespace(EzXML.nodecontent(match))
end

function node_attr(node, attribute::AbstractString)
    try
        value = node[String(attribute)]
        return isempty(value) ? nothing : value
    catch
        return nothing
    end
end

function canonical_arxiv_id(raw_id::AbstractString)
    cleaned = replace(String(raw_id), r"^https?://arxiv\.org/abs/" => "")
    cleaned = replace(cleaned, r"^https?://export\.arxiv\.org/abs/" => "")
    return replace(cleaned, r"v\d+$" => "")
end

function is_first_submission(paper::ArxivPaper)
    return paper.published_at == paper.updated_at
end

const ARXIV_REQUEST_LOCK = ReentrantLock()
const ARXIV_NEXT_REQUEST_AT = Ref(0.0)
const ARXIV_MIN_REQUEST_INTERVAL_SECONDS = 3.0
const ARXIV_MAX_RETRY_ATTEMPTS = 5

function throttle_arxiv_request!()
    lock(ARXIV_REQUEST_LOCK)
    try
        now_seconds = Base.time()
        wait_seconds = ARXIV_NEXT_REQUEST_AT[] - now_seconds
        wait_seconds > 0 && sleep(wait_seconds)
        ARXIV_NEXT_REQUEST_AT[] = Base.time() + ARXIV_MIN_REQUEST_INTERVAL_SECONDS
        return max(wait_seconds, 0.0)
    finally
        unlock(ARXIV_REQUEST_LOCK)
    end
end

function arxiv_get(url::AbstractString; context::AbstractString)
    attempt = 1
    request_url = String(url)

    while true
        waited_seconds = throttle_arxiv_request!()
        @info "arXiv request" context attempt waited_seconds request_url
        response = HTTP.get(request_url; status_exception = false)
        @info "arXiv response" context attempt status = response.status request_url body_bytes = length(response.body)

        if response.status == 200
            return response
        elseif response.status == 429 && attempt < ARXIV_MAX_RETRY_ATTEMPTS
            backoff_seconds = ARXIV_MIN_REQUEST_INTERVAL_SECONDS * (2.0 ^ (attempt - 1))
            @warn "arXiv rate limited; retrying" context attempt status = response.status request_url backoff_seconds
            sleep(backoff_seconds)
            attempt += 1
            continue
        end

        error("$context failed with status $(response.status)")
    end
end

function arxiv_html_get(url::AbstractString; context::AbstractString)
    request_url = String(url)
    @info "arXiv request" context request_url
    response = HTTP.get(request_url; status_exception = false)
    @info "arXiv response" context status = response.status request_url body_bytes = length(response.body)
    response.status == 200 || error("$context failed with status $(response.status)")
    return response
end

function build_search_query(start_date::Date, end_date::Date)
    category_clause = join(["cat:$category" for category in ASTRO_PH_CATEGORIES], " OR ")
    date_clause = "submittedDate:[$(query_day_string(start_date))0000 TO $(query_day_string(end_date))2359]"
    return "($(category_clause)) AND $date_clause"
end

function build_query_url(start_date::Date, end_date::Date; start::Integer = 0, max_results::Integer = 200)
    return string(
        HTTP.URI(
            ARXIV_API_URL;
            query = [
                "search_query" => build_search_query(start_date, end_date),
                "sortBy" => "submittedDate",
                "sortOrder" => "descending",
                "start" => string(start),
                "max_results" => string(max_results),
            ],
        ),
    )
end

function build_id_query_url(ids::AbstractVector{<:AbstractString})
    return string(
        HTTP.URI(
            ARXIV_API_URL;
            query = [
                "id_list" => join(String.(ids), ","),
                "start" => "0",
                "max_results" => string(length(ids)),
            ],
        ),
    )
end

function build_catchup_url(subject::AbstractString, day::Date; include_abs::Bool = false)
    return string(
        HTTP.URI(
            "https://arxiv.org/catchup";
            query = [
                "subject" => String(subject),
                "date" => date_string(day),
                "include_abs" => include_abs ? "True" : "False",
            ],
        ),
    )
end

function class_xpath(class_name::AbstractString)
    return ".//*[contains(concat(' ', normalize-space(@class), ' '), ' $(String(class_name)) ')]"
end

function strip_descriptor(text::AbstractString, descriptor::AbstractString)
    normalized = compact_whitespace(text)
    startswith(normalized, descriptor) || return normalized
    return compact_whitespace(replace(normalized, descriptor => ""; count = 1))
end

function first_class_text(node, class_name::AbstractString; descriptor::Union{Nothing, AbstractString} = nothing)
    text = first_text(node, class_xpath(class_name))
    text === nothing && return nothing
    resolved = descriptor === nothing ? text : strip_descriptor(text, descriptor)
    return isempty(resolved) ? nothing : resolved
end

function absolute_arxiv_url(raw_url::AbstractString)
    value = String(raw_url)
    if startswith(value, "http://") || startswith(value, "https://")
        return value
    end
    startswith(value, "/") && return "https://arxiv.org$value"
    return "https://arxiv.org/$value"
end

function first_category_code(text::AbstractString)
    matched = match(r"\(([A-Za-z0-9.\-]+)\)", text)
    return matched === nothing ? "" : String(matched.captures[1])
end

function extract_category_codes(text::AbstractString)
    categories = String[]
    for matched in eachmatch(r"\(([A-Za-z0-9.\-]+)\)", text)
        push!(categories, String(matched.captures[1]))
    end
    return unique(categories)
end

function parse_authors(entry)
    authors = AuthorEntry[]
    for author_node in xpath_findall("./*[local-name()='author']", entry)
        name = first_text(author_node, "./*[local-name()='name']")
        isnothing(name) && continue
        affiliation = first_text(author_node, "./*[local-name()='affiliation']")
        push!(authors, AuthorEntry(name, affiliation))
    end
    return authors
end

function parse_categories(entry)
    categories = String[]
    for category_node in xpath_findall("./*[local-name()='category']", entry)
        term = node_attr(category_node, "term")
        term === nothing && continue
        push!(categories, term)
    end
    return unique(categories)
end

function parse_links(entry)
    abs_url = nothing
    pdf_url = nothing
    for link_node in xpath_findall("./*[local-name()='link']", entry)
        href = node_attr(link_node, "href")
        href === nothing && continue
        rel = maybe_value(node_attr(link_node, "rel"))
        title = maybe_value(node_attr(link_node, "title"))

        if rel == "alternate"
            abs_url = href
        elseif title == "pdf"
            pdf_url = href
        end
    end
    return (; abs_url, pdf_url)
end

function parse_entry(entry)
    entry_id = first_text(entry, "./*[local-name()='id']")
    title = first_text(entry, "./*[local-name()='title']")
    summary = first_text(entry, "./*[local-name()='summary']")
    published_at = first_text(entry, "./*[local-name()='published']")
    updated_at = first_text(entry, "./*[local-name()='updated']")
    primary_category_node = first_node(entry, "./*[local-name()='primary_category']")
    primary_category = primary_category_node === nothing ? "" : something(node_attr(primary_category_node, "term"), "")
    comment = first_text(entry, "./*[local-name()='comment']")
    journal_ref = first_text(entry, "./*[local-name()='journal_ref']")
    doi = first_text(entry, "./*[local-name()='doi']")
    links = parse_links(entry)

    if isnothing(entry_id) || isnothing(title) || isnothing(summary) || isnothing(published_at) || isnothing(updated_at) || isnothing(links.abs_url)
        return nothing
    end

    return ArxivPaper(
        canonical_arxiv_id(entry_id),
        title,
        summary,
        published_at,
        updated_at,
        first(published_at, 10),
        primary_category,
        doi,
        links.pdf_url,
        links.abs_url,
        comment,
        journal_ref,
        parse_authors(entry),
        parse_categories(entry),
    )
end

function parse_feed(body::AbstractString)
    document = EzXML.parsexml(String(body))
    papers = ArxivPaper[]
    for entry in xpath_findall("/*[local-name()='feed']/*[local-name()='entry']", document)
        paper = parse_entry(entry)
        paper === nothing && continue
        is_first_submission(paper) || continue
        push!(papers, paper)
    end

    return papers
end

function fetch_arxiv_page(start_date::Date, end_date::Date; start::Integer = 0, max_results::Integer = 200)
    response = arxiv_get(
        build_query_url(start_date, end_date; start, max_results);
        context = "arXiv API request",
    )
    return parse_feed(String(response.body))
end

function fetch_arxiv_papers(start_date::Date, end_date::Date; max_results::Integer = 200)
    papers = Dict{String, ArxivPaper}()
    start = 0

    while true
        page = fetch_arxiv_page(start_date, end_date; start, max_results)
        for paper in page
            papers[paper.arxiv_id] = paper
        end
        length(page) < max_results && break
        start += max_results
    end

    return sort!(collect(values(papers)); by = paper -> (paper.submitted_on, lowercase(paper.title)), rev = true)
end

function fetch_arxiv_papers_by_ids(ids::AbstractVector{<:AbstractString}; batch_size::Integer = 50)
    isempty(ids) && return ArxivPaper[]

    papers = Dict{String, ArxivPaper}()
    unique_ids = unique(String.(ids))
    start_index = 1

    while start_index <= length(unique_ids)
        end_index = min(start_index + batch_size - 1, length(unique_ids))
        batch_ids = unique_ids[start_index:end_index]
        response = arxiv_get(build_id_query_url(batch_ids); context = "arXiv API request")

        for paper in parse_feed(String(response.body))
            papers[paper.arxiv_id] = paper
        end

        start_index = end_index + 1
    end

    return sort!(collect(values(papers)); by = paper -> lowercase(paper.title))
end

function extract_catchup_ids(fragment::AbstractString)
    ids = String[]

    for match in eachmatch(r"""href\s*=\s*"/abs/([^"]+)""", fragment)
        push!(ids, canonical_arxiv_id(match.captures[1]))
    end

    return unique(ids)
end

function catchup_section(body::AbstractString, heading::AbstractString, following_headings::Vector{String})
    heading_range = findfirst(heading, body)
    heading_range === nothing && return ""

    start_index = first(heading_range)
    end_index = lastindex(body)
    search_start = last(heading_range) + 1

    for next_heading in following_headings
        next_range = findnext(next_heading, body, search_start)
        next_range === nothing && continue
        end_index = min(end_index, first(next_range) - 1)
    end

    return body[start_index:end_index]
end

function catchup_sections(body::AbstractString)
    cross_heading = if occursin("<h3>Cross submissions", body)
        "<h3>Cross submissions"
    elseif occursin("<h3>Cross-lists", body)
        "<h3>Cross-lists"
    else
        nothing
    end

    new_following = ["<h3>Replacements"]
    cross_heading === nothing || pushfirst!(new_following, cross_heading)

    new_section = catchup_section(body, "<h3>New submissions", new_following)
    cross_section = cross_heading === nothing ? "" : catchup_section(body, cross_heading, ["<h3>Replacements"])

    return (; new_section, cross_section)
end

function listing_entries_fragment(section_html::AbstractString)
    start_range = findfirst(r"<dt\b", section_html)
    start_range === nothing && return ""

    fragment = section_html[first(start_range):end]
    end_range = findfirst("</dl>", fragment)
    end_range === nothing && return fragment
    return fragment[1:first(end_range) - 1]
end

function parse_listing_authors(metadata_node)
    authors_node = first_node(metadata_node, class_xpath("list-authors"))
    authors_node === nothing && return AuthorEntry[]

    authors = AuthorEntry[]
    seen_names = Set{String}()
    for author_node in xpath_findall(".//a", authors_node)
        name = compact_whitespace(EzXML.nodecontent(author_node))
        isempty(name) && continue
        name in seen_names && continue
        push!(authors, AuthorEntry(name, nothing))
        push!(seen_names, name)
    end

    return authors
end

function parse_listing_entry(identifier_node, metadata_node, listed_day::Date)
    abstract_node = first_node(metadata_node, ".//p[contains(concat(' ', normalize-space(@class), ' '), ' mathjax ')]")
    abstract_text = abstract_node === nothing ? "" : compact_whitespace(EzXML.nodecontent(abstract_node))

    title = first_class_text(metadata_node, "list-title"; descriptor = "Title:")
    title === nothing && return nothing

    abs_node = first_node(identifier_node, "./a[@title='Abstract']")
    abs_node === nothing && return nothing

    abs_href = node_attr(abs_node, "href")
    abs_href === nothing && return nothing

    raw_id = something(node_attr(abs_node, "id"), abs_href)
    arxiv_id = canonical_arxiv_id(raw_id)
    isempty(arxiv_id) && return nothing

    pdf_node = first_node(identifier_node, "./a[@title='Download PDF']")
    pdf_href = pdf_node === nothing ? nothing : node_attr(pdf_node, "href")

    subject_text = something(first_class_text(metadata_node, "list-subjects"; descriptor = "Subjects:"), "")
    primary_subject_text = first_text(metadata_node, class_xpath("primary-subject"))
    primary_category = primary_subject_text === nothing ? "" : first_category_code(primary_subject_text)
    categories = extract_category_codes(subject_text)
    !isempty(primary_category) && primary_category ∉ categories && pushfirst!(categories, primary_category)

    listed_on = date_string(listed_day)
    listed_at = "$(listed_on)T00:00:00Z"

    return ArxivPaper(
        arxiv_id,
        title,
        abstract_text,
        listed_at,
        listed_at,
        listed_on,
        primary_category,
        first_class_text(metadata_node, "list-doi"; descriptor = "DOI:"),
        pdf_href === nothing ? nothing : absolute_arxiv_url(pdf_href),
        absolute_arxiv_url(abs_href),
        first_class_text(metadata_node, "list-comments"; descriptor = "Comments:"),
        first_class_text(metadata_node, "list-journal-ref"; descriptor = "Journal-ref:"),
        parse_listing_authors(metadata_node),
        categories,
    )
end

function parse_listing_section_papers(section_html::AbstractString, listed_day::Date)
    fragment = listing_entries_fragment(section_html)
    isempty(strip(fragment)) && return ArxivPaper[]

    document = EzXML.parsehtml("<html><body><dl>$(fragment)</dl></body></html>")
    identifier_nodes = xpath_findall("//dt", document)
    metadata_nodes = xpath_findall("//dd", document)
    papers = ArxivPaper[]

    for (identifier_node, metadata_node) in zip(identifier_nodes, metadata_nodes)
        paper = parse_listing_entry(identifier_node, metadata_node, listed_day)
        paper === nothing && continue
        push!(papers, paper)
    end

    return papers
end

function parse_catchup_ids(body::AbstractString)
    ids = String[]

    sections = catchup_sections(body)

    append!(ids, extract_catchup_ids(sections.new_section))
    append!(ids, extract_catchup_ids(sections.cross_section))

    return unique(ids)
end

function parse_catchup_papers(body::AbstractString, listed_day::Date)
    papers = Dict{String, ArxivPaper}()

    sections = catchup_sections(body)

    for section in (sections.new_section, sections.cross_section)
        for paper in parse_listing_section_papers(section, listed_day)
            papers[paper.arxiv_id] = paper
        end
    end

    return sort!(collect(values(papers)); by = paper -> lowercase(paper.title))
end

function fetch_catchup_ids(day::Date; subject::AbstractString = "astro-ph")
    response = arxiv_html_get(build_catchup_url(subject, day); context = "arXiv catch-up request")
    return parse_catchup_ids(String(response.body))
end

function fetch_catchup_papers(day::Date; subject::AbstractString = "astro-ph")
    response = arxiv_html_get(
        build_catchup_url(subject, day; include_abs = true);
        context = "arXiv catch-up listing request",
    )
    return parse_catchup_papers(String(response.body), day)
end

previous_business_day(day::Date) = begin
    candidate = day - Day(1)
    while dayofweek(candidate) > 5
        candidate -= Day(1)
    end
    return candidate
end

const LATEST_LISTED_DAY_CACHE_TTL = Minute(15)
const latest_listed_day_cache = Ref{Union{Nothing, NamedTuple{(:reference_day, :resolved_day, :expires_at), Tuple{Date, Date, DateTime}}}}(nothing)

function latest_listed_day_uncached(; reference_day::Date = Dates.today(), fetch_ids::Function = fetch_catchup_ids, max_lookback::Integer = 5)
    candidate = dayofweek(reference_day) > 5 ? previous_business_day(reference_day) : reference_day
    fallback_day = candidate

    for _ in 0:max(max_lookback, 0)
        ids = fetch_ids(candidate)
        !isempty(ids) && return candidate
        candidate = previous_business_day(candidate)
    end

    return fallback_day
end

function latest_listed_day(; reference_day::Date = Dates.today(), fetch_ids::Function = fetch_catchup_ids, max_lookback::Integer = 5)
    if fetch_ids === fetch_catchup_ids
        cache = latest_listed_day_cache[]
        if cache !== nothing && cache.reference_day == reference_day && cache.expires_at >= Dates.now()
            return cache.resolved_day
        end
    end

    resolved_day = latest_listed_day_uncached(; reference_day, fetch_ids, max_lookback)

    if fetch_ids === fetch_catchup_ids
        latest_listed_day_cache[] = (
            reference_day = reference_day,
            resolved_day = resolved_day,
            expires_at = Dates.now() + LATEST_LISTED_DAY_CACHE_TTL,
        )
    end

    return resolved_day
end

function default_window_selection(window::AbstractString; reference_day::Date = Dates.today(), fetch_ids::Function = fetch_catchup_ids)
    resolved_reference_day = latest_listed_day(; reference_day, fetch_ids)
    return window_selection(window; reference_day = resolved_reference_day)
end

function ingest_range!(start_date::Date, end_date::Date)
    init_database!()

    started_at = timestamp_now()
    inserted_count = 0
    status = "success"
    message = nothing

    try
        papers = fetch_arxiv_papers(start_date, end_date)
        with_db() do db
            for paper in papers
                upsert_paper!(db, paper)
            end
        end
        recompute_paper_scores!()
        inserted_count = length(papers)
        return inserted_count
    catch err
        status = "error"
        message = sprint(showerror, err)
        rethrow(err)
    finally
        record_ingestion_run!(started_at, timestamp_now(), start_date, end_date, inserted_count, status, message)
    end
end

function ingest_listed_range!(start_date::Date, end_date::Date; subject::AbstractString = "astro-ph")
    init_database!()

    started_at = timestamp_now()
    inserted_count = 0
    status = "success"
    message = nothing

    try
        papers_by_id = Dict{String, ArxivPaper}()
        appearance_by_id = Dict{String, String}()
        current_day = start_date

        while current_day <= end_date
            papers = fetch_catchup_papers(current_day; subject)
            for paper in papers
                papers_by_id[paper.arxiv_id] = paper
                appearance_by_id[paper.arxiv_id] = date_string(current_day)
            end
            current_day += Day(1)
        end

        papers = sort!(collect(values(papers_by_id)); by = paper -> (appearance_by_id[paper.arxiv_id], lowercase(paper.title)))
        with_db() do db
            for paper in papers
                upsert_paper!(db, paper; appeared_on = appearance_by_id[paper.arxiv_id])
            end
        end

        recompute_paper_scores!()
        inserted_count = length(papers)
        return inserted_count
    catch err
        status = "error"
        message = sprint(showerror, err)
        rethrow(err)
    finally
        record_ingestion_run!(started_at, timestamp_now(), start_date, end_date, inserted_count, status, message)
    end
end

function refresh_recent!(; days::Integer = lookback_days())
    upper = Dates.today()
    lower = upper - Day(max(days - 1, 0))
    return ingest_listed_range!(lower, upper)
end

function refresh_selection!(selection::BrowseSelection)
    return ingest_listed_range!(selection.lower, selection.upper)
end

function startup_refresh_today!(;
    reference_day::Date = Dates.today(),
    refresh!::Function = refresh_selection!,
    selection_for_refresh::Function = day -> default_window_selection("today"; reference_day = day),
)
    selection = selection_for_refresh(reference_day)

    if selection_has_successful_ingestion(selection)
        @info "Skipping startup refresh; today's selection already has a successful local refresh" selection = selection_range_text(selection)
        return 0
    end

    if selection_has_local_papers(selection)
        @info "Skipping startup refresh; today's papers already exist locally" selection = selection_range_text(selection)
        return 0
    end

    @info "Refreshing today's astro-ph papers on startup" selection = selection_range_text(selection)
    return refresh!(selection)
end

function bootstrap_recent_if_empty!()
    paper_count() > 0 && return false
    @info "Bootstrapping recent astro-ph submissions" lookback_days = lookback_days()
    refresh_recent!()
    return true
end