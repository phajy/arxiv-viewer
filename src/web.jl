function stat_card(title::AbstractString, value::AbstractString, detail::AbstractString)
    return """
    <section class=\"stat-card\">
      <div class=\"stat-title\">$(html_escape(title))</div>
      <div class=\"stat-value\">$(html_escape(value))</div>
      <div class=\"stat-detail\">$(html_escape(detail))</div>
    </section>
    """
end

same_selection(left::BrowseSelection, right::BrowseSelection) = left.mode == right.mode && left.lower == right.lower && left.upper == right.upper

function selection_link(label::AbstractString, target::BrowseSelection, current::BrowseSelection, base_class::AbstractString)
    css_class = same_selection(target, current) ? "$base_class active" : base_class
    return "<a class=\"$css_class\" href=\"$(browse_path(target))\">$(html_escape(label))</a>"
end

function render_daily_counts(rows)
    isempty(rows) && return "<div class=\"meta-empty\">No ingested papers yet.</div>"

    items = String[]
    for row in rows
    push!(items, "<li><span>$(html_escape(maybe_string(row.appeared_on)))</span><strong>$(Int(row.paper_count))</strong></li>")
    end

    return "<ul class=\"meta-list\">$(join(items))</ul>"
end

function render_named_count_list(rows, name_key::Symbol)
    isempty(rows) && return "<div class=\"meta-empty\">Not enough data yet.</div>"

    items = String[]
    for row in rows
        label = html_escape(maybe_string(getproperty(row, name_key)))
        count = Int(row.paper_count)
        push!(items, "<li><span>$label</span><strong>$count</strong></li>")
    end

    return "<ul class=\"meta-list\">$(join(items))</ul>"
end

function render_label_actions(selection::BrowseSelection, paper_id::String, current_label::String)
    actions = String[]
    for label in LABEL_OPTIONS
        is_active = label == current_label
        css_class = is_active ? "label-action active" : "label-action"
        push!(
            actions,
            "<a class=\"$css_class\" href=\"$(label_path(selection, paper_id, label))\">$(html_escape(label_display(label)))</a>",
        )
    end

    return join(actions)
end

function author_preview_text(row)
    preview = maybe_string(row.authors)
    author_count = Int(row.author_count)

    isempty(preview) && return ""
    author_count > 5 && return string(preview, ", et al.")

    return preview
end

function render_generated_summary(label::AbstractString, text::AbstractString)
    cleaned = strip(String(text))
    isempty(cleaned) && return ""

    return """
    <section class=\"generated-summary\">
      <div class=\"generated-summary-label\">$(html_escape(label))</div>
      <div class=\"generated-summary-body\">$(summary_text_html(cleaned))</div>
    </section>
    """
end

