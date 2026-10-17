--[[
    ================================================================================
    RaicyHUB — Epalogan Tycoon Auto-Worker  (v2.3.1)
    ================================================================================
    Features:
      1. Auto-Assign   — seats customers to tables via RemoteEvent
      2. Auto-Pick Up   — grabs food from counter
      3. Auto-Serve     — delivers food to customers at tables
      4. Auto-Buy       — restocks ingredients + buys rare furniture
      5. Auto-Claim     — claims completed missions & achievements
      6. Anti-AFK       — prevents idle kick
    ================================================================================
]]

local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local UserInputService     = game:GetService("UserInputService")
local TweenService         = game:GetService("TweenService")
local VirtualInputManager  = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- GUI Container
--------------------------------------------------------------------------------
local ParentGui
if typeof(gethui) == "function" then
    ParentGui = gethui()
elseif game:GetService("CoreGui"):FindFirstChild("RobloxGui") then
    ParentGui = game:GetService("CoreGui")
else
    ParentGui = LocalPlayer:WaitForChild("PlayerGui")
end

if ParentGui:FindFirstChild("RaicyHUB_UI") then
    ParentGui.RaicyHUB_UI:Destroy()
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------
local Remotes               = ReplicatedStorage:WaitForChild("Remotes", 5)
local CounterAssignCustomer = Remotes and Remotes:FindFirstChild("CounterAssignCustomer")
local ClaimMissionReward    = Remotes and Remotes:FindFirstChild("ClaimMissionReward")
local GetMissionsSnapshot   = Remotes and Remotes:FindFirstChild("GetMissionsSnapshot")

