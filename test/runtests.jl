using Dates
using Test

using ArxivViewer

@testset "ArxivViewer basics" begin
    @test ArxivViewer.canonical_arxiv_id("http://arxiv.org/abs/2505.12345v1") == "2505.12345"
    @test ArxivViewer.window_or_default("week") == "week"
    @test ArxivViewer.window_or_default("invalid") == "today"
    @test ArxivViewer.label_display("not_interested") == "-"
    @test ArxivViewer.label_display("interested") == "+"
    @test ArxivViewer.label_display("very_interested") == "++"

    query = ArxivViewer.build_search_query(Date(2026, 5, 1), Date(2026, 5, 21))
    @test occursin("astro-ph.HE", query)
    @test occursin("submittedDate:[202605010000 TO 202605212359]", query)

    today_selection = ArxivViewer.window_selection("today"; reference_day = Date(2026, 5, 21))
    @test today_selection.mode == "day"
    @test today_selection.lower == Date(2026, 5, 21)
    @test today_selection.upper == Date(2026, 5, 21)
    @test ArxivViewer.browse_path(today_selection) == "/browse/day/2026-05-21"

    week_selection = ArxivViewer.window_selection("week"; reference_day = Date(2026, 5, 21))
    @test week_selection.mode == "week"
    @test week_selection.lower == Date(2026, 5, 18)
    @test week_selection.upper == Date(2026, 5, 21)

    month_selection = ArxivViewer.browse_selection("month", "2026-04-15"; reference_day = Date(2026, 5, 21))
    @test month_selection.lower == Date(2026, 4, 1)
    @test month_selection.upper == Date(2026, 4, 30)
    @test ArxivViewer.selection_title(month_selection) == "April 2026"
end

@testset "Latest listed day fallback" begin
    fetch_ids = day -> begin
        day == Date(2026, 5, 29) && return ["2605.28851"]
        day == Date(2026, 6, 2) && return ["2606.00001"]
        return String[]
    end

    @test ArxivViewer.latest_listed_day(reference_day = Date(2026, 6, 1), fetch_ids = fetch_ids) == Date(2026, 5, 29)
    @test ArxivViewer.latest_listed_day(reference_day = Date(2026, 5, 31), fetch_ids = fetch_ids) == Date(2026, 5, 29)
    @test ArxivViewer.latest_listed_day(reference_day = Date(2026, 6, 2), fetch_ids = fetch_ids) == Date(2026, 6, 2)

    week_selection = ArxivViewer.default_window_selection("week"; reference_day = Date(2026, 6, 1), fetch_ids = fetch_ids)
    @test week_selection.lower == Date(2026, 5, 25)
    @test week_selection.upper == Date(2026, 5, 29)

    today_selection = ArxivViewer.default_window_selection("today"; reference_day = Date(2026, 6, 1), fetch_ids = fetch_ids)
    @test today_selection.lower == Date(2026, 5, 29)
    @test today_selection.upper == Date(2026, 5, 29)
end

@testset "Vote ordering" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ArxivViewer.init_database!()

            paper_a = ArxivViewer.ArxivPaper(
                "2505.00001",
                "Alpha paper",
                "alpha abstract",
                "2026-05-21T00:00:00",
                "2026-05-21T00:00:00",
                "2026-05-21",
                "astro-ph.HE",
                nothing,
                nothing,
                "https://arxiv.org/abs/2505.00001",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.HE"],
            )

            paper_b = ArxivViewer.ArxivPaper(
                "2505.00002",
                "Beta paper",
                "beta abstract",
                "2026-05-21T00:00:00",
                "2026-05-21T00:00:00",
                "2026-05-21",
                "astro-ph.HE",
                nothing,
                nothing,
                "https://arxiv.org/abs/2505.00002",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.HE"],
            )

            ArxivViewer.with_db() do db
                ArxivViewer.upsert_paper!(db, paper_a)
                ArxivViewer.upsert_paper!(db, paper_b)
            end

            selection = ArxivViewer.browse_selection("day", Date(2026, 5, 21); reference_day = Date(2026, 5, 21))
            @test getfield.(ArxivViewer.list_papers(selection), :arxiv_id) == ["2505.00001", "2505.00002"]

            ArxivViewer.save_label!("2505.00002", "very_interested")
            @test getfield.(ArxivViewer.list_papers(selection), :arxiv_id) == ["2505.00002", "2505.00001"]

            ArxivViewer.mark_selection_viewed!(selection)
            @test selection.lower in ArxivViewer.viewed_days_in_range(Date(2026, 5, 1), Date(2026, 5, 31))
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end
        end
    end
