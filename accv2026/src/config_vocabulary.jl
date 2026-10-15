# =============================================================================
# config_vocabulary.jl — config keys RETIRED from the cells' TOMLs.
#
# A key nothing reads is a second authority that can only agree or silently
# disagree with the code (package-cleanup audit, 2026-09-08): `arm.name` in
# the Aachen/InLoc PnP cells labelled an arm the driver selects by its own
# constants, and `pool.dedupe` in the Aachen pools cell described a rule the
# pool builder applies unconditionally. Both are deleted from the configs
# (the recorded run configs were stripped of them once, 2026-09-09), and
# test/test_config_vocabulary.jl refuses their return. Since the tuning
# protocol of record (configs/tuning.toml, 2026-10-01) every tuning parameter
# is a [tuning.<name>] key: the old per-cell [two_knob] table, the
# expand-on-boundary caps of miscal_protocol.toml, the subsample seed of
# cv_protocol.toml and the PnP CV's half-octave ladders are retired here.
# =============================================================================
const RETIRED_CONFIG_KEYS = [("arm", "name"), ("pool", "dedupe"),
    ("two_knob", "mode"), ("two_knob", "np"), ("two_knob", "resume_val"),
    ("protocol", "k_ext_pts"), ("protocol", "k_ext_max"), ("protocol", "subsample_seed"),
    ("arm", "a0"), ("arm", "a_half_octaves"), ("arm", "k_half_octaves"),
    ("arm", "criterion"), ("arm", "max_expansions"), ("arm", "ext_half_octaves"),
    # the PnP cells' width keys under their full names since 2026-10-01
    # (`scale_multiple`, `outlier_halfwidth`)
    ("arm", "k"), ("arm", "a")]
