---@class AudioTrack : Object
local AudioTrack = Object:extend()

function AudioTrack:init(name, source, filepath, source_type)
    self.name = name
    self.source = source
    self.filepath = filepath
    self.source_type = source_type or "static"
    self.pitch = 1
    self.is3d = false
    self.base_volume = 1
    self.playback_state = {
        is_playing = false,
        volume = 1,
        pitch = 1,
        position = 0,
        looping = false,
        relative = false,
        air_absorption = 0,
        rolloff = 1,
        velocity = { x = 0, y = 0, z = 0 },
        source_position = { x = 0, y = 0, z = 0 },
        direction = { x = 0, y = 0, z = 0 },
        spatial_settings = nil
    }
end

function AudioTrack:_apply_spatial_effects(spatial_settings, target_source)
    if not spatial_settings then return end

    local source_to_use = target_source or self.source
    if not source_to_use then return end

    local listener_x, listener_y, listener_z = audio:get_listener_position()

    local dx = spatial_settings.x - listener_x
    local dy = spatial_settings.y - listener_y
    local dz = spatial_settings.z - listener_z
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

    local max_distance = spatial_settings.max_distance or 50
    local ref_distance = spatial_settings.ref_distance or 1

    local spatial_volume = 1
    if distance > ref_distance then
        local normalized_distance = (distance - ref_distance) / (max_distance - ref_distance)
        normalized_distance = math.max(0, math.min(1, normalized_distance)) -- clamp to 0-1

        spatial_volume = math.pow(1 - normalized_distance, 2)
        spatial_volume = math.max(spatial_volume, 0.001)
    end

    local rolloff = spatial_settings.rolloff or 2
    spatial_volume = math.pow(spatial_volume, rolloff)

    local base_vol = spatial_settings.base_volume or self.base_volume

    local final_volume = base_vol * spatial_volume * self:_channel_volume()
    source_to_use:setVolume(final_volume)
end

-- a track's own volume is scaled by its channel (music/sfx) and the master
-- volume, so player volume settings apply to every sound
function AudioTrack:_channel_volume()
    local channel = self.channel
    return channel and channel.real_volume or 1
end

function AudioTrack:_capture_state()
    if not self.source then return end

    self.playback_state.is_playing = self.source:isPlaying()
    self.playback_state.volume = self.source:getVolume()
    self.playback_state.pitch = self.source:getPitch()
    self.playback_state.looping = self.source:isLooping()

    if self.source:getChannelCount() == 1 then
        self.playback_state.relative = self.source:isRelative()
        self.playback_state.air_absorption = self.source:getAirAbsorption()
        self.playback_state.rolloff = self.source:getRolloff()

        local x, y, z = self.source:getPosition()
        self.playback_state.source_position = { x = x, y = y, z = z }

        local vx, vy, vz = self.source:getVelocity()
        self.playback_state.velocity = { x = vx, y = vy, z = vz }

        local dx, dy, dz = self.source:getDirection()
        self.playback_state.direction = { x = dx, y = dy, z = dz }
    end

    if self.playback_state.is_playing then
        self.playback_state.position = self.source:tell()
    end
end

function AudioTrack:_restore_state(new_source)
    if not new_source then return end

    new_source:setVolume(self.playback_state.volume)
    new_source:setPitch(self.playback_state.pitch)
    new_source:setLooping(self.playback_state.looping)

    if new_source:getChannelCount() == 1 then
        new_source:setRelative(self.playback_state.relative)
        new_source:setAirAbsorption(self.playback_state.air_absorption)
        new_source:setRolloff(self.playback_state.rolloff)

        local pos = self.playback_state.source_position
        new_source:setPosition(pos.x, pos.y, pos.z)

        local vel = self.playback_state.velocity
        new_source:setVelocity(vel.x, vel.y, vel.z)

        local dir = self.playback_state.direction
        new_source:setDirection(dir.x, dir.y, dir.z)
    end

    if self.playback_state.position > 0 then
        new_source:seek(self.playback_state.position)
    end

    if self.playback_state.is_playing then
        new_source:play()
    end
