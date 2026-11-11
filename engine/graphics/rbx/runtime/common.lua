---@class RBXLXVector3
---@operator add(RBXLXVector3):RBXLXVector3
---@operator sub(RBXLXVector3):RBXLXVector3
---@operator unm:RBXLXVector3
---@operator mul(number|RBXLXVector3):RBXLXVector3
---@operator div(number|RBXLXVector3):RBXLXVector3
---@field x number
---@field y number
---@field z number
---@field X number
---@field Y number
---@field Z number
---@field Magnitude number
---@field Unit RBXLXVector3
---@field clone fun(self:RBXLXVector3):RBXLXVector3
---@field Dot fun(self:RBXLXVector3, other:RBXLXVector3):number
---@field Cross fun(self:RBXLXVector3, other:RBXLXVector3):RBXLXVector3
---@field Lerp fun(self:RBXLXVector3, other:RBXLXVector3, alpha:number):RBXLXVector3

---@class RBXLXVector3Api
---@field new fun(x?:number, y?:number, z?:number):RBXLXVector3
---@field zero RBXLXVector3
---@field one RBXLXVector3
---@field xAxis RBXLXVector3
---@field yAxis RBXLXVector3
---@field zAxis RBXLXVector3

---@class RBXLXColor3
---@field r number
---@field g number
---@field b number
---@field R number
---@field G number
---@field B number
---@field clone fun(self:RBXLXColor3):RBXLXColor3
---@field Lerp fun(self:RBXLXColor3, other:RBXLXColor3, alpha:number):RBXLXColor3

---@class RBXLXColor3Api
---@field new fun(r?:number, g?:number, b?:number):RBXLXColor3
---@field fromRGB fun(r?:number, g?:number, b?:number):RBXLXColor3
---@field fromHSV fun(h?:number, s?:number, v?:number):RBXLXColor3

---@class RBXLXCFrame
---@operator mul(RBXLXCFrame):RBXLXCFrame
---@operator mul(RBXLXVector3):RBXLXVector3
---@operator add(RBXLXVector3):RBXLXCFrame
---@operator sub(RBXLXVector3):RBXLXCFrame
---@field x number
---@field y number
---@field z number
---@field r00 number
---@field r01 number
---@field r02 number
---@field r10 number
---@field r11 number
---@field r12 number
---@field r20 number
---@field r21 number
---@field r22 number
---@field X number
---@field Y number
---@field Z number
---@field Position RBXLXVector3
---@field LookVector RBXLXVector3
---@field RightVector RBXLXVector3
---@field UpVector RBXLXVector3
---@field clone fun(self:RBXLXCFrame):RBXLXCFrame
---@field get_right_vector fun(self:RBXLXCFrame):number, number, number
---@field get_up_vector fun(self:RBXLXCFrame):number, number, number
---@field get_look_vector fun(self:RBXLXCFrame):number, number, number
---@field VectorToWorldSpace fun(self:RBXLXCFrame, vector:RBXLXVector3):RBXLXVector3
---@field VectorToObjectSpace fun(self:RBXLXCFrame, vector:RBXLXVector3):RBXLXVector3
---@field PointToWorldSpace fun(self:RBXLXCFrame, point:RBXLXVector3):RBXLXVector3
---@field PointToObjectSpace fun(self:RBXLXCFrame, point:RBXLXVector3):RBXLXVector3
---@field ToWorldSpace fun(self:RBXLXCFrame, frame:RBXLXCFrame):RBXLXCFrame
---@field ToObjectSpace fun(self:RBXLXCFrame, frame:RBXLXCFrame):RBXLXCFrame
---@field Inverse fun(self:RBXLXCFrame):RBXLXCFrame
---@field Lerp fun(self:RBXLXCFrame, other:RBXLXCFrame, alpha:number):RBXLXCFrame

---@class RBXLXCFrameApi
---@field new fun(x?:number|RBXLXVector3, y?:number|RBXLXVector3, z?:number, r00?:number, r01?:number, r02?:number, r10?:number, r11?:number, r12?:number, r20?:number, r21?:number, r22?:number):RBXLXCFrame
---@field identity RBXLXCFrame
---@field fromAxisAngle fun(axis:RBXLXVector3, angle:number):RBXLXCFrame
---@field lookAt fun(at:RBXLXVector3|table, look_at:RBXLXVector3|table, up?:RBXLXVector3|table):RBXLXCFrame
---@field fromMatrix fun(position:RBXLXVector3|table, right_vector:RBXLXVector3|table, up_vector:RBXLXVector3|table, back_vector?:RBXLXVector3|table):RBXLXCFrame
---@field Angles fun(rx:number, ry:number, rz:number):RBXLXCFrame
---@field from_matrix fun(x?:number, y?:number, z?:number, r00?:number, r01?:number, r02?:number, r10?:number, r11?:number, r12?:number, r20?:number, r21?:number, r22?:number):RBXLXCFrame
---@field from_look_vector fun(x:number, y:number, z:number, look_x:number, look_y:number, look_z:number, up_x?:number, up_y?:number, up_z?:number):RBXLXCFrame

---@class RBXScriptSignal
---@field Connect fun(self:RBXScriptSignal, callback:function):RBXScriptConnection
---@field Once fun(self:RBXScriptSignal, callback:function):RBXScriptConnection
---@field Wait fun(self:RBXScriptSignal):...
---@field connect fun(self:RBXScriptSignal, callback:function):RBXScriptConnection
---@field once fun(self:RBXScriptSignal, callback:function):RBXScriptConnection
---@field wait fun(self:RBXScriptSignal):...

---@class RBXSimulationSignal: RBXScriptSignal
---@field Connect fun(self:RBXSimulationSignal, callback:fun(dt:number)):RBXScriptConnection
---@field Once fun(self:RBXSimulationSignal, callback:fun(dt:number)):RBXScriptConnection
---@field connect fun(self:RBXSimulationSignal, callback:fun(dt:number)):RBXScriptConnection
---@field once fun(self:RBXSimulationSignal, callback:fun(dt:number)):RBXScriptConnection

---@alias RBXLXSignal RBXScriptSignal

---@class RBXScriptConnection
---@field Connected boolean
---@field Disconnect fun(self:RBXScriptConnection)
---@field disconnect fun(self:RBXScriptConnection)

---@alias RBXLXConnection RBXScriptConnection

RBXScriptConnection = {}
RBXScriptConnection.__index = RBXScriptConnection

RBXScriptSignal = {}
RBXScriptSignal.__index = RBXScriptSignal

local function unlink_rbx_script_connection(signal, connection)
    if not signal or not connection then
        return
    end
    local previous = connection._prev
    local next_connection = connection._next
    if previous then
        previous._next = next_connection
    elseif signal._head == connection then
        signal._head = next_connection
    end
    if next_connection then
        next_connection._prev = previous
    elseif signal._tail == connection then
        signal._tail = previous
    end
    connection._prev = nil
    connection._next = nil
    connection._signal = nil
    if signal._connection_count and signal._connection_count > 0 then
        signal._connection_count = signal._connection_count - 1
    end
end

local function disconnect_rbx_script_connection(connection, keep_callback)
    if not connection or not connection.Connected then
        return
    end
    connection.Connected = false
    if not keep_callback then
        connection._callback = nil
        connection._waiting_thread = nil
    end
    local signal = connection._signal
    if not signal then
        return
    end
    if signal._firing_depth and signal._firing_depth > 0 then
        signal._dirty = true
    else
        unlink_rbx_script_connection(signal, connection)
    end
end

function RBXScriptConnection:Disconnect()
    disconnect_rbx_script_connection(self, false)
end

RBXScriptConnection.disconnect = RBXScriptConnection.Disconnect

function RBXScriptSignal:_connect(callback, once)
    if self._destroyed then
        error("Cannot connect to a destroyed RBXScriptSignal", 2)
    end
    if type(callback) ~= "function" then
        error("Connect expected a function", 3)
    end
    local connection = setmetatable({
        Connected = true,
        _signal = self,
        _callback = callback,
        _once = once == true,
        _prev = self._tail,
        _next = nil,
    }, RBXScriptConnection)
    if self._tail then
        self._tail._next = connection
    else
        self._head = connection
    end
    self._tail = connection
    self._connection_count = (self._connection_count or 0) + 1
    return connection
end

function RBXScriptSignal:Connect(callback)
    return self:_connect(callback, false)
end

RBXScriptSignal.connect = RBXScriptSignal.Connect

function RBXScriptSignal:Once(callback)
    return self:_connect(callback, true)
end

RBXScriptSignal.once = RBXScriptSignal.Once

function RBXScriptSignal:_compact()
    local connection = self._head
    while connection do
        local next_connection = connection._next
        if not connection.Connected then
            unlink_rbx_script_connection(self, connection)
        end
        connection = next_connection
    end
    self._dirty = false
end

function RBXScriptSignal:_fire(...)
    if self._destroyed then
        return
    end
    self._firing_depth = (self._firing_depth or 0) + 1
    local connection = self._head
    local final_connection = self._tail
    local ok, err = true, nil
    while connection do
        local next_connection = connection._next
        if connection.Connected then
            local callback = connection._callback
            if connection._once then
                disconnect_rbx_script_connection(connection, true)
            end
            if callback then
                ok, err = pcall(callback, ...)
                if connection._once then
                    connection._callback = nil
                    connection._waiting_thread = nil
                end
                if not ok then
                    break
                end
            end
        end
        if connection == final_connection then
            break
        end
        connection = next_connection
    end
    self._firing_depth = self._firing_depth - 1
    if self._firing_depth == 0 and self._dirty then
        self:_compact()
    end
    if not ok then
        error(err, 0)
    end
end

RBXScriptSignal.Fire = RBXScriptSignal._fire

function RBXScriptSignal:Wait()
    if self._destroyed then
        return nil
    end
    local thread, is_main = coroutine.running()
    if not thread or is_main then
        error("RBXScriptSignal:Wait() must be called from a coroutine", 2)
    end
    local connection
    connection = self:_connect(function(...)
        local waiting_thread = connection and connection._waiting_thread
        if waiting_thread and coroutine.status(waiting_thread) ~= "dead" then
            local ok, err = coroutine.resume(waiting_thread, ...)
            if not ok then
                error(err, 0)
            end
        end
    end, true)
    connection._waiting_thread = thread
    return coroutine.yield()
end

RBXScriptSignal.wait = RBXScriptSignal.Wait

function RBXScriptSignal:_disconnect_all(resume_waiters)
    local connection = self._head
    self._head = nil
    self._tail = nil
    self._dirty = false
    self._connection_count = 0
    self._destroyed = true
    while connection do
        local next_connection = connection._next
        connection.Connected = false
        connection._signal = nil
        connection._callback = nil
        connection._prev = nil
        connection._next = nil
        if resume_waiters and connection._waiting_thread and coroutine.status(connection._waiting_thread) ~= "dead" then
            coroutine.resume(connection._waiting_thread)
        end
        connection._waiting_thread = nil
        connection = next_connection
    end
end

function new_rbx_script_signal(owner, name)
    return setmetatable({
        _owner = owner,
        _name = tostring(name or "Signal"),
        _head = nil,
        _tail = nil,
        _connection_count = 0,
        _firing_depth = 0,
        _dirty = false,
        _destroyed = false,
    }, RBXScriptSignal)
end

function fire_rbx_script_signal(signal, ...)
    if signal then
        signal:_fire(...)
    end
end

function cleanup_rbx_script_signal_bucket(bucket)
    if type(bucket) ~= "table" then
        return
    end
    for _, signal in pairs(bucket) do
        if type(signal) == "table" and signal._disconnect_all then
            signal:_disconnect_all(true)
        end
    end
end

INSTANCE_CLASS_SUPERCLASS = {
    DataModel = "ServiceProvider",
    Workspace = "ServiceProvider",
    Lighting = "Instance",
    Atmosphere = "Instance",
    Light = "Instance",
    PointLight = "Light",
    SpotLight = "Light",
    SurfaceLight = "Light",
    Attachment = "Instance",
    Constraint = "Instance",
    RopeConstraint = "Constraint",
    RodConstraint = "Constraint",
    DataModelMesh = "Instance",
    FileMesh = "DataModelMesh",
    SpecialMesh = "FileMesh",
    BevelMesh = "DataModelMesh",
    BlockMesh = "BevelMesh",
    CylinderMesh = "BevelMesh",
    FaceInstance = "Instance",
    Decal = "FaceInstance",
    Texture = "Decal",
    RunService = "Instance",
    Folder = "Instance",
    Model = "Instance",
    WorldModel = "Model",
    Camera = "Instance",
    BasePart = "Instance",
    Part = "BasePart",
    SpawnLocation = "Part",
    WedgePart = "BasePart",
    CornerWedgePart = "BasePart",
    TrussPart = "BasePart",
    Seat = "Part",
    VehicleSeat = "Seat",
    MeshPart = "BasePart",
    UnionOperation = "BasePart",
    PartOperation = "BasePart",
    NegateOperation = "BasePart",
    SurfaceAppearance = "Instance",
}

---@class RBXLXPhysicalProperties
---@field density number|nil
---@field friction number|nil
---@field elasticity number|nil
---@field friction_weight number|nil
---@field elasticity_weight number|nil
---@field acoustic_absorption number|nil
---@field friction_combine string|nil
---@field elasticity_combine string|nil

---@class RBXLXInstance
---@field Name string
---@field ClassName string
---@field Parent RBXLXInstance|RBXDataModel|nil
---@field Changed RBXLXSignal
---@field ChildAdded RBXLXSignal
---@field ChildRemoved RBXLXSignal
---@field DescendantAdded RBXLXSignal
---@field AncestryChanged RBXLXSignal
---@field Destroying RBXLXSignal
---@field IsA fun(self:RBXLXInstance, class_name:string):boolean
---@field GetChildren fun(self:RBXLXInstance):RBXLXInstance[]
---@field GetDescendants fun(self:RBXLXInstance):RBXLXInstance[]
---@field FindFirstChild fun(self:RBXLXInstance, name:string, recursive?:boolean):RBXLXInstance|nil
---@field WaitForChild fun(self:RBXLXInstance, name:string):RBXLXInstance|nil
---@field Clone fun(self:RBXLXInstance):RBXLXInstance|nil
---@field Destroy fun(self:RBXLXInstance)
---@field GetPropertyChangedSignal fun(self:RBXLXInstance, property_name:string):RBXLXSignal

