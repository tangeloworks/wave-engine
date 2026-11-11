-- Ordered coarse bounds over the existing prepared member array. no shape or
-- contact approximation: only the unchanged leaf filters may admit a pair
local M = { MIN_MEMBERS = 16, MAX_MEMBERS = 4096 }
local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local INF = math.huge
local function axis(c, h)
    if type(c) ~= 'number' or type(h) ~= 'number' or c ~= c or h ~= h
        or h < 0 or abs(c) > 1e150 or h > 1e150 then error('unbounded member') end
    -- Outward error allowance, not a collision margin. it dominates rounding
    -- in endpoint construction and the old center-difference/sum leaf test
    -- Coarse overlap is inclusive, the original leaf arithmetic remains exact
    local pad = (abs(c) + h + 1) * 2^-45
    return c-h-pad, c+h+pad
end
local function topology(nodes, lo, hi)
    local node = {lo=lo, hi=hi}; nodes[#nodes+1]=node
    if hi-lo >= 4 then
        local mid=floor((lo+hi)/2)
        node.left=topology(nodes,lo,mid);node.right=topology(nodes,mid+1,hi)
    end
    node.after = #nodes + 1
    return node
end
function M.refit(tree, members)
    -- Postorder refit, reusing all nodes. Indices preserve the source sequence,
    -- so traversal never needs sorting or deduplication before contact work
    for i=#tree.nodes,1,-1 do
        local node=tree.nodes[i];local a,b=node.left,node.right
        if a then
            node.x0=min(a.x0,b.x0);node.y0=min(a.y0,b.y0);node.z0=min(a.z0,b.z0)
            node.x1=max(a.x1,b.x1);node.y1=max(a.y1,b.y1);node.z1=max(a.z1,b.z1)
        else
            local x0,y0,z0,x1,y1,z1=INF,INF,INF,-INF,-INF,-INF
            for j=node.lo,node.hi do
                local e=members[j]
                local ax,bx=axis(e.cx,e.hbx);local ay,by=axis(e.cy,e.hby);local az,bz=axis(e.cz,e.hbz)
                x0=min(x0,ax);y0=min(y0,ay);z0=min(z0,az)
                x1=max(x1,bx);y1=max(y1,by);z1=max(z1,bz)
            end
            node.x0,node.y0,node.z0,node.x1,node.y1,node.z1=x0,y0,z0,x1,y1,z1
        end
    end
end
function M.prepare(members, n, stamp, counters)
    if n<1 or n>M.MAX_MEMBERS then return nil end
    local tree=members._selection_tree
    if tree and tree.valid and tree.stamp==stamp and tree.count==n then return tree end
    if tree then tree.valid=false end
    local built=false
    local ok,result=pcall(function()
        if not tree or tree.count~=n then
            tree={nodes={},count=n,valid=false};built=true
            if n<M.MIN_MEMBERS then tree.root={lo=1,hi=n,after=2};tree.nodes[1]=tree.root
            else tree.root=topology(tree.nodes,1,n) end
        end
        M.refit(tree,members)
        return tree
    end)
    if not ok then members._selection_tree=nil;return nil end
    tree=result;tree.stamp=stamp;tree.valid=true;members._selection_tree=tree
    if counters then
        counters.member_tree_builds=(counters.member_tree_builds or 0)+(built and 1 or 0)
        counters.member_tree_refits=(counters.member_tree_refits or 0)+1
    end
    return tree
end
function M.overlap(a,b)
    return not(a.x1<b.x0 or b.x1<a.x0 or a.y1<b.y0 or b.y1<a.y0 or a.z1<b.z0 or b.z1<a.z0)
end
function M.entry_overlap(e,b)
    local ax,bx=axis(e.cx,e.hbx);local ay,by=axis(e.cy,e.hby);local az,bz=axis(e.cz,e.hbz)
    return not(bx<b.x0 or b.x1<ax or by<b.y0 or b.y1<ay or bz<b.z0 or b.z1<az)
end
function M.release(body)
    if body._member_buf then body._member_buf._selection_tree=nil end
    if body._static_member_cache then body._static_member_cache._selection_tree=nil end
end
return M
