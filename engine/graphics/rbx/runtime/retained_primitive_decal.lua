-- keep vertex rows for a top decal on a flat sphere
-- rigid moves can reuse the shader pose, while resizing recalculates normals and surface offsets
local ffi=require('ffi')
local RetainedDecal={}
local function update_bounds(b)
 b.center_x=(b.min_x+b.max_x)*.5;b.center_y=(b.min_y+b.max_y)*.5;b.center_z=(b.min_z+b.max_z)*.5
 b.extent_x=(b.max_x-b.min_x)*.5;b.extent_y=(b.max_y-b.min_y)*.5;b.extent_z=(b.max_z-b.min_z)*.5
 b.radius=math.sqrt(b.extent_x*b.extent_x+b.extent_y*b.extent_y+b.extent_z*b.extent_z)
end
local function copy_bounds(b)
 return {min_x=b.min_x,min_y=b.min_y,min_z=b.min_z,max_x=b.max_x,max_y=b.max_y,max_z=b.max_z}
end
local function transform_bounds(src,m00,m01,m02,m10,m11,m12,m20,m21,m22,tx,ty,tz,dst)
 local cx,cy,cz=(src.min_x+src.max_x)*.5,(src.min_y+src.max_y)*.5,(src.min_z+src.max_z)*.5
 local ex,ey,ez=(src.max_x-src.min_x)*.5,(src.max_y-src.min_y)*.5,(src.max_z-src.min_z)*.5
 local wx,wy,wz=m00*cx+m01*cy+m02*cz+tx,m10*cx+m11*cy+m12*cz+ty,m20*cx+m21*cy+m22*cz+tz
 local hx,hy,hz=math.abs(m00)*ex+math.abs(m01)*ey+math.abs(m02)*ez,
  math.abs(m10)*ex+math.abs(m11)*ey+math.abs(m12)*ez,
  math.abs(m20)*ex+math.abs(m21)*ey+math.abs(m22)*ez
 dst.min_x,dst.min_y,dst.min_z=wx-hx,wy-hy,wz-hz
 dst.max_x,dst.max_y,dst.max_z=wx+hx,wy+hy,wz+hz
 return update_bounds(dst)
end
local function reset_gpu_pose(decal)
 local pose=decal.gpu_pose
 if not pose then return end
 local a,b,c=pose.rows[1],pose.rows[2],pose.rows[3]
 a[1],a[2],a[3],a[4]=1,0,0,0
 b[1],b[2],b[3],b[4]=0,1,0,0
 c[1],c[2],c[3],c[4]=0,0,1,0
 pose.revision=pose.revision+1
end
local function capture_gpu_pose(decal,px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,item)
 decal.base_px,decal.base_py,decal.base_pz=px,py,pz
 decal.base_rx,decal.base_ry,decal.base_rz=rx,ry,rz
 decal.base_ux,decal.base_uy,decal.base_uz=ux,uy,uz
 decal.base_bx,decal.base_by,decal.base_bz=bx,by,bz
 decal.base_item_bounds=copy_bounds(item.bounds)
 decal.base_sort_x,decal.base_sort_y,decal.base_sort_z=item.sort_x,item.sort_y,item.sort_z
 reset_gpu_pose(decal)
end
local function supported_size(sx,sy,sz)
 -- the cached top face fits a flat sphere within this size range
 return math.abs(sy-1)<=1e-9 and sx==sz and sx>=0.1 and sx<=12
end
local function is_rotation_basis(rx,ry,rz,ux,uy,uz,bx,by,bz)
 return math.abs(rx*(uy*bz-uz*by)+ry*(uz*bx-ux*bz)+rz*(ux*by-uy*bx)-1)<1e-6
  and math.abs(rx*rx+ry*ry+rz*rz-1)<1e-6 and math.abs(ux*ux+uy*uy+uz*uz-1)<1e-6
  and math.abs(bx*bx+by*by+bz*bz-1)<1e-6
end
local function stable_top(source,sy,count)
 local selected=0
 for i=1,#source,3 do
  local a,b,c=source[i],source[i+1],source[i+2]
  local ax,ay,az=b[1]-a[1],b[2]-a[2],b[3]-a[3]
  local bx,by,bz=c[1]-a[1],c[2]-a[2],c[3]-a[3]
  local nx,ny,nz=ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx
  if (math.abs(nx)+math.abs(ny)+math.abs(nz))*sy*sy<=1e-8 then return false end
  local unit_y=ny/math.sqrt(nx*nx+ny*ny+nz*nz)
  if math.abs(unit_y)<=1e-6 then return false end
  if unit_y>0 then selected=selected+3 end
 end
 return selected==count
