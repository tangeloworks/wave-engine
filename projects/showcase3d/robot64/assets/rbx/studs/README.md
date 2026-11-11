# Generated surface textures

The RBX renderer shares these textures across maps and runtime-created parts.
Each surface folder (`studs`, `inlets`, `weld`, `universal`) contains `2x2` and
`4x4` tile variants, each with:

- `diffuse.png`: ambient-occlusion color texture.
- `normal-plastic.png`: normal map for plastic materials.
- `normal-smooth.png`: normal map for other materials.

All 24 PNGs are selected dynamically by
`engine/graphics/rbx/runtime/render.lua`. Glue surfaces use `weld` textures.
Keep both sizes and normal variants even when a particular map does not use
them: part size, material, and surface types can change at runtime. A custom
`asset_folders.studs` directory must use this same layout.

The Blender source files, normal-combining helper, raw material source texture,
and macOS metadata are unused authoring leftovers; the runtime does not load them.
The existing Roblox-HD-Studs attribution remains in `credits.lua`; the original
raw material documentation credited AmbientCG.