function render_paper_card(selection::BrowseSelection, row)
    paper_id = maybe_string(row.arxiv_id)
    current_label = maybe_string(row.label)
    details_open = current_label == "interested" || current_label == "very_interested" ? " open" : ""
    label_chip = isempty(current_label) ? "<span class=\"paper-label muted\">Unrated</span>" : "<span class=\"paper-label\">$(html_escape(label_display(current_label)))</span>"
    score_chip = "<span class=\"paper-score\">Score $(round(Float64(row.score); digits = 1))/10</span>"
    comment_text = maybe_value(row.comment)
    comment_html = comment_text === nothing ? "" : "<p class=\"paper-comment\">$(html_escape(comment_text))</p>"
    journal_text = maybe_value(row.journal_ref)
    journal_html = journal_text === nothing ? "" : "<p class=\"paper-journal\">$(html_escape(journal_text))</p>"
    score_detail_text = maybe_string(row.score_details)
    score_detail_html = isempty(score_detail_text) ? "" : "<p class=\"paper-score-detail\">$(html_escape(score_detail_text))</p>"
    authors_text = author_preview_text(row)
    abstract_summary_html = render_generated_summary("Abstract summary", maybe_string(row.abstract_summary))
    pdf_summary_html = render_generated_summary("PDF summary", maybe_string(row.pdf_summary))
    authors_html = isempty(authors_text) ? "" : "<p class=\"paper-authors\">$(html_escape(authors_text))</p>"
    abstract_text = compact_whitespace(maybe_string(row.abstract))
    abstract_html = isempty(abstract_text) ? "" : "<p class=\"paper-abstract\">$(html_escape(abstract_text))</p>"
    pdf_link = maybe_value(row.pdf_url)
    pdf_html = pdf_link === nothing ? "" : "<a class=\"paper-link\" href=\"$(html_escape(pdf_link))\" target=\"_blank\" rel=\"noreferrer\">PDF</a>"
    html_html = "<a class=\"paper-link\" href=\"$(html_escape(arxiv_html_url(paper_id)))\" target=\"_blank\" rel=\"noreferrer\">HTML</a>"
    abstract_summary_action = "<a class=\"paper-link\" href=\"$(abstract_summary_path(selection, paper_id))\">Summarize abstract</a>"
    pdf_summary_action = pdf_link === nothing ? "" : "<a class=\"paper-link\" href=\"$(pdf_summary_path(selection, paper_id))\">Summarize PDF</a>"
    open_pdf_action = pdf_link === nothing ? "" : "<a class=\"paper-link\" href=\"$(pdf_open_path(selection, paper_id))\">Open local PDF</a>"
    appeared_on = maybe_string(row.appeared_on)
    submitted_on = maybe_string(row.submitted_on)
    date_bits = String[]
    !isempty(appeared_on) && push!(date_bits, "<span class=\"paper-date\">Appeared $(html_escape(appeared_on))</span>")
    !isempty(submitted_on) && submitted_on != appeared_on && push!(date_bits, "<span class=\"paper-submitted\">Submitted $(html_escape(submitted_on))</span>")
    date_line = join(date_bits)

    return """
    <details class=\"paper-card\"$details_open>
      <summary class=\"paper-summary\">
        <span class=\"paper-title\">$(html_escape(maybe_string(row.title)))</span>
        <span class=\"paper-summary-meta\">$score_chip$label_chip</span>
      </summary>
      <div class=\"paper-body\">
        <div class=\"paper-topline\">
          $date_line
          <span class=\"paper-categories\">$(html_escape(maybe_string(row.categories)))</span>
        </div>
        $score_detail_html
        $authors_html
        $abstract_html
        $abstract_summary_html
        $comment_html
        $pdf_summary_html
        $journal_html
        <div class=\"paper-actions\">
          <a class=\"paper-link\" href=\"$(html_escape(maybe_string(row.abs_url)))\" target=\"_blank\" rel=\"noreferrer\">Abstract</a>
          $pdf_html
          $html_html
          $abstract_summary_action
          $pdf_summary_action
          $open_pdf_action
        </div>
        <div class=\"label-actions\">
          $(render_label_actions(selection, paper_id, current_label))
        </div>
      </div>
    </details>
    """
end

function render_papers(selection::BrowseSelection, papers)
    isempty(papers) && return """
    <section class=\"empty-state\">
      <h2>No papers in this slice</h2>
      <p>Pick another day, week, or month from the calendar, or refresh this selection.</p>
      <a class=\"primary-button\" href=\"$(refresh_path(selection))\">Refresh</a>
    </section>
    """

    return join(render_paper_card(selection, row) for row in papers)
end

function render_quick_links(selection::BrowseSelection)
    reference_day = selection.reference_day
    links = [
        ("Today", window_selection("today"; reference_day)),
        ("This Week", window_selection("week"; reference_day)),
        ("This Month", window_selection("month"; reference_day)),
    ]

    return join(selection_link(label, target, selection, "nav-link") for (label, target) in links)
end

weekday_labels() = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