end
local function candidate_face(core,part,collect_layers)
 if type(part)~='table'
  or part.MeshOwner~='SpecialMesh' or part.Transparency~=1 or part._loaded_map_mirror_x then return end
 local kind=core.SPECIAL_MESH_TYPE_ENUM[tonumber(part.SpecialMeshType)] or part.SpecialMeshType
 if kind~='Sphere' then return end
 local px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,sx,sy,sz=core._get_runtime_part_render_basis(part)
 if not supported_size(sx,sy,sz) or not is_rotation_basis(rx,ry,rz,ux,uy,uz,bx,by,bz) then return end
 -- `needs_rows` runs while every dynamic textured chunk is being built. its
 -- raw FaceTextures list is enough to reject ordinary Sphere meshes without
 -- asking the renderer to construct surface/gui layers. capture repeats the
 -- full collector after batching, which remains the authoritative check
 local faces=collect_layers and core._collect_part_face_textures(core,part) or part.FaceTextures
 if type(faces)~='table' then return end
 local face=faces[1]
 if #faces~=1 or face.class_name~='Decal' or core._enum_face_name(face.face)~='Top' then return end
 return face
end
function RetainedDecal.needs_rows(core,chunk)
 local part=chunk and chunk.dynamic_part
 -- this runs before the textured batch builder decides whether to retain CPU
 -- rows. keep the request as narrow as capture itself so unrelated dynamic
 -- Sphere meshes do not take the row-retention path only to be rejected later
 return candidate_face(core,part,false)~=nil
end
function RetainedDecal.release(core,chunk)
 local decal=chunk and chunk._fast_decal
 if not decal then return 0 end
 chunk._fast_decal=nil
 if decal.item and decal.item.rigid_pose==decal.gpu_pose then decal.item.rigid_pose=nil end
 if decal.data then decal.data:release()end
 decal.data,decal.dst,decal.rows,decal.current,decal.item,decal.part,decal.gpu_pose=nil,nil,nil,nil,nil,nil,nil
 core._retained_decal_cache_count=(core._retained_decal_cache_count or 1)-1
 return 1
