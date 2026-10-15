// =============================================================================
// julia_wrapper.cpp — C shim exposing RansacLib's LO-MSAC local optimization
// (Sattler's reference implementation of [Lebeda, Matas, Chum, "Fixing the
// Locally Optimized RANSAC", BMVC 2012] — RansacLib/ransac.h, Algorithms 2&3)
// as a SEEDED, STANDALONE refiner for essential, fundamental, and homography
// models (model_kind = 0/1/2).
//
// VERBATIM-REFERENCE CONTRACT: RansacLib is vendored byte-identical to
// upstream and is never edited. Everything in this file is RansacLib's
// intended usage surface:
//   (a) the Solver-concept plug-in its template API requires the user to
//       supply (E model, non-minimal fit, residuals), and
//   (b) a subclass lifting the `protected` LocalOptimization/LeastSquaresFit
//       members so the LO can be entered with a caller-supplied seed
//       (subclassing is usage, not modification).
//
// Solver plug-in (the only numerics we author), one class, model kind by
// runtime switch (single RansacLib template instantiation):
//   * E (model_kind 0): Hartley-normalized 8-point DLT + projection to the
//     essential manifold (SVD, singular values ((s1+s2)/2, (s1+s2)/2, 0));
//     residual = SQUARED first-order Sampson of x2' E x1 (same 4-term
//     denominator as the caller's canonical signed-Sampson scoring stack).
//     min_sample_size = 5.
//   * F (model_kind 1): same 8-point DLT + rank-2 projection (zero smallest
//     singular value); same epipolar Sampson residual. min_sample_size = 7.
//   * H (model_kind 2): Hartley-normalized 4-point DLT (2 rows/point);
//     residual = SQUARED codimension-2 Sampson of the transfer constraint
//     e = (x2 × H x1)_{1:2}, r² = eᵀ(JJᵀ)⁻¹e — the whitened transfer-error
//     convention of the caller's homography track. min_sample_size = 4,
//     non_minimal_sample_size = 5.
//   All fits are PLAIN (unweighted) least squares, exactly as RansacLib's
//   LeastSquaresFit drives them. DISCLOSED DELTA vs Lebeda's original code:
//   Lebeda's iterated LSq used Sampson-gradient REWEIGHTED fits (u2fw,
//   w_i = 1/||grad g_i||); RansacLib's refits are plain, and the arm is
//   attributed to Sattler's implementation as-is — no weighting is added.
//   Points are given in whatever frame the caller's threshold currency
//   lives in.
//
// Determinism: a std::mt19937 seeded from the caller's rng_seed is
// constructed per call and is the ONLY randomness source (RansacLib's LO
// samples exclusively through the supplied rng; no global rand()).
//
// Model-update accounting: the solver counts every NonMinimalSolver and
// LeastSquares invocation (each is one linear solve = one model update), so
// budget parity against the caller's LO update caps is measured, not
// estimated. With every stage active, full LO spends
// 1 + num_lo_trials * (2 + num_lsq_iterations) updates.
//
// License: RansacLib is BSD-3-Clause (c) 2019 Torsten Sattler. This shim is
// part of RansacLibLO.jl.
// =============================================================================

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <random>
#include <vector>

#include <Eigen/Dense>
#include <RansacLib/ransac.h>

namespace {

enum ModelKind { kEssential = 0, kFundamental = 1, kHomography = 2 };

// RansacLib Solver concept for LO-only (seeded) two-view model use.
class TwoViewLOSolver {
 public:
  // pts: 4 x n column-major, column i = (x1, y1, x2, y2), z = 1 implied.
  TwoViewLOSolver(const double* pts, int n, ModelKind kind)
      : pts_(Eigen::Map<const Eigen::Matrix<double, 4, Eigen::Dynamic>>(pts, 4, n)),
        n_(n), kind_(kind) {}

  inline int num_data() const { return n_; }
  // Honest minimal sizes: 5-pt E, 7-pt F, 4-pt H (the minimal solver itself
  // is never called; RansacLib uses the value in its data-size arithmetic).
  inline int min_sample_size() const {
    return kind_ == kEssential ? 5 : kind_ == kFundamental ? 7 : 4;
  }
  inline int non_minimal_sample_size() const {
    return kind_ == kHomography ? 5 : 8;
  }

