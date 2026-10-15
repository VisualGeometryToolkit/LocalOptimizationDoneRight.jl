# Build the RansacLib LO C++ shim for RansacLibLO.jl
#
# Called by `Pkg.build("RansacLibLO")`. Clones RansacLib (header-only, BSD-3)
# on first build and compiles `libransaclib_jl.so` (see ransaclib_wrapper/).
#
# Requires: git, g++. Eigen comes from Eigen_jll (its include directory is
# handed to the Makefile as EIGEN_INCLUDE); set EIGEN_INCLUDE in the
# environment to use another copy.

using Eigen_jll: Eigen_jll

const RANSACLIB_DIR = joinpath(@__DIR__, "RansacLib")
# Pinned upstream commit (byte-identical vendoring contract — RansacLib is
# never edited; see deps/ransaclib_wrapper/julia_wrapper.cpp header).
const RANSACLIB_COMMIT = "b952083fcf1b2aea001bf178e010e540ff372889"
if !isdir(RANSACLIB_DIR)
    println("Cloning RansacLib source ($RANSACLIB_COMMIT)...")
    run(`git clone https://github.com/tsattler/RansacLib.git $RANSACLIB_DIR`)
    run(`git -C $RANSACLIB_DIR checkout --quiet $RANSACLIB_COMMIT`)
end

const WRAPPER_DIR = joinpath(@__DIR__, "ransaclib_wrapper")
const SHIM = joinpath(WRAPPER_DIR,
    "libransaclib_jl.$(Sys.iswindows() ? "dll" : Sys.isapple() ? "dylib" : "so")")

if !isfile(SHIM)
    println("Building RansacLib LO shim...")
    eigen = get(ENV, "EIGEN_INCLUDE", joinpath(Eigen_jll.artifact_dir, "include", "eigen3"))
    cd(WRAPPER_DIR) do
        run(`make EIGEN_INCLUDE=$eigen`)
    end
    @assert isfile(SHIM) "Build failed: $SHIM not found"
    println("Built: $SHIM")
else
    println("RansacLib LO shim already built: $SHIM")
end