function render_calendar_month(selection::BrowseSelection, month_start::Date, counts::Dict{Date, Int}, viewed_days::Set{Date})
    month_end = Dates.lastdayofmonth(month_start)
    month_target = browse_selection("month", month_start; reference_day = selection.reference_day)
    grid_start = Dates.firstdayofweek(month_start)
    grid_end = Dates.lastdayofweek(month_end)

    header_cells = join("<span class=\"calendar-head-cell\">$label</span>" for label in weekday_labels())
    rows = String[]
    current = grid_start

    while current <= grid_end
        week_start = current
        week_target = browse_selection("week", week_start; reference_day = selection.reference_day)
        week_link = if week_start > selection.reference_day
            "<span class=\"calendar-week-link disabled\">Week</span>"
        else
            selection_link("Week", week_target, selection, "calendar-week-link")
        end

        day_cells = String[]
        for offset in 0:6
            day_value = week_start + Day(offset)
            in_month = month(day_value) == month(month_start) && year(day_value) == year(month_start)
            if !in_month
                push!(day_cells, "<span class=\"calendar-day filler\"></span>")
                continue
            end

            if day_value > selection.reference_day
                push!(day_cells, "<span class=\"calendar-day future\"><span class=\"calendar-day-number\">$(Dates.day(day_value))</span></span>")
                continue
            end

            day_target = browse_selection("day", day_value; reference_day = selection.reference_day)
            classes = ["calendar-day"]
            same_selection(day_target, selection) && push!(classes, "active")
            day_value == selection.reference_day && push!(classes, "latest")
      in(day_value, viewed_days) && push!(classes, "viewed")
            count = get(counts, day_value, 0)
            count_html = count > 0 ? "<span class=\"calendar-day-count\">$count</span>" : ""
            push!(
                day_cells,
                "<a class=\"$(join(classes, ' '))\" href=\"$(browse_path(day_target))\"><span class=\"calendar-day-number\">$(Dates.day(day_value))</span>$count_html</a>",
            )
        end

        push!(rows, "<div class=\"calendar-week-row\">$week_link$(join(day_cells))</div>")
        current += Day(7)
    end

    month_link = selection_link(calendar_month_label(month_start), month_target, selection, "calendar-month-link")

    return """
    <section class=\"calendar-month-card\">
      <div class=\"calendar-month-header\">$month_link</div>
      <div class=\"calendar-weekday-row\"><span class=\"calendar-week-placeholder\"></span>$header_cells</div>
      <div class=\"calendar-grid\">$(join(rows))</div>
    </section>
    """
end

function render_calendar_panel(selection::BrowseSelection, counts::Dict{Date, Int}, viewed_days::Set{Date})
    month_starts = [Dates.firstdayofmonth(selection.reference_day), Dates.firstdayofmonth(selection.reference_day - Month(1))]
    months_html = join(render_calendar_month(selection, month_start, counts, viewed_days) for month_start in month_starts)

    return """
    <section class=\"panel meta-section\">
      <div class=\"panel-header\">
        <h3>Recent calendar</h3>
        <p class=\"panel-copy\">Click a day, a whole week, or a month title to change the slice. Green days have already been viewed.</p>
      </div>
      <div class=\"calendar-panel\">$months_html</div>
    </section>
    """
end

function render_selection_summary_panel(selection::BrowseSelection, selection_summary)
    actions_html = string(
        "<a class=\"paper-link\" href=\"", selection_summary_path(selection, 5), "\">Summarize top 5</a>",
        "<a class=\"paper-link\" href=\"", selection_summary_path(selection, 10), "\">Summarize top 10</a>",
    )

    summary_html = if selection_summary === nothing
        "<p class=\"panel-copy\">Generate an overview of the current slice on demand. The summary uses the current ranking and reuses cached paper summaries when they exist.</p>"
    else
        generated_at = maybe_string(selection_summary.generated_at)
        top_n = Int(selection_summary.top_n)
        string(
            "<p class=\"panel-copy\">Cached summary for the top ", top_n, " papers",
            isempty(generated_at) ? "" : " | Generated at $(html_escape(generated_at))",
            ".</p>",
            "<div class=\"generated-summary-body selection-summary-body\">",
            summary_text_html(maybe_string(selection_summary.summary_text)),
            "</div>",
        )
    end

    return """
    <section class=\"panel meta-section\">
      <div class=\"panel-header\">
        <h3>AI Selection Summary</h3>
        <p class=\"panel-copy\">Request a digest of the top-ranked papers for the current day, week, or month.</p>
      </div>
      <div class=\"paper-actions\">$actions_html</div>
      $summary_html
    </section>
    """
end

