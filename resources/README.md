# Image assets

## App icon

`icon.png` is the maintainer-supplied master image for SmallGit's app icon.
It is distributed with the project under the [MIT license](../LICENSE).
The master retains its embedded provenance metadata.

Run `SmallGit/scripts/generate-icon.sh` from the repository root to regenerate
`SmallGit/Resources/AppIcon.icns`. The script uses macOS `sips` and `iconutil`
and accepts the master image's encoding independently of its filename extension.

## README potato

[`small-potato.png`](small-potato.png) is the transparent potato image created
for the "SmallGit, Small Potato" README introduction. It was generated at the
maintainer's request using the built-in ImageGen tool and copied into this
directory with its alpha channel preserved. It is a documentation asset, separate
from the app icon.

Generation prompt:

```text
Use case: product-mockup
Asset type: SmallGit open-source README header illustration
Primary request: One small ordinary potato, an understated playful visual for the slogan 'SmallGit, Small Potato'.
Subject: A single whole brown potato with a gently irregular oval shape, authentic small eyes and subtle earthy skin texture.
Style/medium: Realistic studio product photograph, simple and warm, softly lit, natural proportions.
Composition/framing: Square image; potato centered, angled slightly diagonally, entire object visible, occupies about 70% of the frame with generous clear padding.
Scene/backdrop: Truly transparent background with alpha; no floor or scene, clean cutout edges that work on light and dark GitHub themes.
Constraints: Exactly one potato. No text, lettering, logo, watermark, face, limbs, sprouts, props or extra objects.
```
