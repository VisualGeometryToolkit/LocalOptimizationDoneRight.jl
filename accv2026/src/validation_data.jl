# =============================================================================
# src/validation_data.jl — the data a cross-validation reads, from its spec.
#
# Every scene list and every unit sample of this paper comes from the
# `cross_validation` of a `[tuning.<name>]` spec (VisualGeometryToolkitEval
# Tuning: the registered scene split of its configs/splits.toml, the unit
# samplings, stable name-keyed seeds). Nothing here states a scene, a fraction
# or a seed. A driver states which samplings it supports by the SIGNATURE of
# the function it calls, so a spec with an unsupported sampling is a
# `MethodError` before any work:
#
#   two_view_scene_loaders(cv, pool_dir)  stratified (or every) PAIRS per scene
#
# and a pool producer's scene set is one side of a registered split
# (VisualGeometryToolkitEval DataArtifacts `split_scenes`, the resolver the producer
# cells, the pool driver and the data catalog share).
# =============================================================================
using VisualGeometryToolkitEval.DataArtifacts: split_scenes
using VisualGeometryToolkitEval.Tuning: CrossValidation, SceneSplit, ExhaustiveSampling, StratifiedSampling,
    sample_units, validation_units, test_units,
    validation_scenes, test_scenes, tuning_spec, load_tuning_artifact, registered_split
import VisualGeometryToolkitEval.Tuning: sampling_unit
using VisualGeometryToolkitEval.Pools: load_pool, load_pool_residuals, residuals_path
using VisualGeometryToolkitCore.Pools: PoolPair

const TWO_VIEW_UNIT = sampling_unit(PoolPair)

"The cross-validations a two-view driver runs: every pair, or a stratified sample of each scene's pairs, per side."
const TwoViewCrossValidation =
    CrossValidation{<:SceneSplit, <:Union{ExhaustiveSampling,StratifiedSampling}, <:Union{ExhaustiveSampling,StratifiedSampling}}

"""
    sidecar_cross_validation(path) -> CrossValidation

The cross-validation a tuning artifact ran under (its persisted spec): a
evaluation of the artifact's operating points reads that cross-validation's
TEST side.
"""
sidecar_cross_validation(path::AbstractString) = load_tuning_artifact(path).spec.scheme.cross_validation

# A side's loaders: scene => zero-arg loader of the `(pool, residuals)` of the
# pairs `sampling` keeps of that scene (`pool.pairs` and the residuals both
# indexed 1:k over the kept pairs, in pool order — the shape LO engine's
# `stream_selections` reads). A stratified sample of a scene is a function of
# that scene's name and pair count alone, so each loader samples its own scene
# on load, and reads only the kept pairs' residual matrices.
function _load_side(pool_dir, s, sampling)
    path = joinpath(pool_dir, "$s.jld2")
    pool = load_pool(path)
    keep = only(values(sample_units(sampling, Dict(s => collect(eachindex(pool.pairs))))))
    res = load_pool_residuals(residuals_path(path), pool; pairs = keep)
    return ((; pairs = pool.pairs[keep], scene = pool.scene, problem = pool.problem),
            PoolResiduals(res.pool_key, res.kind, [residual_matrix(res, i) for i in keep]))
end
_side_loaders(pool_dir, scenes, sampling) =
    [s => let s = s
         () -> (@info "loading $s"; _load_side(pool_dir, s, sampling))
     end for s in scenes]

"""
    two_view_scene_loaders(cv::TwoViewCrossValidation, pool_dir) -> (; validation, test)

The two-view pools of `cv`'s scenes under `pool_dir` (`<scene>.jld2`), each
side a `Vector{Pair{String,Function}}` (scene ⇒ zero-arg loader, scenes
sorted) whose loader returns `(pool, residuals)` of the pairs the side's
sampling keeps (in pool order). A pooled sampling is a `MethodError`.
"""
two_view_scene_loaders(cv::TwoViewCrossValidation, pool_dir::AbstractString) =
    (validation = _side_loaders(pool_dir, validation_scenes(cv), cv.validation),
     test = _side_loaders(pool_dir, test_scenes(cv), cv.test))
