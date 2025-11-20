-- Auto Perfect Fishing (charge → near peak → release → repeat)
-- Uses FishingController internals (RequestChargeFishingRod + _getPower + Signal)
-- Prints bar "power" and peak values to console.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer or Players.PlayerAdded:Wait()

----------------------------------------------------------------
-- Locate & require FishingController
----------------------------------------------------------------
local controllersFolder = ReplicatedStorage:FindFirstChild("Controllers")
if not controllersFolder then
    controllersFolder = ReplicatedStorage:WaitForChild("Controllers", 10)
end

if not controllersFolder then
    warn("[AutoPerfect] Controllers folder not found in ReplicatedStorage.")
    return
end

local fishingModule = controllersFolder:FindFirstChild("FishingController")
if not (fishingModule and fishingModule:IsA("ModuleScript")) then
    warn("[AutoPerfect] FishingController module not found.")
    return
end

local FishingController = require(fishingModule)
if type(FishingController) ~= "table" then
    warn("[AutoPerfect] FishingController did not return a table.")
    return
end

if type(FishingController._getPower) ~= "function" then
    warn("[AutoPerfect] FishingController._getPower not found.")
    return
end

local hasOnCooldown = type(FishingController.OnCooldown) == "function"

----------------------------------------------------------------
-- Grab the internal Signal used for releasing charge
-- (the v_u_44 in your decompile)
----------------------------------------------------------------
local getupvalues = (debug and debug.getupvalues) or getupvalues
if not getupvalues then
    warn("[AutoPerfect] No getupvalues/debug.getupvalues available in this executor.")
    return
end

local chargeSignal

for idx, upv in ipairs(getupvalues(FishingController.RequestChargeFishingRod)) do
    if type(upv) == "table" and type(upv.Fire) == "function" and type(upv.Connect) == "function" then
        chargeSignal = upv
        print(("[AutoPerfect] Found charge signal as upvalue #%d"):format(idx))
        break
    end
end

if not chargeSignal then
    warn("[AutoPerfect] Failed to locate charge signal upvalue.")
    return
end

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local autoPerfectEnabled = false
local loopRunning = false

-- Tuning (you can tweak these numbers)
local PERFECT_THRESHOLD      = 0.96  -- if bar ever reaches this, release
local MIN_PEAK_FOR_RELEASE   = 0.70  -- if bar starts falling after reaching this, release
local MAX_CHARGE_TIME        = 5     -- max seconds we allow one charge
local BETWEEN_CAST_DELAY     = 0.4   -- delay between casts
local PRINT_INTERVAL_SECONDS = 0.05  -- how often to print power to console

local function getAimPos()
    if UserInputService.MouseEnabled then
        return UserInputService:GetMouseLocation()
    end

    local cam = workspace.CurrentCamera
    if not cam then
        cam = workspace:WaitForChild("CurrentCamera", 5)
    end

    if cam then
        return Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
    end

    return Vector2.new(0, 0)
end

local function getPowerSafe()
    local ok, power = pcall(function()
        -- method-style call so it uses same upvalues as game
        return FishingController:_getPower()
    end)
    if not ok or type(power) ~= "number" then
        return 0
    end
    return power
end

----------------------------------------------------------------
-- Charge → monitor bar → release using internal Signal
----------------------------------------------------------------
local function monitorChargeAndRelease()
    local startTime = tick()
    local lastPrintTime = 0
    local lastPower = 0
    local peakPower = 0

    while autoPerfectEnabled and (tick() - startTime) < MAX_CHARGE_TIME do
        -- if game says "on cooldown", bail out
        if hasOnCooldown then
            local ok, onCD = pcall(function()
                return FishingController:OnCooldown()
            end)
            if ok and onCD then
                print("[AutoPerfect] OnCooldown during charge; aborting this cast.")
                break
            end
        end

        local p = getPowerSafe()
        if p > peakPower then
            peakPower = p
        end

        -- Debug output to console (F9 / executor console)
        local now = tick()
        if now - lastPrintTime >= PRINT_INTERVAL_SECONDS then
            print(("[AutoPerfect] power = %.3f, peak = %.3f"):format(p, peakPower))
            lastPrintTime = now
        end

        -- Case 1: strong/fast bar - reaches near max
        if p >= PERFECT_THRESHOLD then
            print(("[AutoPerfect] Releasing at near-max power: %.3f"):format(p))
            pcall(function()
                chargeSignal:Fire(true)
            end)
            return
        end

        -- Case 2: weak/slow bar - we release at the best peak we saw
        if p < lastPower and peakPower >= MIN_PEAK_FOR_RELEASE then
            print(("[AutoPerfect] Releasing at peak power: %.3f"):format(peakPower))
            pcall(function()
                chargeSignal:Fire(true)
            end)
            return
        end

        lastPower = p
        task.wait(0.01)
    end

    -- Safety: timed out or disabled mid-charge → still release once
    print("[AutoPerfect] Charge monitor ended; forcing release.")
    pcall(function()
        chargeSignal:Fire(true)
    end)
end

local function doOneCast()
    -- Respect cooldown if controller exposes it
    if hasOnCooldown then
        local ok, onCD = pcall(function()
            return FishingController:OnCooldown()
        end)
        if ok and onCD then
            return
        end
    end

    -- Don't start a new charge if power already above zero (already charging)
    if getPowerSafe() > 0.01 then
        return
    end

    local aimPos = getAimPos()
    print(string.format("[AutoPerfect] Starting charge at (%.0f, %.0f)", aimPos.X, aimPos.Y))

    local ok, err = pcall(function()
        FishingController:RequestChargeFishingRod(aimPos)
    end)

    if not ok then
        warn("[AutoPerfect] RequestChargeFishingRod failed:", err)
        return
    end

    -- Now watch the bar and release at the right time
    monitorChargeAndRelease()
end

local function startLoop()
    if loopRunning then return end
    loopRunning = true

    task.spawn(function()
        while autoPerfectEnabled do
            local ok = pcall(doOneCast)
            if not ok then
                -- swallow errors to keep loop alive
            end

            -- little pause between casts
            local waited = 0
            while autoPerfectEnabled and waited < BETWEEN_CAST_DELAY do
                task.wait(0.1)
                waited += 0.1
            end
        end

        loopRunning = false
    end)
end

----------------------------------------------------------------
-- Simple ON/OFF Button
----------------------------------------------------------------
local guiName = "AutoPerfectThrowGui"

local function createToggleGui()
    local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui")

    local existing = pg:FindFirstChild(guiName)
    if existing then
        existing:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = guiName
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.Parent = pg

    local btn = Instance.new("TextButton")
    btn.Name = "ToggleButton"
    btn.Parent = gui
    btn.Size = UDim2.new(0, 140, 0, 32)
    btn.Position = UDim2.new(0, 20, 0, 200)
    btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    btn.BorderSizePixel = 0
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 14
    btn.Text = "Auto Perfect: OFF"
    btn.AutoButtonColor = true

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn

    local function refreshButtonVisual()
        if autoPerfectEnabled then
            btn.Text = "Auto Perfect: ON"
            btn.BackgroundColor3 = Color3.fromRGB(0, 170, 80)
        else
            btn.Text = "Auto Perfect: OFF"
            btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        end
    end

    refreshButtonVisual()

    btn.MouseButton1Click:Connect(function()
        autoPerfectEnabled = not autoPerfectEnabled
        refreshButtonVisual()
        if autoPerfectEnabled then
            startLoop()
        end
    end)
end

createToggleGui()
print("[AutoPerfect] Loaded. Toggle it with the 'Auto Perfect' button. Watch F9 / console for power values.")
