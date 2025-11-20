-- Dev Tools + X/Y HUD + draggable + resizable window + scrollable Teleport list
-- + Auto Fishing Toggle + Keybind
-- LocalScript

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Prevent duplicate UIs if script is re-executed
local existing = playerGui:FindFirstChild("DevToolsGui")
if existing then
    existing:Destroy()
end

-- Track character / humanoid / HRP
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local hrp = character:WaitForChild("HumanoidRootPart")

local function hookCharacter(char)
    character = char
    humanoid = char:WaitForChild("Humanoid")
    hrp = char:WaitForChild("HumanoidRootPart")

    humanoid.Died:Connect(function()
        hrp = nil
    end)
end

hookCharacter(character)
player.CharacterAdded:Connect(hookCharacter)

---------------------------------------------------------------------
-- Auto Fishing integration (uses game’s remote)
---------------------------------------------------------------------
local autoFishingReady = false
local AutoFish_Data
local AutoFish_Remote

do
    local ok, result = pcall(function()
        local Net = require(ReplicatedStorage.Packages.Net)
        local Replion = require(ReplicatedStorage.Packages.Replion)

        local data = Replion.Client:WaitReplion("Data")
        local remote = Net:RemoteFunction("UpdateAutoFishingState")

        return {
            Data = data,
            Remote = remote,
        }
    end)

    if ok and result and result.Data and result.Remote then
        AutoFish_Data = result.Data
        AutoFish_Remote = result.Remote
        autoFishingReady = true
        print("[DevTools] Auto Fishing integration ready.")
    else
        warn("[DevTools] Auto Fishing integration unavailable in this game:", result)
    end
end

local function ToggleAutoFishing()
    if not autoFishingReady or not AutoFish_Data or not AutoFish_Remote then
        warn("[DevTools] Auto Fishing not available in this game.")
        return
    end

    local success, current = pcall(function()
        return AutoFish_Data:GetExpect("AutoFishing")
    end)

    if not success then
        warn("[DevTools] Failed to read AutoFishing state:", current)
        return
    end

    local newState = not current

    local ok, err = pcall(function()
        AutoFish_Remote:InvokeServer(newState)
    end)

    if ok then
        print("[DevTools] Auto Fishing is now:", newState and "ON" or "OFF")
        -- Game’s own AutoFishingStateChanged will show notification + handle logic
    else
        warn("[DevTools] Failed to toggle Auto Fishing:", err)
    end
end

-- UI-related AutoFishing state
local autoFishToggleButton -- checkbox-style button
local autoFishBindBtn      -- "Bind: None / Key"
local autoFishState = false
local autoFishHotkey = nil
local autoFishBindingActive = false

local function refreshAutoFishBindText()
    if not autoFishBindBtn then return end

    if autoFishBindingActive then
        autoFishBindBtn.Text = "Bind: ..."
    elseif autoFishHotkey then
        autoFishBindBtn.Text = "Bind: " .. autoFishHotkey.Name
    else
        autoFishBindBtn.Text = "Bind: None"
    end
end

local function updateAutoFishToggleVisual(state)
    autoFishState = state and true or false
    if autoFishToggleButton then
        if autoFishState then
            autoFishToggleButton.Text = "✔"
            autoFishToggleButton.TextColor3 = Color3.fromRGB(0, 200, 0)
        else
            autoFishToggleButton.Text = ""
            autoFishToggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
        end
    end
end

---------------------------------------------------------------------
-- Main ScreenGui
---------------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DevToolsGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.Parent = playerGui

-- forward-declare for devButton toggle
local settingsFrame

---------------------------------------------------------------------
-- Generic draggable helper
---------------------------------------------------------------------
local function makeDraggable(frame)
    local dragging = false
    local dragInput
    local dragStart
    local startPos
    local dragMoved = false

    if frame:GetAttribute("IsDragging") == nil then
        frame:SetAttribute("IsDragging", false)
    end
    if frame:GetAttribute("BlockDrag") == nil then
        frame:SetAttribute("BlockDrag", false)
    end

    local function update(input)
        local delta = input.Position - dragStart

        if not dragMoved and (math.abs(delta.X) > 6 or math.abs(delta.Y) > 6) then
            dragMoved = true
            frame:SetAttribute("IsDragging", true)
        end

        frame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end

    frame.InputBegan:Connect(function(input)
        if frame:GetAttribute("BlockDrag") then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then

            dragging = true
            dragMoved = false
            dragStart = input.Position
            startPos = frame.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    task.delay(0.05, function()
                        frame:SetAttribute("IsDragging", false)
                    end)
                end
            end)
        end
    end)

    frame.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            update(input)
        end
    end)
