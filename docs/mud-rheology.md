# Mud behavior and the surface model

The target is concentrated, clay-rich mud on a rigid 5 x 5 metre concrete slab. Mud composition varies; a single viscosity or softness slider cannot represent every sample.

## Research

- [Ran et al., Understanding the rheology of kaolinite clay suspensions using Bayesian inference (2022)](https://arxiv.org/abs/2208.13846): laboratory flow curves show yield stress and hysteresis. More dilute kaolinite suspensions display stronger viscoelasticity; concentrated suspensions become predominantly inelastic and thixotropic. This supports avoiding a strongly elastic support spring for this demo's dense clay target. It does not imply that every natural mud has zero elasticity.
- [Spearman, An examination of the rheology of flocculated clay suspensions (2017)](https://eprints.hrwallingford.com/id/eprint/1257/): fluid mud resistance depends on concentration and evolving particle structure; a static viscosity alone does not capture the time-dependent behavior.
- [Mudflow rheology: A review and analysis for Earth and planetary science disciplines (2025)](https://doi.org/10.1016/j.earscirev.2025.105226): compares rheological fits and highlights the sensitivity of predicted motion to yield stress. This informed the choice of a Herschel-Bulkley-inspired flow relation; its fitted coefficients are not copied into this scene.

Mud is already a particulate suspension containing water. Free water pools, absorbed pore water, and suspended clay are useful compartments; they are not two immiscible liquids. Mixing, settling and moisture redistribution depend on disturbance and local concentration.

## Implementation decisions

`src/mud.cu` now stores an advected structure fraction lambda, initially one. Contact/brush shear reduces it; resting structure recovers. Permanent kneading/pigment mixing is stored separately so strength recovery does not undo texture mixing.

Each face computes a shallow-layer driving stress using rho*g*depth*headGradient. Below the moisture- and structure-dependent yield stress, pressure-driven soil flux is zero. Above yield, a shear-thinning relation estimates flow. A face transfer cap prevents explicit nonlinear diffusion from alternating high and low cells. Donor limiting conserves transferred solid volume.

Contact pressure comes from the collider's lower spherical surface or flat block underside. Intrusion pushes mud toward the footprint rim. Vertical support uses overdamped penetration rather than an elastic height spring. Free-falling objects remain gravitational until contact. This avoids storing artificial rebound energy in the support model.

UV gradients transform generated texture-height gradients into surface normals. Pigment and painted tangent-normal edits travel with the solid flux. Diagnostics display raw values without material lighting, which otherwise washed out the normal view.

## Limits and validation

This is a depth-integrated artistic approximation, not a calibrated soil mechanics or volumetric multiphase solver. The density, yield law, consistency, shear exponent and recovery time are chosen for the interactive scene. The model omits pore-pressure consolidation, tensile suction during vertical extraction, actual granular contacts, undercuts, strings and splashes. The pointer currently drags objects across the surface; it does not lift them vertically out of mud.

Browser tests cover volume conservation across the water/solid compartments, resting versus churned wet patches, structural breakdown/recovery, thick-layer stationary rebound, permanent tracks, concrete residue, and actual pointer UV/normal editing while paused. Those tests establish the implemented behavior and numerical checks; they do not validate material coefficients against a physical mud sample.
