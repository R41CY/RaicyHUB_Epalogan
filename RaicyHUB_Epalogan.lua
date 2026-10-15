--[[
    ================================================================================
    Epalogan Tycoon - Auto-Worker Script (Clean Build)
    ================================================================================
    Core Features:
      1. Auto-Assign (seats customers to tables via RemoteEvent)
      2. Auto-Pick Up (grabs food from counter)
      3. Auto-Serve (delivers food to customers at tables)
      4. Auto-Buy Ingredients (restocks when low)
    ================================================================================
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

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

if ParentGui:FindFirstChild("EpalogWorkerUI") then
    ParentGui.EpalogWorkerUI:Destroy()
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
local CounterAssignCustomer = Remotes and Remotes:FindFirstChild("CounterAssignCustomer")
local ClaimMissionReward = Remotes and Remotes:FindFirstChild("ClaimMissionReward")
local GetMissionsSnapshot = Remotes and Remotes:FindFirstChild("GetMissionsSnapshot")

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

--------------------------------------------------------------------------------
-- Config & State
--------------------------------------------------------------------------------
local Config = {
    AutoAssign = true,
    AutoPickUp = true,
    AutoServe = true,
    AutoBuy = true,
    AutoClaim = true,
    AntiAFK = true,
    SeatDelay = 0.1,
    BuyThreshold = 35,
}

local Stats = {
    Seated = 0,
    PickedUp = 0,
    Served = 0,
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
-- Food Tool Detection
--------------------------------------------------------------------------------
local function getFoodTool()
    local c = LocalPlayer.Character
    if c then
        for _, item in ipairs(c:GetChildren()) do
            if item:IsA("Tool") then return item, true end
        end
    end
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        for _, item in ipairs(bp:GetChildren()) do
            if item:IsA("Tool") then return item, false end
        end
    end
    return nil, false
end

local function equipFood()
    local tool, isEquipped = getFoodTool()
    if tool and not isEquipped then
        local c = LocalPlayer.Character
        local hum = c and c:FindFirstChild("Humanoid")
        if hum then
            hum:EquipTool(tool)
            task.wait(0.08)
        end
    end
    return tool
end

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

--------------------------------------------------------------------------------
-- Get position from a prompt (walks up hierarchy)
--------------------------------------------------------------------------------
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
-- Prompt Classification (SIMPLE: ActionText is the primary signal)
--------------------------------------------------------------------------------
local function isPickupPrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local action = (prompt.ActionText or ""):lower()
    -- REJECT serve prompts
    if action:find("serve") or action:find("give") or action:find("deliver") then return false end
    if action:find("manage") then return false end
    -- Must say pick up / take / grab
    return action:find("pick") or action:find("take") or action:find("grab")
        or action:find("get") or action:find("kuha") or action:find("collect")
end

local function isServePrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local action = (prompt.ActionText or ""):lower()
    -- REJECT pickup prompts
    if action:find("pick") or action:find("grab") or action:find("kuha") then return false end
    -- Must say serve / give / deliver
    return action:find("serve") or action:find("give") or action:find("deliver")
end

--------------------------------------------------------------------------------
-- GUI — RaicyHUB (Premium Dark Theme, Collapsible)
--------------------------------------------------------------------------------
local TweenService = game:GetService("TweenService")

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "EpalogWorkerUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = ParentGui

-- Roblox icon asset IDs
local ICONS = {
    Assign = "rbxassetid://6764432293",   -- chair/seat
    PickUp = "rbxassetid://6764432408",   -- hand/grab
    Serve  = "rbxassetid://6764432293",   -- plate
    Buy    = "rbxassetid://6764432148",   -- cart
    Claim  = "rbxassetid://6764432408",   -- trophy
    Logo   = "rbxassetid://6764432293",   -- star
}

-- Color palette
local COLORS = {
    bg        = Color3.fromRGB(15, 15, 25),
    header    = Color3.fromRGB(22, 22, 38),
    card      = Color3.fromRGB(25, 25, 42),
    accent    = Color3.fromRGB(130, 80, 255),
    accentAlt = Color3.fromRGB(90, 200, 250),
    on        = Color3.fromRGB(45, 200, 120),
    off       = Color3.fromRGB(200, 50, 60),
    text      = Color3.fromRGB(230, 230, 245),
    textDim   = Color3.fromRGB(140, 140, 170),
    border    = Color3.fromRGB(50, 50, 80),
}

local EXPANDED_SIZE = UDim2.new(0, 240, 0, 376)
local COLLAPSED_SIZE = UDim2.new(0, 240, 0, 36)
local _isExpanded = true

-- Main frame
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = EXPANDED_SIZE
MainFrame.Position = UDim2.new(0, 12, 0.5, -170)
MainFrame.BackgroundColor3 = COLORS.bg
MainFrame.BackgroundTransparency = 0.08
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 8)

-- Subtle border stroke
local stroke = Instance.new("UIStroke")
stroke.Color = COLORS.border
stroke.Thickness = 1
stroke.Transparency = 0.5
stroke.Parent = MainFrame

-- Header bar
local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 36)
Header.BackgroundColor3 = COLORS.header
Header.BorderSizePixel = 0
Header.Parent = MainFrame
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 8)