function render_layout(selection::BrowseSelection, papers, overview; notice::Union{Nothing, String} = nothing, calendar_counts::Dict{Date, Int} = Dict{Date, Int}(), viewed_days::Set{Date} = Set{Date}(), selection_summary = nothing)
    notice_html = notice === nothing ? "" : "<div class=\"notice\">$(html_escape(notice))</div>"
    latest_data_html = overview.latest_data_day === nothing ? "No papers ingested yet" : "Latest listed arXiv day: $(date_string(overview.latest_data_day))"
    reference_html = "Calendar anchor: $(date_string(selection.reference_day))"
    refresh_html = overview.last_refresh === nothing ? "Never refreshed" : "Last refresh: $(html_escape(overview.last_refresh))"
    quick_links = render_quick_links(selection)
    selection_summary_panel = render_selection_summary_panel(selection, selection_summary)

    stats = join([
        stat_card("Selection", string(overview.total_papers), selection_title(selection)),
        stat_card("Range", selection_range_text(selection), reference_html),
        stat_card("Labeled", string(overview.labeled_count), "Explicit feedback in this slice"),
        stat_card("Positive votes", string(overview.interested_count + overview.very_interested_count), string(latest_data_html, " | ", refresh_html)),
    ])

    return """
    <!doctype html>
    <html lang=\"en\">
      <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <title>arxiv-viewer</title>
        <script>
          window.MathJax = {
            tex: {
              inlineMath: [['\$', '\$'], ['\\(', '\\)']],
              displayMath: [['\$\$', '\$\$'], ['\\[', '\\]']],
              processEscapes: true,
            },
            options: {
              skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code'],
            },
          };

          document.addEventListener('DOMContentLoaded', () => {
            document.addEventListener('toggle', event => {
              if (!event.target.classList.contains('paper-card') || !event.target.open) {
                return;
              }

              if (window.MathJax && window.MathJax.typesetPromise) {
                window.MathJax.typesetPromise([event.target]);
              }
            }, true);
          });
        </script>
        <script defer src=\"https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js\"></script>
        <style>
          :root {
            --bg: #f2efe7;
            --panel: #fbfaf6;
            --ink: #1d1c1a;
            --muted: #6a645d;
            --accent: #0f766e;
            --accent-strong: #134e4a;
            --line: #d9d2c7;
            --warm: #b45309;
            --chip: #efe6d6;
            --shadow: 0 18px 36px rgba(38, 33, 28, 0.08);
          }

          * { box-sizing: border-box; }
          body {
            margin: 0;
            font-family: Georgia, "Iowan Old Style", "Palatino Linotype", serif;
            background:
              radial-gradient(circle at top right, rgba(15, 118, 110, 0.08), transparent 30%),
              radial-gradient(circle at bottom left, rgba(180, 83, 9, 0.08), transparent 28%),
              var(--bg);
            color: var(--ink);
          }

          a { color: inherit; text-decoration: none; }

          .page {
            max-width: 1440px;
            margin: 0 auto;
            padding: 28px 20px 56px;
          }

          .hero {
            background: linear-gradient(135deg, rgba(255,255,255,0.85), rgba(251,250,246,0.96));
            border: 1px solid rgba(15, 118, 110, 0.12);
            box-shadow: var(--shadow);
            border-radius: 28px;
            padding: 28px;
          }

          .hero-top {
            display: flex;
            gap: 16px;
            justify-content: space-between;
            align-items: flex-start;
            flex-wrap: wrap;
          }

          .eyebrow {
            display: inline-block;
            padding: 6px 10px;
            border-radius: 999px;
            background: rgba(15, 118, 110, 0.1);
            color: var(--accent-strong);
            font-size: 0.78rem;
            letter-spacing: 0.08em;
            text-transform: uppercase;
          }

          h1 {
            margin: 14px 0 8px;
            font-size: clamp(2.4rem, 6vw, 4rem);
            line-height: 0.95;
          }

          .hero-copy {
            max-width: 860px;
            color: var(--muted);
            font-size: 1.02rem;
            line-height: 1.6;
          }

          .hero-actions,
          .nav-row,
          .paper-topline,
          .paper-actions,
          .label-actions,
          .selection-meta {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
            align-items: center;
          }

          .hero-actions {
            margin-top: 18px;
          }

          .primary-button,
          .secondary-button,
          .nav-link,
          .label-action,
          .paper-link,
          .calendar-week-link,
          .calendar-day,
          .calendar-month-link {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            border-radius: 999px;
            transition: transform 0.16s ease, box-shadow 0.16s ease, background 0.16s ease;
          }

          .primary-button,
          .secondary-button {
            padding: 12px 18px;
            font-weight: 700;
          }

          .primary-button {
            background: var(--accent);
            color: #f8fffd;
            box-shadow: 0 10px 18px rgba(15, 118, 110, 0.18);
          }

          .secondary-button {
            border: 1px solid var(--line);
            background: rgba(255,255,255,0.78);
            color: var(--ink);
          }

          .primary-button:hover,
          .secondary-button:hover,
          .nav-link:hover,
          .label-action:hover,
          .paper-link:hover,
          .calendar-week-link:hover,
          .calendar-day:hover,
          .calendar-month-link:hover {
            transform: translateY(-1px);
          }

          .notice {
            margin-top: 16px;
            padding: 12px 14px;
            border-radius: 16px;
            background: rgba(15, 118, 110, 0.1);
            color: var(--accent-strong);
          }

          .main-grid {
            display: grid;
            grid-template-columns: minmax(0, 1.9fr) minmax(320px, 1.1fr);
            gap: 22px;
            margin-top: 22px;
          }

          .column,
          .sidebar {
            display: flex;
            flex-direction: column;
            gap: 18px;
          }

          .panel {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 24px;
            box-shadow: var(--shadow);
            padding: 20px;
          }

          .nav-row {
            margin-bottom: 12px;
          }

          .nav-link {
            padding: 10px 14px;
            background: rgba(255,255,255,0.86);
            border: 1px solid var(--line);
            font-weight: 700;
          }

          .nav-link.active,
          .calendar-week-link.active,
          .calendar-month-link.active,
          .calendar-day.active {
            background: var(--ink);
            color: #faf7f1;
            border-color: var(--ink);
          }

          .selection-title {
            font-size: 1.2rem;
            font-weight: 700;
          }

          .selection-subtitle,
          .selection-note,
          .panel-copy {
            color: var(--muted);
            line-height: 1.5;
          }

          .selection-note {
            margin-top: 10px;
          }

          .stats-grid {
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 12px;
          }

          .stat-card {
            padding: 16px;
            border-radius: 18px;
            background: linear-gradient(180deg, rgba(255,255,255,0.88), rgba(246,242,235,0.98));
            border: 1px solid rgba(15, 118, 110, 0.08);
          }

          .stat-title {
            font-size: 0.82rem;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--muted);
          }

          .stat-value {
            margin-top: 8px;
            font-size: 1.5rem;
            font-weight: 700;
            line-height: 1.2;
          }

          .stat-detail {
            margin-top: 6px;
            color: var(--muted);
            line-height: 1.5;
          }

          .paper-stack {
            display: grid;
            gap: 16px;
          }

          .paper-card {
            border-radius: 22px;
            background: linear-gradient(180deg, rgba(255,255,255,0.92), rgba(250,248,242,0.96));
            border: 1px solid rgba(15, 118, 110, 0.1);
            overflow: hidden;
          }

          .paper-summary {
            list-style: none;
            cursor: pointer;
            padding: 18px 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
          }

          .paper-summary-meta {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            flex-wrap: wrap;
            justify-content: flex-end;
          }

          .paper-summary::-webkit-details-marker {
            display: none;
          }

          .paper-summary::after {
            content: '+';
            color: var(--accent-strong);
            font-size: 1.2rem;
            flex-shrink: 0;
          }

          .paper-card[open] .paper-summary::after {
            content: '−';
          }

          .paper-body {
            padding: 0 20px 20px;
          }

          .paper-topline {
            color: var(--muted);
            font-size: 0.85rem;
          }

          .paper-categories,
          .paper-label,
          .paper-score {
            padding: 4px 10px;
            border-radius: 999px;
            background: var(--chip);
          }

          .paper-label {
            color: var(--warm);
            font-weight: 700;
          }

          .paper-score {
            color: var(--accent-strong);
            font-weight: 700;
          }

          .paper-label.muted {
            color: var(--muted);
          }

          .paper-title {
            margin: 0;
            font-size: clamp(1.05rem, 2vw, 1.35rem);
            line-height: 1.18;
            font-weight: 700;
          }

          .paper-authors,
          .paper-abstract,
          .paper-comment,
          .paper-journal,
          .paper-score-detail,
          .generated-summary-body {
            margin: 0 0 10px;
            line-height: 1.6;
          }

          .paper-authors,
          .paper-comment,
          .paper-journal,
          .paper-score-detail {
            color: var(--muted);
          }

          .generated-summary {
            margin: 0 0 12px;
            padding: 12px 14px;
            border-radius: 16px;
            background: rgba(15, 118, 110, 0.08);
            border: 1px solid rgba(15, 118, 110, 0.12);
          }

          .generated-summary-label {
            margin-bottom: 6px;
            color: var(--accent-strong);
            font-size: 0.82rem;
            font-weight: 700;
            letter-spacing: 0.04em;
            text-transform: uppercase;
          }

          .selection-summary-body {
            margin-top: 12px;
          }

          .paper-abstract mjx-container {
            margin: 0.12em 0;
          }

          .paper-link,
          .label-action,
          .calendar-week-link,
          .calendar-month-link {
            padding: 9px 12px;
            font-size: 0.92rem;
            border: 1px solid var(--line);
            background: rgba(255,255,255,0.82);
          }

          .label-action.active {
            background: rgba(15, 118, 110, 0.14);
            color: var(--accent-strong);
            border-color: rgba(15, 118, 110, 0.28);
            font-weight: 700;
          }

          .panel-header h3,
          .meta-section h3 {
            margin: 0 0 8px;
            font-size: 1rem;
          }

          .panel-copy {
            margin: 0 0 14px;
          }

          .calendar-panel {
            display: grid;
            gap: 14px;
          }

          .calendar-month-card {
            padding: 14px;
            border-radius: 18px;
            background: linear-gradient(180deg, rgba(255,255,255,0.9), rgba(247,243,236,0.98));
            border: 1px solid rgba(15, 118, 110, 0.08);
          }

          .calendar-month-header {
            margin-bottom: 10px;
          }

          .calendar-month-link {
            font-weight: 700;
          }

          .calendar-weekday-row,
          .calendar-week-row {
            display: grid;
            grid-template-columns: 56px repeat(7, minmax(0, 1fr));
            gap: 6px;
          }

          .calendar-weekday-row {
            margin-bottom: 6px;
          }

          .calendar-head-cell,
          .calendar-week-placeholder {
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--muted);
            font-size: 0.8rem;
          }

          .calendar-grid {
            display: grid;
            gap: 6px;
          }

          .calendar-week-link {
            min-height: 44px;
          }

          .calendar-week-link.disabled {
            color: var(--muted);
            background: rgba(255,255,255,0.5);
          }

          .calendar-day,
          .calendar-day.filler,
          .calendar-day.future {
            min-height: 44px;
            padding: 6px;
            border-radius: 14px;
            border: 1px solid rgba(15, 118, 110, 0.08);
            background: rgba(255,255,255,0.8);
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            gap: 2px;
          }

          .calendar-day.filler {
            visibility: hidden;
          }

          .calendar-day.future {
            color: var(--muted);
            background: rgba(244, 240, 232, 0.6);
          }

          .calendar-day.viewed {
            background: rgba(34, 197, 94, 0.14);
            border-color: rgba(34, 197, 94, 0.3);
            color: #166534;
          }

          .calendar-day.latest {
            box-shadow: inset 0 0 0 1px rgba(15, 118, 110, 0.28);
          }

          .calendar-day.active.viewed {
            box-shadow: inset 0 0 0 2px rgba(134, 239, 172, 0.5);
          }

          .calendar-day-number {
            font-weight: 700;
            line-height: 1;
          }

          .calendar-day-count {
            font-size: 0.74rem;
            color: var(--muted);
          }

          .meta-list {
            list-style: none;
            padding: 0;
            margin: 0;
            display: grid;
            gap: 8px;
          }

          .meta-list li {
            display: flex;
            justify-content: space-between;
            gap: 10px;
            padding: 10px 0;
            border-bottom: 1px solid rgba(29, 28, 26, 0.08);
          }

          .meta-list li:last-child {
            border-bottom: none;
          }

          .meta-empty {
            color: var(--muted);
            line-height: 1.5;
          }

          .empty-state {
            padding: 36px;
            text-align: center;
            border-radius: 24px;
            background: linear-gradient(135deg, rgba(255,255,255,0.92), rgba(239,230,214,0.5));
            border: 1px dashed rgba(15, 118, 110, 0.25);
          }

          .empty-state h2 {
            margin-top: 0;
          }

          @media (max-width: 1080px) {
            .main-grid {
              grid-template-columns: 1fr;
            }
          }

          @media (max-width: 640px) {
            .page {
              padding: 18px 14px 32px;
            }

            .hero,
            .panel,
            .calendar-month-card {
              padding: 16px;
              border-radius: 18px;
            }

            .paper-summary,
            .paper-body {
              padding-left: 16px;
              padding-right: 16px;
            }

            .stats-grid {
              grid-template-columns: 1fr;
            }

            .calendar-weekday-row,
            .calendar-week-row {
              grid-template-columns: 52px repeat(7, minmax(0, 1fr));
              gap: 4px;
            }
          }
        </style>
      </head>
      <body>
        <main class=\"page\">
          <section class=\"hero\">
            <div class=\"hero-top\">
              <div>
                <span class=\"eyebrow\">Phase 1 Core Reader</span>
                <h1>arxiv-viewer</h1>
                <p class=\"hero-copy\">Local Julia reader for astro-ph mailings. Browse by the day papers appeared on arXiv, refresh an exact day, week, or month on demand, and let explicit votes immediately reshape the reading order.</p>
              </div>
              <div class=\"hero-actions\">
                <a class=\"primary-button\" href=\"$(refresh_path(selection))\">Refresh</a>
                <a class=\"secondary-button\" href=\"https://arxiv.org/list/astro-ph/new\" target=\"_blank\" rel=\"noreferrer\">Open arXiv new list</a>
              </div>
            </div>
            $notice_html
          </section>

          <section class=\"main-grid\">
            <div class=\"column\">
              <section class=\"panel\">
                <div class=\"nav-row\">$quick_links</div>
                <div class=\"selection-meta\">
                  <div class=\"selection-title\">$(html_escape(selection_title(selection)))</div>
                  <div class=\"selection-subtitle\">$(html_escape(selection_range_text(selection)))</div>
                </div>
                <p class=\"selection-note\">Papers are ranked by a dynamic score out of 10. Your votes <strong>++</strong>, <strong>+</strong>, and <strong>-</strong> directly modify that score and steer future text/category matching.</p>
                <div class=\"stats-grid\">$stats</div>
              </section>

              $selection_summary_panel

              <section class=\"paper-stack\">
                $(render_papers(selection, papers))
              </section>
            </div>

            <aside class=\"sidebar\">
              $(render_calendar_panel(selection, calendar_counts, viewed_days))

              <section class=\"panel meta-section\">
                <h3>Counts in selection</h3>
                $(render_daily_counts(overview.daily_counts))
              </section>

              <section class=\"panel meta-section\">
                <h3>Active categories</h3>
                $(render_named_count_list(overview.category_counts, :category_code))
              </section>

              <section class=\"panel meta-section\">
                <h3>Recurring authors</h3>
                $(render_named_count_list(overview.author_counts, :author_name))
              </section>
            </aside>
          </section>
        </main>
      </body>
    </html>
    """
