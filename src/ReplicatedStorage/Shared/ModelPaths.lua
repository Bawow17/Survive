--!strict
-- ModelPaths.lua - Client-safe model path definitions
-- Contains model paths for client-side rendering
-- Models are replicated from ServerStorage to ReplicatedStorage on-demand

local ModelPaths = {
    -- Enemy models (replicated when needed)
    Enemies = {
        Zombie = "ReplicatedStorage.ContentDrawer.Enemies.Mobs.Zombie",
        Charger = "ReplicatedStorage.ContentDrawer.Enemies.Mobs.Charger",
        -- Additional enemy types will be added when replicated
    },
    
    -- Projectile models (replicated when needed)
    Projectiles = {
        MagicBolt = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.MagicBolt.MagicBolt",
        FireBall = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.FireBall.FireBall",
        FireBallExplosion = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.FireBall.Explosion",
        IceShard = "ReplicatedStorage.ContentDrawer.Attacks.Abilties.IceShard.IceShard",
        -- Additional projectile types will be added when replicated
    },
    
    -- Item models (some already replicated)
    Items = {
        -- Powerup models (already in ReplicatedStorage)
        ArcaneRune = "ReplicatedStorage.ContentDrawer.ItemModels.Powerups.ArcaneRune",
        Cloak = "ReplicatedStorage.ContentDrawer.ItemModels.Powerups.Cloak",
        Health = "ReplicatedStorage.ContentDrawer.ItemModels.Powerups.Health",
        Magnet = "ReplicatedStorage.ContentDrawer.ItemModels.Powerups.Magnet",
        Nuke = "ReplicatedStorage.ContentDrawer.ItemModels.Powerups.Nuke",
        
        -- Experience/Coin models will be added when replicated
        Experience = "ReplicatedStorage.ContentDrawer.Items.Experience.Experience",
        Coin = "ReplicatedStorage.ContentDrawer.Items.Coin.Coin",
    },
    
    -- Player models (if needed)
    Players = {
        Player = "ReplicatedStorage.ContentDrawer.Players.Player",
    },
}

-- Helper function to get model path
local function getModelPath(entityType: string, subtype: string?): string?
    if entityType == "Enemy" and subtype then
        return ModelPaths.Enemies[subtype]
    elseif entityType == "Projectile" and subtype then
        return ModelPaths.Projectiles[subtype]
    elseif entityType == "Item" and subtype then
        return ModelPaths.Items[subtype]
    elseif entityType == "Player" and subtype then
        return ModelPaths.Players[subtype]
    end
    return nil
end

-- Helper function to check if model path exists
local function modelPathExists(entityType: string, subtype: string?): boolean
    local path = getModelPath(entityType, subtype)
    if not path then return false end
    
    -- Convert string path to actual Instance path
    local parts = string.split(path, ".")
    local current = game
    for _, part in ipairs(parts) do
        if part == "ReplicatedStorage" then
            current = game.ReplicatedStorage
        elseif current and current:FindFirstChild(part) then
            current = current:FindFirstChild(part)
        else
            return false
        end
    end
    return current ~= nil
end

return {
    ModelPaths = ModelPaths,
    getModelPath = getModelPath,
    modelPathExists = modelPathExists,
}