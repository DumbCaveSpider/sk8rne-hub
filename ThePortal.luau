-- The Portal
local ctx = ...
local task = ctx.task

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local TICK = 0.25
local HARVEST_RANGE = 10 -- Assumed: the game's harvest range is not in the dumps
local PICKUP_RETRY_SECONDS = 2
local WATER_RETRY_SECONDS = 5
local CLAIM_RETRY_SECONDS = 15

---------------------------------------------------------------------
-- Game modules
---------------------------------------------------------------------

local Core = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Core")
local Constants = require(Core:WaitForChild("Constants"))
local GatherNodes = require(Core:WaitForChild("GatherNodes"))
local Utility = require(Core:WaitForChild("Utility"))

local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")

-- Same lookup the game's own controllers use. Returns nil if a controller is missing.
local function getController(name)
	local module = Client:FindFirstChild(name, true)
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, module)
	return ok and result or nil
end

local Combat = getController("CombatController")
local Network = getController("NetworkController")
local Gathering = getController("GatheringController")
local TrashDig = getController("TrashDigController")
local Fishing = getController("FishingController")
local Farm = getController("FarmController")
local Sprint = getController("SprintController")
local Mount = getController("MountController")
local Smelter = getController("SmelterController")
local Processing = getController("ProcessingController")
local Sheathe = getController("SheatheController")

for name, controller in pairs({
	SheatheController = Sheathe,
	SprintController = Sprint,
	MountController = Mount,
	SmelterController = Smelter,
	ProcessingController = Processing,
	CombatController = Combat,
	NetworkController = Network,
	GatheringController = Gathering,
	TrashDigController = TrashDig,
	FishingController = Fishing,
	FarmController = Farm,
}) do
	if not controller then
		ctx.Log(name .. " was not found, so its features won't work", "warn")
	end
end

local EntityIdAttribute = Constants.Entity.EntityIdAttribute
local CombatNPCAttribute = Constants.NPCCombat.CombatNPCAttribute
local NPCFolderName = Constants.NPC.FolderName
local Farming = Constants.Farming
local GatherConfig = Constants.Gathering
local FishConfig = Constants.Fishing
local DigConfig = Constants.Quest.TrashDig
local InteractionConfig = Constants.Interaction
local ReservedAttribute = Constants.WorldItem.ReservedAttribute
local OwnerIdAttribute = Constants.Tycoon.Placement.OwnerIdAttribute
local PlotIdAttribute = Constants.Tycoon.Placement.PlotIdAttribute
local DeadAttribute = Constants.Entity.DeadAttribute

---------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------

local Settings = {
	AutoDraw = false,
	AutoAttack = false,
	AttackRange = 12,
	HitAllNearby = false,
	HitRadius = 15,
	AutoGather = false,
	AutoDig = false,
	AutoFish = false,
	AutoLoot = false,
	AutoHarvest = false,
	AutoWater = false,
	SpeedBoost = false,
	WalkSpeed = 30,
	AutoClaim = false,
	MonsterEsp = false,
	EspDistance = 500,
}

local function getRootPart()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function isUnsheathed()
	local character = LocalPlayer.Character
	return character ~= nil and character:GetAttribute("IsUnsheathed") == true
end

local function getEquippedTool()
	local character = LocalPlayer.Character
	local toolId = character and character:GetAttribute("EquippedRightHand")
	if type(toolId) == "string" and toolId ~= "" then
		return toolId
	end
	return nil
end

-- Runs step every interval while enabled() is true. Errors are logged once per message.
local function runLoop(label, enabled, step, interval)
	task.spawn(function()
		local lastError
		while ctx:Alive() and enabled() do
			local ok, err = pcall(step)
			if not ok and err ~= lastError then
				lastError = err
				ctx.Log(label .. ": " .. tostring(err), "error")
			end
			task.wait(interval or TICK)
		end
	end)
end

---------------------------------------------------------------------
-- Combat
---------------------------------------------------------------------

-- Mobs and combat NPCs only, matching the game's own target list without its player branch.
local function forEachEnemy(callback)
	local mobs = workspace:FindFirstChild("Mobs")
	local active = mobs and mobs:FindFirstChild("Active")
	if active then
		for _, model in ipairs(active:GetChildren()) do
			callback(model)
		end
	end
	local npcs = workspace:FindFirstChild(NPCFolderName)
	if npcs then
		for _, model in ipairs(npcs:GetChildren()) do
			if model:GetAttribute(CombatNPCAttribute) then
				callback(model)
			end
		end
	end
