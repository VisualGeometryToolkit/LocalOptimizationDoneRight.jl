# Renders docs/src/assets/landing/hero_manifold.png (the landing hero), then crop to the
# non-transparent extent. Needs matplotlib + numpy (e.g. a pixi env); not part of the build.
"""Hero image: a curved model manifold with noisy correspondences around it.

Points near the surface (inliers) are drawn strong, coloured by their robust
weight; gross outliers are faint. Transparent background for light/dark themes.
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap, LightSource

rng = np.random.default_rng(7)

def surf(u, v):
    # a gently curved sheet (saddle + ripple)
    return 0.35 * (u**2 - v**2) + 0.12 * np.sin(2.2 * u) * np.cos(1.6 * v)

def normal(u, v, h=1e-4):
    zu = (surf(u + h, v) - surf(u - h, v)) / (2 * h)
    zv = (surf(u, v + h) - surf(u, v - h)) / (2 * h)
    n = np.stack([-zu, -zv, np.ones_like(u)], axis=-1)
    return n / np.linalg.norm(n, axis=-1, keepdims=True)

# surface mesh
U, V = np.meshgrid(np.linspace(-1.6, 1.6, 120), np.linspace(-1.6, 1.6, 120))
Z = surf(U, V)

# inliers: on the surface, displaced along the normal by Student-t-ish noise
n_in = 420
u = rng.uniform(-1.5, 1.5, n_in); v = rng.uniform(-1.5, 1.5, n_in)
d = 0.045 * rng.standard_t(4, n_in)
p_in = np.stack([u, v, surf(u, v)], -1) + d[:, None] * normal(u, v)

# outliers: scattered through the volume
n_out = 110
p_out = np.stack([rng.uniform(-1.7, 1.7, n_out), rng.uniform(-1.7, 1.7, n_out),
                  rng.uniform(-1.1, 1.3, n_out)], -1)
r_out = np.abs(p_out[:, 2] - surf(p_out[:, 0], p_out[:, 1]))

# robust weight (Welsch-like) from the residual along z
s = 0.07
w_in = np.exp(-(d / s) ** 2 / 2)
w_out = np.exp(-(r_out / s) ** 2 / 2)

surface_cmap = LinearSegmentedColormap.from_list("sheet", ["#2b5d7d", "#5f9bb8", "#cfe3ec"])
point_cmap = LinearSegmentedColormap.from_list("w", ["#9aa4ad", "#e07a2f", "#c2410c"])

fig = plt.figure(figsize=(9, 7.2), dpi=160)
ax = fig.add_subplot(111, projection="3d", computed_zorder=False)
fig.patch.set_alpha(0); ax.set_facecolor((0, 0, 0, 0))

ls = LightSource(azdeg=225, altdeg=40)
rgb = ls.shade(Z, cmap=surface_cmap, vert_exag=1.2, blend_mode="soft")
ax.plot_surface(U, V, Z, facecolors=rgb, rstride=1, cstride=1, linewidth=0,
                antialiased=True, alpha=0.78, shade=False, zorder=1)
# a few iso-lines for the manifold feel
for c in np.linspace(-1.6, 1.6, 9):
    ax.plot(np.full(120, c), np.linspace(-1.6, 1.6, 120), surf(np.full(120, c), np.linspace(-1.6, 1.6, 120)),
            color="#1f3f55", lw=0.5, alpha=0.35, zorder=2)
    ax.plot(np.linspace(-1.6, 1.6, 120), np.full(120, c), surf(np.linspace(-1.6, 1.6, 120), np.full(120, c)),
            color="#1f3f55", lw=0.5, alpha=0.35, zorder=2)

above = p_in[:, 2] >= surf(p_in[:, 0], p_in[:, 1])
for mask, z in ((~above, 0), (above, 3)):
    ax.scatter(*p_in[mask].T, c=w_in[mask], cmap=point_cmap, vmin=0, vmax=1,
               s=10 + 14 * w_in[mask], edgecolors="none", alpha=0.95, depthshade=False, zorder=z)
ax.scatter(*p_out.T, c=w_out, cmap=point_cmap, vmin=0, vmax=1, s=9,
           edgecolors="none", alpha=0.55, depthshade=False, zorder=4)

ax.view_init(elev=24, azim=-58)
ax.set_box_aspect((1, 1, 0.62))
ax.set_axis_off()
ax.set_xlim(-1.7, 1.7); ax.set_ylim(-1.7, 1.7); ax.set_zlim(-1.1, 1.2)
plt.subplots_adjust(0, 0, 1, 1)
fig.savefig("hero_manifold.png", transparent=True, bbox_inches="tight", pad_inches=0.0)
