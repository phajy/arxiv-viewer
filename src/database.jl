function ensure_data_dir!()
    mkpath(data_dir())
    return nothing
end

function with_db(f::Function)
    ensure_data_dir!()
    db = SQLite.DB(db_path())
    try
        execute_sql(db, "PRAGMA foreign_keys = ON")
        return f(db)
    finally
        SQLite.close(db)
    end
end

function materialize_row(row)
    return (; (name => getproperty(row, name) for name in propertynames(row))...)
end

function materialize_rows(result)
    rows = NamedTuple[]
    for row in result
        push!(rows, materialize_row(row))
    end
    return rows
end

function with_query(f::Function, db::SQLite.DB, sql::AbstractString, params::DBInterface.StatementParams = ())
    stmt = SQLite.Stmt(db, sql; register = false)
    try
        query = DBInterface.execute(stmt, params)
        try
            return f(query)
        finally
            DBInterface.close!(query)
        end
    finally
        DBInterface.close!(stmt)
    end
end

function query_rows(db::SQLite.DB, sql::AbstractString, params::DBInterface.StatementParams = ())
    return with_query(db, sql, params) do query
        materialize_rows(query)
    end
end

function query_first_row(db::SQLite.DB, sql::AbstractString, params::DBInterface.StatementParams = ())
    return with_query(db, sql, params) do query
        state = iterate(query)
        state === nothing && return nothing
        return materialize_row(state[1])
    end
end

function execute_sql(db::SQLite.DB, sql::AbstractString, params::DBInterface.StatementParams = ())
    SQLite.execute(db, sql, params)
    return nothing
end

function ensure_column!(db::SQLite.DB, table_name::AbstractString, column_name::AbstractString, definition::AbstractString)
    rows = query_rows(db, "PRAGMA table_info($(String(table_name)))")
    any(maybe_string(row.name) == String(column_name) for row in rows) && return nothing

    execute_sql(db, "ALTER TABLE $(String(table_name)) ADD COLUMN $(String(column_name)) $(String(definition))")
    return nothing
end