local function findRemoteByKeyword(keywords, exclude)
    if not Remotes then return nil end
    for _, obj in ipairs(Remotes:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            local n = obj.Name:lower()
            local found = false
            for _, kw in ipairs(keywords) do
                if n:find(kw) then found = true; break end
            end
            if found and exclude then
                for _, ex in ipairs(exclude) do
                    if n:find(ex) then found = false; break end
                end
            end
            if found then return obj end
        end
    end
    return nil
end

local BuyIngredientRemote = findRemoteByKeyword({"buy", "purchase", "restock"}, {"furniture"})

-- Achievement remotes
local ClaimAchievementReward = Remotes and (
    Remotes:FindFirstChild("ClaimAchievementReward")
    or Remotes:FindFirstChild("ClaimAchievement")
)
local GetAchievementsSnapshot = Remotes and Remotes:FindFirstChild("GetAchievementsSnapshot")

--------------------------------------------------------------------------------
-- Config & State
--------------------------------------------------------------------------------
local Config = {
    AutoAssign = true,
    AutoPickUp = true,
    AutoServe  = true,
    AutoBuy    = true,
    AutoClaim  = true,
    AntiAFK    = true,
    SeatDelay  = 0.1,
}

local Running = true

--------------------------------------------------------------------------------
-- Core Utilities
--------------------------------------------------------------------------------
local function getRootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function moveTo(targetPosition)
    if not targetPosition then return end
    local root = getRootPart()
    if root then
        root.CFrame = CFrame.new(targetPosition + Vector3.new(0, 1.8, 0))
    end
end

--------------------------------------------------------------------------------
-- Plot Detection — works for OWNER and ADMINS
-- Owner: matches plot by UserId
-- Admin: finds the plot they're physically closest to
--------------------------------------------------------------------------------
local _myPlot = nil   -- cached reference to the working plot

-- Get the position of a plot (its center/pivot)
local function getPlotPosition(plot)
    -- Try PrimaryPart first
    if plot:IsA("Model") and plot.PrimaryPart then
        return plot.PrimaryPart.Position
    end
    -- Try GetPivot
    local ok, pivot = pcall(function() return plot:GetPivot().Position end)
    if ok and pivot then return pivot end
    -- Fallback: find any BasePart inside and use its position
    for _, desc in ipairs(plot:GetChildren()) do
        if desc:IsA("BasePart") then return desc.Position end
        if desc:IsA("Model") then
            local ok2, p = pcall(function() return desc:GetPivot().Position end)
            if ok2 and p then return p end
        end
    end
    return nil
end

-- Find and cache the plot we should work in
local function getMyPlot()
    -- Return cached if still valid
    if _myPlot and _myPlot.Parent then return _myPlot end
    _myPlot = nil

    local plots = workspace:FindFirstChild("EpaloganPlots")
    if not plots then return nil end
    local allPlots = plots:GetChildren()

    -- Strategy 1: match by our UserId (we're the plot owner)
    local myUserId = tostring(LocalPlayer.UserId)
    for _, plot in ipairs(allPlots) do
        if plot.Name:find(myUserId) then
            _myPlot = plot
            return _myPlot
        end
    end

    -- Strategy 2: find the plot we're physically closest to (admin mode)
    local root = getRootPart()
    if root then
        local myPos = root.Position
        local bestPlot, bestDist = nil, math.huge
        for _, plot in ipairs(allPlots) do
            local plotPos = getPlotPosition(plot)
            if plotPos then
                local dist = (plotPos - myPos).Magnitude
                if dist < bestDist then
                    bestDist = dist
                    bestPlot = plot
                end
            end
        end
        if bestPlot then
            _myPlot = bestPlot
            return _myPlot
        end
    end

    -- Strategy 3: if only one plot exists, use it
    if #allPlots == 1 then
        _myPlot = allPlots[1]
        return _myPlot
    end

    return nil
end

-- Check if an instance is inside our working plot
local function isInsideMyPlot(instance)
    local plot = getMyPlot()
    if not plot then return false end
    local check = instance
    while check and check ~= workspace do
        if check == plot then return true end
        check = check.Parent
    end
    return false
end

-- Get all descendants of our working plot only (instead of workspace)
local function getMyPlotDescendants()
    local plot = getMyPlot()
    if not plot then return {} end
    return plot:GetDescendants()
end

-- Log which plot we're working in
task.defer(function()
    task.wait(2) -- give time for character to load
    local plot = getMyPlot()
    if plot then
        print("[RaicyHUB] Working in plot: " .. plot.Name)
    else
        warn("[RaicyHUB] Could not find a plot! Make sure you're near a restaurant.")
    end
end)

--------------------------------------------------------------------------------
-- Prompt Trigger
--------------------------------------------------------------------------------
local function triggerPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then
        return false
    end
    pcall(function()
        prompt.RequiresLineOfSight = false
        local oldHold = prompt.HoldDuration
        local oldDist = prompt.MaxActivationDistance
        prompt.HoldDuration = 0
        prompt.MaxActivationDistance = 999

        if typeof(fireproximityprompt) == "function" then
            fireproximityprompt(prompt)
        else
            prompt:InputHoldBegin()
            task.wait(0.04)
            prompt:InputHoldEnd()
        end

        task.wait(0.04)
        prompt.HoldDuration = oldHold
        prompt.MaxActivationDistance = oldDist
    end)
    return true
end

local function getPromptPosition(prompt)
    local ancestor = prompt.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("BasePart") then
            return ancestor.Position
        elseif ancestor:IsA("Model") then
            local ok, pos = pcall(function() return ancestor:GetPivot().Position end)
            if ok and pos then return pos end
        end
        ancestor = ancestor.Parent
    end
    return nil
end

--------------------------------------------------------------------------------
-- Prompt Classification
--------------------------------------------------------------------------------
local function isPickupPrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local action = (prompt.ActionText or ""):lower()
    if action:find("serve") or action:find("give") or action:find("deliver") then return false end
    if action:find("manage") then return false end
    return action:find("pick") or action:find("take") or action:find("grab")
        or action:find("get") or action:find("kuha") or action:find("collect")
end

local function isServePrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local action = (prompt.ActionText or ""):lower()
    if action:find("pick") or action:find("grab") or action:find("kuha") then return false end
    return action:find("serve") or action:find("give") or action:find("deliver")
end

--------------------------------------------------------------------------------
-- Food Matching (deep scan — reads order bubbles, BillboardGuis, model names)
--------------------------------------------------------------------------------
local KNOWN_FOODS = {
    "lugaw", "epalog", "pares", "lomi", "batangas", "adobo",
    "sinigang", "tapsilog", "sisig", "bulalo", "kare",
}

-- Collect ALL text from an instance and its children (BillboardGuis, TextLabels, names)
local function collectAllText(inst)
    local texts = {}
    if inst:IsA("BasePart") or inst:IsA("Model") then
        table.insert(texts, inst.Name:lower())
    end
    for _, child in ipairs(inst:GetDescendants()) do
        if child:IsA("TextLabel") then
            table.insert(texts, (child.Text or ""):lower())
        elseif child:IsA("BillboardGui") then
            table.insert(texts, child.Name:lower())
        end
        -- Also grab names of parts/models (food might be in the name)
        if child:IsA("Model") or child:IsA("BasePart") then
            table.insert(texts, child.Name:lower())
        end
    end
    return texts
end

-- Extract food name from a prompt by scanning its ancestors AND siblings deeply
local function getFoodFromPrompt(prompt)
    local texts = {
        (prompt.ActionText or ""):lower(),
        (prompt.ObjectText or ""):lower(),
        prompt.Name:lower(),
    }

    -- Walk up the hierarchy, scanning each ancestor AND its children
    local parent = prompt.Parent
    local depth = 0
    while parent and parent ~= workspace and depth < 6 do
        table.insert(texts, parent.Name:lower())

        -- Scan all children AND descendants of this ancestor
        for _, child in ipairs(parent:GetChildren()) do
            table.insert(texts, child.Name:lower())
            if child:IsA("TextLabel") then
                table.insert(texts, (child.Text or ""):lower())
            end
            if child:IsA("BillboardGui") then
                for _, desc in ipairs(child:GetDescendants()) do
                    if desc:IsA("TextLabel") then
                        table.insert(texts, (desc.Text or ""):lower())
                    end
                end
            end
            -- If sibling is a Model (could be a customer NPC), read its texts too
            if child:IsA("Model") then
                for _, t in ipairs(collectAllText(child)) do
                    table.insert(texts, t)
                end
            end
        end

        parent = parent.Parent
        depth = depth + 1
    end

    -- Match against known foods
    local combined = table.concat(texts, " ")
    for _, food in ipairs(KNOWN_FOODS) do
        if combined:find(food) then return food end
    end
    return nil
end

-- Read what a CUSTOMER wants by scanning the serve prompt area for order text
-- Scoped to OUR plot only — won't read other players' customer orders
local function getCustomerOrder(servePrompt)
    -- First try the prompt itself
    local food = getFoodFromPrompt(servePrompt)
    if food then return food end

    -- Also scan nearby BillboardGuis in OUR PLOT (customer speech bubbles)
    local promptPos = getPromptPosition(servePrompt)
    if promptPos then
        for _, obj in ipairs(getMyPlotDescendants()) do
            if obj:IsA("BillboardGui") and obj.Parent
                and (obj.Parent:IsA("BasePart") or obj.Parent:IsA("Model")) then
                local guiParent = obj.Parent
                local guiPos
                if guiParent:IsA("BasePart") then
                    guiPos = guiParent.Position
                elseif guiParent:IsA("Model") then
                    local ok, p = pcall(function() return guiParent:GetPivot().Position end)
                    if ok then guiPos = p end
                end
                -- If this billboard is near the serve prompt (within 12 studs), read it
                if guiPos and (guiPos - promptPos).Magnitude < 12 then
                    for _, desc in ipairs(obj:GetDescendants()) do
                        if desc:IsA("TextLabel") then
                            local txt = (desc.Text or ""):lower()
                            for _, f in ipairs(KNOWN_FOODS) do
                                if txt:find(f) then return f end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- GUI — RaicyHUB v2.1 (Premium Dark Orange, Compact)
--------------------------------------------------------------------------------
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "RaicyHUB_UI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = ParentGui

-- ── Color Palette ──
local C = {
    bg        = Color3.fromRGB(16, 12, 10),
    header    = Color3.fromRGB(24, 18, 14),
    card      = Color3.fromRGB(30, 24, 18),
    cardHover = Color3.fromRGB(38, 30, 22),
    accent    = Color3.fromRGB(255, 140, 30),
    accentAlt = Color3.fromRGB(255, 80, 10),
    glow      = Color3.fromRGB(255, 180, 60),
    on        = Color3.fromRGB(255, 140, 30),
    onGlow    = Color3.fromRGB(255, 180, 60),
    off       = Color3.fromRGB(55, 40, 30),
    offKnob   = Color3.fromRGB(90, 70, 55),
    text      = Color3.fromRGB(240, 230, 215),
    textDim   = Color3.fromRGB(120, 100, 75),
    border    = Color3.fromRGB(55, 40, 28),
    pulse     = Color3.fromRGB(50, 200, 80),
}

-- ── Sizing ──
local ROW_HEIGHT    = 36
local ROW_GAP       = 4
local HEADER_HEIGHT = 42
local SIDE_PAD      = 10
local PANEL_WIDTH   = 230

local features = {
    {"Auto-Assign",  "AutoAssign",  "⚡"},
    {"Auto-Pick Up", "AutoPickUp",  "🍳"},
    {"Auto-Serve",   "AutoServe",   "🍽"},
    {"Auto-Buy",     "AutoBuy",     "🛒"},
    {"Auto-Claim",   "AutoClaim",   "🏆"},
    {"Anti-AFK",     "AntiAFK",     "🛡"},
}

local contentHeight = #features * (ROW_HEIGHT + ROW_GAP) - ROW_GAP + 16
local EXPANDED_SIZE  = UDim2.new(0, PANEL_WIDTH, 0, HEADER_HEIGHT + contentHeight)
local COLLAPSED_SIZE = UDim2.new(0, PANEL_WIDTH, 0, HEADER_HEIGHT)
local _isExpanded    = true

-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN FRAME
-- ══════════════════════════════════════════════════════════════════════════════
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = EXPANDED_SIZE
MainFrame.Position = UDim2.new(0, 14, 0.5, -math.floor((HEADER_HEIGHT + contentHeight) / 2))
MainFrame.BackgroundColor3 = C.bg
MainFrame.BackgroundTransparency = 0.02
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 12)

-- Border
local mainStroke = Instance.new("UIStroke")
mainStroke.Color = C.border
mainStroke.Thickness = 1
mainStroke.Transparency = 0.3
mainStroke.Parent = MainFrame

-- ══════════════════════════════════════════════════════════════════════════════
-- HEADER
-- ══════════════════════════════════════════════════════════════════════════════
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
Header.BackgroundColor3 = C.header
Header.BorderSizePixel = 0
Header.ZIndex = 5
Header.Parent = MainFrame

-- Bottom edge of header only gets rounded
local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 12)
headerCorner.Parent = Header

