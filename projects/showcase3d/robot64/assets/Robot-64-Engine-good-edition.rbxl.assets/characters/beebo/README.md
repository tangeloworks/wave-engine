# Beebo local character assets

This map-owned directory contains eight meshes and six PNG textures collected from the
legacy shared asset pool (original paths are recorded in the manifest). No network fetch is needed to construct or
animate the playable character. `character_rig.lua` references these local paths
explicitly. Keep this directory with the demo when moving the project.

`manifest.json` records each original asset ID, source path, size and SHA-256.
The body/battery sources had `.mesh` filenames but contain PNG bytes; the copies
use `.png` without converting or changing the image. Shared limb meshes remain
shared. The template smile is retained alongside the three animated face states.

The collision sphere and antenna stem are procedural. No runtime read of the
Robot 64 map or a user cache is needed for this character.

Original Robot 64 assets are by zKevin.