-- Accent line under header
local AccentLine = Instance.new("Frame")
AccentLine.Size = UDim2.new(1, -16, 0, 2)
AccentLine.Position = UDim2.new(0, 8, 1, -2)
AccentLine.BackgroundColor3 = COLORS.accent
AccentLine.BorderSizePixel = 0
AccentLine.Parent = Header
Instance.new("UICorner", AccentLine).CornerRadius = UDim.new(0, 1)

-- Gradient on accent line
local gradient = Instance.new("UIGradient")
gradient.Color = ColorSequence.new{
    ColorSequenceKeypoint.new(0, COLORS.accent),
    ColorSequenceKeypoint.new(1, COLORS.accentAlt),
}
gradient.Parent = AccentLine

-- Hub name
local HubTitle = Instance.new("TextLabel")
HubTitle.Size = UDim2.new(1, -60, 1, 0)
HubTitle.Position = UDim2.new(0, 12, 0, 0)
HubTitle.BackgroundTransparency = 1
HubTitle.Text = "RaicyHUB"
HubTitle.TextColor3 = COLORS.text
HubTitle.TextSize = 15
HubTitle.Font = Enum.Font.GothamBold
HubTitle.TextXAlignment = Enum.TextXAlignment.Left
HubTitle.Parent = Header

-- Version badge
local VerBadge = Instance.new("TextLabel")
VerBadge.Size = UDim2.new(0, 30, 0, 14)
VerBadge.Position = UDim2.new(0, 82, 0.5, -7)
VerBadge.BackgroundColor3 = COLORS.accent
VerBadge.BackgroundTransparency = 0.3
VerBadge.Text = "v1.1"
VerBadge.TextColor3 = COLORS.text
VerBadge.TextSize = 9
VerBadge.Font = Enum.Font.GothamBold
VerBadge.Parent = Header
Instance.new("UICorner", VerBadge).CornerRadius = UDim.new(0, 4)

-- Minimize button
local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 28, 0, 28)
MinBtn.Position = UDim2.new(1, -34, 0.5, -14)
MinBtn.BackgroundColor3 = COLORS.card
MinBtn.BackgroundTransparency = 0.3
MinBtn.Text = "—"
MinBtn.TextColor3 = COLORS.textDim
MinBtn.TextSize = 16
MinBtn.Font = Enum.Font.GothamBold
MinBtn.Parent = Header
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 6)

-- Content container (everything below header)
local Content = Instance.new("Frame")
Content.Name = "Content"
Content.Size = UDim2.new(1, 0, 1, -40)
Content.Position = UDim2.new(0, 0, 0, 40)
Content.BackgroundTransparency = 1
Content.Parent = MainFrame

-- Minimize/Maximize toggle
MinBtn.MouseButton1Click:Connect(function()
    _isExpanded = not _isExpanded
    local targetSize = _isExpanded and EXPANDED_SIZE or COLLAPSED_SIZE
    MinBtn.Text = _isExpanded and "—" or "+"
    TweenService:Create(MainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Size = targetSize
    }):Play()