-- Accent bar (animated gradient)
local AccentBar = Instance.new("Frame")
AccentBar.Size = UDim2.new(1, 0, 0, 2)
AccentBar.Position = UDim2.new(0, 0, 1, -2)
AccentBar.BackgroundColor3 = C.accent
AccentBar.BorderSizePixel = 0
AccentBar.ZIndex = 6
AccentBar.Parent = Header

local barGrad = Instance.new("UIGradient")
barGrad.Color = ColorSequence.new{
    ColorSequenceKeypoint.new(0, C.glow),
    ColorSequenceKeypoint.new(0.4, C.accent),
    ColorSequenceKeypoint.new(1, C.accentAlt),
}
barGrad.Parent = AccentBar

-- Animate gradient offset for shimmer effect
task.spawn(function()
    while Running do
        TweenService:Create(barGrad, TweenInfo.new(2, Enum.EasingStyle.Linear), {
            Offset = Vector2.new(1, 0)
        }):Play()
        task.wait(2)
        barGrad.Offset = Vector2.new(-1, 0)
    end
end)

-- Pulsing "ACTIVE" dot (shows the script is running)
local PulseDot = Instance.new("Frame")
PulseDot.Size = UDim2.new(0, 6, 0, 6)
PulseDot.Position = UDim2.new(0, 12, 0.5, -3)
PulseDot.BackgroundColor3 = C.pulse
PulseDot.BorderSizePixel = 0
PulseDot.ZIndex = 7
PulseDot.Parent = Header
Instance.new("UICorner", PulseDot).CornerRadius = UDim.new(1, 0)

-- Pulse animation
task.spawn(function()
    while Running do
        TweenService:Create(PulseDot, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
            BackgroundTransparency = 0.7,
        }):Play()
        task.wait(0.8)
        TweenService:Create(PulseDot, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
            BackgroundTransparency = 0,
        }):Play()
        task.wait(0.8)
    end
end)

-- Title
local HubTitle = Instance.new("TextLabel")
HubTitle.Size = UDim2.new(1, -90, 1, 0)
HubTitle.Position = UDim2.new(0, 24, 0, 0)
HubTitle.BackgroundTransparency = 1
HubTitle.Text = "RaicyHUB"
HubTitle.TextColor3 = C.text
HubTitle.TextSize = 15
HubTitle.Font = Enum.Font.GothamBold
HubTitle.TextXAlignment = Enum.TextXAlignment.Left
HubTitle.ZIndex = 7
HubTitle.Parent = Header

-- Version pill
local VerPill = Instance.new("TextLabel")
VerPill.Size = UDim2.new(0, 30, 0, 14)
VerPill.Position = UDim2.new(0, 90, 0.5, -7)
VerPill.BackgroundColor3 = C.accent
VerPill.BackgroundTransparency = 0.15
VerPill.Text = "v2.3.1"
VerPill.TextColor3 = C.bg
VerPill.TextSize = 8
VerPill.Font = Enum.Font.GothamBold
VerPill.ZIndex = 7
VerPill.Parent = Header
Instance.new("UICorner", VerPill).CornerRadius = UDim.new(1, 0)

-- Minimize button
local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 28, 0, 28)
MinBtn.Position = UDim2.new(1, -36, 0.5, -14)
MinBtn.BackgroundColor3 = C.card
MinBtn.BackgroundTransparency = 0.1
MinBtn.Text = "—"
MinBtn.TextColor3 = C.accent
MinBtn.TextSize = 14
MinBtn.Font = Enum.Font.GothamBold
MinBtn.ZIndex = 7
MinBtn.Parent = Header
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 6)

-- ══════════════════════════════════════════════════════════════════════════════
-- CONTENT
-- ══════════════════════════════════════════════════════════════════════════════
local Content = Instance.new("Frame")
Content.Name = "Content"
Content.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
Content.Position = UDim2.new(0, 0, 0, HEADER_HEIGHT)
Content.BackgroundTransparency = 1
Content.ZIndex = 2
Content.Parent = MainFrame

-- ── Minimize toggle ──
MinBtn.MouseButton1Click:Connect(function()
    _isExpanded = not _isExpanded
    local targetSize = _isExpanded and EXPANDED_SIZE or COLLAPSED_SIZE
    MinBtn.Text = _isExpanded and "—" or "+"
    TweenService:Create(MainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Size = targetSize
    }):Play()
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- TOGGLE ROWS (iOS-style sliding toggle)
-- ══════════════════════════════════════════════════════════════════════════════
local TOGGLE_W = 38
local TOGGLE_H = 20
local KNOB_SIZE = 16
local KNOB_ON_X = TOGGLE_W - KNOB_SIZE - 2
local KNOB_OFF_X = 2

