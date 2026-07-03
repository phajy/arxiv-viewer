const ABSTRACT_SUMMARY_PROMPT_VERSION = "abstract-v1"
const PDF_SUMMARY_PROMPT_VERSION = "pdf-v1"
const SELECTION_SUMMARY_PROMPT_VERSION = "selection-v1"
const PDF_SUMMARY_TEXT_LIMIT = 30000
const ABSTRACT_PROMPT_TEXT_LIMIT = 1600
const SELECTION_PROMPT_TEXT_LIMIT = 800

function truncate_chars(text::AbstractString, limit::Integer)
    limit <= 0 && return ""
    length(text) <= limit && return String(text)
    return String(first(text, limit))
end

function excerpt_text(text::AbstractString, limit::Integer)
    cleaned = strip(replace(String(text), "\r" => ""))
    isempty(cleaned) && return ""
    length(cleaned) <= limit && return cleaned

    head_limit = max(Int(floor(limit * 0.7)), 1)
    tail_limit = max(limit - head_limit, 1)
    return string(first(cleaned, head_limit), "\n\n[... omitted ...]\n\n", last(cleaned, tail_limit))
end

function summary_text_html(text::AbstractString)
    cleaned = strip(String(text))
    isempty(cleaned) && return ""
    return replace(html_escape(cleaned), "\n" => "<br>")
end

function title_slug(text::AbstractString; max_words::Integer = 3)
    tokens = String[]

    for match in eachmatch(r"[A-Za-z0-9]+", lowercase(text))
        token = match.match
        length(token) <= 1 && continue
        push!(tokens, token)
        length(tokens) >= max_words && break
    end

    return isempty(tokens) ? "paper" : join(tokens, "_")
end

function author_last_name_slug(name::AbstractString)
    for part in Iterators.reverse(split(strip(String(name))))
        cleaned = lowercase(replace(part, r"[^A-Za-z0-9]+" => ""))
        isempty(cleaned) || return cleaned
    end

    return "unknown"
end

paper_id_slug(paper_id::AbstractString) = lowercase(replace(String(paper_id), r"[^A-Za-z0-9]+" => "_"))

function paper_reference_day(row)
    appeared_on = maybe_string(row.appeared_on)
    submitted_on = maybe_string(row.submitted_on)
    day_text = isempty(appeared_on) ? submitted_on : appeared_on
    return Date(day_text, DAY_FMT)
end

function paper_pdf_relative_path(row)
    paper_day = paper_reference_day(row)
    year_dir = string(Dates.year(paper_day))
    month_dir = lpad(string(Dates.month(paper_day)), 2, '0')
    day_dir = lpad(string(Dates.day(paper_day)), 2, '0')
    author_slug = author_last_name_slug(maybe_string(row.first_author))
    short_title = title_slug(maybe_string(row.title))
    filename = "$(author_slug)_$(short_title)_$(paper_id_slug(maybe_string(row.arxiv_id))).pdf"
    return joinpath("pdfs", year_dir, month_dir, day_dir, filename)
end

paper_pdf_absolute_path(row) = joinpath(data_dir(), paper_pdf_relative_path(row))

function default_pdf_downloader(url::AbstractString)
    return HTTP.get(String(url); redirect = true)
end

function open_in_preview(path::AbstractString)
    run(Cmd(["open", "-a", "Preview", String(path)]))
    return nothing
end

function extract_pdf_text(path::AbstractString; executable::AbstractString = pdftotext_executable())
    command = Cmd([String(executable), "-layout", String(path), "-"])
    text = read(command, String)
    cleaned = strip(replace(text, "\r" => ""))
    isempty(cleaned) && error("pdftotext produced no text for $(String(path))")
    return cleaned
end

function ollama_generate_text(prompt::AbstractString; model::AbstractString = summary_model(), system::Union{Nothing, AbstractString} = nothing)
    payload = Dict{String, Any}(
        "model" => String(model),
        "prompt" => String(prompt),
        "stream" => false,
        "options" => Dict("temperature" => 0.2),
    )
    system === nothing || (payload["system"] = String(system))

    response = HTTP.post(
        ollama_generate_url(),
        ["Content-Type" => "application/json"],
        JSON3.write(payload),
    )
    response.status == 200 || error("Ollama generation failed with status $(response.status)")

    body = JSON3.read(String(response.body))
    hasproperty(body, :response) || error("Ollama response did not contain generated text")

    generated = strip(String(getproperty(body, :response)))
    isempty(generated) && error("Ollama returned an empty summary")
    return generated
end

function abstract_summary_prompt(row)
    abstract_text = excerpt_text(compact_whitespace(maybe_string(row.abstract)), ABSTRACT_PROMPT_TEXT_LIMIT)

    return """
You are helping an astrophysicist scan newly listed arXiv papers.

Write a concise plain-text summary using exactly this structure:
Summary: <two sentences max>
Key points:
- <point 1>
- <point 2>
- <point 3>
Interest fit: <one sentence on likely relevance>

Keep the wording factual and avoid hype.

Title: $(maybe_string(row.title))
Primary category: $(maybe_string(row.primary_category))
Categories: $(maybe_string(row.categories))
Authors: $(maybe_string(row.authors))
Abstract:
$(abstract_text)
"""
end