end)

-- Toggle buttons
local toggles = {}
local features = {
    {"Auto-Assign",  "AutoAssign", COLORS.on},
    {"Auto-Pick Up", "AutoPickUp", COLORS.on},
    {"Auto-Serve",   "AutoServe",  COLORS.on},
    {"Auto-Buy",     "AutoBuy",    COLORS.on},
    {"Auto-Claim",   "AutoClaim",  COLORS.on},
    {"Anti-AFK",     "AntiAFK",    COLORS.on},
}

for i, feat in ipairs(features) do
    local row = Instance.new("Frame")
    row.Size = UDim2.new(0.92, 0, 0, 30)
    row.Position = UDim2.new(0.04, 0, 0, (i - 1) * 36)
    row.BackgroundColor3 = COLORS.card
    row.BackgroundTransparency = 0.3
    row.BorderSizePixel = 0
    row.Parent = Content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    -- Status indicator dot
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 8, 0, 8)
    dot.Position = UDim2.new(0, 10, 0.5, -4)
    dot.BackgroundColor3 = COLORS.on
    dot.BorderSizePixel = 0
    dot.Parent = row
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    -- Label
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.6, 0, 1, 0)
    label.Position = UDim2.new(0, 26, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = feat[1]
    label.TextColor3 = COLORS.text
    label.TextSize = 12
    label.Font = Enum.Font.GothamSemibold
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    -- Toggle button
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.new(0, 44, 0, 20)
    toggleBtn.Position = UDim2.new(1, -52, 0.5, -10)
    toggleBtn.BackgroundColor3 = COLORS.on
    toggleBtn.BackgroundTransparency = 0.15
    toggleBtn.Text = "ON"
    toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    toggleBtn.TextSize = 10
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.Parent = row
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 4)

    toggleBtn.MouseButton1Click:Connect(function()
        Config[feat[2]] = not Config[feat[2]]
        if Config[feat[2]] then
            toggleBtn.BackgroundColor3 = COLORS.on
            toggleBtn.Text = "ON"
            dot.BackgroundColor3 = COLORS.on
        else
            toggleBtn.BackgroundColor3 = COLORS.off
            toggleBtn.Text = "OFF"
            dot.BackgroundColor3 = COLORS.off
        end
    end)

    toggles[feat[2]] = {btn = toggleBtn, dot = dot}
end

-- Divider line
local Divider = Instance.new("Frame")
Divider.Size = UDim2.new(0.88, 0, 0, 1)
Divider.Position = UDim2.new(0.06, 0, 0, #features * 36 + 4)
Divider.BackgroundColor3 = COLORS.border
Divider.BackgroundTransparency = 0.5
Divider.BorderSizePixel = 0
Divider.Parent = Content

-- Stats panel
local StatsLabel = Instance.new("TextLabel")
StatsLabel.Size = UDim2.new(0.92, 0, 0, 80)
StatsLabel.Position = UDim2.new(0.04, 0, 0, #features * 36 + 10)
StatsLabel.BackgroundColor3 = COLORS.card
StatsLabel.BackgroundTransparency = 0.4
StatsLabel.Text = "Seated: 0  |  Picked: 0  |  Served: 0"
StatsLabel.TextColor3 = COLORS.textDim
StatsLabel.TextSize = 11
StatsLabel.Font = Enum.Font.Gotham
StatsLabel.TextWrapped = true
StatsLabel.TextYAlignment = Enum.TextYAlignment.Top
StatsLabel.Parent = Content
Instance.new("UICorner", StatsLabel).CornerRadius = UDim.new(0, 6)
local sp = Instance.new("UIPadding"); sp.PaddingLeft = UDim.new(0, 8); sp.PaddingTop = UDim.new(0, 6); sp.Parent = StatsLabel

-- Draggable (header only)
local dragging, dragStart, startPos
Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
    end
end)
Header.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

--------------------------------------------------------------------------------
-- 1. AUTO-ASSIGN (seats customers to tables)
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if Config.AutoAssign and CounterAssignCustomer then
            local plots = workspace:FindFirstChild("EpaloganPlots")
            if plots then
                for _, plot in ipairs(plots:GetChildren()) do
                    if plot.Name:find(tostring(LocalPlayer.UserId)) then
                        for _, child in ipairs(plot:GetDescendants()) do
                            if not Config.AutoAssign then break end
                            if child.Name:match("^Table%d+$") then
                                for _, seat in ipairs(child:GetDescendants()) do
                                    if not Config.AutoAssign then break end
                                    if seat.Name:match("^ChairSlot%d+$") then
                                        pcall(function()
                                            CounterAssignCustomer:FireServer(child.Name, seat.Name)
                                        end)
                                        Stats.Seated = Stats.Seated + 1
                                        task.wait(Config.SeatDelay)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        task.wait(0.1)
    end
end)

