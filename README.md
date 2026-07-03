# arxiv-viewer

Local Julia web app for scanning new arXiv astronomy papers, ranking them by likely personal relevance, and producing concise AI-assisted summaries on demand.

## Current status

Phase 1 is largely in place:

- Ingest astro-ph listings from arXiv catch-up pages (by appearance date)
- Browse by day, week, or month with a calendar sidebar
- Label papers (`-`, `+`, `++`) and adapt ranking from your votes
- On-demand abstract summaries, PDF summaries, and top-N selection digests via local Ollama
- PDF download/cache and open in Preview (macOS)

See [docs/implementation-plan.md](docs/implementation-plan.md) for the full roadmap.

## Requirements

- Julia 1.12+ (see `Project.toml`)
- [Ollama](https://ollama.com/) running locally with a model (default: `qwen2.5:7b`)
- `pdftotext` from Poppler (for PDF summarization)
- macOS for “Open local PDF” in Preview; other platforms can still download/cache PDFs

## Quick start

```bash
# Install dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run tests
julia --project=. test/runtests.jl

# Start the web UI (default http://127.0.0.1:8000)
julia bin/server.jl

# Or refresh recent papers from the CLI
julia scripts/refresh.jl
```

Data is stored under `data/` (SQLite database, cached PDFs). Override paths with `ARXIV_VIEWER_DATA_DIR`, `ARXIV_VIEWER_DB_PATH`, and related env vars in `src/config.jl`.

## V1 scope

- Track submissions from the full astro-ph family: `astro-ph.CO`, `astro-ph.EP`, `astro-ph.GA`, `astro-ph.HE`, `astro-ph.IM`, `astro-ph.SR`.
- Show Today, This Week, and This Month views with a global overview of relevant papers.
- Let the user label each paper as `not interested`, `interested`, or `very interested`.
- Rank papers using lightweight adaptive TF-IDF scoring plus transparent heuristics (not heavy model training).
- Summarize papers on demand from abstracts and PDFs; defer automatic batch summarization until the workflow is stable.
- Defer Zotero export and sync until after the core reader, ranking, and summary workflow is stable.

## Stack

- Web framework: `Genie.jl`
- Storage: `SQLite.jl`
- HTTP and parsing: `HTTP.jl`, `EzXML.jl`, `JSON3.jl`
- AI: local `Ollama` first, optional cloud adapter later

## Build order

1. Metadata ingestion and local database — done
2. Web UI with time windows and paper labeling — done
3. Abstract summaries and adaptive ranking — done
4. Selective PDF summarization — done (on-demand)
5. arXiv HTML full-paper summarization — planned
6. Zotero export
7. Optional direct Zotero sync