end

@testset "Dynamic heuristic scoring" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ArxivViewer.init_database!()

            positive = ArxivViewer.ArxivPaper(
                "2505.10001",
                "Black hole accretion flares in AGN",
                "Accretion disk variability around a black hole with jet signatures.",
                "2026-05-26T00:00:00",
                "2026-05-26T00:00:00",
                "2026-05-26",
                "astro-ph.HE",
                nothing,
                nothing,
                "https://arxiv.org/abs/2505.10001",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.HE"],
            )

            similar = ArxivViewer.ArxivPaper(
                "2505.10002",
                "Accretion disk echoes from active black holes",
                "Black hole disk structure and AGN flare timing.",
                "2026-05-26T00:00:00",
                "2026-05-26T00:00:00",
                "2026-05-26",
                "astro-ph.HE",
                nothing,
                nothing,
                "https://arxiv.org/abs/2505.10002",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.HE"],
            )

            unrelated = ArxivViewer.ArxivPaper(
                "2505.10003",
                "Exoplanet atmosphere chemistry survey",
                "Spectral retrieval for planetary atmospheres and clouds.",
                "2026-05-26T00:00:00",
                "2026-05-26T00:00:00",
                "2026-05-26",
                "astro-ph.EP",
                nothing,
                nothing,
                "https://arxiv.org/abs/2505.10003",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.EP"],
            )

            ArxivViewer.with_db() do db
                ArxivViewer.upsert_paper!(db, positive)
                ArxivViewer.upsert_paper!(db, similar)
                ArxivViewer.upsert_paper!(db, unrelated)
            end

            ArxivViewer.recompute_paper_scores!()
            ArxivViewer.save_label!("2505.10001", "very_interested")

            selection = ArxivViewer.browse_selection("day", Date(2026, 5, 26); reference_day = Date(2026, 5, 26))
            papers = ArxivViewer.list_papers(selection)
            score_by_id = Dict(ArxivViewer.maybe_string(row.arxiv_id) => Float64(row.score) for row in papers)
            details_by_id = Dict(ArxivViewer.maybe_string(row.arxiv_id) => ArxivViewer.maybe_string(row.score_details) for row in papers)

            @test score_by_id["2505.10002"] > score_by_id["2505.10003"]
            @test occursin("Signals:", details_by_id["2505.10002"])
            @test getfield.(papers, :arxiv_id) == ["2505.10001", "2505.10002", "2505.10003"]
            @test score_by_id["2505.10002"] < 9.0
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end
        end
    end
end

@testset "Appearance-date filing" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ArxivViewer.init_database!()

            paper = ArxivViewer.ArxivPaper(
                "2605.18958",
                "Directly tracking the re-brightening of a supermassive black hole accretion disk",
                "abstract",
                "2026-05-18T18:00:05Z",
                "2026-05-18T18:00:05Z",
                "2026-05-18",
                "astro-ph.HE",
                nothing,
                nothing,
                "https://arxiv.org/abs/2605.18958",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.HE", "astro-ph.GA"],
            )

            ArxivViewer.with_db() do db
                ArxivViewer.upsert_paper!(db, paper; appeared_on = Date(2026, 5, 20))
            end

            may_20 = ArxivViewer.browse_selection("day", Date(2026, 5, 20); reference_day = Date(2026, 5, 23))
            may_18 = ArxivViewer.browse_selection("day", Date(2026, 5, 18); reference_day = Date(2026, 5, 23))
            @test getfield.(ArxivViewer.list_papers(may_20), :arxiv_id) == ["2605.18958"]
            @test isempty(ArxivViewer.list_papers(may_18))

            overview = ArxivViewer.overview_for_window(may_20)
            @test overview.total_papers == 1
            @test overview.latest_data_day == Date(2026, 5, 20)

            calendar_counts = ArxivViewer.recent_calendar_counts(Date(2026, 5, 23))
            @test get(calendar_counts, Date(2026, 5, 20), 0) == 1
            @test !haskey(calendar_counts, Date(2026, 5, 18))

            @test !ArxivViewer.selection_has_successful_ingestion(may_20)
            ArxivViewer.record_ingestion_run!(
                "2026-05-23T10:00:00",
                "2026-05-23T10:00:01",
                Date(2026, 5, 1),
                Date(2026, 5, 31),
                1,
                "success",
                nothing,
            )
            @test ArxivViewer.selection_has_successful_ingestion(may_20)
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end
        end
    end