--------------------------------------------------------------------------------
-- 2. AUTO-PICKUP & AUTO-SERVE (SMART: matches food to customer orders)
--------------------------------------------------------------------------------
local KNOWN_FOODS = {"lugaw", "epalog", "pares", "lomi", "batangas", "adobo", "sinigang", "tapsilog", "sisig", "bulalo", "kare"}

-- Extract food name from a prompt or its nearby context
local function getFoodFromPrompt(prompt)
    -- Check ActionText and ObjectText
    local texts = {
        (prompt.ActionText or ""):lower(),
        (prompt.ObjectText or ""):lower(),
    }
    -- Check parent model/part names
    local parent = prompt.Parent
    while parent and parent ~= workspace do
        table.insert(texts, parent.Name:lower())
        -- Check for TextLabels/BillboardGuis nearby
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("TextLabel") or child:IsA("BillboardGui") then
                if child:IsA("TextLabel") then
                    table.insert(texts, child.Text:lower())
                else
                    for _, desc in ipairs(child:GetDescendants()) do
                        if desc:IsA("TextLabel") then
                            table.insert(texts, desc.Text:lower())
                        end
                    end
                end
            end
        end
        parent = parent.Parent
    end

    -- Match against known foods
    local combined = table.concat(texts, " ")
    for _, food in ipairs(KNOWN_FOODS) do
        if combined:find(food) then
            return food
        end
    end
    return nil
end

local _lastAction = "serve" -- start by trying pickup first
task.spawn(function()
    while Running do
        if Config.AutoPickUp or Config.AutoServe then
            if _lastAction == "serve" then
                -- STEP 1: Check what customers want FIRST
                local wantedFoods = {}
                local servePrompts = {}
                for _, obj in ipairs(workspace:GetDescendants()) do
                    if obj:IsA("ProximityPrompt") and obj.Enabled and isServePrompt(obj) then
                        local food = getFoodFromPrompt(obj)
                        if food then
                            wantedFoods[food] = true
                        end
                        table.insert(servePrompts, {prompt = obj, food = food})
                    end
                end

                -- STEP 2: Find pickup prompt matching a wanted food
                local found = false
                if Config.AutoPickUp then
                    -- First try: match a specific food order
                    for _, obj in ipairs(workspace:GetDescendants()) do
                        if obj:IsA("ProximityPrompt") and obj.Enabled and isPickupPrompt(obj) then
                            local stationFood = getFoodFromPrompt(obj)
                            if stationFood and wantedFoods[stationFood] then
                                local pos = getPromptPosition(obj)
                                if pos then
                                    moveTo(pos)
                                    task.wait(0.05)
                                    triggerPrompt(obj)
                                    Stats.PickedUp = Stats.PickedUp + 1
                                    task.wait(0.05)
                                    _lastAction = "pickup"
                                    found = true
                                    break
                                end
                            end
                        end
                    end
                    -- Fallback: pick up any available food
                    if not found then
                        for _, obj in ipairs(workspace:GetDescendants()) do
                            if obj:IsA("ProximityPrompt") and obj.Enabled and isPickupPrompt(obj) then
                                local pos = getPromptPosition(obj)
                                if pos then
                                    moveTo(pos)
                                    task.wait(0.05)
                                    triggerPrompt(obj)
                                    Stats.PickedUp = Stats.PickedUp + 1
                                    task.wait(0.05)
                                    _lastAction = "pickup"
                                    found = true
                                    break
                                end
                            end
                        end
                    end
                end
                if not found then _lastAction = "pickup" end

            else
                -- JUST PICKED UP → serve matching customer
                local found = false
                if Config.AutoServe then
                    for _, obj in ipairs(workspace:GetDescendants()) do
                        if obj:IsA("ProximityPrompt") and obj.Enabled and isServePrompt(obj) then
                            local pos = getPromptPosition(obj)
                            if pos then
                                moveTo(pos)
                                task.wait(0.05)
                                triggerPrompt(obj)
                                Stats.Served = Stats.Served + 1
                                task.wait(0.05)
                                _lastAction = "serve"
                                found = true
                                break
                            end
                        end
                    end
                end
                if not found then _lastAction = "serve" end
            end
        end
        task.wait(0.08)
    end
end)

