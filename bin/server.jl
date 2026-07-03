#!/usr/bin/env julia

using Pkg

Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArxivViewer

ArxivViewer.start_server()