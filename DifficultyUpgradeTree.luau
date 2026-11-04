-- The Difficulty Upgrade Tree: Regrown
local ctx = ...
local task = ctx.task

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local Settings = {
	AutoBuy = false,
	BuyInterval = 1,
	BuyFilter = {},
	AutoRest = false,
	RestInterval = 30,
	GodMode = false,
	BypassAntiClip = false,
	SpeedBoost = false,
	WalkSpeed = 30,
	JumpBoost = false,
	JumpPower = 75,
	Noclip = false,
	Fly = false,
	FlySpeed = 50,
	InfiniteJump = false,
	MuteMusic = false,
	FullBright = false,
}

---------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------

local function getCharacterParts()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, root
end

local function runLoop(label, enabled, step, getInterval)
	task.spawn(function()
		local lastError
		while ctx:Alive() and enabled() do
			local ok, err = pcall(step)
			if not ok and err ~= lastError then
				lastError = err
				ctx.Log(label .. ": " .. tostring(err), "error")
			end
			task.wait(getInterval())
		end
	end)
end

-- Removes rich text tags and the zero-width spaces the game puts around numbers.
local function cleanText(text)
	return (text:gsub("<[^>]+>", ""):gsub("\226\128\139", ""))
end

---------------------------------------------------------------------
-- Upgrades
---------------------------------------------------------------------

local function upgradeNumber(folder)
	return tonumber(folder.Name:match("^UP(-?%d+)$")) or math.huge
end

-- Upgrades in tree order. Found on every call because the game can swap the map out.
local function getUpgrades()
	local list = {}
	local folder = workspace:FindFirstChild("Upgrades")
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:FindFirstChild("Values") and child:FindFirstChild("Main") then
				table.insert(list, child)
			end
		end
	end
	table.sort(list, function(a, b)
		return upgradeNumber(a) < upgradeNumber(b)
	end)
	return list
end

local function getUpgradeName(upgrade)
	local name = upgrade.Values:FindFirstChild("UpgradeName")
	return name and name.Value or upgrade.Name
end

local function getUpgradeOption(upgrade)
	return upgrade.Name .. " " .. getUpgradeName(upgrade)
end

local function getUpgradeOptions()
	local options = {}
	for _, upgrade in ipairs(getUpgrades()) do
		table.insert(options, getUpgradeOption(upgrade))
	end
	return options
end

local function findUpgradeFromOption(option)
	local id = type(option) == "string" and option:match("^%S+")
	for _, upgrade in ipairs(getUpgrades()) do
		if upgrade.Name == id then
			return upgrade
		end
	end
	return nil
end

-- The game drops a maxed upgrade's click range to 0.
local function getBuyDetector(upgrade)
	local detector = upgrade.Main:FindFirstChildOfClass("ClickDetector")
	if detector and detector.MaxActivationDistance > 0 then
		return detector
	end
	return nil
end

local function isUpgradeSelected(upgrade)
	if #Settings.BuyFilter == 0 then
		return true
	end
	return table.find(Settings.BuyFilter, getUpgradeOption(upgrade)) ~= nil
end

local function buyStep()
	for _, upgrade in ipairs(getUpgrades()) do
		if not Settings.AutoBuy then
			return
		end
		local detector = isUpgradeSelected(upgrade) and getBuyDetector(upgrade)
		if detector then
			fireclickdetector(detector)
			task.wait(0.05)
		end
	end
end

local function getUpgradeLabel(upgrade, name)
	local gui = upgrade.Main:FindFirstChildOfClass("SurfaceGui")
	local label = gui and gui:FindFirstChild(name)
	return label and label:IsA("TextLabel") and cleanText(label.Text) or "?"
end

local function getUpgradeRows()
	local rows = {}
	for _, upgrade in ipairs(getUpgrades()) do
		table.insert(rows, {
			id = upgrade.Name,
			name = getUpgradeName(upgrade),
			level = (getUpgradeLabel(upgrade, "Level"):gsub("^Level:%s*", "")),
			price = (getUpgradeLabel(upgrade, "Price"):gsub("^Requirement:%s*", "")),
		})
	end
	return rows
end

