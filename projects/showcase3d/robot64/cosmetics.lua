-- Rig visibility from the port's cosmetics.lua (Cosmetics:update). The
-- sandbox has no skins or hats, so only the per-frame transparency is kept:
-- the rig fades out as the camera closes in (follow_camera:visual_alpha),
-- blinks while invulnerable, and the pack and batteries show health.
local Cosmetics={};Cosmetics.__index=Cosmetics
function Cosmetics.new(app,rbx)
    return setmetatable({app=app,rbx=rbx,visual=app.visual},Cosmetics)
end
function Cosmetics:update(paused)
    local app=self.app
    if not app or not self.visual or self.visual.destroyed then return end
    local health=app.session.health or 4;local parts=self.visual.by_name
    local base=app.camera and app.camera:visual_alpha()or 0
    local rules=app.rules
    local blink=rules and rules.invulnerable_until and app.session.clocks.gameplay<rules.invulnerable_until
        and math.sin(app.session.clocks.gameplay*40)>0 and 1 or 0
    local alpha=paused and 0 or base+blink
    for _,item in ipairs(self.visual.parts) do
        if item.part.Parent==self.visual.model then item.part.Transparency=alpha end
    end
    self.visual.face.Transparency=alpha
    local beam=parts.head and parts.head:FindFirstChild('Beam')
    if beam then
        beam.Enabled=alpha~=1
        if self.beam_alpha~=alpha then
            beam.Transparency={{time=0,value=alpha,envelope=0},{time=1,value=alpha,envelope=0}}
            self.beam_alpha=alpha
        end
    end
    if parts.pack then parts.pack.Transparency=health>=4 and base or 1 end
    for i=1,4 do if parts['bt'..i] then parts['bt'..i].Transparency=health>=i and base or 1 end end
end
function Cosmetics:destroy()
    self.app=nil;self.visual=nil
end
return Cosmetics