end

---------------------------------------------------------------------
-- Resizable helper (drag bottom-right corner, top-left stays fixed)
---------------------------------------------------------------------
local function makeResizable(window)
    local MIN_WIDTH, MIN_HEIGHT = 260, 220
    local HOT_SIZE = 12 -- clickable corner size

    local handle = Instance.new("Frame")
    handle.Name = "ResizeHandle"
    handle.Size = UDim2.new(0, HOT_SIZE, 0, HOT_SIZE)
    handle.AnchorPoint = Vector2.new(1, 1)
    handle.Position = UDim2.new(1, 0, 1, 0)
    handle.BackgroundTransparency = 1
    handle.BorderSizePixel = 0
    handle.Active = true
    handle.ZIndex = (window.ZIndex or 0) + 10
    handle.Parent = window

    local resizing = false
    local startInputPos
    local startSize

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then

            resizing = true
            window:SetAttribute("BlockDrag", true)
            startInputPos = input.Position
            startSize = window.Size

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    resizing = false
                    window:SetAttribute("BlockDrag", false)
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not resizing then return end

        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        local delta = input.Position - startInputPos

        local newWidth = math.max(MIN_WIDTH, startSize.X.Offset + delta.X)
        local newHeight = math.max(MIN_HEIGHT, startSize.Y.Offset + delta.Y)

        window.Size = UDim2.new(0, newWidth, 0, newHeight)
    end)
end

---------------------------------------------------------------------
-- Dev Tools Button (top-right) + icon size state
---------------------------------------------------------------------
local iconMinSize = 24
local iconMaxSize = 96
local currentIconSize = 36

local devButton = Instance.new("TextButton")
devButton.Name = "DevToolsButton"
devButton.Parent = screenGui
devButton.AnchorPoint = Vector2.new(1, 0)
devButton.Size = UDim2.new(0, currentIconSize, 0, currentIconSize)
devButton.Position = UDim2.new(1, -12, 0, 12)
devButton.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
devButton.BackgroundTransparency = 0.1
devButton.BorderSizePixel = 0
devButton.Text = "⚙"
devButton.Font = Enum.Font.SourceSansBold
devButton.TextSize = 22
devButton.TextColor3 = Color3.fromRGB(255, 255, 255)
devButton.AutoButtonColor = false
devButton.ZIndex = 5

local devBtnCorner = Instance.new("UICorner")
devBtnCorner.CornerRadius = UDim.new(0, 6)
devBtnCorner.Parent = devButton

local function setDevVisual(pressed)
    if pressed then
        devButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    else
        devButton.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    end
end

setDevVisual(false)

local draggingDev = false
local devDragStart
local devStartPos
local devDragInput
local devMoved = false
local DRAG_THRESHOLD = 5

local function updateDevButton(input)
    local delta = input.Position - devDragStart
    if delta.Magnitude > DRAG_THRESHOLD then
        devMoved = true
    end

    devButton.Position = UDim2.new(
        devStartPos.X.Scale,
        devStartPos.X.Offset + delta.X,
        devStartPos.Y.Scale,
        devStartPos.Y.Offset + delta.Y
    )
end

devButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        draggingDev = true
        devMoved = false
        devDragStart = input.Position
        devStartPos = devButton.Position
        setDevVisual(true)

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                draggingDev = false
                setDevVisual(false)
            end
        end)
    end
end)

devButton.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        devDragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == devDragInput and draggingDev then
        updateDevButton(input)
    end
end)

devButton.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        if not devMoved and settingsFrame then
            settingsFrame.Visible = not settingsFrame.Visible
        end
    end
end)

---------------------------------------------------------------------
-- Settings Panel ("Dev Tools" window) - BIGGER + RESIZABLE
---------------------------------------------------------------------
settingsFrame = Instance.new("Frame")
settingsFrame.Name = "DevToolsPanel"
settingsFrame.Parent = screenGui

local DEFAULT_WIDTH = 360
local DEFAULT_HEIGHT = 320