---------------------------------------------------------------------
-- Rest
---------------------------------------------------------------------

local function findRestPrompt()
	local folder = workspace:FindFirstChild("Incremental")
	if folder then
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and descendant.ActionText == "Rest" then
				return descendant
			end
		end
	end
	return nil
end

local function restStep()
	local prompt = findRestPrompt()
	if prompt then
		fireproximityprompt(prompt)
	end
end

---------------------------------------------------------------------
-- God Mode
---------------------------------------------------------------------

-- TouchScript reports hazards to the server through this remote. Heals still go through.
local function getDamageEvent()
	local folder = ReplicatedStorage:FindFirstChild("Event")
	folder = folder and folder:FindFirstChild("Important")
	return folder and folder:FindFirstChild("DamageEvent")
end

local removeDamageHook

local function setGodMode(enabled)
	Settings.GodMode = enabled
	if not enabled then
		if removeDamageHook then
			removeDamageHook()
			removeDamageHook = nil
		end
		return
	end
	if removeDamageHook then
		return
	end
	local damageEvent = getDamageEvent()
	if not damageEvent then
		ctx.Notify("Damage remote not found in this zone.", "warning")
		return
	end
	removeDamageHook = ctx:HookMeta(game, "__namecall", function(old, self, ...)
		if self == damageEvent and getnamecallmethod() == "FireServer" and (...) ~= "Heal" then
			return nil
		end
		return old(self, ...)
	end)
end

---------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------

-- The game's anti-clip script ignores anyone with something named Noclip on their character.
local BYPASS_NAME = "Noclip"
local bypassMarker

local function updateAntiClipBypass()
	local needed = Settings.BypassAntiClip or Settings.Noclip or Settings.Fly
	local character = LocalPlayer.Character
	if needed and character then
		if not character:FindFirstChild(BYPASS_NAME) then
			bypassMarker = Instance.new("Folder")
			bypassMarker.Name = BYPASS_NAME
			bypassMarker.Parent = character
		end
	elseif bypassMarker then
		bypassMarker:Destroy()
		bypassMarker = nil
	end
end

ctx:Connect(LocalPlayer.CharacterAdded, function(character)
	bypassMarker = nil
	character:WaitForChild("Humanoid")
	updateAntiClipBypass()
end)

local originalSpeed = setmetatable({}, { __mode = "k" })
local originalJump = setmetatable({}, { __mode = "k" })

local function restoreSpeed()
	local _, humanoid = getCharacterParts()
	if humanoid and originalSpeed[humanoid] then
		humanoid.WalkSpeed = originalSpeed[humanoid]
		originalSpeed[humanoid] = nil
	end
end

local function restoreJump()
	local _, humanoid = getCharacterParts()
	local saved = humanoid and originalJump[humanoid]
	if saved then
		humanoid.UseJumpPower = saved.UseJumpPower
		humanoid.JumpPower = saved.JumpPower
		originalJump[humanoid] = nil
	end
end

local noclipParts = {}

local function restoreNoclip()
	for part in pairs(noclipParts) do
		if part.Parent then
			part.CanCollide = true
		end
	end
	table.clear(noclipParts)
end

ctx:Connect(RunService.Stepped, function()
	if not Settings.Noclip then
		return
	end
	local character = LocalPlayer.Character
	if character then
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				noclipParts[part] = true
				part.CanCollide = false
			end
		end
	end
end)

ctx:Connect(RunService.Heartbeat, function()
	local _, humanoid, root = getCharacterParts()
	if not humanoid then
		return
	end

	if Settings.SpeedBoost then
		originalSpeed[humanoid] = originalSpeed[humanoid] or humanoid.WalkSpeed
		humanoid.WalkSpeed = Settings.WalkSpeed
	end

	if Settings.JumpBoost then
		originalJump[humanoid] = originalJump[humanoid]
			or { UseJumpPower = humanoid.UseJumpPower, JumpPower = humanoid.JumpPower }
		humanoid.UseJumpPower = true
		humanoid.JumpPower = Settings.JumpPower
	end

	if Settings.Fly and root then
		local vertical = 0
		if not UserInputService:GetFocusedTextBox() then
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				vertical += 1
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
				vertical -= 1
			end
		end
		root.AssemblyLinearVelocity = (humanoid.MoveDirection + Vector3.new(0, vertical, 0)) * Settings.FlySpeed
	end
end)

