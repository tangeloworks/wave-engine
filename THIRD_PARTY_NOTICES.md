# Third-party notices

wave-engine's own code is under the MIT license in [LICENSE](LICENSE). The
components below keep their own licenses. Full license texts are kept in the
files listed, either as a separate file or in the source header.

## Code

| Component | Author | License | Location |
| --- | --- | --- | --- |
| [CPML](https://github.com/excessive/cpml) | Colby Klein, Landon Manning and contributors | MIT, with CC0 parts | `engine/services/oss/cpml/LICENSE.md` |
| [Menori](https://github.com/rozenmad/Menori) | rozenmad | MIT | `engine/services/oss/menori/LICENSE.md` |
| [json.lua](https://github.com/rxi/json.lua) (inside Menori) | rxi | MIT | `engine/services/oss/menori/modules/libs/json.lua` |
| [love-gamepadguesser](https://github.com/idbrii/love-gamepadguesser) | idbrii | MIT | `engine/services/oss/gamepadguesser/init.lua` |
| [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) | Sam Lantinga and contributors | zlib | `engine/services/oss/gamepadguesser/db/LICENSE.txt` |
| [lbase64](https://github.com/iskolbin/lbase64) | Ilya Kolbin | MIT or Unlicense | `engine/services/oss/base64.lua` |
| [bitser](https://github.com/gvx/bitser) | Jasmijn Wellner | ISC | `engine/services/oss/bitser.lua` |
| [sock.lua](https://github.com/camchenry/sock.lua) | Cameron McHenry | MIT | `engine/services/oss/sock.lua` |
| [tween.lua](https://github.com/kikito/tween.lua) | Enrique García Cota, Yuichi Tateno, Emmanuel Oga | MIT | `engine/services/oss/tween.lua`, `engine/services/oss/splashy/tween.lua` |
| [splashy](https://github.com/videah/splashy) | Ruairidh Carmichael | MIT | `engine/services/oss/splashy/init.lua` |
| [fzstd](https://github.com/101arrowz/fzstd) (ported entropy decoding) | Arjun Barrett | MIT | `engine/graphics/rbx/zstd.lua` |

## Fonts

| Font | Author | License | Location |
| --- | --- | --- | --- |
| Poppins | The Poppins Project Authors | SIL Open Font License 1.1 | `engine/assets/fonts/POPPINS-LICENSE.txt` |
| Noto Sans Arabic | The Noto Project Authors | SIL Open Font License 1.1 | `engine/assets/fonts/NOTO-ARABIC-LICENSE.txt` |
| Scrambled Eggs Bold | VEXED | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | `projects/showcase2d/assets/fonts/Scrambled_Eggs_Bold.ttf` |

## Images

| Asset | Author | License | Location |
| --- | --- | --- | --- |
| [Input Prompts](https://kenney.nl/assets/input-prompts) | Kenney | CC0 1.0 | `engine/assets/img/inputsprites/` |

## Showcase 3D

| Content | Author | Location |
| --- | --- | --- |
| Robot 64 and the Robot 64 Engine place, its meshes, textures, sounds, interface and character rig; Lua ported from its scripts | zKevin | `projects/showcase3d/robot64/` |
| Material, stud surface and built-in mesh textures | Roblox | `projects/showcase3d/robot64/assets/rbx/` |

See [projects/showcase3d/robot64/NOTICE.md](projects/showcase3d/robot64/NOTICE.md).

LÖVE and LuaJIT are not included in this repository. When you distribute a
fused executable, include LÖVE's `license.txt` as well.