settingsFrame.AnchorPoint = Vector2.new(0, 0)
settingsFrame.Size = UDim2.new(0, DEFAULT_WIDTH, 0, DEFAULT_HEIGHT)
settingsFrame.Position = UDim2.new(0.5, -DEFAULT_WIDTH / 2, 0.5, -DEFAULT_HEIGHT / 2)
settingsFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
settingsFrame.BackgroundTransparency = 0.08
settingsFrame.BorderSizePixel = 0
settingsFrame.Visible = false
settingsFrame.ZIndex = 4

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 10)
panelCorner.Parent = settingsFrame

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(70, 70, 70)
panelStroke.Thickness = 1
panelStroke.Parent = settingsFrame

makeDraggable(settingsFrame)
makeResizable(settingsFrame)

local titleLabel = Instance.new("TextLabel")
titleLabel.Parent = settingsFrame
titleLabel.Size = UDim2.new(1, -16, 0, 24)
titleLabel.Position = UDim2.new(0, 8, 0, 6)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.SourceSansBold
titleLabel.TextSize = 18
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "Dev Tools"
titleLabel.ZIndex = 5

---------------------------------------------------------------------
-- Option: Show X/Y HUD
---------------------------------------------------------------------
local xyToggleButton = Instance.new("TextButton")
xyToggleButton.Name = "XYToggle"
xyToggleButton.Parent = settingsFrame
xyToggleButton.Size = UDim2.new(0, 18, 0, 18)
xyToggleButton.Position = UDim2.new(0, 12, 0, 40)
xyToggleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
xyToggleButton.BorderSizePixel = 0
xyToggleButton.Text = ""
xyToggleButton.ZIndex = 5

local xyToggleCorner = Instance.new("UICorner")
xyToggleCorner.CornerRadius = UDim.new(0, 3)
xyToggleCorner.Parent = xyToggleButton

local xyToggleLabel = Instance.new("TextButton")
xyToggleLabel.Name = "XYLabelButton"
xyToggleLabel.Parent = settingsFrame
xyToggleLabel.BackgroundTransparency = 1
xyToggleLabel.Size = UDim2.new(1, -40, 0, 24)
xyToggleLabel.Position = UDim2.new(0, 36, 0, 36)
xyToggleLabel.Font = Enum.Font.SourceSans
xyToggleLabel.TextSize = 16
xyToggleLabel.TextXAlignment = Enum.TextXAlignment.Left
xyToggleLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
xyToggleLabel.Text = "Show X / Y HUD"
xyToggleLabel.AutoButtonColor = true
xyToggleLabel.ZIndex = 5

---------------------------------------------------------------------
-- Icon size controls
---------------------------------------------------------------------
local iconSizeLabel = Instance.new("TextLabel")
iconSizeLabel.Parent = settingsFrame
iconSizeLabel.BackgroundTransparency = 1
iconSizeLabel.Size = UDim2.new(1, -24, 0, 20)
iconSizeLabel.Position = UDim2.new(0, 12, 0, 68)
iconSizeLabel.Font = Enum.Font.SourceSans
iconSizeLabel.TextSize = 16
iconSizeLabel.TextXAlignment = Enum.TextXAlignment.Left
iconSizeLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
iconSizeLabel.Text = ("Icon size: %d px"):format(currentIconSize)
iconSizeLabel.ZIndex = 5

local minusBtn = Instance.new("TextButton")
minusBtn.Name = "MinusBtn"
minusBtn.Parent = settingsFrame
minusBtn.Size = UDim2.new(0, 40, 0, 28)
minusBtn.Position = UDim2.new(0, 12, 0, 94)
minusBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
minusBtn.BorderSizePixel = 0
minusBtn.Font = Enum.Font.SourceSansBold
minusBtn.TextSize = 20
minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
minusBtn.Text = "-"
minusBtn.ZIndex = 5

local minusCorner = Instance.new("UICorner")
minusCorner.CornerRadius = UDim.new(0, 6)
minusCorner.Parent = minusBtn

local plusBtn = Instance.new("TextButton")
plusBtn.Name = "PlusBtn"
plusBtn.Parent = settingsFrame
plusBtn.Size = UDim2.new(0, 40, 0, 28)
plusBtn.Position = UDim2.new(0, 58, 0, 94)
plusBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
plusBtn.BorderSizePixel = 0
plusBtn.Font = Enum.Font.SourceSansBold
plusBtn.TextSize = 20
plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
plusBtn.Text = "+"
plusBtn.ZIndex = 5

