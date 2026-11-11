--[[
-------------------------------------------------------------------------------
	Menori
	@author rozenmad
	2025
-------------------------------------------------------------------------------
]]

--[[--
Class provides instancing functionality for Meshes.
]]
-- @classmod InstancedMesh

local modules = (...):match('(.*%menori.modules.)')

local class = require (modules .. 'libs.class')
local utils = require (modules .. 'libs.utils')

local Mesh = require (modules .. 'core3d.mesh')

local lg = love.graphics

local InstancedMesh = class('InstancedMesh')

-- LÖVE 11 and 12 use different vertex-format spellings.  Mesh.lua already
-- handles this split for ordinary vertices; the instancing path must do the
-- same or its default constructor fails on the LÖVE 11.5 runtime this project
-- ships with.
local default_format
if love._version_major > 11 then
	default_format = {
		{name = "InstancePosition", format = "floatvec3"},
	}
else
	default_format = {
		{"InstancePosition", "float", 3},
	}
end

local function attribute_name(attribute)
	return attribute.name or attribute[1]
end

local function resolve_mesh(mesh)
	-- Public Menori API: InstancedMesh(Mesh(...)).  Older code in this module
	-- treated the argument as a Menori Mesh while reading metadata, then as a
	-- love.Mesh while attaching and drawing.  Accept both deliberately so the
	-- class is also useful as a zero-copy adapter around an existing LOVE mesh.
	if type(mesh) == "table" and mesh.lg_mesh then
		return mesh.lg_mesh, mesh
	end
	if type(mesh) == "userdata" and mesh.typeOf and mesh:typeOf("Mesh") then
		return mesh, nil
	end
	error("InstancedMesh expects a menori.Mesh or love.Mesh", 3)
end

local function collect_used_locations(mesh_wrapper, raw_mesh)
	if mesh_wrapper and mesh_wrapper.used_locations then
		return utils.copy(mesh_wrapper.used_locations)
	end
	local _, used_locations = Mesh.set_locations(raw_mesh:getVertexFormat())
	return used_locations
end

local function normalize_count(value)
	value = math.floor(tonumber(value) or 0)
	return math.max(0, value)
end

----
-- The public constructor.
function InstancedMesh:init(mesh, instanced_format, initial_capacity)
	instanced_format = instanced_format or default_format
	local raw_mesh, mesh_wrapper = resolve_mesh(mesh)
	self.mesh = mesh_wrapper
	self.lg_mesh = raw_mesh

	local used_locations = collect_used_locations(mesh_wrapper, raw_mesh)
	self.instanced_format, self.used_locations = Mesh.set_locations(instanced_format, used_locations)

	initial_capacity = math.max(1, normalize_count(initial_capacity or 16))
	self.instanced_mesh_buffer = love.graphics.newMesh(
		self.instanced_format, initial_capacity, 'triangles', 'dynamic')
	self.capacity = initial_capacity

	self.format_attribute_indices_map = {}
	for i, v in ipairs(self.instanced_format) do
		self.format_attribute_indices_map[attribute_name(v)] = i
	end

	self.vertexformat = utils.table_concat(
		mesh_wrapper and mesh_wrapper.vertexformat or raw_mesh:getVertexFormat(),
		self.instanced_format)

	self.count = 0
	self:_attach_buffer()
end

function InstancedMesh:increase_count()
	self:set_count(self.count + 1)
	return self.count
end

function InstancedMesh:decrease_count()
	self.count = math.max(0, self.count - 1)
	return self.count
end

function InstancedMesh:set_count(count)
	count = normalize_count(count)
	self:_reallocate(count)
	self.count = count
	return self.count
end

function InstancedMesh:set_instance_data(index, attribute_name, ...)
	index = normalize_count(index)
	assert(index >= 1, "instance index must be >= 1")
	self:_reallocate(index)
	local attribute_index = self.format_attribute_indices_map[attribute_name]
	assert(attribute_index, "unknown instance attribute '" .. tostring(attribute_name) .. "'")
	self.instanced_mesh_buffer:setVertexAttribute(index, attribute_index, ...)
