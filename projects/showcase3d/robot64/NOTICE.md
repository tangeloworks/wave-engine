# Robot 64 scene

This folder holds the Robot 64 Engine scene for Showcase 3D: a sandbox built
on the good edition of the Robot 64 Engine place, running on wave-engine's
RBX renderer and physics.

## Credits

- **Robot 64** and the **Robot 64 Engine** place are by zKevin. This includes
  the place file (`assets/Robot-64-Engine-good-edition.rbxl`) and its meshes,
  textures, sounds, user interface and character rig.
- The material, stud surface and built-in mesh files under `assets/rbx/` are
  Roblox's.
- The Lua modules here are ported from Robot 64's scripts:
  - adapted with local compatibility fixes: `ball_controller.lua`,
    `character_animation.lua`, `player_environment.lua`,
    `moving_geometry.lua`, `equipment.lua`, `content.lua`, `public_rig.lua`,
    `ray_filter.lua`, `source_ray.lua`, `source_regions.lua`,
    `gravity_policy.lua`, `beam_geometry.lua`, `prompts.lua`
    (source_prompts.lua);
  - `dialogue.lua`: the port's dialogue.lua with this place's own INT table
    (the Good edition's CharacterScript `totext`) in place of the public
    game's;
  - copied with small host changes (an interpolated body pose, no research
    catalogue, the place's own rig only): `character.lua`,
    `character_visual.lua`, `follow_camera.lua`, `equipment_visual.lua`,
    `source_presentation.lua`, `source.lua`, `source_effects.lua`;
  - reduced ports of the port's modules to what this sandbox uses:
    `sandbox_rules.lua` (gameplay.lua, encounters.lua), `carrying.lua`,
    `transitions.lua` (cinematics.lua), `audio.lua` (source_audio.lua),
    `hud.lua` (source_hud.lua, equipment_hud.lua, the iris),
    `cosmetics.lua` (cosmetics.lua's per-frame rig visibility),
    `dialogue_view.lua` (dialogue_view.lua, drawn from the scene overlay),
    `session.lua`, and the wiring in `init.lua` (application.lua).
- `assets.lua` is this repository's own small asset lookup.

Texture `17819077905` uses Roblox's public 420 × 420 preview as a local
fallback. The original download requires authentication and was not found
in the local asset folders or Roblox cache. This is a resized preview, not
the original texture.

Source: https://tr.rbxcdn.com/180DAY-d2868ef6176577ff0a8f2b82acd64ab2/420/420/Image/Png/noFilter