end

local function getEnemiesInRange(origin, range)
	local found = {}
	forEachEnemy(function(model)
		local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and (root.Position - origin).Magnitude <= range then
			table.insert(found, model)
		end
	end)
	return found
end

-- Same call as the game's sheathe key, which refuses while mounted, carrying or swimming.
local function drawStep()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and not Sheathe:IsArmed() and not Sheathe.IsTransitioning() then
		Sheathe:ToggleArmed()
	end
end

local function attackStep()
	local root = getRootPart()
	if not (root and Combat and Combat:IsArmed()) then
		return
	end
	if #getEnemiesInRange(root.Position, Settings.AttackRange) > 0 then
		Combat.HandlePrimaryAction()
		task.wait(0.05)
		Combat.HandlePrimaryRelease()
	end
end

-- Adds nearby enemies to the hit list of each real swing, so cooldowns and animations still apply.
local originalMeleeHits = Network and Network.RequestMeleeHits

if originalMeleeHits then
	Network.RequestMeleeHits = function(self, rightTargets, leftTargets)
		local root = Settings.HitAllNearby and getRootPart()
		if root then
			local targets = table.clone(rightTargets or {})
			local seen = {}
			for _, id in ipairs(targets) do
				seen[id] = true
			end
			for _, model in ipairs(getEnemiesInRange(root.Position, Settings.HitRadius)) do
				local id = model:GetAttribute(EntityIdAttribute)
				if type(id) == "string" and id ~= "" and not seen[id] then
					seen[id] = true
					table.insert(targets, id)
				end
			end
			rightTargets = targets
		end
		return originalMeleeHits(self, rightTargets, leftTargets)
	end

	ctx:OnCleanup(function()
		Network.RequestMeleeHits = originalMeleeHits
	end)
end

---------------------------------------------------------------------
-- Gathering, digging and fishing
---------------------------------------------------------------------

local function gatherStep()
	local root = getRootPart()
	local toolId = getEquippedTool()
	if not (root and toolId and isUnsheathed() and Gathering) or Gathering.IsGathering() then
		return
	end
	local toolConfig = Farming.ToolConfig and Farming.ToolConfig[toolId]
	local tag = toolConfig and GatherConfig.ToolToTag[toolConfig.ToolType]
	if not tag then
		return
	end
	local node = GatherNodes.FindClosest(root.Position, tag, toolId, GatherConfig.GatherInteractRange)
	if node then
		Gathering.PlayGatherSingle(node)
	end
end

local function digStep()
	local root = getRootPart()
	local toolId = getEquippedTool()
	if not (root and toolId and isUnsheathed() and TrashDig) then
		return
	end
	local toolConfig = Farming.ToolConfig and Farming.ToolConfig[toolId]
	if not toolConfig or toolConfig.ToolType ~= DigConfig.ToolType then
		return
	end
	local closest, closestDistance = nil, DigConfig.InteractRange
	for _, part in ipairs(CollectionService:GetTagged(DigConfig.Tag)) do
		if
			part:IsA("BasePart")
			and type(part:GetAttribute(DigConfig.IdAttribute)) == "string"
			and part:GetAttribute(DigConfig.OpenUntilAttribute) == nil
		then
			local distance = (root.Position - part.Position).Magnitude
			if distance <= closestDistance then
				closest, closestDistance = part, distance
			end
		end
	end
	if closest then
		TrashDig.PlayDig(closest)
	end
end

local function distanceToBox(position, part)
	local half = part.Size * 0.5
	local localPoint = part.CFrame:PointToObjectSpace(position)
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (position - part.CFrame:PointToWorldSpace(clamped)).Magnitude
end

local startedFishing = false

local function fishStep()
	local root = getRootPart()
	local toolId = getEquippedTool()
	if not (root and toolId and isUnsheathed() and Fishing) or Fishing.IsFishing() then
		return
	end
	if Utility.Tool.GetToolType(toolId) ~= FishConfig.RequiredToolType then
		return
	end
	local closest, closestDistance = nil, FishConfig.InteractRange or 10
	for _, part in ipairs(CollectionService:GetTagged(FishConfig.FishingZoneTag)) do
		if part:IsA("BasePart") and part:IsDescendantOf(workspace) then
			local distance = distanceToBox(root.Position, part)
			if distance <= closestDistance then
				closest, closestDistance = part, distance
			end
		end
	end
	if closest then
		startedFishing = true
		Fishing.StartAutoFish(closest)
	end
