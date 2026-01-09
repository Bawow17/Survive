--!strict
-- OverhealSystem - Manages temporary health that decays over time
-- Overheal is damaged before actual health and decays at a configurable rate

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PowerupBalance = require(game.ServerScriptService.Balance.PowerupBalance)

local OverhealSystem = {}

local world: any
local Components: any
local DirtyService: any

local Overheal: any
local PlayerStats: any
local Health: any

-- Remote for notifying clients of overheal changes
local OverhealUpdate: RemoteEvent

-- Cached query for players with overheal
local overhealQuery: any

function OverhealSystem.init(worldRef: any, components: any, dirtyService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	
	Overheal = Components.Overheal
	PlayerStats = Components.PlayerStats
	Health = Components.Health
	
	-- Create cached query
	overhealQuery = world:query(Components.Overheal, Components.PlayerStats):cached()
	
	-- Get or create OverhealUpdate remote
	local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
	OverhealUpdate = remotes:FindFirstChild("OverhealUpdate")
	if not OverhealUpdate then
		OverhealUpdate = Instance.new("RemoteEvent")
		OverhealUpdate.Name = "OverhealUpdate"
		OverhealUpdate.Parent = remotes
	end
end

-- Broadcast overheal to client
local function broadcastToClient(playerEntity: number, overheal: any)
	local playerStats = world:get(playerEntity, PlayerStats)
	if not playerStats or not playerStats.player then
		return
	end
	
	-- Also set overheal as an attribute on the player for immediate client access
	local player = playerStats.player
	if player then
		player:SetAttribute("Overheal", overheal.current)
		player:SetAttribute("MaxOverheal", overheal.max)
	end
	
	OverhealUpdate:FireClient(player, {
		current = overheal.current,
		max = overheal.max,
	})
end

-- PUBLIC API: Grant overheal to a player
function OverhealSystem.grantOverheal(playerEntity: number, amount: number)
	if amount <= 0 then
		return
	end
	
	local existingOverheal = world:get(playerEntity, Overheal)
	local newAmount = amount
	
	if existingOverheal then
		-- Add to existing overheal
		newAmount = existingOverheal.current + amount
	end
	
	local overhealData = {
		current = newAmount,
		max = newAmount,
		decayRate = PowerupBalance.OverhealDecayRate,
	}
	
	-- Use world:set directly to ensure component is set immediately
	world:set(playerEntity, Overheal, overhealData)
	DirtyService.mark(playerEntity, "Overheal")
	broadcastToClient(playerEntity, overhealData)
end

-- PUBLIC API: Damage overheal (returns remaining damage that should go to actual health)
function OverhealSystem.damageOverheal(playerEntity: number, damageAmount: number): number
	local overheal = world:get(playerEntity, Overheal)
	if not overheal or overheal.current <= 0 then
		return damageAmount  -- No overheal, all damage goes to health
	end
	
	if damageAmount >= overheal.current then
		-- Damage exceeds overheal
		local remainingDamage = damageAmount - overheal.current
		
		-- Remove overheal component
		world:remove(playerEntity, Overheal)
		
		-- CRITICAL: Broadcast exact 0 values to client immediately
		local playerStats = world:get(playerEntity, PlayerStats)
		if playerStats and playerStats.player then
			local player = playerStats.player
			player:SetAttribute("Overheal", 0)
			player:SetAttribute("MaxOverheal", 0)
			OverhealUpdate:FireClient(player, {
				current = 0,
				max = 0,
			})
		end
		
		return remainingDamage
	else
		-- Damage absorbed by overheal
		overheal.current = math.max(0, overheal.current - damageAmount)
		
		-- Double-check for depletion after damage
		if overheal.current < 0.1 then
			world:remove(playerEntity, Overheal)
			local playerStats = world:get(playerEntity, PlayerStats)
			if playerStats and playerStats.player then
				local player = playerStats.player
				player:SetAttribute("Overheal", 0)
				player:SetAttribute("MaxOverheal", 0)
				OverhealUpdate:FireClient(player, {
					current = 0,
					max = 0,
				})
			end
			return 0
		end
		
		DirtyService.setIfChanged(world, playerEntity, Overheal, overheal, "Overheal")
		broadcastToClient(playerEntity, overheal)
		return 0  -- No damage to health
	end
end

-- PUBLIC API: Get current overheal amount
function OverhealSystem.getOverheal(playerEntity: number): number
	local overheal = world:get(playerEntity, Overheal)
	return overheal and overheal.current or 0
end

-- System step: Decay overheal over time
function OverhealSystem.step(dt: number)
	for entity in overhealQuery do
		local overheal = world:get(entity, Overheal)
		if not overheal then
			continue
		end
		
		-- Decay overheal
		local decayAmount = (overheal.decayRate or PowerupBalance.OverhealDecayRate) * dt
		overheal.current = math.max(0, overheal.current - decayAmount)
		
		if overheal.current <= 0.1 then
			-- Remove overheal component when depleted (with small threshold to avoid rounding errors)
			world:remove(entity, Overheal)
			
			-- Broadcast removal
			local playerStats = world:get(entity, PlayerStats)
			if playerStats and playerStats.player then
				local player = playerStats.player
				player:SetAttribute("Overheal", 0)
				player:SetAttribute("MaxOverheal", 0)
				OverhealUpdate:FireClient(player, {
					current = 0,
					max = 0,
				})
			end
		else
			-- Update overheal (only if significant amount remains)
			DirtyService.setIfChanged(world, entity, Overheal, overheal, "Overheal")
			broadcastToClient(entity, overheal)
		end
	end
end

return OverhealSystem

