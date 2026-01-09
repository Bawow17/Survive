--!strict
-- EntityTypes.lua - Client-safe entity type definitions
-- Contains only the information clients need for rendering

-- Entity type constants for client rendering
local EntityTypes = {
    ENEMY = "Enemy",
    PROJECTILE = "Projectile", 
    ITEM = "Item",
    PLAYER = "Player",
}

-- Enemy subtypes for model loading
local EnemySubtypes = {
    ZOMBIE = "Zombie",
    CHARGER = "Charger",
    GOBLIN = "Goblin",
    ORC = "Orc",
    SKELETON = "Skeleton",
    SPIDER = "Spider",
}

-- Projectile subtypes for model loading
local ProjectileSubtypes = {
    MAGIC_BOLT = "MagicBolt",
    FIREBALL = "Fireball",
    ICE_SHARD = "IceShard",
    LIGHTNING = "Lightning",
}

-- Item subtypes for model loading
local ItemSubtypes = {
    POWERUP = "Powerup",
    EXPERIENCE = "Experience",
    COIN = "Coin",
}

return {
    EntityTypes = EntityTypes,
    EnemySubtypes = EnemySubtypes,
    ProjectileSubtypes = ProjectileSubtypes,
    ItemSubtypes = ItemSubtypes,
}