end

---------------------------------------------------------------------
-- Loot and crops
---------------------------------------------------------------------

local lastPickupTry = {}

local function lootStep()
	local root = getRootPart()
	local folder = workspace:FindFirstChild(InteractionConfig.WorldItemsFolderName)
	if not (root and folder and Network) then
		return
	end
	local character = LocalPlayer.Character
	local myEntityId = character and character:GetAttribute(EntityIdAttribute)
	local range = InteractionConfig.LootRange or 10
	local now = os.clock()

	for _, item in ipairs(folder:GetChildren()) do
		local pickupId = item:GetAttribute("PickupId")
		if
			item:IsA("Model")
			and pickupId
			and item:GetAttribute("ItemId")
			and not item:GetAttribute(ReservedAttribute)
			and now - (lastPickupTry[pickupId] or 0) >= PICKUP_RETRY_SECONDS
		then
			-- Same ownership rule the game applies: someone else's drop needs a shared party.
			local owner = item:GetAttribute(OwnerIdAttribute)
			local partyId = item:GetAttribute("PartyId")
			local allowed = not owner or owner == myEntityId or (partyId and partyId ~= "")
			local distance = Utility.Drop.DistanceTo(root.Position, item)
			if allowed and distance and distance <= range then
				lastPickupTry[pickupId] = now
				Network:RequestPickupItem(pickupId)
			end
		end
	end
end

local function harvestStep()
	local root = getRootPart()
	local character = LocalPlayer.Character
	local myPlot = character and character:GetAttribute(PlotIdAttribute)
	if not (root and myPlot and Farm) or Farm.IsBusy() then
		return
	end
	for _, soil in ipairs(CollectionService:GetTagged(Farming.SoilTag)) do
		if
			soil:IsA("Model")
			and soil.Parent
			and soil:GetAttribute(PlotIdAttribute) == myPlot
			and (soil:GetAttribute("Phase") or 0) ~= 5
			and (soil:GetAttribute("GrowthProgress") or 0) >= 100
			and (soil:GetAttribute("FruitProgress") or 0) >= 100
			and (soil:GetAttribute("RemainingYield") or 0) > 0
			and (root.Position - soil:GetPivot().Position).Magnitude <= HARVEST_RANGE
		then
			local soilId = soil:GetAttribute("SoilId")
			if soilId then
				Farm.PlayHarvestSingleAction(soilId)
				return
			end
		end
	end
end

local lastWaterTry = {}

local function waterStep()
	local root = getRootPart()
	local character = LocalPlayer.Character
	local myPlot = character and character:GetAttribute(PlotIdAttribute)
	if not (root and myPlot and Farm) or Farm.IsBusy() or Farm.GetActiveTool() ~= "WateringCan" then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	folder = folder and folder:FindFirstChild(Farming.RemoteFolder)
	local remote = folder and folder:FindFirstChild(Farming.Remotes.RequestWater)
	if not remote then
		return
	end
	local now = os.clock()
	for _, soil in ipairs(CollectionService:GetTagged(Farming.SoilTag)) do
		local soilId = soil:IsA("Model") and soil:GetAttribute("SoilId")
		local seedId = soilId and soil:GetAttribute("SeedId")
		if
			seedId
			and seedId ~= ""
			and soil:GetAttribute(PlotIdAttribute) == myPlot
			and not soil:GetAttribute("Watered")
			and now - (lastWaterTry[soilId] or 0) >= WATER_RETRY_SECONDS
			and (root.Position - soil:GetPivot().Position).Magnitude <= HARVEST_RANGE
		then
			lastWaterTry[soilId] = now
			remote:FireServer({ SoilId = soilId })
			return
		end
	end
end

local function openNearestMachine(controller, label)
	local root = getRootPart()
	local entries = root and controller and controller.ScanInteractables(root.Position, math.huge)
	if entries and entries[1] then
		controller.Trigger(entries[1])
	else
		ctx.Notify("No " .. label .. " of yours in range.", "warning")
	end
end

---------------------------------------------------------------------
-- Player
---------------------------------------------------------------------

local SPEED_KEY = "sk8rne_speed"