function pdf_summary_prompt(row, pdf_text::AbstractString)
    text_excerpt = excerpt_text(pdf_text, PDF_SUMMARY_TEXT_LIMIT)

    return """
You are helping an astrophysicist decide whether to read a paper in full.

Write a concise plain-text summary using exactly this structure:
Summary: <three sentences max>
Key contributions:
- <point 1>
- <point 2>
- <point 3>
Methods/data:
- <bullet>
- <bullet>
Reasons to read:
- <bullet>
- <bullet>

Stay close to the source text and do not speculate.

Title: $(maybe_string(row.title))
Categories: $(maybe_string(row.categories))
Authors: $(maybe_string(row.authors))
Extracted paper text:
$(text_excerpt)
"""
end

function selection_summary_prompt(selection::BrowseSelection, rows)
    paper_blocks = String[]

    for (index, row) in enumerate(rows)
        abstract_source = maybe_string(row.abstract_summary)
        isempty(abstract_source) && (abstract_source = excerpt_text(compact_whitespace(maybe_string(row.abstract)), SELECTION_PROMPT_TEXT_LIMIT))

        push!(
            paper_blocks,
            """
$(index). $(maybe_string(row.title))
arXiv id: $(maybe_string(row.arxiv_id))
Score: $(round(Float64(row.score); digits = 1))/10
Categories: $(maybe_string(row.categories))
Authors: $(maybe_string(row.authors))
Paper summary:
$(abstract_source)
""",
        )
    end

    return """
Summarize the top $(length(rows)) papers for this arXiv selection.

Write plain text using exactly this structure:
Overview: <two to four sentences>
Themes:
- <theme 1>
- <theme 2>
- <theme 3>
Papers to prioritize:
- <arXiv id>: <one sentence>
- <arXiv id>: <one sentence>
- <arXiv id>: <one sentence>

Selection title: $(selection_title(selection))
Selection range: $(selection_range_text(selection))

Top papers:
$(join(paper_blocks, "\n"))
"""
end

function ensure_local_pdf!(paper_id::AbstractString; downloader::Function = default_pdf_downloader)
    existing = pdf_download_for_paper(paper_id)
    if existing !== nothing
        local_path = maybe_string(existing.local_path)
        !isempty(local_path) && isfile(local_path) && return local_path
    end

    row = paper_detail(paper_id)
    row === nothing && error("Unknown paper id $(String(paper_id))")

    pdf_url = maybe_value(row.pdf_url)
    pdf_url === nothing && error("No PDF URL is available for $(String(paper_id))")

    destination = paper_pdf_absolute_path(row)
    mkpath(dirname(destination))

    response = downloader(pdf_url)
    Int(response.status) == 200 || error("PDF download failed with status $(response.status)")

    open(destination, "w") do io
        write(io, response.body)
    end

    save_pdf_download!(paper_id, destination, pdf_url, filesize(destination))
    return destination
end

function open_local_pdf!(paper_id::AbstractString; downloader::Function = default_pdf_downloader, opener::Function = open_in_preview)
    local_path = ensure_local_pdf!(paper_id; downloader)
    mark_pdf_opened!(paper_id)
    opener(local_path)
    return local_path
end

function summarize_abstract!(paper_id::AbstractString; generator::Function = ollama_generate_text, force::Bool = false)
    cached = abstract_summary_for_paper(paper_id)
    if !force && cached !== nothing
        return maybe_string(cached.summary_text)
    end

    row = paper_detail(paper_id)
    row === nothing && error("Unknown paper id $(String(paper_id))")

    summary_text = generator(
        abstract_summary_prompt(row);
        model = summary_model(),
        system = "You produce concise scientific reading summaries.",
    )
    save_abstract_summary!(paper_id, summary_model(), ABSTRACT_SUMMARY_PROMPT_VERSION, summary_text)
    return summary_text
end

function summarize_pdf!(paper_id::AbstractString; generator::Function = ollama_generate_text, downloader::Function = default_pdf_downloader, extractor::Function = extract_pdf_text, force::Bool = false)
    cached = pdf_summary_for_paper(paper_id)
    if !force && cached !== nothing
        return maybe_string(cached.summary_text)
    end

    local_path = ensure_local_pdf!(paper_id; downloader)
    row = paper_detail(paper_id)
    row === nothing && error("Unknown paper id $(String(paper_id))")

    pdf_text = extractor(local_path)
    summary_text = generator(
        pdf_summary_prompt(row, pdf_text);
        model = summary_model(),
        system = "You produce concise paper-reading summaries grounded in extracted text.",
    )
    save_pdf_summary!(paper_id, local_path, summary_model(), PDF_SUMMARY_PROMPT_VERSION, summary_text)
    return summary_text
end

function summarize_selection!(selection::BrowseSelection; top_n::Integer = default_top_summary_count(), generator::Function = ollama_generate_text, force::Bool = false)
    cached = latest_selection_summary_for(selection)
    if !force && cached !== nothing && Int(cached.top_n) == Int(top_n)
        return maybe_string(cached.summary_text)
    end

    papers = list_papers(selection)
    isempty(papers) && error("No papers are available in $(selection_range_text(selection))")

    limit = min(length(papers), max(Int(top_n), 1))
    rows = papers[1:limit]
    summary_text = generator(
        selection_summary_prompt(selection, rows);
        model = summary_model(),
        system = "You produce concise overview summaries for ranked astronomy paper lists.",
    )
    save_selection_summary!(selection, limit, summary_model(), SELECTION_SUMMARY_PROMPT_VERSION, summary_text)
    return summary_text
end