end

function should_auto_refresh_selection(selection::BrowseSelection)
    return selection.mode == "day" && !selection_has_successful_ingestion(selection)
end

function render_window(selection::BrowseSelection; notice::Union{Nothing, String} = nothing, auto_refresh::Bool = false)
    resolved_notice = notice

    if auto_refresh && should_auto_refresh_selection(selection)
        try
            refresh_selection!(selection)
        catch err
            resolved_notice === nothing && (resolved_notice = "Refresh failed; showing local data. $(sprint(showerror, err))")
        end
    end

    mark_selection_viewed!(selection)
    papers = list_papers(selection)
    overview = overview_for_window(selection)
    selection_summary = latest_selection_summary_for(selection)
    calendar_counts = recent_calendar_counts(selection.reference_day)
    calendar_lower = Dates.firstdayofmonth(selection.reference_day - Month(1))
    viewed_days = viewed_days_in_range(calendar_lower, selection.reference_day)
    return html(ParsedHTMLString(render_layout(selection, papers, overview; notice = resolved_notice, calendar_counts, viewed_days, selection_summary)))
end

render_window(window::String; notice::Union{Nothing, String} = nothing, auto_refresh::Bool = false) = render_window(default_window_selection(window); notice, auto_refresh)

render_window(mode::String, anchor::AbstractString; notice::Union{Nothing, String} = nothing, auto_refresh::Bool = false) = render_window(browse_selection(mode, anchor); notice, auto_refresh)