local plusCorner = Instance.new("UICorner")
plusCorner.CornerRadius = UDim.new(0, 6)
plusCorner.Parent = plusBtn

local resetBtn = Instance.new("TextButton")
resetBtn.Name = "ResetBtn"
resetBtn.Parent = settingsFrame
resetBtn.Size = UDim2.new(0, 70, 0, 28)
resetBtn.Position = UDim2.new(0, 110, 0, 94)
resetBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
resetBtn.BorderSizePixel = 0
resetBtn.Font = Enum.Font.SourceSans
resetBtn.TextSize = 16
resetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
resetBtn.Text = "Reset"
resetBtn.ZIndex = 5

local resetCorner = Instance.new("UICorner")
resetCorner.CornerRadius = UDim.new(0, 6)
resetCorner.Parent = resetBtn

local function applyIconSize()
    currentIconSize = math.clamp(currentIconSize, iconMinSize, iconMaxSize)
    devButton.Size = UDim2.new(0, currentIconSize, 0, currentIconSize)
    iconSizeLabel.Text = ("Icon size: %d px"):format(currentIconSize)
end

minusBtn.MouseButton1Click:Connect(function()
    currentIconSize -= 4
    applyIconSize()
end)

plusBtn.MouseButton1Click:Connect(function()
    currentIconSize += 4
    applyIconSize()
end)

resetBtn.MouseButton1Click:Connect(function()
    currentIconSize = 36
    applyIconSize()
end)

---------------------------------------------------------------------
-- Auto Fishing UI: checkbox + Bind + Reset
---------------------------------------------------------------------
autoFishToggleButton = Instance.new("TextButton")
autoFishToggleButton.Name = "AutoFishToggle"
autoFishToggleButton.Parent = settingsFrame
autoFishToggleButton.Size = UDim2.new(0, 18, 0, 18)
autoFishToggleButton.Position = UDim2.new(0, 12, 0, 130)
autoFishToggleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
autoFishToggleButton.BorderSizePixel = 0
autoFishToggleButton.Text = ""
autoFishToggleButton.ZIndex = 5

local autoFishToggleCorner = Instance.new("UICorner")
autoFishToggleCorner.CornerRadius = UDim.new(0, 3)
autoFishToggleCorner.Parent = autoFishToggleButton

local autoFishLabel = Instance.new("TextButton")
autoFishLabel.Name = "AutoFishLabel"
autoFishLabel.Parent = settingsFrame
autoFishLabel.BackgroundTransparency = 1
autoFishLabel.Size = UDim2.new(1, -40, 0, 24)
autoFishLabel.Position = UDim2.new(0, 36, 0, 126)
autoFishLabel.Font = Enum.Font.SourceSans
autoFishLabel.TextSize = 16
autoFishLabel.TextXAlignment = Enum.TextXAlignment.Left
autoFishLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
autoFishLabel.Text = autoFishingReady and "Auto Fishing" or "Auto Fishing (N/A)"
autoFishLabel.AutoButtonColor = true
autoFishLabel.ZIndex = 5

autoFishBindBtn = Instance.new("TextButton")
autoFishBindBtn.Name = "AutoFishBindBtn"
autoFishBindBtn.Parent = settingsFrame
autoFishBindBtn.Size = UDim2.new(0, 110, 0, 24)
autoFishBindBtn.Position = UDim2.new(0, 12, 0, 160)
autoFishBindBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
autoFishBindBtn.BorderSizePixel = 0
autoFishBindBtn.Font = Enum.Font.SourceSans
autoFishBindBtn.TextSize = 16
autoFishBindBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
autoFishBindBtn.TextXAlignment = Enum.TextXAlignment.Center
autoFishBindBtn.AutoButtonColor = true
autoFishBindBtn.ZIndex = 5

local autoFishBindCorner = Instance.new("UICorner")
autoFishBindCorner.CornerRadius = UDim.new(0, 6)
autoFishBindCorner.Parent = autoFishBindBtn

local autoFishResetBindBtn = Instance.new("TextButton")
autoFishResetBindBtn.Name = "AutoFishResetBindBtn"
autoFishResetBindBtn.Parent = settingsFrame
autoFishResetBindBtn.Size = UDim2.new(0, 70, 0, 24)
autoFishResetBindBtn.Position = UDim2.new(0, 130, 0, 160)
autoFishResetBindBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
autoFishResetBindBtn.BorderSizePixel = 0
autoFishResetBindBtn.Font = Enum.Font.SourceSans
autoFishResetBindBtn.TextSize = 16
autoFishResetBindBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
autoFishResetBindBtn.Text = "Reset"
autoFishResetBindBtn.ZIndex = 5