  // Never used in LO-only operation; dummy per RansacLib's documentation
  // ("a dummy implementation returning false is sufficient").
  int MinimalSolver(const std::vector<int>&, std::vector<Eigen::Matrix3d>*) const {
    return 0;
  }

  bool NonMinimalSolver(const std::vector<int>& sample, Eigen::Matrix3d* M) const {
    ++num_model_updates_;
    return kind_ == kHomography ? FitDltH(sample, M) : FitDlt9(sample, M);
  }

  void LeastSquares(const std::vector<int>& inliers, Eigen::Matrix3d* M) const {
    ++num_model_updates_;
    Eigen::Matrix3d Mnew;
    const bool ok = kind_ == kHomography ? FitDltH(inliers, &Mnew) : FitDlt9(inliers, &Mnew);
    if (ok) *M = Mnew;   // keep the incumbent on a degenerate solve
  }

  double EvaluateModelOnPoint(const Eigen::Matrix3d& M, int i) const {
    return kind_ == kHomography ? SampsonH2(M, i) : SampsonEpi2(M, i);
  }

  long long num_model_updates() const { return num_model_updates_; }

 private:
  // Squared first-order Sampson of the epipolar constraint x2' M x1.
  double SampsonEpi2(const Eigen::Matrix3d& M, int i) const {
    const Eigen::Vector3d x1(pts_(0, i), pts_(1, i), 1.0);
    const Eigen::Vector3d x2(pts_(2, i), pts_(3, i), 1.0);
    const Eigen::Vector3d Mx1 = M * x1;
    const Eigen::Vector3d Mtx2 = M.transpose() * x2;
    const double C = x2.dot(Mx1);
    const double denom = Mx1(0) * Mx1(0) + Mx1(1) * Mx1(1) +
                         Mtx2(0) * Mtx2(0) + Mtx2(1) * Mtx2(1);
    return (C * C) / (denom + std::numeric_limits<double>::epsilon());
  }

  // Squared codimension-2 Sampson of the homography transfer constraint:
  // e = (x2 × H x1)_{1:2}, J = ∂e/∂(u1,v1,u2,v2), r² = eᵀ(JJᵀ)⁻¹e — the
  // whitened transfer-error convention of the caller's homography track.
  double SampsonH2(const Eigen::Matrix3d& H, int i) const {
    const double u1 = pts_(0, i), v1 = pts_(1, i);
    const double u2 = pts_(2, i), v2 = pts_(3, i);
    const Eigen::Vector3d Hx1 = H * Eigen::Vector3d(u1, v1, 1.0);
    const double a = Hx1(0), b = Hx1(1), c = Hx1(2);
    const double e1 = v2 * c - b;
    const double e2 = a - u2 * c;
    // J rows: [v2*h31−h21, v2*h32−h22, 0, c], [h11−u2*h31, h12−u2*h32, −c, 0]
    const double j11 = v2 * H(2, 0) - H(1, 0);
    const double j12 = v2 * H(2, 1) - H(1, 1);
    const double j14 = c;
    const double j21 = H(0, 0) - u2 * H(2, 0);
    const double j22 = H(0, 1) - u2 * H(2, 1);
    const double j23 = -c;
    const double g11 = j11 * j11 + j12 * j12 + j14 * j14;   // (JJᵀ)₁₁
    const double g22 = j21 * j21 + j22 * j22 + j23 * j23;   // (JJᵀ)₂₂
    const double g12 = j11 * j21 + j12 * j22;               // (JJᵀ)₁₂
    const double det = g11 * g22 - g12 * g12;
    if (!(det > 1e-30)) return std::numeric_limits<double>::max();
    return (e1 * (g22 * e1 - g12 * e2) + e2 * (g11 * e2 - g12 * e1)) / det;
  }

  struct Norm2D {
    Eigen::Vector2d c1, c2;
    double s1, s2;
  };

  bool Normalizer(const std::vector<int>& sample, Norm2D* nrm) const {
    const int m = static_cast<int>(sample.size());
    nrm->c1.setZero(); nrm->c2.setZero();
    for (int k = 0; k < m; ++k) {
      const int i = sample[k];
      nrm->c1 += pts_.col(i).head<2>();
      nrm->c2 += pts_.col(i).tail<2>();
    }
    nrm->c1 /= m; nrm->c2 /= m;
    double d1 = 0.0, d2 = 0.0;
    for (int k = 0; k < m; ++k) {
      const int i = sample[k];
      d1 += (pts_.col(i).head<2>() - nrm->c1).norm();
      d2 += (pts_.col(i).tail<2>() - nrm->c2).norm();
    }
    d1 /= m; d2 /= m;
    if (d1 < 1e-12 || d2 < 1e-12) return false;
    nrm->s1 = std::sqrt(2.0) / d1;
    nrm->s2 = std::sqrt(2.0) / d2;
    return true;
  }