end

@testset "Auto refresh policy" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ArxivViewer.init_database!()

            today = ArxivViewer.browse_selection("day", Date(2026, 5, 25); reference_day = Date(2026, 5, 25))
            this_week = ArxivViewer.browse_selection("week", Date(2026, 5, 25); reference_day = Date(2026, 5, 25))
            this_month = ArxivViewer.browse_selection("month", Date(2026, 5, 25); reference_day = Date(2026, 5, 25))
            @test ArxivViewer.should_auto_refresh_selection(today)
            @test !ArxivViewer.should_auto_refresh_selection(this_week)
            @test !ArxivViewer.should_auto_refresh_selection(this_month)

            ArxivViewer.record_ingestion_run!(
                "2026-05-25T09:00:00",
                "2026-05-25T09:00:01",
                Date(2026, 5, 25),
                Date(2026, 5, 25),
                0,
                "success",
                nothing,
            )

            @test !ArxivViewer.should_auto_refresh_selection(today)
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end
        end
    end
end

@testset "Startup refresh policy" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ArxivViewer.init_database!()

            requested_selection = Ref{Union{Nothing, ArxivViewer.BrowseSelection}}(nothing)
            refresh_count = ArxivViewer.startup_refresh_today!(
                reference_day = Date(2026, 5, 25),
                selection_for_refresh = day -> ArxivViewer.window_selection("today"; reference_day = day),
                refresh! = selection -> begin
                requested_selection[] = selection
                return 7
                end,
            )

            @test refresh_count == 7
            @test requested_selection[] !== nothing
            @test requested_selection[].lower == Date(2026, 5, 25)
            @test requested_selection[].upper == Date(2026, 5, 25)

            today_paper = ArxivViewer.ArxivPaper(
                "2505.20001",
                "Cached startup paper",
                "already downloaded",
                "2026-05-25T00:00:00",
                "2026-05-25T00:00:00",
                "2026-05-25",
                "astro-ph.HE",
                nothing,
                nothing,
                "https://arxiv.org/abs/2505.20001",
                nothing,
                nothing,
                ArxivViewer.AuthorEntry[],
                ["astro-ph.HE"],
            )

            ArxivViewer.with_db() do db
                ArxivViewer.upsert_paper!(db, today_paper)
            end

            requested_selection[] = nothing
            refresh_count = ArxivViewer.startup_refresh_today!(
                reference_day = Date(2026, 5, 25),
                selection_for_refresh = day -> ArxivViewer.window_selection("today"; reference_day = day),
                refresh! = selection -> begin
                requested_selection[] = selection
                return 11
                end,
            )

            @test refresh_count == 0
            @test requested_selection[] === nothing
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end
        end
    end
end