local autoFishResetBindCorner = Instance.new("UICorner")
autoFishResetBindCorner.CornerRadius = UDim.new(0, 6)
autoFishResetBindCorner.Parent = autoFishResetBindBtn

refreshAutoFishBindText()

-- Sync initial state from game + subscribe to changes
if autoFishingReady and AutoFish_Data then
    local ok, initial = pcall(function()
        return AutoFish_Data:GetExpect("AutoFishing")
    end)
    if ok then
        updateAutoFishToggleVisual(initial)
    end

    pcall(function()
        AutoFish_Data:OnChange("AutoFishing", function(newVal)
            updateAutoFishToggleVisual(newVal)
        end)
    end)
else
    updateAutoFishToggleVisual(false)
end

local function handleAutoFishClick()
    ToggleAutoFishing()
end

autoFishToggleButton.MouseButton1Click:Connect(handleAutoFishClick)
autoFishLabel.MouseButton1Click:Connect(handleAutoFishClick)

autoFishBindBtn.MouseButton1Click:Connect(function()
    autoFishBindingActive = true
    refreshAutoFishBindText()
end)

autoFishResetBindBtn.MouseButton1Click:Connect(function()
    autoFishBindingActive = false
    autoFishHotkey = nil
    refreshAutoFishBindText()
end)

---------------------------------------------------------------------
-- Teleport tools (scrollable box)
---------------------------------------------------------------------
local function teleportToPlayer(targetPlayer)
    if not targetPlayer or targetPlayer == player then return end

    local myChar = player.Character or player.CharacterAdded:Wait()
    local myHRP = myChar:FindFirstChild("HumanoidRootPart")
    if not myHRP then return end

    local targetChar = targetPlayer.Character or targetPlayer.CharacterAdded:Wait()
    local targetHRP = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
    if not targetHRP then return end

    myHRP.CFrame = targetHRP.CFrame * CFrame.new(0, 0, 3)
end

local teleportTitle = Instance.new("TextLabel")
teleportTitle.Parent = settingsFrame
teleportTitle.BackgroundTransparency = 1
teleportTitle.Size = UDim2.new(1, -16, 0, 20)
teleportTitle.Position = UDim2.new(0, 12, 0, 195)
teleportTitle.Font = Enum.Font.SourceSansBold
teleportTitle.TextSize = 16
teleportTitle.TextXAlignment = Enum.TextXAlignment.Left
teleportTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
teleportTitle.Text = "Teleport to player"
teleportTitle.ZIndex = 5

local teleportScroll = Instance.new("ScrollingFrame")
teleportScroll.Name = "TeleportScroll"
teleportScroll.Parent = settingsFrame
teleportScroll.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
teleportScroll.BackgroundTransparency = 0.12
teleportScroll.BorderSizePixel = 0
teleportScroll.Size = UDim2.new(1, -24, 1, -231)
teleportScroll.Position = UDim2.new(0, 12, 0, 219)
teleportScroll.ScrollBarThickness = 5
teleportScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
teleportScroll.ClipsDescendants = true
teleportScroll.ZIndex = 5

local teleportScrollCorner = Instance.new("UICorner")
teleportScrollCorner.CornerRadius = UDim.new(0, 8)
teleportScrollCorner.Parent = teleportScroll

local teleportListLayout = Instance.new("UIListLayout")
teleportListLayout.Parent = teleportScroll
teleportListLayout.FillDirection = Enum.FillDirection.Vertical
teleportListLayout.SortOrder = Enum.SortOrder.LayoutOrder
teleportListLayout.Padding = UDim.new(0, 4)

local function updateTeleportCanvasSize()
    local totalHeight = 0
    for _, child in ipairs(teleportScroll:GetChildren()) do
        if child:IsA("TextButton") then
            totalHeight += child.AbsoluteSize.Y + teleportListLayout.Padding.Offset
        end
    end
    teleportScroll.CanvasSize = UDim2.new(0, 0, 0, totalHeight)
end