end

function AudioTrack:recreate_source()
    if not self.filepath then
        print("[audio] no file path stored for " .. self.name)
        return false
    end

    self:_capture_state()

    -- build the replacement BEFORE touching self.source: every tier is pcall-
    -- guarded (love.audio.newSource can throw, e.g. on OpenAL source-pool
    -- exhaustion) and total failure must leave the track on its old, still-
    -- playable source rather than a released/dangling one
    local new_source
    -- prefer_mono tracks (positional 3D sfx) must stay mono across recreation
    -- regardless of the global mono toggle, or they lose OpenAL spatialization
    if self.prefer_mono then
        local ok, s = pcall(audio._newSourceDownmixed, audio, self.filepath)
        if ok then new_source = s end
    end
    if not new_source then
        local ok, s = pcall(audio._newSourceMonoAware, audio, self.filepath, self.source_type)
        if ok then new_source = s end
    end
    if not new_source then
        local success, created = pcall(love.audio.newSource, self.filepath, self.source_type)
        if success then new_source = created end
    end
    if not new_source then
        print("[audio] could not recreate source: " .. self.name)
        return false
    end

    if self.source then
        self.source:stop()
        self.source:release()
    end
    self.source = new_source

    self:_restore_state(new_source)

    return true
end

function AudioTrack:play(settings)
    settings = settings or {}
    if settings.clone then
        local s = self.source:clone()
        self:_apply_settings(s, settings)
        s:play()
        s:release()
    else
        self:_apply_settings(self.source, settings)
        self.source:play()
        self.playback_state.is_playing = true
    end
end

function AudioTrack:_apply_settings(src, settings)
    if settings.loop ~= nil then
        src:setLooping(settings.loop)
        self.playback_state.looping = settings.loop
    end

    if settings.pitch then
        src:setPitch(settings.pitch)
        self.playback_state.pitch = settings.pitch
    end

    local base_volume = settings.volume or self.base_volume
    if src == self.source then
        self.base_volume = base_volume
        self.playback_state.volume = base_volume * self:_channel_volume()
    end
    src:setVolume(base_volume * self:_channel_volume())

    local is_mono = src:getChannelCount() == 1

    -- a MONO source with NO position given is a UI/flat sound, but OpenAL
    -- spatializes every mono source: unless made listener-relative it sits at
    -- WORLD ORIGIN and distance-attenuates to silence the moment a game moves
    -- the listener (love.audio.setPosition). default it to relative so "play
    -- this sound" means "at the listener", not "at (0,0,0)"
    if is_mono and settings.position == nil and settings.relative == nil then
        src:setRelative(true)
        src:setPosition(0, 0, 0)
    end

    if settings.position then
        if is_mono then
            src:setPosition(settings.position.x or 0, settings.position.y or 0, settings.position.z or 0)
            src:setAttenuationDistances(settings.ref_distance or 1, settings.max_distance or 50)
            src:setRolloff(settings.rolloff or 1)
            self.playback_state.source_position = {
                x = settings.position.x or 0,
                y = settings.position.y or 0,
                z = settings.position.z or 0
            }
            self.is3d = true
        else
            local spatial_settings = {
                x = settings.position.x or 0,
                y = settings.position.y or 0,
                z = settings.position.z or 0,
                max_distance = settings.max_distance or 50,
                ref_distance = settings.ref_distance or 1,
                rolloff = settings.rolloff or 2,
                base_volume = base_volume
            }
            -- count nil->set transitions so set_listener_position (per frame)
            -- can skip its track scan entirely while no stereo track is spatial
            if self.playback_state.spatial_settings == nil then
                audio._stereo_spatial_count = (audio._stereo_spatial_count or 0) + 1
            end
            self.playback_state.spatial_settings = spatial_settings
            self:_apply_spatial_effects(spatial_settings, src)
            self.is3d = true
        end
    end

    if settings.relative ~= nil then
        if is_mono then
            src:setRelative(settings.relative)
            self.playback_state.relative = settings.relative
        else
            self.playback_state.relative = settings.relative
        end
    end