ctx:Connect(UserInputService.JumpRequest, function()
	if Settings.InfiniteJump then
		local _, humanoid = getCharacterParts()
		if humanoid then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end
end)

ctx:OnCleanup(function()
	restoreSpeed()
	restoreJump()
	restoreNoclip()
	if bypassMarker then
		bypassMarker:Destroy()
		bypassMarker = nil
	end
end)

---------------------------------------------------------------------
-- Currency
---------------------------------------------------------------------

local function getCurrencyText()
	local folder = ReplicatedStorage:FindFirstChild("CurrencyDisplay")
	local display = folder and folder:FindFirstChild("Display")
	if not display then
		return "Currency display not found in this zone"
	end
	local lines = {}
	for _, value in ipairs(display:GetChildren()) do
		if value:IsA("StringValue") and not value.Name:find("Boost$") then
			local text = cleanText(value.Value)
			if text ~= "" and text ~= "0" and text ~= "???" then
				table.insert(lines, text:find(":") and text or (value.Name .. ": " .. text))
			end
		end
	end
	table.sort(lines)
	return #lines > 0 and table.concat(lines, "\n") or "No currencies to show yet"
end

---------------------------------------------------------------------
-- Visuals
---------------------------------------------------------------------

local function getMusicSounds()
	local sounds = {}
	local folder = ReplicatedStorage:FindFirstChild("Background Music")
	if folder then
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("Sound") then
				table.insert(sounds, descendant)
			end
		end
	end
	return sounds
end

-- The game's music script fades volumes every frame, and puts them back once this stops.
local function muteStep()
	for _, sound in ipairs(getMusicSounds()) do
		sound.Volume = 0
	end
end

local BRIGHT_LIGHTING = {
	Ambient = Color3.fromRGB(180, 180, 180),
	OutdoorAmbient = Color3.fromRGB(180, 180, 180),
	Brightness = 2,
	ClockTime = 14,
	FogEnd = 100000,
	GlobalShadows = false,
}

local savedLighting

local function restoreLighting()
	if savedLighting then
		for property, value in pairs(savedLighting) do
			Lighting[property] = value
		end
		savedLighting = nil
	end
end

local function brightStep()
	if not savedLighting then
		savedLighting = {}
		for property in pairs(BRIGHT_LIGHTING) do
			savedLighting[property] = Lighting[property]
		end
	end
	for property, value in pairs(BRIGHT_LIGHTING) do
		Lighting[property] = value
	end
end

ctx:OnCleanup(restoreLighting)

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local FarmTab = ctx:SubTab("Farm", "Lucide:coins")

FarmTab:AddSection("Upgrades", "Lucide:arrow-up")
FarmTab:AddToggle({
	Text = "Auto Buy Upgrades",
	Description = "Keeps clicking upgrades that aren't maxed, and the game refuses what you can't afford",
	Icon = "Lucide:shopping-cart",
	Default = false,
	Flag = "dut_auto_buy",
	Locked = not fireclickdetector,
	Callback = function(value)
		Settings.AutoBuy = value
		if value then
			runLoop("Auto Buy Upgrades", function()
				return Settings.AutoBuy
			end, buyStep, function()
				return Settings.BuyInterval
			end)
		end
	end,
})
FarmTab:AddSlider({
	Text = "Buy Interval",
	Description = "Time between passes over the upgrade list",
	Icon = "Lucide:timer",
	Min = 0.5,
	Max = 10,
	Default = Settings.BuyInterval,
	Increment = 0.5,
	Suffix = "s",
	Flag = "dut_buy_interval",
	Callback = function(value)
		Settings.BuyInterval = value
	end,
})
local buyFilter = FarmTab:AddDropdown({
	Text = "Upgrade Filter",
	Description = "Only buys the selected upgrades. Select none to buy them all",
	Icon = "Lucide:list",
	Options = getUpgradeOptions(),
	MultiSelect = true,
	Default = {},
	Flag = false, -- Upgrades differ per zone, so a saved selection could match nothing
	Callback = function(value)
		Settings.BuyFilter = value
	end,
})

