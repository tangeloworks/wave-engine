-- movement ported from the Robot 64 ball controller by zKevin
--
-- The reference applies damping in an unspecified wait() loop. Here its factors
-- mean one 1/30 s compatibility tick; fixed-step factors are factor^(dt*30).
-- BodyForce is world-space at the centre attachment. Desired point/facing
-- drives the template BodyGyro; animation uses the simulated body orientation.
local Animation = require("projects/showcase3d/robot64/character_animation")
local RayFilter = require("projects/showcase3d/robot64/ray_filter")
local Controller = {}
Controller.__index = Controller
Controller.damping_hz = 30

local function horizontal(v, V) return V.new(v.X, 0, v.Z) end
local function alive(part) return part and part.Parent ~= nil end
local function moving(part) return part and part.Parent and part.Parent.Name == "moving" end

---@param world RBXDataModel
---@param body RBXPart
---@param force RBXBodyForce
---@param rbx RBXModule
---@param options? table
function Controller.new(world, body, force, rbx, options)
    options = options or {}
    local self = setmetatable({world=world, workspace=world.Workspace, body=body,
        force=force, V=rbx.Vector3, CF=rbx.CFrame, enabled=true, input_enabled=true, time=0,
        facing=rbx.Vector3.new(0,0,-1), spin=0, walk=0, pitch=0,
        read_actions=options.read_actions or function() return {} end,
        spawn=body.CFrame, state={}, destroyed=false, hooks=options.hooks or {},
        on_surface_sound=options.on_surface_sound,on_impact=options.on_impact,anchor_held=options.anchor_held}, Controller)
    self.gyro = body.FindFirstChild and body:FindFirstChild("BodyGyro") or nil
    self.gyro_torque = self.gyro and self.gyro.MaxTorque
    self.animation = Animation.new(rbx)
    self.animation.templates = options.animation_templates
    self.visual_torso = options.visual_torso
    self.params = rbx.RaycastParams.new()
    self.params.FilterType = "Exclude"
    self.params.RespectCanCollide = true
    self.ground_params = rbx.RaycastParams.new()
    self.ground_params.FilterType = "Exclude"
    self.ground_params.RespectCanCollide = false
    self.ignore = {body}
    if options.visual then self.ignore[#self.ignore+1] = options.visual end
    RayFilter.assign(self.params, self.ignore)
    force.Force = self.V.new()
    self.velocity_deferred={};self.velocity_render={}
    if world.GetService then
        local run=world:GetService('RunService')
        self.velocity_defer_connection=run.Heartbeat:Connect(function()self:_defer_velocity()end)
        self.velocity_render_connection=run.RenderStepped:Connect(function()self:_render_velocity()end)
    end
    return self
end

-- point (desired facing) and mps (physical body basis) are distinct in the
-- source. Probes/skids using mps must not snap when the player's input turns.
function Controller:_body_facing() return self.gyro and self.body.CFrame.LookVector or self.facing end
function Controller:_publish_gyro()
    if not self.gyro then return end
    local goal=self.CF.lookAt(self.V.new(),self.facing)
    if self.facing:Dot(self.body.CFrame.LookVector)<-.96 then
        goal=goal*self.CF.Angles(0,self.animation.fallvr,0)
    end
    self.gyro.CFrame=goal
    self.gyro.MaxTorque=self.gyro_torque
end
function Controller:_right() return self.CF.lookAt(self.V.new(),self.facing).RightVector end
function Controller:_turn(direction, amount)
    if direction.Magnitude<1e-6 then return end
    self.facing=self.CF.lookAt(self.V.new(),self.facing):Lerp(
        self.CF.lookAt(self.V.new(),direction),math.min(1,amount)).LookVector
end
function Controller:_mps() return self.body.Position-self.V.new(0,1,0) end
function Controller:_event(name)
    self.animation:event(name,self.time)
    if self.hooks.event then self.hooks.event(name,self.time,self)end
end
function Controller:_velocity(y) local v=self.body.Velocity; return self.V.new(v.X,y,v.Z) end

-- Public cvt: publish now, defer once, then retry at RenderStepped only if
-- the requested motion was consumed. This never moves the body or bypasses
-- contacts; the next physics step still resolves the same collidable geometry.
function Controller:cvt(velocity)
    self.body.Velocity=velocity
    self.velocity_deferred[#self.velocity_deferred+1]={velocity=velocity,state=self.state}
end
function Controller:_clear_velocity_retries()
    self.velocity_deferred={};self.velocity_render={}
end
function Controller:_defer_velocity()
    local pending=self.velocity_deferred
    if #pending==0 then return end
    self.velocity_deferred={}
    local ready=self.velocity_render
    for i=1,#pending do ready[#ready+1]=pending[i]end
end
function Controller:_render_velocity()
    local ready=self.velocity_render
    if #ready==0 then return end
    self.velocity_render={}
    if self.destroyed or not self.enabled or self.frozen or not self.body.Parent then return end
    for i=1,#ready do
        local launch=ready[i]
        if launch.state==self.state and self.body.Velocity:Dot(launch.velocity)<.3 then
            self.body.Velocity=launch.velocity
        end
    end
end

-- only ground probes accept clouds, and only while approaching their top
function Controller:_ray(origin, direction, allow_clouds)
    local params = allow_clouds and self.ground_params or self.params
    local ignored = self.ignore
    RayFilter.assign(params,ignored)
    local seen,copied
    while true do
        local hit=self.workspace:Raycast(origin,direction,params)
        if not hit then return nil end
        local part = hit.Instance
        local cloud = part.Name == 'cloudy' or part.Name == 'weakcloudy'
        local supported = part.CanCollide ~= false
        if cloud then
            supported = allow_clouds and direction.Y < 0 and hit.Normal.Y >= .6
                and (part.Name ~= 'weakcloudy' or not self.state.crouch)
                and (self.state.ground == part or self.body.Velocity.Y <= 0)
                and self.body.Position.Y - self.body.Size.Y * .5 >= hit.Position.Y - .1
        end
        if part ~= self.body and supported and part.Name ~= "pole" then return hit end
        if not copied then
            copied=true;seen={}
            local list={}
            for i=1,#ignored do list[i]=ignored[i] end
            ignored=list
        end
        assert(not seen[hit.Instance],'Raycast returned an excluded instance')
        seen[hit.Instance]=true;ignored[#ignored+1]=hit.Instance
        RayFilter.assign(params,ignored)
    end
end

function Controller:_pause_context_valid(token,saved)
    if not token or token.active~=true or token.body~=self.body
        or type(token.generation)~='number' or type(token.current)~='function'
        or type(token.retire_anchor)~='function' or token:current()~=true
        or self.destroyed or not self.enabled then return false end
    if saved then
        return saved.token==token and saved.body==self.body
            and saved.generation==token.generation and saved.map==token.map
            and saved.state==self.state
    end
    return true
end
function Controller:_begin_pause_pound()
    local saved=self.pause_pound
    if saved then
        if self:_pause_context_valid(self.pause_context,saved)then return saved end
        return nil
    end
    local token,s=self.pause_context,self.state
    -- An early ground impact may clear pound but retain its deadline/anchor.
    if self.frozen or not self:_pause_context_valid(token)
        or not(s.pound or s.pound_release or s.owned_anchor)then return nil end
    local velocity,rotation=self.body.Velocity,self.body.RotVelocity
    saved={token=token,body=self.body,generation=token.generation,map=token.map,state=s,
        anchor=self.body.Anchored==true,external_anchor=self.body.Anchored==true and not s.owned_anchor,
        velocity=self.V.new(velocity.X,velocity.Y,velocity.Z),
        rotation=self.V.new(rotation.X,rotation.Y,rotation.Z)}
    self.pause_pound=saved
    return saved
end
function Controller:set_pause_context(token)
    if token and not self:_pause_context_valid(token)then token=nil end
    if self.pause_pound and not self:_pause_context_valid(token,self.pause_pound)then
        -- Retirement must run even when input/frozen booleans already match.
        self:_cancel()
        self.body.Velocity=self.V.new();self.body.RotVelocity=self.V.new()
    end
    self.pause_context=token
end
function Controller:_cancel()
    self:_clear_velocity_retries()
    local s,saved=self.state,self.pause_pound
    self.pause_context,self.pause_pound=nil,nil
    if saved then saved.token:retire_anchor(self.body,saved.external_anchor==true)end
    local held=self.anchor_held and self.anchor_held(self.body)==true
    if s.owned_anchor and not(self.frozen or held)then self.body.Anchored=false end
    self.state={}
    self.force.Force=self.V.new()
    if self.gyro then self.gyro.MaxTorque=self.V.new() end
    self.pheight=nil
    self.support=nil
    self.animation:reset()
    if saved and self.frozen then
        self.previous_anchor=saved.external_anchor==true
        self.body.Anchored=true
    end
end

-- Hard disable is for a stopped controller or disabled physics. Focus suspends
-- input; debug free camera freezes this body independently of world physics.
function Controller:set_enabled(enabled)
    enabled=enabled==true
    if self.enabled~=enabled then self:_cancel(); self.enabled=enabled end
end

function Controller:set_frozen(active)
    active = active == true
    if active then self:_clear_velocity_retries()end
    if self.pause_pound and not self:_pause_context_valid(self.pause_context,self.pause_pound)then
        self:set_pause_context(nil)
    end
    -- End our logical freeze without releasing a current registry's anchor.
    if not active and self.anchor_held and self.anchor_held(self.body)==true then
        self.frozen=false
        if not(self.pause_pound and self:_pause_context_valid(self.pause_context,self.pause_pound))then
            self.previous_anchor=nil
        end
        return
    end
    local saved=self.pause_pound
    if not active and saved and self:_pause_context_valid(self.pause_context,saved)
        and self.pause_context.phase=='resuming'and self.pause_context.restore_succeeded then
        self.frozen=false
        self.body.Anchored=saved.anchor
        self.previous_anchor=nil
        self.body.Velocity=saved.velocity;self.body.RotVelocity=saved.rotation
        self.pause_pound=nil
        return
    end
    if (self.frozen == true) == active then
        if active and not self.body.Anchored then self.body.Anchored=true end
        return
    end
    if active then
        local saved=self:_begin_pause_pound()
        if saved then self.previous_anchor=saved.anchor
        else
            self:_cancel() -- Release ability-owned anchors before taking our own.
            self.previous_anchor = self.body.Anchored
        end
        self.frozen = true
        self.body.Anchored = true
    else
        self.frozen = false
        self.body.Anchored = self.previous_anchor == true
        self.previous_anchor = nil
    end
    self.body.Velocity = self.V.new()
    self.body.RotVelocity = self.V.new()
end

function Controller:teleport(position, direction)
    self.departing_support=nil
    self:_cancel()
    direction = direction or self.facing
    direction = horizontal(direction, self.V)
    if direction.Magnitude < 1e-6 then direction = self.V.new(0, 0, -1) end
    self.body.CFrame = self.CF.lookAt(position, position + direction.Unit)
    self.body.Velocity = self.V.new()
    self.body.RotVelocity = self.V.new()
    self.facing = direction.Unit
    self.spin, self.walk, self.pitch = 0, 0, 0
    self.ground_hit, self.visual_velocity, self.visual_speed = nil, nil, nil
    if self.enabled and not self.frozen then self:_publish_gyro() end
end

-- Clear player abilities while retaining passive support. The existing launch
-- guard prevents a nearby floor from cancelling ascent; its delayed phase is
-- discarded. A used double jump and crouched headroom remain authoritative.
function Controller:set_input_enabled(enabled)
    enabled=enabled==true
    if not enabled then self:_clear_velocity_retries()end
    if self.pause_pound and not self:_pause_context_valid(self.pause_context,self.pause_pound)then
        self:set_pause_context(nil)
    end
    if self.input_enabled==enabled then return end
    self.input_enabled=enabled
    if enabled or self:_begin_pause_pound()then return end
    local previous=self.state
    local support,pheight,ground_hit=self.support,self.pheight,self.ground_hit
    self:_cancel()
    if previous.ground then
        self.state.ground=previous.ground; self.state.landed=previous.landed
        self.state.crouch=previous.crouch
        self.support=support; self.pheight=pheight; self.ground_hit=ground_hit
    else
        self.state.double=previous.double
        if previous.jumping and previous.until_time and previous.until_time>self.time then
            self.state.jumping=true; self.state.until_time=previous.until_time
        end
    end
end

function Controller:respawn()
    self.departing_support=nil
    self:_cancel()
    self.body.CFrame=self.spawn
    self.body.Velocity=self.V.new()
    self.body.RotVelocity=self.V.new()
    self.facing=self.spawn.LookVector; self.spin=0; self.walk=0; self.pitch=0
    if self.enabled then self:_publish_gyro() end
end

function Controller:destroy()
    self.departing_support=nil
    if self.destroyed then return end
    for _,name in ipairs{'velocity_defer_connection','velocity_render_connection'}do
        local connection=self[name];if connection then connection:Disconnect();self[name]=nil end
    end
    self:set_frozen(false)
    self:_cancel(); self.enabled=false; self.destroyed=true
end

function Controller:visual_state() return self:_body_facing(),self.spin,self.animation end

function Controller:_lock(duration, phase)
    local s=self.state
    s.jumping=true; s.until_time=self.time+duration; s.phase=phase
    -- Launch state also invalidates support immediately, independently of cvt's
    -- deferred velocity retry, so grounded damping cannot consume the jump.
    s.ground=nil; s.wall=nil; self.ground_hit=nil; self.pheight=nil; self.support=nil
end

function Controller:_advance()
    local s=self.state
    if s.pound_release and self.time+1e-9>=s.pound_release then
        if s.owned_anchor and self.anchor_held and self.anchor_held(self.body)==true then return end
        s.pound_release=nil
        if s.owned_anchor then self.body.Anchored=false; s.owned_anchor=nil end
        if s.pound then self:cvt(self.V.new(0,-40,0)) end
    end
    if not s.until_time or self.time+1e-9<s.until_time then return end
    local phase=s.phase
    s.until_time=nil; s.phase=nil; s.jumping=false
    if phase=="climb-first" then
        self:cvt(self.V.new(0,self.body.Velocity.Y,0)-s.wall_normal*10-self:_right()*7)
        self:_lock(.2,"climb-last")
    elseif phase=="climb-last" then s.double=false; s.debounce=nil
    elseif phase=="away" then s.debounce=nil
    elseif phase=="slide" then
        s.sliding=false; s.until_time=self.time+.1; s.phase="roll-end"
    elseif phase=="backflip" or phase=="roll-end" then s.rolling=false end
end

function Controller:_follow_support()
    local record=self.support
    if not record then return end
    if not alive(record.part) then
        if self.state.ledge then self.state.ledge=nil end
        self.support=nil; return
    end
    local now=record.part.CFrame
    if self.state.ledge then
        local point=now:PointToWorldSpace(record.local_point)
        self.body.CFrame=self.body.CFrame+(point-record.world_point)
        self.state.ledge_point=point
    elseif moving(record.part) then
        local delta=now:PointToWorldSpace(record.local_point)-record.world_point
        self.body.CFrame=self.body.CFrame+delta
        if self.pheight then self.pheight=self.pheight+delta.Y end
    end
    record.world_point=now:PointToWorldSpace(record.local_point)
end

function Controller:_remember_support(part, point)
    self.support={part=part,local_point=part.CFrame:PointToObjectSpace(point),world_point=point}
end

function Controller:_ground()
    local s,V=self.state,self.V
    local was=s.ground
    -- A returned enemy impulse retires its support so grounded damping cannot
    -- consume the launch. Until actual separation/descent, the same nearby
    -- collider is still that contact, not a fresh landing on every probe.
    local departing=self.departing_support
    if departing and(not alive(departing)or self.body.Velocity.Y<=0)then
        self.departing_support=nil;departing=nil
    end
    local mps=self:_mps()
    local length=2.5+(was and horizontal(self.body.Velocity,V).Magnitude/30 or 0)
    local hit
    if not s.jumping then
        local forward=self:_body_facing()
        local right=self.gyro and self.body.CFrame.RightVector or self:_right()
        local offsets={V.new(),forward*.9,-forward*.9,right*.9,-right*.9}
        local raw_contact=false
        for _,offset in ipairs(offsets) do
            hit=self:_ray(mps+offset,V.new(0,-length,0),true)
            if hit then
                raw_contact=true
                if hit.Instance==departing then hit=nil
                elseif departing then self.departing_support=nil end
                break
            end
        end
        if departing and not raw_contact then self.departing_support=nil end
        if hit and hit.Normal.Y>=.6 and not was then self.pheight=mps.Y-2 end
        if self.pheight and hit and hit.Normal.Y>=.3 and not moving(hit.Instance)
            and not self.body.Anchored then
            local correction=V.new(0,hit.Position.Y-self.pheight,0)
            self.body.CFrame=self.body.CFrame+correction
            -- The camera owner follows the corrected published body after
            -- physics; writing its pose here would apply this movement twice.
        end
    end
    self.probe_hit=hit
    self.probe_position=hit and hit.Position or nil
    local traversable=hit and hit.Normal.Y>=.6 and hit.Instance.Name~="door"
    if traversable then
        local name=hit.Instance.Name
        local glass=name=='ufo' and hit.Instance:FindFirstChild('glass')
        if glass and glass.CanCollide==false then
            local outward=horizontal(mps-hit.Instance.Position,V)
            if outward.Magnitude>1e-8 then self.body.Velocity=outward.Unit*30 end
            traversable=false
        elseif name=='Bounce' then
            self.body.Velocity=self:_velocity(150);traversable=false
        elseif name=='mushroom' then
            local held=self.jump_held and 1 or 0
            self:cvt(self:_velocity(60+held*30));traversable=false
            if self.on_surface_sound then self.on_surface_sound(hit.Instance:FindFirstChild('Sound'),1+held/4) end
        end
    end
    if not traversable then
        if was and s.sliding and self.pitch+1.3>0 and not s.rolling then
            self.body.Velocity=self:_velocity(horizontal(self.body.Velocity,V).Magnitude/2)
        end
        s.ground=nil; self.pheight=nil
        if not s.ledge then self.support=nil end
    else
        s.ground=hit.Instance
        if not was then
            self.land_serial=(self.land_serial or 0)+1
            local incoming=self.body.Velocity
            self.last_land={part=hit.Instance,pound=s.pound==true,serial=self.land_serial}
            self.body.Velocity=self:_velocity(0)
            self.walk=0; self:_event('land')
            local impact=self.on_impact and self.on_impact(hit.Instance,{serial=self.land_serial,
                pound=s.pound==true,velocity=incoming,frame=self.body.CFrame-self.V.new(0,1,0)})
            if self.destroyed or not self.enabled or self.frozen or self.state~=s then return false end
            if impact then
                self.last_land.handled=impact.handled
                if impact.velocity then
                    self.body.Velocity=impact.velocity
                    if impact.remove_support and impact.velocity.Y>0 then self.departing_support=hit.Instance end
                end
                if impact.ground_delta then hit.Position=hit.Position+impact.ground_delta end
                if impact.remove_support then traversable=false end
            end
            s.rolling=false; s.pound=false; s.double=false; s.wall=nil; s.ledge=nil
            s.landed=self.time-(s.longjump and 0 or .2)
            if traversable and s.crouch and hit.Instance.Name~="Slide" then s.sliding=false end
        end
        s.longjump=false; s.attack=false
        if traversable then
            self.pheight=hit.Position.Y
            if hit.Instance.Name=="Slide" then s.sliding=true end
            self:_remember_support(hit.Instance,self.body.Position)
        else s.ground=nil;self.pheight=nil;self.support=nil end
    end
    self.ground_hit=traversable and hit or nil
    if not s.ground then s.skid=nil end
end

local function can_wall(part)
    local name=part.Name
    return name~="nowall" and name~="pole" and name~="knoddy" and name~="door" and name~="breakable"
        and not part:FindFirstChild("nowall")
end

function Controller:_wall(dt, dir)
    local s,V=self.state,self.V
    if s.ground or s.debounce or s.pound_release then
        s.wall=nil
        if s.ledge then s.ledge=nil; self.support=nil end
        return
    end
    local mps,right=self:_mps(),self:_right()
    local hit,side
    for _,probe in ipairs({self.facing*3,right*2,-right*2}) do
        local candidate=self:_ray(mps,probe)
        if candidate then hit,side=candidate,probe; break end
    end
    if not hit or not can_wall(hit.Instance) or math.abs(hit.Normal.Y)>=.2 or self.facing:Dot(hit.Normal)>=.3 then
        s.wall=nil
        if s.ledge then s.ledge=nil; self.support=nil end
        return
    end
    if not s.wall and horizontal(self.body.Velocity,V):Dot(self.facing)>0 and dir.Magnitude>.5 then
        local n=hit.Normal
        local wall_right=self.CF.lookAt(V.new(),n).RightVector
        local up=self.CF.lookAt(V.new(),self.facing).UpVector
        local tangent=wall_right*(-n:Dot(right))+up*(-n:Dot(self.facing))
        if tangent.Magnitude>0 then self.body.Velocity=self:_velocity(10+tangent.Unit.Y*30) end
    end
    s.wall=hit.Instance; s.wall_normal=hit.Normal
    s.longjump=false; s.pound=false; s.attack=false; s.rolling=false
    local upper=self:_ray(mps+V.new(0,2,0),side)
    local top=not upper and self:_ray(mps+V.new(0,2,0)+side,V.new(0,-2,0))
    -- Evaluate the rig's torso at this physics boundary. Reading the published
    -- visual Part here would feed render cadence back into ledge detection.
    -- Marker-only callers retain the body-centre surrogate.
    local torso_position=self.body.Position
    if self.visual_torso then
        local root=self.gyro and self.body.CFrame-self.V.new(0,1,0)
            or self.CF.lookAt(mps,mps+self.facing)
        torso_position=(root*self.animation:evaluate(self.animation.templates).torso).Position
    end
    local floor=self:_ray(torso_position,V.new(0,-30,0))
    local clearance=not floor or torso_position.Y-floor.Position.Y>5
    if top and top.Normal.Y>.8 and clearance and not s.skate then
        if not s.ledge then
            s.ledge=hit.Instance
            s.ledge_point=V.new(hit.Position.X,top.Position.Y-1.4,hit.Position.Z)+hit.Normal
            self:_remember_support(hit.Instance,s.ledge_point)
            self.body.Velocity=V.new()
        end
    elseif s.ledge then
        s.ledge=nil; self.support=nil
    end
end

function Controller:_ledge_jump(away)
    local s=self.state
    s.ledge=nil; s.wall=nil; s.debounce=true; self.support=nil
    if away then
        self:_event('away')
        self:cvt(self:_velocity(20)-self.facing*50)
        self:_lock(.2,"away")
    else
        self:_event('climb')
        self:cvt(self.V.new(0,30,0)+self:_right()*10)
        self:_lock(.2,"climb-first")
    end
end

function Controller:_slide_recovery()
    local s=self.state
    if s.ground and s.ground.Name~="Slide" and not s.jumping then
        self:_event('recovery')
        self:cvt(self:_velocity(20)); s.double=false; s.rolling=true
        self:_lock(.2,"slide")
    end
end

function Controller:_jump(dir)
    local s,V=self.state,self.V
    if s.debounce or s.pound or s.attack then return end
    if s.skid then
        self:_event('skidjump')
        self.facing=-s.skid; s.skid=nil
        self:cvt(self.facing*10+V.new(0,60,0))
        s.longjump=true; s.double=true; s.rolling=true; self:_lock(.5,"backflip")
    elseif s.ledge then self:_ledge_jump(dir:Dot(self.facing)<-.5)
    elseif s.wall then
        if not s.jumping then
            self:_event('walljump')
            self:cvt(self:_velocity(30)+s.wall_normal*30)
            self.facing=(-2*self.facing:Dot(s.wall_normal)*s.wall_normal+self.facing).Unit
            s.double=true; self:_lock(.2)
        end
    elseif s.sliding then self:_slide_recovery()
    elseif s.ground and not s.jumping then
        if s.crouch then
            local extra=self.body.Velocity.Y<0 and self.body.Velocity.Y>-10 and 3.5 or 0
            s.longjump=true; s.double=true
            if dir.Magnitude>.8 then
                self:_event('longjump')
                self:cvt(self.facing*30+V.new(0,40+extra,0)); self:_lock(.3)
            else
                self:_event('backflip')
                self:cvt(-self.facing*10+V.new(0,60+extra,0))
                s.rolling=true; self:_lock(.5,"backflip")
            end
        else self:_event('jump'); self:cvt(self:_velocity(40)); self:_lock(.3) end
    elseif not self.onejump and not s.ground and not s.double then
        self:_event('double')
        s.double=true; self:cvt(self:_velocity(40))
        if dir.Magnitude>.2 then self.facing=dir.Unit end
    end
end

function Controller:_dive()
    if self.onejump then return end
    local s=self.state
    if s.ledge and not s.debounce then self:_ledge_jump(false)
    elseif s.wall then self:_jump(self.V.new())
    elseif s.sliding then self:_slide_recovery()
    elseif not (s.wall or s.attack or s.pound or s.debounce) then
        self:_event('dive')
        self:cvt(self.facing*40+self.V.new(0,s.ground and 30 or 20,0))
        s.sliding=true; s.longjump=false; s.rolling=false; self:_lock(.3)
    end
end

function Controller:_twirl()
    local s=self.state
    if s.jumping or s.attack or s.wall or s.ledge or s.pound then return end
    if s.ground and s.ground.Name=="Slide" then return end
    self:_event('twirl')
    local v=self.body.Velocity
    self:cvt(self.V.new(v.X/2,20,v.Z/2))
    s.attack=true; s.double=true; s.sliding=false; s.longjump=false; self:_lock(.2)
end

function Controller:_crouch()
    if self.onejump then return end
    local s=self.state
    s.crouch=true
    if not s.ground or s.ground.Name~="Slide" then s.sliding=false end
    if s.ledge and not s.debounce then self:_ledge_jump(true)
    elseif not (s.ground or s.wall or s.attack or s.sliding or s.pound) then
        self:_event('pound')
        s.pound=true; s.rolling=true; s.double=true; s.longjump=true
        -- Own only this temporary anchor; all cancellation paths release it.
        if not self.body.Anchored then self.body.Anchored=true; s.owned_anchor=true end
        s.pound_release=self.time+.4
    end
end

function Controller:_forces(dt,dir,held_crouch)
    local s,V=self.state,self.V
    local normal=self.ground_hit and self.ground_hit.Normal or V.new(0,1,0)
    local velocity=self.body.Velocity
    local force,damping=dir*600,V.new(.75,1,.75)
    local speed=dir.Magnitude
    if s.sliding then
        local mg=s.ground and normal.Y>.995 and (s.ground.Name=="Slide" and 1 or 0) or 1
        force=dir*300*mg*math.max(.3,1-math.abs(dir:Dot(self.facing)))*(velocity.Magnitude/100)
            +horizontal(normal,V)*300
        local d=horizontal(velocity,V).Magnitude<50 and mg==0 and .94 or .994
        damping=V.new(d,1,d); speed=0
        if velocity.Magnitude<10 and mg<1 and s.ground and s.ground.Name~="Slide" then s.sliding=false end
    elseif s.attack then
        damping=V.new(.75,s.jumping and 1 or .9,.75); speed=0
        if not s.jumping and held_crouch then force=force-V.new(0,600,0) end
    elseif s.longjump then force=dir*150; damping=V.new(.98,1,.98)
    elseif s.crouch then force=dir*300; speed=speed*.5
    elseif not s.ground then force=dir*200; damping=V.new(.9,1,.9) end
    local gravity,mass=self.workspace.Gravity,self.body:GetMass()
    local result=force*.3
    if s.ledge then
        s.sliding=false
        result=(s.ledge_point-self:_mps())*400+V.new(0,gravity*mass,0)
        damping=V.new(.1,.1,.1)
    elseif s.wall then
        local imp=math.abs(dir:Dot(self.facing))>.9 and 0 or 1
        self:_turn(-s.wall_normal*2+dir*imp,dt*3)
        s.sliding=false
        result=V.new(0,gravity*mass/2,0)+self.facing*imp*150-s.wall_normal*100
        damping=V.new(.93,.96,.93)
    elseif s.ground then
        local height=s.crouch and not s.sliding and 1 or 2
        result=result+V.new(0,(self.ground_hit.Position.Y+height-self:_mps().Y)*300+gravity*mass/2,0)
        damping=V.new(damping.X,.2,damping.Z)
    elseif s.pound then result=result+V.new(0,-30,0) end
    if self.hooks.force then
        local override_force,override_damping,override_speed=self.hooks.force(self,dt,dir,held_crouch,result,damping)
        result=override_force or result;damping=override_damping or damping;speed=override_speed or speed
    end
    self.visual_velocity=velocity; self.visual_speed=speed
    self.force.Force=result
    local ticks=dt*Controller.damping_hz
    self.body.Velocity=V.new(velocity.X*damping.X^ticks,velocity.Y*damping.Y^ticks,velocity.Z*damping.Z^ticks)
    self.walk=self.walk+(speed-self.walk)*math.min(1,dt*4)
    if s.attack then self.spin=self.spin+dt*(20+(held_crouch and 10 or 0)) end
    local desired_pitch=s.sliding and (-1.3+math.max(-.8,math.min(.8,
        s.ground and -self.facing:Dot(normal) or velocity.Y/40))) or 0
    self.pitch=self.pitch+(desired_pitch-self.pitch)*math.min(1,dt*(s.longjump and not s.pound and 3 or 6))
end

function Controller:_steer(dt,dir)
    if self.hooks.steer and self.hooks.steer(self,dt,dir) then return end
    local s,V=self.state,self.V
    if s.sliding then
        local velocity=horizontal(self.body.Velocity,V)
        if velocity.Magnitude>.2 then
            self:_turn(dir*2+(self.facing:Dot(self.body.Velocity.Unit)<0 and -velocity or velocity),dt*4)
        end
    elseif s.ledge then self.facing=-s.wall_normal
    elseif not s.wall and not s.skid and dir.Magnitude>.2 and s.ground
        and self.time-(s.landed or self.time)>.2 then
        if s.crouch then self:_turn(dir,dt*5) else self.facing=dir.Unit end
    end
end

function Controller:_step(dt)
    self.time=self.time+dt
    -- Drain edges even while passive; none may be replayed on focus return.
    local input=self.read_actions() or {}
    if not self.input_enabled then input={} end
    self.jump_held=input.jump_held==true
    self:_advance(); self:_follow_support(); if self:_ground()==false then return end
    local dir=self.V.new(input.x or 0,0,input.z or 0)
    if dir.Magnitude>1 then dir=dir.Unit end
    self.movement_direction=dir
    if self.input_enabled then self:_wall(dt,dir) end
    if self.hooks.actions then input=self.hooks.actions(self,dt,input,dir) or input end
    local s=self.state
    if s.crouch and not input.crouch and not self:_ray(self:_mps(),self.V.new(0,4,0)) then s.crouch=false end
    if s.skid and self.time-s.skid_time>=.3 then s.skid=nil end
    if s.skid then
        self.facing=s.skid; dir=self.V.new()
    elseif s.ground and not (s.skate or s.sliding or s.crouch or s.attack) and dir.Magnitude>.3
        and dir:Dot(self:_body_facing())<=-.5 and horizontal(self.body.Velocity,self.V).Magnitude>10
        and self.walk>.7 and not s.skid then s.skid=self:_body_facing(); s.skid_time=self.time end
    if input.crouch_pressed then self:_crouch() end
    if input.jump then self:_jump(dir) end
    if input.dive then self:_dive() end
    if input.twirl then self:_twirl() end
    self:_steer(dt,dir)
    self:_forces(dt,dir,input.crouch==true)
    self:_publish_gyro()
    self.animation:advance(dt,self,dir,input.crouch==true)
end

function Controller:step(dt)
    if self.destroyed or not self.enabled or self.frozen then return end
    assert(type(dt)=="number" and dt>=0 and dt<math.huge,"finite nonnegative simulation step required")
    local ok,err=xpcall(function() self:_step(dt) end,debug.traceback)
    if not ok then self:_cancel(); self.enabled=false; error(err,0) end
end

-- A source door's walkto owns steering while ordinary actions are suspended.
-- Keep the same body, force/ground support and animation clock.
function Controller:cinematic_step(dt,direction)
    if self.destroyed or not self.enabled or self.frozen then return end
    self.time=self.time+dt;self:_advance();self:_follow_support();if self:_ground()==false then return end
    local dir=direction or self.V.new()
    if dir.Magnitude>1 then dir=dir.Unit end
    self:_steer(dt,dir);self:_forces(dt,dir,false);self:_publish_gyro()
    self.animation:advance(dt,self,dir,false)
end

-- Scripted anchored poses still run the source's ground probes and anim().
-- This publishes visual state only; the held body receives no movement force,
-- support correction or landing/attack callback.
function Controller:scripted_pose_step(dt,crouch_held)
    if self.destroyed or not self.enabled or not self.frozen then return end
    self.time=self.time+dt
    local V,s=self.V,self.state
    local forward,right=self:_body_facing(),self.body.CFrame.RightVector
    local point=self:_mps();local hit
    for _,offset in ipairs{V.new(),forward*.9,-forward*.9,right*.9,-right*.9}do
        hit=self:_ray(point+offset,V.new(0,-2.5,0),true)
        if hit then break end
    end
    local ground=hit and hit.Normal.Y>=.6 and hit.Instance.Name~='door'
    self.ground_hit=ground and hit or nil;s.ground=ground and hit.Instance or nil
    s.crouch=crouch_held==true
    self:_publish_gyro()
    self.animation:advance(dt,self,V.new(),crouch_held==true)
end

return Controller