local function createToggleRow(i, feat)
    local yPos = 8 + (i - 1) * (ROW_HEIGHT + ROW_GAP)

    -- Row card
    local row = Instance.new("TextButton") -- TextButton so entire row is clickable
    row.Name = "Row_" .. feat[2]
    row.Size = UDim2.new(1, -(SIDE_PAD * 2), 0, ROW_HEIGHT)
    row.Position = UDim2.new(0, SIDE_PAD, 0, yPos)
    row.BackgroundColor3 = C.card
    row.BackgroundTransparency = 0.08
    row.BorderSizePixel = 0
    row.Text = ""
    row.AutoButtonColor = false
    row.ZIndex = 3
    row.Parent = Content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    -- Left accent bar (thin vertical stripe)
    local leftBar = Instance.new("Frame")
    leftBar.Size = UDim2.new(0, 3, 0.55, 0)
    leftBar.Position = UDim2.new(0, 0, 0.225, 0)
    leftBar.BackgroundColor3 = C.on
    leftBar.BorderSizePixel = 0
    leftBar.ZIndex = 4
    leftBar.Parent = row
    Instance.new("UICorner", leftBar).CornerRadius = UDim.new(0, 2)

    -- Emoji icon
    local icon = Instance.new("TextLabel")
    icon.Size = UDim2.new(0, 22, 0, 22)
    icon.Position = UDim2.new(0, 12, 0.5, -11)
    icon.BackgroundTransparency = 1
    icon.Text = feat[3]
    icon.TextSize = 14
    icon.ZIndex = 4
    icon.Parent = row

    -- Label
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -(TOGGLE_W + 56), 1, 0)
    label.Position = UDim2.new(0, 36, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = feat[1]
    label.TextColor3 = C.text
    label.TextSize = 12
    label.Font = Enum.Font.GothamSemibold
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.ZIndex = 4
    label.Parent = row

    -- ── iOS Sliding Toggle ──
    local toggleTrack = Instance.new("Frame")
    toggleTrack.Size = UDim2.new(0, TOGGLE_W, 0, TOGGLE_H)
    toggleTrack.Position = UDim2.new(1, -(TOGGLE_W + 10), 0.5, -math.floor(TOGGLE_H / 2))
    toggleTrack.BackgroundColor3 = C.on
    toggleTrack.BackgroundTransparency = 0.1
    toggleTrack.BorderSizePixel = 0
    toggleTrack.ZIndex = 4
    toggleTrack.Parent = row
    Instance.new("UICorner", toggleTrack).CornerRadius = UDim.new(1, 0)

    -- Knob (circle that slides)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, KNOB_SIZE, 0, KNOB_SIZE)
    knob.Position = UDim2.new(0, KNOB_ON_X, 0.5, -math.floor(KNOB_SIZE / 2))
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.ZIndex = 5
    knob.Parent = toggleTrack
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    -- Knob shadow
    local knobShadow = Instance.new("UIStroke")
    knobShadow.Color = Color3.fromRGB(0, 0, 0)
    knobShadow.Thickness = 1
    knobShadow.Transparency = 0.8
    knobShadow.Parent = knob

    -- Click handler (whole row is clickable)
    local function toggle()
        Config[feat[2]] = not Config[feat[2]]
        local isOn = Config[feat[2]]
        local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

        -- Slide knob
        TweenService:Create(knob, tweenInfo, {
            Position = UDim2.new(0, isOn and KNOB_ON_X or KNOB_OFF_X, 0.5, -math.floor(KNOB_SIZE / 2))
        }):Play()

        -- Track color
        TweenService:Create(toggleTrack, tweenInfo, {
            BackgroundColor3 = isOn and C.on or C.off,
        }):Play()

        -- Left bar color
        TweenService:Create(leftBar, tweenInfo, {
            BackgroundColor3 = isOn and C.on or C.off,
        }):Play()

        -- Label dim when off
        TweenService:Create(label, tweenInfo, {
            TextColor3 = isOn and C.text or C.textDim,
        }):Play()
    end

    row.MouseButton1Click:Connect(toggle)

    -- Hover effect
    row.MouseEnter:Connect(function()
        TweenService:Create(row, TweenInfo.new(0.12), {
            BackgroundColor3 = C.cardHover,
        }):Play()
    end)
    row.MouseLeave:Connect(function()
        TweenService:Create(row, TweenInfo.new(0.15), {
            BackgroundColor3 = C.card,
        }):Play()
    end)
end

for i, feat in ipairs(features) do
    createToggleRow(i, feat)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- DRAGGABLE (header only)
-- ══════════════════════════════════════════════════════════════════════════════
local dragging, dragStart, startPos
Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
    end
end)
Header.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)

--==============================================================================
-- FEATURE LOOPS (unchanged logic, no stats tracking needed)
--==============================================================================

--------------------------------------------------------------------------------
-- 1. AUTO-ASSIGN (rarity-priority: smart table matching)
--    Game structure: DiningArea > Table6 > Chair1, Chair2, Chair3, Chair4, TableModel
--    Each Chair/TableModel has BillboardGuis with rarity text ("COMMON", "EPIC", etc.)
--------------------------------------------------------------------------------

-- Rarity hierarchy (lower number = better)
local RARITY_SCORES = {
    ["heaven"]    = 1,
    ["celestial"] = 2,
    ["divine"]    = 3,
    ["legendary"] = 4,
    ["epic"]      = 5,
    ["rare"]      = 6,
    ["uncommon"]  = 7,
    ["common"]    = 8,
}
local DEFAULT_RARITY_SCORE = 9
local RARE_THRESHOLD = 6  -- score <= 6 (Rare+) → use best tables

-- Extract best rarity from a text string
local function extractRarity(text)
    local lower = text:lower()
    local best = DEFAULT_RARITY_SCORE
    for keyword, score in pairs(RARITY_SCORES) do
        if lower:find(keyword) then
            best = math.min(best, score)
        end
    end
    return best
end