@testset "Catch-up parsing" begin
    html = """
    <h3>New submissions (showing 1 of 1 entries)</h3>
    <dt><a href =\"/abs/2605.18958\" title=\"Abstract\" id=\"2605.18958\">arXiv:2605.18958</a></dt>
    <h3>Cross-lists (showing 1 of 1 entries)</h3>
    <dt><a href =\"/abs/2605.20000\" title=\"Abstract\" id=\"2605.20000\">arXiv:2605.20000</a></dt>
    <h3>Replacements (showing 1 of 1 entries)</h3>
    <dt><a href =\"/abs/2605.30000\" title=\"Abstract\" id=\"2605.30000\">arXiv:2605.30000</a></dt>
    """

    @test ArxivViewer.parse_catchup_ids(html) == ["2605.18958", "2605.20000"]
    @test ArxivViewer.parse_catchup_ids(replace(html, "Cross-lists" => "Cross submissions")) == ["2605.18958", "2605.20000"]

        listing_html = """
        <h3>New submissions (showing 1 of 1 entries)</h3>
        <dt>
            <a href=\"/abs/2605.18958\" title=\"Abstract\" id=\"2605.18958\">arXiv:2605.18958</a>
            [<a href=\"/pdf/2605.18958\" title=\"Download PDF\" id=\"pdf-2605.18958\">pdf</a>]
        </dt>
        <dd>
            <div class='meta'>
                <div class='list-title mathjax'><span class='descriptor'>Title:</span> Directly tracking the re-brightening of a supermassive black hole accretion disk</div>
                <div class='list-authors'><a href='/search?query=lovelace'>Ada Lovelace</a>, <a href='/search?query=hopper'>Grace Hopper</a></div>
                <div class='list-comments mathjax'><span class='descriptor'>Comments:</span> 3 figures</div>
                <div class='list-journal-ref'><span class='descriptor'>Journal-ref:</span> ApJ 123 (2026)</div>
                <div class='list-doi'><span class='descriptor'>DOI:</span> 10.1234/example</div>
                <div class='list-subjects'><span class='descriptor'>Subjects:</span> <span class='primary-subject'>High Energy Astrophysical Phenomena (astro-ph.HE)</span>; Astrophysics of Galaxies (astro-ph.GA)</div>
                <p class='mathjax'>We revisit the brightening of a compact accretion disk.</p>
            </div>
        </dd>
        <h3>Cross submissions (showing 1 of 1 entries)</h3>
        <dt>
            <a href=\"/abs/2605.20000\" title=\"Abstract\" id=\"2605.20000\">arXiv:2605.20000</a>
            [<a href=\"/pdf/2605.20000\" title=\"Download PDF\" id=\"pdf-2605.20000\">pdf</a>]
        </dt>
        <dd>
            <div class='meta'>
                <div class='list-title mathjax'><span class='descriptor'>Title:</span> Cross-listed compact object note</div>
                <div class='list-authors'><a href='/search?query=turing'>Alan Turing</a></div>
                <div class='list-subjects'><span class='descriptor'>Subjects:</span> <span class='primary-subject'>Machine Learning (cs.LG)</span>; High Energy Astrophysical Phenomena (astro-ph.HE)</div>
                <p class='mathjax'>A cross-list abstract.</p>
            </div>
        </dd>
        <h3>Replacements (showing 1 of 1 entries)</h3>
        <dt>
            <a href=\"/abs/2605.30000\" title=\"Abstract\" id=\"2605.30000\">arXiv:2605.30000</a>
            [<a href=\"/pdf/2605.30000\" title=\"Download PDF\" id=\"pdf-2605.30000\">pdf</a>]
        </dt>
        <dd>
            <div class='meta'>
                <div class='list-title mathjax'><span class='descriptor'>Title:</span> Replacement entry</div>
                <div class='list-authors'><a href='/search?query=babbage'>Charles Babbage</a></div>
                <div class='list-subjects'><span class='descriptor'>Subjects:</span> <span class='primary-subject'>High Energy Astrophysical Phenomena (astro-ph.HE)</span></div>
                <p class='mathjax'>Replacement abstract.</p>
            </div>
        </dd>
        """

        papers = ArxivViewer.parse_catchup_papers(listing_html, Date(2026, 5, 20))
        @test length(papers) == 2

        paper_by_id = Dict(paper.arxiv_id => paper for paper in papers)
        @test sort!(collect(keys(paper_by_id))) == ["2605.18958", "2605.20000"]

        primary = paper_by_id["2605.18958"]
        @test primary.abstract == "We revisit the brightening of a compact accretion disk."
        @test primary.published_at == "2026-05-20T00:00:00Z"
        @test primary.updated_at == "2026-05-20T00:00:00Z"
        @test primary.submitted_on == "2026-05-20"
        @test primary.primary_category == "astro-ph.HE"
        @test primary.doi == "10.1234/example"
        @test primary.pdf_url == "https://arxiv.org/pdf/2605.18958"
        @test primary.abs_url == "https://arxiv.org/abs/2605.18958"
        @test primary.comment == "3 figures"
        @test primary.journal_ref == "ApJ 123 (2026)"
        @test getfield.(primary.authors, :name) == ["Ada Lovelace", "Grace Hopper"]
        @test primary.categories == ["astro-ph.HE", "astro-ph.GA"]

        cross_list = paper_by_id["2605.20000"]
        @test cross_list.primary_category == "cs.LG"
        @test cross_list.categories == ["cs.LG", "astro-ph.HE"]