  // Hartley-normalized 8-point DLT for the epipolar models, followed by the
  // model-kind projection: E — equalized singular values ((s1+s2)/2, ·, 0);
  // F — rank-2 (zero smallest singular value). Unit Frobenius output.
  bool FitDlt9(const std::vector<int>& sample, Eigen::Matrix3d* M) const {
    const int m = static_cast<int>(sample.size());
    if (m < 8) return false;
    Norm2D nrm;
    if (!Normalizer(sample, &nrm)) return false;

    // Constraint rows for x2n' * F * x1n = 0, F row-major in the unknown vector.
    Eigen::Matrix<double, Eigen::Dynamic, 9> A(m, 9);
    for (int k = 0; k < m; ++k) {
      const int i = sample[k];
      const double u1 = nrm.s1 * (pts_(0, i) - nrm.c1(0));
      const double v1 = nrm.s1 * (pts_(1, i) - nrm.c1(1));
      const double u2 = nrm.s2 * (pts_(2, i) - nrm.c2(0));
      const double v2 = nrm.s2 * (pts_(3, i) - nrm.c2(1));
      A.row(k) << u2 * u1, u2 * v1, u2, v2 * u1, v2 * v1, v2, u1, v1, 1.0;
    }

    Eigen::JacobiSVD<Eigen::Matrix<double, Eigen::Dynamic, 9>> svdA(
        A, Eigen::ComputeFullV);
    const Eigen::Matrix<double, 9, 1> f = svdA.matrixV().col(8);
    Eigen::Matrix3d Fn;
    Fn << f(0), f(1), f(2), f(3), f(4), f(5), f(6), f(7), f(8);

    // Denormalize: x2' F x1 = x2n' Fn x1n with xin = Ti xi.
    Eigen::Matrix3d T1, T2;
    T1 << nrm.s1, 0, -nrm.s1 * nrm.c1(0), 0, nrm.s1, -nrm.s1 * nrm.c1(1), 0, 0, 1;
    T2 << nrm.s2, 0, -nrm.s2 * nrm.c2(0), 0, nrm.s2, -nrm.s2 * nrm.c2(1), 0, 0, 1;
    const Eigen::Matrix3d F = T2.transpose() * Fn * T1;

    Eigen::JacobiSVD<Eigen::Matrix3d> svdF(
        F, Eigen::ComputeFullU | Eigen::ComputeFullV);
    const Eigen::Vector3d sv = svdF.singularValues();
    if (!sv.allFinite()) return false;
    Eigen::Matrix3d S = Eigen::Matrix3d::Zero();
    if (kind_ == kEssential) {
      const double sm = 0.5 * (sv(0) + sv(1));
      if (sm < 1e-14) return false;
      S(0, 0) = sm; S(1, 1) = sm;                 // essential manifold
    } else {
      if (sv(1) < 1e-14) return false;
      S(0, 0) = sv(0); S(1, 1) = sv(1);           // rank-2 fundamental
    }
    *M = svdF.matrixU() * S * svdF.matrixV().transpose();
    *M /= M->norm();   // unit Frobenius (Sampson is scale invariant)
    return M->allFinite();
  }

