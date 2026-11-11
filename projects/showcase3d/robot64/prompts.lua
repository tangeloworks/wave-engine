-- The interaction prompt: the place's ReplicatedFirst/button floating above
-- whatever twirl would grab or talk to. Copied from the port's
-- source_prompts.lua (see NOTICE.md). Eligibility and the region query belong
-- to Carrying; this owner consumes that same target snapshot without rescanning.
local Source=require('projects/showcase3d/robot64/source')
local Prompts={};Prompts.__index=Prompts
local KEYBOARD_TEXTURE='rbxassetid://1194553296'
function Prompts.new(world,rbx,assets,options)
    options=options or{}
    local rf=options.storage or assert(Source.service(world,'ReplicatedFirst'))
    local template=options.template or assert(rf:FindFirstChild('button'),'Public interaction button is missing')
    local button=(options.clone or Source.clone)(template,world,rbx)
    -- This camera-relative source clone repeatedly crosses storage/Workspace.
    -- Keep its draw ownership independent of the static map, as with clouds.
    world:retain_dynamic_geometry(button)
    -- The one source-owned prompt is hidden in ReplicatedFirst between targets.
    -- Park its independently owned chunk there after the first visible build;
    -- it stays out of every active render list and releases on Destroy.
    world:preserve_dynamic_geometry_while_stored(button)
    button.Parent=rf
    local self=setmetatable({world=world,rbx=rbx,storage=rf,button=button,mesh=assert(button:FindFirstChild('Mesh')),
        assets=assets,targets=0},Prompts)
    -- Resolve once, leaving genuine unavailable-art errors observable. The
    -- actual Mesh setter retains the supplied source geometry/material path.
    for _,id in ipairs({'1194553296','1129630779'})do
        assert(assets:resolve('rbxassetid://'..id,'texture'),'Public interaction button texture is unavailable: '..id)
    end
    return self
end
-- The one source prompt is usually created on its first eligible interaction.
-- This activation-only path may build its retained chunk while it is stored.
-- Publication remains the ordinary current-pose/device-art path.
function Prompts:prepare()
    if self.closed or self.button.Parent~=self.storage then return false,'not_stored' end
    if self.texture~=KEYBOARD_TEXTURE then
        self.mesh.TextureId=KEYBOARD_TEXTURE;self.texture=KEYBOARD_TEXTURE
    end
    return self.world:prepare_dynamic_geometry_while_stored(self.button)
end
function Prompts:clear()
    if self.connection then self.connection:Disconnect();self.connection=nil end
    self.target=nil
    if not self.closed then self.button.Parent=self.storage end
end
function Prompts:update(dt,snapshot,context)
    if self.closed then return false end
    context=context or{};local target=snapshot and snapshot.target
    if not target or snapshot.visible==false or context.mode~='play'or context.paused or context.loading
        or context.talkto or context.anicam or context.held or context.anchored and not context.pound then
        self:clear();return false
    end
    if not target.Parent then self:clear();return false end
    if self.target~=target then
        local already_showing=self.target~=nil
        if self.connection then self.connection:Disconnect();self.connection=nil end
        self.target=target;self.targets=self.targets+1
        if not already_showing then self.started=context.gtick or 0 end
        if target.Destroying then self.connection=target.Destroying:Connect(function()self:clear()end)end
    end
    -- Storage rooms are alive but temporarily ineligible; the authoritative
    -- snapshot clears them at its membership boundary. Destruction clears the
    -- target through its public event before any pose setter can run.
    if not self.target or not target.Parent then self:clear();return false end
    local C,V=self.rbx.CFrame,self.rbx.Vector3;local camera=assert(context.camera_frame,'Current prompt camera is required')
    local age=(context.gtick or 0)-(self.started or 0)
    local pose=camera*C.Angles(-math.pi/2,math.cos(age*4)/10,math.sin(age*4)/10+math.pi)
    self.button.CFrame=pose-camera.Position+target.Position+V.new(0,target.Size.Y/2+2,0)
    local console=snapshot.console or snapshot.device=='controller'or snapshot.device=='mobile'
    local texture=console and'rbxassetid://1129630779'or'rbxassetid://1194553296'
    if self.texture~=texture then self.mesh.TextureId=texture;self.texture=texture end
    self.button.Parent=self.world.Workspace
    return true
end
function Prompts:destroy()
    if self.closed then return end
    self:clear();self.closed=true;self.button:Destroy()
end
Prompts.contracts={
    {kind='source-derived',source='public001-CharacterScript.lua:9139-9208; ReplicatedFirst/button referents92-93',
        decision='Use Carrying current eligibility, retain source mesh/device textures, target-height offset and camera-relative cosine/sine rotation on the same gameplay clock; hide in dialogue/hold/pause/cinematic/transition.'},
    {kind='lifetime-repair',source='Native public Instance.Destroying; map/character ownership',
        decision='One owned source clone and one target listener; its dormant chunk is outside active lists while stored, target destruction clears before pose publication, and retirement disconnects listeners/releases only owned geometry.'},
}
return Prompts
