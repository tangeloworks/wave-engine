local original_print = print
function print(...)
  local arguments = { ... }
  local message = ''
  for index, value in ipairs(arguments) do
    if type(value) == 'table' then
      message = message .. table2str(value, 1)
    else
      message = message .. tostring(value)
    end
    if index < #arguments then message = message .. "\t" end
  end
  original_print(message)
end

function string.split(text, separators)
  if separators == nil then separators = "%s" end
  local words = {}
  for word in string.gmatch(text, "([^" .. separators .. "]+)") do
    words[#words + 1] = word
  end
  return words
end

function table.extend(destination, source)
  for key, value in pairs(source) do
    destination[key] = value
  end
  return destination
end

function table.find(values, target, start_index)
  assert(target ~= nil, "second argument cannot be nil")
  for index = start_index or 1, #values do
    if values[index] == target then return index end
  end
end

function table.dict_length(values)
  local count = 0
  for _ in next, values do count = count + 1 end
  return count
end

function table.shallow_copy(source)
  return table.extend({}, source)
end

function table.deep_copy(source)
  if type(source) ~= 'table' then return source end
  local copy = {}
  for key, value in next, source do
    copy[table.deep_copy(key)] = table.deep_copy(value)
  end
  return setmetatable(copy, table.deep_copy(getmetatable(source)))
end

function math.round(num)
  return math.floor(num + 0.5)
end

function math.clamp(number, min, max)
  return math.max(min, math.min(number, max))
end

local function fastExp(x)
  if x > 1 then return math.exp(x) end
  if x < -2.5 then return 0 end
  local x2 = x * x
  local x3 = x2 * x
  local x4 = x3 * x
  return 1 + x + (x2 * 0.5) + (x3 * (1 / 6)) + (x4 * (1 / 24))
end

function math.roundlerp(a, b, t, dtcheck)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local f = dtcheck and t or (1 - t ^ G.delta)
  local p = 1 - fastExp(-f)
  local r = a + (b - a) * p
  local e = 1e-6 * (1 + math.abs(b))
  if math.abs(b - r) <= e then return b end
  return math.floor(r * 1e6 + 0.5) / 1e6
end

function math.lerp(a, b, t, dtcheck)
  if t == 1 then
    return b
  end
  return a + (b - a) * (dtcheck and t or (1 - t ^ G.delta))
end

function math.roundToDecimal(value, numDecimalPlaces)
  local multiplier = 10 ^ (numDecimalPlaces)
  return math.floor(value * multiplier + 0.5) / multiplier
end

function math.lerp_angle(a1, a2, t, dtcheck)
  local diff = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
  local result = a1 + diff * (dtcheck and t or (1 - t ^ G.delta))
  return math.abs(t - 1) < 1e-5 and a2 or (result + 2 * math.pi) % (2 * math.pi)
end

function getLerpAlpha(speed, dt)
  return 1 - math.exp(-speed * dt)
end

lerp = math.lerp
function lerpRGB(color1, color2, t, dtcheck)
  local color = {}
  color[1] = lerp(color1[1], color2[1], t, dtcheck)
  color[2] = lerp(color1[2], color2[2], t, dtcheck)
  color[3] = lerp(color1[3], color2[3], t, dtcheck)
  if color1[4] and color2[4] then
    color[4] = lerp(color1[4], color2[4], t, dtcheck)
  end
  return color
end

function clamp1(x) return math.max(-1, math.min(1, x)) end

function lerpVec(v, trg, t)
  v:set(lerp(v.x, trg.x, t),
    lerp(v.y, trg.y, t)); return v
end

function limitMin(v, minMag)
  if v:magnitude() < minMag and v:magnitude() > 0 then v:setMagnitude(minMag) end
  return v
end

base64 = require "engine/services/oss/base64"

function serialize_table(tbl)
  local t = type(tbl)
  if t == "number" or t == "boolean" then
    return tostring(tbl)
  elseif t == "string" then
    return string.format("%q", tbl)
  elseif t == "table" then
    local s = "{"
    local first = true
    for k, v in pairs(tbl) do
      local key_type = type(k)
      local val_type = type(v)
      if val_type ~= "function" and val_type ~= "userdata" and val_type ~= "thread" then
        if not first then
          s = s .. ","
        end
        first = false
        if key_type == "number" then
          s = s .. "[" .. k .. "]=" .. serialize_table(v)
        elseif key_type == "string" then
          if k:match("^[_%a][_%w]*$") then
            s = s .. k .. "=" .. serialize_table(v)
          else
            s = s .. "[" .. string.format("%q", k) .. "]=" .. serialize_table(v)
          end
        end
      end
    end
    s = s .. "}"
    return s
  else
    return "nil"
  end
end

function deserialize_table(str)
  local f, err = load("return " .. str)
  if not f then
    error("Error loading serialized table: " .. err)
  end
  return f()
end

function load_data(filename, default_data)
  local fileContents, size = love.filesystem.read(filename)
  if not fileContents or fileContents == '' then
    return default_data
  end
  local decodedData = base64.decode(fileContents)
  local success, result = pcall(function() return deserialize_table(decodedData) end)
  if not success or result == nil then
    print("[save] could not decode saved data, using the defaults")
    return default_data
  end
  return result
end

function math.sign(x)
  return (x > 0 and 1) or (x < 0 and -1) or 0
end


function table2str(tab, max_depth, indent, done)
  max_depth = max_depth or math.huge -- default: no depth limit
  done = done or {}
  indent = indent or 0
  local str = ""

  if type(tab) == "table" then
    if done[tab] then
      return "(recursion)"
    end
    done[tab] = true

    if max_depth > 0 then -- only process if we haven't reached max depth
      str = str .. "{\n"
      for k, v in pairs(tab) do
        str = str .. string.rep("  ", indent + 1)
        str = str .. tostring(k) .. ": "

        if type(v) == "table" then
          -- Recursive call with decreased max_depth
          str = str .. table2str(v, max_depth - 1, indent + 1, done)
        else
          str = str .. tostring(v)
        end

        str = str .. ",\n"
      end
      str = str .. string.rep("  ", indent) .. "}"
    else
      str = "{ ... }" -- Indicate that there's more to the table
    end
  else
    str = tostring(tab)
  end

  return str
end
