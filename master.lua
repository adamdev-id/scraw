-- Auto Perfect Fishing (state-aware)
-- AFTER you’ve done one full manual cycle (throw + minigame + anim),
-- turn ON "Auto Perfect" and it will:
--   charge → release near peak → wait for FishingCompleted/Stopped → repeat

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer or Players.PlayerAdded:Wait()

----------------------------------------------------------------
-- Net + FishingController
----------------------------------------------------------------
local packages = ReplicatedStorage:WaitForChild("Packages")

local Net = require(packages:WaitForChild("Net"))

-- From your decompile:
-- v_u_36 = Net:RemoteFunction("CancelFishingInputs")
-- v_u_41 = Net:RemoteEvent("FishingCompleted")
-- v_u_42 = Net:RemoteEvent("FishingStopped")
local RF_CancelFishingInputs = Net:RemoteFunction("CancelFishingInputs")
local RE_FishingCompleted    = Net:RemoteEvent("FishingCompleted")
local RE_FishingStopped      = Net:RemoteEvent("FishingStopped")

local controllersFolder = ReplicatedStorage:WaitForChild("Controllers")
local fishingModule = controllersFolder:WaitForChild("FishingController")

local FishingController = require(fishingModule)
if type(FishingController) ~= "table" then
    warn("[AutoPerfect] FishingController did not return a table.")
    return
end

if type(FishingController._getPower) ~= "function"
or type(FishingController.RequestChargeFishingRod) ~= "function" then
    warn("[AutoPerfect] Missing _getPower or RequestChargeFishingRod on FishingController.")
    return
end

local hasOnCooldown    = (type(FishingController.OnCooldown)    == "function")
local hasGetCurrentGUID = (type(FishingController.GetCurrentGUID) == "function")

----------------------------------------------------------------
-- Find the internal "chargeSignal" (v_u_44) used to confirm charge
----------------------------------------------------------------
local debugLib = debug or getfenv().debug
if not (debugLib and debugLib.getupvalues) then
    warn("[AutoPerfect] debug.getupvalues not available in this executor.")
    return
end

local getupvalues = debugLib.getupvalues
local chargeSignal

for idx, upv in ipairs(getupvalues(FishingController.RequestChargeFishingRod)) do
    if type(upv) == "table"
       and type(upv.Fire) == "function"
       and type(upv.Connect) == "function" then
        chargeSignal = upv
        print(("[AutoPerfect] Found charge Signal upvalue at index %d"):format(idx))
        break
    end
end

if not chargeSignal then
    warn("[AutoPerfect] Could not find charge Signal upvalue; aborting.")
    return
end

----------------------------------------------------------------
-- State flags driven by FishingCompleted / FishingStopped
----------------------------------------------------------------
local autoPerfectEnabled = false
local loopRunning        = false
local cycleActive        = false  -- one full fishing cycle (charge→minigame→anim)
local hasCompletedOnce   = false  -- require at least ONE manual cycle before auto

RE_FishingCompleted.OnClientEvent:Connect(function(...)
    print("[AutoPerfect] FishingCompleted event.")
    hasCompletedOnce = true
    cycleActive = false
end)

RE_FishingStopped.OnClientEvent:Connect(function(...)
    print("[AutoPerfect] FishingStopped event.")
    cycleActive = false
end)

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local PERFECT_THRESHOLD       = 0.96  -- near max → insta release
local MIN_PEAK_FOR_RELEASE    = 0.70  -- if bar starts falling after this → release at peak
local MAX_CHARGE_TIME         = 5     -- safety timeout per charge
local BETWEEN_CAST_DELAY      = 0.4   -- delay between cycles
local PRINT_INTERVAL_SECONDS  = 0.05  -- how often to log power/peak during charge

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
        return FishingController:_getPower()
    end)
    if not ok or type(power) ~= "number" then
        return 0
    end
    return power
end