end
function RetainedDecal.capture(core,chunk,part,capture)
 local face=candidate_face(core,part,true)
 if not face then return end
 if #(chunk.cube_instances or {})>0 or #(chunk.textured_batches or {})>0
  or #(chunk.overlay_textured_batches or {})>0 or #(chunk.opaque_static_draw_items or {})>0
  or #(chunk.transparent_draw_items or {})~=1 then return end
 local item=chunk.transparent_draw_items[1]
 if item.kind~='textured' or item.source_kind=='SurfaceGui' or (item.surface_geometry_face_count or 0)>0 then return end
 local px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,sx,sy,sz=core._get_runtime_part_render_basis(part)
 if not supported_size(sx,sy,sz) or not is_rotation_basis(rx,ry,rz,ux,uy,uz,bx,by,bz) then return end
 local vertices=item.cpu_vertices
 if type(vertices)~='table' or vertices.vbuf~=nil then return end
 if not stable_top(core._primitive_vertices.Ball,sy,#vertices) then return end
 local snapshot=capture(item)
 if not snapshot then return end
 local src=snapshot.src;local local_rows=ffi.new('double[?]',snapshot.count*6)
 local bias=core._get_scaled_decal_surface_offset(core,math.max(sx,sy,sz),part)
 for j=0,snapshot.count-1 do
  local a,o=j*20,j*6
  local v=vertices[j+1]
  local x,y,z=v[1]-px-v[4]*bias,v[2]-py-v[5]*bias,v[3]-pz-v[6]*bias
  local_rows[o]=(x*rx+y*ry+z*rz)/sx
  local_rows[o+1]=(x*ux+y*uy+z*uz)/sy
  local_rows[o+2]=(x*bx+y*by+z*bz)/sz
  x,y,z=v[4],v[5],v[6]
  local_rows[o+3]=(x*rx+y*ry+z*rz)*sx
  local_rows[o+4]=(x*ux+y*uy+z*uz)*sy
  local_rows[o+5]=(x*bx+y*by+z*bz)*sz
 end
 local gpu_pose
 if core.retain_decal_gpu_pose==true then
  gpu_pose={rows={{1,0,0,0},{0,1,0,0},{0,0,1,0}},revision=0}
  item.rigid_pose=gpu_pose
 else item.rigid_pose=nil end
 item.cpu_vertices=nil
 chunk._fast_decal={part=part,item=item,rows=local_rows,current=ffi.new('double[?]',snapshot.count*6),data=snapshot.dst_data,dst=snapshot.dst,
  count=snapshot.count,prop=part._render_prop_revision or 0,size_revision=part._render_size_revision or 0,
  sy=sy,face=face,face_depth=core._get_face_texture_depth_bias(core,part,face,math.max(sx,sy,sz)),
  source_geometry=core._primitive_vertices.Ball,transparent_depth_bias=core.transparent_depth_bias,gpu_pose=gpu_pose}
 if gpu_pose then capture_gpu_pose(chunk._fast_decal,px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,item)end
 core._retained_decal_cache_count=(core._retained_decal_cache_count or 0)+1
 return true
end
function RetainedDecal.update(core,chunk,part)
 local decal=chunk._fast_decal
 if not decal or decal.part~=part or part._destroyed then return false end
 if (part._render_prop_revision or 0)-decal.prop~=(part._render_size_revision or 0)-decal.size_revision then
  RetainedDecal.release(core,chunk);return false
 end
 local px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,sx,sy,sz=core._get_runtime_part_render_basis(part)
 if sy~=decal.sy or not supported_size(sx,sy,sz) or not is_rotation_basis(rx,ry,rz,ux,uy,uz,bx,by,bz) or core._primitive_vertices.Ball~=decal.source_geometry
  or core.transparent_depth_bias~=decal.transparent_depth_bias
  or core._get_face_texture_depth_bias(core,part,decal.face,math.max(sx,sy,sz))~=decal.face_depth then
  RetainedDecal.release(core,chunk);return false
 end
 -- an unchanged-size update is a rigid change of the already-offset decal
 -- rows. keep its GPU buffer resident and use the existing shader pose path
 -- the experiment is opt-in on the renderer, Size writes retain the exact CPU
 -- rebuild below because scale changes alter the normal-directed offset
 if decal.gpu_pose and (part._render_size_revision or 0)==decal.size_revision then
  local m00=rx*decal.base_rx+ux*decal.base_ux+bx*decal.base_bx
  local m01=rx*decal.base_ry+ux*decal.base_uy+bx*decal.base_by
  local m02=rx*decal.base_rz+ux*decal.base_uz+bx*decal.base_bz
  local m10=ry*decal.base_rx+uy*decal.base_ux+by*decal.base_bx
  local m11=ry*decal.base_ry+uy*decal.base_uy+by*decal.base_by
  local m12=ry*decal.base_rz+uy*decal.base_uz+by*decal.base_bz
  local m20=rz*decal.base_rx+uz*decal.base_ux+bz*decal.base_bx
  local m21=rz*decal.base_ry+uz*decal.base_uy+bz*decal.base_by
  local m22=rz*decal.base_rz+uz*decal.base_uz+bz*decal.base_bz
  local tx=px-(m00*decal.base_px+m01*decal.base_py+m02*decal.base_pz)
  local ty=py-(m10*decal.base_px+m11*decal.base_py+m12*decal.base_pz)
  local tz=pz-(m20*decal.base_px+m21*decal.base_py+m22*decal.base_pz)
  local a,b,c=decal.gpu_pose.rows[1],decal.gpu_pose.rows[2],decal.gpu_pose.rows[3]
  a[1],a[2],a[3],a[4]=m00,m01,m02,tx
  b[1],b[2],b[3],b[4]=m10,m11,m12,ty
  c[1],c[2],c[3],c[4]=m20,m21,m22,tz
  decal.gpu_pose.revision=decal.gpu_pose.revision+1
  local item=decal.item
  item.sort_x=m00*decal.base_sort_x+m01*decal.base_sort_y+m02*decal.base_sort_z+tx
  item.sort_y=m10*decal.base_sort_x+m11*decal.base_sort_y+m12*decal.base_sort_z+ty
  item.sort_z=m20*decal.base_sort_x+m21*decal.base_sort_y+m22*decal.base_sort_z+tz
  transform_bounds(decal.base_item_bounds,m00,m01,m02,m10,m11,m12,m20,m21,m22,tx,ty,tz,item.bounds)
  local bounds=core:_get_part_render_bounds(part);local cb=chunk.bounds
  cb.min_x,cb.min_y,cb.min_z=math.min(bounds.min_x,item.bounds.min_x),math.min(bounds.min_y,item.bounds.min_y),math.min(bounds.min_z,item.bounds.min_z)
  cb.max_x,cb.max_y,cb.max_z=math.max(bounds.max_x,item.bounds.max_x),math.max(bounds.max_y,item.bounds.max_y),math.max(bounds.max_z,item.bounds.max_z);update_bounds(cb)
  chunk._settled_content_revision=(chunk._settled_content_revision or 0)+1
  core._fast_rebake_count=(core._fast_rebake_count or 0)+1
  core._retained_decal_update_count=(core._retained_decal_update_count or 0)+1
  core._retained_decal_gpu_pose_update_count=(core._retained_decal_gpu_pose_update_count or 0)+1
  return true
 end
 local bias=core._get_scaled_decal_surface_offset(core,math.max(sx,sy,sz),part)
 local src,dst,current=decal.rows,decal.dst,decal.current
 local minx,miny,minz,maxx,maxy,maxz=math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge
 local sumx,sumy,sumz=0,0,0
 for j=0,decal.count-1 do
  local a,o=j*20,j*6
  local nx,ny,nz=src[o+3]/sx,src[o+4]/sy,src[o+5]/sz
  local inverse=1/math.sqrt(nx*nx+ny*ny+nz*nz);nx,ny,nz=nx*inverse,ny*inverse,nz*inverse
  local wx,wy,wz=rx*nx+ux*ny+bx*nz,ry*nx+uy*ny+by*nz,rz*nx+uz*ny+bz*nz
  local x,y,z=src[o]*sx,src[o+1]*sy,src[o+2]*sz
  x,y,z=px+rx*x+ux*y+bx*z+wx*bias,py+ry*x+uy*y+by*z+wy*bias,pz+rz*x+uz*y+bz*z+wz*bias
  dst[a],dst[a+1],dst[a+2]=x,y,z;dst[a+3],dst[a+4],dst[a+5]=wx,wy,wz
  current[o],current[o+1],current[o+2]=x,y,z;current[o+3],current[o+4],current[o+5]=wx,wy,wz
  minx,miny,minz=math.min(minx,x),math.min(miny,y),math.min(minz,z)
  maxx,maxy,maxz=math.max(maxx,x),math.max(maxy,y),math.max(maxz,z)
  sumx,sumy,sumz=sumx+x,sumy+y,sumz+z
 end
 for a=0,(decal.count-1)*20,60 do
  local o=a/20*6
  local nx,ny,nz=current[o+3]+current[o+9]+current[o+15],current[o+4]+current[o+10]+current[o+16],current[o+5]+current[o+11]+current[o+17]
  local inverse=1/math.sqrt(nx*nx+ny*ny+nz*nz);nx,ny,nz=nx*inverse,ny*inverse,nz*inverse
  local tx,ty,tz,btx,bty,btz=core._compute_textured_tangent_basis(
   current[o],current[o+1],current[o+2],dst[a+6],dst[a+7],
   current[o+6],current[o+7],current[o+8],dst[a+26],dst[a+27],
   current[o+12],current[o+13],current[o+14],dst[a+46],dst[a+47],nx,ny,nz)
  for o=a,a+40,20 do dst[o+13],dst[o+14],dst[o+15]=tx,ty,tz;dst[o+16],dst[o+17],dst[o+18]=btx,bty,btz end
 end
 local item=decal.item
 if decal.gpu_pose then reset_gpu_pose(decal);item.rigid_pose=decal.gpu_pose end
 require('engine/graphics/rbx/runtime/shadow_array').invalidate(item.mesh)
 local ok=pcall(item.mesh.setVertices,item.mesh,decal.data)
 if not ok then RetainedDecal.release(core,chunk);return false end
 if core._note_gpu_upload_bytes then core:_note_gpu_upload_bytes(decal.count*80)end
 core._mesh_uploads_total=(core._mesh_uploads_total or 0)+1
 core._retained_decal_upload_count=(core._retained_decal_upload_count or 0)+1
 core._retained_decal_upload_bytes=(core._retained_decal_upload_bytes or 0)+decal.count*80
 item.sort_x,item.sort_y,item.sort_z=sumx/decal.count,sumy/decal.count,sumz/decal.count
 local b=item.bounds;b.min_x,b.min_y,b.min_z,b.max_x,b.max_y,b.max_z=minx,miny,minz,maxx,maxy,maxz;update_bounds(b)
 local bounds=core:_get_part_render_bounds(part)
 local cb=chunk.bounds
 cb.min_x,cb.min_y,cb.min_z=math.min(bounds.min_x,minx),math.min(bounds.min_y,miny),math.min(bounds.min_z,minz)
 cb.max_x,cb.max_y,cb.max_z=math.max(bounds.max_x,maxx),math.max(bounds.max_y,maxy),math.max(bounds.max_z,maxz);update_bounds(cb)
 if decal.gpu_pose then
  decal.prop,decal.size_revision=part._render_prop_revision or 0,part._render_size_revision or 0
  capture_gpu_pose(decal,px,py,pz,rx,ry,rz,ux,uy,uz,bx,by,bz,item)
 end
 chunk._settled_content_revision=(chunk._settled_content_revision or 0)+1
 core._fast_rebake_count=(core._fast_rebake_count or 0)+1
 core._retained_decal_update_count=(core._retained_decal_update_count or 0)+1
 return true
end
return RetainedDecal