-- The game's override system: stuns, cutscenes and higher-priority overrides still take precedence.
local function applySpeed()
	if Sprint then
		Sprint.SetMoveSpeedOverride(Settings.SpeedBoost and Settings.WalkSpeed or nil, SPEED_KEY)
	end
end

ctx:OnCleanup(function()
	if Sprint then
		Sprint.SetMoveSpeedOverride(nil, SPEED_KEY)
	end
end)

---------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------

local QuestConfig = Constants.Quest
local pendingRewards = {}
local lastClaimTry = {}

if Network and Network.OnQuestBookSync then
	ctx:Connect(Network.OnQuestBookSync, function(book)
		pendingRewards = (book and book.Quests and book.Quests.PendingRewards) or {}
	end)
end

local function getQuestRemote(name)
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	folder = folder and folder:FindFirstChild("Quest")
	return folder and name and folder:FindFirstChild(name)
end

local function claimStep()
	local syncRemote = getQuestRemote(QuestConfig.RequestQuestBookSyncRemote)
	if syncRemote then
		syncRemote:FireServer()
	end
	-- Gives the sync reply time to arrive before the rewards are read.
	task.wait(1)
	local claimRemote = getQuestRemote(QuestConfig.RequestClaimMainRewardRemote)
	if not (claimRemote and Settings.AutoClaim) then
		return
	end
	local now = os.clock()
	for questId in pairs(pendingRewards) do
		if now - (lastClaimTry[questId] or 0) >= CLAIM_RETRY_SECONDS then
			lastClaimTry[questId] = now
			claimRemote:FireServer({ QuestId = questId })
		end
	end
end

---------------------------------------------------------------------
-- Visuals
---------------------------------------------------------------------

local espFolder = ctx:Track(Instance.new("Folder"))
espFolder.Name = "Sk8rnePortalEsp"
espFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local espEntries = {}

local function removeEsp(model)
	local entry = espEntries[model]
	if entry then
		entry.Gui:Destroy()
		espEntries[model] = nil
	end
end

local function clearEsp()
	for model in pairs(espEntries) do
		removeEsp(model)
	end
end

local function createEsp(model, root)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 36)
	gui.StudsOffset = Vector3.new(0, 3.5, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = root
	gui.Parent = espFolder

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(255, 96, 96)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui

	local entry = { Gui = gui, Label = label }
	espEntries[model] = entry
	return entry
end

local function espStep()
	local myRoot = getRootPart()
	if not myRoot then
		return
	end
	local visible = {}
	forEachEnemy(function(model)
		local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid and humanoid.Health > 0) or model:GetAttribute(DeadAttribute) then
			return
		end
		local distance = (root.Position - myRoot.Position).Magnitude
		if distance <= Settings.EspDistance then
			visible[model] = true
			local entry = espEntries[model] or createEsp(model, root)
			entry.Gui.Adornee = root
			entry.Label.Text = string.format(
				"%s\n%d/%d HP  %d studs",
				model.Name,
				math.floor(humanoid.Health),
				math.floor(humanoid.MaxHealth),
				math.floor(distance)
			)
		end
	end)
	for model in pairs(espEntries) do
		if not visible[model] then
			removeEsp(model)
		end
	end
end

local function getBossTimerText()
	local config = Constants.BossRespawnTimer
	local folder = config and ReplicatedStorage:FindFirstChild(config.FolderName)
	if not folder then
		return "No boss timers right now"
	end
	local lines = {}
	for _, marker in ipairs(folder:GetChildren()) do
		local respawnAt = marker:GetAttribute(config.RespawnAtAttribute)
		if type(respawnAt) == "number" then
			local remaining = math.max(0, math.floor(respawnAt - workspace:GetServerTimeNow()))
			table.insert(lines, string.format("%s: %02d:%02d", marker.Name, math.floor(remaining / 60), remaining % 60))
		end
	end
	table.sort(lines)
	return #lines > 0 and table.concat(lines, "\n") or "No boss timers right now"
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local CombatTab = ctx:SubTab("Combat", "Lucide:swords")

