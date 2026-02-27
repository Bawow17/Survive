--!strict
-- ItemGridLayoutController - Keeps TopBar item viewports in a responsive integer-column grid.

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
if not playerScripts then
	playerScripts = localPlayer:WaitForChild("PlayerScripts", 10)
end
local scriptsContainer = playerScripts or script:FindFirstAncestor("StarterPlayerScripts")
if not scriptsContainer then
	warn("[ItemGridLayoutController] Could not locate StarterPlayerScripts ancestor")
	return
end
local localSharedFolder = scriptsContainer:WaitForChild("_Shared", 10)
if not localSharedFolder then
	warn("[ItemGridLayoutController] Could not locate _Shared folder")
	return
end

local MainHUDLocator = require(localSharedFolder:WaitForChild("MainHUDLocator"))

local mainHUD = MainHUDLocator.waitForMainHUD(playerGui)

local topBarFrame = mainHUD:WaitForChild("TopBarFrame", 10)
if not topBarFrame or not topBarFrame:IsA("GuiObject") then
	warn("[ItemGridLayoutController] MainHUD.TopBarFrame not found")
	return
end

local itemsFrame = topBarFrame:WaitForChild("Items", 10)
if not itemsFrame or not itemsFrame:IsA("GuiObject") then
	warn("[ItemGridLayoutController] MainHUD.TopBarFrame.Items not found")
	return
end

local grid = itemsFrame:WaitForChild("UIGridLayout", 10)
if not grid or not grid:IsA("UIGridLayout") then
	warn("[ItemGridLayoutController] MainHUD.TopBarFrame.Items.UIGridLayout not found")
	return
end

local function ensureSquareConstraint(viewport: ViewportFrame)
	local constraint = viewport:FindFirstChildOfClass("UIAspectRatioConstraint")
	if not constraint then
		constraint = Instance.new("UIAspectRatioConstraint")
		constraint.Parent = viewport
	end
	constraint.AspectRatio = 1
	constraint.DominantAxis = Enum.DominantAxis.Height
end

local isApplyingLayout = false
local layoutQueued = false
local viewportVisibleConnections: {[ViewportFrame]: RBXScriptConnection} = {}
local baseItemsSize = itemsFrame.Size
local MIN_ROWS = 2

local function applyLayout()
	if isApplyingLayout then
		return
	end
	isApplyingLayout = true

	local parent = itemsFrame.Parent
	if not parent or not parent:IsA("GuiObject") then
		isApplyingLayout = false
		return
	end

	local containerWidth = itemsFrame.AbsoluteSize.X
	local containerHeight = itemsFrame.AbsoluteSize.Y
	local parentWidth = parent.AbsoluteSize.X

	if containerWidth <= 0 or containerHeight <= 0 or parentWidth <= 0 then
		isApplyingLayout = false
		return
	end

	local visibleViewportCount = 0
	for _, child in ipairs(itemsFrame:GetChildren()) do
		if child:IsA("ViewportFrame") then
			ensureSquareConstraint(child)
			if child.Visible then
				visibleViewportCount += 1
			end
		end
	end

	grid.CellPadding = UDim2.fromScale(0, 0)
	grid.FillDirection = Enum.FillDirection.Horizontal

	-- Use the original width budget relative to parent so layout can grow back after shrinking.
	local maxAvailableWidth = (parentWidth * baseItemsSize.X.Scale) + baseItemsSize.X.Offset
	if maxAvailableWidth <= 0 then
		maxAvailableWidth = containerWidth
	end

	local rows = MIN_ROWS
	local columns = 1
	local cellSide = containerHeight / rows
	local maxRows = math.max(MIN_ROWS, visibleViewportCount, 200)

	while true do
		cellSide = containerHeight / rows
		columns = math.max(1, math.floor(maxAvailableWidth / cellSide))

		if visibleViewportCount <= 0 then
			break
		end
		if (columns * rows) >= visibleViewportCount then
			break
		end
		if rows >= maxRows then
			break
		end
		rows += 1
	end

	local snappedWidth = math.min(columns * cellSide, maxAvailableWidth)
	local xScale = math.clamp(snappedWidth / parentWidth, 0, 1)

	grid.FillDirectionMaxCells = columns
	grid.CellSize = UDim2.new(1 / columns, 0, 1 / rows, 0)

	local currentSize = itemsFrame.Size
	if math.abs(currentSize.X.Scale - xScale) > 0.0005 or currentSize.X.Offset ~= 0 then
		itemsFrame.Size = UDim2.new(xScale, 0, currentSize.Y.Scale, currentSize.Y.Offset)
	end

	isApplyingLayout = false
end

local function queueLayout()
	if layoutQueued then
		return
	end
	layoutQueued = true
	task.defer(function()
		layoutQueued = false
		applyLayout()
	end)
end

local function disconnectViewportListeners()
	for viewport, conn in pairs(viewportVisibleConnections) do
		if conn.Connected then
			conn:Disconnect()
		end
		viewportVisibleConnections[viewport] = nil
	end
end

local function reconnectViewportListeners()
	disconnectViewportListeners()
	for _, child in ipairs(itemsFrame:GetChildren()) do
		if child:IsA("ViewportFrame") then
			viewportVisibleConnections[child] = child:GetPropertyChangedSignal("Visible"):Connect(queueLayout)
		end
	end
end

itemsFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)
itemsFrame.ChildAdded:Connect(function()
	reconnectViewportListeners()
	queueLayout()
end)
itemsFrame.ChildRemoved:Connect(function()
	reconnectViewportListeners()
	queueLayout()
end)

local itemsParent = itemsFrame.Parent
if itemsParent and itemsParent:IsA("GuiObject") then
	itemsParent:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)
end

reconnectViewportListeners()
queueLayout()