  // Hartley-normalized homography DLT (2 rows per point), unit Frobenius,
  // deterministic sign (largest-|entry| positive).
  bool FitDltH(const std::vector<int>& sample, Eigen::Matrix3d* M) const {
    const int m = static_cast<int>(sample.size());
    if (m < 4) return false;
    Norm2D nrm;
    if (!Normalizer(sample, &nrm)) return false;

    Eigen::Matrix<double, Eigen::Dynamic, 9> A(2 * m, 9);
    for (int k = 0; k < m; ++k) {
      const int i = sample[k];
      const double u1 = nrm.s1 * (pts_(0, i) - nrm.c1(0));
      const double v1 = nrm.s1 * (pts_(1, i) - nrm.c1(1));
      const double u2 = nrm.s2 * (pts_(2, i) - nrm.c2(0));
      const double v2 = nrm.s2 * (pts_(3, i) - nrm.c2(1));
      A.row(2 * k)     << 0, 0, 0, -u1, -v1, -1, v2 * u1, v2 * v1, v2;
      A.row(2 * k + 1) << u1, v1, 1, 0, 0, 0, -u2 * u1, -u2 * v1, -u2;
    }

    Eigen::JacobiSVD<Eigen::Matrix<double, Eigen::Dynamic, 9>> svdA(
        A, Eigen::ComputeFullV);
    const Eigen::Matrix<double, 9, 1> h = svdA.matrixV().col(8);
    Eigen::Matrix3d Hn;
    Hn << h(0), h(1), h(2), h(3), h(4), h(5), h(6), h(7), h(8);

    Eigen::Matrix3d T1, T2;
    T1 << nrm.s1, 0, -nrm.s1 * nrm.c1(0), 0, nrm.s1, -nrm.s1 * nrm.c1(1), 0, 0, 1;
    T2 << nrm.s2, 0, -nrm.s2 * nrm.c2(0), 0, nrm.s2, -nrm.s2 * nrm.c2(1), 0, 0, 1;
    Eigen::Matrix3d H = T2.inverse() * Hn * T1;

    const double nH = H.norm();
    if (!(nH > 1e-14) || !H.allFinite()) return false;
    H /= nH;
    // Deterministic sign: largest-|entry| positive.
    int rmax = 0, cmax = 0;
    H.cwiseAbs().maxCoeff(&rmax, &cmax);
    if (H(rmax, cmax) < 0) H = -H;
    *M = H;
    return true;
  }

  const Eigen::Matrix<double, 4, Eigen::Dynamic> pts_;
  const int n_;
  const ModelKind kind_;
  mutable long long num_model_updates_ = 0;
};

using LOMSAC = ransac_lib::LocallyOptimizedMSAC<
    Eigen::Matrix3d, std::vector<Eigen::Matrix3d>, TwoViewLOSolver>;

// Thin subclass lifting the protected LO entries — RansacLib usage, zero
// modification. RunFullLO calls the library's LocalOptimization verbatim.
// RunFullLOWithBase and RunIterLSQ are OUR compositions of the library's
// protected primitives (LeastSquaresFit / ScoreModel / UpdateBestModel):
// the former substitutes a caller-supplied base inlier set (diagnostic
// override), the latter runs the iterative-least-squares ladder alone (the
// Chum'03 "iterative" mechanism / Lebeda's LO'), mirroring the ladder block
// inside LocalOptimization.
class ExposedLO : public LOMSAC {
 public:
  // Full LO (Alg. 2 + 3), the published behavior: initial LSq fit at the
  // enlarged threshold, num_lo_steps_ non-minimal draws from the internally
  // derived base consensus, per-draw iterative least squares; best-tracking
  // on the MSAC score at the terminal threshold. The seed enters
  // best-tracking (LocalOptimization only overwrites on strict improvement).
  void RunFullLO(const ransac_lib::LORansacOptions& opt,
                 const TwoViewLOSolver& solver, std::mt19937* rng,
                 Eigen::Matrix3d* model, double* score) const {
    *score = std::numeric_limits<double>::max();
    ScoreModel(solver, *model, opt.squared_inlier_threshold_, score);
    LocalOptimization(opt, solver, rng, model, score);
  }

