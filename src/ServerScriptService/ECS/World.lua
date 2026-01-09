--!strict
-- ECS World - Server-only ECS world initialization and management
-- Based on: https://github.com/Ukendio/jecs

local ServerStorage = game:GetService("ServerStorage")
local jecs = require(ServerStorage.Packages.jecs)

-- Create the main ECS world (server-only)
local world = jecs.World.new()

-- Export the world for use across server systems
return world