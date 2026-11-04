-- Something Evil Will Happen
local ctx = ...
local task = ctx.task

local LOG_REMOVED = false -- EffectLogger: also print when an effect is removed
local DEFAULT_DURATION = 10 -- seconds, used when the duration box is empty. 0 = permanent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local EventHandler = require(ReplicatedStorage.Communication.EventHandler)
local StatusEffects = require(ReplicatedStorage.Resources.Information.StatusEffects)
local YourCharacter = require(ReplicatedStorage.Resources.Client.YourCharacter)
local Stamina = require(ReplicatedStorage.Resources.Client.MovementHandler.Stamina)

local EffectLogic = ReplicatedStorage.Resources.Client
	:WaitForChild("ClientStatusEffects")
	:WaitForChild("EffectLogic")

local function popup(text)
	task.spawn(function()
		EventHandler:FireSelf("DisplayPopup", "Saved", text)
	end)
end

----------------------------------------------------------------------
-- EffectLogger
----------------------------------------------------------------------
do
	local function onStatusEffect(effectName, applied)
		if not applied and not LOG_REMOVED then
			return
		end

		local effectInfo = StatusEffects.GetEffectInfo(effectName)
		local effectType = effectInfo and effectInfo.EffectType or "Unknown"

		ctx.Log(string.format(
			"[EffectLogger] %s: %s (%s)",
			applied and "Applied" or "Removed",
			tostring(effectName),
			effectType
		))
	end

	ctx:HookFunction(EventHandler.FireSelf, function(old, self, eventName, ...)
		if eventName == "OnStatusEffect" then
			local ok, err = pcall(onStatusEffect, ...)

			if not ok then
				ctx.Log("[EffectLogger] " .. tostring(err), "warn")
			end
		end

		return old(self, eventName, ...)
	end)
end

----------------------------------------------------------------------
-- Effect logic
----------------------------------------------------------------------
local active = {} -- [effectName] = { instance = effectInstance }

local function removeEffect(name)
	local entry = active[name]
	if not entry then
		return
	end

	active[name] = nil

	local instance = entry.instance
	if instance and instance.Wipe then
		pcall(instance.Wipe)
	end
end

local function applyEffect(name, duration)
	local logicModule = EffectLogic:FindFirstChild(name)
	if not logicModule then
		return false, "No client logic for " .. name
	end

	local character = YourCharacter.GetCharacter()
	if not character then
		return false, "No character"
	end

	-- Re-applying replaces the previous instance
	removeEffect(name)

	local effectInfo = StatusEffects.GetEffectInfo(name)
	local ok, instance = pcall(function()
		return require(logicModule)(character, effectInfo.Config or {})
	end)

	if not ok then
		return false, tostring(instance)
	end

	if instance then
		if instance.OnRefresh and duration > 0 then
			pcall(instance.OnRefresh, duration)
		end

		if instance.OnStack then
			pcall(instance.OnStack, 1)
		end
	end

	local entry = { instance = instance }
	active[name] = entry

	if duration > 0 then
		task.delay(duration, function()
			if active[name] == entry then
				removeEffect(name)
			end
		end)
	end

	return true
end

local function wipeAll()
	local names = {}
	for name in pairs(active) do
		table.insert(names, name)
	end

	for _, name in ipairs(names) do
		removeEffect(name)
	end

	return #names
end

----------------------------------------------------------------------
-- Fast regen / infinite stamina
----------------------------------------------------------------------
local TICK = 0.1
local fastRegen = false
local regenPerSecond = 10
local infStamina = false

-- Infinite Nimble: the effect is tied to the character it was created for, so re-apply it
-- permanently whenever the character changes (respawn) or the effect got removed.
local infNimble = false
local nimbleCharacter = nil

task.spawn(function()
	while ctx:Alive() do
		task.wait(0.5)

		if infNimble then
			local character = YourCharacter.GetCharacter()

			if character and (character ~= nimbleCharacter or not active.Nimble) then
				local ok = applyEffect("Nimble", 0)

				if ok then
					nimbleCharacter = character
				end
			end
		end
	end
end)

task.spawn(function()
	while ctx:Alive() do
		task.wait(TICK)

		if fastRegen then
			local character = Players.LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")

			if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
				humanoid.Health = math.min(humanoid.Health + regenPerSecond * TICK, humanoid.MaxHealth)
			end
		end

		if infStamina then
			pcall(Stamina.DrainStamina, -100, 0, true)
		end
	end
end)

----------------------------------------------------------------------
-- Aim assist (forced on for every device)
----------------------------------------------------------------------
local aimAssistOn = false
local aimRadius = 125
local aimStrength = 4

local AimAssist = require(
	ReplicatedStorage.Utilities:WaitForChild("GetMouseLocation"):WaitForChild("AimAssist")
)
local ControlScheme = require(ReplicatedStorage.Utilities.ControlScheme)