CombatTab:AddSection("Attacking", "Lucide:sword")
CombatTab:AddToggle({
	Text = "Auto Draw Weapon",
	Description = "Draws your weapon or tool whenever it is put away",
	Icon = "Lucide:sword",
	Default = false,
	Flag = "portal_auto_draw",
	Locked = not Sheathe,
	Callback = function(value)
		Settings.AutoDraw = value
		if value then
			runLoop("Auto Draw Weapon", function()
				return Settings.AutoDraw
			end, drawStep, 3)
		end
	end,
})
CombatTab:AddToggle({
	Text = "Auto Attack",
	Description = "Swings while an enemy is in range and your weapon is drawn",
	Icon = "Lucide:swords",
	Default = false,
	Flag = "portal_auto_attack",
	Locked = not Combat,
	Callback = function(value)
		Settings.AutoAttack = value
		if value then
			runLoop("Auto Attack", function()
				return Settings.AutoAttack
			end, attackStep, 0.1)
		end
	end,
})
CombatTab:AddSlider({
	Text = "Attack Range",
	Description = "How close an enemy must be before Auto Attack swings",
	Icon = "Lucide:target",
	Min = 5,
	Max = 30,
	Default = Settings.AttackRange,
	Increment = 1,
	Suffix = " studs",
	Flag = "portal_attack_range",
	Callback = function(value)
		Settings.AttackRange = value
	end,
})

CombatTab:AddSection("Hit Area", "Lucide:radius")
CombatTab:AddToggle({
	Text = "Hit All Nearby",
	Description = "Each melee swing also reports nearby enemies as hit, never players",
	Icon = "Lucide:radius",
	Default = false,
	Flag = "portal_hit_all_nearby",
	Locked = not originalMeleeHits,
	Callback = function(value)
		Settings.HitAllNearby = value
	end,
})
CombatTab:AddSlider({
	Text = "Hit Radius",
	Description = "How far Hit All Nearby reaches from your character",
	Icon = "Lucide:target",
	Min = 5,
	Max = 30,
	Default = Settings.HitRadius,
	Increment = 1,
	Suffix = " studs",
	Flag = "portal_hit_radius",
	Callback = function(value)
		Settings.HitRadius = value
	end,
})

local FarmTab = ctx:SubTab("Farm", "Lucide:coins")

FarmTab:AddSection("Gathering", "Lucide:pickaxe")
FarmTab:AddToggle({
	Text = "Auto Gather",
	Description = "Gathers the nearest node your equipped tool can use",
	Icon = "Lucide:pickaxe",
	Default = false,
	Flag = "portal_auto_gather",
	Locked = not Gathering,
	Callback = function(value)
		Settings.AutoGather = value
		if value then
			runLoop("Auto Gather", function()
				return Settings.AutoGather
			end, gatherStep)
		elseif Gathering and Gathering.IsGathering() then
			Gathering.StopGather()
		end
	end,
})
FarmTab:AddToggle({
	Text = "Auto Dig",
	Description = "Digs the nearest trash pile while your digging tool is drawn",
	Icon = "Lucide:shovel",
	Default = false,
	Flag = "portal_auto_dig",
	Locked = not TrashDig,
	Callback = function(value)
		Settings.AutoDig = value
		if value then
			runLoop("Auto Dig", function()
				return Settings.AutoDig
			end, digStep, 1)
		end
	end,
})
FarmTab:AddToggle({
	Text = "Auto Fish",
	Description = "Starts the game's auto fishing at the nearest water with your rod drawn",
	Icon = "Lucide:fish",
	Default = false,
	Flag = "portal_auto_fish",
	Locked = not Fishing,
	Callback = function(value)
		Settings.AutoFish = value
		if value then
			runLoop("Auto Fish", function()
				return Settings.AutoFish
			end, fishStep, 1)
		elseif startedFishing and Fishing then
			startedFishing = false
			if Fishing.IsFishing() then
				Fishing.StopFishing()
			end
		end
	end,
})

FarmTab:AddSection("Collecting", "Lucide:package")
FarmTab:AddToggle({
	Text = "Auto Loot",
	Description = "Picks up drops within loot range that you are allowed to take",
	Icon = "Lucide:hand",
	Default = false,
	Flag = "portal_auto_loot",
	Locked = not Network,
	Callback = function(value)
		Settings.AutoLoot = value
		if value then
			runLoop("Auto Loot", function()
				return Settings.AutoLoot
			end, lootStep)
		end
	end,
})
FarmTab:AddToggle({
	Text = "Auto Harvest",
	Description = "Harvests ripe crops near you on your own plot",
	Icon = "Lucide:wheat",
	Default = false,
	Flag = "portal_auto_harvest",
	Locked = not Farm,
	Callback = function(value)
		Settings.AutoHarvest = value
		if value then
			runLoop("Auto Harvest", function()
				return Settings.AutoHarvest
			end, harvestStep, 0.5)
		end
	end,
})
FarmTab:AddToggle({
	Text = "Auto Water",
	Description = "Waters thirsty crops near you on your plot while holding a watering can",
	Icon = "Lucide:droplets",
	Default = false,
	Flag = "portal_auto_water",
	Locked = not Farm,
	Callback = function(value)
		Settings.AutoWater = value
		if value then
			runLoop("Auto Water", function()
				return Settings.AutoWater
			end, waterStep, 1)
		end
	end,
})