---@class RBXLXPart: RBXLXInstance
---@field Name string
---@field ClassName string
---@field Shape string|RBXEnumItem
---@field CFrame RBXLXCFrame
---@field Position RBXLXVector3
---@field Size RBXLXVector3
---@field Color RBXLXColor3
---@field BrickColor table
---@field Transparency number
---@field Reflectance number
---@field Anchored boolean
---@field CanCollide boolean
---@field CanTouch boolean
---@field CanQuery boolean
---@field CollisionGroup string
---@field Massless boolean
---@field RootPriority number
---@field CustomPhysicalProperties RBXLXPhysicalProperties|nil
---@field CurrentPhysicalProperties RBXLXPhysicalProperties
---@field Mass number
---@field AssemblyMass number
---@field AssemblyCenterOfMass RBXLXVector3
---@field AssemblyRootPart RBXLXPart|nil
---@field AssemblyShapeApproximation string|nil
---@field Velocity RBXLXVector3
---@field RotVelocity RBXLXVector3
---@field AssemblyLinearVelocity RBXLXVector3
---@field AssemblyAngularVelocity RBXLXVector3
---@field Material number|RBXEnumItem
---@field MaterialVariant string|nil
---@field TopSurface number|string|RBXEnumItem
---@field BottomSurface number|string|RBXEnumItem
---@field LeftSurface number|string|RBXEnumItem
---@field RightSurface number|string|RBXEnumItem
---@field FrontSurface number|string|RBXEnumItem
---@field BackSurface number|string|RBXEnumItem
---@field TopSurfaceInput number
---@field BottomSurfaceInput number
---@field LeftSurfaceInput number
---@field RightSurfaceInput number
---@field FrontSurfaceInput number
---@field BackSurfaceInput number
---@field TopParamA number|nil
---@field TopParamB number|nil
---@field BottomParamA number|nil
---@field BottomParamB number|nil
---@field LeftParamA number|nil
---@field LeftParamB number|nil
---@field RightParamA number|nil
---@field RightParamB number|nil
---@field FrontParamA number|nil
---@field FrontParamB number|nil
---@field BackParamA number|nil
---@field BackParamB number|nil
---@field MeshId string|nil
---@field TextureContent string|nil
---@field TextureId string|nil
---@field UsePartColor boolean
---@field DoubleSided boolean
---@field SmoothingAngle number|nil
---@field RenderFidelity string|number|nil
---@field TriangleCount number|nil
---@field MeshSize RBXLXVector3|nil
---@field MeshVertexColor RBXLXColor3|nil
---@field SurfaceAppearance table|nil
---@field SurfaceGuis table
---@field Changed RBXLXSignal
---@field Destroy fun(self:RBXLXPart)
---@field Clone fun(self:RBXLXPart):RBXLXPart|nil
---@field GetPropertySchema fun(self:RBXLXPart):table<string,string>
---@field GetMass fun(self:RBXLXPart):number
---@field GetPropertyChangedSignal fun(self:RBXLXPart, property_name:string):RBXLXSignal
---@field ApplyImpulse fun(self:RBXLXPart, impulse:RBXLXVector3)
---@field ApplyImpulseAtPosition fun(self:RBXLXPart, impulse:RBXLXVector3, position:RBXLXVector3)
---@field ApplyAngularImpulse fun(self:RBXLXPart, impulse:RBXLXVector3)

---@class RBXLXPartProperties
---@field Parent RBXLXInstance|nil
---@field Name string|nil
---@field Shape string|RBXEnumItem|nil
---@field CFrame RBXLXCFrame|nil
---@field Position RBXLXVector3|nil
---@field Size RBXLXVector3|nil
---@field Color RBXLXColor3|nil
---@field Transparency number|nil
---@field Reflectance number|nil
---@field Anchored boolean|nil
---@field CanCollide boolean|nil
---@field CanTouch boolean|nil
---@field CanQuery boolean|nil
---@field CollisionGroup string|nil
---@field Massless boolean|nil
---@field RootPriority number|nil
---@field CustomPhysicalProperties RBXLXPhysicalProperties|nil
---@field Velocity RBXLXVector3|nil
---@field RotVelocity RBXLXVector3|nil
---@field AssemblyLinearVelocity RBXLXVector3|nil
---@field AssemblyAngularVelocity RBXLXVector3|nil
---@field Material number|RBXEnumItem|nil
---@field MaterialVariant string|nil
---@field TopSurface number|string|RBXEnumItem|nil
---@field BottomSurface number|string|RBXEnumItem|nil
---@field LeftSurface number|string|RBXEnumItem|nil
---@field RightSurface number|string|RBXEnumItem|nil
---@field FrontSurface number|string|RBXEnumItem|nil
---@field BackSurface number|string|RBXEnumItem|nil
---@field MeshId string|nil
---@field TextureContent string|nil
---@field TextureId string|nil
---@field UsePartColor boolean|nil
---@field DoubleSided boolean|nil
---@field SmoothingAngle number|nil
---@field RenderFidelity string|number|nil
---@field TriangleCount number|nil
---@field SurfaceAppearance table|nil

---@class RBXLXPartExplorer
---@field Get fun(self:RBXLXPartExplorer, index_or_name:integer|string):RBXLXPart|nil
---@field GetAll fun(self:RBXLXPartExplorer):RBXLXPart[]
---@field FindFirstChild fun(self:RBXLXPartExplorer, name:string):RBXLXPart|nil
---@field Count fun(self:RBXLXPartExplorer):integer
---@field GetPropertySchema fun(self:RBXLXPartExplorer):table<string,string>

---@class RBXLXBodyForce: RBXLXInstance
---@field Force RBXLXVector3

---@class RBXLXBodyGyro: RBXLXInstance
---@field P number|nil Proportional torque gain
---@field D number|nil Angular damping gain
---@field CFrame RBXLXCFrame|nil
---@field MaxTorque RBXLXVector3|nil

---@class RBXLXBodyForceProperties
---@field Name string|nil
---@field Parent RBXLXInstance|nil
---@field Force RBXLXVector3|nil

---@class RBXLXRaycastParams
---@field FilterType RBXEnumItem|string
---@field FilterDescendantsInstances RBXLXInstance[]
---@field IgnoreWater boolean
---@field RespectCanCollide boolean
---@field CollisionGroup string
---@field AddToFilter fun(self:RBXLXRaycastParams, instances:RBXLXInstance|RBXLXInstance[])

---@class RBXLXRaycastResult
---@field Instance RBXLXPart
---@field Position RBXLXVector3
---@field Normal RBXLXVector3
---@field Distance number
---@field Material RBXEnumItem|nil

---@class RBXLXRay
---@field Origin RBXLXVector3
---@field Direction RBXLXVector3
---@field Unit RBXLXRay
---@field ClosestPoint fun(self:RBXLXRay, point:RBXLXVector3):RBXLXVector3
---@field Distance fun(self:RBXLXRay, point:RBXLXVector3):number

---@class RBXLXRegion3
---@field CFrame RBXLXCFrame
---@field Size RBXLXVector3

---@class RBXLXWorkspace: RBXLXInstance
---@field Name string
---@field ClassName string
---@field Gravity number
---@field FallenPartsDestroyHeight number
---@field CurrentCamera RBXLXCamera
---@field Raycast fun(self:RBXLXWorkspace, origin:RBXLXVector3, direction:RBXLXVector3, params?:RBXLXRaycastParams):RBXLXRaycastResult|nil
---@field FindPartsInRegion3 fun(self:RBXLXWorkspace, region:RBXLXRegion3, ignore?:RBXLXInstance|RBXLXInstance[], max_parts?:integer):RBXLXPart[]
---@field FindFirstChild fun(self:RBXLXWorkspace, name:string, recursive?:boolean):RBXLXInstance|nil
---@field GetChildren fun(self:RBXLXWorkspace):RBXLXInstance[]
---@field GetDescendants fun(self:RBXLXWorkspace):RBXLXInstance[]
---@field GetPropertySchema fun(self:RBXLXWorkspace):table<string,string>

---@class RBXLXLighting: RBXLXInstance

---@class RBXLXAtmosphere: RBXLXInstance
---@field Density number
---@field Offset number
---@field Color RBXLXColor3
---@field Decay RBXLXColor3
---@field Haze number
---@field Glare number

---@class RBXLXSurfaceAppearance: RBXLXInstance
---@field AlphaMode table|string|number
---@field Color RBXLXColor3
---@field ColorMap string
---@field ColorMapContent string
---@field EmissiveMaskContent string
---@field EmissiveStrength number
---@field EmissiveTint RBXLXColor3
---@field MetalnessMap string
---@field MetalnessMapContent string
---@field NormalMap string
---@field NormalMapContent string
---@field ResampleMode table|string|number
---@field RoughnessMap string
---@field RoughnessMapContent string

---@class RBXLXFaceInstance: RBXLXInstance
---@field Face table|string
---@field Color3 RBXLXColor3
---@field Transparency number
---@field ZIndex integer
---@field Rotation number
---@field UVOffset table
---@field UVScale table

---@class RBXLXDecal: RBXLXFaceInstance
---@field Texture string
---@field TextureContent string
---@field ColorMap string
---@field ColorMapContent string

---@class RBXLXTexture: RBXLXDecal
---@field StudsPerTileU number
---@field StudsPerTileV number
---@field OffsetStudsU number
---@field OffsetStudsV number

---@class RBXLXDataModelMesh: RBXLXInstance
---@field Scale RBXLXVector3
---@field Offset RBXLXVector3
---@field VertexColor RBXLXVector3

---@class RBXLXFileMesh: RBXLXDataModelMesh
---@field MeshId string
---@field MeshContent string
---@field TextureId string
---@field TextureContent string

---@class RBXLXSpecialMesh: RBXLXFileMesh
---@field MeshType table|string

---@class RBXLXBlockMesh: RBXLXDataModelMesh

---@class RBXLXCylinderMesh: RBXLXDataModelMesh

---@class RBXLXRunService: RBXLXInstance
---@field Heartbeat RBXScriptSignal
---@field Stepped RBXScriptSignal
---@field PreSimulation RBXSimulationSignal
---@field FixedHeartbeat RBXSimulationSignal Wave fixed-step extension; fires once per admitted physics substep
---@field RenderStepped RBXScriptSignal

---@class RBXLXCamera: RBXLXInstance
---@field Name string
---@field ClassName string
---@field CFrame RBXLXCFrame
---@field Focus RBXLXCFrame
---@field CameraType table|string
---@field FieldOfView number
---@field ViewportSize RBXLXVector3
---@field ViewportPointToRay fun(self:RBXLXCamera, x:number, y:number, depth?:number):RBXLXRay
---@field ScreenPointToRay fun(self:RBXLXCamera, x:number, y:number, depth?:number):RBXLXRay

---@class RBXDataModel: RBXLXInstance
---@field Name string
---@field ClassName string
---@field Workspace RBXLXWorkspace
---@field Lighting RBXLXLighting
---@field RunService RBXLXRunService
---@field Instance RBXLXInstanceApi
---@field set_camera_cframe fun(self:RBXDataModel, cframe:RBXLXCFrame)
---@field get_camera_cframe fun(self:RBXDataModel):RBXLXCFrame
---@field on_display_resized fun(self:RBXDataModel, width:number, height:number)
---@field load_map fun(self:RBXDataModel, map_path:string):boolean, table|string
---@field load_map_async fun(self:RBXDataModel, map_path:string, options?:table):boolean, table|string
---@field is_map_loading fun(self:RBXDataModel):boolean
---@field get_map_load_status fun(self:RBXDataModel):table
---@field update fun(self:RBXDataModel, dt:number)
---@field draw fun(self:RBXDataModel)
---@field get_stats fun(self:RBXDataModel):table
---@field get_debug_report fun(self:RBXDataModel):table
---@field needs_redraw fun(self:RBXDataModel):boolean
---@field render_to_canvas fun(self:RBXDataModel, width:number, height:number, options?:table):any, table|string
---@field draw_to_rect fun(self:RBXDataModel, x:number, y:number, width:number, height:number, options?:table):any, table|string
---@field capture_frame fun(self:RBXDataModel, width:number, height:number, options?:table):any, table|string
---@field GetService fun(self:RBXDataModel, service_name:string):RBXLXInstance
---@field FindService fun(self:RBXDataModel, service_name:string):RBXLXInstance|nil
---@field FindFirstChild fun(self:RBXDataModel, name:string, recursive?:boolean):RBXLXInstance|nil
---@field GetChildren fun(self:RBXDataModel):RBXLXInstance[]
---@field GetDescendants fun(self:RBXDataModel):RBXLXInstance[]

---@class RBXOptions
---@field physics_budget_ms? number CPU cutoff per update; 0 preserves catch-up work without a wall-clock deadline. Fixed step/frame caps still apply
---@field map_path string|nil
---@field fov_degrees number|nil
---@field follow_display_settings boolean|nil
---@field quality 'performance'|'balanced'|'quality'|nil
---@field allow_remote_assets boolean|nil
---@field async_loading boolean|nil
---@field simulate_physics boolean|nil
---@field virtual_resolution RBXLXVector3|table|nil
---@field letterbox_resolution RBXLXVector3|table|nil
---@field asset_root string|nil
---@field debug_deprecation_warnings boolean|nil
---@field retain_mesh_transforms boolean|nil
---@field use_authored_gui_fonts boolean|nil Resolve serialized FontFace.cachedFaceId locally; default false retains legacy GUI font