end

function AudioTrack:pause()
    self.source:pause()
    self.playback_state.is_playing = false
end

function AudioTrack:resume()
    self.source:play()
    self.playback_state.is_playing = true
end

function AudioTrack:stop()
    self.source:stop()
    self.playback_state.is_playing = false
    self.playback_state.position = 0
end

---set this track's own volume (0..1), channel and master volume still apply
function AudioTrack:set_volume(vol)
    self.base_volume = vol
    self:refresh_volume()
end

function AudioTrack:refresh_volume()
    local volume = self.base_volume * self:_channel_volume()
    self.source:setVolume(volume)
    self.playback_state.volume = volume
end

function AudioTrack:set_pitch(pitch)
    self.source:setPitch(pitch)
    self.playback_state.pitch = pitch
end

function AudioTrack:update_position(position)
    local is_mono = self.source:getChannelCount() == 1

    if is_mono then
        self.source:setPosition(position.x, position.y, position.z)
        self.playback_state.source_position = position
    else
        if self.playback_state.spatial_settings then
            self.playback_state.spatial_settings.x = position.x
            self.playback_state.spatial_settings.y = position.y
            self.playback_state.spatial_settings.z = position.z
            self:_apply_spatial_effects(self.playback_state.spatial_settings, self.source)
        end
    end
end

---@class AudioChannel : Object
local AudioChannel = Object:extend()

function AudioChannel:init(name, method)
    self.name = name
    self.method = method or "static"
    self.volume = 1
    self.real_volume = 1
    self.tracks = {}
    self.base_path = ""
end

function AudioChannel:clear()
    for _, track in pairs(self.tracks) do
        if track.source then
            pcall(track.source.stop, track.source)
            pcall(track.source.release, track.source)
        end
    end
    self.tracks = {}
    self.base_path = ""
end

function AudioChannel:load(path, options)
    options = options or {}
    assert(type(path) == "string" and path ~= "", "audio channel path must be a non-empty virtual path")
    local info = love.filesystem.getInfo(path)
    if not info or info.type ~= "directory" then
        return nil, "audio directory not found: " .. path
    end
    if options.replace then self:clear() end
    self.base_path = path
    local files = love.filesystem.getDirectoryItems(path) or {}
    for _, file in ipairs(files) do
        local track_name = file:match("(.+)%..+$")
        if track_name then -- skip subdirectories / extensionless entries
            local full_path = path .. "/" .. file
            local source = audio:_newSourceMonoAware(full_path, self.method)
            if not source then
                local ok, created = pcall(love.audio.newSource, full_path, self.method)
                source = ok and created or nil
            end
            if source then
                self:_add_track(AudioTrack(track_name, source, full_path, self.method))
            else
                print("[audio] could not load track: " .. full_path)
            end
        end
    end
    return true
end

-- load a SINGLE file into this channel under an explicit name, additive
-- alongside whatever load(dir) already populated (mirrors load()'s own
-- per-file construction). Lets a project keep a track under its own asset
-- tree instead of a shared global channel folder
function AudioChannel:load_file(path, name)
    name = name or path:match("([^/\\]+)%..+$") or path
    local source = audio:_newSourceMonoAware(path, self.method)
    if not source then
        source = love.audio.newSource(path, self.method)
    end
    return self:_add_track(AudioTrack(name, source, path, self.method))
end

function AudioChannel:_add_track(track)
    track.channel = self
    self.tracks[track.name] = track
    track:refresh_volume()
    return track
end

---register a generated sound (a SoundData or Source) under a name, e.g
---from engine/services/synth.lua
function AudioChannel:add_sound(name, sound)
    assert(type(name) == "string" and name ~= "", "audio sound needs a name")
    local source = sound
    if type(sound) == "userdata" and sound.typeOf and sound:typeOf("SoundData") then
        source = love.audio.newSource(sound, "static")
    end
    assert(source and source.typeOf and source:typeOf("Source"), "add_sound expects SoundData or a Source")
    return self:_add_track(AudioTrack(name, source, sound, "static"))