end

-- Bulk upload is the normal path for a render batch.  It avoids N Lua method
-- calls and keeps count/capacity changes atomic from the caller's perspective.
function InstancedMesh:set_instances(vertices, count)
	count = normalize_count(count or #vertices)
	assert(type(vertices) == "table", "instances must be a vertex table")
	assert(#vertices >= count, "instance vertex table is shorter than count")
	self:_reallocate(count)
	if count > 0 then
		self.instanced_mesh_buffer:setVertices(vertices, 1, count)
	end
	self.count = count
	return count
end

function InstancedMesh:get_capacity()
	return self.capacity
end

function InstancedMesh:_reallocate(required_count)
	required_count = normalize_count(required_count)
	local old_buffer = self.instanced_mesh_buffer
	local instance_count = self.capacity or old_buffer:getVertexCount()
	if required_count <= instance_count then
		return false
	end

	local new_capacity = math.max(1, instance_count)
	while new_capacity < required_count do
		new_capacity = new_capacity * 2
	end

	-- Build and populate the replacement before touching the live attachment.
	-- If allocation or copying fails, the old buffer remains draw-ready.
	local temp_mesh
	local build_ok, build_error = pcall(function()
		temp_mesh = love.graphics.newMesh(
			self.instanced_format, new_capacity, 'triangles', 'dynamic')
		for i = 1, instance_count do
			temp_mesh:setVertex(i, old_buffer:getVertex(i))
		end
	end)
	if not build_ok then
		if temp_mesh then
			pcall(temp_mesh.release, temp_mesh)
		end
		error(build_error, 0)
	end

	local detach_ok, detach_error = pcall(self._detach_buffer, self)
	if not detach_ok then
		-- A driver may detach only a prefix of the attributes before failing.
		-- Re-attaching the still-live old buffer restores a coherent base mesh.
		pcall(self._attach_buffer, self)
		pcall(temp_mesh.release, temp_mesh)
		error(detach_error, 0)
	end

	self.instanced_mesh_buffer = temp_mesh
	self.capacity = new_capacity
	local attach_ok, attach_error = pcall(self._attach_buffer, self)
	if not attach_ok then
		-- Roll back ownership and every attribute alias atomically.
		self.instanced_mesh_buffer = old_buffer
		self.capacity = instance_count
		pcall(self._attach_buffer, self)
		pcall(temp_mesh.release, temp_mesh)
		error(attach_error, 0)
	end

	old_buffer:release()
	return true
end

function InstancedMesh:_attach_buffer()
	for i, v in ipairs(self.instanced_format) do
		self.lg_mesh:attachAttribute(attribute_name(v), self.instanced_mesh_buffer, "perinstance")
	end
end

function InstancedMesh:_detach_buffer()
	for i, v in ipairs(self.instanced_format) do
		self.lg_mesh:detachAttribute(attribute_name(v))
	end
end

function InstancedMesh:draw(material)
	material:send_to(material.shader)

	if material.wireframe ~= lg.isWireframe() then
		lg.setWireframe(material.wireframe)
	end
	if material.depth_test then
		if material.depth_func ~= lg.getDepthMode() then
			lg.setDepthMode(material.depth_func, true)
		end
	else
		lg.setDepthMode()
	end
	if material.mesh_cull_mode ~= lg.getMeshCullMode() then
		lg.setMeshCullMode(material.mesh_cull_mode)
	end

	local mesh = self.lg_mesh
	mesh:setTexture(material.main_texture)
	lg.drawInstanced(mesh, self.count)
end

function InstancedMesh:release()
	if not self.instanced_mesh_buffer then
		return
	end
	self:_detach_buffer()
	self.instanced_mesh_buffer:release()
	self.instanced_mesh_buffer = nil
	self.capacity = 0
	self.count = 0
end

return InstancedMesh