--------------------------------------------------------------------------------
-- 3. AUTO-BUY INGREDIENTS
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if Config.AutoBuy then
            -- Method 1: Try remote (if found)
            if BuyIngredientRemote then
                -- Buy ALL ingredients with name variants (covers new recipes too)
                local ingredients = {
                    "Egg", "Harina", "Asin", "Pork", "Chicken", "Beef", "Rice", "Noodles",
                    "Toyo", "Suka", "Patis", "Garlic", "Onion",
                    -- Cooking Oil variants
                    "Cooking Oil", "CookingOil", "Oil", "Cooking_Oil",
                    -- Extra ingredients for future recipes
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

            -- Method 2: Click BUY buttons in the grocery store UI
            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if playerGui then
                    for _, gui in ipairs(playerGui:GetChildren()) do
                        if gui:IsA("ScreenGui") then
                            for _, desc in ipairs(gui:GetDescendants()) do
                                if desc:IsA("TextButton") or desc:IsA("TextLabel") then
                                    local txt = desc.Text:upper()
                                    if txt == "BUY" and desc:IsA("TextButton") then
                                        -- Check if parent shows 0/100 or low stock
                                        local parentFrame = desc.Parent
                                        if parentFrame then
                                            local needsBuy = false
                                            for _, sibling in ipairs(parentFrame:GetChildren()) do
                                                if sibling:IsA("TextLabel") then
                                                    local t = sibling.Text
                                                    -- Check for "0 / 100" or low numbers
                                                    local current = t:match("(%d+)%s*/%s*%d+")
                                                    if current and tonumber(current) < 50 then
                                                        needsBuy = true
                                                        break
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
-- 3b. AUTO-BUY FURNITURE (Legendary / Heaven / Epic priority)
--------------------------------------------------------------------------------
local RARE_PRIORITIES = {"HEAVEN", "LEGENDARY"}

task.spawn(function()
    while Running do
        if Config.AutoBuy then
            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if not playerGui then return end

                for _, gui in ipairs(playerGui:GetChildren()) do
                    if not gui:IsA("ScreenGui") then continue end

                    -- Check if this is the Furniture Store
                    local isFurnitureStore = false
                    for _, desc in ipairs(gui:GetDescendants()) do
                        if desc:IsA("TextLabel") and desc.Text:upper():find("FURNITURE STORE") then
                            isFurnitureStore = true
                            break
                        end
                    end

                    if isFurnitureStore then
                        -- Collect all item cards with their rarity
                        for _, desc in ipairs(gui:GetDescendants()) do
                            if desc:IsA("TextLabel") then
                                local txt = desc.Text:upper()
                                -- Check if this label shows a rare rarity
                                for _, rarity in ipairs(RARE_PRIORITIES) do
                                    if txt == rarity then
                                        -- Found a rarity label! Look for BUY button in same parent frame
                                        local card = desc.Parent
                                        if card then
                                            -- Walk up to find the item card container
                                            for _ = 1, 3 do
                                                if card then
                                                    for _, child in ipairs(card:GetDescendants()) do
                                                        if child:IsA("TextButton") then
                                                            local btnText = child.Text:upper():gsub("%s+", "")
                                                            -- Only click BUY, not SOLD OUT
                                                            if btnText == "BUY" then
                                                                pcall(function() child:Activate() end)
                                                                task.wait(0.3)
                                                            end
                                                        end
                                                    end
                                                    card = card.Parent
                                                end
                                            end
                                        end
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end)

            -- Also try furniture buy remotes
            if Remotes then
                local furnitureItems = {
                    -- Chairs (best first)
                    "Demon Angel Chair", "King Chair", "Queen Chair",
                    -- Tables (best first)
                    "Angel Table", "Banana Leaf Table",
                }
                for _, obj in ipairs(Remotes:GetDescendants()) do
                    if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction"))
                        and (obj.Name:lower():find("buy") or obj.Name:lower():find("purchase"))
                        and obj.Name:lower():find("furniture") then
                        for _, item in ipairs(furnitureItems) do
                            pcall(function()
                                if obj:IsA("RemoteEvent") then
                                    obj:FireServer(item)
                                else
                                    obj:InvokeServer(item)
                                end
                            end)
                            task.wait(0.1)
                        end
                        break
                    end
                end
            end
        end
        task.wait(3)
    end
end)

