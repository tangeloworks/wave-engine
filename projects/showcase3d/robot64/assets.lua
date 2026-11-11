-- the robot pack owns its assets, resolved locally from the map sidecar or asset root
-- authored sounds use the engine channels so the player's volume settings still apply
local AssetPaths = require("engine/graphics/rbx/runtime/asset_paths")
local json = require("engine/services/oss/menori/modules/libs/json")

local Assets = {}
Assets.__index = Assets

function Assets.new(map_path, asset_root)
    return setmetatable({
        map = map_path, root = asset_root, sidecar = AssetPaths.map_directory(map_path),
        cache = {}, loaded = {}, named = {}, warnings = {},
    }, Assets)
end

local function is_file(path)
    return love.filesystem.getInfo(path, "file") ~= nil
end

---resolve a content id or local path, or return nil if the pack does not include it
function Assets:resolve(reference, kind)
    if reference == nil or reference == "" then return nil end
    reference = tostring(reference)
    local key = reference .. "\0" .. tostring(kind)
    local cached = self.cache[key]
    if cached ~= nil then return cached or nil end
    local found = false
    if is_file(reference) then
        found = reference
    else
        for _, path in ipairs(AssetPaths.candidates(reference, kind, { map_path = self.map, asset_root = self.root })) do
            if is_file(path) then found = path; break end
        end
    end
    self.cache[key] = found
    return found or nil
end

---find a FontFace's weight and style in the local family file
function Assets:font(face)
    face = face or {}
    local family = face.family or face.Family
    if not family then return nil, "FontFace missing" end
    local cached = face.cachedFaceId or face.CachedFaceId
    if cached and cached ~= "" then
        local path = self:resolve(cached, "font")
        if path then return path end
    end
    local relative = family:match("^rbxasset://(.*)$")
    local data = relative and love.filesystem.read(self.sidecar .. "/" .. relative)
    if data then
        local info = json.decode(data)
        local weight = face.weight or face.Weight or 400
        local style = (face.style or face.Style or 0) == 1 and "italic" or "normal"
        for _, item in ipairs(info.faces or {}) do
            if item.weight == weight and item.style == style then
                local path = self:resolve(item.assetId, "font")
                if path then return path end
            end
        end
    end
    return nil, "Missing authored font " .. tostring(family)
end

function Assets:_warn(key, message)
    if self.warnings[key] then return end
    self.warnings[key] = true
    print("[robot64] " .. message)
end

-- each channel keeps its own source, even when both use the same file
function Assets:_track(reference, channel, instance_name)
    local path = self:resolve(reference, "sound")
    if not path then
        if reference and reference ~= "" and reference ~= "rbxassetid://0" then
            self:_warn("missing:" .. tostring(reference), "sound not found locally: " .. tostring(reference))
        end
        return nil
    end
    local name = "robot64:" .. channel .. ":" .. (instance_name or "oneshot") .. ":" .. path
    if self.loaded[name] == nil then
        local ok, track = pcall(audio.channels[channel].load_file, audio.channels[channel], path, name)
        self.loaded[name] = ok and track or false
        if not ok then self:_warn(name, "could not load sound " .. path .. ": " .. tostring(track)) end
    end
    return self.loaded[name] or nil, name
end

-- load short effects during setup so the first play doesn't decode mid-frame
function Assets:preload_sound(reference)
    return self:_track(reference, "sfx") ~= nil
end

---play a one-shot, overlapping plays get their own sources
function Assets:play_sound(reference, volume, pitch)
    local track = self:_track(reference, "sfx")
    if track then track:play({ clone = true, volume = volume or 1, pitch = pitch or 1 }) end
    return track ~= nil
end

---keep a named source so its volume can follow the game state
---return nil when the pack does not include the sound
function Assets:play(name, reference, volume, loop, pitch, channel)
    self:stop(name)
    local track = self:_track(reference, channel or "sfx", name)
    if not track then return nil end
    self.named[name] = track
    track:play({ loop = loop == true, volume = volume or 1, pitch = pitch or 1 })
    return track
end

function Assets:set_volume(name, volume)
    local track = self.named[name]
    if track then track:set_volume(volume) end
end

function Assets:stop(name)
    local track = self.named[name]
    if track then track:stop() end
    self.named[name] = nil
end

function Assets:destroy()
    for name, track in pairs(self.loaded) do
        if track then
            track:stop()
            track.source:release()
            track.channel.tracks[name] = nil
        end
    end
    self.loaded, self.named = {}, {}
end

return Assets
