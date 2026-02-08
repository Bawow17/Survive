--!strict

local PlayerSettingsSchema = {}

export type SettingsV1 = {
	version: number,
	graphics: {
		enemyRenderScale: number,
		chunkRenderScale: number,
		projectileOpacitySelf: number,
		projectileOpacityOthers: number,
		otherPlayerVfxOpacity: number,
	},
	accessibility: {
		reduceFlash: boolean,
		reduceMotion: boolean,
	},
	controls: {
		settingsHotkeyEnabled: boolean,
	},
}

local VERSION = 1

local DEFAULTS: SettingsV1 = {
	version = VERSION,
	graphics = {
		enemyRenderScale = 1.0,
		chunkRenderScale = 1.0,
		projectileOpacitySelf = 1.0,
		projectileOpacityOthers = 1.0,
		otherPlayerVfxOpacity = 1.0,
	},
	accessibility = {
		reduceFlash = false,
		reduceMotion = false,
	},
	controls = {
		settingsHotkeyEnabled = true,
	},
}

PlayerSettingsSchema.DEFAULTS = DEFAULTS
PlayerSettingsSchema.VERSION = VERSION

local function clamp(value: any, minimum: number, maximum: number, fallback: number): number
	if typeof(value) == "number" then
		return math.clamp(value, minimum, maximum)
	end
	return fallback
end

local function clampToStep(value: any, minimum: number, maximum: number, step: number, fallback: number): number
	if typeof(value) ~= "number" then
		return fallback
	end
	local clamped = math.clamp(value, minimum, maximum)
	local snapped = minimum + (math.round((clamped - minimum) / step) * step)
	return math.clamp(snapped, minimum, maximum)
end

local function asBoolean(value: any, fallback: boolean): boolean
	if typeof(value) == "boolean" then
		return value
	end
	return fallback
end

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, nestedValue in pairs(value) do
		copy[key] = deepCopy(nestedValue)
	end
	return copy
end

local function sanitizeInternal(raw: any): SettingsV1
	local source = if typeof(raw) == "table" then raw else {}
	local graphics = if typeof(source.graphics) == "table" then source.graphics else {}
	local accessibility = if typeof(source.accessibility) == "table" then source.accessibility else {}
	local controls = if typeof(source.controls) == "table" then source.controls else {}
	local legacyRenderScale = if typeof(graphics.renderScale) == "number" then graphics.renderScale else nil

	return {
		version = VERSION,
		graphics = {
			enemyRenderScale = clampToStep(graphics.enemyRenderScale or legacyRenderScale, 0.50, 10.00, 0.50, DEFAULTS.graphics.enemyRenderScale),
			chunkRenderScale = clampToStep(graphics.chunkRenderScale, 0.50, 10.00, 0.50, DEFAULTS.graphics.chunkRenderScale),
			projectileOpacitySelf = clamp(graphics.projectileOpacitySelf, 0.25, 1.00, DEFAULTS.graphics.projectileOpacitySelf),
			projectileOpacityOthers = clamp(graphics.projectileOpacityOthers, 0.05, 1.00, DEFAULTS.graphics.projectileOpacityOthers),
			otherPlayerVfxOpacity = clamp(graphics.otherPlayerVfxOpacity, 0.00, 1.00, DEFAULTS.graphics.otherPlayerVfxOpacity),
		},
		accessibility = {
			reduceFlash = asBoolean(accessibility.reduceFlash, DEFAULTS.accessibility.reduceFlash),
			reduceMotion = asBoolean(accessibility.reduceMotion, DEFAULTS.accessibility.reduceMotion),
		},
		controls = {
			settingsHotkeyEnabled = asBoolean(controls.settingsHotkeyEnabled, DEFAULTS.controls.settingsHotkeyEnabled),
		},
	}
end

local function mergeKnown(base: SettingsV1, patch: any): SettingsV1
	local merged: SettingsV1 = deepCopy(base)
	if typeof(patch) ~= "table" then
		return merged
	end

	if typeof(patch.graphics) == "table" then
		local incoming = patch.graphics
		if incoming.enemyRenderScale ~= nil then
			merged.graphics.enemyRenderScale = incoming.enemyRenderScale
		end
		if incoming.chunkRenderScale ~= nil then
			merged.graphics.chunkRenderScale = incoming.chunkRenderScale
		end
		if incoming.renderScale ~= nil then
			merged.graphics.enemyRenderScale = incoming.renderScale
		end
		if incoming.projectileOpacitySelf ~= nil then
			merged.graphics.projectileOpacitySelf = incoming.projectileOpacitySelf
		end
		if incoming.projectileOpacityOthers ~= nil then
			merged.graphics.projectileOpacityOthers = incoming.projectileOpacityOthers
		end
		if incoming.otherPlayerVfxOpacity ~= nil then
			merged.graphics.otherPlayerVfxOpacity = incoming.otherPlayerVfxOpacity
		end
	end

	if typeof(patch.accessibility) == "table" then
		local incoming = patch.accessibility
		if incoming.reduceFlash ~= nil then
			merged.accessibility.reduceFlash = incoming.reduceFlash
		end
		if incoming.reduceMotion ~= nil then
			merged.accessibility.reduceMotion = incoming.reduceMotion
		end
	end

	if typeof(patch.controls) == "table" then
		local incoming = patch.controls
		if incoming.settingsHotkeyEnabled ~= nil then
			merged.controls.settingsHotkeyEnabled = incoming.settingsHotkeyEnabled
		end
	end

	return merged
end

function PlayerSettingsSchema.sanitize(raw: any): SettingsV1
	return sanitizeInternal(raw)
end

function PlayerSettingsSchema.mergeAndSanitize(base: any, patch: any): SettingsV1
	local sanitizedBase = sanitizeInternal(base)
	local merged = mergeKnown(sanitizedBase, patch)
	return sanitizeInternal(merged)
end

function PlayerSettingsSchema.createDefault(): SettingsV1
	return sanitizeInternal(DEFAULTS)
end

return PlayerSettingsSchema
