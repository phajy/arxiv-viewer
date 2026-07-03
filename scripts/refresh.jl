#!/usr/bin/env julia

using Pkg

Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArxivViewer

count = ArxivViewer.refresh_recent!()
println("Refreshed $(count) first-time astro-ph submissions.")