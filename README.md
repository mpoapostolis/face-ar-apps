# Face AR apps

Two native iOS apps (Swift, ARKit, Metal) that run on an iPhone with Face ID.

## Glow AR — makeup try-on

Lipstick, eyeshadow, eyeliner, blush, skin finish and a brow-shaping guide on the live camera, with recommendations for what suits the face in front of it.

- ARKit face tracking (TrueDepth), regions found from the face-mesh topology (eye and mouth openings).
- Lip outline learned per person with Vision and painted into the mesh's UV space, so it fits the real lips and follows every expression with no lag.
- Pigment model: makeup is lit by the real light on the skin (shading, colour cast, texture); shine is kept separate, so matte, satin and gloss look different.
- **Skin:** smoothing by frequency bands (blemishes, blotches and fine lines are taken out; pores and real skin texture stay; brows, lids and the edge of the face stay sharp), even tone (pulls local redness towards the person's own average skin colour), highlighter (cheekbones, bridge of the nose, cupid's bow) and contour (under the cheekbones, sides of the nose).
- **What suits you:** measures the face shape and the eyes on the 3D mesh (against ARKit's average face), and reads the contrast between brows and skin and the skin undertone from the camera (the undertone can also be set by hand). From these it ranks every shade (stars on the swatches), places the blush for the face shape, builds a day look and a night look, and explains why.
- **Looks:** complete looks with one tap; the ones that suit the measured face are starred.
- **Brows:** the three classic lines (start, arch, end) through the person's own nose sides and pupils, the zone between the brows to clean, and single stray hairs around the brow. The hair detector sets its thresholds from the person's own clean skin in the current light.
- **Before / after:** a divider that is dragged across the picture.
- Photo of the result, saved to Photos.

## Groom AR — men's grooming guides

- **Beard:** trimming guides on the face for Stubble, Short, Full and Goatee (cheek line, neckline on a neck extension under the jaw), adjustable heights, step-by-step instructions, optional style preview.
- **Brows:** the three classic lines (start, arch, end) through the person's own nose sides and pupils (learned with Vision), the zone between the brows to clean, and single stray hairs around the brow (under it, over it, past its end).
- **Trim here:** hair left in the shave zones is highlighted live, with a clean/trim status per zone. The detector looks for hairs and stubble dots as thin dark valleys, so shadow edges and shading do not count, and it sets its thresholds from the person's own clean skin (a patch on the upper cheeks) in the current light.
- **Symmetry:** finds the real edge of the beard on each cheek and shows how many millimetres one side is higher than the other.
- **Suggestion:** measures the face proportions on the 3D mesh (length, jaw width against the average face) and suggests a beard style and line heights; one tap can also move the guide onto the person's real beard line.
- Guides are fields on the ARKit face mesh, so they stick to the skin and hide correctly when the head turns.
- Photo of the screen with the guides, saved to Photos.
- **Routine:** skin-care routine by skin type (morning, evening, weekly), beard care and shaving tips, with a daily checklist.

## Build and install (no App Store)

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), an Apple ID added in Xcode (free Personal Team works), iPhone with Developer Mode on.

```bash
cd GlowAR   # or GroomAR
xcodegen generate
./reinstall.sh
```

`reinstall.sh` builds and installs over the cable. It contains the team ID and device ID used here — change them for another Apple ID or iPhone.

With a free Personal Team the apps expire after 7 days; run `reinstall.sh` again. The first time, trust the developer on the iPhone: Settings → General → VPN & Device Management.