---@deprecated Use RBXDataModel. This alias stays for one migration cycle
---@class RBX
---@field Part RBXLXPartExplorer
---@field Instance RBXLXInstanceApi
---@field Workspace RBXLXWorkspace
---@field CFrame RBXLXCFrameApi
---@field Vector3 RBXLXVector3Api
---@field Color3 RBXLXColor3Api
---@field Enum RBXEnum
---@field load_map fun(self:RBX, map_path:string):boolean, table|string
---@field load_map_async fun(self:RBX, map_path:string, options?:table):boolean, table|string
---@field is_map_loading fun(self:RBX):boolean
---@field get_map_load_status fun(self:RBX):table
---@field set_camera_cframe fun(self:RBX, cframe:RBXLXCFrame)
---@field get_camera_cframe fun(self:RBX):RBXLXCFrame
---@field update fun(self:RBX, dt:number)
---@field draw fun(self:RBX)
---@field get_stats fun(self:RBX):table
---@field get_debug_report fun(self:RBX):table
---@field needs_redraw fun(self:RBX):boolean
---@field render_to_canvas fun(self:RBX, width:number, height:number, options?:table):any, table|string
---@field draw_to_rect fun(self:RBX, x:number, y:number, width:number, height:number, options?:table):any, table|string
---@field capture_frame fun(self:RBX, width:number, height:number, options?:table):any, table|string

RBX = {}

-- Authored-space defaults for a newly constructed Atmosphere. shared by the
-- public facade, parser fallbacks, and the bounded shader model so those three
-- entry points cannot drift. current Roblox API reflection (build 731) reports
-- these exact values
RBX._ATMOSPHERE_DEFAULTS = {
    Density = 0.395000011,
    Offset = 0,
    Color = { 0.7843, 0.6667, 0.4235 },
    Decay = { 0.3608, 0.2353, 0.0549 },
    Haze = 0,
    Glare = 0,
}

-- Native authored defaults for a newly-created SurfaceAppearance. Content
-- values remain strings at this facade boundary, the asset layer is solely
-- responsible for resolving local, asset-id, and remote references
RBX._SURFACE_APPEARANCE_DEFAULTS = {
    AlphaMode = 0,
    Color = { 1, 1, 1 },
    EmissiveStrength = 1,
    EmissiveTint = { 1, 1, 1 },
    ResampleMode = 0,
}
RBX.__index = RBX

bitops = bit or bit32
if not bitops then
    error("rbx module requires bit or bit32 library")
end

function RBX._time_seconds()
    return love.timer.getTime()
end

band = bitops.band
bxor = bitops.bxor
rshift = bitops.rshift
lshift = bitops.lshift
BRICK_COLORS = nil

RBX.BINARY_SIGNATURE = "<roblox!\137\255\r\n\26\n"

RBX.SUPPORTED_MAP_EXTENSIONS = {
    [".rbxl"] = true,
    [".rbxlx"] = true,
}

RBX.FACE_ENUM = {
    [0] = "Right",
    [1] = "Top",
    [2] = "Back",
    [3] = "Left",
    [4] = "Bottom",
    [5] = "Front",
    aliases = {
        right = "Right",
        top = "Top",
        back = "Back",
        left = "Left",
        bottom = "Bottom",
        front = "Front",
    },
}

RBX.PART_SHAPE_ENUM = {
    [0] = "Ball",
    [1] = "Block",
    [2] = "Cylinder",
    [3] = "Wedge",
    [4] = "CornerWedge",
    aliases = {
        block = "Block",
        brick = "Block",
        ball = "Ball",
        sphere = "Ball",
        cylinder = "Cylinder",
        wedge = "Wedge",
        cornerwedge = "CornerWedge",
        ["corner_wedge"] = "CornerWedge",
        truss = "Truss",
    },
}

RBX.SPECIAL_MESH_TYPE_ENUM = {
    [0] = "Head",
    [1] = "Torso",
    [2] = "Wedge",
    [3] = "Sphere",
    [4] = "Cylinder",
    [5] = "FileMesh",
    [6] = "Brick",
    [7] = "Prism",
    [8] = "Pyramid",
    [9] = "ParallelRamp",
    [10] = "RightAngleRamp",
    [11] = "CornerWedge",
    aliases = {
        head = "Head",
        torso = "Torso",
        wedge = "Wedge",
        sphere = "Sphere",
        cylinder = "Cylinder",
        filemesh = "FileMesh",
        brick = "Brick",
        prism = "Prism",
        pyramid = "Pyramid",
        parallelramp = "ParallelRamp",
        ["parallel_ramp"] = "ParallelRamp",
        rightangleramp = "RightAngleRamp",
        ["right_angle_ramp"] = "RightAngleRamp",
        cornerwedge = "CornerWedge",
        ["corner_wedge"] = "CornerWedge",
    },
    primitive_shapes = {
        Head = "Ball",
        Torso = "Block",
        Wedge = "Wedge",
        Sphere = "Ball",
        Cylinder = "Cylinder",
        Brick = "Block",
        -- these five legacy MeshType members were never implemented by Roblox
        -- and make the parent part submit no render geometry. they are distinct
        -- from the real CornerWedgePart class, which remains fully supported
        Prism = "None",
        Pyramid = "None",
        ParallelRamp = "None",
        RightAngleRamp = "None",
        CornerWedge = "None",
    },
}

RBX.SURFACE_TYPE_ENUM = {
    [0] = "Smooth",
    [1] = "Glue",
    [2] = "Weld",
    [3] = "Studs",
    [4] = "Inlet",
    [5] = "Universal",
    [6] = "Hinge",
    [7] = "Motor",
    [8] = "SteppingMotor",
    [9] = "SmoothNoOutlines",
    aliases = {
        smooth = "Smooth",
        glue = "Glue",
        weld = "Weld",
        studs = "Studs",
        inlet = "Inlet",
        inlets = "Inlet",
        universal = "Universal",
        hinge = "Hinge",
        motor = "Motor",
        steppingmotor = "SteppingMotor",
        smoothnooutlines = "SmoothNoOutlines",
    },
}

RBX.TEXT_X_ALIGNMENT_ENUM = {
    [0] = "Left",
    [1] = "Right",
    [2] = "Center",
}

RBX.TEXT_Y_ALIGNMENT_ENUM = {
    [0] = "Top",
    [1] = "Center",
    [2] = "Bottom",
}

SURFACE_PROPERTY_FIELDS = {
    { property = "TopSurface",    face = "Top",    parsed_key = "top_surface" },
    { property = "BottomSurface", face = "Bottom", parsed_key = "bottom_surface" },
    { property = "LeftSurface",   face = "Left",   parsed_key = "left_surface" },
    { property = "RightSurface",  face = "Right",  parsed_key = "right_surface" },
    { property = "FrontSurface",  face = "Front",  parsed_key = "front_surface" },
    { property = "BackSurface",   face = "Back",   parsed_key = "back_surface" },
}

RBX.SKIPPED_WORKSPACE_SUBTREE_NAMES = {
    temp = true,
    testmap = true,
}

RBX.CFRAME_SPECIAL_ORIENTATIONS = {
    [2] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    [3] = { 1, 0, 0, 0, 0, -1, 0, 1, 0 },
    [5] = { 1, 0, 0, 0, -1, 0, 0, 0, -1 },
    [6] = { 1, 0, 0, 0, 0, 1, 0, -1, 0 },
    [7] = { 0, 1, 0, 1, 0, 0, 0, 0, -1 },
    [9] = { 0, 0, 1, 1, 0, 0, 0, 1, 0 },
    [10] = { 0, -1, 0, 1, 0, 0, 0, 0, 1 },
    [12] = { 0, 0, -1, 1, 0, 0, 0, -1, 0 },
    [13] = { 0, 1, 0, 0, 0, 1, 1, 0, 0 },
    [14] = { 0, 0, -1, 0, 1, 0, 1, 0, 0 },
    [16] = { 0, -1, 0, 0, 0, -1, 1, 0, 0 },
    [17] = { 0, 0, 1, 0, -1, 0, 1, 0, 0 },
    [20] = { -1, 0, 0, 0, 1, 0, 0, 0, -1 },
    [21] = { -1, 0, 0, 0, 0, 1, 0, 1, 0 },
    [23] = { -1, 0, 0, 0, -1, 0, 0, 0, 1 },
    [24] = { -1, 0, 0, 0, 0, -1, 0, -1, 0 },
    [25] = { 0, 1, 0, -1, 0, 0, 0, 0, 1 },
    [27] = { 0, 0, -1, -1, 0, 0, 0, 1, 0 },
    [28] = { 0, -1, 0, -1, 0, 0, 0, 0, -1 },
    [30] = { 0, 0, 1, -1, 0, 0, 0, -1, 0 },
    [31] = { 0, 1, 0, 0, 0, -1, -1, 0, 0 },
    [32] = { 0, 0, 1, 0, 1, 0, -1, 0, 0 },
    [34] = { 0, -1, 0, 0, 0, 1, -1, 0, 0 },
    [35] = { 0, 0, -1, 0, -1, 0, -1, 0, 0 },
}

function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

function round_dimension(value)
    local number = tonumber(value)
    if number == nil then
        return nil
    end
    return math.max(1, math.floor(number + 0.5))
end

function normalize_resolution_value(value)
    if value == nil then
        return nil
    end

    if type(value) == "string" then
        local w, h = value:match("^(%d+)x(%d+)$")
        w = round_dimension(w)
        h = round_dimension(h)
        if w and h then
            return { x = w, y = h }
        end
        return nil
    end

    if type(value) ~= "table" then
        return nil
    end

    local w = round_dimension(value.x or value.width or value.w or value[1])
    local h = round_dimension(value.y or value.height or value.h or value[2])
    if not w or not h then
        return nil
    end

    return { x = w, y = h }
end

function RBX._clone_resolution_value(value)
    if not value then
        return nil
    end
    return { x = value.x, y = value.y }
end

function RBX._clone_string_list(values)
    if type(values) ~= "table" or #values == 0 then
        return nil
    end

    local copy = {}
    for i = 1, #values do
        copy[i] = values[i]
    end
    return copy
end

function RBX._get_active_canvas_target()
    local canvas = love.graphics.getCanvas()
    while type(canvas) == "table" do
        canvas = canvas[1]
    end
    return canvas
end

function RBX._get_active_surface_dimensions()
    local canvas = RBX._get_active_canvas_target()
    local width, height
    if canvas and canvas.getWidth and canvas.getHeight then
        width, height = canvas:getWidth(), canvas:getHeight()
    else
        width, height = love.graphics.getDimensions()
    end
    return round_dimension(width) or 1, round_dimension(height) or 1
end

DEBUG_FONT_CACHE = {}

function RBX._get_debug_font(size)
    size = math.max(8, round_dimension(size) or 12)
    local cached = DEBUG_FONT_CACHE[size]
    if cached then
        return cached
    end

    local ok, font = pcall(love.graphics.newFont, size)
    if not ok or not font then
        return love.graphics.getFont()
    end
    if font.setFilter then
        font:setFilter("nearest", "nearest")
    end

    DEBUG_FONT_CACHE[size] = font
    return font
end