local selectedTeleport = getUpgradeOptions()[1] -- The dropdown starts on its first option
local teleportTarget = FarmTab:AddDropdown({
	Text = "Upgrade To Teleport To",
	Description = "The upgrade used by Teleport To Upgrade",
	Icon = "Lucide:map-pin",
	Options = getUpgradeOptions(),
	Flag = false,
	Callback = function(value)
		selectedTeleport = value
	end,
})
FarmTab:AddButton({
	Text = "Teleport To Upgrade",
	Description = "Moves you next to the selected upgrade",
	Icon = "Lucide:navigation",
	Callback = function()
		local upgrade = findUpgradeFromOption(selectedTeleport)
		local _, _, root = getCharacterParts()
		if upgrade and root then
			root.CFrame = upgrade.Main.CFrame * CFrame.new(0, 0, -6)
		else
			ctx.Notify("Pick an upgrade first.", "warning")
		end
	end,
})
FarmTab:AddButton({
	Text = "Refresh Upgrade Lists",
	Description = "Reloads both lists after the map changes",
	Icon = "Lucide:refresh-cw",
	Callback = function()
		local options = getUpgradeOptions()
		buyFilter:SetOptions(options)
		teleportTarget:SetOptions(options)
		Settings.BuyFilter = {}
		selectedTeleport = options[1]
	end,
})

FarmTab:AddSection("Rest", "Lucide:bed")
FarmTab:AddToggle({
	Text = "Auto Rest",
	Description = "Uses the bed on a timer, which resets progress the way resting normally does",
	Icon = "Lucide:bed",
	Default = false,
	Flag = "dut_auto_rest",
	Locked = not fireproximityprompt,
	Callback = function(value)
		Settings.AutoRest = value
		if value then
			runLoop("Auto Rest", function()
				return Settings.AutoRest
			end, restStep, function()
				return Settings.RestInterval
			end)
		end
	end,
})
FarmTab:AddSlider({
	Text = "Rest Interval",
	Description = "Time between rests",
	Icon = "Lucide:timer",
	Min = 5,
	Max = 300,
	Default = Settings.RestInterval,
	Increment = 5,
	Suffix = "s",
	Flag = "dut_rest_interval",
	Callback = function(value)
		Settings.RestInterval = value
	end,
})

local PlayerTab = ctx:SubTab("Player", "Lucide:user")

PlayerTab:AddSection("Protection", "Lucide:shield")
PlayerTab:AddToggle({
	Text = "God Mode",
	Description = "Stops hazards you touch from reporting damage to the server",
	Icon = "Lucide:shield",
	Default = false,
	Flag = "dut_god_mode",
	Callback = setGodMode,
})
PlayerTab:AddToggle({
	Text = "Bypass Anti-Clip",
	Description = "Stops the game snapping you back when you pass through walls",
	Icon = "Lucide:shield-off",
	Default = false,
	Flag = "dut_bypass_anticlip",
	Callback = function(value)
		Settings.BypassAntiClip = value
		updateAntiClipBypass()
	end,
})