  // Full LO with a CALLER-SUPPLIED base inlier set (diagnostic/pipeline
  // override — NOT the published algorithm, which derives I_base internally
  // by gating at the enlarged threshold; see RunFullLO). Mirror of
  // LocallyOptimizedMSAC::LocalOptimization with the single substitution
  // inliers_base = base_indices.
  void RunFullLOWithBase(const ransac_lib::LORansacOptions& opt,
                         const TwoViewLOSolver& solver, std::mt19937* rng,
                         const std::vector<int>& base_indices,
                         Eigen::Matrix3d* model, double* score) const {
    const double kSqInThresh = opt.squared_inlier_threshold_;
    const double kThreshMult = opt.threshold_multiplier_;
    const int kMinNonMinSampleSize = solver.non_minimal_sample_size();
    const int kMinSampleSize = solver.min_sample_size();

    *score = std::numeric_limits<double>::max();
    ScoreModel(solver, *model, kSqInThresh, score);
    if (kMinNonMinSampleSize > solver.num_data()) return;

    Eigen::Matrix3d m_init = *model;
    LeastSquaresFit(opt, kSqInThresh * kThreshMult, solver, rng, &m_init);

    double s = std::numeric_limits<double>::max();
    ScoreModel(solver, m_init, kSqInThresh, &s);
    UpdateBestModel(s, m_init, score, model);

    const std::vector<int>& inliers_base = base_indices;   // caller override
    // Guard (mask path only): a base set smaller than the non-minimal floor
    // cannot be sampled (RandomShuffleAndResize would zero-pad).
    if (static_cast<int>(inliers_base.size()) < kMinNonMinSampleSize) return;
    const int kNonMinSampleSize =
        std::max(kMinNonMinSampleSize,
                 std::min(kMinSampleSize * opt.non_min_sample_multiplier_,
                          static_cast<int>(inliers_base.size()) / 2));

    std::vector<int> sample;
    for (int r = 0; r < opt.num_lo_steps_; ++r) {
      sample = inliers_base;
      ransac_lib::utils::RandomShuffleAndResize(kNonMinSampleSize, rng, &sample);

      Eigen::Matrix3d m_non_min;
      if (!solver.NonMinimalSolver(sample, &m_non_min)) continue;

      ScoreModel(solver, m_non_min, kSqInThresh, &s);
      UpdateBestModel(s, m_non_min, score, model);

      LeastSquaresFit(opt, kSqInThresh, solver, rng, &m_non_min);

      double thresh = kThreshMult * kSqInThresh;
      const double thresh_mult_update =
          (kThreshMult - 1.0) * kSqInThresh /
          static_cast<int>(opt.num_lsq_iterations_ - 1);
      for (int i = 0; i < opt.num_lsq_iterations_; ++i) {
        LeastSquaresFit(opt, thresh, solver, rng, &m_non_min);
        ScoreModel(solver, m_non_min, kSqInThresh, &s);
        UpdateBestModel(s, m_non_min, score, model);
        thresh -= thresh_mult_update;
      }
    }
  }

  // ILSQ-only (Alg. 3): the ladder block of LocalOptimization applied to the
  // caller's seed — one LeastSquaresFit at the inlier threshold, then
  // num_lsq_iterations_ fits while the squared threshold decreases
  // arithmetically from threshold_multiplier_ * theta^2 to theta^2.
  void RunIterLSQ(const ransac_lib::LORansacOptions& opt,
                  const TwoViewLOSolver& solver, std::mt19937* rng,
                  Eigen::Matrix3d* model, double* score) const {
    const double kSqInThresh = opt.squared_inlier_threshold_;
    *score = std::numeric_limits<double>::max();
    ScoreModel(solver, *model, kSqInThresh, score);

    Eigen::Matrix3d m = *model;
    LeastSquaresFit(opt, kSqInThresh, solver, rng, &m);

    double s = std::numeric_limits<double>::max();
    double thresh = opt.threshold_multiplier_ * kSqInThresh;
    const double thresh_mult_update =
        (opt.threshold_multiplier_ - 1.0) * kSqInThresh /
        static_cast<int>(opt.num_lsq_iterations_ - 1);
    for (int i = 0; i < opt.num_lsq_iterations_; ++i) {
      LeastSquaresFit(opt, thresh, solver, rng, &m);
      ScoreModel(solver, m, kSqInThresh, &s);
      UpdateBestModel(s, m, score, model);
      thresh -= thresh_mult_update;
    }
  }
};

}  // namespace

