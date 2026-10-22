# Per-eye FOV: up and down swapped in the visionOS client (W32)

**Conclusion: the swap is in our client.** On visionOS 2+, the CompositorServices renderer sent the bottom tangent as
`Fov.up` and the top tangent as `Fov.down`. The server fork and OpenVR pass the values through correctly, and R.E.A.L.
prints what it receives. Fixed in `ViewLayout.fovAngles` (bugfix/fov-updown), with a unit test and a `DIAG fov_sent` line.

## Chain of evidence (left eye, device values)

| # | Link | Code | Values (top / bottom) |
|---|------|------|-----------------------|
| 1 | CompositorServices projection | `computeProjection(convention: .rightUpBack, viewIndex:)`. The default convention is +Y up (SDK `CompositorServices.swiftinterface:228`, `drawable.h:484-489`) | true frustum: 45° up, 50° down |
| 2 | Tangent extraction | `ALVRClient/Extensions/RealityKit.swift:89-92`: `top = (1+m12)/m11`, `bottom = (-1+m12)/m11`, returned as `(left, right, bottom, top)`. In a +Y-up projection, `(1+m12)/m11` is the top edge | `.z` = bottom 1.1918, `.w` = top 1.0 |
| 3 | DIAG names | `CornerTangents(simd:)` reads `.z` as bottom and `.w` as top (`Diagnostics/CornerChart.swift:50-58`) | DIAG `tan_bottom=1.1918 tan_top=1.0000`, `axis_y=2291.8` of 5023 (eye axis above the viewport centre) |
| 4 | **Packing (the flip)** | `Renderer.swift:962` (before the fix): `AlvrFov(..., up: leftAngles.z, down: -leftAngles.w)` | **up = atan 1.1918 = +50.0°, down = −45.0°** |
| 5 | Canting circumscription | `RealityKit.swift:152-158` multiplies all four **angles** by `fov_inscribe_scale` (≥ 1) | L ×1.0118, R ×1.0205 |
| 6 | Client → server | `EventHandler.viewFovs` → `AlvrViewParams(fov:)` → `alvr_send_view_params` (`WorldTracker.swift:3474-3477`) | Fov in radians: up +0.883, down −0.802 |
| 7 | ALVR Fov convention | `alvr/common/src/primitives.rs:5-12`: radians, up positive, down negative. Our own default `EventHandler.swift:151` has `up: 0.785 (45°), down: -0.873 (50°)`, the correct device values | — |
| 8 | Server → OpenVR | `server_openvr/cpp/alvr_server/HMD.cpp:24-31,357-364`: `pfTop = tan(fov.down)` (negative), `pfBottom = tan(fov.up)` (positive) | pfTop −1.019, pfBottom +1.217 |
| 9 | OpenVR meaning | The `ComposeProjection` maths (`m11 = 2/(b−t)`, `m12 = (b+t)/(b−t)`) puts `pfBottom` at NDC +1 (up) and `pfTop` (negative) at the downward edge. Valve's Unity sample agrees: `vMin = 0.5 − 0.5·bottom/tanHalf` (`vr-gaming/alvr-visionos/ALVR/openvr/samples/unity_keyboard_sample/Assets/SteamVR/Scripts/SteamVR.cs:293-296`). ALVR upstream uses the same mapping. | the game's frustum is 50.6° up, 45.5° down |
| 10 | R.E.A.L. | prints `U = pfBottom`, `D = −pfTop` | **L U1.217 D1.019 L1.782 R1.019** |

**The 2–5 % margin.** Step 5 scales the angles once per eye, and that one factor reproduces all four logged values:

- **Left eye**, s = 1.0118: tan(50·s) = 1.217, tan(45·s) = 1.019, tan(60·s) = 1.782.
- **Right eye**, s = 1.0205: tan(50·s) = 1.236, tan(45·s) = 1.033, tan(60·s) = 1.821.

So the margin is the canted-view circumscription and is separate from the swap.

**Contradiction check.** Suppose R.E.A.L. labelled `U = −pfTop`. It would then print U1.019, but it prints U1.217. Steps 2–4
follow from the code and the SDK alone, and they predict exactly the R.E.A.L. numbers. W28's reading is confirmed.

**Why the image still looked right.** The Metal path draws the video quad from the same swapped Fov
(`tangentsCorrected` → `Shaders.metal:211-216`). The stream is therefore geometrically consistent, but it covers about 5°
above the display's top edge (wasted) and leaves about 5° at the bottom of the display uncovered.

## Fix

- `ViewLayout.fovAngles(tangents:scale:)` now packs `up = atan(.w)` and `down = −atan(.z)`. `Renderer.swift` uses it.
- With Diagnostics on, each view-config send logs one line per eye, after canting correction:
  `DIAG fov_sent eye=L up=.. down=.. left=.. right=.. units=deg`. The values are in degrees with ALVR's signs (left and
  down are negative). The line is not built when Diagnostics is off.
- The test is `tests/swift/FovPackingTests.swift`. It uses the device tangents (1.7321, 1.0, 1.1918, 1.0) and expects up
  45.00° and down −50.00°. It failed 8 of 17 checks on the old mapping (up 50.00, down −45.00).
- After the fix, the expected device output is L up 45.53, down −50.59 and R up 45.92, down −51.02. R.E.A.L. should then
  print L U1.019 D1.217.

## Consequences

- **Foveation centre.** The stream's eye axis was about 5.5° *below* the texture centre (frustum 50.6° up, 45.5° down). It
  is now 5.5° *above* the centre (tan offset (1.1918 − 1.0)/2 = 0.096) and 20.1° nasal. Any `center_shift_y` tuned
  against the old stream must change sign. `center_shift_x` (nasal) is unaffected. ALVR's sign convention for
  `center_shift_y` (FFR `Shaders.metal:153-157`, uv with the origin at top-left) is not verified here. Check it before
  setting a value.
- **Server and OpenVR:** no change needed.

## Not changed (open)

- **RealityKit renderer.** It runs the same swapped chain:
  - Fov packing at `RealityKitClientSystem.swift:1552`
  - plane offset `diffUD = .z − .w` at `RealityKitClientSystem.swift:1318`
  - projection `topTangent: realTangents[2]` at `Renderer.swift:696` (drawable nil)

  That chain is internally consistent, and fixing it needs all three changed together plus a device check. It is out of
  scope here.
- `WorldTracker.swift:2830-2882` labels `renderTangents.z` "top" and `.w` "bottom". Those labels are wrong on visionOS 2+
  and affect only the eye-tracking heuristics.
- The legacy `views[].tangents` branch is dead code. The app targets deploy at visionOS 2.0/2.1, so `#available(visionOS 2.0, *)`
  is always true.

## Proof on device

1. With Diagnostics on, start a stream. Expect `DIAG fov_sent eye=L up=45.53 down=-50.59`. R.E.A.L.'s log should then
   show L U1.019 D1.217.
2. One-frame overlay test: render a server-side frame with horizontal lines at ±45° and −50° from the eye axis (the
   pfTop/pfBottom edges). On the headset, the −50° line should sit on the bottom edge of the display and the +45° line
   on the top edge, with no black band at the bottom. Before the fix, the bottom ~5° was uncovered.
