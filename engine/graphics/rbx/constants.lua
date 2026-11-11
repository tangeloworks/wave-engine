local util = require("engine/graphics/rbx/util")

local bitops = util.make_bitops()
local lshift = bitops.lshift

local constants = {}

constants.BINARY_SIGNATURE = "<roblox!\137\255\r\n\26\n"

constants.DATA_TYPES = {
    String = 0x01,
    Bool = 0x02,
    Int32 = 0x03,
    Float32 = 0x04,
    Float64 = 0x05,
    UDim = 0x06,
    UDim2 = 0x07,
    Ray = 0x08,
    Faces = 0x09,
    Axes = 0x0A,
    BrickColor = 0x0B,
    Color3 = 0x0C,
    Vector2 = 0x0D,
    Vector3 = 0x0E,
    CFrame = 0x10,
    Enum = 0x12,
    Referent = 0x13,
    Vector3int16 = 0x14,
    NumberSequence = 0x15,
    ColorSequence = 0x16,
    NumberRange = 0x17,
    Rect = 0x18,
    PhysicalProperties = 0x19,
    Color3uint8 = 0x1A,
    Int64 = 0x1B,
    SharedString = 0x1C,
    Bytecode = 0x1D,
    OptionalCFrame = 0x1E,
    UniqueId = 0x1F,
    Font = 0x20,
    SecurityCapabilities = 0x21,
    Content = 0x22,
}

constants.TYPE_NAMES_BY_ID = {}
for name, id in pairs(constants.DATA_TYPES) do
    constants.TYPE_NAMES_BY_ID[id] = name
end

constants.CFRAME_SPECIAL_ORIENTATIONS = {
    [0x02] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    [0x03] = { 1, 0, 0, 0, 0, -1, 0, 1, 0 },
    [0x05] = { 1, 0, 0, 0, -1, 0, 0, 0, -1 },
    [0x06] = { 1, 0, 0, 0, 0, 1, 0, -1, 0 },
    [0x07] = { 0, 1, 0, 1, 0, 0, 0, 0, -1 },
    [0x09] = { 0, 0, 1, 1, 0, 0, 0, 1, 0 },
    [0x0A] = { 0, -1, 0, 1, 0, 0, 0, 0, 1 },
    [0x0C] = { 0, 0, -1, 1, 0, 0, 0, -1, 0 },
    [0x0D] = { 0, 1, 0, 0, 0, 1, 1, 0, 0 },
    [0x0E] = { 0, 0, -1, 0, 1, 0, 1, 0, 0 },
    [0x10] = { 0, -1, 0, 0, 0, -1, 1, 0, 0 },
    [0x11] = { 0, 0, 1, 0, -1, 0, 1, 0, 0 },
    [0x14] = { -1, 0, 0, 0, 1, 0, 0, 0, -1 },
    [0x15] = { -1, 0, 0, 0, 0, 1, 0, 1, 0 },
    [0x17] = { -1, 0, 0, 0, -1, 0, 0, 0, 1 },
    [0x18] = { -1, 0, 0, 0, 0, -1, 0, -1, 0 },
    [0x19] = { 0, 1, 0, -1, 0, 0, 0, 0, 1 },
    [0x1B] = { 0, 0, -1, -1, 0, 0, 0, 1, 0 },
    [0x1C] = { 0, -1, 0, -1, 0, 0, 0, 0, -1 },
    [0x1E] = { 0, 0, 1, -1, 0, 0, 0, -1, 0 },
    [0x1F] = { 0, 1, 0, 0, 0, -1, -1, 0, 0 },
    [0x20] = { 0, 0, 1, 0, 1, 0, -1, 0, 0 },
    [0x22] = { 0, -1, 0, 0, 0, 1, -1, 0, 0 },
    [0x23] = { 0, 0, -1, 0, -1, 0, -1, 0, 0 },
}

constants.CFRAME_ORIENTATION_KEYS = {}
for orient_id, orientation in pairs(constants.CFRAME_SPECIAL_ORIENTATIONS) do
    local key = 0
    for index = 1, 9 do
        local value = orientation[index]
        if value > 0 then
            key = key + lshift(1, index - 1)
        elseif value < 0 then
            key = key + lshift(1, index + 8)
        end
    end
    constants.CFRAME_ORIENTATION_KEYS[key] = orient_id
end

constants.PART_SHAPES = {
    aliases = {
        block = "Block",
        brick = "Block",
        ball = "Ball",
        sphere = "Ball",
        cylinder = "Cylinder",
        wedge = "Wedge",
        cornerwedge = "CornerWedge",
        ["corner_wedge"] = "CornerWedge",
    },
}

constants.SPECIAL_MESH_TYPES = {
    aliases = {
        head = "Head",
        torso = "Torso",
        wedge = "Wedge",
        sphere = "Sphere",
        cylinder = "Cylinder",
        filemesh = "FileMesh",
        brick = "Brick",
    },
    primitive_shapes = {
        Head = "Ball",
        Torso = "Block",
        Wedge = "Wedge",
        Sphere = "Ball",
        Cylinder = "Cylinder",
        Brick = "Block",
    },
}

constants.SUPPORTED_BASEPART_CLASSES = {
    Part = true,
    SpawnLocation = true,
    WedgePart = true,
    CornerWedgePart = true,
    TrussPart = true,
    Seat = true,
    VehicleSeat = true,
    MeshPart = true,
    PartOperation = true,
    UnionOperation = true,
    NegateOperation = true,
}

return constants