function init_database!()
    with_db() do db
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS papers (
                arxiv_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                abstract TEXT NOT NULL,
                published_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                submitted_on TEXT NOT NULL,
                appeared_on TEXT,
                primary_category TEXT,
                doi TEXT,
                pdf_url TEXT,
                abs_url TEXT NOT NULL,
                comment TEXT,
                journal_ref TEXT,
                last_ingested_at TEXT NOT NULL
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS paper_authors (
                paper_id TEXT NOT NULL,
                author_position INTEGER NOT NULL,
                author_name TEXT NOT NULL,
                affiliation TEXT,
                PRIMARY KEY (paper_id, author_position),
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS paper_categories (
                paper_id TEXT NOT NULL,
                category_code TEXT NOT NULL,
                is_primary INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (paper_id, category_code),
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS user_labels (
                paper_id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS paper_scores (
                paper_id TEXT PRIMARY KEY,
                score REAL NOT NULL,
                score_details TEXT NOT NULL,
                ranked_at TEXT NOT NULL,
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS abstract_summaries (
                paper_id TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                summary_text TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS pdf_downloads (
                paper_id TEXT PRIMARY KEY,
                local_path TEXT NOT NULL,
                source_url TEXT NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                downloaded_at TEXT NOT NULL,
                open_count INTEGER NOT NULL DEFAULT 0,
                last_opened_at TEXT,
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS pdf_summaries (
                paper_id TEXT PRIMARY KEY,
                local_path TEXT NOT NULL,
                model TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                summary_text TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                FOREIGN KEY (paper_id) REFERENCES papers(arxiv_id) ON DELETE CASCADE
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS selection_summaries (
                selection_key TEXT PRIMARY KEY,
                selection_mode TEXT NOT NULL,
                anchor_day TEXT NOT NULL,
                lower_day TEXT NOT NULL,
                upper_day TEXT NOT NULL,
                top_n INTEGER NOT NULL,
                model TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                summary_text TEXT NOT NULL,
                generated_at TEXT NOT NULL
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS ingestion_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                finished_at TEXT NOT NULL,
                from_date TEXT NOT NULL,
                to_date TEXT NOT NULL,
                inserted_count INTEGER NOT NULL,
                status TEXT NOT NULL,
                message TEXT
            )
        """)
        execute_sql(db, """
            CREATE TABLE IF NOT EXISTS viewed_days (
                viewed_on TEXT PRIMARY KEY,
                last_viewed_at TEXT NOT NULL
            )
        """)
        ensure_column!(db, "papers", "appeared_on", "TEXT")
        execute_sql(db, "UPDATE papers SET appeared_on = submitted_on WHERE appeared_on IS NULL OR appeared_on = ''")
        execute_sql(db, "CREATE INDEX IF NOT EXISTS idx_papers_submitted_on ON papers(submitted_on)")
        execute_sql(db, "CREATE INDEX IF NOT EXISTS idx_papers_appeared_on ON papers(appeared_on)")
        execute_sql(db, "CREATE INDEX IF NOT EXISTS idx_labels_updated_at ON user_labels(updated_at)")
        execute_sql(db, "CREATE INDEX IF NOT EXISTS idx_paper_scores_score ON paper_scores(score DESC)")
        execute_sql(db, "CREATE INDEX IF NOT EXISTS idx_selection_summaries_generated_at ON selection_summaries(generated_at DESC)")
    end

    return nothing
end

function record_ingestion_run!(started_at::String, finished_at::String, from_date::Date, to_date::Date, inserted_count::Integer, status::String, message::Union{Nothing, String})
    with_db() do db
        execute_sql(
            db,
            "INSERT INTO ingestion_runs (started_at, finished_at, from_date, to_date, inserted_count, status, message) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (started_at, finished_at, date_string(from_date), date_string(to_date), inserted_count, status, message),
        )
    end

    return nothing
end

function upsert_paper!(db::SQLite.DB, paper::ArxivPaper; appeared_on::Union{Nothing, Date, AbstractString} = nothing)
    resolved_appeared_on = if appeared_on === nothing
        paper.submitted_on
    elseif appeared_on isa Date
        date_string(appeared_on)
    else
        String(appeared_on)
    end

    execute_sql(
        db,
        """
        INSERT INTO papers (
            arxiv_id, title, abstract, published_at, updated_at, submitted_on, appeared_on,
            primary_category, doi, pdf_url, abs_url, comment, journal_ref, last_ingested_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(arxiv_id) DO UPDATE SET
            title = excluded.title,
            abstract = excluded.abstract,
            published_at = excluded.published_at,
            updated_at = excluded.updated_at,
            submitted_on = excluded.submitted_on,
            appeared_on = excluded.appeared_on,
            primary_category = excluded.primary_category,
            doi = excluded.doi,
            pdf_url = excluded.pdf_url,
            abs_url = excluded.abs_url,
            comment = excluded.comment,
            journal_ref = excluded.journal_ref,
            last_ingested_at = excluded.last_ingested_at
        """,
        (
            paper.arxiv_id,
            paper.title,
            paper.abstract,
            paper.published_at,
            paper.updated_at,
            paper.submitted_on,
            resolved_appeared_on,
            paper.primary_category,
            paper.doi,
            paper.pdf_url,
            paper.abs_url,
            paper.comment,
            paper.journal_ref,
            timestamp_now(),
        ),
    )

    execute_sql(db, "DELETE FROM paper_authors WHERE paper_id = ?", (paper.arxiv_id,))
    execute_sql(db, "DELETE FROM paper_categories WHERE paper_id = ?", (paper.arxiv_id,))

    for (index, author) in enumerate(paper.authors)
        execute_sql(
            db,
            "INSERT INTO paper_authors (paper_id, author_position, author_name, affiliation) VALUES (?, ?, ?, ?)",
            (paper.arxiv_id, index, author.name, author.affiliation),
        )
    end

    for category in paper.categories
        execute_sql(
            db,
            "INSERT INTO paper_categories (paper_id, category_code, is_primary) VALUES (?, ?, ?)",
            (paper.arxiv_id, category, category == paper.primary_category ? 1 : 0),
        )
    end

    return nothing
end

function paper_count()
    with_db() do db
        row = query_first_row(db, "SELECT COUNT(*) AS total FROM papers")
        return Int(row.total)
    end
end

function latest_submission_day()
    with_db() do db
        row = query_first_row(db, "SELECT MAX(submitted_on) AS latest FROM papers")
        value = maybe_value(row.latest)
        value === nothing && return nothing
        return Date(value, DAY_FMT)
    end
end

function latest_appearance_day()
    with_db() do db
        row = query_first_row(db, "SELECT MAX(COALESCE(appeared_on, submitted_on)) AS latest FROM papers")
        value = maybe_value(row.latest)
        value === nothing && return nothing
        return Date(value, DAY_FMT)
    end
end

const SCORE_BASELINE = 4.6
const SCORE_TITLE_TOKEN_WEIGHT = 1.5
const SCORE_ABSTRACT_TOKEN_WEIGHT = 0.45
const SCORE_CATEGORY_TOKEN_WEIGHT = 1.2
const SCORE_RECENCY_WINDOW_DAYS = 21.0
const SCORE_RECENCY_MAX = 0.8
const SCORE_SEED_SCALE = 1.8
const SCORE_PROFILE_SCALE = 2.2
const SCORE_LABEL_ADJUSTMENTS = Dict(
    "very_interested" => 2.2,
    "interested" => 0.9,
    "not_interested" => -2.6,
)
const SCORE_PROFILE_LABEL_WEIGHTS = Dict(
    "very_interested" => 2.0,
    "interested" => 1.0,
    "not_interested" => -1.5,
)
const SCORE_SEED_WEIGHTS = Dict(
    "cat:astro-ph.he" => 2.0,
    "cat:astro-ph.ga" => 0.8,
    "cat:astro-ph.co" => 0.4,
    "accretion" => 2.0,
    "agn" => 1.8,
    "black" => 1.6,
    "hole" => 1.2,
    "disk" => 1.0,
    "disks" => 1.0,
    "jet" => 1.4,
    "jets" => 1.4,
    "x-ray" => 1.8,
    "xray" => 1.8,
    "transient" => 1.6,
    "neutron" => 1.4,
    "pulsar" => 1.4,
    "magnetar" => 1.6,
    "binary" => 0.8,
    "binaries" => 0.8,
    "cluster" => 1.0,
    "clusters" => 1.0,
    "gravitational" => 1.0,
)
const SCORE_STOPWORDS = Set([
    "about",
    "after",
    "also",
    "among",
    "and",
    "around",
    "based",
    "been",
    "being",
    "between",
    "both",
    "each",
    "find",
    "found",
    "from",
    "have",
    "having",
    "here",
    "however",
    "include",
    "including",
    "into",
    "more",
    "most",
    "other",
    "paper",
    "propose",
    "provide",
    "reported",
    "respectively",
    "results",
    "sample",
    "show",
    "shows",
    "study",
    "such",
    "than",
    "that",
    "the",
    "there",
    "their",
    "these",
    "they",
    "this",
    "through",
    "toward",
    "towards",
    "using",
    "various",
    "were",
    "what",
    "when",
    "where",
    "which",
    "while",
    "with",
    "within",
])

function score_tokenize(text::AbstractString)
    tokens = String[]
    for match in eachmatch(r"[A-Za-z][A-Za-z0-9\-]{1,}", lowercase(text))
        token = match.match
        length(token) <= 2 && continue
        token in SCORE_STOPWORDS && continue
        push!(tokens, token)
    end

    return tokens
end

function merge_score_tokens!(weights::Dict{String, Float64}, tokens, token_weight::Real)
    scaled_weight = Float64(token_weight)
    for token in tokens
        key = String(token)
        weights[key] = get(weights, key, 0.0) + scaled_weight
    end

    return weights
end

function paper_score_features(row)
    weights = Dict{String, Float64}()
    merge_score_tokens!(weights, score_tokenize(maybe_string(row.title)), SCORE_TITLE_TOKEN_WEIGHT)
    merge_score_tokens!(weights, score_tokenize(maybe_string(row.abstract)), SCORE_ABSTRACT_TOKEN_WEIGHT)

    categories = Set{String}()
    primary_category = lowercase(strip(maybe_string(row.primary_category)))
    !isempty(primary_category) && push!(categories, primary_category)

    for category in split(maybe_string(row.categories), ",")
        normalized = lowercase(strip(category))
        isempty(normalized) && continue
        push!(categories, normalized)
    end

    for category in categories
        token = "cat:" * category
        weights[token] = get(weights, token, 0.0) + SCORE_CATEGORY_TOKEN_WEIGHT
    end

    return weights
end

function score_document_frequencies(feature_rows::Dict{String, Dict{String, Float64}})
    weights = Dict{String, Float64}()

    for token_weights in values(feature_rows)
        for token in keys(token_weights)
            weights[token] = get(weights, token, 0.0) + 1.0
        end
    end

    return weights
end

function score_inverse_document_frequency(token::AbstractString, document_frequencies::Dict{String, Float64}, total_documents::Integer)
    frequency = get(document_frequencies, String(token), 0.0)
    return log(1.0 + total_documents / (1.0 + frequency))
end

function score_tfidf_weights(raw_weights::Dict{String, Float64}, document_frequencies::Dict{String, Float64}, total_documents::Integer)
    weights = Dict{String, Float64}()

    for (token, token_weight) in raw_weights
        weights[token] = token_weight * score_inverse_document_frequency(token, document_frequencies, total_documents)
    end

    return weights
end

function score_vector_norm(weights::Dict{String, Float64})
    return sqrt(sum(value ^ 2 for value in values(weights)))
end

function score_dot(left::Dict{String, Float64}, right::Dict{String, Float64})
    if length(left) > length(right)
        return score_dot(right, left)
    end

    total = 0.0
    for (token, value) in left
        total += value * get(right, token, 0.0)
    end

    return total
end

function score_profile_weights(rows, feature_rows::Dict{String, Dict{String, Float64}})
    weights = Dict{String, Float64}()

    for row in rows
        scale = get(SCORE_PROFILE_LABEL_WEIGHTS, maybe_string(row.label), 0.0)
        iszero(scale) && continue

        for (token, token_weight) in get(feature_rows, maybe_string(row.arxiv_id), Dict{String, Float64}())
            weights[token] = get(weights, token, 0.0) + scale * token_weight
        end
    end

    return weights
end

function latest_score_day(rows)
    latest_day = nothing

    for row in rows
        appeared_on = maybe_string(row.appeared_on)
        isempty(appeared_on) && continue
        current_day = Date(appeared_on, DAY_FMT)
        latest_day = latest_day === nothing ? current_day : max(latest_day, current_day)
    end

    return latest_day
end

function score_signal_tokens(reference_weights::Dict{String, Float64}, paper_weights::Dict{String, Float64}; limit::Integer = 3, positive_only::Bool = false)
    contributions = Pair{String, Float64}[]

    for (token, token_weight) in paper_weights
        contribution = get(reference_weights, token, 0.0) * token_weight
        iszero(contribution) && continue
        positive_only && contribution <= 0 && continue
        push!(contributions, token => contribution)
    end

    sort!(contributions; by = pair -> abs(last(pair)), rev = true)

    signals = String[]
    for pair in Iterators.take(contributions, limit)
        token = first(pair)
        push!(signals, startswith(token, "cat:") ? replace(token, "cat:" => "") : token)
    end

    return unique(signals)
end

function score_similarity_component(reference_weights::Dict{String, Float64}, paper_weights::Dict{String, Float64}; scale::Real, positive_only::Bool = false)
    isempty(reference_weights) && return 0.0, String[]
    isempty(paper_weights) && return 0.0, String[]

    denominator = score_vector_norm(reference_weights) * score_vector_norm(paper_weights)
    denominator == 0 && return 0.0, String[]

    similarity = score_dot(reference_weights, paper_weights) / denominator
    component = Float64(scale) * sign(similarity) * sqrt(abs(similarity))
    signals = score_signal_tokens(reference_weights, paper_weights; positive_only = positive_only)

    return component, signals
end

function score_recency_component(row, latest_day::Union{Nothing, Date})
    latest_day === nothing && return 0.0

    appeared_on = maybe_string(row.appeared_on)
    isempty(appeared_on) && return 0.0

    paper_day = Date(appeared_on, DAY_FMT)
    age_days = max(Dates.value(latest_day - paper_day), 0)
    recency_fraction = 1.0 - age_days / SCORE_RECENCY_WINDOW_DAYS

    return clamp(SCORE_RECENCY_MAX * recency_fraction, 0.0, SCORE_RECENCY_MAX)
end

function score_details_text(seed_component::Real, profile_component::Real, recency_component::Real, label_component::Real, signals::Vector{String})
    parts = ["Base $(round(SCORE_BASELINE; digits = 1))"]

    !iszero(seed_component) && push!(parts, "Seed $(seed_component >= 0 ? "+" : "")$(round(seed_component; digits = 1))")
    !iszero(profile_component) && push!(parts, "Profile $(profile_component >= 0 ? "+" : "")$(round(profile_component; digits = 1))")
    !iszero(recency_component) && push!(parts, "Recency +$(round(recency_component; digits = 1))")
    !iszero(label_component) && push!(parts, "Vote $(label_component >= 0 ? "+" : "")$(round(label_component; digits = 1))")
    !isempty(signals) && push!(parts, "Signals: $(join(signals, ", "))")

    return join(parts, " | ")
end

function scoring_rows(db::SQLite.DB)
    return query_rows(
        db,
        """
        SELECT
            p.arxiv_id,
            p.title,
            p.abstract,
            COALESCE(p.appeared_on, p.submitted_on) AS appeared_on,
            p.primary_category,
            COALESCE((
                SELECT group_concat(category_code, ', ')
                FROM (
                    SELECT category_code
                    FROM paper_categories
                    WHERE paper_id = p.arxiv_id
                    ORDER BY is_primary DESC, category_code ASC
                )
            ), '') AS categories,
            COALESCE(ul.label, '') AS label
        FROM papers p
        LEFT JOIN user_labels ul ON ul.paper_id = p.arxiv_id
        ORDER BY COALESCE(p.appeared_on, p.submitted_on) DESC, p.title COLLATE NOCASE ASC
        """,
    )
end

function save_paper_score!(db::SQLite.DB, paper_id::AbstractString, score::Real, score_details::AbstractString)
    execute_sql(
        db,
        """
        INSERT INTO paper_scores (paper_id, score, score_details, ranked_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(paper_id) DO UPDATE SET
            score = excluded.score,
            score_details = excluded.score_details,
            ranked_at = excluded.ranked_at
        """,
        (String(paper_id), Float64(score), String(score_details), timestamp_now()),
    )

    return nothing
end

function recompute_paper_scores!()
    with_db() do db
        rows = scoring_rows(db)
        execute_sql(db, "DELETE FROM paper_scores WHERE paper_id NOT IN (SELECT arxiv_id FROM papers)")
        isempty(rows) && return nothing

        raw_feature_rows = Dict{String, Dict{String, Float64}}()
        for row in rows
            raw_feature_rows[maybe_string(row.arxiv_id)] = paper_score_features(row)
        end

        document_frequencies = score_document_frequencies(raw_feature_rows)
        total_documents = max(length(raw_feature_rows), 1)
        feature_rows = Dict{String, Dict{String, Float64}}()
        for (paper_id, raw_weights) in raw_feature_rows
            feature_rows[paper_id] = score_tfidf_weights(raw_weights, document_frequencies, total_documents)
        end

        profile_weights = score_profile_weights(rows, feature_rows)
        latest_day = latest_score_day(rows)

        for row in rows
            paper_id = maybe_string(row.arxiv_id)
            label_component = get(SCORE_LABEL_ADJUSTMENTS, maybe_string(row.label), 0.0)
            paper_weights = get(feature_rows, paper_id, Dict{String, Float64}())
            seed_component, seed_signals = score_similarity_component(SCORE_SEED_WEIGHTS, paper_weights; scale = SCORE_SEED_SCALE, positive_only = true)
            profile_component, profile_signals = score_similarity_component(profile_weights, paper_weights; scale = SCORE_PROFILE_SCALE)
            recency_component = score_recency_component(row, latest_day)
            score = clamp(SCORE_BASELINE + seed_component + profile_component + recency_component + label_component, 0.0, 10.0)
            signals = unique(vcat(seed_signals, profile_signals))
            score_details = score_details_text(seed_component, profile_component, recency_component, label_component, signals)
            save_paper_score!(db, paper_id, score, score_details)
        end
    end

    return nothing
end

selection_bounds(selection::BrowseSelection) = (; lower = selection.lower, upper = selection.upper)

window_bounds(window::String) = selection_bounds(window_selection(window))

function list_papers(selection::BrowseSelection)
    bounds = selection_bounds(selection)

    with_db() do db
        return query_rows(
            db,
            """
            SELECT
                p.arxiv_id,
                p.title,
                p.abstract,
                p.submitted_on,
                COALESCE(p.appeared_on, p.submitted_on) AS appeared_on,
                p.primary_category,
                p.abs_url,
                p.pdf_url,
                p.comment,
                p.journal_ref,
                COALESCE(ps.score, $(SCORE_BASELINE)) AS score,
                COALESCE(ps.score_details, 'Base $(round(SCORE_BASELINE; digits = 1))') AS score_details,
                COALESCE(asu.summary_text, '') AS abstract_summary,
                COALESCE(pds.summary_text, '') AS pdf_summary,
                COALESCE(pdd.local_path, '') AS local_pdf_path,
                COALESCE(pdd.downloaded_at, '') AS pdf_downloaded_at,
                (
                    SELECT COUNT(*)
                    FROM paper_authors
                    WHERE paper_id = p.arxiv_id
                ) AS author_count,
                COALESCE((
                    SELECT group_concat(author_name, ', ')
                    FROM (
                        SELECT author_name
                        FROM paper_authors
                        WHERE paper_id = p.arxiv_id
                        ORDER BY author_position ASC
                        LIMIT 5
                    )
                ), '') AS authors,
                COALESCE((
                    SELECT group_concat(category_code, ', ')
                    FROM (
                        SELECT category_code
                        FROM paper_categories
                        WHERE paper_id = p.arxiv_id
                        ORDER BY is_primary DESC, category_code ASC
                    )
                ), '') AS categories,
                    COALESCE(ul.label, '') AS label,
                    COALESCE(ul.updated_at, '') AS label_updated_at
            FROM papers p
            LEFT JOIN user_labels ul ON ul.paper_id = p.arxiv_id
            LEFT JOIN paper_scores ps ON ps.paper_id = p.arxiv_id
            LEFT JOIN abstract_summaries asu ON asu.paper_id = p.arxiv_id
            LEFT JOIN pdf_summaries pds ON pds.paper_id = p.arxiv_id
            LEFT JOIN pdf_downloads pdd ON pdd.paper_id = p.arxiv_id
            WHERE COALESCE(p.appeared_on, p.submitted_on) BETWEEN ? AND ?
                ORDER BY
                    COALESCE(ps.score, $(SCORE_BASELINE)) DESC,
                    COALESCE(ul.updated_at, '') DESC,
                    COALESCE(p.appeared_on, p.submitted_on) DESC,
                    p.title COLLATE NOCASE ASC
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )
    end
end

list_papers(window::String) = list_papers(window_selection(window))

function paper_detail(paper_id::AbstractString)
    with_db() do db
        return query_first_row(
            db,
            """
            SELECT
                p.arxiv_id,
                p.title,
                p.abstract,
                p.submitted_on,
                COALESCE(p.appeared_on, p.submitted_on) AS appeared_on,
                p.primary_category,
                p.abs_url,
                p.pdf_url,
                p.comment,
                p.journal_ref,
                COALESCE((
                    SELECT group_concat(author_name, ', ')
                    FROM (
                        SELECT author_name
                        FROM paper_authors
                        WHERE paper_id = p.arxiv_id
                        ORDER BY author_position ASC
                    )
                ), '') AS authors,
                COALESCE((
                    SELECT author_name
                    FROM paper_authors
                    WHERE paper_id = p.arxiv_id
                    ORDER BY author_position ASC
                    LIMIT 1
                ), '') AS first_author,
                COALESCE((
                    SELECT group_concat(category_code, ', ')
                    FROM (
                        SELECT category_code
                        FROM paper_categories
                        WHERE paper_id = p.arxiv_id
                        ORDER BY is_primary DESC, category_code ASC
                    )
                ), '') AS categories
            FROM papers p
            WHERE p.arxiv_id = ?
            """,
            (String(paper_id),),
        )
    end
end

function abstract_summary_for_paper(paper_id::AbstractString)
    with_db() do db
        return query_first_row(db, "SELECT * FROM abstract_summaries WHERE paper_id = ?", (String(paper_id),))
    end
end

function save_abstract_summary!(paper_id::AbstractString, model::AbstractString, prompt_version::AbstractString, summary_text::AbstractString)
    with_db() do db
        execute_sql(
            db,
            """
            INSERT INTO abstract_summaries (paper_id, model, prompt_version, summary_text, generated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(paper_id) DO UPDATE SET
                model = excluded.model,
                prompt_version = excluded.prompt_version,
                summary_text = excluded.summary_text,
                generated_at = excluded.generated_at
            """,
            (String(paper_id), String(model), String(prompt_version), String(summary_text), timestamp_now()),
        )
    end

    return nothing
end

function pdf_download_for_paper(paper_id::AbstractString)
    with_db() do db
        return query_first_row(db, "SELECT * FROM pdf_downloads WHERE paper_id = ?", (String(paper_id),))
    end
end

function save_pdf_download!(paper_id::AbstractString, local_path::AbstractString, source_url::AbstractString, file_size_bytes::Integer)
    current = pdf_download_for_paper(paper_id)
    open_count = current === nothing ? 0 : Int(coalesce(current.open_count, 0))
    last_opened_at = current === nothing ? nothing : maybe_value(current.last_opened_at)

    with_db() do db
        execute_sql(
            db,
            """
            INSERT INTO pdf_downloads (paper_id, local_path, source_url, file_size_bytes, downloaded_at, open_count, last_opened_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(paper_id) DO UPDATE SET
                local_path = excluded.local_path,
                source_url = excluded.source_url,
                file_size_bytes = excluded.file_size_bytes,
                downloaded_at = excluded.downloaded_at,
                open_count = excluded.open_count,
                last_opened_at = excluded.last_opened_at
            """,
            (String(paper_id), String(local_path), String(source_url), Int(file_size_bytes), timestamp_now(), open_count, last_opened_at),
        )
    end

    return nothing
end

function mark_pdf_opened!(paper_id::AbstractString)
    current = pdf_download_for_paper(paper_id)
    current === nothing && return nothing

    with_db() do db
        execute_sql(
            db,
            """
            UPDATE pdf_downloads
            SET open_count = ?, last_opened_at = ?
            WHERE paper_id = ?
            """,
            (Int(coalesce(current.open_count, 0)) + 1, timestamp_now(), String(paper_id)),
        )
    end

    return nothing
end

function pdf_summary_for_paper(paper_id::AbstractString)
    with_db() do db
        return query_first_row(db, "SELECT * FROM pdf_summaries WHERE paper_id = ?", (String(paper_id),))
    end
end

function save_pdf_summary!(paper_id::AbstractString, local_path::AbstractString, model::AbstractString, prompt_version::AbstractString, summary_text::AbstractString)
    with_db() do db
        execute_sql(
            db,
            """
            INSERT INTO pdf_summaries (paper_id, local_path, model, prompt_version, summary_text, generated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(paper_id) DO UPDATE SET
                local_path = excluded.local_path,
                model = excluded.model,
                prompt_version = excluded.prompt_version,
                summary_text = excluded.summary_text,
                generated_at = excluded.generated_at
            """,
            (String(paper_id), String(local_path), String(model), String(prompt_version), String(summary_text), timestamp_now()),
        )
    end

    return nothing
end

selection_summary_key(selection::BrowseSelection, top_n::Integer) = "$(selection.mode):$(date_string(selection.anchor)):$(Int(top_n))"

function save_selection_summary!(selection::BrowseSelection, top_n::Integer, model::AbstractString, prompt_version::AbstractString, summary_text::AbstractString)
    with_db() do db
        execute_sql(
            db,
            """
            INSERT INTO selection_summaries (
                selection_key, selection_mode, anchor_day, lower_day, upper_day,
                top_n, model, prompt_version, summary_text, generated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(selection_key) DO UPDATE SET
                selection_mode = excluded.selection_mode,
                anchor_day = excluded.anchor_day,
                lower_day = excluded.lower_day,
                upper_day = excluded.upper_day,
                top_n = excluded.top_n,
                model = excluded.model,
                prompt_version = excluded.prompt_version,
                summary_text = excluded.summary_text,
                generated_at = excluded.generated_at
            """,
            (
                selection_summary_key(selection, top_n),
                String(selection.mode),
                date_string(selection.anchor),
                date_string(selection.lower),
                date_string(selection.upper),
                Int(top_n),
                String(model),
                String(prompt_version),
                String(summary_text),
                timestamp_now(),
            ),
        )
    end

    return nothing
end

function latest_selection_summary_for(selection::BrowseSelection)
    with_db() do db
        return query_first_row(
            db,
            """
            SELECT *
            FROM selection_summaries
            WHERE selection_mode = ? AND anchor_day = ? AND lower_day = ? AND upper_day = ?
            ORDER BY generated_at DESC
            LIMIT 1
            """,
            (String(selection.mode), date_string(selection.anchor), date_string(selection.lower), date_string(selection.upper)),
        )
    end
end

function overview_for_window(selection::BrowseSelection)
    bounds = selection_bounds(selection)

    if latest_appearance_day() === nothing
        return (
            total_papers = 0,
            labeled_count = 0,
            interested_count = 0,
            very_interested_count = 0,
            not_interested_count = 0,
            daily_counts = NamedTuple[],
            category_counts = NamedTuple[],
            author_counts = NamedTuple[],
            reference_day = selection.reference_day,
            latest_data_day = nothing,
            last_refresh = nothing,
        )
    end

    with_db() do db
        totals = query_first_row(
            db,
            """
            SELECT
                COUNT(*) AS total_papers,
                COUNT(ul.paper_id) AS labeled_count,
                SUM(CASE WHEN ul.label = 'interested' THEN 1 ELSE 0 END) AS interested_count,
                SUM(CASE WHEN ul.label = 'very_interested' THEN 1 ELSE 0 END) AS very_interested_count,
                SUM(CASE WHEN ul.label = 'not_interested' THEN 1 ELSE 0 END) AS not_interested_count
            FROM papers p
            LEFT JOIN user_labels ul ON ul.paper_id = p.arxiv_id
            WHERE COALESCE(p.appeared_on, p.submitted_on) BETWEEN ? AND ?
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )

        daily_counts = query_rows(
            db,
            """
            SELECT COALESCE(appeared_on, submitted_on) AS appeared_on, COUNT(*) AS paper_count
            FROM papers
            WHERE COALESCE(appeared_on, submitted_on) BETWEEN ? AND ?
            GROUP BY COALESCE(appeared_on, submitted_on)
            ORDER BY COALESCE(appeared_on, submitted_on) DESC
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )

        category_counts = query_rows(
            db,
            """
            SELECT pc.category_code, COUNT(*) AS paper_count
            FROM paper_categories pc
            JOIN papers p ON p.arxiv_id = pc.paper_id
            WHERE COALESCE(p.appeared_on, p.submitted_on) BETWEEN ? AND ?
            GROUP BY pc.category_code
            ORDER BY paper_count DESC, pc.category_code ASC
            LIMIT 8
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )

        author_counts = query_rows(
            db,
            """
            SELECT pa.author_name, COUNT(*) AS paper_count
            FROM paper_authors pa
            JOIN papers p ON p.arxiv_id = pa.paper_id
            WHERE COALESCE(p.appeared_on, p.submitted_on) BETWEEN ? AND ?
            GROUP BY pa.author_name
            ORDER BY paper_count DESC, pa.author_name ASC
            LIMIT 8
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )

        refresh_row = query_first_row(
            db,
            "SELECT finished_at FROM ingestion_runs WHERE status = 'success' ORDER BY id DESC LIMIT 1",
        )
        last_refresh = refresh_row === nothing ? nothing : maybe_value(refresh_row.finished_at)

        return (
            total_papers = Int(totals.total_papers),
            labeled_count = Int(coalesce(totals.labeled_count, 0)),
            interested_count = Int(coalesce(totals.interested_count, 0)),
            very_interested_count = Int(coalesce(totals.very_interested_count, 0)),
            not_interested_count = Int(coalesce(totals.not_interested_count, 0)),
            daily_counts,
            category_counts,
            author_counts,
            reference_day = selection.reference_day,
            latest_data_day = latest_appearance_day(),
            last_refresh,
        )
    end
end

overview_for_window(window::String) = overview_for_window(window_selection(window))

function recent_calendar_counts(reference_day::Date)
    lower = Dates.firstdayofmonth(reference_day - Month(1))

    with_db() do db
        rows = query_rows(
            db,
            """
            SELECT COALESCE(appeared_on, submitted_on) AS appeared_on, COUNT(*) AS paper_count
            FROM papers
            WHERE COALESCE(appeared_on, submitted_on) BETWEEN ? AND ?
            GROUP BY COALESCE(appeared_on, submitted_on)
            """,
            (date_string(lower), date_string(reference_day)),
        )

        counts = Dict{Date, Int}()
        for row in rows
            counts[Date(maybe_string(row.appeared_on), DAY_FMT)] = Int(row.paper_count)
        end

        return counts
    end
end

function selection_has_successful_ingestion(selection::BrowseSelection)
    bounds = selection_bounds(selection)

    with_db() do db
        row = query_first_row(
            db,
            """
            SELECT EXISTS(
                SELECT 1
                FROM ingestion_runs
                WHERE status = 'success' AND from_date <= ? AND to_date >= ?
            ) AS has_cover
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )

        return Int(coalesce(row.has_cover, 0)) == 1
    end
end

function selection_has_local_papers(selection::BrowseSelection)
    bounds = selection_bounds(selection)

    with_db() do db
        row = query_first_row(
            db,
            """
            SELECT COUNT(*) AS total
            FROM papers
            WHERE COALESCE(appeared_on, submitted_on) BETWEEN ? AND ?
            """,
            (date_string(bounds.lower), date_string(bounds.upper)),
        )

        return Int(coalesce(row.total, 0)) > 0
    end
end

function mark_selection_viewed!(selection::BrowseSelection)
    with_db() do db
        for viewed_day in selection.lower:Day(1):selection.upper
            execute_sql(
                db,
                """
                INSERT INTO viewed_days (viewed_on, last_viewed_at)
                VALUES (?, ?)
                ON CONFLICT(viewed_on) DO UPDATE SET
                    last_viewed_at = excluded.last_viewed_at
                """,
                (date_string(viewed_day), timestamp_now()),
            )
        end
    end

    return nothing
end

function viewed_days_in_range(lower::Date, upper::Date)
    with_db() do db
        rows = query_rows(
            db,
            "SELECT viewed_on FROM viewed_days WHERE viewed_on BETWEEN ? AND ?",
            (date_string(lower), date_string(upper)),
        )

        return Set(Date(maybe_string(row.viewed_on), DAY_FMT) for row in rows)
    end
end

function save_label!(paper_id::AbstractString, label::AbstractString)
    selected_label = label_or_default(label)
    with_db() do db
        execute_sql(
            db,
            """
            INSERT INTO user_labels (paper_id, label, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(paper_id) DO UPDATE SET
                label = excluded.label,
                updated_at = excluded.updated_at
            """,
            (String(paper_id), selected_label, timestamp_now()),
        )
    end

    recompute_paper_scores!()

    return selected_label
end