end

@testset "Atom namespace parsing" begin
        body = """
        <feed xmlns="http://www.w3.org/2005/Atom">
            <entry>
                <id>http://arxiv.org/abs/2501.00001v1</id>
                <title> Example title </title>
                <summary> Example summary </summary>
                <published>2026-05-25T00:00:00Z</published>
                <updated>2026-05-25T00:00:00Z</updated>
                <author>
                    <name>Example Author</name>
                </author>
                <link rel="alternate" href="https://arxiv.org/abs/2501.00001" />
                <category term="astro-ph.HE" />
            </entry>
        </feed>
        """

        papers = ArxivViewer.parse_feed(body)
        @test length(papers) == 1
        @test first(papers).arxiv_id == "2501.00001"
end

@testset "Empty selection render" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ArxivViewer.init_database!()

            selection = ArxivViewer.browse_selection("day", Date(2026, 5, 23); reference_day = Date(2026, 5, 23))
            overview = ArxivViewer.overview_for_window(selection)
            @test overview.total_papers == 0
            @test overview.interested_count == 0
            @test overview.very_interested_count == 0

            calendar_counts = Dict{Date, Int}()
            viewed_days = Set{Date}([Date(2026, 5, 20)])
            html = ArxivViewer.render_layout(selection, NamedTuple[], overview; calendar_counts, viewed_days)
            @test occursin("No papers in this slice", html)
            @test occursin("Recent calendar", html)
            @test occursin(">Refresh<", html)
            @test occursin("tex-chtml.js", html)
            @test findfirst("May 2026", html) < findfirst("April 2026", html)
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end
        end
    end
end