local originalRadius = AimAssist.snapRadius
local originalStrength = AimAssist.strength

-- GetMouseLocation disables aim assist when GetCurrentControl() == "PC".
-- Report a non-PC scheme, but only to GetMouseLocation so the rest of the game is unaffected.
do
	ctx:HookFunction(ControlScheme.GetCurrentControl, function(old, ...)
		local result = old(...)

		if aimAssistOn and result == "PC" then
			local ok, source = pcall(debug.info, 2, "s")

			if not ok or (type(source) == "string" and source:find("GetMouseLocation")) then
				return "Gamepad"
			end
		end

		return result
	end)
end

ctx:OnCleanup(function()
	AimAssist.snapRadius = originalRadius
	AimAssist.strength = originalStrength
	wipeAll()
end)

task.spawn(function()
	while ctx:Alive() do
		task.wait(0.1)

		if aimAssistOn then
			AimAssist.snapRadius = aimRadius
			AimAssist.strength = aimStrength
		end
	end
end)

----------------------------------------------------------------------
-- Give gear (client side only)
----------------------------------------------------------------------
local GearInfo = require(ReplicatedStorage.Resources.Information.Shop.Gear)

local gearEntries = {} -- [dropdown label] = { id, name, info }
local gearLabels = {}

do
	local sorted = {}
	for id, info in pairs(GearInfo.GetList()) do
		table.insert(sorted, { id = id, name = info.Name or id, info = info })
	end
	table.sort(sorted, function(a, b)
		return a.name:lower() < b.name:lower()
	end)

	for _, entry in ipairs(sorted) do
		local label = entry.name
		if gearEntries[label] then
			label = string.format("%s (%s)", entry.name, entry.id)
		end

		gearEntries[label] = entry
		table.insert(gearLabels, label)
	end
end

-- The real Tools live in ServerStorage, which clients can't read. Clone a copy if the client has
-- one somewhere (ReplicatedStorage / StarterPack), otherwise build a client-side Tool by name.
local function findToolTemplate(name)
	local roots = {
		ReplicatedStorage,
		game:GetService("StarterPack"),
		Players.LocalPlayer:FindFirstChild("StarterGear"),
	}

	for _, root in ipairs(roots) do
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("Tool") and descendant.Name == name then
				return descendant
			end
		end
	end
end

local function giveGear(entry)
	local backpack = Players.LocalPlayer:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "No backpack"
	end

	local template = findToolTemplate(entry.name) or findToolTemplate(entry.id)
	local tool

	if template then
		tool = template:Clone()
	else
		tool = Instance.new("Tool")
		tool.Name = entry.name
		tool.RequiresHandle = false
		tool.CanBeDropped = false
		tool.ToolTip = entry.info.Tooltip or ""
		tool.TextureId = entry.info.Icon or ""
	end

	-- Gearslot reads these: gear_id picks the info/icon/stats, Durability/MaxDurability drive the
	-- charge counter (0 durability shows the slot as disabled), Inf shows the infinity symbol.
	local durability = entry.info.ToolConfig and entry.info.ToolConfig.Durability or 1
	local infinite = durability < 0
	local maxDurability = infinite and 1 or math.max(durability, 1)

	if tool:GetAttribute("gear_id") == nil then
		ctx:SetAttribute(tool, "gear_id", entry.id)
	end

	if tool:GetAttribute("MaxDurability") == nil then
		ctx:SetAttribute(tool, "Durability", maxDurability)
		ctx:SetAttribute(tool, "MaxDurability", maxDurability)
		ctx:SetAttribute(tool, "Inf", infinite)
	end

	tool.Parent = backpack
	ctx:Track(tool)

	return true, template and "cloned" or "client-only"
end

----------------------------------------------------------------------
-- GUI (Vind UI)
----------------------------------------------------------------------
local function notify(title, text, kind)
	ctx.Notify(title .. " - " .. text, kind)
end

-- Effects tab ---------------------------------------------------------
local effectNames = {}
for name in pairs(StatusEffects.GetFullList()) do
	if EffectLogic:FindFirstChild(name) then
		table.insert(effectNames, name)
	end
end
table.sort(effectNames)

local selectedEffect = effectNames[1]

local Effects = ctx:SubTab("Effects", "Lucide:sparkles")
Effects:AddSection("Apply Effect", "Lucide:zap")

Effects:AddParagraph({
	Title = "Effects Warning",
	Icon = "Lucide:triangle-alert",
	Text = "Visual effects won't work but some effects may still be applied to your character."
})

Effects:AddDropdown({
	Text = "Effect",
	Icon = "Lucide:list",
	Options = effectNames,
	Default = selectedEffect,
	Callback = function(value)
		selectedEffect = value
	end,
})