FarmTab:AddSection("Tycoon", "Lucide:factory")
FarmTab:AddButton({
	Text = "Open Nearest Smelter",
	Description = "Opens the panel of your closest smelter in range",
	Icon = "Lucide:flame",
	Callback = function()
		openNearestMachine(Smelter, "smelter")
	end,
})
FarmTab:AddButton({
	Text = "Open Nearest Processor",
	Description = "Opens the panel of your closest processing machine in range",
	Icon = "Lucide:cog",
	Callback = function()
		openNearestMachine(Processing, "processor")
	end,
})

local PlayerTab = ctx:SubTab("Player", "Lucide:user")

PlayerTab:AddSection("Movement", "Lucide:gauge")
PlayerTab:AddToggle({
	Text = "Speed Boost",
	Description = "Sets your walking speed to the value below",
	Icon = "Lucide:rabbit",
	Default = false,
	Flag = "portal_speed_boost",
	Locked = not Sprint,
	Callback = function(value)
		Settings.SpeedBoost = value
		applySpeed()
	end,
})
PlayerTab:AddSlider({
	Text = "Walk Speed",
	Description = "Speed used while Speed Boost is on",
	Icon = "Lucide:gauge",
	Min = 16,
	Max = 100,
	Default = Settings.WalkSpeed,
	Increment = 1,
	Suffix = " studs",
	Flag = "portal_walk_speed",
	Callback = function(value)
		Settings.WalkSpeed = value
		applySpeed()
	end,
})
PlayerTab:AddButton({
	Text = "Summon Mount",
	Description = "Summons or dismisses your mount",
	Icon = "Lucide:rocket",
	Callback = function()
		if Mount then
			Mount.ToggleSummon()
		else
			ctx.Notify("The mount controller wasn't found.", "error")
		end
	end,
})

local QuestsTab = ctx:SubTab("Quests", "Lucide:scroll-text")

QuestsTab:AddSection("Rewards", "Lucide:gift")
QuestsTab:AddToggle({
	Text = "Auto Claim Rewards",
	Description = "Claims finished main and side quest rewards",
	Icon = "Lucide:gift",
	Default = false,
	Flag = "portal_auto_claim",
	Locked = not Network,
	Callback = function(value)
		Settings.AutoClaim = value
		if value then
			runLoop("Auto Claim Rewards", function()
				return Settings.AutoClaim
			end, claimStep, 15)
		end
	end,
})

local VisualsTab = ctx:SubTab("Visuals", "Lucide:eye")

VisualsTab:AddSection("Monster ESP", "Lucide:skull")
VisualsTab:AddToggle({
	Text = "Monster ESP",
	Description = "Shows each monster's name, health and distance through walls",
	Icon = "Lucide:eye",
	Default = false,
	Flag = "portal_monster_esp",
	Callback = function(value)
		Settings.MonsterEsp = value
		if value then
			runLoop("Monster ESP", function()
				return Settings.MonsterEsp
			end, espStep)
		else
			clearEsp()
		end
	end,
})
VisualsTab:AddSlider({
	Text = "ESP Distance",
	Description = "Monsters farther away than this are not shown",
	Icon = "Lucide:radar",
	Min = 50,
	Max = 2000,
	Default = Settings.EspDistance,
	Increment = 50,
	Suffix = " studs",
	Flag = "portal_esp_distance",
	Callback = function(value)
		Settings.EspDistance = value
	end,
})

VisualsTab:AddSection("Bosses", "Lucide:timer")
local bossTimers = VisualsTab:AddParagraph({
	Title = "Boss Respawns",
	Icon = "Lucide:timer",
	Text = "No boss timers right now",
})

task.spawn(function()
	while ctx:Alive() do
		local ok, text = pcall(getBossTimerText)
		if ok then
			bossTimers:Set(text)
		end
		task.wait(1)
	end
end)