@testset "On-demand summaries and PDF cache" begin
    mktempdir() do tempdir
        old_db_path = get(ENV, "ARXIV_VIEWER_DB_PATH", nothing)
        old_data_dir = get(ENV, "ARXIV_VIEWER_DATA_DIR", nothing)

        try
            ENV["ARXIV_VIEWER_DB_PATH"] = joinpath(tempdir, "test.sqlite")
            ENV["ARXIV_VIEWER_DATA_DIR"] = joinpath(tempdir, "data")
            ArxivViewer.init_database!()

            paper = ArxivViewer.ArxivPaper(
                "2605.30001",
                "Black hole corona variability",
                "We study coronal variability in an accreting black hole system with X-ray timing diagnostics.",
                "2026-05-26T00:00:00",
                "2026-05-26T00:00:00",
                "2026-05-26",
                "astro-ph.HE",
                nothing,
                "https://arxiv.org/pdf/2605.30001.pdf",
                "https://arxiv.org/abs/2605.30001",
                nothing,
                nothing,
                [ArxivViewer.AuthorEntry("Ada Lovelace", nothing), ArxivViewer.AuthorEntry("Grace Hopper", nothing)],
                ["astro-ph.HE", "astro-ph.GA"],
            )

            ArxivViewer.with_db() do db
                ArxivViewer.upsert_paper!(db, paper; appeared_on = Date(2026, 5, 26))
            end

            abstract_prompt = Ref("")
            abstract_summary = ArxivViewer.summarize_abstract!(
                "2605.30001";
                generator = (prompt; model, system) -> begin
                    abstract_prompt[] = prompt
                    @test model == ArxivViewer.summary_model()
                    @test occursin("Black hole corona variability", prompt)
                    return "Summary: A concise abstract summary.\nKey points:\n- Point one\n- Point two\n- Point three\nInterest fit: Strong compact-object relevance."
                end,
            )

            cached_abstract = ArxivViewer.abstract_summary_for_paper("2605.30001")
            @test cached_abstract !== nothing
            @test ArxivViewer.maybe_string(cached_abstract.summary_text) == abstract_summary
            @test occursin("Interest fit", abstract_summary)

            opened_path = Ref("")
            local_path = ArxivViewer.open_local_pdf!(
                "2605.30001";
                downloader = url -> begin
                    @test url == "https://arxiv.org/pdf/2605.30001.pdf"
                    return (; status = 200, body = Vector{UInt8}(codeunits("%PDF-1.4 fake")))
                end,
                opener = path -> begin
                    opened_path[] = path
                    return nothing
                end,
            )

            @test local_path == opened_path[]
            @test isfile(local_path)
            @test occursin(joinpath("data", "pdfs", "2026", "05", "26"), local_path)
            @test occursin("lovelace", lowercase(basename(local_path)))
            @test occursin("black_hole_corona", lowercase(basename(local_path)))

            cached_download = ArxivViewer.pdf_download_for_paper("2605.30001")
            @test cached_download !== nothing
            @test Int(cached_download.open_count) == 1

            pdf_summary = ArxivViewer.summarize_pdf!(
                "2605.30001";
                downloader = _ -> error("PDF should already be cached"),
                extractor = path -> begin
                    @test path == local_path
                    return "Introduction\nWe analyze black hole corona timing and spectra.\nConclusion\nThe corona is compact and variable."
                end,
                generator = (prompt; model, system) -> begin
                    @test model == ArxivViewer.summary_model()
                    @test occursin("Extracted paper text", prompt)
                    return "Summary: A concise PDF summary.\nKey contributions:\n- Contribution one\n- Contribution two\n- Contribution three\nMethods/data:\n- Timing analysis\n- X-ray spectroscopy\nReasons to read:\n- Useful corona constraints\n- Clear observational setup"
                end,
            )

            cached_pdf_summary = ArxivViewer.pdf_summary_for_paper("2605.30001")
            @test cached_pdf_summary !== nothing
            @test ArxivViewer.maybe_string(cached_pdf_summary.summary_text) == pdf_summary

            selection = ArxivViewer.browse_selection("day", Date(2026, 5, 26); reference_day = Date(2026, 5, 26))
            selection_summary = ArxivViewer.summarize_selection!(
                selection;
                top_n = 1,
                generator = (prompt; model, system) -> begin
                    @test occursin("2605.30001", prompt)
                    @test occursin("A concise abstract summary", prompt)
                    return "Overview: One standout compact-object paper.\nThemes:\n- Coronal variability\n- X-ray timing\n- Accretion physics\nPapers to prioritize:\n- 2605.30001: Strong fit for compact-object interests."
                end,
            )

            cached_selection = ArxivViewer.latest_selection_summary_for(selection)
            @test cached_selection !== nothing
            @test ArxivViewer.maybe_string(cached_selection.summary_text) == selection_summary
            @test Int(cached_selection.top_n) == 1

            papers = ArxivViewer.list_papers(selection)
            @test length(papers) == 1
            @test ArxivViewer.maybe_string(first(papers).abstract_summary) == abstract_summary
            @test ArxivViewer.maybe_string(first(papers).pdf_summary) == pdf_summary
            @test ArxivViewer.maybe_string(first(papers).local_pdf_path) == local_path
        finally
            if old_db_path === nothing
                delete!(ENV, "ARXIV_VIEWER_DB_PATH")
            else
                ENV["ARXIV_VIEWER_DB_PATH"] = old_db_path
            end

            if old_data_dir === nothing
                delete!(ENV, "ARXIV_VIEWER_DATA_DIR")
            else
                ENV["ARXIV_VIEWER_DATA_DIR"] = old_data_dir
            end
        end
    end
end