-- Get the rarity of a Table by scanning its Chair/TableModel children
-- Structure: Table6 > Chair1 (Model) > [furniture mesh] > BillboardGui > TextLabel "EPIC"
local function getTableRarity(tableFolder)
    local bestScore = DEFAULT_RARITY_SCORE

    -- Scan ALL descendants of the table (Chairs + TableModel + their children)
    for _, desc in ipairs(tableFolder:GetDescendants()) do
        -- BillboardGuis with rarity text labels
        if desc:IsA("TextLabel") then
            local score = extractRarity(desc.Text or "")
            if score < bestScore then
                -- Make sure this label is on furniture, not a customer NPC sitting here
                local isNPC = false
                local check = desc.Parent
                while check and check ~= tableFolder do
                    if check:IsA("Model") and check:FindFirstChildOfClass("Humanoid") then
                        isNPC = true; break
                    end
                    check = check.Parent
                end
                if not isNPC then
                    bestScore = score
                end
            end
        end

        -- StringValues that might store rarity
        if desc:IsA("StringValue") then
            local score = math.min(extractRarity(desc.Name), extractRarity(desc.Value or ""))
            if score < bestScore then bestScore = score end
        end

        -- IntValues named Rarity/Tier
        if desc:IsA("IntValue") and (desc.Name:lower() == "rarity" or desc.Name:lower() == "tier") then
            if desc.Value >= 1 and desc.Value <= 8 then
                bestScore = math.min(bestScore, desc.Value)
            end
        end

        -- Model/Part names containing rarity keywords (e.g. "HeavenChair", "LegendaryTable")
        if desc:IsA("Model") or desc:IsA("BasePart") then
            local score = extractRarity(desc.Name)
            if score < bestScore then
                local isNPC = false
                if desc:IsA("Model") and desc:FindFirstChildOfClass("Humanoid") then
                    isNPC = true
                end
                if not isNPC then
                    bestScore = score
                end
            end
        end
    end

    return bestScore
end

-- Detect best customer rarity in the plot
-- Scans NPCs (Humanoid models) including ActiveCustomers folder
local function getWaitingCustomerBestRarity(plot)
    local bestScore = DEFAULT_RARITY_SCORE

    -- Scan ActiveCustomers folder specifically
    local activeFolder = plot:FindFirstChild("ActiveCustomers")
    local searchIn = activeFolder or plot

    for _, desc in ipairs(searchIn:GetDescendants()) do
        if desc:IsA("Model") and desc:FindFirstChildOfClass("Humanoid") then
            for _, child in ipairs(desc:GetDescendants()) do
                if child:IsA("TextLabel") then
                    local score = extractRarity(child.Text or "")
                    if score < DEFAULT_RARITY_SCORE then
                        bestScore = math.min(bestScore, score)
                    end
                end
            end
        end
    end

    -- Also scan the whole plot for NPCs if ActiveCustomers didn't yield results
    if bestScore >= DEFAULT_RARITY_SCORE and searchIn == activeFolder then
        for _, desc in ipairs(plot:GetDescendants()) do
            if desc:IsA("Model") and desc:FindFirstChildOfClass("Humanoid") then
                for _, child in ipairs(desc:GetDescendants()) do
                    if child:IsA("TextLabel") then
                        local score = extractRarity(child.Text or "")
                        if score < DEFAULT_RARITY_SCORE then
                            bestScore = math.min(bestScore, score)
                        end
                    end
                end
            end
        end
    end

    return bestScore
end

task.spawn(function()
    while Running do
        if Config.AutoAssign and CounterAssignCustomer then
            local plot = getMyPlot()
            if plot then
                        -- Collect all table+seat combos with rarity scores
                        local assignments = {}
                        for _, child in ipairs(plot:GetDescendants()) do
                            if not Config.AutoAssign then break end
                            if child.Name:match("^Table%d+$") then
                                local tableScore = getTableRarity(child)
                                for _, seat in ipairs(child:GetDescendants()) do
                                    if not Config.AutoAssign then break end
                                    if seat.Name:match("^ChairSlot%d+$") then
                                        table.insert(assignments, {
                                            tableName = child.Name,
                                            seatName  = seat.Name,
                                            score     = tableScore,
                                        })
                                    end
                                end
                            end
                        end

                        -- If no ChairSlots found, fallback to firing without sorting
                        -- (original behavior)
                        if #assignments == 0 then
                            for _, child in ipairs(plot:GetDescendants()) do
                                if not Config.AutoAssign then break end
                                if child.Name:match("^Table%d+$") then
                                    for _, seat in ipairs(child:GetDescendants()) do
                                        if not Config.AutoAssign then break end
                                        if seat.Name:match("^ChairSlot%d+$") then
                                            pcall(function()
                                                CounterAssignCustomer:FireServer(child.Name, seat.Name)
                                            end)
                                            task.wait(Config.SeatDelay)
                                        end
                                    end
                                end
                            end
                        else
                            -- Sort by rarity based on customer waiting
                            local bestCustomer = getWaitingCustomerBestRarity(plot)
                            local hasRarePlus = bestCustomer <= RARE_THRESHOLD

                            if hasRarePlus then
                                -- Rare+ customer → best tables first
                                table.sort(assignments, function(a, b)
                                    return a.score < b.score
                                end)
                            else
                                -- Only Common/Uncommon → worst tables first
                                table.sort(assignments, function(a, b)
                                    return a.score > b.score
                                end)
                            end

                            -- Fire assigns in sorted order
                            for _, entry in ipairs(assignments) do
                                if not Config.AutoAssign then break end
                                pcall(function()
                                    CounterAssignCustomer:FireServer(entry.tableName, entry.seatName)
                                end)
                                task.wait(Config.SeatDelay)
                            end
                        end
            end
        end
        task.wait(0.1)
    end
end)

--------------------------------------------------------------------------------
-- 2. AUTO-PICKUP & AUTO-SERVE (food-matched serving)  — v2.2 anti-loop fix
--------------------------------------------------------------------------------
-- State machine with stuck-detection, prompt cooldowns & action verification
local _phase           = "pickup"   -- "pickup" | "serve"
local _heldFood        = nil
local _consecutiveFails = 0         -- how many cycles found nothing actionable
local MAX_FAILS_BEFORE_RESET = 5    -- after this many fails → hard reset state
local FAIL_COOLDOWN    = 1.5        -- seconds to wait when we detect we're stuck

-- Cooldown table: promptInstance → tick() when we last failed on it
local _promptCooldowns = {}
local PROMPT_COOLDOWN_SECS = 4      -- ignore a prompt for this long after it fails

-- Unique-ish key for a prompt so we can track it across scans
local function promptKey(prompt)
    local p = prompt.Parent
    local name = p and p.Name or "?"
    local gp = p and p.Parent
    local gpName = gp and gp.Name or "?"
    return gpName .. "/" .. name .. "/" .. prompt.Name
end

-- Check if a prompt is on cooldown
local function isOnCooldown(prompt)
    local key = promptKey(prompt)
    local t = _promptCooldowns[key]
    if t and (tick() - t) < PROMPT_COOLDOWN_SECS then
        return true
    end
    if t then _promptCooldowns[key] = nil end -- expired, clean up
    return false
end

-- Mark a prompt as failed (put on cooldown)
local function markPromptFailed(prompt)
    _promptCooldowns[promptKey(prompt)] = tick()
end

-- Verify a prompt is still valid right before acting on it
local function isPromptStillValid(prompt)
    local ok, enabled = pcall(function() return prompt.Parent ~= nil and prompt.Enabled end)
    return ok and enabled
