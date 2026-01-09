--!strict
-- [Ability Name] System Template
-- Copy this file to create a new ability's system logic
-- 1. Copy this entire _Templates folder
-- 2. Rename folder to your ability name (e.g., "Fireball")
-- 3. Rename this file to "System.lua"
-- 4. Implement the logic below (or use the simple version)

local AbilitySystemBase = require(script.Parent.Parent.AbilitySystemBase)
local Config = require(script.Parent.Config)
local Balance = Config  -- Backward compatibility alias

local YourAbilitySystem = {}

local world: any
local Components: any
local DirtyService: any
local ECSWorldService: any

-- Your ability ID (should match folder name)
local ABILITY_ID = script.Parent.Name
local ABILITY_NAME = Balance.Name

-- Initialize the system (REQUIRED)
function YourAbilitySystem.init(worldRef: any, components: any, dirtyService: any, ecsWorldService: any)
	world = worldRef
	Components = components
	DirtyService = dirtyService
	ECSWorldService = ecsWorldService
	
	-- Initialize base system with shared references
	AbilitySystemBase.init(worldRef, components, dirtyService, ecsWorldService)
end

-- Step function called every frame (REQUIRED)
function YourAbilitySystem.step(dt: number)
	if not world then
		return
	end
	
	-- Query all players with this ability
	local playerQuery = world:query(Components.EntityType, Components.Position, Components.Ability)
	for entity, entityType, position, ability in playerQuery do
		if entityType.type == "Player" and entityType.player then
			local player = entityType.player
			local abilityData = world:get(entity, Components.AbilityData)
			
			if abilityData and abilityData.type == ABILITY_ID then
				-- Get or create cooldown component
				local cooldown = world:get(entity, Components.AbilityCooldown)
				if not cooldown then
					world:set(entity, Components.AbilityCooldown, {
						id = ABILITY_ID,
						name = ABILITY_NAME,
						remaining = 0,
						max = Balance.cooldown,
					})
					cooldown = world:get(entity, Components.AbilityCooldown)
				end
				
				-- Cast ability when cooldown is ready
				if cooldown.remaining <= 0 then
					local success = castAbility(entity, player)
					if success then
						-- Reset cooldown
						DirtyService.setIfChanged(world, entity, Components.AbilityCooldown, {
							id = ABILITY_ID,
							name = ABILITY_NAME,
							remaining = Balance.cooldown,
							max = Balance.cooldown,
						}, "AbilityCooldown")
					end
				else
					-- Update cooldown timer
					DirtyService.setIfChanged(world, entity, Components.AbilityCooldown, {
						id = cooldown.id or ABILITY_ID,
						name = cooldown.name or ABILITY_NAME,
						remaining = math.max((cooldown.remaining or 0) - dt, 0),
						max = cooldown.max or Balance.cooldown,
					}, "AbilityCooldown")
				end
			end
		end
	end
end

-- Cast the ability (customize this function)
local function castAbility(playerEntity: number, player: Player): boolean
	-- Get player position
	local position = AbilitySystemBase.getPlayerPosition(playerEntity, player)
	if not position then
		return false
	end
	
	-- Find nearest enemy
	local targetEntity = AbilitySystemBase.findNearestEnemy(position, Balance.targetingRange)
	local targetPosition: Vector3
	
	if targetEntity then
		targetPosition = AbilitySystemBase.getEnemyCenterPosition(targetEntity)
	else
		-- No target, fire forward
		local character = player.Character
		local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
		if humanoidRootPart then
			targetPosition = position + humanoidRootPart.CFrame.LookVector * Balance.targetingRange
		else
			targetPosition = position + Vector3.new(Balance.targetingRange, 0, 0)
		end
	end
	
	-- Calculate direction
	local direction = (targetPosition - position).Unit
	
	-- Create projectile using shared system
	local projectileEntity = AbilitySystemBase.createProjectile(
		ABILITY_ID,
		Balance,
		position,
		direction,
		player,
		targetPosition
	)
	
	return projectileEntity ~= nil
end

return YourAbilitySystem