end

function AudioChannel:recreate_all_sources()
    for name, track in pairs(self.tracks) do
        -- one track's recreation must never abort the rest of the channel
        -- (recreate_source is already failure-safe internally, this is
        -- defense-in-depth against anything still throwing)
        local ok, err = pcall(track.recreate_source, track)
        if not ok then
            print("[audio] recreate_source failed for '" .. tostring(name) .. "': " .. tostring(err))
        end
    end
end

function AudioChannel:get(name)
    local track = self.tracks[name]
    if not track then
        print("[audio] track not found: " .. name)
    end
    return track
end

function AudioChannel:set_volume(vol, max_vol)
    self.volume = vol
    self.real_volume = vol * max_vol
    for _, track in pairs(self.tracks) do
        track:refresh_volume()
    end
end

---@class AudioSystem : Object
local AudioSystem = Object:extend()

function AudioSystem:init()
    self.channels = {}
    self.max_volume = 1
    self.listener_position = { x = 0, y = 0, z = 0 }
    self.force_mono = false
    self._stereo_spatial_count = 0
    self.asset_root = nil
end

function AudioSystem:set_listener_position(x, y, z)
    self.listener_position.x = x
    self.listener_position.y = y
    self.listener_position.z = z

    love.audio.setPosition(x, y, z)

    -- this runs per frame in gameplay: only scan when some stereo track has
    -- ever gone spatial (mono sources are positioned by OpenAL directly)
    if (self._stereo_spatial_count or 0) > 0 then
        for _, channel in pairs(self.channels) do
            for _, track in pairs(channel.tracks) do
                if track.playback_state.spatial_settings and track.source:getChannelCount() == 2 then
                    track:_apply_spatial_effects(track.playback_state.spatial_settings, track.source)
                end
            end
        end
    end
end

function AudioSystem:get_listener_position()
    return self.listener_position.x, self.listener_position.y, self.listener_position.z
end

function AudioSystem:add_channel(name, method)
    local chan = AudioChannel(name, method)
    self.channels[name] = chan
    return chan
end