function register_routes!()
    ROUTES_REGISTERED[] && return nothing

    route("/") do
        render_window("today")
    end

    route("/today") do
        render_window("today")
    end

    route("/week") do
        render_window("week"; auto_refresh = true)
    end

    route("/month") do
        render_window("month"; auto_refresh = true)
    end

    route("/browse/:mode/:anchor") do
        render_window(String(params(:mode)), String(params(:anchor)); auto_refresh = true)
    end

    route("/refresh/:mode/:anchor") do
        selection = browse_selection(String(params(:mode)), String(params(:anchor)))
        try
            count = refresh_selection!(selection)
            render_window(selection; notice = "Refreshed $(count) astro-ph papers for $(selection_range_text(selection)).")
        catch err
            render_window(selection; notice = "Refresh failed; showing local data. $(sprint(showerror, err))")
        end
    end

    route("/label/:mode/:anchor/:paper_id/:label") do
        selection = browse_selection(String(params(:mode)), String(params(:anchor)))
        saved_label = save_label!(String(params(:paper_id)), String(params(:label)))
        render_window(selection; notice = "Saved $(label_display(saved_label)) for $(String(params(:paper_id))).")
    end

    route("/pdf/open/:mode/:anchor/:paper_id") do
        selection = browse_selection(String(params(:mode)), String(params(:anchor)))
        paper_id = String(params(:paper_id))

        try
            local_path = open_local_pdf!(paper_id)
            render_window(selection; notice = "Opened cached PDF for $(paper_id) at $(local_path).")
        catch err
            render_window(selection; notice = "PDF open failed; showing local data. $(sprint(showerror, err))")
        end
    end

    route("/summary/abstract/:mode/:anchor/:paper_id") do
        selection = browse_selection(String(params(:mode)), String(params(:anchor)))
        paper_id = String(params(:paper_id))

        try
            summarize_abstract!(paper_id; force = true)
            render_window(selection; notice = "Generated abstract summary for $(paper_id).")
        catch err
            render_window(selection; notice = "Abstract summarization failed; showing local data. $(sprint(showerror, err))")
        end
    end

    route("/summary/pdf/:mode/:anchor/:paper_id") do
        selection = browse_selection(String(params(:mode)), String(params(:anchor)))
        paper_id = String(params(:paper_id))

        try
            summarize_pdf!(paper_id; force = true)
            render_window(selection; notice = "Generated PDF summary for $(paper_id).")
        catch err
            render_window(selection; notice = "PDF summarization failed; showing local data. $(sprint(showerror, err))")
        end
    end

    route("/summary/top/:mode/:anchor/:count") do
        selection = browse_selection(String(params(:mode)), String(params(:anchor)))
        top_n = summary_count_or_default(String(params(:count)))

        try
            summarize_selection!(selection; top_n, force = true)
            render_window(selection; notice = "Generated an AI summary for the top $(top_n) papers in $(selection_range_text(selection)).")
        catch err
            render_window(selection; notice = "Selection summarization failed; showing local data. $(sprint(showerror, err))")
        end
    end

    ROUTES_REGISTERED[] = true
    return nothing
end

function start_server(; port::Integer = server_port())
    Genie.config.run_as_server = true
    init_database!()

    try
        recompute_paper_scores!()
    catch err
        @warn "Score recomputation failed; continuing with existing data" error = sprint(showerror, err)
    end

    try
        startup_refresh_today!()
    catch err
        @warn "Startup refresh failed; starting server with local state only" error = sprint(showerror, err)
    end

    register_routes!()
    up(Int(port))
end