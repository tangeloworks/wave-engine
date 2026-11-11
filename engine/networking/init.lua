--[[ engine networking: one linear client/server api over pluggable
transports. the default enet transport covers localhost, LAN and any udp
host (aws / gcp / oracle / your own vps), a steam or websocket transport
can slot in later by implementing the contract in transports/enet.lua
 the optional ENet transport and LuaSocket discovery backend are loaded only
 when a project requires this module. `sock.lua` retains its embedded notice

    local network = require "engine/networking"

    -- host (authoritative)
    local server = network.host { port = 22122, name = "my game" }
    server:on("connect", function(player) end)
    server:on("input", function(player, data) end)
    server:set_state("round", 1)
    server:set_player_data(player, "x", 120)

    -- join
    local client = network.join { address = "192.168.1.20", port = 22122 }
    client:on("connect", function() end)
    client:on("state", function(state) end) -- .players / world state mirror
    client:send_input({ move = 1 })

    -- LAN browser
    network.discover(function(info) print(info.name, info.address) end)

everything is non-blocking: connects resolve over frames, disconnects fire
events, and a dead server can never stall the game loop. updates hook into
G.pipeline automatically (or call network.update(dt) yourself) ]]

local network = {
    transports = {
        enet = require "engine.networking.transports.enet",
    },
}

-- active wire serializer ("bitser" | "text"), useful on-device where bitser
-- may fall back to the text serializer
network.serializer = network.transports.enet.serializer

local DISCOVERY_PORT = 22123
local DISCOVERY_MAGIC = "LOVENET1"

--[[ luasocket 3.0's socket.udp() makes an unspecified/ipv6-capable socket
that returns WSAECONNREFUSED when you sendto a raw ipv4 literal before it is
bound. socket.udp4() forces the ipv4 stack (broadcast + 127.* both work);
fall back to an explicitly bound udp() where udp4 is unavailable ]]
local function make_udp4(socket)
    local udp = socket.udp4 and socket.udp4() or socket.udp()
    if udp and not socket.udp4 then
        udp:setsockname('0.0.0.0', 0)
    end
    return udp
end

local active = {}
local hooked = false

local function ensure_update_hook()
    if hooked then return end
    if G and G.pipeline and G.pipeline.register then
        G.pipeline:register("update", "networking", function(dt)
            network.update(dt)
        end, { priority = 2, after = "INIT" })
        hooked = true
    end
end