PlayerTab:AddSection("Movement", "Lucide:gauge")
PlayerTab:AddToggle({
	Text = "Speed Boost",
	Description = "Sets your walking speed to the value below",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "dut_speed_boost",
	Callback = function(value)
		Settings.SpeedBoost = value
		if not value then
			restoreSpeed()
		end
	end,
})
PlayerTab:AddSlider({
	Text = "Walk Speed",
	Description = "Speed used while Speed Boost is on",
	Icon = "Lucide:gauge",
	Min = 16,
	Max = 200,
	Default = Settings.WalkSpeed,
	Increment = 1,
	Suffix = " studs",
	Flag = "dut_walk_speed",
	Callback = function(value)
		Settings.WalkSpeed = value
	end,
})
PlayerTab:AddToggle({
	Text = "Jump Boost",
	Description = "Sets your jump power to the value below",
	Icon = "Lucide:arrow-up",
	Default = false,
	Flag = "dut_jump_boost",
	Callback = function(value)
		Settings.JumpBoost = value
		if not value then
			restoreJump()
		end
	end,
})
PlayerTab:AddSlider({
	Text = "Jump Power",
	Description = "Power used while Jump Boost is on",
	Icon = "Lucide:gauge",
	Min = 50,
	Max = 300,
	Default = Settings.JumpPower,
	Increment = 5,
	Flag = "dut_jump_power",
	Callback = function(value)
		Settings.JumpPower = value
	end,
})
PlayerTab:AddToggle({
	Text = "Infinite Jump",
	Description = "Lets you jump again in mid-air",
	Icon = "Lucide:chevrons-up",
	Default = false,
	Flag = "dut_infinite_jump",
	Callback = function(value)
		Settings.InfiniteJump = value
	end,
})
PlayerTab:AddToggle({
	Text = "Noclip",
	Description = "Walks through walls and also turns on the anti-clip bypass",
	Icon = "Lucide:ghost",
	Default = false,
	Flag = "dut_noclip",
	Callback = function(value)
		Settings.Noclip = value
		if not value then
			restoreNoclip()
		end
		updateAntiClipBypass()
	end,
})
PlayerTab:AddToggle({
	Text = "Fly",
	Description = "Move normally, Space to rise and Left Ctrl to sink",
	Icon = "Lucide:plane",
	Default = false,
	Flag = "dut_fly",
	Callback = function(value)
		Settings.Fly = value
		updateAntiClipBypass()
	end,
})
PlayerTab:AddSlider({
	Text = "Fly Speed",
	Description = "Speed used while Fly is on",
	Icon = "Lucide:gauge",
	Min = 10,
	Max = 300,
	Default = Settings.FlySpeed,
	Increment = 5,
	Suffix = " studs",
	Flag = "dut_fly_speed",
	Callback = function(value)
		Settings.FlySpeed = value
	end,
})

local InfoTab = ctx:SubTab("Info", "Lucide:info")

InfoTab:AddSection("Currency", "Lucide:wallet")
local currencyPanel = InfoTab:AddParagraph({
	Title = "Currency",
	Icon = "Lucide:wallet",
	Text = "Loading",
})

InfoTab:AddSection("Upgrades", "Lucide:arrow-up")
local upgradeTable = InfoTab:AddTable({
	Title = "Upgrade List",
	Description = "Live level and price for this zone",
	Height = 260,
	RowHeight = 30,
	Columns = {
		{ Key = "id", Label = "ID", Weight = 0.7 },
		{ Key = "name", Label = "Upgrade", Weight = 1.6, Emphasized = true },
		{ Key = "level", Label = "Level", Weight = 0.6, Align = "Center" },
		{ Key = "price", Label = "Price", Weight = 1.6 },
	},
	Rows = getUpgradeRows(),
})

task.spawn(function()
	while ctx:Alive() do
		local okCurrency, text = pcall(getCurrencyText)
		if okCurrency then
			currencyPanel:Set(text)
		end
		local okRows, rows = pcall(getUpgradeRows)
		if okRows then
			upgradeTable:SetRows(rows)
		end
		task.wait(2)
	end
end)

local VisualsTab = ctx:SubTab("Visuals", "Lucide:eye")

VisualsTab:AddSection("Display", "Lucide:sun")
VisualsTab:AddToggle({
	Text = "Mute Music",
	Description = "Silences the zone music",
	Icon = "Lucide:volume-x",
	Default = false,
	Flag = "dut_mute_music",
	Callback = function(value)
		Settings.MuteMusic = value
		if value then
			runLoop("Mute Music", function()
				return Settings.MuteMusic
			end, muteStep, function()
				return 0.1
			end)
		end
	end,
})
VisualsTab:AddToggle({
	Text = "Full Bright",
	Description = "Keeps every zone fully lit",
	Icon = "Lucide:sun",
	Default = false,
	Flag = "dut_full_bright",
	Callback = function(value)
		Settings.FullBright = value
		if value then
			runLoop("Full Bright", function()
				return Settings.FullBright
			end, brightStep, function()
				return 0.5
			end)
		else
			restoreLighting()
		end
	end,
})