end

-- Cleanup stale cooldown entries periodically
local _lastCooldownClean = 0
local function cleanCooldowns()
    if (tick() - _lastCooldownClean) < 10 then return end
    _lastCooldownClean = tick()
    local now = tick()
    for key, t in pairs(_promptCooldowns) do
        if (now - t) >= PROMPT_COOLDOWN_SECS then
            _promptCooldowns[key] = nil
        end
    end
end

task.spawn(function()
    while Running do
        if Config.AutoPickUp or Config.AutoServe then
            cleanCooldowns()

            if _phase == "pickup" then
                -- ═══════ PICKUP PHASE ═══════
                -- Build a set of what customers currently want (OUR PLOT ONLY)
                local wantedFoods = {}
                local hasAnyServe = false
                if Config.AutoServe then
                    for _, obj in ipairs(getMyPlotDescendants()) do
                        if obj:IsA("ProximityPrompt") and obj.Enabled
                            and isServePrompt(obj) and not isOnCooldown(obj) then
                            hasAnyServe = true
                            local order = getCustomerOrder(obj)
                            if order then wantedFoods[order] = true end
                        end
                    end
                end

                local pickedUp = false
                if Config.AutoPickUp then
                    -- 1) Try to pick up food that matches a waiting customer (OUR PLOT)
                    for _, obj in ipairs(getMyPlotDescendants()) do
                        if obj:IsA("ProximityPrompt") and obj.Enabled
                            and isPickupPrompt(obj) and not isOnCooldown(obj) then
                            local stationFood = getFoodFromPrompt(obj)
                            if stationFood and wantedFoods[stationFood] then
                                -- Re-validate right before acting
                                if isPromptStillValid(obj) then
                                    local pos = getPromptPosition(obj)
                                    if pos then
                                        moveTo(pos); task.wait(0.08)
                                        -- Check AGAIN after teleport
                                        if isPromptStillValid(obj) then
                                            triggerPrompt(obj); task.wait(0.18)
                                            _heldFood = stationFood
                                            pickedUp = true
                                        else
                                            markPromptFailed(obj)
                                        end
                                        break
                                    end
                                else
                                    markPromptFailed(obj)
                                end
                            end
                        end
                    end

                    -- 2) Fallback: pick up any available food
                    if not pickedUp then
                        for _, obj in ipairs(getMyPlotDescendants()) do
                            if obj:IsA("ProximityPrompt") and obj.Enabled
                                and isPickupPrompt(obj) and not isOnCooldown(obj) then
                                if isPromptStillValid(obj) then
                                    local stationFood = getFoodFromPrompt(obj)
                                    local pos = getPromptPosition(obj)
                                    if pos then
                                        moveTo(pos); task.wait(0.08)
                                        if isPromptStillValid(obj) then
                                            triggerPrompt(obj); task.wait(0.18)
                                            _heldFood = stationFood
                                            pickedUp = true
                                        else
                                            markPromptFailed(obj)
                                        end
                                        break
                                    end
                                else
                                    markPromptFailed(obj)
                                end
                            end
                        end
                    end
                end

                -- Advance state only if we actually picked something up
                if pickedUp then
                    _phase = "serve"
                    _consecutiveFails = 0
                else
                    -- Nothing to pick up → if there are serve prompts pending,
                    -- skip to serve anyway (we might already be holding food)
                    if hasAnyServe then
                        _phase = "serve"
                    end
                    _consecutiveFails = _consecutiveFails + 1
                end

            else
                -- ═══════ SERVE PHASE ═══════
                local served = false
                if Config.AutoServe then
                    -- 1) If we know what we're holding, find the matching customer
                    if _heldFood then
                        for _, obj in ipairs(getMyPlotDescendants()) do
                            if obj:IsA("ProximityPrompt") and obj.Enabled
                                and isServePrompt(obj) and not isOnCooldown(obj) then
                                local order = getCustomerOrder(obj)
                                if order and order == _heldFood then
                                    if isPromptStillValid(obj) then
                                        local pos = getPromptPosition(obj)
                                        if pos then
                                            moveTo(pos); task.wait(0.08)
                                            if isPromptStillValid(obj) then
                                                triggerPrompt(obj); task.wait(0.18)
                                                _heldFood = nil
                                                served = true
                                            else
                                                markPromptFailed(obj)
                                            end
                                            break
                                        end
                                    else
                                        markPromptFailed(obj)
                                    end
                                end
                            end
                        end
                    end

                    -- 2) Fallback: serve ANY customer
                    if not served then
                        for _, obj in ipairs(getMyPlotDescendants()) do
                            if obj:IsA("ProximityPrompt") and obj.Enabled
                                and isServePrompt(obj) and not isOnCooldown(obj) then
                                if isPromptStillValid(obj) then
                                    local pos = getPromptPosition(obj)
                                    if pos then
                                        moveTo(pos); task.wait(0.08)
                                        if isPromptStillValid(obj) then
                                            triggerPrompt(obj); task.wait(0.18)
                                            _heldFood = nil
                                            served = true
                                        else
                                            markPromptFailed(obj)
                                        end
                                        break
                                    end
                                else
                                    markPromptFailed(obj)
                                end
                            end
                        end
                    end
                end

                -- Always go back to pickup after serve attempt
                _phase = "pickup"
                if served then
                    _consecutiveFails = 0
                else
                    _consecutiveFails = _consecutiveFails + 1
                end
            end

            -- ═══════ STUCK DETECTION ═══════
            if _consecutiveFails >= MAX_FAILS_BEFORE_RESET then
                -- We've been going back and forth doing nothing → full reset
                _heldFood = nil
                _phase = "pickup"
                _consecutiveFails = 0
                -- Clear all cooldowns so we get a fresh start
                _promptCooldowns = {}
                -- Wait longer before retrying to let the game state settle
                task.wait(FAIL_COOLDOWN)
            end
        end
        task.wait(0.1)
    end
end)