----------------------------------------------------------------
-- Charge → monitor bar → tell controller to "confirm" (throw)
-- Only runs during the CHARGE phase; we do NOT loop during animations.
----------------------------------------------------------------
local function monitorChargeAndRelease()
    local startTime = tick()
    local lastPrintTime = 0
    local lastPower = 0
    local peakPower = 0

    while autoPerfectEnabled and cycleActive and (tick() - startTime) < MAX_CHARGE_TIME do
        -- If already in minigame (GUID set), stop watching charge.
        if hasGetCurrentGUID then
            local ok, guid = pcall(function()
                return FishingController:GetCurrentGUID()
            end)
            if ok and guid ~= nil then
                print("[AutoPerfect] Minigame started, stopping charge monitor.")
                break
            end
        end

        local p = getPowerSafe()
        if p > peakPower then
            peakPower = p
        end

        -- Debug: print bar value only during charge
        local now = tick()
        if now - lastPrintTime >= PRINT_INTERVAL_SECONDS then
            print(("[AutoPerfect] charge power = %.3f, peak = %.3f"):format(p, peakPower))
            lastPrintTime = now
        end

        -- Strong / fast bars → hit near max
        if p >= PERFECT_THRESHOLD then
            print(("[AutoPerfect] Releasing at near-max power: %.3f"):format(p))
            pcall(function()
                chargeSignal:Fire(true)  -- same Signal the controller uses when you release mouse
            end)
            break
        end

        -- Weak / slow bars → release at the best peak we saw
        if p < lastPower and peakPower >= MIN_PEAK_FOR_RELEASE then
            print(("[AutoPerfect] Releasing at peak power: %.3f"):format(peakPower))
            pcall(function()
                chargeSignal:Fire(true)
            end)
            break
        end

        lastPower = p
        task.wait(0.01)
    end

    -- We do NOT set cycleActive = false here.
    -- We wait for FishingCompleted / FishingStopped to fire, then recast.
end

----------------------------------------------------------------
-- One auto cast (only if not mid-animation / minigame / cooldown)
----------------------------------------------------------------
local function doOneCast()
    -- Require at least one manual full cycle first (your requirement)
    if not hasCompletedOnce then
        return
    end

    -- Don't start if a fishing cycle is already in progress
    if cycleActive then
        return
    end

    -- Don't start if minigame is already active
    if hasGetCurrentGUID then
        local ok, guid = pcall(function()
            return FishingController:GetCurrentGUID()
        end)
        if ok and guid ~= nil then
            return
        end
    end

    -- Respect OnCooldown if exposed
    if hasOnCooldown then
        local ok, onCd = pcall(function()
            return FishingController:OnCooldown()
        end)
        if ok and onCd then
            return
        end
    end

    -- Avoid starting if it's somehow still in a charge state
    if getPowerSafe() > 0.01 then
        return
    end

    cycleActive = true

    local aimPos = getAimPos()
    print(("[AutoPerfect] Auto cast: starting charge at (%.0f, %.0f)"):format(aimPos.X, aimPos.Y))

    local ok, err = pcall(function()
        FishingController:RequestChargeFishingRod(aimPos)
    end)

    if not ok then
        warn("[AutoPerfect] RequestChargeFishingRod failed:", err)
        cycleActive = false
        return
    end

    -- Only watch the bar while charging; repeats handled by events.
    monitorChargeAndRelease()
end

----------------------------------------------------------------
-- Auto loop: only recast AFTER FishingCompleted/FishingStopped
----------------------------------------------------------------
local function startLoop()
    if loopRunning then return end
    loopRunning = true

    task.spawn(function()
        while autoPerfectEnabled do
            -- Only try to cast if:
            --  - we’ve already had one manual cycle (hasCompletedOnce)
            --  - we’re not in the middle of a cycle (cycleActive == false)
            if hasCompletedOnce and not cycleActive then
                pcall(doOneCast)
            end

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
-- Simple ON/OFF button (no fancy GUI)
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
    btn.Size = UDim2.new(0, 160, 0, 32)
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
        else
            -- If you want, you could also force-cancel current fishing via:
            -- pcall(function() RF_CancelFishingInputs:InvokeServer() end)
        end
    end)
end

createToggleGui()
print("[AutoPerfect] Loaded. Do ONE full manual fishing cycle first, then turn 'Auto Perfect' ON.")
