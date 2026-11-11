-- Robot 64 dialogue, copied from the port's dialogue.lua (public
-- CharacterScriptDecomp.txt:1254-1632,8194-8216; see NOTICE.md). The text
-- markup, reveal timing, voice notes and effects are the port's. Only the
-- INT table differs: this place is the Good edition, whose CharacterScript
-- (totext) ends a conversation with INT 1 = Rusty's cosmetics shop,
-- 2 = save the game, 3 = drop to one battery and take a hit.
local Dialogue = {}; Dialogue.__index = Dialogue
Dialogue.CHARACTER_DELAY = 1 / 30 -- provisional legacy-wait cadence; not measured reference parity
Dialogue.PUNCTUATION_EXTRA = 5 * 0.06
Dialogue.actions = { [1] = 'good_edition_shop', [2] = 'save_game', [3] = 'knockout' }
local cache, cache_order, CACHE_LIMIT = {}, {}, 256
local function copy(t) local out = {}; for k, v in pairs(t) do out[k] = v end; return out end
local function child(instance, name)
    if not instance then return nil end
    if instance.FindFirstChild then return instance:FindFirstChild(name) end
    return instance[name]
end
local function value(instance)
    if type(instance) == 'table' and instance.Value ~= nil then return instance.Value end
    return instance
end
local function next_character(text, at)
    local lead = text:byte(at)
    if not lead then return nil, at end
    local size = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
    if lead >= 128 and (lead < 194 or lead > 244) then size = 1 end
    for i = at + 1, at + size - 1 do
        local byte = text:byte(i); if not byte or byte < 128 or byte > 191 then size = 1; break end
    end
    return text:sub(at, at + size - 1), at + size