--------------------------------------------------------------------------------
-- 3a. AUTO-BUY INGREDIENTS
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if Config.AutoBuy then
            if BuyIngredientRemote then
                local ingredients = {
                    "Egg", "Harina", "Asin", "Pork", "Chicken", "Beef",
                    "Rice", "Noodles", "Toyo", "Suka", "Patis", "Garlic", "Onion",
                    "Cooking Oil", "CookingOil", "Oil", "Cooking_Oil",
                    "Bawang", "Sibuyas", "Pepper", "Salt", "Sugar", "Flour",
                    "Fish", "Shrimp", "Vegetables", "Vinegar", "Soy Sauce",
                }
                for _, ing in ipairs(ingredients) do
                    pcall(function()
                        if BuyIngredientRemote:IsA("RemoteEvent") then
                            BuyIngredientRemote:FireServer(ing, 10)
                        elseif BuyIngredientRemote:IsA("RemoteFunction") then
                            BuyIngredientRemote:InvokeServer(ing, 10)
                        end
                    end)
                    task.wait(0.05)
                end
            end

            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if playerGui then
                    for _, gui in ipairs(playerGui:GetChildren()) do
                        if gui:IsA("ScreenGui") then
                            for _, desc in ipairs(gui:GetDescendants()) do
                                if desc:IsA("TextButton") then
                                    local txt = (desc.Text or ""):upper():gsub("%s+", "")
                                    if txt == "BUY" then
                                        local parentFrame = desc.Parent
                                        if parentFrame then
                                            local needsBuy = false
                                            for _, sibling in ipairs(parentFrame:GetChildren()) do
                                                if sibling:IsA("TextLabel") then
                                                    local current = sibling.Text:match("(%d+)%s*/%s*%d+")
                                                    if current and tonumber(current) < 50 then
                                                        needsBuy = true; break
                                                    end
                                                end
                                            end
                                            if needsBuy then
                                                pcall(function() desc:Activate() end)
                                                task.wait(0.15)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
        task.wait(5)
    end
end)

--------------------------------------------------------------------------------
-- 3b. AUTO-BUY FURNITURE
--------------------------------------------------------------------------------
local FURNITURE_RARITIES = {"HEAVEN", "LEGENDARY"}

local function findCardBuyButton(startInstance)
    local card = startInstance.Parent
    for _ = 1, 6 do
        if not card or card:IsA("ScreenGui") then break end
        for _, child in ipairs(card:GetDescendants()) do
            if child:IsA("TextButton") or child:IsA("ImageButton") then
                local btnText = (child.Text or ""):upper():gsub("%s+", "")
                if btnText == "BUY" or btnText == "PURCHASE" or btnText == "BUYITEM" then
                    return child
                end
            end
        end
        card = card.Parent
    end
    return nil
end

local function clickConfirmations()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return end
    for _ = 1, 5 do
        for _, gui in ipairs(playerGui:GetChildren()) do
            if gui:IsA("ScreenGui") then
                for _, desc in ipairs(gui:GetDescendants()) do
                    if desc:IsA("TextButton") or desc:IsA("ImageButton") then
                        local txt = (desc.Text or ""):upper():gsub("%s+", "")
                        if txt == "CONFIRM" or txt == "YES" or txt == "OK"
                            or txt == "BUY" or txt == "PURCHASE"
                            or txt == "ACCEPT" or txt == "PROCEED" then
                            pcall(function() desc:Activate() end)
                            task.wait(0.15)
                        end
                    end
                end
            end
        end
        task.wait(0.2)
    end
end

local function matchesRarity(text)
    local upper = text:upper():gsub("%s+", " ")
    for priority, rarity in ipairs(FURNITURE_RARITIES) do
        if upper:find(rarity) then return rarity, priority end
    end
    return nil, 999
end

task.spawn(function()
    while Running do
        if Config.AutoBuy then
            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if not playerGui then return end

                for _, gui in ipairs(playerGui:GetChildren()) do
                    if not gui:IsA("ScreenGui") then continue end

                    local isShop = false
                    for _, desc in ipairs(gui:GetDescendants()) do
                        if desc:IsA("TextLabel") or desc:IsA("TextButton") then
                            local t = (desc.Text or ""):upper()
                            if t:find("FURNITURE") or t:find("SHOP") or t:find("STORE") then
                                isShop = true; break
                            end
                        end
                    end

                    if isShop then
                        local buyTargets = {}
                        for _, desc in ipairs(gui:GetDescendants()) do
                            if desc:IsA("TextLabel") then
                                local rarity, priority = matchesRarity(desc.Text)
                                if rarity then
                                    local buyBtn = findCardBuyButton(desc)
                                    if buyBtn then
                                        local btnText = (buyBtn.Text or ""):upper():gsub("%s+", "")
                                        if btnText ~= "SOLDOUT" and btnText ~= "SOLD"
                                            and btnText ~= "OWNED" and btnText ~= "MAXED"
                                            and buyBtn.Visible ~= false then
                                            table.insert(buyTargets, {btn = buyBtn, priority = priority})
                                        end
                                    end
                                end
                            end
                        end

                        table.sort(buyTargets, function(a, b) return a.priority < b.priority end)

                        for _, target in ipairs(buyTargets) do
                            pcall(function() target.btn:Activate() end)
                            task.wait(0.4)
                            clickConfirmations()
                            task.wait(0.3)
                        end

                        if #buyTargets == 0 then
                            for _, desc in ipairs(gui:GetDescendants()) do
                                if (desc:IsA("TextButton") or desc:IsA("ImageButton")) then
                                    local btnText = (desc.Text or ""):upper():gsub("%s+", "")
                                    if (btnText == "BUY" or btnText == "PURCHASE")
                                        and desc.Visible ~= false then
                                        pcall(function() desc:Activate() end)
                                        task.wait(0.3)
                                        clickConfirmations()
                                        task.wait(0.2)
                                    end
                                end
                            end
                        end
                    end
                end
            end)

            if Remotes then
                local furnitureItems = {
                    "Demon Angel Chair", "Angel Table", "Heaven Chair", "Heaven Table",
                    "Divine Chair", "Divine Table", "Celestial Chair", "Celestial Table",
                    "King Chair", "Queen Chair", "King Table", "Queen Table",
                    "Royal Chair", "Royal Table", "Gold Chair", "Gold Table",
                    "Diamond Chair", "Diamond Table", "Crystal Chair", "Crystal Table",
                    "Banana Leaf Table", "VIP Chair", "VIP Table",
                    "Premium Chair", "Premium Table", "Deluxe Chair", "Deluxe Table",
                    "Fancy Chair", "Fancy Table", "Elegant Chair", "Elegant Table",
                }
                for _, obj in ipairs(Remotes:GetDescendants()) do
                    if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction"))
                        and (obj.Name:lower():find("buy") or obj.Name:lower():find("purchase")) then
                        for _, item in ipairs(furnitureItems) do
                            pcall(function()
                                if obj:IsA("RemoteEvent") then
                                    obj:FireServer(item)
                                    obj:FireServer(item, 1)
                                    obj:FireServer("Furniture", item)
                                    obj:FireServer("furniture", item)
                                else
                                    obj:InvokeServer(item)
                                    obj:InvokeServer(item, 1)
                                    obj:InvokeServer("Furniture", item)
                                    obj:InvokeServer("furniture", item)
                                end
                            end)
                            task.wait(0.08)
                        end
                    end
                end
            end
        end
        task.wait(3)
    end