// ---------------------------------------------------------------------------
// SHIM NAMING CONVENTION (shared with PoseLib.jl's julia_wrapper.cpp):
//   C symbols:  <lib>_<upstream free-function name> when upstream has one;
//               <lib>_<algorithm name> when the entry composes upstream
//               internals with no free function of their own — RansacLib's
//               LO is a protected class method, hence ransaclib_lebeda_lo /
//               ransaclib_lebeda_iterlo.
//   Julia API:  algorithm names for algorithm drivers (lebeda_lo,
//               lebeda_iterlo); task verbs refine_<model> live in PoseLib.jl.
// ---------------------------------------------------------------------------
extern "C" {

// Seeded RansacLib LO-MSAC on a two-view model (E / F / H).
//
//   pts                  4 x n column-major (x1, y1, x2, y2), z = 1 implied;
//                        the frame defines the threshold currency.
//   seed_E / out_E       3 x 3 column-major.
//   squared_threshold    theta^2, the terminal (MSAC) inlier threshold on the
//                        SQUARED Sampson distance.
//   threshold_multiplier multiplies the SQUARED threshold (RansacLib
//                        convention; its own default is sqrt(2)).
//   base_mask            OPTIONAL (nullable) length-n 0/1 mask: caller-supplied
//                        base inlier set for the non-minimal sampling stage
//                        (diagnostic/pipeline override). NULL = the published
//                        behavior — the base set is derived internally by
//                        gating against the current model at the enlarged
//                        threshold. Ignored for variant = 1 (the ILSQ ladder
//                        re-derives its consensus per rung by design).
//   model_kind           0 = essential, 1 = fundamental, 2 = homography.
//   variant              0 = full LO (Alg. 2+3), 1 = ILSQ-only (Alg. 3).
//   out_score            MSAC score (sum of min(r^2, theta^2)) of out_E.
//   out_num_updates      linear solves performed (model updates; counted in
//                        OUR solver class callbacks).
//   out_lo_ns            wall-clock nanoseconds spent inside the RansacLib LO
//                        invocation itself (steady_clock; excludes shim
//                        argument marshalling) — the lo_ns half of the
//                        caller's lo_ns/lo_calls timing accounting.
//
// Returns 0 on success, < 0 on invalid arguments. out_E is always a valid
// model: the seed if no candidate improved on it.
int ransaclib_lebeda_lo(const double* pts, int32_t n, const double* seed_E,
                        double squared_threshold, int32_t num_lo_trials,
                        double threshold_multiplier, int32_t num_lsq_iterations,
                        int32_t min_sample_multiplicator,
                        int32_t non_min_sample_multiplier, uint32_t rng_seed,
                        const uint8_t* base_mask, int32_t model_kind,
                        int32_t variant, double* out_E, double* out_score,
                        int64_t* out_num_updates, int64_t* out_lo_ns) {
  if (pts == nullptr || seed_E == nullptr || out_E == nullptr) return -1;
  if (n < 8) return -2;
  if (!(squared_threshold > 0.0)) return -3;
  if (num_lsq_iterations < 2) return -4;  // RansacLib's decrement divides by (iters - 1)
  if (num_lo_trials < 0 || threshold_multiplier < 1.0) return -5;
  if (min_sample_multiplicator < 1 || non_min_sample_multiplier < 1) return -6;
  if (variant != 0 && variant != 1) return -7;
  if (model_kind < 0 || model_kind > 2) return -8;

  ransac_lib::LORansacOptions opt;
  opt.squared_inlier_threshold_ = squared_threshold;
  opt.num_lo_steps_ = num_lo_trials;
  opt.threshold_multiplier_ = threshold_multiplier;
  opt.num_lsq_iterations_ = num_lsq_iterations;
  opt.min_sample_multiplicator_ = min_sample_multiplicator;
  opt.non_min_sample_multiplier_ = non_min_sample_multiplier;
  opt.random_seed_ = rng_seed;

  TwoViewLOSolver solver(pts, n, static_cast<ModelKind>(model_kind));
  std::mt19937 rng;
  rng.seed(rng_seed);

  Eigen::Matrix3d E = Eigen::Map<const Eigen::Matrix3d>(seed_E);
  double score = std::numeric_limits<double>::max();

  std::vector<int> base_indices;
  if (variant == 0 && base_mask != nullptr) {
    base_indices.reserve(n);
    for (int32_t i = 0; i < n; ++i) {
      if (base_mask[i] != 0) base_indices.push_back(i);
    }
  }

  ExposedLO lo;
  const auto t0 = std::chrono::steady_clock::now();   // LO time only (no marshalling)
  if (variant == 0) {
    if (base_mask == nullptr) {
      lo.RunFullLO(opt, solver, &rng, &E, &score);          // published Alg. 2+3
    } else {
      lo.RunFullLOWithBase(opt, solver, &rng, base_indices, &E, &score);
    }
  } else {
    lo.RunIterLSQ(opt, solver, &rng, &E, &score);
  }
  const auto t1 = std::chrono::steady_clock::now();

  Eigen::Map<Eigen::Matrix3d> out_map(out_E);
  out_map = E;
  if (out_score != nullptr) *out_score = score;
  if (out_num_updates != nullptr) *out_num_updates = solver.num_model_updates();
  if (out_lo_ns != nullptr)
    *out_lo_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
  return 0;
}

}  // extern "C"