local function track(endpoint)
    active[#active + 1] = endpoint
    ensure_update_hook()
    return endpoint
end

local function untrack(endpoint)
    for i = #active, 1, -1 do
        if active[i] == endpoint then
            table.remove(active, i)
        end
    end
end

function network.update(dt)
    for i = #active, 1, -1 do
        local endpoint = active[i]
        if endpoint._update then
            endpoint:_update(dt)
        end
    end
end

-- ============================== server ==============================

local server = {}
server.__index = server

--[[ opts: port (22122), address ("*" = all interfaces), max_players (16),
transport ("enet"), tick_rate (20 state snapshots/s), discover (false, LAN
beacon), name (discovery label) ]]
function network.host(opts)
    opts = opts or {}
    local self = setmetatable({}, server)
    local transport = network.transports[opts.transport or "enet"]
    assert(transport, "unknown transport: " .. tostring(opts.transport))

    self.backend = transport.host(opts)
    self.players = {}
    self.player_count = 0
    self.state = {}
    self.handlers = {}
    self.tick_rate = opts.tick_rate or 20
    self._tick_acc = 0
    self._state_dirty = true
    self._snapshot = { state = self.state, players = {} }
    self.closed = false

    self.backend:set_handler(function(kind, peer_id, event, data)
        if kind == 'connect' then
            local player = {
                id = peer_id,
                data = {},
                send = function(p, ev, payload, mode)
                    self.backend:register_event(ev)
                    self.backend:send(p.id, ev, payload, mode)
                end,
                kick = function(p) self.backend:kick(p.id) end,
            }
            self.players[peer_id] = player
            self.player_count = self.player_count + 1
            self._snapshot.players[peer_id] = player.data
            self._state_dirty = true
            self:_fire('connect', player)
        elseif kind == 'disconnect' then
            local player = self.players[peer_id]
            if player then
                self.players[peer_id] = nil
                self.player_count = self.player_count - 1
                self._snapshot.players[peer_id] = nil
                self._state_dirty = true
                self:_fire('disconnect', player)
            end
        elseif kind == 'message' then
            local player = self.players[peer_id]
            if player then
                self:_fire(event == 'net_input' and 'input' or event, player, data)
            end
        end
    end)
    self.backend:register_event('net_input')

    if opts.discover then
        self:_start_beacon(opts.name or "server", opts.port or 22122)
    end

    return track(self)
end

function server:_fire(event, ...)
    local handler = self.handlers[event]
    if handler then handler(...) end
end

-- handler(player [, data]), built-ins: connect, disconnect, input
function server:on(event, handler)
    self.handlers[event] = handler
    if event ~= 'connect' and event ~= 'disconnect' and event ~= 'input' then
        self.backend:register_event(event)
    end
    return handler
end

function server:send(player, event, data, mode)
    self.backend:register_event(event)
    self.backend:send(player.id, event, data, mode)
end

function server:broadcast(event, data, mode)
    self.backend:register_event(event)
    self.backend:broadcast(event, data, mode)
end

function server:kick(player)
    self.backend:kick(player.id)
end

-- replicated world state: mirrored to every client at tick_rate
function server:set_state(key, value)
    self.state[key] = value
    self._state_dirty = true
end

function server:set_player_data(player, key, value)
    player.data[key] = value
    self._state_dirty = true
end

function server:_start_beacon(name, port)
    local ok, socket = pcall(require, "socket")
    if not ok then return end
    self._beacon_socket_lib = socket
    self._beacon = true
    -- unique per server instance so a browser dedups the LAN-ip and the
    -- loopback announce of the same host into a single list entry
    local id = string.format("%x%x", os.time(),
        love.math and love.math.random(0, 0xffffff) or math.random(0, 0xffffff))
    self._beacon_msg = table.concat({ DISCOVERY_MAGIC, id, name, tostring(port) }, "|")
    self._beacon_acc = 1 -- announce immediately
end

--[[ a fresh socket per announcement: windows poisons a udp socket with
WSAECONNREFUSED after any icmp bounce, which would silently kill every
following beacon on a long-lived socket ]]
function server:_announce()
    local socket = self._beacon_socket_lib
    local udp = make_udp4(socket)
    if not udp then return end
    udp:settimeout(0)
    pcall(function()
        udp:setoption('broadcast', true)
        udp:sendto(self._beacon_msg, '255.255.255.255', DISCOVERY_PORT)
    end)
    pcall(function()
        -- windows does not reliably loop broadcasts back to the sender's
        -- own machine, announce on loopback too so local browsers work
        udp:sendto(self._beacon_msg, '127.0.0.1', DISCOVERY_PORT)
    end)
    udp:close()
end

function server:_update(dt)
    self.backend:update()

    --[[ replication is decoupled from frame rate: unreliable snapshots at
    tick_rate, and only when something changed ]]
    self._tick_acc = self._tick_acc + dt
    local interval = 1 / self.tick_rate
    if self._tick_acc >= interval then
        self._tick_acc = self._tick_acc % interval
        if self._state_dirty and self.player_count > 0 then
            self._state_dirty = false
            self.backend:broadcast('net_state', self._snapshot, 'unreliable')
        end
    end

    if self._beacon then
        self._beacon_acc = (self._beacon_acc or 0) + dt
        if self._beacon_acc >= 1 then
            self._beacon_acc = 0
            self:_announce()
        end
    end
end

function server:close()
    if self.closed then return end
    self.closed = true
    self._beacon = nil
    self.backend:destroy()
    untrack(self)
end

-- ============================== client ==============================

local client = {}
client.__index = client

--[[ opts: address ("localhost"), port (22122), transport ("enet"),
timeout (5s -> "fail"), reconnect (true), reconnect_tries (3),
reconnect_delay (2s). status: "connecting" | "connected" | "reconnecting"
| "disconnected" | "failed"  ]]
function network.join(opts)
    opts = opts or {}
    local self = setmetatable({}, client)
    self.opts = opts
    self.transport = network.transports[opts.transport or "enet"]
    assert(self.transport, "unknown transport: " .. tostring(opts.transport))

    self.handlers = {}
    self.pending_events = {}
    self.state = {}
    self.players = {}
    self.timeout = opts.timeout or 5
    self.reconnect = opts.reconnect ~= false
    self.reconnect_tries = opts.reconnect_tries or 3
    self.closed = false

    self:_start_backend()
    return track(self)
end

function client:_start_backend()
    if self.backend then self.backend:destroy() end
    self.backend = self.transport.join(self.opts)
    self.status = "connecting"
    self._elapsed = 0

    self.backend:set_handler(function(kind, event, data)
        if kind == 'connect' then
            self.status = "connected"
            self._tries = 0
            self:_fire('connect')
        elseif kind == 'disconnect' then
            if self.status == "connected" then
                self:_fire('disconnect')
                self:_begin_reconnect()
            end
        elseif kind == 'message' then
            if event == 'net_state' and type(data) == 'table' then
                self.state = data.state or {}
                self.players = data.players or {}
                self:_fire('state', self.state, self.players)
            else
                self:_fire(event, data)
            end
        end
    end)
    self.backend:register_event('net_state')
    for event in pairs(self.pending_events) do
        self.backend:register_event(event)
    end
end

--[[ fallback path: an unexpected drop retries quietly in the background
("reconnecting" events), then settles on "failed" - the game keeps running
throughout and can offer offline play or a rejoin button ]]
function client:_begin_reconnect()
    if not self.reconnect or self.closed then
        self.status = "disconnected"
        return
    end
    self._tries = (self._tries or 0) + 1
    if self._tries > self.reconnect_tries then
        self.status = "failed"
        self:_fire('fail')
        return
    end
    self.status = "reconnecting"
    self._retry_in = self.opts.reconnect_delay or 2
    self:_fire('reconnecting', self._tries)
end

-- built-ins: connect, disconnect, reconnecting, fail, state
function client:on(event, handler)
    self.handlers[event] = handler
    local builtin = event == 'connect' or event == 'disconnect'
        or event == 'reconnecting' or event == 'fail' or event == 'state'
    if not builtin then
        self.pending_events[event] = true
        self.backend:register_event(event)
    end
    return handler
end

function client:_fire(event, ...)
    local handler = self.handlers[event]
    if handler then handler(...) end
end

function client:send(event, data, mode)
    if self.status ~= "connected" then return false end
    self.pending_events[event] = true
    self.backend:register_event(event)
    self.backend:send(event, data, mode)
    return true
end

-- movement/action spam belongs on the unreliable channel
function client:send_input(data)
    return self:send('net_input', data, 'unreliable')
end

function client:is_connected()
    return self.status == "connected"
end

function client:_update(dt)
    if self.status == "reconnecting" then
        self._retry_in = self._retry_in - dt
        if self._retry_in <= 0 then
            self:_start_backend()
        end
        return
    end

    self.backend:update()

    if self.status == "connecting" then
        self._elapsed = self._elapsed + dt
        if self.backend:is_connected() then
            -- handled by the connect event, guard for transports without one
            self.status = "connected"
        elseif self._elapsed >= self.timeout then
            self.backend:disconnect()
            self:_begin_reconnect()
            if self.status == "disconnected" then
                self.status = "failed"
                self:_fire('fail')
            end
        end
    end
end

function client:close()
    if self.closed then return end
    self.closed = true
    self.backend:destroy()
    untrack(self)
end

-- ============================== discovery ==============================

local finder = {}
finder.__index = finder

--[[ listens for LAN server beacons, on_found(info) per unique server,
info = { name, address, port }. duration nil = keep listening until
:close(). requires the hosting side to pass discover = true ]]
function network.discover(on_found, duration)
    local ok, socket = pcall(require, "socket")
    if not ok then return nil, "luasocket unavailable" end

    -- ipv4 stack: beacons arrive as ipv4 broadcast / loopback
    local udp = socket.udp4 and socket.udp4() or socket.udp()
    udp:settimeout(0)
    udp:setoption('reuseaddr', true)
    local bound = udp:setsockname('0.0.0.0', DISCOVERY_PORT)
    if not bound then
        return nil, "discovery port in use"
    end

    local self = setmetatable({
        udp = udp,
        on_found = on_found,
        duration = duration,
        elapsed = 0,
        seen = {},
        closed = false,
    }, finder)
    return track(self)
end

function finder:_update(dt)
    for _ = 1, 8 do
        local msg, ip = self.udp:receivefrom()
        if not msg then break end
        local magic, id, name, port = msg:match("^([^|]+)|([^|]*)|([^|]*)|(%d+)$")
        if magic == DISCOVERY_MAGIC then
            -- dedup per server instance, not per address, so the host's own
            -- loopback + lan-ip announcements collapse to one list entry
            if not self.seen[id] then
                self.seen[id] = true
                self.on_found({ name = name, address = ip, port = tonumber(port), id = id })
            end
        end
    end

    if self.duration then
        self.elapsed = self.elapsed + dt
        if self.elapsed >= self.duration then
            self:close()
        end
    end
end

function finder:close()
    if self.closed then return end
    self.closed = true
    self.udp:close()
    untrack(self)
end

return network
