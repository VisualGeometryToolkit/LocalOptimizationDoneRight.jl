# The RansacLib LO arms' identity: the VisualGeometryToolkitCore traits and the
# external-refit contract they implement (src/lebeda_lo.jl, loaded by
# config.jl) resolve to the arms' methods: a renamed trait or a moved extension
# point upstream would leave the arms loading fine but dispatching to nothing.
import VisualGeometryToolkitCore as VgtkCore
using Test
using VisualGeometryToolkitCore: VisualGeometryToolkitCore, RefitFamily, ExternalRefit, FixedScale, LossWidth,
    external_workspace, refine_external!
using RansacLibLO: RansacLibLO, LebedaLOOptions, PRESET_REFERENCE
using VisualGeometryToolkitEval.Evaluation: consumed_axis

@testset "RansacLib LO arms: identity" begin
    opts = LebedaLOOptions(num_lo_trials = 4)   # any non-reference options
    for lo in (LebedaIterLO(opts, 0), LebedaLOPlus(opts, 0), LebedaLOPlus(PRESET_REFERENCE, 0))
        @test lo isa VgtkCore.AbstractLocalOptimization
        @test RefitFamily(lo) isa ExternalRefit
        @test VgtkCore.scale_interface(lo) isa FixedScale
        @test VgtkCore.loss_family(lo) === :tls
        @test VgtkCore.optimization_path(lo) === :classical_lo
        @test VgtkCore.lo_marker(lo) isa Symbol
        # an external refiner consumes an absolute loss width
        @test consumed_axis(lo) === LossWidth()
    end
    @test VgtkCore.lo_label(LebedaIterLO(opts, 0)) == "TLS-LO"
    @test VgtkCore.lo_label(LebedaLOPlus(opts, 0)) == raw"TLS-LO$^+$"
    @test VgtkCore.lo_label(LebedaLOPlus(PRESET_REFERENCE, 0)) == raw"TLS-LO$^+$ (ref)"
    @test String(VgtkCore.lo_marker(LebedaLOPlus(opts, 0))) == "pentagon*"
    # the arms implement VisualGeometryToolkitCore's external-refit contract
    @test any(m -> m.sig <: Tuple{typeof(external_workspace), Union{LebedaIterLO, LebedaLOPlus}, Vararg},
              methods(external_workspace))
    @test any(m -> m.sig <: Tuple{typeof(refine_external!), LebedaWorkspace, Union{LebedaIterLO, LebedaLOPlus},
                                  Any, Any, LossWidth, Any},
              methods(refine_external!))
    # the vendored baseline is reachable
    @test isdefined(RansacLibLO, :lebeda_lo) && isdefined(RansacLibLO, :lebeda_iterlo)
end