local function refreshTeleportList()
    for _, child in ipairs(teleportScroll:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player then
            local targetChar = plr.Character
            local targetHRP = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
            local pos = targetHRP and targetHRP.Position or Vector3.new(0, 0, 0)

            local btn = Instance.new("TextButton")
            btn.Name = "TeleportTo_" .. plr.Name
            btn.Parent = teleportScroll
            btn.Size = UDim2.new(1, 0, 0, 24)
            btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
            btn.BorderSizePixel = 0
            btn.AutoButtonColor = true
            btn.Font = Enum.Font.SourceSans
            btn.TextSize = 16
            btn.TextColor3 = Color3.fromRGB(255, 255, 255)
            btn.TextXAlignment = Enum.TextXAlignment.Left

            btn.Text = string.format(
                "Teleport to %s (X: %.1f  Y: %.1f)",
                plr.Name,
                pos.X,
                pos.Y
            )

            btn.ZIndex = 6

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 4)
            corner.Parent = btn

            btn.MouseButton1Click:Connect(function()
                teleportToPlayer(plr)
            end)
        end
    end

    updateTeleportCanvasSize()
end

Players.PlayerAdded:Connect(refreshTeleportList)
Players.PlayerRemoving:Connect(refreshTeleportList)
refreshTeleportList()

---------------------------------------------------------------------
-- X/Y HUD (draggable)
---------------------------------------------------------------------
local showXYHud = false
local xyFrame
local xyLabel

local function updateToggleVisual()
    if showXYHud then
        xyToggleButton.Text = "✔"
        xyToggleButton.TextColor3 = Color3.fromRGB(0, 200, 0)
    else
        xyToggleButton.Text = ""
        xyToggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    end
end

local function createXYHud()
    if xyFrame then
        xyFrame.Visible = true
        return
    end

    xyFrame = Instance.new("Frame")
    xyFrame.Name = "XYHudBox"
    xyFrame.Parent = screenGui
    xyFrame.Size = UDim2.new(0, 240, 0, 34)
    xyFrame.Position = UDim2.new(0, 10, 0, 70)
    xyFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    xyFrame.BackgroundTransparency = 0.2
    xyFrame.BorderSizePixel = 0
    xyFrame.ZIndex = 3

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = xyFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 80, 80)
    stroke.Thickness = 1
    stroke.Parent = xyFrame

    xyLabel = Instance.new("TextLabel")
    xyLabel.Parent = xyFrame
    xyLabel.BackgroundTransparency = 1
    xyLabel.Size = UDim2.new(1, -10, 1, 0)
    xyLabel.Position = UDim2.new(0, 5, 0, 0)
    xyLabel.Font = Enum.Font.SourceSansBold
    xyLabel.TextSize = 18
    xyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    xyLabel.TextXAlignment = Enum.TextXAlignment.Left
    xyLabel.Text = "X: 0.0  |  Y: 0.0"
    xyLabel.ZIndex = 4

    makeDraggable(xyFrame)
end

local function hideXYHud()
    if xyFrame then
        xyFrame.Visible = false
    end
end

local function setShowXYHud(value)
    showXYHud = value
    updateToggleVisual()
    if showXYHud then
        createXYHud()
    else
        hideXYHud()
    end
end

---------------------------------------------------------------------
-- Wiring up interactions
---------------------------------------------------------------------
xyToggleButton.MouseButton1Click:Connect(function()
    setShowXYHud(not showXYHud)
end)

xyToggleLabel.MouseButton1Click:Connect(function()
    setShowXYHud(not showXYHud)
end)

RunService.RenderStepped:Connect(function()
    if showXYHud and xyLabel and hrp and hrp.Parent then
        local pos = hrp.Position
        xyLabel.Text = string.format("X: %.1f  |  Y: %.1f", pos.X, pos.Y)
    end
end)

---------------------------------------------------------------------
-- Global Input: AutoFish Keybinding
---------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- If we're currently binding a key
    if autoFishBindingActive then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            autoFishBindingActive = false

            if input.KeyCode ~= Enum.KeyCode.Unknown then
                autoFishHotkey = input.KeyCode
            else
                autoFishHotkey = nil
            end

            refreshAutoFishBindText()
        end
        return
    end

    if gameProcessed then return end

    -- Trigger Auto Fishing via bound hotkey
    if autoFishHotkey
        and input.UserInputType == Enum.UserInputType.Keyboard
        and input.KeyCode == autoFishHotkey then

        handleAutoFishClick()
    end
end)