--------------------------------------------------------------------------------
-- 4. AUTO-CLAIM MISSIONS (claims completed unclaimed rewards)
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if Config.AutoClaim and GetMissionsSnapshot and ClaimMissionReward then
            pcall(function()
                local snapshot = GetMissionsSnapshot:InvokeServer()
                if snapshot and typeof(snapshot) == "table" then
                    -- Handle Daily missions
                    local daily = snapshot.Daily
                    if daily and daily.Tasks then
                        for _, task_item in ipairs(daily.Tasks) do
                            if task_item.Completed and not task_item.Claimed then
                                pcall(function()
                                    ClaimMissionReward:InvokeServer("Daily", task_item.Id)
                                end)
                                task.wait(0.3)
                            end
                        end
                    end
                    -- Claim Daily COMPLETION BONUS if ready
                    if daily and daily.CompletionReady and not daily.CompletionClaimed then
                        pcall(function() ClaimMissionReward:InvokeServer("Daily") end)
                        task.wait(0.2)
                        pcall(function() ClaimMissionReward:InvokeServer("DailyCompletion") end)
                        task.wait(0.2)
                    end
                    -- Handle Weekly missions
                    local weekly = snapshot.Weekly
                    if weekly and weekly.Missions then
                        for _, task_item in ipairs(weekly.Missions) do
                            if task_item.Completed and not task_item.Claimed then
                                pcall(function()
                                    ClaimMissionReward:InvokeServer("Weekly", task_item.Id)
                                end)
                                task.wait(0.3)
                            end
                        end
                    end
                    -- Claim Weekly COMPLETION BONUS if ready
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
-- 4b. MISSION FARM (spam-claims ALL mission IDs on loop)
--------------------------------------------------------------------------------
task.spawn(function()
    local DAILY_IDS = {"EpalogDay", "RareVisitors", "ServeCustomers"}
    local WEEKLY_IDS = {"MenuMaster", "VIPTreatment", "ConsistentService", "RestaurantRush", "EpicEncounterWeekly"}

    while Running do
        if Config.AutoClaim and ClaimMissionReward then
            -- Spam claim every daily mission
            for _, id in ipairs(DAILY_IDS) do
                pcall(function()
                    ClaimMissionReward:InvokeServer("Daily", id)
                end)
                task.wait(0.2)
            end
            -- Spam claim every weekly mission
            for _, id in ipairs(WEEKLY_IDS) do
                pcall(function()
                    ClaimMissionReward:InvokeServer("Weekly", id)
                end)
                task.wait(0.2)
            end

            -- Claim COMPLETION BONUSES (Daily + Weekly)
            local completionIds = {"CompletionBonus", "DailyCompletion", "Completion", "DailyBonus", "WeeklyBonus", "WeeklyCompletion"}
            for _, id in ipairs(completionIds) do
                pcall(function() ClaimMissionReward:InvokeServer("Daily", id) end)
                pcall(function() ClaimMissionReward:InvokeServer("Weekly", id) end)
                task.wait(0.1)
            end
            -- Try claiming completion as a category directly
            pcall(function() ClaimMissionReward:InvokeServer("DailyCompletion") end)
            pcall(function() ClaimMissionReward:InvokeServer("WeeklyCompletion") end)

            -- Search for any completion-specific remote
            if Remotes then
                for _, obj in ipairs(Remotes:GetDescendants()) do
                    if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction")) and obj.Name:lower():find("completion") then
                        pcall(function()
                            if obj:IsA("RemoteEvent") then
                                obj:FireServer("Daily")
                                obj:FireServer("Weekly")
                            else
                                obj:InvokeServer("Daily")
                                obj:InvokeServer("Weekly")
                            end
                        end)
                    end
                end
            end

            -- Also try FireServer in case it works as RemoteEvent too
            pcall(function()
                for _, id in ipairs(DAILY_IDS) do
                    ClaimMissionReward:FireServer("Daily", id)
                    task.wait(0.1)
                end
                for _, id in ipairs(WEEKLY_IDS) do
                    ClaimMissionReward:FireServer("Weekly", id)
                    task.wait(0.1)
                end
            end)
        end
        task.wait(30)
    end
end)

--------------------------------------------------------------------------------
-- 4c. AUTO-CLICK CLAIM BUTTONS (Missions + Achievements UI)
--------------------------------------------------------------------------------
local ClaimAchievementReward = Remotes and (Remotes:FindFirstChild("ClaimAchievementReward") 
    or Remotes:FindFirstChild("ClaimAchievement"))
local GetAchievementsSnapshot = Remotes and Remotes:FindFirstChild("GetAchievementsSnapshot")

task.spawn(function()
    while Running do
        if Config.AutoClaim then
            -- Method 1: Click all CLAIM buttons in PlayerGui
            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                if playerGui then
                    for _, gui in ipairs(playerGui:GetChildren()) do
                        if gui:IsA("ScreenGui") then
                            for _, desc in ipairs(gui:GetDescendants()) do
                                if desc:IsA("TextButton") then
                                    local txt = desc.Text:upper():gsub("%s+", "")
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

            -- Method 2: Try achievement remotes
            if GetAchievementsSnapshot and ClaimAchievementReward then
                pcall(function()
                    local res = GetAchievementsSnapshot:InvokeServer()
                    if res and typeof(res) == "table" then
                        if res[1] and typeof(res[1]) == "table" then res = res[1] end
                        -- Scan all categories (Lifetime, Ratings, Ultimate, Titles)
                        for category, data in pairs(res) do
                            if typeof(data) == "table" then
                                local items = data
                                if data.Tasks then items = data.Tasks end
                                if data.Missions then items = data.Missions end
                                if typeof(items) == "table" then
                                    for _, item in ipairs(items) do
                                        if typeof(item) == "table" and item.Completed and not item.Claimed and item.Id then
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
-- 4. STATS UPDATER
--------------------------------------------------------------------------------
task.spawn(function()
    while Running do
        if StatsLabel and StatsLabel.Parent then
            local hasFood = (_lastAction == "pickup")
            StatsLabel.Text = string.format(
                "Picked Up: %d\nServed: %d\nHolding Food: %s",
                Stats.PickedUp, Stats.Served,
                hasFood and "YES" or "NO"
            )
        end
        task.wait(1)
    end
end)

--------------------------------------------------------------------------------
-- Auto-Hide Counter UI
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
-- 5. ANTI-AFK (prevents idle kick)
--------------------------------------------------------------------------------
-- Method 1: Hook the Idled event to block the 20-minute kick
local _idledConnection
pcall(function()
    _idledConnection = LocalPlayer.Idled:Connect(function()
        if Config.AntiAFK then
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.1)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
        end
    end)
end)

-- Method 2: Periodic simulated input as a safety net (every 60s)
task.spawn(function()
    while Running do
        if Config.AntiAFK then
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.1)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
            -- Also try clicking as some games check mouse input
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                task.wait(0.1)
                VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
            end)
        end
        task.wait(60)
    end
end)

print("[Epalogan Worker] Script loaded! Auto-Assign + Auto-Pickup + Auto-Serve + Auto-Buy + Anti-AFK active.")