function dot(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx
end

function RBX._axis_sign(value)
    return (tonumber(value) or 1) < 0 and -1 or 1
end

function RBX._basis_handedness_sign(rx, ry, rz, ux, uy, uz, bx, by, bz)
    local cx, cy, cz = cross(rx, ry, rz, ux, uy, uz)
    local determinant = dot(cx, cy, cz, bx, by, bz)
    if determinant < 0 then
        return -1
    end
    return 1
end

-- closed primitive rows carry a basis in slots 4..12 and a local scale in
-- slots 13..15.  their product is the exact transform used by both the
-- instanced shader and the CPU-baked LOVE fallback, so its determinant is the
-- only safe source of face-cull parity.  combine signs rather than magnitudes:
-- very large/small authored scales must not overflow/underflow an otherwise
-- valid transform into the collapsed class
local function finite_closed_primitive_component(value)
    return value ~= nil
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function RBX._classify_closed_primitive_instance_row(row)
    if row == nil then
        return "collapsed"
    end

    local rx, ry, rz = tonumber(row[4]), tonumber(row[5]), tonumber(row[6])
    local ux, uy, uz = tonumber(row[7]), tonumber(row[8]), tonumber(row[9])
    local bx, by, bz = tonumber(row[10]), tonumber(row[11]), tonumber(row[12])
    local sx, sy, sz = tonumber(row[13]), tonumber(row[14]), tonumber(row[15])
    if not finite_closed_primitive_component(rx)
        or not finite_closed_primitive_component(ry)
        or not finite_closed_primitive_component(rz)
        or not finite_closed_primitive_component(ux)
        or not finite_closed_primitive_component(uy)
        or not finite_closed_primitive_component(uz)
        or not finite_closed_primitive_component(bx)
        or not finite_closed_primitive_component(by)
        or not finite_closed_primitive_component(bz)
        or not finite_closed_primitive_component(sx)
        or not finite_closed_primitive_component(sy)
        or not finite_closed_primitive_component(sz) then
        return "collapsed"
    end

    local cx, cy, cz = cross(rx, ry, rz, ux, uy, uz)
    local basis_determinant = dot(cx, cy, cz, bx, by, bz)
    if not finite_closed_primitive_component(basis_determinant)
        or basis_determinant == 0
        or sx == 0 or sy == 0 or sz == 0 then
        return "collapsed"
    end
    local sign = basis_determinant < 0 and -1 or 1
    if sx < 0 then sign = -sign end
    if sy < 0 then sign = -sign end
    if sz < 0 then sign = -sign end
    return sign < 0 and "negative" or "positive"
end

function RBX._summarize_closed_primitive_instance_rows(rows)
    local homogeneous = nil
    for index = 1, #(rows or {}) do
        local handedness =
            RBX._classify_closed_primitive_instance_row(rows[index])
        if handedness == "collapsed" then
            return "collapsed"
        end
        if homogeneous == nil then
            homogeneous = handedness
        elseif homogeneous ~= handedness then
            return "mixed"
        end
    end
    return homogeneous or "collapsed"
end

function RBX._closed_primitive_batch_key(shape_name, handedness)
    local suffix = handedness == "positive" and "p"
        or (handedness == "negative" and "n" or "0")
    return tostring(shape_name or "Block") .. "|" .. suffix
end

function RBX._closed_primitive_shape_name_from_batch_key(batch_key)
    local shape_name = type(batch_key) == "string"
        and batch_key:match("^(.-)|[pn0]$") or nil
    return shape_name or batch_key
end

function normalize(x, y, z)
    local length = math.sqrt(x * x + y * y + z * z)
    if length <= 1e-8 then
        return 0, 0, 0, 0
    end
    return x / length, y / length, z / length, length
end

function normalize_or_fallback(x, y, z, fx, fy, fz)
    local nx, ny, nz = normalize(x, y, z)
    if nx == 0 and ny == 0 and nz == 0 then
        return fx, fy, fz
    end
    return nx, ny, nz
end

-- both builders: optional out table fills in place, no per-frame alloc
function RBX._make_view_matrix(px, py, pz, tx, ty, tz, upx, upy, upz, out)
    local zx, zy, zz = normalize_or_fallback(px - tx, py - ty, pz - tz, 0, 0, 1)
    local xx, xy, xz = normalize(cross(upx, upy, upz, zx, zy, zz))
    if xx == 0 and xy == 0 and xz == 0 then
        local fallback_x,fallback_y,fallback_z=cross(0,0,1,zx,zy,zz)
        xx, xy, xz = normalize_or_fallback(fallback_x,fallback_y,fallback_z,1,0,0)
    end
    local yx, yy, yz = cross(zx, zy, zz, xx, xy, xz)

    local m = out or {}
    m[1], m[2], m[3], m[4] = xx, xy, xz, -dot(xx, xy, xz, px, py, pz)
    m[5], m[6], m[7], m[8] = yx, yy, yz, -dot(yx, yy, yz, px, py, pz)
    m[9], m[10], m[11], m[12] = zx, zy, zz, -dot(zx, zy, zz, px, py, pz)
    m[13], m[14], m[15], m[16] = 0, 0, 0, 1
    return m
end

function RBX._make_projection_matrix(fov, near_clip, far_clip, aspect_ratio, flip_y, out)
    local top = near_clip * math.tan(fov * 0.5)
    local bottom = -top
    local right = top * aspect_ratio
    local left = -right
    local y_scale = 2 * near_clip / (top - bottom)
    if flip_y == nil then
        flip_y = 1
    end
    local m = out or {}
    m[1], m[2], m[3], m[4] = 2 * near_clip / (right - left), 0, (right + left) / (right - left), 0
    m[5], m[6], m[7], m[8] = 0, y_scale * flip_y, (top + bottom) / (top - bottom), 0
    m[9], m[10], m[11], m[12] =
        0, 0, -(far_clip + near_clip) / (far_clip - near_clip), -(2 * far_clip * near_clip) / (far_clip - near_clip)
    m[13], m[14], m[15], m[16] = 0, 0, -1, 0
    return m
end

function transform_point4(matrix, x, y, z, w)
    w = w or 1
    return matrix[1] * x + matrix[2] * y + matrix[3] * z + matrix[4] * w,
        matrix[5] * x + matrix[6] * y + matrix[7] * z + matrix[8] * w,
        matrix[9] * x + matrix[10] * y + matrix[11] * z + matrix[12] * w,
        matrix[13] * x + matrix[14] * y + matrix[15] * z + matrix[16] * w
end

function multiply_matrices(a, b)
    local out = {}
    for row = 0, 3 do
        local row_offset = row * 4
        for col = 1, 4 do
            out[row_offset + col] =
                a[row_offset + 1] * b[col] +
                a[row_offset + 2] * b[col + 4] +
                a[row_offset + 3] * b[col + 8] +
                a[row_offset + 4] * b[col + 12]
        end
    end
    return out
end

function RBX._is_finite_number(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function RBX._matrix_is_finite(matrix)
    if type(matrix) ~= "table" then
        return false
    end
    for index = 1, 16 do
        if not RBX._is_finite_number(matrix[index]) then
            return false
        end
    end
    return true
end

function RBX._bounds_are_finite(bounds)
    if type(bounds) ~= "table" then
        return false
    end
    local min_x = bounds.min_x
    local min_y = bounds.min_y
    local min_z = bounds.min_z
    local max_x = bounds.max_x
    local max_y = bounds.max_y
    local max_z = bounds.max_z
    return RBX._is_finite_number(min_x)
        and RBX._is_finite_number(min_y)
        and RBX._is_finite_number(min_z)
        and RBX._is_finite_number(max_x)
        and RBX._is_finite_number(max_y)
        and RBX._is_finite_number(max_z)
        and min_x <= max_x
        and min_y <= max_y
        and min_z <= max_z
end

function RBX._frustum_planes_are_valid(planes)
    if type(planes) ~= "table" or #planes < 6 then
        return false
    end
    for index = 1, 6 do
        local plane = planes[index]
        if type(plane) ~= "table"
            or plane.invalid == true
            or not RBX._is_finite_number(plane.a)
            or not RBX._is_finite_number(plane.b)
            or not RBX._is_finite_number(plane.c)
            or not RBX._is_finite_number(plane.d) then
            return false
        end
    end
    return true
end

function normalize_plane(a, b, c, d)
    if not RBX._is_finite_number(a)
        or not RBX._is_finite_number(b)
        or not RBX._is_finite_number(c)
        or not RBX._is_finite_number(d) then
        return { a = 0, b = 0, c = 0, d = 0, invalid = true }
    end
    local length = math.sqrt(a * a + b * b + c * c)
    if length <= 1e-8 or not RBX._is_finite_number(length) then
        return { a = 0, b = 0, c = 0, d = 0, invalid = true }
    end

    return {
        a = a / length,
        b = b / length,
        c = c / length,
        d = d / length,
    }
end

function extract_frustum_planes(view_projection)
    if not RBX._matrix_is_finite(view_projection) then
        return nil
    end
    return {
        normalize_plane(
            view_projection[13] + view_projection[1],
            view_projection[14] + view_projection[2],
            view_projection[15] + view_projection[3],
            view_projection[16] + view_projection[4]
        ),
        normalize_plane(
            view_projection[13] - view_projection[1],
            view_projection[14] - view_projection[2],
            view_projection[15] - view_projection[3],
            view_projection[16] - view_projection[4]
        ),
        normalize_plane(
            view_projection[13] + view_projection[5],
            view_projection[14] + view_projection[6],
            view_projection[15] + view_projection[7],
            view_projection[16] + view_projection[8]
        ),
        normalize_plane(
            view_projection[13] - view_projection[5],
            view_projection[14] - view_projection[6],
            view_projection[15] - view_projection[7],
            view_projection[16] - view_projection[8]
        ),
        normalize_plane(
            view_projection[13] + view_projection[9],
            view_projection[14] + view_projection[10],
            view_projection[15] + view_projection[11],
            view_projection[16] + view_projection[12]
        ),
        normalize_plane(
            view_projection[13] - view_projection[9],
            view_projection[14] - view_projection[10],
            view_projection[15] - view_projection[11],
            view_projection[16] - view_projection[12]
        ),
    }
end

function bounds_outside_frustum(bounds, planes, plane_count)
    if not bounds or not planes then
        return false
    end
    if not RBX._bounds_are_finite(bounds) or not RBX._frustum_planes_are_valid(planes) then
        return false
    end

    local cx = bounds.center_x
    local cy = bounds.center_y
    local cz = bounds.center_z
    local ex = bounds.extent_x
    local ey = bounds.extent_y
    local ez = bounds.extent_z
    if not RBX._is_finite_number(cx) or not RBX._is_finite_number(cy) or not RBX._is_finite_number(cz) then
        cx = (bounds.min_x + bounds.max_x) * 0.5
        cy = (bounds.min_y + bounds.max_y) * 0.5
        cz = (bounds.min_z + bounds.max_z) * 0.5
    end
    if not RBX._is_finite_number(ex) or not RBX._is_finite_number(ey) or not RBX._is_finite_number(ez) then
        ex = (bounds.max_x - bounds.min_x) * 0.5
        ey = (bounds.max_y - bounds.min_y) * 0.5
        ez = (bounds.max_z - bounds.min_z) * 0.5
    end
    if not RBX._is_finite_number(cx)
        or not RBX._is_finite_number(cy)
        or not RBX._is_finite_number(cz)
        or not RBX._is_finite_number(ex)
        or not RBX._is_finite_number(ey)
        or not RBX._is_finite_number(ez) then
        return false
    end

    for i = 1, plane_count or #planes do
        local plane = planes[i]
        local radius = math.abs(plane.a) * ex + math.abs(plane.b) * ey + math.abs(plane.c) * ez
        local distance = plane.a * cx + plane.b * cy + plane.c * cz + plane.d
        if distance + radius < 0 then
            return true
        end
    end

    return false
end

function project_bounds_to_buffer(bounds, view_matrix, projection_matrix, buffer_width, buffer_height, flip_y)
    if not bounds or not view_matrix or not projection_matrix then
        return nil
    end
    if not RBX._bounds_are_finite(bounds)
        or not RBX._matrix_is_finite(view_matrix)
        or not RBX._matrix_is_finite(projection_matrix) then
        return nil
    end
    buffer_width = round_dimension(buffer_width)
    buffer_height = round_dimension(buffer_height)
    if not buffer_width or not buffer_height or buffer_width <= 0 or buffer_height <= 0 then
        return nil
    end

    local min_x, min_y, min_z = bounds.min_x, bounds.min_y, bounds.min_z
    local max_x, max_y, max_z = bounds.max_x, bounds.max_y, bounds.max_z
    local min_sx = math.huge
    local min_sy = math.huge
    local max_sx = -math.huge
    local max_sy = -math.huge
    local near_depth = 1
    local far_depth = 0
    local all_in_front = true
    local all_in_near_clip = true
    local any_projected = false
    local clip_epsilon = 1e-5
    local y_scale = math.max(1, buffer_height - 1)
    local x_scale = math.max(1, buffer_width - 1)
    local y_flipped = flip_y ~= nil and flip_y < 0

    local function project_corner(px, py, pz)
        local vx, vy, vz, vw = transform_point4(view_matrix, px, py, pz, 1)
        local cx, cy, cz, cw = transform_point4(projection_matrix, vx, vy, vz, vw)
        if cw <= clip_epsilon then
            all_in_front = false
            all_in_near_clip = false
        else
            if (cz + cw) <= clip_epsilon then
                all_in_near_clip = false
            end
            any_projected = true
            local ndc_x = cx / cw
            local ndc_y = cy / cw
            local ndc_z = cz / cw
            local sx = (ndc_x * 0.5 + 0.5) * x_scale
            local normalized_y = ndc_y * 0.5 + 0.5
            local sy = (y_flipped and normalized_y or (1 - normalized_y)) * y_scale
            local depth = clamp(ndc_z * 0.5 + 0.5, 0, 1)

            min_sx = math.min(min_sx, sx)
            min_sy = math.min(min_sy, sy)
            max_sx = math.max(max_sx, sx)
            max_sy = math.max(max_sy, sy)
            near_depth = math.min(near_depth, depth)
            far_depth = math.max(far_depth, depth)
        end
    end

    project_corner(min_x, min_y, min_z)
    project_corner(max_x, min_y, min_z)
    project_corner(min_x, max_y, min_z)
    project_corner(max_x, max_y, min_z)
    project_corner(min_x, min_y, max_z)
    project_corner(max_x, min_y, max_z)
    project_corner(min_x, max_y, max_z)
    project_corner(max_x, max_y, max_z)

    if not any_projected then
        return nil
    end

    local rect_min_x = math.max(0, math.floor(min_sx))
    local rect_min_y = math.max(0, math.floor(min_sy))
    local rect_max_x = math.min(buffer_width - 1, math.ceil(max_sx))
    local rect_max_y = math.min(buffer_height - 1, math.ceil(max_sy))
    if rect_min_x > rect_max_x or rect_min_y > rect_max_y then
        return nil
    end

    local width = rect_max_x - rect_min_x + 1
    local height = rect_max_y - rect_min_y + 1

    return {
        min_x = rect_min_x,
        min_y = rect_min_y,
        max_x = rect_max_x,
        max_y = rect_max_y,
        width = width,
        height = height,
        area = width * height,
        near_depth = near_depth,
        far_depth = far_depth,
        all_in_front = all_in_front and all_in_near_clip,
        all_in_near_clip = all_in_near_clip,
    }
end

function escape_pattern(text)
    return (text:gsub("([^%w])", "%%%1"))
end

function find_named_block(source, tag_name, property_name)
    local escaped_name = escape_pattern(property_name)
    local pattern = "<" .. tag_name .. "[^>]-name=\"" .. escaped_name .. "\"[^>]*>(.-)</" .. tag_name .. ">"
    return source:match(pattern)
end

function find_named_value(source, tag_name, property_name)
    local escaped_name = escape_pattern(property_name)
    local pattern = "<" .. tag_name .. "[^>]-name=\"" .. escaped_name .. "\"[^>]*>([^<]*)</" .. tag_name .. ">"
    return source:match(pattern)
end

function find_named_content_value(source, property_name)
    local function local_trim(text)
        if type(text) ~= "string" then
            return ""
        end
        return (text:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local escaped_name = escape_pattern(property_name)
    local pattern = "<Content[^>]-name=\"" .. escaped_name .. "\"[^>]*>(.-)</Content>"
    local content = source:match(pattern)
    if not content then
        return nil
    end

    local url = content:match("<url>(.-)</url>")
    if url then
        return local_trim(url)
    end

    -- modern Content properties (for example Decal.ColorMapContent) serialize
    -- their URI under <uri>, while legacy ContentId properties use <url>
    local uri = content:match("<uri>(.-)</uri>")
    if uri then
        return local_trim(uri)
    end

    local text = content:match("<string>(.-)</string>")
    if text then
        return local_trim(text)
    end

    if content:find("<null", 1, true) then
        return nil
    end

    local raw = content:match("([^<]+)")
    return raw and local_trim(raw) or nil
end

function read_tag_number(block, tag_name, default_value)
    local raw = block:match("<" .. tag_name .. ">([^<]+)</" .. tag_name .. ">")
    local number = read_numeric_token(raw, nil)
    if number == nil then
        return default_value
    end
    return number
end

function read_numeric_token(value, default_value)
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return default_value
    end

    local trimmed = trim(value)
    if trimmed == "" then
        return default_value
    end

    local upper = trimmed:upper()
    if upper == "INF" or upper == "+INF" or upper == "INFINITY" or upper == "+INFINITY" then
        return math.huge
    end
    if upper == "-INF" or upper == "-INFINITY" then
        return -math.huge
    end
    if upper == "NAN" then
        return 0 / 0
    end

    local number = tonumber(trimmed)
    if number == nil then
        return default_value
    end
    return number
end

function read_named_number(properties_block, property_name, default_value)
    local candidates = { "float", "double", "int", "int64", "token" }
    for i = 1, #candidates do
        local value = read_numeric_token(find_named_value(properties_block, candidates[i], property_name), nil)
        if value ~= nil then
            return value
        end
    end
    return default_value
end

function read_named_bool(properties_block, property_name, default_value)
    local value = find_named_value(properties_block, "bool", property_name)
    if value == nil then
        return default_value
    end
    value = value:lower()
    if value == "true" then
        return true
    end
    if value == "false" then
        return false
    end
    return default_value
end

function RBX._read_named_ref(properties_block, property_name)
    local value = find_named_value(properties_block, "Ref", property_name)
    if value == nil then
        return nil
    end
    value = tostring(value):match("^%s*(.-)%s*$")
    if value == "" or value == "null" then
        return nil
    end
    return value
end

function RBX._read_named_sequence_value(properties_block, tag_name, property_name, fallback)
    local raw = find_named_value(properties_block, tag_name, property_name)
    if type(raw) ~= "string" then
        return fallback
    end
    local numbers = {}
    for number in raw:gmatch("[-+]?%d*%.?%d+") do
        numbers[#numbers + 1] = tonumber(number)
    end
    return #numbers > 0 and numbers or fallback
end

function RBX._parse_constraint_color_properties_block(properties_block)
    local brick_color = read_named_number(properties_block, "Color", nil)
    if brick_color ~= nil then
        local color = BRICK_COLORS[brick_color]
        if color then
            return tonumber(color[1]) or 235, tonumber(color[2]) or 235, tonumber(color[3]) or 235
        end
    end

    local sequence = RBX._read_named_sequence_value(properties_block, "ColorSequence", "Color", nil)
    if sequence and #sequence >= 4 then
        return math.floor(clamp(sequence[2] or 1, 0, 1) * 255 + 0.5),
            math.floor(clamp(sequence[3] or 1, 0, 1) * 255 + 0.5),
            math.floor(clamp(sequence[4] or 1, 0, 1) * 255 + 0.5)
    end

    local color3 = read_named_color3(properties_block, "Color")
    if color3 then
        return math.floor(clamp(color3[1] or 1, 0, 1) * 255 + 0.5),
            math.floor(clamp(color3[2] or 1, 0, 1) * 255 + 0.5),
            math.floor(clamp(color3[3] or 1, 0, 1) * 255 + 0.5)
    end

    return 235, 235, 235
end

function RBX._parse_constraint_transparency_properties_block(properties_block)
    local direct = read_named_number(properties_block, "Transparency", nil)
    if direct ~= nil then
        return clamp(direct, 0, 1)
    end

    local sequence = RBX._read_named_sequence_value(properties_block, "NumberSequence", "Transparency", nil)
    if sequence and #sequence >= 3 then
        return clamp(sequence[2] or 0, 0, 1)
    end

    return 0
end

function read_named_color3(properties_block, property_name)
    local color_block = find_named_block(properties_block, "Color3", property_name)
    if not color_block then
        return nil
    end

    local r = read_tag_number(color_block, "R", 1)
    local g = read_tag_number(color_block, "G", 1)
    local b = read_tag_number(color_block, "B", 1)

    if r > 1 or g > 1 or b > 1 then
        r, g, b = r / 255, g / 255, b / 255
    end

    return {
        clamp(r, 0, 1),
        clamp(g, 0, 1),
        clamp(b, 0, 1),
    }
end

function parse_time_of_day_hours(time_of_day_string, clock_time_number)
    if type(clock_time_number) == "number" then
        return clock_time_number % 24
    end

    if type(time_of_day_string) == "string" then
        local h, m, s = time_of_day_string:match("^(%d+):(%d+):(%d+)$")
        if h then
            h, m, s = tonumber(h), tonumber(m), tonumber(s)
            if h and m and s then
                return ((h % 24) + (m / 60) + (s / 3600))
            end
        end
        local simple = tonumber(time_of_day_string)
        if simple then
            return simple % 24
        end
    end

    return 14
end

function lerp3(a, b, t)
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    }
end

function mul3(a, b)
    return {
        clamp(a[1] * b[1], 0, 1),
        clamp(a[2] * b[2], 0, 1),
        clamp(a[3] * b[3], 0, 1),
    }
end

function avg3(a)
    return (a[1] + a[2] + a[3]) / 3
end

function clone3(a)
    if not a then
        return nil
    end
    return { a[1], a[2], a[3] }
end

function starts_with(text, prefix)
    return type(text) == "string" and text:sub(1, #prefix) == prefix
end

function trim(text)
    if type(text) ~= "string" then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function safe_lower(text)
    if type(text) ~= "string" then
        return ""
    end
    return text:lower()
end

DEFAULT_SKYBOX = {
    SkyboxBk = "rbxasset://sky/null_plainsky512_bk.jpg",
    SkyboxDn = "rbxasset://sky/null_plainsky512_dn.jpg",
    SkyboxFt = "rbxasset://sky/null_plainsky512_ft.jpg",
    SkyboxLf = "rbxasset://sky/null_plainsky512_lf.jpg",
    SkyboxRt = "rbxasset://sky/null_plainsky512_rt.jpg",
    SkyboxUp = "rbxasset://sky/null_plainsky512_up.jpg",
}

RBX.DEFAULT_HEAD_MESH_ASSET = "rbxasset://asset/Head.mesh"
RBX.DEFAULT_HEAD_SPECIAL_MESH_SCALE = {
    x = 1,
    y = 1,
    z = 1,
}
RBX.LEGACY_DEFAULT_HEAD_SPECIAL_MESH_SCALE = {
    x = 1.25,
    y = 1.25,
    z = 1.25,
}

RBX.MESH_TRANSFORM_CONFORMANCE = {
    MeshPart = {
        parent_size = "MeshPart.Size scales the imported mesh bounds",
        original_bounds = "normalize by mesh bounds or MeshSize when present",
        mesh_scale = "none",
        mesh_offset = "none",
        axis_mapping = "Roblox CFrame basis with renderer Z negation; mesh asset basis signs apply only to positions/normals/culling",
        matrix_order = "CFrame * asset_axis_conversion * bounds_scale * vertex",
        uv = "preserve imported mesh UVs",
        normal = "inverse-scale normal transform, then CFrame basis",
        winding = "swap cull parity for negative scales or handedness changes; DoubleSided disables culling",
    },
    SpecialMeshFileMesh = {
        parent_size = "collision part size is not used for render scale",
        original_bounds = "uploaded mesh dimensions are used directly",
        mesh_scale = "DataModelMesh.Scale multiplies local mesh axes directly",
        mesh_offset = "DataModelMesh.Offset applies in parent local space before mesh vertices",
        axis_mapping = "Roblox parent CFrame basis with renderer asset-axis conversion",
        matrix_order = "ParentCFrame * Offset * asset_axis_conversion * DataModelMesh.Scale * vertex",
        uv = "preserve imported mesh UVs",
        normal = "inverse-scale normal transform, then parent CFrame basis",
        winding = "swap cull parity for negative scales or handedness changes",
    },
    SpecialMeshHead = {
        parent_size = "legacy non-standard; multiply BasePart.Size by Scale, then constrain X/Z display extents to the lower absolute product",
        original_bounds = "built-in or explicit Head mesh authored bounds are used only as the normalization source",
        mesh_scale = "DataModelMesh.Scale is applied componentwise before X/Z radial conformity",
        mesh_offset = "DataModelMesh.Offset applies in parent local space",
        axis_mapping = "same as SpecialMesh FileMesh",
        matrix_order = "ParentCFrame * Offset * asset_axis_conversion * normalize_to_radially_constrained(BasePart.Size * DataModelMesh.Scale) * vertex",
        uv = "preserve imported mesh UVs",
        normal = "inverse-scale normal transform, then parent CFrame basis",
        winding = "swap cull parity for negative scales or handedness changes",
    },
    SpecialMeshBrick = {
        parent_size = "BasePart.Size is multiplied by DataModelMesh.Scale",
        original_bounds = "primitive block bounds",
        mesh_scale = "per-axis DataModelMesh.Scale",
        mesh_offset = "DataModelMesh.Offset applies in parent local space",
        axis_mapping = "parent CFrame basis",
        matrix_order = "ParentCFrame * Offset * BasePart.Size * DataModelMesh.Scale * primitive_vertex",
        uv = "generated primitive UVs",
        normal = "primitive face normals transformed by parent CFrame",
        winding = "primitive culling follows scaled basis parity",
    },
    SpecialMeshWedge = {
        parent_size = "BasePart.Size is multiplied by DataModelMesh.Scale",
        original_bounds = "primitive wedge bounds",
        mesh_scale = "per-axis DataModelMesh.Scale",
        mesh_offset = "DataModelMesh.Offset applies in parent local space",
        axis_mapping = "parent CFrame basis",
        matrix_order = "ParentCFrame * Offset * BasePart.Size * DataModelMesh.Scale * primitive_vertex",
        uv = "generated primitive UVs",
        normal = "primitive face normals transformed by parent CFrame",
        winding = "primitive culling follows scaled basis parity",
    },
    SpecialMeshSphere = {
        parent_size = "BasePart.Size is multiplied by DataModelMesh.Scale without sphere diameter clamping",
        original_bounds = "primitive sphere bounds",
        mesh_scale = "per-axis DataModelMesh.Scale",
        mesh_offset = "DataModelMesh.Offset applies in parent local space",
        axis_mapping = "parent CFrame basis",
        matrix_order = "ParentCFrame * Offset * BasePart.Size * DataModelMesh.Scale * primitive_vertex",
        uv = "generated primitive UVs",
        normal = "primitive smooth normals transformed by parent CFrame",
        winding = "primitive culling follows scaled basis parity",
    },
    SpecialMeshCylinder = {
        parent_size = "multiply BasePart.Size by DataModelMesh.Scale, then constrain the local Y/Z cross-section to the lower absolute product",
        original_bounds = "primitive cylinder bounds",
        mesh_scale = "DataModelMesh.Scale is applied componentwise before radial conformity",
        mesh_offset = "DataModelMesh.Offset applies in parent local space",
        axis_mapping = "parent CFrame basis; renderer cylinder height is local X",
        matrix_order = "ParentCFrame * Offset * constrain_radially(BasePart.Size * DataModelMesh.Scale) * primitive_vertex",
        uv = "generated primitive UVs",
        normal = "primitive cylinder normals transformed by parent CFrame",
        winding = "primitive culling follows scaled basis parity",
    },
    SpecialMeshTorso = {
        parent_size = "legacy non-standard; approximated as a scaled primitive block",
        original_bounds = "primitive block bounds",
        mesh_scale = "DataModelMesh.Scale multiplies BasePart.Size",
        mesh_offset = "DataModelMesh.Offset applies in parent local space",
        axis_mapping = "parent CFrame basis",
        matrix_order = "ParentCFrame * Offset * BasePart.Size * DataModelMesh.Scale * primitive_vertex",
        uv = "generated primitive UVs",
        normal = "primitive face normals transformed by parent CFrame",
        winding = "primitive culling follows scaled basis parity",
    },
    SpecialMeshDeprecatedRamp = {
        parent_size = "retained in the DataModel but no render geometry is submitted",
        original_bounds = "none; the legacy MeshType member was never implemented by Roblox",
        mesh_scale = "retained in the DataModel but has no submitted vertices",
        mesh_offset = "retained in the DataModel but has no submitted vertices",
        axis_mapping = "not applicable",
        matrix_order = "not applicable",
        uv = "none",
        normal = "none",
        winding = "none",
    },
}

function RBX._get_mesh_transform_conformance_table()
    return RBX.MESH_TRANSFORM_CONFORMANCE
end

local function normalize_special_mesh_scale_value(scale, default_x, default_y, default_z)
    if type(scale) ~= "table" then
        return {
            x = default_x,
            y = default_y,
            z = default_z,
        }
    end
    local function scale_component(value, fallback)
        local number = tonumber(value)
        if number == nil then
            return fallback
        end
        if not RBX._is_finite_number(number) then
            return 0
        end
        return number
    end
    return {
        x = scale_component(scale.x, default_x),
        y = scale_component(scale.y, default_y),
        z = scale_component(scale.z, default_z),
    }
end

function RBX._is_legacy_default_head_special_mesh_scale(scale)
    local normalized = normalize_special_mesh_scale_value(scale, 1, 1, 1)
    local legacy = RBX.LEGACY_DEFAULT_HEAD_SPECIAL_MESH_SCALE or { x = 1.25, y = 1.25, z = 1.25 }
    local tolerance = 1e-4
    return math.abs((normalized.x or 1) - (legacy.x or 1.25)) <= tolerance
        and math.abs((normalized.y or 1) - (legacy.y or 1.25)) <= tolerance
        and math.abs((normalized.z or 1) - (legacy.z or 1.25)) <= tolerance
end

function RBX._get_effective_special_mesh_scale(part, mesh_type)
    local resolved_mesh_type = mesh_type
    if resolved_mesh_type == nil and type(part) == "table" and part.MeshOwner == "SpecialMesh" then
        resolved_mesh_type = normalize_special_mesh_type(part.SpecialMeshType, part.MeshId)
    end

    local default_scale = resolved_mesh_type == "Head"
        and (RBX.DEFAULT_HEAD_SPECIAL_MESH_SCALE or { x = 1, y = 1, z = 1 })
        or { x = 1, y = 1, z = 1 }
    local normalized = normalize_special_mesh_scale_value(
        type(part) == "table" and part.SpecialMeshScale or nil,
        default_scale.x or 1,
        default_scale.y or 1,
        default_scale.z or 1
    )

    return normalized
end

-- Compatibility projection for older embedding code. Renderer semantics live in
-- material_registry.lua, this table is no longer an independently maintained
-- enum subset and therefore cannot silently drift from modern Enum.Material
do
    local registry = runtime_require("material_registry.lua")
    MATERIAL_TOKEN_TO_FOLDER = {}
    local tokens = registry.official_tokens()
    for index = 1, #tokens do
        local descriptor = registry.get(tokens[index])
        local family = descriptor and descriptor.fallback_asset_family
        if family and family ~= registry.FLAT_ASSET_FAMILY then
            MATERIAL_TOKEN_TO_FOLDER[tokens[index]] = family
        end
    end
    local aliases = registry.compatibility_tokens()
    for index = 1, #aliases do
        local descriptor = registry.get(aliases[index])
        local family = descriptor and descriptor.fallback_asset_family
        if family and family ~= registry.FLAT_ASSET_FAMILY then
            MATERIAL_TOKEN_TO_FOLDER[aliases[index]] = family
        end
    end
end

MATERIAL_STUDS_PER_TILE = 4

function get_path_extension(path)
    if type(path) ~= "string" then
        return ""
    end
    local extension = path:match("^.+(%.[^./\\]+)$")
    return safe_lower(extension or "")
end

function file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    return love.filesystem.getInfo(path, "file") ~= nil
end

function normalize_asset_path(path)
    if type(path) ~= "string" then
        return ""
    end
    local normalized = trim(path:gsub("\\", "/"))
    normalized = normalized:gsub("&amp;", "&")
    normalized = normalized:gsub("&lt;", "<")
    normalized = normalized:gsub("&gt;", ">")
    normalized = normalized:gsub("&quot;", "\"")
    normalized = normalized:gsub("&#39;", "'")
    return normalized
end

function extract_asset_id(path)
    path = normalize_asset_path(path)
    if path == "" then
        return nil
    end

    local lower = safe_lower(path)
    if starts_with(lower, "rbxassetid://") then
        local tail = trim(path:sub(#"rbxassetid://" + 1))
        return tail:match("(%d+)")
    end

    if starts_with(lower, "http://") or starts_with(lower, "https://") then
        local id = path:match("[?&]id=(%d+)")
        if not id then
            id = path:match("[?&]assetid=(%d+)")
        end
        if not id then
            id = path:match("/asset/%?id=(%d+)")
        end
        if id then
            return id
        end
        local tail = path:match("(%d+)([^%d]*)$")
        if tail then
            return tail
        end
        local last = nil
        for candidate in path:gmatch("(%d+)") do
            last = candidate
        end
        return last
    end

    if path:match("^%d+$") then
        return path
    end

    return nil
end

function normalize_asset_reference(value)
    if value == nil then
        return nil
    end
    if type(value) == "table" then
        if type(value.type) == "string" and value.value ~= nil then
            return normalize_asset_reference(value.value)
        end
        if type(value.uri) == "string" then
            return normalize_asset_reference(value.uri)
        end
        if type(value.value) == "string" or type(value.value) == "number" then
            return normalize_asset_reference(value.value)
        end
        if type(value.text) == "string" then
            return normalize_asset_reference(value.text)
        end
        if type(value.assetId) == "string" or type(value.assetId) == "number" then
            return normalize_asset_reference(value.assetId)
        end
        if type(value.assetid) == "string" or type(value.assetid) == "number" then
            return normalize_asset_reference(value.assetid)
        end
        return nil
    end
    if type(value) == "number" then
        if value <= 0 then
            return nil
        end
        return tostring(math.floor(value + 0.5))
    end
    if type(value) == "string" then
        local out = trim(value)
        if out == "" then
            return nil
        end
        return out
    end
    return nil
end

function canonicalize_asset_reference(value, asset_type)
    local normalized = normalize_asset_reference(value)
    if not normalized then
        return nil
    end

    local asset_id = extract_asset_id(normalized)
    if asset_id then
        return "id:" .. tostring(asset_id)
    end

    local path = normalize_asset_path(normalized)
    if path == "" then
        return nil
    end

    local lower = safe_lower(path)
    if starts_with(lower, "rbxasset://") then
        local relative = normalize_asset_path(path:sub(#"rbxasset://" + 1)):gsub("^/+", "")
        return "rbxasset:" .. safe_lower(relative)
    end
    if starts_with(lower, "rbxgameasset://") then
        local relative = normalize_asset_path(path:sub(#"rbxgameasset://" + 1)):gsub("^/+", "")
        return "rbxgameasset:" .. safe_lower(relative)
    end

    return "path:" .. safe_lower(path)
end

function RBX._canonical_asset_cache_key(value, asset_type)
    return (asset_type or "asset") .. "|" .. (canonicalize_asset_reference(value, asset_type) or "__empty")
end

function RBX._add_stage_time(stage_times, key, seconds)
    if type(stage_times) ~= "table" or type(key) ~= "string" or key == "" then
        return
    end
    stage_times[key] = (tonumber(stage_times[key]) or 0) + math.max(0, tonumber(seconds) or 0)
end

function RBX:_add_load_stage_time(key, seconds)
    self._load_stage_times = self._load_stage_times or {}
    RBX._add_stage_time(self._load_stage_times, key, seconds)
end

function RBX:_note_load_cache_stat(key, amount)
    if type(key) ~= "string" or key == "" then
        return
    end
    self._load_cache_stats = self._load_cache_stats or {}
    self._load_cache_stats[key] = (tonumber(self._load_cache_stats[key]) or 0) + (tonumber(amount) or 1)
end

function RBX:_note_gpu_upload_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes <= 0 then
        return
    end
    self._load_cache_stats = self._load_cache_stats or {}
    self._load_cache_stats.gpu_upload_bytes = (tonumber(self._load_cache_stats.gpu_upload_bytes) or 0) + bytes
end

function RBX:_reset_load_cache_stats()
    self._load_cache_stats = {
        mesh_cache_hits = 0,
        mesh_cache_misses = 0,
        texture_cache_hits = 0,
        texture_cache_misses = 0,
        union_cache_hits = 0,
        union_cache_misses = 0,
        surfacegui_cache_hits = 0,
        surfacegui_cache_misses = 0,
        material_cache_hits = 0,
        material_cache_misses = 0,
        gpu_mesh_upload_count = 0,
        gpu_texture_upload_count = 0,
        duplicate_asset_count = 0,
        gpu_upload_bytes = 0,
    }
end

function RBX._is_empty_asset_reference(value)
    local normalized = normalize_asset_reference(value)
    if not normalized then
        return true
    end
    local lower = safe_lower(normalized)
    return lower == "0"
        or lower == "rbxassetid://0"
        or lower == "rbxasset://0"
        or lower == "content.none"
        or lower == "rbxasset://content.none"
        or lower == "rbxassetid://content.none"
end

CSG_EMBEDDED_MESH_FIELDS = {
    "ModelMeshData",
    "MeshData",
    "ChildData",
    "ModelMeshData2",
    "MeshData2",
    "ChildData2",
    "AeroMeshData",
    "PhysicalConfigData",
    "PhysicsData",
}

function append_unique_string_candidate(candidates, seen, candidate)
    if type(candidate) ~= "string" then
        return
    end

    if candidate == "" or seen[candidate] then
        return
    end

    seen[candidate] = true
    candidates[#candidates + 1] = candidate
end

function collect_csg_embedded_mesh_candidates_from_instance(instance)
    if type(instance) ~= "table" then
        return nil
    end

    local candidates = {}
    local seen = {}
    for i = 1, #CSG_EMBEDDED_MESH_FIELDS do
        append_unique_string_candidate(candidates, seen, instance[CSG_EMBEDDED_MESH_FIELDS[i]])
    end

    return #candidates > 0 and candidates or nil
end

function copy_runtime_value(value, seen, copy_leaf, copy_step)
    if type(value) ~= "table" then
        return value
    end
    local source = rawget(value, "_surface_gui_data") or value
    seen = seen or {}
    if seen[source] and (not copy_leaf or source == value) then
        return seen[source]
    end
    -- explicit reference handling sees the actual value before a GUI payload
    -- can erase facade identity. Nil hooks retain the original wrapper/memo
    -- contract. explicit opaque memo hits use the original facade identity
    if copy_leaf then
        local handled, replacement = copy_leaf(value)
        if handled then
            if seen[value] then return seen[value] end
            seen[value] = replacement
            return replacement
        end
    end
    if seen[source] then return seen[source] end
    local out = {}
    seen[source] = out
    for key, item in pairs(source) do
        out[key] = copy_runtime_value(item, seen, copy_leaf, copy_step)
        if copy_step then copy_step() end
    end
    return out
end

-- Decal/Texture descriptors cross four ownership boundaries (DOM parser,
-- fallback parser, renderer part, and public facade).  keep one canonical,
-- finite renderer shape here so every boundary can take a value-owned copy
-- without carrying facade tables or transient GPU resources with it
local function face_descriptor_value(source, ...)
    if type(source) ~= "table" then
        return nil
    end
    for index = 1, select("#", ...) do
        local key = select(index, ...)
        local value = source[key]
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function finite_face_descriptor_number(value, fallback, minimum, maximum)
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric
        or numeric == math.huge or numeric == -math.huge then
        numeric = fallback
    end
    if minimum ~= nil and numeric < minimum then numeric = minimum end
    if maximum ~= nil and numeric > maximum then numeric = maximum end
    return numeric
end

local function face_descriptor_asset(source, ...)
    if type(source) ~= "table" then return nil end
    for index = 1, select("#", ...) do
        local normalized = normalize_asset_reference(
            source[select(index, ...)])
        if normalized ~= nil then return normalized end
    end
    return nil
end

local function face_descriptor_color(value)
    value = type(value) == "table" and value or {}
    return {
        finite_face_descriptor_number(value[1] or value.r or value.R, 1, 0, 1),
        finite_face_descriptor_number(value[2] or value.g or value.G, 1, 0, 1),
        finite_face_descriptor_number(value[3] or value.b or value.B, 1, 0, 1),
    }
end

local function face_descriptor_vector2(value, default_x, default_y)
    value = type(value) == "table" and value or {}
    return finite_face_descriptor_number(value.X or value.x or value[1], default_x, -1000000, 1000000),
        finite_face_descriptor_number(value.Y or value.y or value[2], default_y, -1000000, 1000000)
end

local function normalized_face_descriptor_name(value)
    if RBX._enum_face_name then
        return RBX._enum_face_name(value)
    end
    local numeric = tonumber(value)
    if numeric ~= nil and RBX.FACE_ENUM then
        return RBX.FACE_ENUM[math.floor(numeric + 0.5)] or "Front"
    end
    local text = tostring(value or "Front")
    local tail = text:match("([%a_]+)$") or text
    local aliases = RBX.FACE_ENUM and RBX.FACE_ENUM.aliases
    return aliases and aliases[string.lower(tail)] or "Front"
end

function RBX._normalize_face_texture_descriptor(source, class_name, metadata)
    source = type(source) == "table" and source or {}
    metadata = type(metadata) == "table" and metadata or {}
    class_name = class_name
        or face_descriptor_value(source, "class_name", "ClassName")
        or "Decal"
    if class_name ~= "Texture" then class_name = "Decal" end

    local texture = face_descriptor_asset(source,
        "ColorMapContent", "colormapcontent", "ColorMap", "colormap",
        "TextureContent", "texturecontent", "Texture", "Content",
        "texture")
    local uv_offset_u = face_descriptor_value(source, "uv_offset_u")
    local uv_offset_v = face_descriptor_value(source, "uv_offset_v")
    if uv_offset_u == nil and uv_offset_v == nil then
        uv_offset_u, uv_offset_v = face_descriptor_vector2(
            face_descriptor_value(source, "UVOffset", "uvoffset"), 0, 0)
    end
    local uv_scale_u = face_descriptor_value(source, "uv_scale_u")
    local uv_scale_v = face_descriptor_value(source, "uv_scale_v")
    if uv_scale_u == nil and uv_scale_v == nil then
        uv_scale_u, uv_scale_v = face_descriptor_vector2(
            face_descriptor_value(source, "UVScale", "uvscale"), 1, 1)
    end

    local studs_fallback = class_name == "Texture" and 2 or nil
    local shared_studs = face_descriptor_value(source, "StudsPerTile", "studspertile")
    local studs_u = face_descriptor_value(source, "studs_per_tile_u", "StudsPerTileU", "studspertileu")
    local studs_v = face_descriptor_value(source, "studs_per_tile_v", "StudsPerTileV", "studspertilev")
    if studs_u == nil then studs_u = shared_studs end
    if studs_v == nil then studs_v = shared_studs end
    if studs_fallback ~= nil then
        studs_u = finite_face_descriptor_number(studs_u, studs_fallback, 0.001, 1000000)
        studs_v = finite_face_descriptor_number(studs_v, studs_fallback, 0.001, 1000000)
    else
        studs_u = studs_u ~= nil
            and finite_face_descriptor_number(studs_u, 2, 0.001, 1000000) or nil
        studs_v = studs_v ~= nil
            and finite_face_descriptor_number(studs_v, 2, 0.001, 1000000) or nil
    end

    local authored_index = face_descriptor_value(source,
        "authored_index", "authored_order")
        or metadata.authored_index or metadata.authored_order
    if authored_index ~= nil then
        authored_index = math.floor(finite_face_descriptor_number(
            authored_index, 0, 0, 2147483647))
    end

    return {
        class_name = class_name,
        name = face_descriptor_value(source, "name", "Name") or metadata.name,
        referent = face_descriptor_value(source, "referent", "Referent")
            or metadata.referent,
        authored_index = authored_index,
        face = normalized_face_descriptor_name(
            face_descriptor_value(source, "face", "Face")),
        texture = texture,
        transparency = finite_face_descriptor_number(face_descriptor_value(
            source, "transparency", "Transparency"), 0, 0, 1),
        color = face_descriptor_color(face_descriptor_value(
            source, "color", "Color3", "Color")),
        zindex = math.floor(finite_face_descriptor_number(face_descriptor_value(
            source, "zindex", "ZIndex"), 1, -10000, 10000)),
        rotation = finite_face_descriptor_number(face_descriptor_value(
            source, "rotation", "Rotation"), 0, -1000000, 1000000),
        uv_offset_u = finite_face_descriptor_number(uv_offset_u, 0, -1000000, 1000000),
        uv_offset_v = finite_face_descriptor_number(uv_offset_v, 0, -1000000, 1000000),
        uv_scale_u = finite_face_descriptor_number(uv_scale_u, 1, -1000000, 1000000),
        uv_scale_v = finite_face_descriptor_number(uv_scale_v, 1, -1000000, 1000000),
        studs_per_tile_u = studs_u,
        studs_per_tile_v = studs_v,
        offset_studs_u = finite_face_descriptor_number(face_descriptor_value(
            source, "offset_studs_u", "OffsetStudsU", "offsetstudsu"), 0, -1000000, 1000000),
        offset_studs_v = finite_face_descriptor_number(face_descriptor_value(
            source, "offset_studs_v", "OffsetStudsV", "offsetstudsv"), 0, -1000000, 1000000),
    }
end

function RBX._clone_face_texture_descriptor(descriptor)
    if type(descriptor) ~= "table" then return nil end
    return RBX._normalize_face_texture_descriptor(
        descriptor, descriptor.class_name or descriptor.ClassName)
end

function RBX._clone_face_texture_list(descriptors)
    local out = {}
    for index = 1, #(descriptors or {}) do
        local clone = RBX._clone_face_texture_descriptor(descriptors[index])
        if clone then out[#out + 1] = clone end
    end
    return out
end

---SurfaceAppearance is transported as renderer metadata rather than exposed as
---a writable BasePart property. keep every transport boundary value-owned so a
---runtime clone cannot mutate the parsed map descriptor (or another clone)
function RBX._clone_surface_appearance_descriptor(descriptor)
    if type(descriptor) ~= "table" then
        return nil
    end
    return copy_runtime_value(descriptor)
end

local SURFACE_APPEARANCE_ALPHA_MODE_BY_NAME = {
    overlay = 0,
    transparency = 1,
    tintmask = 2,
    opaque = 3,
}

---normalize numeric tokens, EnumItem values and names to the same AlphaMode
---unknown values fall back to Overlay
function RBX._normalize_surface_appearance_alpha_mode(value)
    local seen = nil
    while type(value) == "table" do
        seen = seen or {}
        if seen[value] then
            return 0
        end
        seen[value] = true
        value = value.Value
            or value.value
            or value.Name
            or value.name
            or value.EnumItem
            or value.enum_item
    end

    if type(value) == "number" then
        if value == math.floor(value) and value >= 0 and value <= 3 then
            return value
        end
        return 0
    end

    if type(value) ~= "string" then
        return 0
    end

    local normalized = value:gsub("^%s+", ""):gsub("%s+$", "")
    local numeric = tonumber(normalized)
    if numeric ~= nil then
        if numeric == math.floor(numeric) and numeric >= 0 and numeric <= 3 then
            return numeric
        end
        return 0
    end

    -- accept both bare names and qualified Enum strings such as
    -- `Enum.AlphaMode.TintMask` without accepting an arbitrary substring
    local name = normalized:match("([%a_]+)$") or normalized
    name = name:gsub("_", ""):lower()
    return SURFACE_APPEARANCE_ALPHA_MODE_BY_NAME[name] or 0
end

function convert_brick_color_value(number)
    local color = BRICK_COLORS[tonumber(number) or -1]
    return {
        Number = tonumber(number) or 0,
        Color = {
            R = (color and color[1]) or 0,
            G = (color and color[2]) or 0,
            B = (color and color[3]) or 0,
        },
    }
end

function RBX._extract_cframe_components(raw)
    if type(raw) ~= "table" then
        return nil
    end

    local position = raw.Position or raw.position or {}
    local px = tonumber(raw.X or raw.x or position.X or position.x)
    local py = tonumber(raw.Y or raw.y or position.Y or position.y)
    local pz = tonumber(raw.Z or raw.z or position.Z or position.z)
    if px == nil or py == nil or pz == nil then
        return nil
    end

    return {
        x = px,
        y = py,
        z = pz,
        r00 = tonumber(raw.R00 or raw.r00) or 1,
        r01 = tonumber(raw.R01 or raw.r01) or 0,
        r02 = tonumber(raw.R02 or raw.r02) or 0,
        r10 = tonumber(raw.R10 or raw.r10) or 0,
        r11 = tonumber(raw.R11 or raw.r11) or 1,
        r12 = tonumber(raw.R12 or raw.r12) or 0,
        r20 = tonumber(raw.R20 or raw.r20) or 0,
        r21 = tonumber(raw.R21 or raw.r21) or 0,
        r22 = tonumber(raw.R22 or raw.r22) or 1,
    }
end

function RBX._transform_attachment_world_point(parent_cframe, local_x, local_y, local_z)
    local cframe = RBX._extract_cframe_components(parent_cframe)
    if not cframe then
        return nil, nil, nil
    end

    local ox = tonumber(local_x) or 0
    local oy = tonumber(local_y) or 0
    local oz = tonumber(local_z) or 0
    return cframe.x + cframe.r00 * ox + cframe.r01 * oy + cframe.r02 * oz,
        cframe.y + cframe.r10 * ox + cframe.r11 * oy + cframe.r12 * oz,
        cframe.z + cframe.r20 * ox + cframe.r21 * oy + cframe.r22 * oz
end

function convert_dom_vector_value(raw, x_key, y_key, z_key)
    raw = type(raw) == "table" and raw or {}
    local out = {
        [x_key] = tonumber(raw.x or raw.X or raw[1] or 0) or 0,
        [y_key] = tonumber(raw.y or raw.Y or raw[2] or 0) or 0,
    }
    if z_key then
        out[z_key] = tonumber(raw.z or raw.Z or raw[3] or 0) or 0
    end
    return out
end

function convert_dom_cframe_value(raw)
    raw = type(raw) == "table" and raw or {}
    local position = raw.position or raw.Position or raw.pos or {}
    local orientation = raw.orientation or raw.Orientation or raw.matrix or {}
    local out = {
        X = tonumber(position.x or position.X or raw.x or raw.X or 0) or 0,
        Y = tonumber(position.y or position.Y or raw.y or raw.Y or 0) or 0,
        Z = tonumber(position.z or position.Z or raw.z or raw.Z or 0) or 0,
    }
    out.Position = {
        X = out.X,
        Y = out.Y,
        Z = out.Z,
    }
    out.R00 = tonumber(orientation[1] or orientation.R00 or raw.R00 or 1) or 1
    out.R01 = tonumber(orientation[2] or orientation.R01 or raw.R01 or 0) or 0
    out.R02 = tonumber(orientation[3] or orientation.R02 or raw.R02 or 0) or 0
    out.R10 = tonumber(orientation[4] or orientation.R10 or raw.R10 or 0) or 0
    out.R11 = tonumber(orientation[5] or orientation.R11 or raw.R11 or 1) or 1
    out.R12 = tonumber(orientation[6] or orientation.R12 or raw.R12 or 0) or 0
    out.R20 = tonumber(orientation[7] or orientation.R20 or raw.R20 or 0) or 0
    out.R21 = tonumber(orientation[8] or orientation.R21 or raw.R21 or 0) or 0
    out.R22 = tonumber(orientation[9] or orientation.R22 or raw.R22 or 1) or 1
    return out
end

function convert_dom_content_value(raw)
    if type(raw) ~= "table" then
        return normalize_asset_reference(raw)
    end
    if type(raw.uri) == "string" and raw.uri ~= "" then
        return raw.uri
    end
    if type(raw.value) == "string" and raw.value ~= "" then
        return raw.value
    end
    if type(raw.text) == "string" and raw.text ~= "" then
        return raw.text
    end
    return nil
end

DOM_RUNTIME_PROPERTY_ALLOWLIST = {
    -- keep authored audio settings through loading, caching and cloning
    SoundId = true,
    Volume = true,
    PlaybackSpeed = true,
    Pitch = true,
    Looped = true,
    TimePosition = true,
    RollOffMode = true,
    RollOffMinDistance = true,
    RollOffMaxDistance = true,
    EmitterSize = true,
    PlayOnRemove = true,
    SoundGroup = true,
    Name = true,
    ClassName = true,
    Referent = true,
    Source = true,
    source = true,
    Disabled = true,
    disabled = true,
    Enabled = true,
    enabled = true,
    Shape = true,
    shape = true,
    CFrame = true,
    cframe = true,
    CoordinateFrame = true,
    coordinateframe = true,
    -- Camera source values must survive both XML and binary conversion. the
    -- loader retains CurrentCamera as authored metadata, importing a map does
    -- not implicitly replace the embedding application's active camera
    Focus = true,
    focus = true,
    CameraType = true,
    FieldOfView = true,
    CurrentCamera = true,
    Size = true,
    size = true,
    Transparency = true,
    transparency = true,
    Reflectance = true,
    reflectance = true,
    Color = true,
    color = true,
    Color3 = true,
    color3 = true,
    Color3uint8 = true,
    color3uint8 = true,
    -- Atmosphere facade properties. Color and Offset are shared with other
    -- instance types below, retain the remaining authored fields so promoted
    -- Lighting children stay live-value equivalent to parser LightingState
    Density = true,
    density = true,
    Decay = true,
    decay = true,
    Haze = true,
    haze = true,
    Glare = true,
    glare = true,
    BrickColor = true,
    brickcolor = true,
    Anchored = true,
    anchored = true,
    CanCollide = true,
    cancollide = true,
    CanTouch = true,
    cantouch = true,
    CanQuery = true,
    canquery = true,
    CastShadow = true,
    castshadow = true,
    CollisionGroup = true,
    collisiongroup = true,
    CollisionGroupId = true,
    collisiongroupid = true,
    CollisionGroupData = true,
    TouchesUseCollisionGroups = true,
    Gravity = true,
    FallenPartsDestroyHeight = true,
    Massless = true,
    massless = true,
    RootPriority = true,
    rootpriority = true,
    CustomPhysicalProperties = true,
    customphysicalproperties = true,
    Material = true,
    material = true,
    MeshId = true,
    MeshID = true,
    meshid = true,
    MeshContent = true,
    meshcontent = true,
    TextureContent = true,
    texturecontent = true,
    TextureId = true,
    TextureID = true,
    textureid = true,
    DoubleSided = true,
    doublesided = true,
    SmoothingAngle = true,
    smoothingangle = true,
    RenderFidelity = true,
    renderfidelity = true,
    CollisionFidelity = true,
    collisionfidelity = true,
    PhysicsData = true,
    physicsdata = true,
    TriangleCount = true,
    trianglecount = true,
    MaterialVariant = true,
    materialvariant = true,
    BaseMaterial = true,
    basematerial = true,
    MaterialPattern = true,
    materialpattern = true,
    Use2022Materials = true,
    use2022materials = true,
    MeshType = true,
    meshtype = true,
    Scale = true,
    scale = true,
    Offset = true,
    offset = true,
    VertexColor = true,
    vertexcolor = true,
    MeshSize = true,
    ModelMeshSize = true,
    InitialSize = true,
    meshsize = true,
    modelmeshsize = true,
    initialsize = true,
    AssetId = true,
    assetid = true,
    UsePartColor = true,
    usepartcolor = true,
    Value = true,
    value = true,
    Bytecode = true,
    bytecode = true,
    ColorMap = true,
    colormap = true,
    ColorMapContent = true,
    colormapcontent = true,
    NormalMap = true,
    normalmap = true,
    NormalMapContent = true,
    normalmapcontent = true,
    RoughnessMap = true,
    roughnessmap = true,
    RoughnessMapContent = true,
    roughnessmapcontent = true,
    MetalnessMap = true,
    metalnessmap = true,
    MetalnessMapContent = true,
    metalnessmapcontent = true,
    AlphaMode = true,
    alphamode = true,
    EmissiveMaskContent = true,
    emissivemaskcontent = true,
    EmissiveStrength = true,
    emissivestrength = true,
    EmissiveTint = true,
    emissivetint = true,
    ResampleMode = true,
    resamplemode = true,
    TexturePack = true,
    texturepack = true,
    TexturePackContent = true,
    texturepackcontent = true,
    TexturePackMetadata = true,
    texturepackmetadata = true,
    Texture = true,
    texture = true,
    Face = true,
    face = true,
    -- Texture defaults each tile dimension independently to two studs
    StudsPerTileU = true,
    studspertileu = true,
    StudsPerTileV = true,
    studspertilev = true,
    StudsPerTile = true,
    studspertile = true,
    OffsetStudsU = true,
    offsetstudsu = true,
    OffsetStudsV = true,
    offsetstudsv = true,
    UVOffset = true,
    uvoffset = true,
    UVScale = true,
    uvscale = true,
    Position = true,
    position = true,
    Velocity = true,
    velocity = true,
    RotVelocity = true,
    rotvelocity = true,
    AssemblyLinearVelocity = true,
    assemblylinearvelocity = true,
    AssemblyAngularVelocity = true,
    assemblyangularvelocity = true,
    Visible = true,
    visible = true,
    Enabled = true,
    enabled = true,
    Part0 = true,
    part0 = true,
    Part1 = true,
    part1 = true,
    C0 = true,
    c0 = true,
    C1 = true,
    c1 = true,
    BaseAngle = true,
    baseangle = true,
    Force = true,
    force = true,
    RelativeTo = true,
    ApplyAtCenterOfMass = true,
    Location = true,
    location = true,
    MaxForce = true,
    maxforce = true,
    MaxTorque = true,
    maxtorque = true,
    AngularVelocity = true,
    angularvelocity = true,
    P = true,
    p = true,
    D = true,
    d = true,
    Thickness = true,
    thickness = true,
    Width0 = true,
    width0 = true,
    Width1 = true,
    width1 = true,
    Restitution = true,
    restitution = true,
    WinchEnabled = true,
    winchenabled = true,
    Length = true,
    length = true,
    LimitsEnabled = true,
    limitsenabled = true,
    LimitAngle0 = true,
    limitangle0 = true,
    LimitAngle1 = true,
    limitangle1 = true,
    Attachment0 = true,
    attachment0 = true,
    Attachment1 = true,
    attachment1 = true,
    CurveSize0 = true,
    CurveSize1 = true,
    Segments = true,
    ZOffset = true,
    FaceCamera = true,
    Adornee = true,
    adornee = true,
    Ambient = true,
    OutdoorAmbient = true,
    ColorShift_Top = true,
    ColorShift_Bottom = true,
    FogColor = true,
    FogStart = true,
    FogEnd = true,
    Brightness = true,
    ExposureCompensation = true,
    EnvironmentDiffuseScale = true,
    EnvironmentSpecularScale = true,
    GeographicLatitude = true,
    GlobalShadows = true,
    ShadowSoftness = true,
    LightingStyle = true,
    PrioritizeLightingQuality = true,
    Technology = true,
    Outlines = true,
    ClockTime = true,
    TimeOfDay = true,
    Enabled = true,
    enabled = true,
    Shadows = true,
    shadows = true,
    Range = true,
    range = true,
    Angle = true,
    angle = true,
    Face = true,
    face = true,
    TintColor = true,
    TopSurface = true,
    BottomSurface = true,
    LeftSurface = true,
    RightSurface = true,
    FrontSurface = true,
    BackSurface = true,
    SurfaceGui = true,
    SurfaceBoard = true,
    SizingMode = true,
    sizingmode = true,
    CanvasSize = true,
    canvassize = true,
    PixelsPerStud = true,
    pixelsperstud = true,
    AlwaysOnTop = true,
    alwaysontop = true,
    LightInfluence = true,
    lightinfluence = true,
    Brightness = true,
    brightness = true,
    MaxDistance = true,
    maxdistance = true,
    ZIndex = true,
    zindex = true,
    AnchorPoint = true,
    anchorpoint = true,
    Rotation = true,
    rotation = true,
    Position = true,
    position = true,
    Size = true,
    size = true,
    BackgroundColor3 = true,
    backgroundcolor3 = true,
    BackgroundTransparency = true,
    backgroundtransparency = true,
    BorderColor3 = true,
    bordercolor3 = true,
    BorderSizePixel = true,
    bordersizepixel = true,
    ClipsDescendants = true,
    clipsdescendants = true,
    ZOffset = true,
    zoffset = true,
    Image = true,
    image = true,
    ImageColor3 = true,
    imagecolor3 = true,
    ImageTransparency = true,
    imagetransparency = true,
    Text = true,
    text = true,
    TextColor3 = true,
    textcolor3 = true,
    TextTransparency = true,
    texttransparency = true,
    TextStrokeColor3 = true,
    textstrokecolor3 = true,
    TextStrokeTransparency = true,
    textstroketransparency = true,
    TextSize = true,
    textsize = true,
    TextScaled = true,
    textscaled = true,
    TextWrapped = true,
    textwrapped = true,
    TextXAlignment = true,
    textxalignment = true,
    TextYAlignment = true,
    textyalignment = true,
    Font = true,
    font = true,
    FontFace = true,
    fontface = true,
    ImageRectOffset = true,
    imagerectoffset = true,
    ImageRectSize = true,
    imagerectsize = true,
    ScaleType = true,
    SizeConstraint = true,
    scaletype = true,
    SliceCenter = true,
    slicecenter = true,
    RichText = true,
    richtext = true,
    TileSize = true,
    tilesize = true,
    SizeOffset = true,
    ExtentsOffset = true,
    ExtentsOffsetWorldSpace = true,
    StudsOffset = true,
    studsoffset = true,
    StudsOffsetWorldSpace = true,
    studsoffsetworldspace = true,
    DisplayOrder = true,
    ZIndexBehavior = true,
    -- UIAspectRatioConstraint and UISizeConstraint layout
    AspectRatio = true,
    AspectType = true,
    DominantAxis = true,
    MinSize = true,
    MaxSize = true,
    -- ParticleEmitter, Trail and Beam emission and shape state
    Rate = true,
    Lifetime = true,
    Speed = true,
    Acceleration = true,
    Drag = true,
    RotSpeed = true,
    SpreadAngle = true,
    EmissionDirection = true,
    LockedToPart = true,
    VelocityInheritance = true,
    TimeScale = true,
    Orientation = true,
    ShapeStyle = true,
    ShapeInOut = true,
    ShapePartial = true,
    FlipbookLayout = true,
    Squash = true,
    WindAffectsDrag = true,
    LightEmission = true,
    MinLength = true,
    MaxLength = true,
    WidthScale = true,
    TextureMode = true,
    TextureLength = true,
    TextureSpeed = true,
    displayorder = true,
    SkyboxBk = true,
    SkyboxDn = true,
    SkyboxFt = true,
    SkyboxLf = true,
    SkyboxRt = true,
    SkyboxUp = true,
    SunTextureId = true,
    MoonTextureId = true,
    SunAngularSize = true,
    MoonAngularSize = true,
    StarCount = true,
    CelestialBodiesShown = true,
    SkyboxOrientation = true,
}

-- MaterialService serializes its base overrides as one `<Material>Name`
-- property per supported base. keep the properties data-driven here so both
-- binary and XML DOM conversions reach the shared MaterialVariant resolver
for _, material_name in ipairs({
    "Asphalt", "Basalt", "Brick", "Cardboard", "Carpet",
    "CeramicTiles", "ClayRoofTiles", "Cobblestone", "Concrete",
    "CorrodedMetal", "CrackedLava", "DiamondPlate", "Fabric", "Foil",
    "Glacier", "Granite", "Grass", "Ground", "Ice", "LeafyGrass",
    "Leather", "Limestone", "Marble", "Metal", "Mud", "Pavement",
    "Pebble", "Plaster", "Plastic", "Rock", "RoofShingles", "Rubber",
    "Salt", "Sand", "Sandstone", "Slate", "SmoothPlastic", "Snow",
    "Wood", "WoodPlanks",
}) do
    local property_name = material_name .. "Name"
    DOM_RUNTIME_PROPERTY_ALLOWLIST[property_name] = true
    DOM_RUNTIME_PROPERTY_ALLOWLIST[property_name:lower()] = true
end

local SURFACE_CONTROLLER_PROPERTY_PREFIXES = {
    "Top",
    "Bottom",
    "Left",
    "Right",
    "Front",
    "Back",
}

local SURFACE_CONTROLLER_PROPERTY_SUFFIXES = {
    "SurfaceInput",
    "ParamA",
    "ParamB",
}

for prefix_index = 1, #SURFACE_CONTROLLER_PROPERTY_PREFIXES do
    local prefix = SURFACE_CONTROLLER_PROPERTY_PREFIXES[prefix_index]
    for suffix_index = 1, #SURFACE_CONTROLLER_PROPERTY_SUFFIXES do
        local suffix = SURFACE_CONTROLLER_PROPERTY_SUFFIXES[suffix_index]
        local property_name = prefix .. suffix
        DOM_RUNTIME_PROPERTY_ALLOWLIST[property_name] = true
        DOM_RUNTIME_PROPERTY_ALLOWLIST[property_name:lower()] = true
    end
end

for index = 1, #CSG_EMBEDDED_MESH_FIELDS do
    DOM_RUNTIME_PROPERTY_ALLOWLIST[CSG_EMBEDDED_MESH_FIELDS[index]] = true
end

function should_copy_dom_property(property_name)
    return DOM_RUNTIME_PROPERTY_ALLOWLIST[property_name] == true
end

enum_face_name = nil

-- lazy module ref: require() is NYI for LuaJIT, so calling it per property value
-- kept the ~1M-call conversion loop interpreted (and allocated per call)
local _dom_module

function convert_dom_property_value(value)
    local dom = _dom_module
    if not dom then
        dom = require("engine/graphics/rbx/dom")
        _dom_module = dom
    end
    if not dom.is_value(value) then
        return copy_runtime_value(value)
    end

    local type_name = value.type
    local raw = value.value

    if type_name == "String" or type_name == "ProtectedString" then
        return raw
    end
    if type_name == "Bytecode" then
        if value.rawBytes or value.compressedBytes or value.byteLength or value.compression then
            return {
                value = raw,
                raw_bytes = value.rawBytes or raw,
                compressed_bytes = value.compressedBytes or value.rawBytes or raw,
                byte_length = tonumber(value.byteLength) or (type(raw) == "string" and #raw or 0),
                compression = value.compression or "preserved",
            }
        end
        return raw
    end
    if type_name == "SharedString" or type_name == "BinaryString" then
        if type(raw) == "table" then
            return raw.value or raw.text or ""
        end
        return raw
    end
    if type_name == "Enum" then
        local enum_value = raw
        if type(value.tokenText) == "string" and value.tokenText ~= "" and tonumber(value.tokenText) == nil then
            enum_value = value.tokenText
        end
        if value.propertyName == "Face" or value.propertyName == "face" then
            return enum_face_name(enum_value)
        end
        return enum_value
    end
    if type_name == "Bool" or type_name == "Int32" or type_name == "Float32" or type_name == "Float64"
        or type_name == "Faces" or type_name == "Axes" or type_name == "Referent" then
        return raw
    end
    if type_name == "BrickColor" then
        return convert_brick_color_value(raw)
    end
    if type_name == "Color3" or type_name == "Color3uint8" then
        return {
            R = tonumber(raw and (raw.r or raw.R or raw[1]) or 0) or 0,
            G = tonumber(raw and (raw.g or raw.G or raw[2]) or 0) or 0,
            B = tonumber(raw and (raw.b or raw.B or raw[3]) or 0) or 0,
        }
    end
    if type_name == "Vector2" then
        return convert_dom_vector_value(raw, "X", "Y")
    end
    if type_name == "Vector3" or type_name == "Vector3int16" then
        return convert_dom_vector_value(raw, "X", "Y", "Z")
    end
    if type_name == "UDim" then
        raw = type(raw) == "table" and raw or {}
        return {
            Scale = tonumber(raw.scale or raw.Scale or 0) or 0,
            Offset = tonumber(raw.offset or raw.Offset or 0) or 0,
        }
    end
    if type_name == "UDim2" then
        raw = type(raw) == "table" and raw or {}
        return {
            X = convert_dom_property_value(dom.value("UDim", raw.x or raw.X or {})),
            Y = convert_dom_property_value(dom.value("UDim", raw.y or raw.Y or {})),
        }
    end
    if type_name == "Ray" then
        raw = type(raw) == "table" and raw or {}
        return {
            Origin = convert_dom_vector_value(raw.origin or raw.Origin or {}, "X", "Y", "Z"),
            Direction = convert_dom_vector_value(raw.direction or raw.Direction or {}, "X", "Y", "Z"),
        }
    end
    if type_name == "CFrame" then
        return convert_dom_cframe_value(raw)
    end
    if type_name == "OptionalCFrame" then
        if value.none or raw == nil then
            return nil
        end
        return convert_dom_cframe_value(raw)
    end
    if type_name == "Rect" then
        raw = type(raw) == "table" and raw or {}
        return {
            Min = convert_dom_vector_value(raw.min or raw.Min or {}, "X", "Y"),
            Max = convert_dom_vector_value(raw.max or raw.Max or {}, "X", "Y"),
        }
    end
    if type_name == "Content" then
        return convert_dom_content_value(raw)
    end

    return copy_runtime_value(raw)
end

function convert_dom_instance_to_runtime_node(instance)
    if type(instance) ~= "table" then
        return nil
    end
    if parse_progress_hook then parse_progress_hook("dom_convert") end

    local runtime_node = {
        ClassName = instance.className or "Instance",
        Name = instance.name or instance.className or "Instance",
        Referent = instance.referent,
        Children = {},
        _dom_instance = instance,
    }

    -- propertyOrder is exhaustive: dom.Instance:set_property is the only writer of
    -- .properties and always records the key, so no second pairs() sweep is needed
    local property_order = instance.propertyOrder or {}
    local is_camera_source = runtime_node.ClassName == "Camera"
    for index = 1, #property_order do
        local property_name = property_order[index]
        if should_copy_dom_property(property_name)
            or (runtime_node.ClassName == "SunRaysEffect"
                and (property_name == "Intensity" or property_name == "Spread")) then
            runtime_node[property_name] = convert_dom_property_value(instance.properties[property_name])
            -- Native Camera aliases are the same property: the last authored
            -- write wins, including when it is the deprecated spelling
            -- Fold while propertyOrder is available, before the map cache
            -- discards DOM metadata. keep the original alias for diagnostics
            if is_camera_source then
                if property_name == "CoordinateFrame" then
                    runtime_node.CFrame = runtime_node[property_name]
                elseif property_name == "focus" then
                    runtime_node.Focus = runtime_node[property_name]
                end
            end
        end
    end

    runtime_node.Name = runtime_node.Name or instance.name or runtime_node.ClassName
    for index = 1, #(instance.children or {}) do
        local child = convert_dom_instance_to_runtime_node(instance.children[index])
        if child then
            child.Parent = runtime_node
            runtime_node.Children[#runtime_node.Children + 1] = child
        end
    end

    return runtime_node
end

function convert_dom_roots_to_runtime_nodes(roots)
    local out = {}
    for index = 1, #(roots or {}) do
        local runtime_node = convert_dom_instance_to_runtime_node(roots[index])
        if runtime_node then
            out[#out + 1] = runtime_node
        end
    end
    return out
end
