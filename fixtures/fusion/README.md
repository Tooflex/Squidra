# FUSION-024: rectified camera / LiDAR fixture

This is authored test data, not a recording or calibration of a physical sensor.
`rectified-rig.v1.json` supplies a fixed RGB image, four noncoplanar calibration
correspondences and four distinct held-out noisy LiDAR samples with known metric
positions and expected image pixels. No provider or sensor is contacted.

## Contracts

`FusionCalibration` accepts rigid transforms in metres, with explicit source and
destination coordinate-frame UUIDs: LiDAR → camera → map. Rotations are row-major
3×3, right-handed, orthonormal with determinant +1 (numerical tolerance 1e-9).
Translation is applied after rotation. Reflections, scale, bad chains, nonfinite
values and inconsistent known correspondences are rejected. Calibration requires
4–64 checks with noncoplanar LiDAR support (a scalar triple product above
1e-9 m³ is the numerical support floor for this bounded profile). It measures maximum coordinate and
pixel residuals against the supplied references and rejects tolerances greater
than the declared error budgets. It checks consistency, not sensor truth.

The camera is a rectified pinhole image, +X right, +Y down, +Z forward, integer
pixel centres, positive focal lengths, no skew or lens distortion. Intrinsics
belong to the exact image dimensions. Inputs are packed RGB8, at most 1024×1024;
resizing requires a new matching calibration. Projection uses
`u=fx*X/Z+cx`, `v=fy*Y/Z+cy`, following the
[OpenCV pinhole model](https://docs.opencv.org/doc/doxygen/html/d4/d93/group__calib.html).
Rectification and calibration estimation are upstream responsibilities. No 2D
mask is converted into depth.

Capture UUIDs are separate from coordinate-frame UUIDs. Actor and coordinate
frames must match the rig; map output retains all three coordinate frames, both
capture IDs and calibration identity/version. Each LiDAR point has a unique ID
and a validated `UTCInstant` observation timestamp. Exported timestamps follow
the existing six-fractional-digit RFC3339 UTC profile, with `Etc/UTC` provenance. Camera time and every point must
fall within the calibration's half-open validity interval. The host declares a
maximum timestamp skew (0–1 s) and scene-speed bound (0–1000 m/s). Each point's
actual skew is checked, retained in the aggregate report, and contributes
`speed × skew` to coordinate uncertainty. This assumes a static calibrated rig
within its validity window; it is not scan deskew or moving-platform pose fusion.

There are 1–100,000 points per capture. Coordinates are finite within ±1,000,000 m;
calibrated input range is at most 1000 m and includes input uncertainty for both
LiDAR and camera coordinates. Invalid input rejects the whole capture, with no
partial map. Cancellation and deadline checks bound the linear fusion/visibility
passes. There is no database write, HTTP activation, ROS2, SLAM or actuator path.

## Metric and color uncertainty

Measurement and transform errors are conservative coordinate-wise bounds, not
standard deviations or probabilities. For each transform, the maximum absolute
row sum of its rotation propagates the incoming bound, then the declared
transform error and a 1 nm arithmetic allowance are added. The host's transform
error must cover parameter/calibration uncertainty over the stated range.
The scene-speed/skew allowance is added in camera coordinates before propagation
to the map. Output metric points remain at their own LiDAR observation time.

Projected interval corners plus intrinsic pixel error must fit strictly inside
one nearest-pixel cell before color is assigned. A z-buffer over supplied samples
rejects farther points; overlapping depth intervals leave color ambiguous.
Behind-camera and out-of-view points remain metric points with no color. If any
projection has an uncertain image footprint, this implementation conservatively
withholds all otherwise-fused colors for that capture; it does not silently
ignore a possible occluder. This limitation avoids quadratic footprint matching.
Unseen camera occluders, transparent surfaces and incomplete point coverage are
not certified by this sample-based visibility check. A metric point map is not
an occupancy/free-space guarantee or complete scene reconstruction.

## Fixture and measurements

The independent reference transforms are:

- LiDAR → camera: `(X,Y,Z)=(-y+0.2, x-0.1, z+0.3)`.
- Camera → map: `(X,Y,Z)=(z+10, y+20, -x+30)`.
- Intrinsics: `fx=fy=8`, `cx=cy=3.5`, 8×8 RGB.

Held-out coordinates have authored millimetre perturbations; expected map
positions are the unperturbed references. Tests measure Euclidean RMSE and
maximum error, count coordinate-wise uncertainty coverage and correct colors,
and export actual processing latency. Calibration checks and held-out samples
are distinct. Declared measurement error is 4 mm per coordinate, each transform
adds 1 mm, skew is 2 ms and the host's scene-speed bound is 1 m/s.

Run `bash Scripts/test-issue.sh SQD-024`. It exports `.build/fusion/report.json`
and `.build/fusion/metric-map.json`. Timing uses `ContinuousClock`, includes
fusion and visibility only, excludes fixture parsing/rectification/encoding,
and is a single debug-build sample on four points, not a throughput benchmark.
No SRS latency or accuracy threshold is invented. The committed dated
`measurement-macos.v1.json` is one actual run; reruns may have different timings.
The gate also rejects bad calibration, wrong frames/actors, stale/skewed times,
image mismatch, duplicate points and invalid numeric data, and exercises
occlusion, ambiguous depth, projection uncertainty and cancellation. SQD-022
regressions separately retain calibrated qualitative relation behavior.

The default server remains unchanged. Rollback removes this pure library
component and its local gate; no persisted state or schema migration exists.
