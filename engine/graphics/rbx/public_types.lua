---@meta
-- Type-only declarations for factory exports. this file is never required at runtime

---@class RBXEnumItem
---@field EnumType string
---@field Name string
---@field Value integer
---@field value integer
---@field EnumItem string

---@class RBXEnum
---@field PartType {Ball:RBXEnumItem, Block:RBXEnumItem, Cylinder:RBXEnumItem, Wedge:RBXEnumItem, CornerWedge:RBXEnumItem}
---@field SurfaceType {Smooth:RBXEnumItem, Glue:RBXEnumItem, Weld:RBXEnumItem, Studs:RBXEnumItem, Inlet:RBXEnumItem, Universal:RBXEnumItem, Hinge:RBXEnumItem, Motor:RBXEnumItem, SteppingMotor:RBXEnumItem, SmoothNoOutlines:RBXEnumItem}
---@field RaycastFilterType {Exclude:RBXEnumItem, Include:RBXEnumItem, Blacklist:RBXEnumItem, Whitelist:RBXEnumItem}
---@field CameraType {Fixed:RBXEnumItem, Attach:RBXEnumItem, Watch:RBXEnumItem, Track:RBXEnumItem, Follow:RBXEnumItem, Custom:RBXEnumItem, Scriptable:RBXEnumItem, Orbital:RBXEnumItem}
---@field NormalId table<string,RBXEnumItem|nil>
---@field Face table<string,RBXEnumItem|nil>
---@field MeshType table<string,RBXEnumItem|nil>
---@field AlphaMode table<string,RBXEnumItem|nil>
---@field ResamplerMode table<string,RBXEnumItem|nil>
---@field TextXAlignment table<string,RBXEnumItem|nil>
---@field TextYAlignment table<string,RBXEnumItem|nil>
---@field SurfaceGuiSizingMode table<string,RBXEnumItem|nil>
---@field Font table<string,RBXEnumItem|nil>
---@field Material table<string,RBXEnumItem|nil>

---@class RBXLXInstanceApi
local Instance = {}

---creates an unparented object in the active world, pass Parent explicitly to attach it
---use world.Instance when more than one world is alive
---@overload fun(class_name:'Part', properties?:RBXLXPartProperties):RBXLXPart
---@overload fun(class_name:'WedgePart', properties?:RBXLXPartProperties):RBXLXPart
---@overload fun(class_name:'CornerWedgePart', properties?:RBXLXPartProperties):RBXLXPart
---@overload fun(class_name:'MeshPart', properties?:RBXLXPartProperties):RBXLXPart
---@overload fun(class_name:'BodyForce', properties?:RBXLXBodyForceProperties):RBXLXBodyForce
---@overload fun(class_name:'BodyGyro', properties?:table):RBXLXBodyGyro
---@overload fun(class_name:'Camera', properties?:table):RBXLXCamera
---@overload fun(class_name:'Atmosphere', properties?:table):RBXLXAtmosphere
---@overload fun(class_name:'SurfaceAppearance', properties?:table):RBXLXSurfaceAppearance
---@overload fun(class_name:'Decal', properties?:table):RBXLXDecal
---@overload fun(class_name:'Texture', properties?:table):RBXLXTexture
---@overload fun(class_name:'SpecialMesh', properties?:table):RBXLXSpecialMesh
---@overload fun(class_name:'BlockMesh', properties?:table):RBXLXBlockMesh
---@overload fun(class_name:'CylinderMesh', properties?:table):RBXLXCylinderMesh
---@param class_name string
---@param properties? table
---@return RBXLXInstance
function Instance.new(class_name, properties) end

---@return string[]
function Instance.GetSupportedClasses() end

return Instance
