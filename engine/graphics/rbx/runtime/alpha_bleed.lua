-- fill transparent edge pixels with nearby color before filtering
-- the renderer and decode workers share this code so their textures match

local AlphaBleed = {}

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok and type(ffi) ~= "table" then
    ffi_ok = false
    ffi = nil
end

-- one small scratch array per Lua state (including decode workers), bounded
-- independently of image area. Alpha never changes in the bleed kernel
local column_counts, column_capacity = nil, 0
local function alpha_columns(px, width, height)
    if width > 16384 then return nil end
    if column_capacity < width then
        column_capacity = math.min(16384, math.max(width, column_capacity * 2, 64))
        column_counts = ffi.new('uint8_t[?]', column_capacity)
    end
    ffi.fill(column_counts, width)
    for y = 0, math.min(4, height - 1) do
        local row = y * width * 4
        for x = 0, width - 1 do
            if px[row + x * 4 + 3] > 0 then column_counts[x] = column_counts[x] + 1 end
        end
    end
    return column_counts
end

-- Progressive in-place semantics are intentional: a transparent pixel filled
-- earlier in scan order still has alpha zero and therefore cannot become a
-- source for a later pixel. only authored non-zero-alpha neighbors contribute
local function bleed_rgba8(px, width, height)
    local changed = 0
    local stride = width * 4
    local columns = alpha_columns(px, width, height)
    for y = 0, height - 1 do
        local row_offset = y * stride
        local contributors = 0
        if columns then
            for x = 0, math.min(4, width - 1) do contributors = contributors + columns[x] end
        end
        for x = 0, width - 1 do
            local offset = row_offset + x * 4
            -- empty radius-four rectangles cannot contribute to any of the
            -- original clipped rings. keep their RGB untouched. Nonempty ones
            -- run the same rings, summation order, weights and rounding below
            if px[offset + 3] == 0 and (not columns or contributors > 0) then
                local out_r, out_g, out_b, total_weight = 0, 0, 0, 0
                for radius = 1, 4 do
                    local min_x = x - radius
                    if min_x < 0 then min_x = 0 end
                    local max_x = x + radius
                    if max_x > width - 1 then max_x = width - 1 end
                    local min_y = y - radius
                    if min_y < 0 then min_y = 0 end
                    local max_y = y + radius
                    if max_y > height - 1 then max_y = height - 1 end
                    for sample_y = min_y, max_y do
                        local sample_row = sample_y * stride
                        for sample_x = min_x, max_x do
                            if sample_x == min_x or sample_x == max_x
                                or sample_y == min_y or sample_y == max_y then
                                local sample_offset = sample_row + sample_x * 4
                                local alpha_byte = px[sample_offset + 3]
                                if alpha_byte > 0 then
                                    local a = alpha_byte / 255
                                    local dx = sample_x - x
                                    local dy = sample_y - y
                                    local weight = a / math.max(
                                        1, dx * dx + dy * dy)
                                    out_r = out_r
                                        + (px[sample_offset] / 255) * weight
                                    out_g = out_g
                                        + (px[sample_offset + 1] / 255) * weight
                                    out_b = out_b
                                        + (px[sample_offset + 2] / 255) * weight
                                    total_weight = total_weight + weight
                                end
                            end
                        end
                    end
                    if total_weight > 0 then break end
                end
                if total_weight > 0 then
                    local r = out_r / total_weight
                    local g = out_g / total_weight
                    local b = out_b / total_weight
                    if r < 0 then r = 0 elseif r > 1 then r = 1 end
                    if g < 0 then g = 0 elseif g > 1 then g = 1 end
                    if b < 0 then b = 0 elseif b > 1 then b = 1 end
                    px[offset] = math.floor(r * 255 + 0.5)
                    px[offset + 1] = math.floor(g * 255 + 0.5)
                    px[offset + 2] = math.floor(b * 255 + 0.5)
                    px[offset + 3] = 0
                    changed = changed + 1
                end
            end
            if columns then
                if x >= 4 then contributors = contributors - columns[x - 4] end
                if x + 5 < width then contributors = contributors + columns[x + 5] end
            end
        end
        if columns then
            local leaving, entering = y - 4, y + 5
            for x = 0, width - 1 do
                local value = columns[x]
                if leaving >= 0 and px[leaving * stride + x * 4 + 3] > 0 then value = value - 1 end
                if entering < height and px[entering * stride + x * 4 + 3] > 0 then value = value + 1 end
                columns[x] = value
            end
        end
    end
    return changed