local function normalize_asset_root(path)
    assert(type(path) == "string" and path ~= "", "audio asset root must be a non-empty virtual path")
    path = path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
    assert(path ~= "", "audio asset root must be a non-empty virtual path")
    assert(not path:match("^/") and not path:match("^%a:[/]"),
        "audio asset root must be a LÖVE virtual path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "..", "audio asset root must not escape the project")
    end
    return path
end

---set the project-owned root used by explicit audio loading
---this never scans or loads a root asset directory by itself
function AudioSystem:set_asset_root(path)
    self.asset_root = normalize_asset_root(path)
    return self
end

---configure a project's audio ownership boundary
---pass an explicit project audio root with `autoload = true` only when that
---project intentionally wants every file in its music/sfx directories
function AudioSystem:configure(options)
    options = options or {}
    assert(type(options) == "table", "audio:configure expects a table")
    local root = options.root or options.asset_root
    if root ~= nil then self:set_asset_root(root) end
    if options.autoload then
        assert(self.asset_root, "audio:configure({autoload=true}) needs root")
        return self:load_all(self.asset_root, { replace = options.replace ~= false })
    end
    return true
end

function AudioSystem:load_all(base_path, options)
    base_path = normalize_asset_root(base_path)
    options = options or {}
    for name, chan in pairs(self.channels) do
        local ok, err = chan:load(base_path .. "/" .. name, options)
        if not ok then return nil, err end
    end
    self.asset_root = base_path
    return true
end

---load one named project-owned track without scanning a directory
function AudioSystem:load_file(channel, path, name)
    local target = self.channels[channel]
    assert(target, "unknown audio channel: " .. tostring(channel))
    assert(type(path) == "string" and path ~= "", "audio file path must be a non-empty virtual path")
    return target:load_file(path, name)
end

function AudioSystem:clear(channel)
    if channel ~= nil then
        local target = self.channels[channel]
        if target then target:clear() end
        return self
    end
    for _, target in pairs(self.channels) do target:clear() end
    return self
end

function AudioSystem:play(channel, name, settings)
    local ch = self.channels[channel]
    if ch then
        local track = ch:get(name)
        if track then track:play(settings) end
    end
end

function AudioSystem:pause(channel, name)
    local track = self.channels[channel]:get(name)
    if track then track:pause() end
end

function AudioSystem:resume(channel, name)
    local track = self.channels[channel]:get(name)
    if track then track:resume() end
end

function AudioSystem:stop(channel, name)
    local track = self.channels[channel]:get(name)
    if track then track:stop() end
end

function AudioSystem:update_position(channel, name, position)
    local track = self.channels[channel]:get(name)
    if track then track:update_position(position) end
end

function AudioSystem:set_volume(channel, vol)
    if self.channels[channel] then
        self.channels[channel]:set_volume(vol, self.max_volume)
    end
end

function AudioSystem:set_max_volume(vol)
    self.max_volume = vol
    for _, ch in pairs(self.channels) do
        ch:set_volume(ch.volume, self.max_volume)
    end
end

function AudioSystem:recreate_all_sources()
    for channel_name, channel in pairs(self.channels) do
        -- same defense-in-depth as AudioChannel:recreate_all_sources: one
        -- channel's failure must not stop the rest (e.g. music never
        -- recreating because sfx threw first)
        local ok, err = pcall(channel.recreate_all_sources, channel)
        if not ok then
            print("[audio] recreate_all_sources failed for channel '" .. tostring(channel_name) .. "': " .. tostring(err))
        end
    end
end

-- Averages a stereo SoundData into a fresh mono SoundData
function AudioSystem:_downmix_sounddata(sd)
    local samples = (sd.getSampleCount and sd:getSampleCount()) or 0
    local rate = (sd.getSampleRate and sd:getSampleRate()) or 44100
    local bitdepth = (sd.getBitDepth and sd:getBitDepth()) or 16

    local mono = love.sound.newSoundData(samples, rate, bitdepth, 1)
    for i = 0, samples - 1 do
        local L = sd:getSample(i, 1)
        local R = sd:getSample(i, 2)
        local avg = (L + R) * 0.5
        mono:setSample(i, avg)
    end
    return mono
end

-- always returns a mono static Source for the file (downmixing stereo), or nil
-- newSource can throw (e.g. OpenAL source-pool exhaustion) -- pcall it like
-- the decode step above so a transient failure returns nil instead of
-- propagating an uncaught error out of a recreate_all_sources() loop
function AudioSystem:_newSourceDownmixed(path)
    local ok, sd = pcall(love.sound.newSoundData, path)
    if not ok or not sd then return nil end

    local channels = (sd.getChannelCount and sd:getChannelCount()) or (sd.getChannels and sd:getChannels()) or 2
    local ok2, src
    if channels == 1 then
        ok2, src = pcall(love.audio.newSource, sd)
    else
        ok2, src = pcall(love.audio.newSource, self:_downmix_sounddata(sd))
    end
    if ok2 then return src end
    return nil
end

-- returns a new Source honoring mono toggle when possible, or nil on fallback
function AudioSystem:_newSourceMonoAware(path, method)
    if not self.force_mono then return nil end
    if method ~= 'static' then return nil end
    return self:_newSourceDownmixed(path)
end

function AudioSystem:set_force_mono(enabled)
    enabled = enabled and true or false
    if self.force_mono == enabled then return end
    self.force_mono = enabled
    self:recreate_all_sources()
end

---@type AudioSystem
audio = AudioSystem()
audio:add_channel("music", "stream")
audio:add_channel("sfx", "static")