end)

--------------------------------------------------------------------------------
-- 4a. AUTO-CLAIM MISSIONS (snapshot)
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if Config.AutoClaim and GetMissionsSnapshot and ClaimMissionReward then
            pcall(function()
                local snapshot = GetMissionsSnapshot:InvokeServer()
                if snapshot and typeof(snapshot) == "table" then
                    local daily = snapshot.Daily
                    if daily and daily.Tasks then
                        for _, t in ipairs(daily.Tasks) do
                            if t.Completed and not t.Claimed then
                                pcall(function() ClaimMissionReward:InvokeServer("Daily", t.Id) end)
                                task.wait(0.3)
                            end
                        end
                    end
                    if daily and daily.CompletionReady and not daily.CompletionClaimed then
                        pcall(function() ClaimMissionReward:InvokeServer("Daily") end)
                        task.wait(0.2)
                        pcall(function() ClaimMissionReward:InvokeServer("DailyCompletion") end)
                        task.wait(0.2)
                    end
                    local weekly = snapshot.Weekly
                    if weekly and weekly.Missions then
                        for _, t in ipairs(weekly.Missions) do
                            if t.Completed and not t.Claimed then
                                pcall(function() ClaimMissionReward:InvokeServer("Weekly", t.Id) end)
                                task.wait(0.3)
                            end
                        end
                    end
                    if weekly and weekly.CompletionReady and not weekly.CompletionClaimed then
                        pcall(function() ClaimMissionReward:InvokeServer("Weekly") end)
                        task.wait(0.2)
                        pcall(function() ClaimMissionReward:InvokeServer("WeeklyCompletion") end)
                        task.wait(0.2)
                    end
                end
            end)
        end
        task.wait(10)
    end
end)

--------------------------------------------------------------------------------
-- 4b. MISSION FARM (spam-claim)
--------------------------------------------------------------------------------
task.spawn(function()
    local DAILY_IDS  = {"EpalogDay", "RareVisitors", "ServeCustomers"}
    local WEEKLY_IDS = {"MenuMaster", "VIPTreatment", "ConsistentService", "RestaurantRush", "EpicEncounterWeekly"}

    while Running do
        if Config.AutoClaim and ClaimMissionReward then
            for _, id in ipairs(DAILY_IDS) do
                pcall(function() ClaimMissionReward:InvokeServer("Daily", id) end)
                task.wait(0.2)
            end
            for _, id in ipairs(WEEKLY_IDS) do
                pcall(function() ClaimMissionReward:InvokeServer("Weekly", id) end)
                task.wait(0.2)
            end
            local bonusIds = {"CompletionBonus", "DailyCompletion", "Completion", "DailyBonus", "WeeklyBonus", "WeeklyCompletion"}
            for _, id in ipairs(bonusIds) do
                pcall(function() ClaimMissionReward:InvokeServer("Daily", id) end)
                pcall(function() ClaimMissionReward:InvokeServer("Weekly", id) end)
                task.wait(0.1)
            end
            pcall(function() ClaimMissionReward:InvokeServer("DailyCompletion") end)
            pcall(function() ClaimMissionReward:InvokeServer("WeeklyCompletion") end)

            if Remotes then
                for _, obj in ipairs(Remotes:GetDescendants()) do
                    if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction"))
                        and obj.Name:lower():find("completion") then
                        pcall(function()
                            if obj:IsA("RemoteEvent") then
                                obj:FireServer("Daily"); obj:FireServer("Weekly")
                            else
                                obj:InvokeServer("Daily"); obj:InvokeServer("Weekly")
                            end
                        end)
                    end
                end
            end
        end
        task.wait(30)
    end
end)

--------------------------------------------------------------------------------
-- 4c. AUTO-CLICK CLAIM BUTTONS + ACHIEVEMENTS
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if Config.AutoClaim then
            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if playerGui then
                    for _, gui in ipairs(playerGui:GetChildren()) do
                        if gui:IsA("ScreenGui") then
                            for _, desc in ipairs(gui:GetDescendants()) do
                                if desc:IsA("TextButton") then
                                    local txt = (desc.Text or ""):upper():gsub("%s+", "")
                                    if txt == "CLAIM" then
                                        pcall(function() desc:Activate() end)
                                        task.wait(0.3)
                                    end
                                end
                            end
                        end
                    end
                end
            end)

            if GetAchievementsSnapshot and ClaimAchievementReward then
                pcall(function()
                    local res = GetAchievementsSnapshot:InvokeServer()
                    if res and typeof(res) == "table" then
                        if res[1] and typeof(res[1]) == "table" then res = res[1] end
                        for category, data in pairs(res) do
                            if typeof(data) == "table" then
                                local items = data
                                if data.Tasks then items = data.Tasks end
                                if data.Missions then items = data.Missions end
                                if typeof(items) == "table" then
                                    for _, item in ipairs(items) do
                                        if typeof(item) == "table" and item.Completed
                                            and not item.Claimed and item.Id then
                                            pcall(function()
                                                ClaimAchievementReward:InvokeServer(category, item.Id)
                                            end)
                                            task.wait(0.3)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end)
            end
        end
        task.wait(15)
    end
end)

--------------------------------------------------------------------------------
-- 5. AUTO-HIDE COUNTER UI
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        pcall(function()
            local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
            if playerGui then
                for _, gui in ipairs(playerGui:GetChildren()) do
                    if gui:IsA("ScreenGui") then
                        for _, desc in ipairs(gui:GetDescendants()) do
                            if desc:IsA("TextLabel") then
                                local txt = desc.Text:upper()
                                if txt == "COUNTER" or txt:find("AVAILABLE SEATS") then
                                    local frame = desc.Parent
                                    while frame and not frame:IsA("ScreenGui") do
                                        if frame:IsA("Frame") or frame:IsA("CanvasGroup") then
                                            frame.Visible = false
                                            break
                                        end
                                        frame = frame.Parent
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
        task.wait(2)
    end
end)

--------------------------------------------------------------------------------
-- 6. ANTI-AFK
--------------------------------------------------------------------------------
pcall(function()
    LocalPlayer.Idled:Connect(function()
        if Config.AntiAFK then
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.1)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
        end
    end)
end)

task.spawn(function()
    while Running do
        if Config.AntiAFK then
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.1)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                task.wait(0.1)
                VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
            end)
        end
        task.wait(60)
    end
end)

--------------------------------------------------------------------------------
print("[RaicyHUB v2.3.1] All systems active! 🔥")
