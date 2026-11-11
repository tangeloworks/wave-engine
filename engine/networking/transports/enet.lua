--[[ enet transport (the default): reliable/sequenced udp via the vendored
sock.lua over love's built-in lua-enet. one codebase covers localhost, LAN
and any host that exposes a udp port (aws/gcp/oracle vps, home hosting)

transport contract (any future transport must provide the same):
  transport.host(opts)  -> backend with :update() :broadcast(event, data,
      mode) :send(peer_id, event, data, mode) :kick(peer_id)
      :set_handler(fn(kind, peer_id, event, data)) :register_event(name)
      :destroy()  (kind = 'connect' | 'disconnect' | 'message')
  transport.join(opts)  -> backend with :update() :send(event, data, mode)
      :disconnect() :is_connected() :is_connecting()
      :set_handler(fn(kind, event, data)) :register_event(name) :destroy()
]]

local sock = require "engine.services.oss.sock"

--[[ serialization. bitser (binary, ffi) is preferred, but it is only used
after a live round-trip probe succeeds - ffi behaves differently across
desktop / mobile / console, so we never trust require alone. the fallback is
the engine's lua-literal serializer with a SANDBOXED loader (wire data from
strangers must never reach plain load) ]]
local serialize, deserialize

local function sandboxed(str)
    local chunk = load("return " .. tostring(str), "net", "t", {})
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    if not ok then return nil end
    return value
end

local function bitser_works(bitser)
    local sample = { a = 1, b = "hi", c = { 1, 2, 3 }, d = true }
    local ok, encoded = pcall(bitser.dumps, sample)
    if not ok or type(encoded) ~= "string" then return false end
    local ok2, decoded = pcall(bitser.loads, encoded)
    return ok2 and type(decoded) == "table"
        and decoded.a == 1 and decoded.b == "hi" and decoded.d == true
        and type(decoded.c) == "table" and decoded.c[3] == 3
end

local ok_bitser, bitser = pcall(require, "engine.services.oss.bitser")
if ok_bitser and type(bitser) == "table" and type(bitser.dumps) == "function"
    and bitser_works(bitser) then
    serialize = bitser.dumps
    deserialize = bitser.loads
else
    serialize = serialize_table
    deserialize = sandboxed
end

local transport = {}
-- which serializer won the probe ("bitser" | "text"), handy on-device where
-- bitser may fall back
transport.serializer = (serialize == serialize_table) and "text" or "bitser"

-- sock's logger both prints warnings and accumulates every message forever
local function quiet(endpoint)
    if endpoint and endpoint.logger then
        endpoint.logger.printWarnings = false
        endpoint.logger.log = function() end
    end
end

local server_backend = {}
server_backend.__index = server_backend

function transport.host(opts)
    local self = setmetatable({}, server_backend)
    self.sock = sock.newServer(opts.address or "*", opts.port or 22122,
        opts.max_players or 16, opts.channels or 1)
    quiet(self.sock)
    self.sock:setSerialization(serialize, deserialize)
    self.handler = function() end
    self.clients = {} -- peer_id -> sock client
    self.registered = {}

    self.sock:on("connect", function(_, client)
        quiet(client)
        local id = client:getConnectId()
        self.clients[id] = client
        self.handler('connect', id)
    end)
    self.sock:on("disconnect", function(_, client)
        local id = client:getConnectId()
        self.clients[id] = nil
        self.handler('disconnect', id)
    end)
    return self
end

function server_backend:set_handler(fn)
    self.handler = fn
end

-- sock has no catch-all, so the generic layer names events before use
function server_backend:register_event(name)
    if self.registered[name] then return end
    self.registered[name] = true
    self.sock:on(name, function(data, client)
        self.handler('message', client:getConnectId(), name, data)
    end)
end

function server_backend:update()
    self.sock:update()
end

function server_backend:broadcast(event, data, mode)
    if mode then self.sock:setSendMode(mode) end
    self.sock:sendToAll(event, data)
end

function server_backend:send(peer_id, event, data, mode)
    local client = self.clients[peer_id]
    if not client then return false end
    if mode then client:setSendMode(mode) end
    client:send(event, data)
    return true
end

function server_backend:kick(peer_id)
    local client = self.clients[peer_id]
    if client then
        client:disconnectLater()
    end
end

function server_backend:destroy()
    -- notify peers immediately instead of leaving them to time out
    for _, client in pairs(self.clients) do
        pcall(function() client:disconnectNow() end)
    end
    self.sock:destroy()
    self.clients = {}
end

local client_backend = {}
client_backend.__index = client_backend

function transport.join(opts)
    local self = setmetatable({}, client_backend)
    self.sock = sock.newClient(opts.address or "localhost", opts.port or 22122,
        opts.channels or 1)
    quiet(self.sock)
    self.sock:setSerialization(serialize, deserialize)
    self.handler = function() end
    self.registered = {}

    self.sock:on("connect", function(data)
        --[[ tighten enet's drop detection (default can take 30s), games
        want to know within a few seconds that the server is gone ]]
        local drop = (opts.drop_timeout or 6) * 1000
        pcall(function() self.sock:setTimeout(32, drop, drop * 2) end)
        self.handler('connect', nil, data)
    end)
    self.sock:on("disconnect", function(data)
        self.handler('disconnect', nil, data)
    end)

    self.sock:connect()
    return self
end

function client_backend:set_handler(fn)
    self.handler = fn
end

function client_backend:register_event(name)
    if self.registered[name] then return end
    self.registered[name] = true
    self.sock:on(name, function(data)
        self.handler('message', name, data)
    end)
end

function client_backend:update()
    self.sock:update()
end

function client_backend:send(event, data, mode)
    if mode then self.sock:setSendMode(mode) end
    self.sock:send(event, data)
end

function client_backend:is_connected()
    return self.sock:isConnected()
end

function client_backend:is_connecting()
    return self.sock:isConnecting() or false
end

function client_backend:disconnect()
    if self.sock.connection then
        self.sock:disconnectNow()
    end
end

function client_backend:destroy()
    self:disconnect()
end

return transport