end

function AlphaBleed.bleed(image_data)
    if not image_data or not image_data.getDimensions
        or not image_data.getPixel or not image_data.setPixel then
        return 0
    end

    local width, height = image_data:getDimensions()
    if not width or not height or width <= 0 or height <= 0 then
        return 0
    end

    if ffi_ok and image_data.getFormat
        and image_data:getFormat() == "rgba8"
        and image_data.getFFIPointer then
        local ok_ptr, pointer = pcall(image_data.getFFIPointer, image_data)
        if ok_ptr and pointer ~= nil then
            return bleed_rgba8(
                ffi.cast("uint8_t*", pointer), width, height)
        end
    end

    local changed = 0
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local _, _, _, alpha = image_data:getPixel(x, y)
            if (alpha or 0) <= 0.001 then
                local out_r, out_g, out_b, total_weight = 0, 0, 0, 0
                for radius = 1, 4 do
                    local min_x = math.max(0, x - radius)
                    local max_x = math.min(width - 1, x + radius)
                    local min_y = math.max(0, y - radius)
                    local max_y = math.min(height - 1, y + radius)
                    for sample_y = min_y, max_y do
                        for sample_x = min_x, max_x do
                            if sample_x == min_x or sample_x == max_x
                                or sample_y == min_y
                                or sample_y == max_y then
                                local r, g, b, a =
                                    image_data:getPixel(sample_x, sample_y)
                                if (a or 0) > 0.001 then
                                    local dx = sample_x - x
                                    local dy = sample_y - y
                                    local weight = (a or 0) / math.max(
                                        1, dx * dx + dy * dy)
                                    out_r = out_r + (r or 0) * weight
                                    out_g = out_g + (g or 0) * weight
                                    out_b = out_b + (b or 0) * weight
                                    total_weight = total_weight + weight
                                end
                            end
                        end
                    end
                    if total_weight > 0 then break end
                end
                if total_weight > 0 then
                    image_data:setPixel(
                        x, y,
                        out_r / total_weight,
                        out_g / total_weight,
                        out_b / total_weight,
                        0)
                    changed = changed + 1
                end
            end
        end
    end
    return changed
end

-- exact alpha classification for a texture already held as ImageData. it is
-- deliberately conservative: any unsupported format, failed read, or one
-- non-255 alpha sample returns false rather than changing renderer semantics
function AlphaBleed.is_fully_opaque(image_data)
    if not image_data or not image_data.getDimensions
        or not image_data.getPixel then
        return false
    end
    local width, height = image_data:getDimensions()
    if not width or not height or width <= 0 or height <= 0 then
        return false
    end
    if ffi_ok and image_data.getFormat
        and image_data:getFormat() == "rgba8"
        and image_data.getFFIPointer then
        local ok_ptr, pointer = pcall(image_data.getFFIPointer, image_data)
        if ok_ptr and pointer ~= nil then
            local px = ffi.cast("uint8_t*", pointer)
            local limit = width * height * 4
            for offset = 3, limit - 1, 4 do
                if px[offset] ~= 255 then return false end
            end
            return true
        end
    end
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local _, _, _, alpha = image_data:getPixel(x, y)
            if alpha ~= 1 then return false end
        end
    end
    return true
end

return AlphaBleed