end
function Dialogue.parse(raw, options)
    assert(type(raw) == 'string', 'Dialogue text must be a string')
    options = options or {}
    local cache_key = tostring(options.console == true) .. ':' .. tostring(options.beebo == true) .. ':' .. tostring(options.silent == true) .. ':' .. tostring(options.no_sound == true) .. ':' .. raw
    if cache[cache_key] then return cache[cache_key] end
    local replacements = options.console and { a = 'attack =0', j = 'jump =1', c = 'crouch =2', d = 'dive =3', F = 'forward', B = 'backward' }
        or { a = 'attack =4', j = 'jump =5=6', c = 'crouch =7=8', d = 'dive =9', F = 'W', B = 'S' }
    local expanded = raw:gsub('>([ajcdFB])', function(code) return '>' .. replacements[code] end)
    local parsed = { raw = raw, expanded = expanded, glyphs = {}, warnings = {}, beebo = options.beebo == true,
        silent = options.silent == true, no_sound = options.no_sound == true }
    local highlight, wave, shake, at = false, false, false, 1
    while at <= #expanded do
        local c, following = next_character(expanded, at)
        if c == '>' or c == '+' then highlight = true
        elseif c == '#' then wave = not wave
        elseif c == '$' then shake = not shake
        elseif c == '=' then
            local digit = expanded:sub(following, following)
            if digit:match('^%d$') then
                parsed.glyphs[#parsed.glyphs + 1] = { kind = 'icon', icon = tonumber(digit), source_offset = at, delay = 0 }
                following = following + 1
            else
                parsed.warnings[#parsed.warnings + 1] = { offset = at, reason = 'Input icon requires one decimal atlas digit.' }
                parsed.glyphs[#parsed.glyphs + 1] = { kind = 'text', text = '=', color = 'default', source_offset = at, delay = 1 }
            end
        else
            local punctuation = c == '.' or c == ',' or c == '!' or c == '?'
            parsed.glyphs[#parsed.glyphs + 1] = { kind = 'text', text = c, source_offset = at,
                color = options.silent and 'silent' or highlight and 'highlight' or 'default',
                beebo = options.beebo == true, wave = wave, shake = not wave and shake,
                punctuation = punctuation, delay = 1, extra_delay = punctuation and Dialogue.PUNCTUATION_EXTRA or 0,
                voice = not options.no_sound and not punctuation and (at + 4) % 5 == 0 }
            if (highlight and punctuation) or c == ' ' then highlight = false end
        end
        at = following
    end
    if #raw <= 65536 then
        cache[cache_key] = parsed; cache_order[#cache_order + 1] = cache_key
        if #cache_order > CACHE_LIMIT then cache[table.remove(cache_order, 1)] = nil end
    end
    return parsed
end
-- Layout is retained separately from animation. Call only when text/font/width
-- changes. Source wrap width830, line height50, spaces8 and icons50 are defaults.
function Dialogue.layout(parsed, measure, options)
    options = options or {}; local width = options.width or 830; local line = options.line_height or 50
    local x, y, result = 0, 0, {}
    local function glyph_width(g)
        return g.kind == 'icon' and (options.icon_width or 50) or g.text == ' ' and (options.space_width or 8) or measure(g.text)
    end
    for index, glyph in ipairs(parsed.glyphs) do
        if glyph.kind == 'text' and glyph.text == '\n' then x, y = 0, y + line
        else
            -- Measure the remaining visible word rather than the markup bytes.
            -- This intentionally repairs source word wrapping counting #/+ etc.
            if index == 1 or (parsed.glyphs[index - 1].kind == 'text' and parsed.glyphs[index - 1].text == ' ') then
                local word = 0
                for j = index, #parsed.glyphs do local g = parsed.glyphs[j]; if g.kind == 'text' and (g.text == ' ' or g.text == '\n') then break end; word = word + glyph_width(g) end
                if x > 0 and x + word > width then x, y = 0, y + line end
            end
            local w = glyph_width(glyph)
            result[#result + 1] = { glyph = glyph, index = index, x = x, y = y, width = w }
            x = x + w; if x > width then x, y = 0, y + line end
        end
    end
    return { glyphs = result, width = width, height = y + line }
end
function Dialogue.effect(glyph, index, game_time, presentation_step, random_int, effect)
    effect = effect or {}
    effect.x, effect.y, effect.rotation, effect.color, effect.hue = 0, 0, 0, glyph.color, nil
    if glyph.kind ~= 'text' then return effect end
    if glyph.beebo then
        if random_int and random_int(1, 200) == 1 then effect.x, effect.y = random_int(-1, 1), random_int(-3, 3) end
    elseif glyph.wave then
        local phase = index / 2 - game_time * 10
        effect.y, effect.rotation, effect.hue = math.sin(phase) * 4, math.cos(phase) * 10, ((presentation_step * 4) % 256) / 255
    elseif glyph.shake and random_int then
        effect.x, effect.y, effect.rotation = random_int(-2, 2), random_int(-2, 2), random_int(-6, 6)
    end
    return effect
end
function Dialogue.node(source, memo)
    if not source then return nil end
    if type(source) == 'table' and source.dialogue_node then return source end
    memo = memo or {}; if memo[source] then return memo[source] end
    local raw = value(source)
    if type(raw) ~= 'string' then return nil, 'Dialogue tx is not a StringValue.' end
    local node = { dialogue_node = true, source = source, raw = raw,
        beebo = child(source, 'beebo') ~= nil, silent = child(source, 'silent') ~= nil,
        ignore = child(source, 'ignore') ~= nil, var_source = child(source, 'var') }
    memo[source] = node
    node.next = Dialogue.node(child(source, 'tx'), memo)
    local int = child(source, 'INT')
    if int then
        node.int = value(int); node.branches = {}
        for _, name in ipairs({ 'tx', 'tx2', 'tx3', 'tx4' }) do node.branches[name] = Dialogue.node(child(int, name), memo) end
    end
    return node
end
local function action(name, data) local a = data or {}; a.name = name; return a end
function Dialogue.resolve(node, context, speaker)
    if node.next then return { next = node.next } end -- tx takes precedence over INT
    local int = node.int
    if int == nil then return { done = true } end
    local name = Dialogue.actions[int]
    if not name then return nil, 'Unknown Good-edition dialogue INT ' .. tostring(int) .. '.' end
    return { action = action(name), done = true }
end
function Dialogue.new(options)
    options = options or {}
    return setmetatable({ console = options.console == true, character_delay = options.character_delay or Dialogue.CHARACTER_DELAY,
        on_action = options.on_action, on_sound = options.on_sound, on_finish = options.on_finish, random_int = options.random_int,
        active = false, ticket = 0, visible = 0, pending_after = {}, status = 'idle' }, Dialogue)
end
function Dialogue:_error(err)
    self.last_error, self.status, self.active = err, 'unresolved', false; self.pending_after = {}; return false, err
end
function Dialogue:_action(descriptor)
    if not self.on_action then return self:_error('Unimplemented public dialogue action: ' .. descriptor.name) end
    local ticket = self.ticket
    local ok, err = self.on_action(descriptor, self.speaker, self.context)
    if ticket ~= self.ticket then return false, 'Dialogue action belonged to a retired conversation.' end
    if not ok then return self:_error(err or ('Unimplemented public dialogue action: ' .. descriptor.name)) end
    return true
end
function Dialogue:_finish()
    while #self.pending_after > 0 do
        local ok, err = self:_action(table.remove(self.pending_after)); if not ok then return false, err end
    end
    self.active, self.status = false, 'finished'
    if self.on_finish then self.on_finish(self) end; return true
end
function Dialogue:_continue()
    local route, err = Dialogue.resolve(self.current, self.context, self.speaker)
    if not route then return self:_error(err) end
    if route.action then local ok, action_err = self:_action(route.action); if not ok then return false, action_err end end
    if route.after then self.pending_after[#self.pending_after + 1] = route.after end
    if route.next then return self:_show(route.next) end
    return self:_finish()
end
function Dialogue:_show(node)
    self.current, self.visible, self.waiting, self.ignore_elapsed, self.status = node, 0, 0, 0, 'revealing'
    self.steps = (self.steps or 0) + 1
    if self.steps > 256 then return self:_error('Dialogue graph cycle/length exceeded 256 nodes.') end
    if node.raw == 'SKIP' then return self:_continue() end
    self.background_asset = node.beebo and 'rbxassetid://1442127057' or 'rbxassetid://1442126894'
    self.parsed = Dialogue.parse(node.raw, { console = self.console, beebo = node.beebo, silent = node.silent })
    if #self.parsed.glyphs == 0 then self.status = 'awaiting' end
    return true
end
function Dialogue:start(source, speaker, context)
    self:cancel()
    local node, err = Dialogue.node(source); if not node then return self:_error(err or 'Dialogue source is absent.') end
    self.speaker, self.context, self.active, self.steps, self.last_error = speaker, context or {}, true, 0, nil
    self.background_asset = node.beebo and 'rbxassetid://1442127057' or 'rbxassetid://1442126894'
    return self:_show(node)
end
function Dialogue:advance()
    if not self.active then return false, self.last_error end
    if self.status == 'revealing' then self.visible, self.waiting, self.status = #self.parsed.glyphs, 0, 'awaiting'; return true end
    if self.status == 'awaiting' then return self:_continue() end
    return false
end
function Dialogue:update(dt)
    if not self.active then return end
    assert(type(dt) == 'number' and dt == dt and dt >= 0 and dt < math.huge, 'Invalid dialogue delta')
    if self.status == 'awaiting' then
        if self.current.ignore then self.ignore_elapsed = self.ignore_elapsed + dt; if self.ignore_elapsed >= 0.1 then self:_continue() end end
        return
    end
    self.waiting = self.waiting - dt
    while self.active and self.status == 'revealing' and self.waiting <= 0 do
        if self.visible >= #self.parsed.glyphs then self.status = 'awaiting'; break end
        self.visible = self.visible + 1
        local glyph = self.parsed.glyphs[self.visible]
        if glyph.voice and self.on_sound then
            local scale = self.context.minor and { 1, 3, 4, 6, 8, 9, 11, 13 } or { 1, 3, 5, 6, 8, 10, 12, 13 }
            local note = self.random_int and scale[self.random_int(1, #scale)] or nil
            local ticket = self.ticket
            self.on_sound({ voice = self.current.beebo and 'text' or 'text2', volume = self.current.silent and 0.2 or 0.5,
                pitch = note and 2 ^ (note / 12) or nil, glyph = glyph }, self)
            if ticket ~= self.ticket then return end
        end
        self.waiting = self.waiting + glyph.delay * self.character_delay + (glyph.extra_delay or 0)
    end
end
function Dialogue:visible_glyphs() return self.parsed and self.parsed.glyphs or {}, self.visible end
function Dialogue:plain_text(icon_text)
    local out = {}
    for i = 1, self.visible do local glyph = self.parsed.glyphs[i]; out[i] = glyph.kind == 'icon' and (icon_text and icon_text[glyph.icon] or ('[' .. glyph.icon .. ']')) or glyph.text end
    return table.concat(out)
end
function Dialogue:cancel()
    self.ticket, self.active, self.status, self.pending_after, self.visible = self.ticket + 1, false, 'cancelled', {}, 0
end
return Dialogue