local DurationBox = Effects:AddTextbox({
	Text = "Duration (Seconds)",
	Description = "How long the effect lasts, 0 for permanent",
	Icon = "Lucide:timer",
	Placeholder = "seconds",
	Default = tostring(DEFAULT_DURATION),
})

Effects:AddButton({
	Text = "Apply Effect",
	Icon = "Lucide:play",
	Callback = function()
		if not selectedEffect then
			return
		end

		local duration = math.max(tonumber(DurationBox:Get()) or DEFAULT_DURATION, 0)
		local ok, err = applyEffect(selectedEffect, duration)

		if ok then
			notify(
				"Applied " .. selectedEffect,
				duration > 0 and (duration .. " seconds") or "Permanent",
				"success"
			)
			popup(selectedEffect .. " Applied")
		else
			notify("Could not apply " .. selectedEffect, tostring(err), "error")
		end
	end,
})

Effects:AddDivider()

Effects:AddButton({
	Text = "Wipe Effects",
	Description = "Removes the effects applied from this panel",
	Icon = "Lucide:eraser",
	Callback = function()
		local count = wipeAll()
		notify("Effects wiped", count .. " effect(s) removed", "success")
		popup("Effects Wiped")
	end,
})

-- Player tab ----------------------------------------------------------
local Player = ctx:SubTab("Player", "Lucide:user")
Player:AddSection("Health & Stamina", "Lucide:heart")

Player:AddToggle({
	Text = "Fast Regen",
	Description = "Regenerates health over time",
	Icon = "Lucide:heart-pulse",
	Default = false,
	Callback = function(value)
		fastRegen = value
		popup(value and "Fast Regen Enabled" or "Fast Regen Disabled")
	end,
})

Player:AddSlider({
	Text = "Regen Speed",
	Description = "Health restored per second",
	Icon = "Lucide:gauge",
	Min = 1,
	Max = 200,
	Default = regenPerSecond,
	Increment = 1,
	Suffix = " HP/s",
	Callback = function(value)
		regenPerSecond = value
	end,
})

Player:AddLabel("High regen rates may not work correctly.")

Player:AddToggle({
	Text = "Infinite Stamina",
	Description = "Keeps your stamina full",
	Icon = "Lucide:zap",
	Default = false,
	Callback = function(value)
		infStamina = value
		popup(value and "Infinite Stamina Enabled" or "Infinite Stamina Disabled")
	end,
})

Player:AddToggle({
	Text = "Infinite Nimble",
	Description = "Keeps Nimble applied, including after you respawn",
	Icon = "Lucide:wind",
	Default = false,
	Callback = function(value)
		infNimble = value
		nimbleCharacter = nil

		if not value then
			removeEffect("Nimble")
		end

		popup(value and "Infinite Nimble Enabled" or "Infinite Nimble Disabled")
	end,
})

Player:AddSection("Aim Assist", "Lucide:crosshair")

Player:AddToggle({
	Text = "Aim Assist (Any Device)",
	Description = "Forces aim assist on, even on PC",
	Icon = "Lucide:crosshair",
	Default = false,
	Callback = function(value)
		aimAssistOn = value

		if not value then
			AimAssist.snapRadius = originalRadius
			AimAssist.strength = originalStrength
		end

		popup(value and "Aim Assist Enabled" or "Aim Assist Disabled")
	end,
})

Player:AddSlider({
	Text = "Snap Radius",
	Min = 0,
	Max = 500,
	Default = aimRadius,
	Increment = 5,
	Callback = function(value)
		aimRadius = value
	end,
})

Player:AddSlider({
	Text = "Strength",
	Min = 0,
	Max = 25,
	Default = aimStrength,
	Increment = 0.5,
	Callback = function(value)
		aimStrength = value
	end,
})

-- Gear tab ------------------------------------------------------------
local selectedGear = gearEntries[gearLabels[1]]

local Gear = ctx:SubTab("Items", "Lucide:package")
Gear:AddSection("Give Gear", "Lucide:package")

Gear:AddParagraph({
	Title = "Client Side Only",
	Icon = "Lucide:monitor",
	Text = "Gear is only created on your client. It shows up in your hotbar, but its "
		.. "abilities run on the server and will not work.",
})

Gear:AddDropdown({
	Text = "Gear",
	Icon = "Lucide:list",
	Options = gearLabels,
	Default = gearLabels[1],
	Callback = function(value)
		selectedGear = gearEntries[value]
	end,
})

Gear:AddButton({
	Text = "Give Gear",
	Icon = "Lucide:gift",
	Callback = function()
		if not selectedGear then
			return
		end

		local ok, result = giveGear(selectedGear)

		if ok then
			notify("Gave " .. selectedGear.name, result, "success")
		else
			notify("Could not give " .. selectedGear.name, tostring(result), "error")
		end
	end,
})
