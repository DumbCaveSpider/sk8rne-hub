-- Criminal Simulator
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local ProximityPromptService = game:GetService("ProximityPromptService")

if not game:IsLoaded() then game.Loaded:Wait() end
while not Players.LocalPlayer do task.wait(0.1) end
local LocalPlayer = Players.LocalPlayer

-- Remotes, as used by the game's LootClient / PunchClient / SprintClient
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LootGrab = Remotes:WaitForChild("LootGrab")
local LootRelease = Remotes:WaitForChild("LootRelease")
local Hotbar = Remotes:WaitForChild("Hotbar")
local Punch = Remotes:WaitForChild("Punch")
local Sneak = Remotes:WaitForChild("Sneak")
local Breathing = Remotes:WaitForChild("Breathing")

local Settings = {
	ShowLabels = true,
	ShowDistance = true,
	EspMaxDistance = 500,

	SilentWalk = false,
	InfiniteStamina = false,
	AutoCollect = false,
	CollectRadius = 12,
	AutoDrop = false,
	AutoPunch = false,
	PunchPolice = false,
	PunchRange = 9, -- PunchClient aims with MeleeAim.target(9, ...)

	AutoFarm = false,
	VerboseLogs = true,
	GrabDelay = 0.6, -- seconds between teleporting to an item and grabbing it
	GrabAttempts = 3,
	MoveSpeed = 30, -- studs/second when gliding along a route
	GlideMovement = true, -- on: glide along the route (through doors); off: really walk it
	GlideAtRunSpeed = true, -- glide as fast as you could run (times GlideSpeedPercent); off: MoveSpeed
	GlideSpeedPercent = 85, -- % of run speed: a margin under what the server allows
	AvoidGuards = true, -- skip loot a guard is standing near, and back off when security spots you
	GuardRadius = 35, -- studs around a guard that count as "near"
	NoclipWhenStuck = true, -- a move that got pushed back retries gliding with noclip
	AlwaysNoclip = true, -- noclip on every glide: routes avoid walls and only cross doors and glass
	MinLootValue = 1, -- the farm only collects loot worth at least this much ($)
	LeaveOnAlarm = true, -- when someone calls the cops, stop collecting and head home
}

local farmLog -- defined in the Auto Farm section; the loot helpers above it log through it too

-- Each ESP category: where its targets live and the color they're drawn in.
-- `path` is walked from workspace each scan, so folders that load late are picked up.
local Categories = {
	{ Key = "Guards", Name = "Guards", Path = { "Guards" }, Color = Color3.fromRGB(255, 60, 60) },
	{ Key = "Npcs", Name = "Residents", Path = { "Npcs" }, Color = Color3.fromRGB(255, 255, 255) },
	{ Key = "Police", Name = "Police", Path = { "Police" }, Color = Color3.fromRGB(60, 130, 255) },
	{ Key = "Loot", Name = "Loot", Path = { "Loot" }, Color = Color3.fromRGB(255, 220, 0) },
	{ Key = "DropCrates", Name = "Drop Crates", Path = { "Town", "DropCrates" }, Color = Color3.fromRGB(255, 140, 0) },
	{ Key = "Atms", Name = "ATMs", Path = { "Town", "Atms" }, Color = Color3.fromRGB(80, 255, 80) },
	{ Key = "Cars", Name = "Cars", Path = { "Town", "Cars" }, Color = Color3.fromRGB(200, 90, 255) },
}

local EspFolder = Instance.new("Folder")
EspFolder.Name = "CriminalESP"
EspFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")
ctx:Track(EspFolder) -- destroyed at shutdown, which also ends every loop below that runs while it exists

-- Per category: [target] = { Highlight = ..., Billboard = ... }
local EspObjects = {}
for _, category in Categories do
	category.Enabled = false
	EspObjects[category.Key] = {}
end

local function getFolder(path)
	local current = workspace
	for _, name in path do
		current = current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function getMyRoot()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- A BillboardGui needs a BasePart (or Attachment) to sit on
local function getRootPart(target)
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		return target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
			or target:FindFirstChildWhichIsA("BasePart", true)
	end
	return target:FindFirstChildWhichIsA("BasePart", true)
end

local function getLabelText(target)
	local value = target:GetAttribute("Value")
	if value and value > 0 then
		return ("%s ($%d)"):format(target:GetAttribute("DisplayName") or target.Name, value)
	end
	return target:GetAttribute("DisplayName") or target.Name
end

--------------------------------------------------------------------------------
-- ESP
--------------------------------------------------------------------------------

local function destroyEntry(entry)
	entry.Highlight:Destroy()
	entry.Billboard:Destroy()
end

local function createEntry(target, color)
	local highlight = Instance.new("Highlight")
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 0.6
	highlight.OutlineTransparency = 0
	highlight.Adornee = target
	highlight.Parent = EspFolder

	local billboard = Instance.new("BillboardGui")
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(200, 32)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.Parent = EspFolder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 16)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextStrokeTransparency = 0.3
	label.TextColor3 = color
	label.Parent = billboard

	local distance = Instance.new("TextLabel")
	distance.Name = "Distance"
	distance.BackgroundTransparency = 1
	distance.Position = UDim2.fromOffset(0, 16)
	distance.Size = UDim2.new(1, 0, 0, 14)
	distance.Font = Enum.Font.GothamMedium
	distance.TextSize = 11
	distance.TextStrokeTransparency = 0.3
	distance.TextColor3 = Color3.fromRGB(220, 220, 220)
	distance.Parent = billboard

	return { Highlight = highlight, Billboard = billboard }
end

local function clearCategory(category)
	local objects = EspObjects[category.Key]
	for target, entry in objects do
		destroyEntry(entry)
		objects[target] = nil
	end
end

local function updateCategory(category, myRoot)
	local objects = EspObjects[category.Key]
	local folder = getFolder(category.Path)
	local seen = {}

	for _, target in folder and folder:GetChildren() or {} do
		local root = getRootPart(target)
		local distance = root and myRoot and (root.Position - myRoot.Position).Magnitude
		-- Targets past the max distance get no ESP at all, which also keeps Highlights under Roblox's ~31 cap
		if root and (not distance or distance <= Settings.EspMaxDistance) then
			seen[target] = true
			local entry = objects[target]
			if not entry then
				entry = createEntry(target, category.Color)
				objects[target] = entry
			end

			local billboard = entry.Billboard
			billboard.Adornee = root
			billboard.Enabled = Settings.ShowLabels
			billboard.TextLabel.Text = getLabelText(target)
			billboard.Distance.Visible = Settings.ShowDistance and distance ~= nil
			if distance then
				billboard.Distance.Text = ("%d studs"):format(distance)
			end
		end
	end

	-- Drop ESP for targets that despawned, were looted, left the folder or went out of range
	for target, entry in objects do
		if not seen[target] then
			destroyEntry(entry)
			objects[target] = nil
		end
	end
end

task.spawn(function()
	while EspFolder.Parent do
		local myRoot = getMyRoot()
		for _, category in Categories do
			if category.Enabled then
				updateCategory(category, myRoot)
			end
		end
		task.wait(0.25)
	end
end)

--------------------------------------------------------------------------------
-- Silent Walk / Infinite Stamina
--------------------------------------------------------------------------------

-- SprintClient tells the server you're sneaking with Sneak:FireServer(bool) and that you're
-- out of breath with Breathing:FireServer(bool). The hook keeps the server told "sneaking" and
-- "not winded" while those toggles are on, whatever speed you actually move at.
ctx:HookMeta(game, "__namecall", function(old, self, ...)
	if getnamecallmethod() == "FireServer" then
		if Settings.SilentWalk and self.Name == "Sneak" and self.Parent and self.Parent.Name == "Remotes" then
			return old(self, true)
		end
		if Settings.InfiniteStamina and self.Name == "Breathing" and self.Parent and self.Parent.Name == "Remotes" then
			return old(self, false)
		end
	end
	return old(self, ...)
end)

-- SprintClient never drains stamina while the player has the "God" attribute
-- (it refills to max every frame). Set locally, so only this client sees it.
local function applyStamina(state)
	if state then
		ctx:SetAttribute(LocalPlayer, "God", true)
		Breathing:FireServer(false)
	elseif LocalPlayer:GetAttribute("God") then
		ctx:SetAttribute(LocalPlayer, "God", nil)
	end
end

task.spawn(function()
	-- re-assert after respawns, in case something clears the attribute
	while EspFolder.Parent do
		if Settings.InfiniteStamina and not LocalPlayer:GetAttribute("God") then
			ctx:SetAttribute(LocalPlayer, "God", true)
		end
		task.wait(1)
	end
end)

--------------------------------------------------------------------------------
-- Loot helpers (mirroring LootClient)
--------------------------------------------------------------------------------

local RecentLoot = {} -- [item] = os.clock() until which it's skipped

local function getLootFolder()
	return workspace:FindFirstChild("Loot")
end

local function isHeldByMe(item)
	return item:GetAttribute("HeldBy") == LocalPlayer.UserId
end

local function getHeldLoot()
	local folder = getLootFolder()
	for _, item in folder and folder:GetChildren() or {} do
		if isHeldByMe(item) then
			return item
		end
	end
	return nil
end

-- LootClient only grabs items you can lift: weight < 2, or enough Shop_Lifter levels
local function canLift(item)
	local weight = item:GetAttribute("Weight") or 1
	return weight < 2 or (LocalPlayer:GetAttribute("Shop_Lifter") or 0) >= weight - 1
end

local StashableKinds = {
	MedKit = true, BananaPeel = true, Package = true, ACGas = true,
	SpikeStrip = true, Jammer = true, TruckKey = true, DesertMap = true,
}

local function isStashable(item)
	local kind = item:GetAttribute("Kind")
	if kind == "Tool" or item:GetAttribute("Stashable") == true then
		return true
	end
	if (item:GetAttribute("Weight") or 1) >= 2 then
		return false
	end
	return (item:GetAttribute("Value") or 0) > 0 or StashableKinds[kind] == true
end

local function waitFor(condition, timeout)
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if condition() then
			return true
		end
		task.wait()
	end
	return condition()
end

-- Why we can't act right now, or nil. BustedUntil is a server timestamp, so it only counts until then.
local function blockedReason()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return "no character"
	end
	if humanoid.Health <= 0 then
		return "dead"
	end
	if LocalPlayer:GetAttribute("Arrested") then
		return "arrested"
	end
	if LocalPlayer:GetAttribute("Downed") then
		return "downed"
	end
	local bustedUntil = LocalPlayer:GetAttribute("BustedUntil")
	if type(bustedUntil) == "number" and bustedUntil > workspace:GetServerTimeNow() then
		return ("busted for %.0fs"):format(bustedUntil - workspace:GetServerTimeNow())
	end
	return nil
end

local function canAct()
	return blockedReason() == nil
end

-- Axis-aligned extent (half size) of a box with this CFrame and size
local function boxExtent(cf, size)
	local half = size / 2
	return Vector3.new(
		math.abs(cf.XVector.X) * half.X + math.abs(cf.YVector.X) * half.Y + math.abs(cf.ZVector.X) * half.Z,
		math.abs(cf.XVector.Y) * half.X + math.abs(cf.YVector.Y) * half.Y + math.abs(cf.ZVector.Y) * half.Z,
		math.abs(cf.XVector.Z) * half.X + math.abs(cf.YVector.Z) * half.Y + math.abs(cf.ZVector.Z) * half.Z
	)
end

local function addBox(box, cf, size)
	local extent = boxExtent(cf, size)
	local low, high = cf.Position - extent, cf.Position + extent
	if not box.Min then
		box.Min, box.Max = low, high
	else
		box.Min, box.Max = box.Min:Min(low), box.Max:Max(high)
	end
end

-- Loot goes into the town truck's cargo zone when the truck departs; on arrival it's in the
-- hideout truck's cargo zone, and goes from there into the hideout's sell zone
local CARGO_ZONE = { "Town", "Truck", "CargoZone" }
local HIDEOUT_CARGO_ZONE = { "Hideout", "Truck", "CargoZone" }
local SELL_ZONE = { "Hideout", "SellBox", "SellZone" }

-- A zone's axis-aligned box: the part itself, or every part inside it if it's a model/folder
local function getZone(path)
	local zone = getFolder(path)
	if not zone then
		return nil
	end
	local box = {}
	if zone:IsA("BasePart") then
		addBox(box, zone.CFrame, zone.Size)
	else
		for _, part in zone:GetDescendants() do
			if part:IsA("BasePart") then
				addBox(box, part.CFrame, part.Size)
			end
		end
	end
	if not box.Min then
		return nil
	end
	box.Center = (box.Min + box.Max) / 2
	return box
end

-- The hideout may still be streaming in when the truck arrives
local function waitForZone(path, timeout)
	local zone
	waitFor(function()
		zone = getZone(path)
		return zone ~= nil
	end, timeout)
	return zone
end

local function isInsideZone(position, zone)
	return position.X >= zone.Min.X - 0.5 and position.X <= zone.Max.X + 0.5
		and position.Z >= zone.Min.Z - 0.5 and position.Z <= zone.Max.Z + 0.5
		and position.Y >= zone.Min.Y - 1 and position.Y <= zone.Max.Y + 3
end

-- The hideout compound's safe zone. A sniper (workspace.Hideout.Sniper) shoots anyone outside
-- it, so at the hideout every spot we stand on and every route point is kept inside, 2 studs in
-- from its edge. Worked out in the part's own space, so a rotated zone is handled too.
local SAFE_ZONE = { "Hideout", "Compound", "SafeZone" }
local SAFE_MARGIN = 2

local function safeZonePart()
	local zone = getFolder(SAFE_ZONE)
	if zone and not zone:IsA("BasePart") then
		zone = zone:FindFirstChildWhichIsA("BasePart", true)
	end
	return zone
end

-- Whether `position` is near enough to the hideout that the safe zone applies
local function guardedBySafeZone(safe, position)
	return safe ~= nil and (safe.Position - position).Magnitude < 300
end

local function insideSafeZone(safe, position)
	local p = safe.CFrame:PointToObjectSpace(position)
	local half = safe.Size / 2
	return math.abs(p.X) <= half.X - SAFE_MARGIN + 0.01 and math.abs(p.Z) <= half.Z - SAFE_MARGIN + 0.01
end

local function clampToSafeZone(safe, position)
	local p = safe.CFrame:PointToObjectSpace(position)
	local half = safe.Size / 2
	local hx, hz = math.max(half.X - SAFE_MARGIN, 0), math.max(half.Z - SAFE_MARGIN, 0)
	return safe.CFrame:PointToWorldSpace(Vector3.new(math.clamp(p.X, -hx, hx), p.Y, math.clamp(p.Z, -hz, hz)))
end

-- The carried item is physics-owned by this client, so moving it replicates. Hold it in the
-- zone for a moment so the position reaches the server before LootRelease does.
local function placeInZone(item, zone, floorPoint)
	local primary = item.PrimaryPart
	if not primary then
		return
	end
	local carryPosition = primary:FindFirstChild("CarryPosition")
	local carryOrientation = primary:FindFirstChild("CarryOrientation")
	if carryPosition then carryPosition.Enabled = false end
	if carryOrientation then carryOrientation.Enabled = false end

	-- 1.5 studs above the floor it should land on (the sell box's Floor, when given), or at least
	-- 1.5 studs above the zone's bottom, so a flat floor zone doesn't bury the item
	local dropPoint = floorPoint and CFrame.new(floorPoint + Vector3.new(0, 1.5, 0))
		or CFrame.new(zone.Center.X, math.max(zone.Center.Y, zone.Min.Y + 1.5), zone.Center.Z)
	local deadline = os.clock() + 0.2
	while os.clock() < deadline and item.Parent do
		item:PivotTo(dropPoint)
		primary.AssemblyLinearVelocity = Vector3.zero
		primary.AssemblyAngularVelocity = Vector3.zero
		task.wait()
	end
	LootRelease:FireServer()
	RecentLoot[item] = os.clock() + 5
	waitFor(function()
		return not isHeldByMe(item)
	end, 1)
end

local function grabItem(item)
	if isHeldByMe(item) then
		return true
	end
	LootGrab:FireServer(item)
	return waitFor(function()
		return isHeldByMe(item)
	end, 1)
end

local function findStashedLoot()
	local character = LocalPlayer.Character
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	for _, container in { character, backpack } do
		for _, tool in container and container:GetChildren() or {} do
			if tool:IsA("Tool") and CollectionService:HasTag(tool, "StashedLoot") then
				return tool
			end
		end
	end
	return nil
end

-- Takes one stashed item out of the hotbar and returns it held, or nil
-- Fires DropStashed for a stashed tool and returns the item it put back into the world (or the
-- one now in our hands, with true), without picking it up
local function catchStashedDrop(tool)
	local folder = getLootFolder()
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not (folder and humanoid) then
		return nil
	end

	if tool.Parent ~= LocalPlayer.Character then
		humanoid:EquipTool(tool)
		task.wait(0.2)
	end

	-- DropStashed puts the item back into the world. Catch it by the "Loot" tag (wherever it's
	-- parented) or as a new child of workspace.Loot, or notice we're already holding it.
	local dropped, seen = nil, {}
	local function consider(instance)
		if not dropped and instance:IsA("Model") then
			dropped = instance
		end
		if #seen < 5 then
			table.insert(seen, instance:GetFullName())
		end
	end
	local connections = {
		CollectionService:GetInstanceAddedSignal("Loot"):Connect(consider),
		folder.ChildAdded:Connect(consider),
	}
	Hotbar:FireServer("DropStashed")
	waitFor(function()
		return dropped ~= nil or getHeldLoot() ~= nil
	end, 3)
	for _, connection in connections do
		connection:Disconnect()
	end

	local held = getHeldLoot()
	if held then
		return held, true
	end
	if not dropped then
		farmLog("DropStashed: nothing tagged Loot appeared and nothing held (tool now in %s)",
			tool.Parent and tool.Parent:GetFullName() or "nil")
		return nil
	end
	farmLog("DropStashed produced %s (seen: %s)", dropped:GetFullName(), table.concat(seen, ", "))
	waitFor(function()
		return dropped.PrimaryPart ~= nil
	end, 1)
	return dropped, false
end

-- Takes one stashed item out of the hotbar and returns it held, or nil
local function dropStashedItem(tool)
	local item, held = catchStashedDrop(tool)
	if not item then
		return nil
	end
	if held or (item.PrimaryPart and grabItem(item)) then
		return item
	end
	farmLog("couldn't grab dropped %s (HeldBy=%s)", item.Name, tostring(item:GetAttribute("HeldBy")))
	return nil
end

-- On Depart: what you're carrying, then every stashed item, into the truck's cargo zone
local function loadCargo()
	local zone = getZone(CARGO_ZONE)
	if not zone then
		return 0
	end

	local count = 0
	local held = getHeldLoot()
	if held then
		placeInZone(held, zone)
		count = count + 1
	end
	for _ = 1, 50 do
		local tool = findStashedLoot()
		local item = tool and dropStashedItem(tool)
		if not item then
			break
		end
		placeInZone(item, zone)
		count = count + 1
	end
	return count
end

-- On Arrive: every item sitting in the hideout truck's cargo zone into the hideout's sell zone
local function unloadCargo()
	local cargo = waitForZone(HIDEOUT_CARGO_ZONE, 5)
	local sell = waitForZone(SELL_ZONE, 5)
	local folder = getLootFolder()
	if not (cargo and sell and folder) then
		return 0
	end

	local count, failed = 0, {}
	for _ = 1, 50 do
		local nextItem
		for _, item in folder:GetChildren() do
			local primary = item.PrimaryPart
			if primary and not failed[item] and canLift(item) and isInsideZone(primary.Position, cargo)
				and (not item:GetAttribute("HeldBy") or isHeldByMe(item)) then
				nextItem = item
				break
			end
		end
		if not nextItem then
			break
		end
		if grabItem(nextItem) then
			placeInZone(nextItem, sell)
			count = count + 1
		else
			failed[nextItem] = true
		end
	end
	return count
end

-- Travel jobs and the collect loop all grab loot, and you can only hold one item at a time
local LootBusy = false

local function runLootJob(title, job)
	task.spawn(function()
		waitFor(function()
			return not LootBusy
		end, 5)
		LootBusy = true
		local ok, result = pcall(job)
		LootBusy = false
		ctx.Notify(title .. ": " .. (ok and ("moved %d item(s)"):format(result) or tostring(result)), ok and "success" or "error", 4)
	end)
end

ctx:Connect(Remotes:WaitForChild("Travel").OnClientEvent, function(kind)
	-- Auto Farm does its own loading and unloading
	if not Settings.AutoDrop or Settings.AutoFarm then
		return
	end
	if kind == "Depart" then
		runLootJob("Loaded truck", loadCargo)
	elseif kind == "Arrive" then
		runLootJob("Sold cargo", function()
			task.wait(1) -- let the truck and its loot settle at the hideout
			return unloadCargo()
		end)
	end
end)

-- Auto Collect: grab the nearest stashable item in range and put it in your hotbar
local function tryCollect(myRoot)
	local folder = getLootFolder()
	if not folder or getHeldLoot() then
		return false
	end

	-- never take loot back out of the truck or the sell box
	local zones = {}
	for _, path in { CARGO_ZONE, HIDEOUT_CARGO_ZONE, SELL_ZONE } do
		table.insert(zones, getZone(path))
	end

	local now = os.clock()
	local best, bestDistance = nil, Settings.CollectRadius
	for _, item in folder:GetChildren() do
		local primary = item.PrimaryPart
		if primary and not item:GetAttribute("HeldBy") and (RecentLoot[item] or 0) < now
			and canLift(item) and isStashable(item) then
			local inZone = false
			for _, zone in zones do
				inZone = inZone or isInsideZone(primary.Position, zone)
			end
			local distance = (primary.Position - myRoot.Position).Magnitude
			if not inZone and distance <= bestDistance then
				best, bestDistance = item, distance
			end
		end
	end
	if not best then
		return false
	end

	RecentLoot[best] = now + 3
	if not grabItem(best) then
		return true
	end

	Hotbar:FireServer("Stash")
	local stashed = waitFor(function()
		return best.Parent ~= folder or not isHeldByMe(best)
	end, 1)
	if not stashed then
		-- Stash refused (hotbar full?): put it down and leave it alone for a while
		LootRelease:FireServer()
		RecentLoot[best] = os.clock() + 30
	end
	return true
end

task.spawn(function()
	while EspFolder.Parent do
		local myRoot = getMyRoot()
		if Settings.AutoCollect and not LootBusy and myRoot and canAct() then
			LootBusy = true
			pcall(tryCollect, myRoot)
			LootBusy = false
		end
		-- forget skipped items that are gone
		for item in RecentLoot do
			if not item.Parent then
				RecentLoot[item] = nil
			end
		end
		task.wait(0.25)
	end
end)

--------------------------------------------------------------------------------
-- Auto Farm
--------------------------------------------------------------------------------
-- Loop: job board (start night) -> travel to town -> collect house loot -> when the hotbar is
-- full, drop it all in the town truck's cargo zone -> return to the hideout -> pick up everything
-- in the hideout truck's cargo zone -> drop it in the sell zone -> pull the sell lever -> repeat

local BOARD_PROMPT = { "Hideout", "Truck", "JobBoard", "Board", "Prompt" }
local TOWN_BOARD_PROMPT = { "Town", "Truck", "JobBoard", "Board", "Prompt" }
local SELL_LEVER_PROMPT = { "Hideout", "SellLever", "Post", "Prompt" }
local FARM_STOPPED = "AutoFarm stopped"

local Farm = {
	Stage = "Idle",
	NextStage = nil,
	Collected = 0,
	Sold = 0,
	Runs = 0,
	Traveling = false,
	LastDepart = 0,
	LastArrive = 0,
	AlarmAt = 0, -- when the game last said someone called the cops
	WantedToastAt = 0, -- when the game last said "You're wanted - lose the police..."
	CollectStartedAt = nil, -- when the current Collect stage began (an alarm after it ends it)
	SpottedAt = 0, -- when the game last said "Security spotted you!"
}
local FarmGrid -- the panel's status grid, created with the UI below

-- All UI work happens on one thread. In this executor, loop threads can fail to touch the
-- library's ScreenGui ("lacking capability Plugin"), so farmLog / updateFarmStatus only queue
-- the work, and the pump thread below (started at load time) applies it.
local uiQueue = {}

-- Log lines go to the hub's Debug Console
local function pushLog(line, messageType)
	ctx.Log(line, messageType == Enum.MessageType.MessageWarning and "warn" or "info")
end

function farmLog(fmt, ...)
	if Settings.VerboseLogs then
		pushLog(fmt:format(...), Enum.MessageType.MessageInfo)
	end
end

local function farmWarn(fmt, ...)
	pushLog(fmt:format(...), Enum.MessageType.MessageWarning)
end

task.spawn(function()
	while EspFolder.Parent do
		if #uiQueue > 0 then
			local batch = uiQueue
			uiQueue = {}
			for _, action in batch do
				local ok, err = pcall(action)
				if not ok then
					ctx.Log("UI update failed: " .. tostring(err), "warn")
				end
			end
		end
		task.wait(0.1)
	end
end)

local function fmtVec(v)
	return ("(%.0f, %.0f, %.0f)"):format(v.X, v.Y, v.Z)
end

local function describeItem(item)
	return ("%s [value=%s weight=%s kind=%s]"):format(
		item:GetAttribute("DisplayName") or item.Name,
		tostring(item:GetAttribute("Value")),
		tostring(item:GetAttribute("Weight")),
		tostring(item:GetAttribute("Kind"))
	)
end

local function farmActive()
	return Settings.AutoFarm and EspFolder.Parent ~= nil
end

-- Unwinds the current stage as soon as the toggle goes off
local function checkFarm()
	if not farmActive() then
		error(FARM_STOPPED, 0)
	end
end

local function farmWait(condition, timeout)
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		checkFarm()
		if condition() then
			return true
		end
		task.wait(0.1)
	end
	return condition()
end

local function countStash()
	local count = 0
	for _, container in { LocalPlayer.Character, LocalPlayer:FindFirstChildOfClass("Backpack") } do
		for _, tool in container and container:GetChildren() or {} do
			if tool:IsA("Tool") and CollectionService:HasTag(tool, "StashedLoot") then
				count = count + 1
			end
		end
	end
	return count
end

local function leaderstatsText()
	local stats = LocalPlayer:FindFirstChild("leaderstats")
	local parts = {}
	for _, value in stats and stats:GetChildren() or {} do
		if value:IsA("ValueBase") then
			table.insert(parts, value.Name .. "=" .. tostring(value.Value))
		end
	end
	return #parts > 0 and table.concat(parts, " ") or "(no leaderstats)"
end

local function updateFarmStatus()
	local stage, collected, sold, runs = Farm.Stage, Farm.Collected, Farm.Sold, Farm.Runs
	table.insert(uiQueue, function()
		if FarmGrid then
			FarmGrid:SetValue("Stage", stage)
			FarmGrid:SetValue("Collected", collected)
			FarmGrid:SetValue("Sold", sold)
			FarmGrid:SetValue("Runs", runs)
		end
	end)
end

local function setStage(name)
	Farm.Stage = name
	if name ~= "Collect" then
		-- an alarm only cuts collecting short; it must not stop the hideout unload later
		Farm.CollectStartedAt = nil
	end
	farmLog("---- stage: %s (hotbar %d, %s)", name, countStash(), leaderstatsText())
	updateFarmStatus()
end

-- A seated character is welded to the seat (e.g. the truck after Travel Arrive), so moving the
-- root alone doesn't stick: get up first
local function leaveSeat()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (humanoid and (humanoid.SeatPart or humanoid.Sit)) then
		return
	end
	local seat = humanoid.SeatPart
	farmLog("seated in %s; getting up", seat and seat:GetFullName() or "?")
	humanoid.Sit = false
	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	if not waitFor(function()
		return humanoid.SeatPart == nil
	end, 1) and seat then
		-- the seat weld is created on this client's side of the seat; removing it frees us
		for _, weld in seat:GetChildren() do
			if weld:IsA("Weld") and weld.Name == "SeatWeld" then
				weld:Destroy()
			end
		end
		waitFor(function()
			return humanoid.SeatPart == nil
		end, 1)
	end
	farmLog("after getting up: SeatPart=%s Sit=%s", tostring(humanoid.SeatPart), tostring(humanoid.Sit))
end

-- Movement. The server pulls you back for passing through walls, and in town also for moving
-- faster than you could, so every move follows a PathfindingService route around obstacles and
-- really walks it (sprinting). Glide Movement glides the route at MoveSpeed instead.
local GroundParams = RaycastParams.new()
GroundParams.FilterType = Enum.RaycastFilterType.Exclude
GroundParams.RespectCanCollide = true

-- How high the HumanoidRootPart's center sits above the floor when standing
local function rootHeight()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = getMyRoot()
	if humanoid and root then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	return 3
end

-- The root position for standing on the floor under `point` (the search starts just above it,
-- so a roof or shelf higher up isn't picked)
local function standingAt(point)
	GroundParams.FilterDescendantsInstances = { LocalPlayer.Character, getLootFolder() }
	local hit = workspace:Raycast(point + Vector3.new(0, 1.5, 0), Vector3.new(0, -40, 0), GroundParams)
	return hit and hit.Position + Vector3.new(0, rootHeight(), 0) or point
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function rotateFlat(v, degrees)
	local a = math.rad(degrees)
	return Vector3.new(v.X * math.cos(a) - v.Z * math.sin(a), 0, v.X * math.sin(a) + v.Z * math.cos(a))
end

-- Doors and glass. Gliding through a wall gets you rubber-banded back, but doors and glass are
-- fine, so routes may pass through them: each gets a PathfindingModifier with PassThrough, which
-- makes pathfinding treat it as open space. Found by the game's HouseDoor / HouseWindow tags,
-- Glass material, or a door/window/glass name, and only if thin (a door, not a wall).
local PassThroughParts = {}
local PassThroughList = {}
local PassThroughModifiers = {}
local passThroughScanned = 0
local passThroughCheckedAt = -math.huge

local function isDoorOrGlass(part)
	local size = part.Size
	if math.min(size.X, size.Y, size.Z) > 2 then
		return false
	end
	local model = part:FindFirstAncestorWhichIsA("Model")
	for _, holder in { part, model } do
		if holder and (CollectionService:HasTag(holder, "HouseDoor") or CollectionService:HasTag(holder, "HouseWindow")) then
			return true
		end
	end
	if part.Material == Enum.Material.Glass then
		return true
	end
	local name = part.Name:lower()
	return name:find("door", 1, true) ~= nil or name:find("window", 1, true) ~= nil or name:find("glass", 1, true) ~= nil
end

-- Scans the town (once per new batch of streamed-in parts) and marks its doors and glass
local function markPassThrough()
	local town = workspace:FindFirstChild("Town")
	if not town then
		return
	end
	if os.clock() - passThroughCheckedAt < 10 then
		return
	end
	passThroughCheckedAt = os.clock()
	local descendants = town:GetDescendants()
	if #descendants == passThroughScanned then
		return
	end
	passThroughScanned = #descendants
	-- the town streams out while you're at the hideout: forget parts that left with it
	for i = #PassThroughList, 1, -1 do
		local part = PassThroughList[i]
		if not part:IsDescendantOf(workspace) then
			PassThroughParts[part] = nil
			table.remove(PassThroughList, i)
		end
	end
	for i = #PassThroughModifiers, 1, -1 do
		if not PassThroughModifiers[i]:IsDescendantOf(workspace) then
			table.remove(PassThroughModifiers, i)
		end
	end
	local added = 0
	for _, part in descendants do
		if part:IsA("BasePart") and not PassThroughParts[part] and part.CanCollide and isDoorOrGlass(part) then
			PassThroughParts[part] = true
			table.insert(PassThroughList, part)
			local modifier = Instance.new("PathfindingModifier")
			modifier.Name = "CriminalPassThrough"
			modifier.PassThrough = true
			modifier.Parent = part
			ctx:Track(modifier)
			table.insert(PassThroughModifiers, modifier)
			added = added + 1
		end
	end
	if added > 0 then
		farmLog("routes may now pass through %d more door/glass part(s) (%d in all)", added, #PassThroughList)
	end
end

local LineParams = RaycastParams.new()
LineParams.FilterType = Enum.RaycastFilterType.Exclude
LineParams.RespectCanCollide = true

-- Nothing but doors and glass between two points: a straight glide here won't cut through a wall.
-- Returns false and the wall in the way otherwise.
local function lineIsClear(from, to)
	local ignore = { LocalPlayer.Character, getLootFolder() }
	for _, part in PassThroughList do
		table.insert(ignore, part)
	end
	LineParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(from, to - from, LineParams)
	return hit == nil, hit and hit.Instance
end

local function computePath(from, to)
	local up = Vector3.new(0, rootHeight(), 0)
	local path = PathfindingService:CreatePath({
		AgentRadius = 1.5, -- 2 made ordinary doorways too narrow to route through
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true, -- ladders and trusses as well as stairs
		WaypointSpacing = 4,
	})
	local ok, err = pcall(path.ComputeAsync, path, from - up, to - up)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil, ok and tostring(path.Status) or tostring(err)
	end
	return path:GetWaypoints()
end

-- Path waypoints are on the floor; turn them into root positions for gliding. A Jump waypoint
-- marks an obstacle (a rail or step), so go over it instead of through it.
local function glidePoints(waypoints, to)
	local up = Vector3.new(0, rootHeight(), 0)
	local lift = Vector3.new(0, 4, 0)
	local points, liftNext = {}, false
	for i, waypoint in waypoints do
		if i > 1 then -- the first waypoint is where we already are
			local point = waypoint.Position + up
			if liftNext then
				table.insert(points, point + lift)
				liftNext = false
			end
			table.insert(points, point)
			if waypoint.Action == Enum.PathWaypointAction.Jump then
				table.insert(points, point + lift)
				liftNext = true
			end
		end
	end
	table.insert(points, to)
	return points
end

-- Your sprint speed, as SprintClient sets it: 26 + 2 per Running Shoes level, times the hideout's
-- furniture speed bonus. Carrying something heavy without Strong Back caps it at 11.
local function runSpeed()
	local multiplier = 1 + (ReplicatedStorage:GetAttribute("FurnitureSpeed") or 0)
	local heavy = (LocalPlayer:GetAttribute("Shop_StrongBack") or 0) < 1
		and (LocalPlayer:GetAttribute("CarryWeight") or 0) >= 2
	if heavy then
		return 11 * multiplier
	end
	return ((LocalPlayer:GetAttribute("Shop_RunningShoes") or 0) * 2 + 26) * multiplier
end

-- Glide a touch under run speed, so the server never sees us go faster than a sprint
local function glideSpeed()
	if Settings.GlideAtRunSpeed then
		return runSpeed() * Settings.GlideSpeedPercent / 100
	end
	return Settings.MoveSpeed
end

-- Breadcrumbs: every spot a glide really reached this trip (not pulled back), about 3 studs
-- apart. Retracing them is a known-good way back out of a building when pathfinding has no route.
local Trail = {} -- { Position, Time }

local function recordTrail(position)
	local last = Trail[#Trail]
	if not last or (position - last.Position).Magnitude >= 3 then
		table.insert(Trail, { Position = position, Time = os.clock() })
		if #Trail > 600 then
			table.remove(Trail, 1)
		end
	end
end

-- The server's correction arrives up to a second late, so the breadcrumbs from just before a
-- pull-back were never really reached (they lead into a wall): drop them
local function dropRecentTrail(seconds)
	local cutoff = os.clock() - seconds
	while #Trail > 0 and Trail[#Trail].Time > cutoff do
		table.remove(Trail)
	end
end

-- Glides the root through `points`. Each frame we should still be where we put ourselves the
-- frame before; if not, something moved us (the server pulling us back) and we stop there.
local function glideThrough(root, points)
	local commanded = root.Position
	for _, point in points do
		local start = commanded
		local length = (point - start).Magnitude
		local facing = flat(point - start).Magnitude > 0.1 and flat(point - start).Unit or root.CFrame.LookVector
		local travelled = 0
		while travelled < length do
			local dt = RunService.Heartbeat:Wait()
			if (root.Position - commanded).Magnitude > 5 then
				dropRecentTrail(1.2)
				return false, ("put at %s, found at %s"):format(fmtVec(commanded), fmtVec(root.Position))
			end
			recordTrail(commanded) -- we seem to have got here (see dropRecentTrail)
			-- A frame hitch (pathfinding, raycasts) would otherwise make one big jump that the
			-- server reads as a teleport and pulls back, so never step more than 1/30s worth
			travelled = math.min(length, travelled + glideSpeed() * math.min(dt, 1 / 30))
			commanded = start:Lerp(point, travelled / length)
			root.CFrame = CFrame.lookAt(commanded, commanded + facing)
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end
	return true
end

-- SprintClient's Toggle BindableEvent latches sprint on/off, like the sprint key does
local function setSprint(on)
	local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
	local client = scripts and scripts:FindFirstChild("SprintClient", true)
	local toggle = client and client:FindFirstChild("Toggle")
	if not (toggle and toggle:IsA("BindableEvent")) then
		return
	end
	if (client:GetAttribute("Sprint") == true) ~= on then
		toggle:Fire("Sprint")
	end
end

-- Really walks the character from waypoint to waypoint with Humanoid:MoveTo, jumping where the
-- path says to. Movement the game itself produces, so the server has nothing to pull back.
local function walkThrough(root, humanoid, waypoints, to)
	local targets = {}
	for i, waypoint in waypoints do
		if i > 1 then
			table.insert(targets, { Position = waypoint.Position, Jump = waypoint.Action == Enum.PathWaypointAction.Jump })
		end
	end
	table.insert(targets, { Position = to - Vector3.new(0, rootHeight(), 0) })

	for index, target in targets do
		checkFarm()
		if target.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(target.Position)
		local speed = math.max(humanoid.WalkSpeed, 8)
		local timeout = flat(target.Position - root.Position).Magnitude / speed + 1.5
		local deadline = os.clock() + timeout
		local last, stuckSince = root.Position, os.clock()
		while flat(target.Position - root.Position).Magnitude > (index == #targets and 1.5 or 2.5) do
			local now = os.clock()
			if now > deadline then
				humanoid:MoveTo(root.Position)
				return false, ("timed out walking to waypoint %d/%d %s (at %s)"):format(index, #targets,
					fmtVec(target.Position), fmtVec(root.Position))
			end
			task.wait(0.05)
			local moved = (root.Position - last).Magnitude
			if moved > 8 then
				humanoid:MoveTo(root.Position)
				return false, ("pulled from %s to %s"):format(fmtVec(last), fmtVec(root.Position))
			end
			if moved > 0.2 then
				stuckSince = now
			elseif now - stuckSince > 0.6 then
				humanoid.Jump = true -- blocked by a step or rail the path didn't flag
				stuckSince = now
			end
			last = root.Position
			humanoid:MoveTo(target.Position) -- MoveTo gives up by itself after 8 seconds
		end
	end
	return true
end

local function faceTowards(root, lookAt)
	if lookAt and flat(lookAt - root.Position).Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat(lookAt - root.Position))
	end
end

-- Moves to a root position (use standingAt for points on the floor) along a pathfinding route,
-- walking unless Glide Movement is on. Up to 3 tries, re-planning from wherever we ended up.
-- Noclip: the character's parts stop colliding, so walls and doors can't push us back out while
-- we glide through them. The Humanoid turns collision back on every step, so it's re-applied in
-- Stepped; turning it off restores each part as it was.
local NoclipConnection
local NoclipSaved = {}

local setNoclip
ctx:OnCleanup(function()
	setNoclip(false)
end)

function setNoclip(on)
	if on and not NoclipConnection then
		NoclipConnection = ctx:Connect(RunService.Stepped, function()
			local character = LocalPlayer.Character
			for _, part in character and character:GetDescendants() or {} do
				if part:IsA("BasePart") and part.CanCollide then
					if NoclipSaved[part] == nil then
						NoclipSaved[part] = true
					end
					part.CanCollide = false
				end
			end
		end)
	elseif not on and NoclipConnection then
		NoclipConnection:Disconnect()
		NoclipConnection = nil
		for part in NoclipSaved do
			if part.Parent then
				part.CanCollide = true
			end
		end
		table.clear(NoclipSaved)
	end
end

-- The closest spot to `target` (5 or 10 studs away, our side first) that pathfinding can reach
-- from `from` and that has nothing but doors or glass between it and the target, with its route
local function reachableNear(from, target)
	local toUs = flat(from - target)
	local first = toUs.Magnitude > 0.1 and toUs.Unit or Vector3.new(1, 0, 0)
	for _, radius in { 5, 10 } do
		for _, degrees in { 0, 45, -45, 90, -90, 135, -135, 180 } do
			local probe = target + rotateFlat(first, degrees) * radius
			local spot = standingAt(probe)
			if lineIsClear(spot, target) then
				local waypoints = computePath(from, spot)
				if waypoints then
					return spot, waypoints
				end
			end
		end
	end
	return nil
end

-- The floor spots 2.5 studs either side of a door or pane (across its thin side)
local function doorSides(part)
	local size = part.Size
	local normal = flat(size.X < size.Z and part.CFrame.RightVector or part.CFrame.LookVector)
	if normal.Magnitude < 0.1 then
		return nil
	end
	normal = normal.Unit
	return standingAt(part.Position + normal * 2.5), standingAt(part.Position - normal * 2.5)
end

local function plainWaypoints(waypoints, skipFirst)
	local out = {}
	for i, waypoint in waypoints do
		if not (skipFirst and i == 1) then
			table.insert(out, { Position = waypoint.Position, Action = waypoint.Action })
		end
	end
	return out
end

-- Route planning can't get into a closed building, but we can: plan a route to the outside of
-- one of its doors (or glass), glide through it, and plan the rest from the inside. A second
-- door is tried on the inside when the first leaves us in the wrong room. Returns floor-level
-- waypoints for the whole way and the doors used, or nil.
local function routeViaDoors(from, target, depth, maxDoors, radius)
	local up = Vector3.new(0, rootHeight(), 0)
	local candidates = {}
	for _, part in PassThroughList do
		if part.Parent then
			local distance = (part.Position - target).Magnitude
			if distance < radius then
				table.insert(candidates, { Part = part, Distance = distance })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.Distance < b.Distance
	end)

	for i = 1, math.min(maxDoors, #candidates) do
		local door = candidates[i].Part
		local sideA, sideB = doorSides(door)
		if sideA then
			for _, pair in { { sideA, sideB }, { sideB, sideA } } do
				local nearSide, farSide = pair[1], pair[2]
				local toDoor = computePath(from, nearSide)
				if toDoor then
					local rest, doors = nil, nil
					local inside = computePath(farSide, target)
					if inside then
						rest, doors = plainWaypoints(inside, true), {}
					elseif depth > 0 then
						rest, doors = routeViaDoors(farSide, target, depth - 1, 3, 30)
					end
					if rest then
						local route = plainWaypoints(toDoor)
						table.insert(route, { Position = nearSide - up, Action = Enum.PathWaypointAction.Walk })
						table.insert(route, { Position = farSide - up, Action = Enum.PathWaypointAction.Walk })
						for _, waypoint in rest do
							table.insert(route, waypoint)
						end
						table.insert(doors, 1, door)
						return route, doors
					end
					break -- this door's reachable side doesn't lead to the target; next door
				end
			end
		end
	end
	return nil
end

local moveToUnsafe

local function moveTo(position, lookAt)
	local ok, result = pcall(moveToUnsafe, position, lookAt)
	setNoclip(false) -- never leave noclip on, even when the farm stops mid-move
	if not ok then
		error(result, 0)
	end
	return result
end

function moveToUnsafe(position, lookAt)
	local root = getMyRoot()
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not (root and humanoid) then
		farmWarn("no character; can't move")
		return false
	end
	leaveSeat()
	markPassThrough()

	-- At the hideout, never aim for (or route through) anywhere the sniper can reach
	local safe = safeZonePart()
	local guarded = guardedBySafeZone(safe, root.Position)
	if guarded and not insideSafeZone(safe, position) then
		local inside = standingAt(clampToSafeZone(safe, position))
		farmLog("%s is outside the compound safe zone (sniper); going to %s instead", fmtVec(position), fmtVec(inside))
		position = inside
	end

	local distance = (position - root.Position).Magnitude
	local mode = Settings.GlideMovement and "glide" or "walk"
	if mode == "walk" then
		setSprint(true)
	end
	if mode == "glide" and Settings.AlwaysNoclip then
		setNoclip(true)
	end

	for try = 1, 3 do
		-- Stuck once already: glide the rest of the way with noclip (walking with noclip would
		-- drop through the floor, so a stuck walk becomes a glide too)
		if try > 1 and Settings.NoclipWhenStuck and not NoclipConnection then
			farmLog("noclip on for the rest of this move")
			mode = "glide"
			setNoclip(true)
		end
		checkFarm()
		if (position - root.Position).Magnitude <= 2.5 then
			break
		end
		local waypoints, status = computePath(root.Position, position)
		if waypoints then
			local jumps = 0
			for _, waypoint in waypoints do
				if waypoint.Action == Enum.PathWaypointAction.Jump then
					jumps = jumps + 1
				end
			end
			farmLog("%s to %s: %d waypoint(s), %d jump(s)%s%s", mode, fmtVec(position), #waypoints, jumps,
				mode == "glide" and (" at %.1f studs/s"):format(glideSpeed()) or "",
				NoclipConnection and " (noclip)" or "")
		else
			-- No route to the spot itself (a closed room, or the truck bed's rails). The server
			-- pulls you back for passing through walls, noclip or not, so route to the closest
			-- reachable spot near it and only go straight for the last few studs.
			local near, nearWaypoints = reachableNear(root.Position, position)
			local straight = near and (position - near).Magnitude or flat(position - root.Position).Magnitude
			-- Going straight from here is only OK when nothing but doors or glass is in the way
			local clear, wall = true, nil
			if not near then
				clear, wall = lineIsClear(root.Position, position)
			end
			-- Still nothing: go in through a door (and maybe a second one inside)
			local doorRoute, doors = nil, nil
			if not near and (straight > 15 or not clear) then
				doorRoute, doors = routeViaDoors(root.Position, position, 1, 5, 60)
			end
			if not near and not doorRoute and (straight > 15 or not clear) then
				farmWarn("no route to %s (%s), nothing reachable near it and no door leads there%s; giving up on it",
					fmtVec(position), tostring(status), wall and (" (" .. wall:GetFullName() .. " is in the way)") or "")
				return false
			end
			local noclip = Settings.NoclipWhenStuck and not NoclipConnection and (straight > 0.5 or doorRoute ~= nil)
			if doorRoute then
				local names = {}
				for _, door in doors do
					table.insert(names, door:GetFullName())
				end
				farmLog("no route to %s; going in through %s (%d waypoint(s))%s", fmtVec(position),
					table.concat(names, " then "), #doorRoute, noclip and " with noclip" or "")
				waypoints = doorRoute
			elseif near then
				farmLog("no route to %s; routing to %s instead, then %.0f studs straight%s", fmtVec(position),
					fmtVec(near), straight, noclip and " with noclip" or "")
				waypoints = nearWaypoints
			else
				farmLog("no route to %s (%s); going %.0f studs straight%s", fmtVec(position), tostring(status),
					straight, noclip and " with noclip" or "")
				waypoints = { { Position = root.Position, Action = Enum.PathWaypointAction.Walk } }
			end
			if noclip then
				mode = "glide"
				setNoclip(true)
			end
		end

		-- A route that swings outside the safe zone gets its points pulled back in. The zone is a
		-- box, so straight lines between points inside it stay inside too.
		if guarded then
			local pulled, kept = 0, {}
			for _, waypoint in waypoints do
				local point = waypoint.Position
				if not insideSafeZone(safe, point) then
					point = clampToSafeZone(safe, point)
					pulled = pulled + 1
				end
				table.insert(kept, { Position = point, Action = waypoint.Action })
			end
			if pulled > 0 then
				farmLog("route left the compound safe zone; pulled %d of %d point(s) back inside", pulled, #kept)
			end
			waypoints = kept
		end

		local ok, why
		if mode == "walk" then
			ok, why = walkThrough(root, humanoid, waypoints, position)
		else
			ok, why = glideThrough(root, glidePoints(waypoints, position))
		end
		if ok then
			break
		end
		farmWarn("%s to %s interrupted (try %d/3): %s", mode, fmtVec(position), try, why)
		task.wait(0.3)
	end

	faceTowards(root, lookAt)
	task.wait(0.1)
	local drift = flat(root.Position - position).Magnitude + math.max(0, math.abs(root.Position.Y - position.Y) - 3)
	if drift > 6 then
		farmWarn("couldn't reach %s: ended at %s (%.0f off)", fmtVec(position), fmtVec(root.Position), drift)
		return false
	end
	farmLog("moved %.0f studs to %s", distance, fmtVec(position))
	return true
end

-- Hideout or Town, by which truck's cargo zone is closer
local function getLocation()
	local root = getMyRoot()
	local town, hideout = getZone(CARGO_ZONE), getZone(HIDEOUT_CARGO_ZONE)
	if not root or not (town or hideout) then
		return nil, math.huge, math.huge
	end
	local toTown = town and (town.Center - root.Position).Magnitude or math.huge
	local toHideout = hideout and (hideout.Center - root.Position).Magnitude or math.huge
	return toHideout <= toTown and "Hideout" or "Town", toTown, toHideout
end

-- Where to stand for a zone, on its floor, inside it: `fraction` of the way from its center to
-- its edge on our side (0.7 when not given). Stashed items drop at your feet, so standing inside
-- is what makes them land inside. `edgeOffset` instead stands that many studs past the edge.
local function zoneStandPoint(zone, fraction, edgeOffset)
	local root = getMyRoot()
	local toUs = root and flat(root.Position - zone.Center) or Vector3.new(1, 0, 0)
	local dir = toUs.Magnitude > 0.1 and toUs.Unit or Vector3.new(1, 0, 0)
	local half = (zone.Max - zone.Min) / 2
	-- distance from the center to the box edge along dir
	local toEdge = math.min(
		math.abs(dir.X) > 1e-3 and half.X / math.abs(dir.X) or math.huge,
		math.abs(dir.Z) > 1e-3 and half.Z / math.abs(dir.Z) or math.huge
	)
	if edgeOffset then
		local point = zone.Center + dir * (toEdge + edgeOffset)
		return standingAt(Vector3.new(point.X, zone.Max.Y, point.Z))
	end
	local point = zone.Center + dir * (toEdge * (fraction or 0.7))
	return standingAt(Vector3.new(point.X, zone.Min.Y + 1, point.Z))
end

local function findPrompt(path)
	local found = getFolder(path)
	if found and not found:IsA("ProximityPrompt") then
		found = found:FindFirstChildWhichIsA("ProximityPrompt", true)
	end
	return found
end

local function enabledGuis()
	local set = {}
	for _, gui in LocalPlayer:WaitForChild("PlayerGui"):GetChildren() do
		-- ProximityPrompts is Roblox's own prompt overlay, not a menu the game opened
		if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= "ProximityPrompts" then
			set[gui] = true
		end
	end
	return set
end

-- Holds the camera on a point (getTarget() is read every frame) while `body` runs, then gives it
-- back to the game. The eye sits at your head (raised by `eyeLift` studs, to look down at
-- something) when that's close enough, otherwise 4 studs from the target on your side
-- (LootClient only looks 12 studs ahead).
local CameraRestore
ctx:OnCleanup(function()
	if CameraRestore then
		pcall(CameraRestore)
		CameraRestore = nil
	end
end)

local function withCameraAt(getTarget, body, eyeLift)
	local camera = workspace.CurrentCamera
	local savedType, savedCFrame = camera.CameraType, camera.CFrame
	local lift = Vector3.new(0, eyeLift or 0, 0)
	local function aimCFrame()
		local target = getTarget()
		if not target then
			return camera.CFrame
		end
		local character = LocalPlayer.Character
		local head = character and character:FindFirstChild("Head")
		local eye = (head and head.Position or camera.CFrame.Position) + lift
		if (eye - target).Magnitude > 10 then
			eye = target + (eye - target).Unit * 4
		end
		return CFrame.lookAt(eye, target)
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = aimCFrame()
	-- keep re-aiming every frame, in case a camera script moves it
	local connection = ctx:Connect(RunService.RenderStepped, function()
		camera.CFrame = aimCFrame()
	end)
	local function restore()
		connection:Disconnect()
		camera.CameraType = savedType
		if savedType == Enum.CameraType.Scriptable then
			camera.CFrame = savedCFrame
		end
	end
	CameraRestore = restore -- so a shutdown mid-shot still gives the camera back
	local ok, result = pcall(body)
	CameraRestore = nil
	restore()
	if not ok then
		error(result, 0)
	end
	return result
end

-- How directly the camera looks at a point: 1 = dead center
local function cameraAimAt(position)
	local camera = workspace.CurrentCamera
	return camera.CFrame.LookVector:Dot((position - camera.CFrame.Position).Unit)
end

-- Prompts showing on screen right now (the engine shows one when you're in range and facing it).
-- Tracked from load, like LootClient does, so a prompt that was already up still counts.
local ShownPrompts = {}
ctx:Connect(ProximityPromptService.PromptShown, function(prompt)
	ShownPrompts[prompt] = true
end)
ctx:Connect(ProximityPromptService.PromptHidden, function(prompt)
	ShownPrompts[prompt] = nil
end)

-- Prompt properties changed while a hold/trigger is in flight, given back at shutdown
local PromptRestores = {}
ctx:OnCleanup(function()
	for prompt, saved in PromptRestores do
		for name, value in saved do
			pcall(function()
				prompt[name] = value
			end)
		end
	end
	table.clear(PromptRestores)
end)

-- Where to stand to use a prompt: `distance` studs from it, on `side`, at floor level
local function promptStandPoint(position, side, distance)
	local stand = position + side * distance
	return standingAt(Vector3.new(stand.X, position.Y, stand.Z))
end

-- Holds the prompt like holding the interact key: the server knows the prompt's HoldDuration and
-- ignores a trigger that comes sooner, so a hold prompt has to really be held that long. We stay
-- put and keep looking at it the whole time; if it stops showing, the hold is lost.
local function holdPrompt(prompt, label)
	local holdTime = prompt.HoldDuration
	local began = false
	local beganConnection = prompt.PromptButtonHoldBegan:Connect(function()
		began = true
	end)
	prompt:InputHoldBegin()
	local releaseAt = os.clock() + holdTime + 0.3
	local lostAt
	while os.clock() < releaseAt do
		if not ShownPrompts[prompt] and not lostAt then
			lostAt = holdTime + 0.3 - (releaseAt - os.clock())
		end
		task.wait(0.05)
	end
	prompt:InputHoldEnd()
	beganConnection:Disconnect()
	farmLog("%s: held %.1fs (needs %.1fs), hold began=%s%s", label, holdTime + 0.3, holdTime, tostring(began),
		lostAt and (", stopped showing after %.1fs"):format(lostAt) or "")
end

-- Fires the prompt and waits for its Triggered event (which fires on this client when it went
-- off). Returns the method that worked, or nil.
local function firePrompt(prompt, label, isTriggered)
	local methods = {
		{ "hold " .. ("%.1fs"):format(prompt.HoldDuration), function()
			holdPrompt(prompt, label)
		end },
		{ "fireproximityprompt", function()
			if not fireproximityprompt then
				error("executor lacks fireproximityprompt", 0)
			end
			fireproximityprompt(prompt)
		end },
	}
	for _, method in methods do
		local ok, err = pcall(method[2])
		waitFor(isTriggered, 1)
		farmLog("%s via %s -> ok=%s triggered=%s %s", label, method[1], tostring(ok), tostring(isTriggered()),
			ok and "" or tostring(err))
		if isTriggered() then
			return method[1]
		end
	end
	return nil
end

-- Walks up to the prompt's part, faces it and centers the camera on it, then waits for the game
-- to show the prompt. If it doesn't show, step closer (3 -> 1.5 -> 0.5 studs, then the other
-- side) and look again. Only a showing prompt is in range as the game sees it, so that's when we
-- fire it; if it never shows, fire it from the closest spot anyway.
local function triggerPrompt(prompt, label)
	if not prompt then
		farmWarn("%s prompt not found", label)
		return false
	end
	local holder = prompt.Parent
	local position, front
	if holder:IsA("BasePart") then
		position, front = holder.Position, holder.CFrame.LookVector
	elseif holder:IsA("Attachment") then
		position, front = holder.WorldPosition, holder.WorldCFrame.LookVector
	elseif holder:IsA("Model") then
		position, front = holder:GetPivot().Position, holder:GetPivot().LookVector
	else
		farmWarn("%s prompt's parent %s has no position", label, holder:GetFullName())
		return false
	end

	farmLog("%s prompt %s: ActionText=%q ObjectText=%q Enabled=%s Hold=%.1fs MaxDistance=%.0f LineOfSight=%s at %s",
		label, prompt:GetFullName(), prompt.ActionText, prompt.ObjectText, tostring(prompt.Enabled),
		prompt.HoldDuration, prompt.MaxActivationDistance, tostring(prompt.RequiresLineOfSight), fmtVec(position))
	if not prompt.Enabled then
		farmWarn("%s prompt is disabled; trying anyway", label)
	end

	-- Approach from whichever side we're on (its LookVector may face a wall); the far side is the
	-- last thing tried
	local root = getMyRoot()
	local away = root and flat(root.Position - position)
	if not away or away.Magnitude < 0.1 then
		away = flat(front)
	end
	local side = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)

	-- Prefer a side whose floor is at the prompt's level: next to the truck the floor straight
	-- below can be the ground, 8 studs under a board that sits on the truck bed
	local frontFlat = flat(front).Magnitude > 0.1 and flat(front).Unit or side
	local candidates = { side, frontFlat, -frontFlat, Vector3.new(frontFlat.Z, 0, -frontFlat.X),
		Vector3.new(-frontFlat.Z, 0, frontFlat.X) }
	for _, candidate in candidates do
		local stand = promptStandPoint(position, candidate, 3)
		if position.Y - stand.Y <= 6 then
			if candidate ~= side then
				farmLog("%s: standing on the %s side instead, level with it (floor here is %.0f studs lower)",
					label, candidate == frontFlat and "front" or "other", position.Y - promptStandPoint(position, side, 3).Y)
			end
			side = candidate
			break
		end
	end

	local approaches = {
		{ side, 3, "3 studs away" },
		{ side, 1.5, "1.5 studs away" },
		{ side, 0.5, "right up against it" },
		{ -side, 1.5, "the other side" },
	}

	local triggered = false
	local triggerConnection = prompt.Triggered:Connect(function()
		triggered = true
	end)
	local function isTriggered()
		return triggered
	end

	-- No line-of-sight check for our attempt. Hold time and range stay as they are: the server
	-- checks both, so "showing" means we're really close enough and the hold has to be real.
	-- Restored afterwards.
	local saved = { RequiresLineOfSight = prompt.RequiresLineOfSight }
	prompt.RequiresLineOfSight = false
	PromptRestores[prompt] = saved

	local worked
	for index, approach in approaches do
		checkFarm()
		moveTo(promptStandPoint(position, approach[1], approach[2]), position)
		local here = getMyRoot()
		if here then
			faceTowards(here, position)
		end

		worked = withCameraAt(function()
			return position
		end, function()
			local shown = waitFor(function()
				return ShownPrompts[prompt] == true
			end, 1)
			local myRoot = getMyRoot()
			local gap = myRoot and (myRoot.Position - position).Magnitude or -1
			local last = index == #approaches
			farmLog("%s from %s: showing=%s, %.1f studs away (range %.0f), aim %.2f (1 = centered)", label,
				approach[3], tostring(shown), gap, prompt.MaxActivationDistance, cameraAimAt(position))
			if not shown and not last then
				farmLog("%s isn't showing; moving closer", label)
				return nil
			end
			if not shown then
				farmWarn("%s never showed; triggering it anyway", label)
			end
			local method = firePrompt(prompt, label, isTriggered)
			if method then
				return method
			end
			-- It showed and still wouldn't fire: getting closer won't change that
			if shown then
				return false
			end
			return nil
		end)
		if worked ~= nil then
			break -- fired (worked is the method) or it showed but wouldn't fire (false)
		end
	end

	for name, value in saved do
		prompt[name] = value
	end
	PromptRestores[prompt] = nil
	triggerConnection:Disconnect()

	if not worked then
		local myRoot = getMyRoot()
		farmWarn("%s prompt never triggered (you %.1f studs away, showing=%s, Enabled=%s)", label,
			myRoot and (myRoot.Position - position).Magnitude or -1, tostring(ShownPrompts[prompt] == true),
			tostring(prompt.Enabled))
	end
	return worked and true or false
end

-- Drops into a zone the way a player would: face it, look down at the middle of its floor, then
-- let go (`drop` does the letting go and returns the item). Waits for the item to land and says
-- whether it came to rest inside the zone; one the zone takes away (sold) counts as inside.
local function dropLookingAt(zone, drop, aimPoint)
	local floorPoint = aimPoint or Vector3.new(zone.Center.X, zone.Min.Y, zone.Center.Z)
	local root = getMyRoot()
	if root then
		faceTowards(root, floorPoint)
	end
	local item = withCameraAt(function()
		return floorPoint
	end, function()
		task.wait(0.15)
		farmLog("looking down at the zone (aim %.2f)", cameraAimAt(floorPoint))
		return drop()
	end, 4)
	if not item then
		return false
	end

	task.wait(0.3) -- let it start falling
	waitFor(function()
		local primary = item.PrimaryPart
		return not item.Parent or not primary or primary.AssemblyLinearVelocity.Magnitude < 0.5
	end, 2)
	task.wait(0.6) -- once it's the server's again, its real resting place reaches us
	if not item.Parent then
		return true
	end
	local primary = item.PrimaryPart
	return primary ~= nil and isInsideZone(primary.Position, zone)
end

-- Puts a loose item back into the hotbar through LootClient (aimed at it); set up next to
-- farmGrab, where the LootClient helpers live
local restashItem

-- An item that landed outside the zone: pick it back up and set it inside
local function placeAgain(item, zone, label, floorPoint)
	local primary = item.PrimaryPart
	farmLog("%s landed at %s, outside the %s; placing it in", item.Name,
		primary and fmtVec(primary.Position) or "?", label)
	if primary and grabItem(item) then
		placeInZone(item, zone, floorPoint)
	else
		farmWarn("couldn't pick %s back up to place it", item.Name)
	end
end

-- The middle of the sell box's Floor part, on its top surface: where sold loot goes
local SELL_FLOOR = { "Hideout", "SellBox", "Floor" }
local function sellFloorPoint()
	local floor = getFolder(SELL_FLOOR)
	if floor and floor:IsA("BasePart") then
		return floor.Position + floor.CFrame.UpVector * (floor.Size.Y / 2)
	end
	return nil
end

-- Loot inside a zone right now, and a "Wallet ($50), Phone ($75)" list of it
local function zoneLoot(zone)
	local folder = getLootFolder()
	local items, names = {}, {}
	for _, item in zone and folder and folder:GetChildren() or {} do
		if item.PrimaryPart and isInsideZone(item.PrimaryPart.Position, zone) then
			table.insert(items, item)
			table.insert(names, ("%s ($%s)"):format(item:GetAttribute("DisplayName") or item.Name,
				tostring(item:GetAttribute("Value") or 0)))
		end
	end
	return items, table.concat(names, ", ")
end

local function logSellZone(when)
	local zone = getZone(SELL_ZONE)
	if not zone then
		farmWarn("%s: sell zone not found at workspace.%s", when, table.concat(SELL_ZONE, "."))
		return 0
	end
	local items, names = zoneLoot(zone)
	farmLog("%s: workspace.%s holds %d item(s)%s", when, table.concat(SELL_ZONE, "."), #items,
		#items > 0 and (": " .. names) or "")
	return #items
end

-- Puts what you're holding, then every stashed item, into a zone. Stashed items drop right in
-- front of you, so we stand at the zone's edge (inside the trucks' cargo zones) facing it.
local function emptyInto(path, label)
	local zone = waitForZone(path, 10)
	if not zone then
		farmWarn("%s zone not found at workspace.%s", label, table.concat(path, "."))
		return 0
	end
	farmLog("emptying into %s: holding=%s hotbar=%d", label, tostring(getHeldLoot() ~= nil), countStash())
	local isSell = path == SELL_ZONE

	-- Stashed items drop at your feet, so stand inside the zone: on the sell box floor, 40% of
	-- the way in (it's small), or 70% in for the trucks. If the inside can't be reached, stand
	-- right at the edge (1 stud out) facing in.
	local reached = moveTo(zoneStandPoint(zone, isSell and 0.4 or 0.7), zone.Center)
	if not reached then
		farmLog("couldn't stand inside the %s; trying its edge", label)
		reached = moveTo(zoneStandPoint(zone, nil, 1), zone.Center)
	end
	if not reached then
		farmWarn("couldn't get to the %s; keeping %d item(s) in the hotbar", label, countStash())
		return 0
	end

	-- At the hideout everything goes onto the sell box's Floor; the SellZone around it is what
	-- decides whether an item is in
	local floorPoint = isSell and sellFloorPoint() or nil
	if isSell and not floorPoint then
		farmWarn("sell box floor not found at workspace.%s; aiming at the sell zone instead",
			table.concat(SELL_FLOOR, "."))
	end

	-- An item that landed outside: put it back in the hotbar the game's way and drop it again
	-- from deeper inside. Moving it ourselves only moves it on our screen (the server still has
	-- it where it fell, so the lever sold nothing), so that's only the last resort.
	local redrops = 0
	local function afterDrop(item, inside, what)
		farmLog("dropped %s %s %s", what, describeItem(item), inside and ("into the " .. label) or "outside the zone")
		if not inside then
			if redrops < 4 and restashItem and restashItem(item) then
				redrops = redrops + 1
				farmLog("put %s back in the hotbar; dropping it again from further in (redrop %d)", item.Name, redrops)
				moveTo(zoneStandPoint(zone, 0.15), zone.Center)
				return false -- back in the hotbar: the loop drops it again
			end
			placeAgain(item, zone, label, floorPoint)
		end
		if isSell then
			logSellZone("after dropping " .. item.Name)
		end
		return true
	end

	local count = 0
	local held = getHeldLoot()
	if held then
		local inside = dropLookingAt(zone, function()
			-- a carried item follows the camera's aim, so give it a moment to swing over the zone
			task.wait(0.4)
			LootRelease:FireServer()
			return held
		end, floorPoint)
		if afterDrop(held, inside, "held") then
			count = count + 1
		end
	end
	for _ = 1, 60 do
		checkFarm()
		local tool = findStashedLoot()
		if not tool then
			break
		end
		local item
		local inside = dropLookingAt(zone, function()
			local caught, inHands = catchStashedDrop(tool)
			if caught and inHands then
				LootRelease:FireServer() -- the server handed it to us: let go over the zone
			end
			item = caught
			return caught
		end, floorPoint)
		if not item then
			farmWarn("DropStashed for %s gave no item (hotbar %d left)", tool.Name, countStash())
			break
		end
		if afterDrop(item, inside, "stashed") then
			count = count + 1
		end
	end
	farmLog("emptied %d item(s) into %s; hotbar now %d", count, label, countStash())
	return count
end

-- People who can catch you: cops (workspace.Police) and security guards (workspace.Guards)
local function npcEye(npc)
	return npc:IsA("Model") and (npc:FindFirstChild("Head") or npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart)
end

local function livingIn(folderName)
	local folder = workspace:FindFirstChild(folderName)
	local npcs = {}
	for _, npc in folder and folder:GetChildren() or {} do
		local eye = npcEye(npc)
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		if eye and (not humanoid or humanoid.Health > 0) then
			table.insert(npcs, npc)
		end
	end
	return npcs
end

local function livingCops()
	return livingIn("Police")
end

local function livingGuards()
	return livingIn("Guards")
end

local function nearestOf(npcs, position)
	local best, bestDistance = nil, math.huge
	for _, npc in npcs do
		local distance = (npcEye(npc).Position - position).Magnitude
		if distance < bestDistance then
			best, bestDistance = npc, distance
		end
	end
	return best, bestDistance
end

local function nearestCop(position)
	return nearestOf(livingCops(), position)
end

local ThreatSightParams = RaycastParams.new()
ThreatSightParams.FilterType = Enum.RaycastFilterType.Exclude
ThreatSightParams.RespectCanCollide = true

-- Whether any of `npcs` has a clear line to a point at head height (glass doesn't hide you)
local function seenBy(position, npcs)
	ThreatSightParams.FilterDescendantsInstances = { LocalPlayer.Character, getLootFolder(),
		workspace:FindFirstChild("Police"), workspace:FindFirstChild("Guards") }
	local head = position + Vector3.new(0, 1.5, 0)
	for _, npc in npcs do
		local eye = npcEye(npc).Position
		if (eye - head).Magnitude < 150 then
			if not workspace:Raycast(eye, head - eye, ThreatSightParams) then
				return true
			end
		end
	end
	return false
end

-- A reachable spot out of sight of `threats` (the cops by default), as far from them as possible.
-- Candidates ring us at 25/50/80 studs; the best few by (hidden, distance) are checked for a
-- route, and the first with one wins.
local function hidingSpot(threats)
	local root = getMyRoot()
	if not root then
		return nil
	end
	threats = threats or livingCops()
	local candidates = {}
	for _, radius in { 25, 50, 80 } do
		for step = 0, 11 do
			local dir = rotateFlat(Vector3.new(1, 0, 0), step * 30)
			local spot = standingAt(root.Position + Vector3.new(0, 10, 0) + dir * radius)
			local _, threatDistance = nearestOf(threats, spot)
			local hidden = not seenBy(spot, threats)
			table.insert(candidates, {
				Spot = spot,
				Distance = threatDistance,
				Hidden = hidden,
				Score = (hidden and 1000 or 0) + math.min(threatDistance, 300),
			})
		end
	end
	table.sort(candidates, function(a, b)
		return a.Score > b.Score
	end)
	for i = 1, math.min(8, #candidates) do
		local candidate = candidates[i]
		if computePath(root.Position, candidate.Spot) then
			return candidate.Spot, candidate.Distance, candidate.Hidden
		end
	end
	return nil
end

-- Nearest liftable loot that isn't already in a truck or the sell box, on the town side of the map
local function findFarmLoot()
	local folder = getLootFolder()
	local root = getMyRoot()
	if not (folder and root) then
		return nil
	end
	local townZone, hideoutZone = getZone(CARGO_ZONE), getZone(HIDEOUT_CARGO_ZONE)
	local zones = { townZone, hideoutZone, getZone(SELL_ZONE) }

	local guards = Settings.AvoidGuards and livingGuards() or {}
	local now = os.clock()
	local best, bestDistance, nearGuards = nil, math.huge, 0
	for _, item in folder:GetChildren() do
		local primary = item.PrimaryPart
		local value = item:GetAttribute("FreeValue") or item:GetAttribute("Value") or 0
		if primary and value >= Settings.MinLootValue and not item:GetAttribute("HeldBy")
			and (RecentLoot[item] or 0) < now and canLift(item) then
			local position = primary.Position
			local skip = false
			for _, zone in zones do
				skip = skip or isInsideZone(position, zone)
			end
			if townZone and hideoutZone then
				skip = skip or (hideoutZone.Center - position).Magnitude < (townZone.Center - position).Magnitude
			end
			-- Security guards down you within a second of spotting you (the Mansion), so leave
			-- whatever they're standing near
			if not skip and #guards > 0 then
				local _, guardDistance = nearestOf(guards, position)
				if guardDistance < Settings.GuardRadius then
					skip = true
					nearGuards = nearGuards + 1
				end
			end
			local distance = (position - root.Position).Magnitude
			if not skip and distance < bestDistance then
				best, bestDistance = item, distance
			end
		end
	end
	return best, bestDistance, nearGuards
end

local function attributesText(instance)
	local parts = {}
	for name, value in instance:GetAttributes() do
		table.insert(parts, name .. "=" .. tostring(value))
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, " ") or "(none)"
end

local SightParams = RaycastParams.new()
SightParams.FilterType = Enum.RaycastFilterType.Exclude
SightParams.RespectCanCollide = true -- invisible room triggers and zones don't block the view

-- Nothing solid between `from` and the item (glass and walls count; the item itself doesn't)
local function clearViewOf(from, item)
	SightParams.FilterDescendantsInstances = { LocalPlayer.Character }
	local target = item.PrimaryPart.Position
	local hit = workspace:Raycast(from, target - from, SightParams)
	return hit == nil or hit.Instance:IsDescendantOf(item), hit and hit.Instance
end

-- A spot beside the item with real floor under it, on the item's level (it may sit on a shelf up
-- to 7 studs above that floor) and a clear line from head height to the item: the server won't
-- hand over loot through a shelf side, wall or window. Tries our side first, then around it.
local function itemStandPoint(item)
	local target = item.PrimaryPart.Position
	local root = getMyRoot()
	local toUs = root and flat(root.Position - target)
	local first = toUs and toUs.Magnitude > 0.1 and toUs.Unit or Vector3.new(1, 0, 0)
	local height = rootHeight()
	GroundParams.FilterDescendantsInstances = { LocalPlayer.Character, getLootFolder() }

	for _, distance in { 2.5, 1.5, 3.5 } do
		for _, degrees in { 0, 45, -45, 90, -90, 135, -135, 180 } do
			local dir = rotateFlat(first, degrees)
			local probe = target + dir * distance
			local floor = workspace:Raycast(probe + Vector3.new(0, 1.5, 0), Vector3.new(0, -40, 0), GroundParams)
			if floor then
				local floorY = floor.Position.Y
				local level = target.Y - floorY <= 7 and floorY - target.Y <= 2
				local stand = floor.Position + Vector3.new(0, height, 0)
				local eye = stand + Vector3.new(0, 1.5, 0)
				if level and clearViewOf(eye, item) then
					return stand, degrees, distance
				end
			end
		end
	end
	return nil
end

-- Stand beside the item where we can see it, facing it
local function approachItem(item)
	local target = item.PrimaryPart.Position
	local stand, degrees, distance = itemStandPoint(item)
	if stand then
		if degrees ~= 0 or distance ~= 2.5 then
			farmLog("standing spot for %s: %d degrees around, %.1f studs away (clear view)", item.Name, degrees, distance)
		end
		return moveTo(stand, target)
	end
	local root = getMyRoot()
	local toUs = root and flat(root.Position - target)
	local side = toUs and toUs.Magnitude > 0.1 and toUs.Unit or Vector3.new(1, 0, 0)
	farmWarn("no spot with a clear view of %s found; standing on our side anyway", item.Name)
	return moveTo(standingAt(target + side * 2.5), target)
end

-- LootClient's Action BindableEvent: Fire("Stash") grabs whatever the camera is aimed at and
-- stashes it once held (the same as pressing the stash key)
local LootAction
local function getLootAction()
	if LootAction and LootAction.Parent then
		return LootAction
	end
	LootAction = nil
	for _, container in { LocalPlayer:FindFirstChild("PlayerScripts"), LocalPlayer.Character,
		LocalPlayer:FindFirstChild("PlayerGui") } do
		local client = container and container:FindFirstChild("LootClient", true)
		local action = client and client:FindFirstChild("Action")
		if action and action:IsA("BindableEvent") then
			LootAction = action
			farmLog("found LootClient action at %s", action:GetFullName())
			break
		end
	end
	return LootAction
end

-- Same as LootClient.lootFrom: the Loot-tagged model a hit part belongs to
local function lootFromPart(part)
	local model = part and part:FindFirstAncestorWhichIsA("Model")
	while model and not CollectionService:HasTag(model, "Loot") do
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return model
end

-- Replays LootClient.lookTarget's ray (12 studs from the camera) to see what it would hover
local function cameraRayHit()
	local camera = workspace.CurrentCamera
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 12, params)
	return result and result.Instance, result and result.Distance
end

local function withCameraOn(item, body)
	return withCameraAt(function()
		return item.PrimaryPart and item.PrimaryPart.Position
	end, body)
end

-- Display cases (Mansion pedestals, store counters) have a prompt tagged DisplayCasePrompt.
-- While one is in view, LootClient's Stash does nothing (its caseAhead check), and the server
-- won't hand over what's inside, so open the case first.
local function openDisplayCase(item)
	local position = item.PrimaryPart.Position
	local best, bestDistance = nil, 10
	for _, prompt in CollectionService:GetTagged("DisplayCasePrompt") do
		local part = prompt:IsA("ProximityPrompt") and prompt.Enabled and prompt.Parent
		if part and part:IsA("BasePart") then
			local distance = (part.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = prompt, distance
			end
		end
	end
	if not best then
		return false
	end
	farmLog("%s is in a display case (%s, %.1f studs away): opening it first", item.Name,
		best:GetFullName(), bestDistance)
	triggerPrompt(best, "display case")
	waitFor(function()
		return not best.Enabled or not best.Parent
	end, best.HoldDuration + 2)
	farmLog("display case prompt after opening: Enabled=%s", tostring(best.Parent and best.Enabled))
	return true
end

-- Teleport to the item, give the server time to see us there, aim the camera at it and let the
-- game's own code grab it. Returns "held" (we're carrying it), "gone" (it left workspace.Loot,
-- e.g. grabbed and stashed already) or "failed".
restashItem = function(item)
	local action = getLootAction()
	local folder = getLootFolder()
	if not (action and folder and item.PrimaryPart and isStashable(item)) then
		return false
	end
	return withCameraOn(item, function()
		task.wait(0.15)
		if lootFromPart((cameraRayHit())) ~= item then
			return false
		end
		action:Fire("Stash")
		return waitFor(function()
			return item.Parent ~= folder
		end, 2)
	end)
end

local function farmGrab(item)
	local folder = getLootFolder()
	local grabStarted = os.clock()
	local function spotted()
		return Settings.AvoidGuards and Farm.SpottedAt > grabStarted
	end
	for attempt = 1, Settings.GrabAttempts do
		checkFarm()
		if Settings.LeaveOnAlarm and Farm.AlarmAt > (Farm.CollectStartedAt or math.huge) then
			farmLog("alarm went off; leaving %s", item.Name)
			return "alarm"
		end
		if spotted() then
			farmWarn("security spotted you going for %s; backing off", item.Name)
			return "spotted"
		end
		if item.Parent ~= folder then
			farmLog("%s disappeared before attempt %d; counting it as collected", item.Name, attempt)
			return "gone"
		end
		if not item.PrimaryPart then
			farmWarn("%s has no PrimaryPart; skipping", item.Name)
			return "failed"
		end

		-- Close with a clear view (the item next to the last one, or a retry of one the game
		-- already saw): grab from right here. Too far, or something in the way: move to a spot
		-- that can see it first.
		local root = getMyRoot()
		local gap = root and (root.Position - item.PrimaryPart.Position).Magnitude or math.huge
		local head = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Head")
		local inView, blocker = false, nil
		if head then
			inView, blocker = clearViewOf(head.Position, item)
		end
		if gap > 8 or not inView then
			if gap <= 8 and blocker then
				farmLog("%s is blocked by %s from here; repositioning", item.Name, blocker:GetFullName())
			end
			if not approachItem(item) then
				farmWarn("can't reach %s; skipping it for a while", item.Name)
				return "unreachable"
			end
			task.wait(Settings.GrabDelay)
			root = getMyRoot()
			gap = root and (root.Position - item.PrimaryPart.Position).Magnitude or math.huge
		elseif attempt > 1 then
			task.wait(0.3) -- already in place: just give the server a moment before re-firing
		end
		if gap <= 12 and openDisplayCase(item) then
			root = getMyRoot()
			gap = root and (root.Position - item.PrimaryPart.Position).Magnitude or math.huge
		end

		if gap > 12 then
			farmWarn("attempt %d/%d: still %.1f studs from %s; not grabbing",
				attempt, Settings.GrabAttempts, gap, item.Name)
		else
			local result = withCameraOn(item, function()
				task.wait(0.15) -- a couple of frames for LootClient to hover the item

				local hit, hitDistance = cameraRayHit()
				local hovered = lootFromPart(hit)
				local hud = LocalPlayer.PlayerGui:FindFirstChild("HUD")
				local hoverLabel = hud and hud:FindFirstChild("HoverLabel")
				local itemName = hoverLabel and hoverLabel:FindFirstChild("ItemName")
				farmLog("attempt %d/%d: %.1f studs from %s; camera ray hits %s at %s studs (%s); HUD hover=%s %q",
					attempt, Settings.GrabAttempts, gap, item.Name, hit and hit:GetFullName() or "nothing",
					hitDistance and ("%.1f"):format(hitDistance) or "-",
					hovered == item and "the target" or hovered and ("other loot " .. hovered.Name) or "not loot",
					tostring(hoverLabel and hoverLabel.Visible), itemName and itemName.Text or "")

				local action = getLootAction()
				local how
				if action and hovered == item and isStashable(item) then
					how = "LootClient Stash action"
					action:Fire("Stash")
				else
					-- heavy items can't go through Stash, and without the action we fall back to
					-- the remote, still aimed at the item like the game's own grab
					how = action and "LootGrab remote (heavy item or ray blocked)"
						or "LootGrab remote (LootClient action not found)"
					LootGrab:FireServer(item)
				end
				farmLog("grabbing %s via %s", item.Name, how)

				local deadline = os.clock() + 2
				while os.clock() < deadline do
					if spotted() then
						return "spotted"
					end
					if item.Parent ~= folder then
						farmLog("%s left workspace.Loot; counting it as collected", item.Name)
						return "gone"
					end
					if isHeldByMe(item) then
						farmLog("grabbed %s on attempt %d", item.Name, attempt)
						return "held"
					end
					task.wait(0.05)
				end
				return nil
			end)
			if result then
				return result
			end
		end
	end

	local root = getMyRoot()
	farmWarn("grab failed after %d attempts: %s at %s, you at %s; HeldBy=%s; parent=%s; attributes: %s",
		Settings.GrabAttempts, item.Name, fmtVec(item.PrimaryPart.Position),
		root and fmtVec(root.Position) or "?", tostring(item:GetAttribute("HeldBy")),
		item.Parent and item.Parent:GetFullName() or "nil", attributesText(item))
	local tags = CollectionService:GetTags(item)
	if #tags > 0 then
		farmLog("tags on %s: %s", item.Name, table.concat(tags, ", "))
	end
	return "failed"
end

local FarmStages = {}

function FarmStages.Locate()
	setStage("Locate")
	local location, toTown, toHideout = getLocation()
	farmLog("location=%s (town truck %.0f studs, hideout truck %.0f studs), traveling=%s",
		tostring(location), toTown, toHideout, tostring(Farm.Traveling))
	if Farm.Traveling then
		return "AwaitArrive"
	end
	if location == "Town" then
		return "Collect"
	end
	if location == "Hideout" then
		local cargo = getZone(HIDEOUT_CARGO_ZONE)
		local folder = getLootFolder()
		for _, item in folder and folder:GetChildren() or {} do
			if cargo and item.PrimaryPart and isInsideZone(item.PrimaryPart.Position, cargo) then
				farmLog("hideout truck still has loot; unloading first")
				return "Unload"
			end
		end
		if countStash() > 0 or getHeldLoot() then
			farmLog("carrying loot at the hideout; unloading first")
			return "Unload"
		end
		return "StartNight"
	end
	farmWarn("can't tell where you are (no Town.Truck.CargoZone or Hideout.Truck.CargoZone loaded); retrying")
	farmWait(function()
		return false
	end, 3)
	return "Locate"
end

function FarmStages.AwaitArrive()
	setStage("AwaitArrive")
	local since = Farm.LastArrive
	if farmWait(function()
		return Farm.LastArrive > since or not Farm.Traveling
	end, 120) then
		farmWait(function()
			return false
		end, 2) -- let the map settle after the loading screen
	else
		farmWarn("still traveling after 120s")
	end
	return "Locate"
end

-- Both trucks have a job board: "Start the Night" at the hideout, "Head Home" in town. A trigger
-- sometimes registers locally but starts nothing, while triggering again starts the trip right
-- away, so retry every 15s rather than waiting out one long timeout. True once we've departed.
local function useJobBoard(path, label)
	local departBefore = Farm.LastDepart
	local function departed()
		return Farm.LastDepart > departBefore
	end

	for attempt = 1, 8 do
		if departed() then
			break
		end
		local attemptStarted = os.clock()
		local function refusedWanted()
			return Farm.WantedToastAt > attemptStarted
		end
		local guisBefore = enabledGuis()
		farmLog("%s attempt %d/8", label, attempt)
		if not triggerPrompt(findPrompt(path), label) then
			farmWait(function()
				return false
			end, 5)
			return false
		end

		task.wait(1)
		for gui in enabledGuis() do
			if not guisBefore[gui] then
				farmLog("%s opened GUI %s", label, gui.Name)
			end
		end

		farmWait(function()
			return departed() or refusedWanted()
		end, 15)
		if departed() then
			break
		end
		if refusedWanted() then
			farmWarn("%s refused: you're wanted", label)
			return "wanted"
		end
		farmLog("no Travel Depart within 15s of %s attempt %d", label, attempt)
	end
	if departed() then
		farmLog("departed: %q", Farm.DepartText)
		return true
	end
	farmWarn("%s triggered 8 times without a Travel Depart", label)
	return false
end

function FarmStages.StartNight()
	setStage("StartNight")
	if useJobBoard(BOARD_PROMPT, "hideout job board") then
		return "AwaitArrive"
	end
	return "Locate"
end

function FarmStages.Collect()
	setStage("Collect")
	local collectStarted = os.clock()
	Farm.CollectStartedAt = collectStarted
	while true do
		checkFarm()
		if Farm.Traveling then
			farmLog("travel started while collecting (%q)", Farm.DepartText)
			return "AwaitArrive"
		end
		local blocked = blockedReason()
		if blocked then
			-- Getting arrested sends you back to the hideout, so work out where we are again
			-- once we're free instead of carrying on with town loot
			farmWarn("can't act (%s); waiting, then relocating", blocked)
			farmWait(canAct, 60)
			return "Locate"
		end
		if getLocation() == "Hideout" then
			farmLog("we're at the hideout, not in town; relocating")
			return "Locate"
		end
		if Settings.LeaveOnAlarm and Farm.AlarmAt > collectStarted then
			-- You're wanted from the moment of the alarm and can't head home until the search
			-- is over, so get out of sight now, before the cops arrive (15s)
			farmWarn("the cops were called (%.0fs ago); hiding until the search is over, then heading home",
				os.clock() - Farm.AlarmAt)
			return "LoseCops"
		end
		local endingAt = ReplicatedStorage:GetAttribute("EndingAt")
		if endingAt ~= nil then
			farmLog("night is ending (EndingAt=%s); heading back", tostring(endingAt))
			return "Return"
		end

		local item, distance, nearGuards = findFarmLoot()
		if not item then
			farmLog("no more loot found in town%s", nearGuards > 0
				and (" (%d item(s) left alone: a guard is within %d studs)"):format(nearGuards, Settings.GuardRadius) or "")
			return "Return"
		end
		farmLog("target %s at %.0f studs, %s", describeItem(item), distance, fmtVec(item.PrimaryPart.Position))
		RecentLoot[item] = os.clock() + 30 -- don't retry a failed item straight away

		local result = farmGrab(item)
		if result == "gone" then
			-- picked up and gone from workspace.Loot already (or someone else took it)
			Farm.Collected = Farm.Collected + 1
			updateFarmStatus()
		end
		if result == "unreachable" then
			RecentLoot[item] = os.clock() + 300 -- e.g. behind a locked door
		elseif result == "failed" then
			RecentLoot[item] = os.clock() + 120 -- don't keep circling back to the same stuck items
		elseif result == "alarm" then
			RecentLoot[item] = nil -- nothing wrong with it; the loop top heads off to hide
		elseif result == "spotted" then
			-- Leave this whole spot alone for a while and get out of the guards' sight
			local root = getMyRoot()
			local skipped = 0
			for _, other in root and getLootFolder():GetChildren() or {} do
				if other.PrimaryPart and (other.PrimaryPart.Position - root.Position).Magnitude < 40 then
					RecentLoot[other] = os.clock() + 180
					skipped = skipped + 1
				end
			end
			local spot, guardDistance, hidden = hidingSpot(livingGuards())
			farmWarn("security: skipping %d item(s) around here for 3 minutes; backing off to %s (%s, nearest guard %.0f studs)",
				skipped, spot and fmtVec(spot) or "nowhere", hidden and "out of sight" or "in sight", guardDistance or -1)
			if spot then
				moveTo(spot)
			end
		end
		if result ~= "held" then
			continue
		end
		Farm.Collected = Farm.Collected + 1
		updateFarmStatus()

		if isStashable(item) then
			Hotbar:FireServer("Stash")
			local stashed = waitFor(function()
				return item.Parent ~= getLootFolder() or not isHeldByMe(item)
			end, 1.5)
			if stashed then
				farmLog("stashed %s (hotbar %d)", item.Name, countStash())
			else
				farmLog("stash refused: hotbar full at %d item(s); unloading at the town truck", countStash())
				if emptyInto(CARGO_ZONE, "town truck") == 0 then
					farmWarn("couldn't unload into the town truck; heading back with what we have")
					return "Return"
				end
			end
		else
			farmLog("%s can't be stashed (heavy); carrying it to the town truck", item.Name)
			if emptyInto(CARGO_ZONE, "town truck") == 0 then
				farmWarn("couldn't carry %s to the town truck; heading back", item.Name)
				return "Return"
			end
		end
	end
end

-- Being wanted, as the game tracks it on the player: Wanted = true from the moment someone calls
-- the cops; PoliceArriveAt = when they get there (15s later); SearchEndsAt = when they give up,
-- which jumps back to 30s every time a cop sees you. Wanted is removed once the search ends.
local function wantedState()
	if LocalPlayer:GetAttribute("Wanted") == true then
		return true, "Wanted"
	end
	local now = workspace:GetServerTimeNow()
	for _, name in { "SearchEndsAt", "PoliceArriveAt" } do
		local value = LocalPlayer:GetAttribute(name)
		if type(value) == "number" and value > now then
			return true, name
		end
	end
	return false, "Wanted"
end

local function secondsUntil(attribute)
	local value = LocalPlayer:GetAttribute(attribute)
	if type(value) == "number" then
		return value - workspace:GetServerTimeNow()
	end
	return nil
end

-- Glides back along the breadcrumbs for up to `studs`: out of the building the way we came in
local function retraceTrail(studs)
	local root = getMyRoot()
	if not root or #Trail == 0 then
		return false
	end
	local points, travelled, last = {}, 0, root.Position
	while #Trail > 0 and travelled < studs do
		local point = table.remove(Trail).Position
		travelled = travelled + (point - last).Magnitude
		last = point
		table.insert(points, point)
	end
	farmLog("retracing %d breadcrumb(s), %.0f studs, back the way we came", #points, travelled)
	setNoclip(true) -- these spots were all reached before; only doors and glass lie between them
	local ok, why = glideThrough(root, points)
	setNoclip(false)
	if not ok then
		farmWarn("retrace interrupted: %s", why)
	end
	return ok
end

-- Straight away from `threat` (or up to 90 degrees off it), as far as a clear line allows: 20,
-- then 12, then 7 studs. Only doors and glass may be in the way, so it never cuts a wall.
local function fleeFrom(root, threat)
	local away = flat(root.Position - threat)
	away = away.Magnitude > 0.1 and away.Unit or root.CFrame.LookVector
	for _, distance in { 20, 12, 7 } do
		for _, degrees in { 0, 45, -45, 90, -90 } do
			local spot = standingAt(root.Position + rotateFlat(away, degrees) * distance + Vector3.new(0, 2, 0))
			if lineIsClear(root.Position, spot) and lineIsClear(root.Position + Vector3.new(0, 1.5, 0),
				spot + Vector3.new(0, 1.5, 0)) then
				farmLog("fleeing %.0f studs to %s", distance, fmtVec(spot))
				setNoclip(true)
				local ok, why = glideThrough(root, { spot })
				setNoclip(false)
				if not ok then
					farmWarn("flee interrupted: %s", why)
				end
				return ok
			end
		end
	end
	return false
end

-- "Lose the police before heading back": stay out of the cops' sight until the search gives up
-- (SearchEndsAt passes and Wanted is removed), moving to a hidden spot whenever one can see us or
-- gets close. With no route out (inside a closed building), retrace the way we came in first.
function FarmStages.LoseCops()
	setStage("LoseCops")
	local started, lastStatus = os.clock(), 0
	while os.clock() - started < 300 do
		checkFarm()
		local blocked = blockedReason()
		if blocked then
			farmWarn("caught while losing the cops (%s)", blocked)
			farmWait(canAct, 60)
			return "Locate"
		end
		local wanted = wantedState()
		if not wanted then
			farmLog("not wanted any more: the search is over")
			return "Return"
		end

		local root = getMyRoot()
		local cops = livingCops()
		local cop, copDistance = nearestCop(root and root.Position or Vector3.zero)
		local seen = root and seenBy(root.Position, cops)
		if os.clock() - lastStatus >= 3 then
			lastStatus = os.clock()
			local arrive, search = secondsUntil("PoliceArriveAt"), secondsUntil("SearchEndsAt")
			farmLog("wanted: %s; nearest cop %s %.0f studs, %s", arrive and ("cops arrive in %.0fs"):format(arrive)
				or search and ("search ends in %.0fs"):format(search) or "waiting for the search", cop and cop.Name or "-",
				copDistance, seen and "can SEE you" or "can't see you")
		end

		-- Cuffing takes about 3 seconds (CuffProgress 0 -> 1), and a cop this close is about to
		-- start: no time to plan, just get away
		local cuffing = (LocalPlayer:GetAttribute("CuffProgress") or 0) > 0
		if root and cop and (cuffing or copDistance < 15) then
			farmWarn("%s (%s %.0f studs away): breaking away", cuffing and "being CUFFED" or "a cop is right on you",
				cop.Name, copDistance)
			if not fleeFrom(root, npcEye(cop).Position) and not retraceTrail(25) then
				farmWarn("no clear way away from %s", cop.Name)
			end
		elseif root and (seen or copDistance < 40) then
			local spot, spotCopDistance, hidden = hidingSpot()
			if spot then
				farmLog("hiding at %s (%s, nearest cop %.0f studs from there)", fmtVec(spot),
					hidden and "out of sight" or "in sight, but farther", spotCopDistance)
				moveTo(spot)
			elseif not fleeFrom(root, cop and npcEye(cop).Position or root.Position) and not retraceTrail(40) then
				farmWarn("nowhere to hide from here and no breadcrumbs to retrace")
			end
		end
		farmWait(function()
			return false
		end, 0.5)
	end
	farmWarn("still wanted after 5 minutes; trying to head home anyway")
	return "Return"
end

-- Load the town truck, then "Head Home" on its job board. The game won't send you home while
-- you're wanted, so lose the police first.
function FarmStages.Return()
	setStage("Return")
	local wanted, attribute = wantedState()
	if wanted then
		farmWarn("%s says you're wanted; losing the cops first", attribute)
		return "LoseCops"
	end
	if getHeldLoot() or countStash() > 0 then
		emptyInto(CARGO_ZONE, "town truck")
	end
	local result = useJobBoard(TOWN_BOARD_PROMPT, "town job board")
	if result == "wanted" then
		return "LoseCops"
	elseif result then
		return "AwaitArrive"
	end
	farmWarn("couldn't head home from the town job board; checking for new loot")
	return "Collect"
end

function FarmStages.Unload()
	setStage("Unload")
	local cargo = waitForZone(HIDEOUT_CARGO_ZONE, 10)
	local sell = waitForZone(SELL_ZONE, 10)
	if not sell then
		farmWarn("sell zone not found at workspace.%s", table.concat(SELL_ZONE, "."))
		return "Locate"
	end
	if not cargo then
		farmWarn("hideout cargo zone not found at workspace.%s; selling what you carry", table.concat(HIDEOUT_CARGO_ZONE, "."))
		emptyInto(SELL_ZONE, "sell zone")
		return "Sell"
	end

	moveTo(zoneStandPoint(cargo), cargo.Center)
	local failed, moved = {}, 0
	for _ = 1, 150 do
		checkFarm()
		local folder = getLootFolder()
		local nextItem
		for _, item in folder and folder:GetChildren() or {} do
			local primary = item.PrimaryPart
			if primary and not failed[item] and isInsideZone(primary.Position, cargo)
				and (not item:GetAttribute("HeldBy") or isHeldByMe(item)) then
				if canLift(item) then
					nextItem = item
					break
				end
				failed[item] = true
				farmWarn("can't lift %s (Shop_Lifter %s); leaving it in the truck", describeItem(item),
					tostring(LocalPlayer:GetAttribute("Shop_Lifter")))
			end
		end
		if not nextItem then
			break
		end

		farmLog("picking up %s from the hideout truck", describeItem(nextItem))
		local result = farmGrab(nextItem)
		local needsTrip = false
		if result == "gone" then
			moved = moved + 1 -- the game's Stash action already put it in the hotbar
		elseif result ~= "held" then
			failed[nextItem] = true -- "failed" or "unreachable": don't pick it again this unload
		elseif not isStashable(nextItem) then
			moved = moved + 1
			needsTrip = true
			farmLog("%s is heavy; carrying it straight to the sell zone", nextItem.Name)
		else
			moved = moved + 1
			Hotbar:FireServer("Stash")
			needsTrip = not waitFor(function()
				return nextItem.Parent ~= folder or not isHeldByMe(nextItem)
			end, 1.5)
			if needsTrip then
				farmLog("hotbar full at %d; emptying into the sell zone first", countStash())
			end
		end
		if needsTrip then
			local sold = emptyInto(SELL_ZONE, "sell zone")
			if sold == 0 then
				farmWarn("couldn't reach the sell zone; retrying from Locate in 5s")
				farmWait(function()
					return false
				end, 5)
				return "Locate"
			end
			Farm.Sold = Farm.Sold + sold
			updateFarmStatus()
			moveTo(zoneStandPoint(cargo), cargo.Center)
		end
	end
	farmLog("hideout truck cleared: %d picked up, %d skipped", moved, (function()
		local n = 0
		for _ in failed do
			n = n + 1
		end
		return n
	end)())

	Farm.Sold = Farm.Sold + emptyInto(SELL_ZONE, "sell zone")
	updateFarmStatus()
	return "Sell"
end

-- Money isn't in leaderstats (only Level), so compare every number attribute on the player
local function numberAttributes()
	local values = {}
	for name, value in LocalPlayer:GetAttributes() do
		if type(value) == "number" then
			values[name] = value
		end
	end
	return values
end

-- Loot sitting in the sell zone right now
local function sellZoneLoot()
	return (zoneLoot(getZone(SELL_ZONE)))
end

function FarmStages.Sell()
	setStage("Sell")
	local before = numberAttributes()
	local waiting = logSellZone("before selling")

	-- The lever is a hold prompt too (0.2s): triggerPrompt holds it the full time. A sale takes
	-- the loot out of the zone, so pull again if it's all still there.
	for attempt = 1, 3 do
		checkFarm()
		triggerPrompt(findPrompt(SELL_LEVER_PROMPT), "sell lever")
		local sold = farmWait(function()
			return #sellZoneLoot() < waiting
		end, 3)
		if sold or waiting == 0 then
			logSellZone(("after sell lever attempt %d"):format(attempt))
			break
		end
		farmWarn("sell lever attempt %d: all %d item(s) still in the sell zone; pulling again", attempt, waiting)
	end
	farmWait(function()
		return false
	end, 1)
	local changes = {}
	for name, value in numberAttributes() do
		if before[name] ~= value then
			table.insert(changes, ("%s %s -> %s"):format(name, tostring(before[name]), tostring(value)))
		end
	end
	farmLog("after selling, player attributes changed: %s",
		#changes > 0 and table.concat(changes, ", ") or "nothing")
	Farm.Runs = Farm.Runs + 1
	updateFarmStatus()
	return "StartNight"
end

-- Alerts, always logged. The game's alerts arrive on the Notify remote: "SneakTip" pops up
-- SneakTipClient's "NPCS CAN HEAR YOU WALKING!" card, "Quota" plays MoneyRain's money rain, and
-- toasts come as a tone plus their text, e.g. ("Good", "Level up! LVL 6").
local NOTIFY_MEANINGS = {
	SneakTip = "NPCs can hear you walking (sneak to stay quiet)",
	Quota = "quota reached (money rain)",
}
local GOOD_TONES = { Good = true, Success = true, Info = true }

local function argsText(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		table.insert(parts, typeof(value) == "Instance" and value:GetFullName() or tostring(value))
	end
	return table.concat(parts, ", ")
end

ctx:Connect(Remotes:WaitForChild("Notify").OnClientEvent, function(kind, ...)
	if not EspFolder.Parent then
		return
	end
	if kind == "Alarm" then
		Farm.AlarmAt = os.clock() -- "Someone was disturbed and called the cops!"
	end
	local text = select("#", ...) > 0 and tostring((...)) or ""
	if text:lower():find("wanted", 1, true) then
		Farm.WantedToastAt = os.clock() -- "You're wanted - lose the police before heading back..."
	end
	if text:lower():find("security", 1, true) then
		Farm.SpottedAt = os.clock() -- "Security spotted you!": a guard is about to take you down
	end
	local meaning = NOTIFY_MEANINGS[kind]
	if meaning then
		local extra = select("#", ...) > 0 and (" [" .. argsText(...) .. "]") or ""
		pushLog(("ALERT %s: %s%s (stage %s)"):format(tostring(kind), meaning, extra, Farm.Stage),
			Enum.MessageType.MessageWarning)
	elseif select("#", ...) > 0 then
		-- a toast: show its text, as a warning unless it's good news
		pushLog(("ALERT %s: %s (stage %s)"):format(tostring(kind), argsText(...), Farm.Stage),
			GOOD_TONES[kind] and Enum.MessageType.MessageInfo or Enum.MessageType.MessageWarning)
	else
		pushLog(("ALERT %s (stage %s)"):format(tostring(kind), Farm.Stage), Enum.MessageType.MessageWarning)
	end
end)

-- Your own status changes: getting caught, knocked down, stunned or bitten
local STATUS_ATTRIBUTES = { "Arrested", "Downed", "BustedUntil", "StunnedUntil", "BittenUntil" }
for _, name in STATUS_ATTRIBUTES do
	ctx:Connect(LocalPlayer:GetAttributeChangedSignal(name), function()
		if not EspFolder.Parent then
			return
		end
		local value = LocalPlayer:GetAttribute(name)
		local text = tostring(value)
		if type(value) == "number" and value > 1e6 then -- a server timestamp: say how long
			text = ("%.1fs from now"):format(value - workspace:GetServerTimeNow())
		end
		local root = getMyRoot()
		pushLog(("ALERT %s -> %s at %s (stage %s)"):format(name, text, root and fmtVec(root.Position) or "?",
			Farm.Stage), Enum.MessageType.MessageWarning)
	end)
end

-- Every other attribute change on you and your character, so the log shows what the game tracks
-- (e.g. the name of the wanted flag). Sneaking flips constantly, so it's left out.
-- These change many times a second (or are covered elsewhere: LoseCops reports the search and
-- cuffing every 3 seconds), so they'd bury everything else
local NOISY_ATTRIBUTES = {
	Sneaking = true, CarryWeight = true, AimPitch = true, HeldFromHotbar = true,
	PunchSide = true, Punches = true, SearchEndsAt = true, CuffProgress = true,
}
local wasCuffing = false
local function watchAttributes(holder, label)
	return ctx:Connect(holder.AttributeChanged, function(name)
		if not EspFolder.Parent then
			return
		end
		if name == "CuffProgress" then
			local cuffing = (holder:GetAttribute(name) or 0) > 0
			if cuffing and not wasCuffing then
				pushLog(("ALERT a cop started cuffing you (stage %s)"):format(Farm.Stage), Enum.MessageType.MessageWarning)
			end
			wasCuffing = cuffing
		end
		if NOISY_ATTRIBUTES[name] or table.find(STATUS_ATTRIBUTES, name) then
			return
		end
		local value = holder:GetAttribute(name)
		local text = tostring(value)
		if type(value) == "number" and value > 1e6 then
			text = ("%.1fs from now"):format(value - workspace:GetServerTimeNow())
		end
		local important = name:lower():find("wanted", 1, true) or name:lower():find("heat", 1, true)
		if important then
			pushLog(("ALERT %s.%s -> %s (stage %s)"):format(label, name, text, Farm.Stage),
				Enum.MessageType.MessageWarning)
		else
			farmLog("%s attribute %s -> %s", label, name, text)
		end
	end)
end
watchAttributes(LocalPlayer, "player")
-- Every hit you take, with where you were: at the hideout, whether you were inside the compound
-- safe zone, and how far off the sniper is
local function watchHealth(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end
	local last = humanoid.Health
	ctx:Connect(humanoid.HealthChanged, function(health)
		if not EspFolder.Parent then
			return
		end
		if health < last - 0.5 then
			local root = getMyRoot()
			local where = root and fmtVec(root.Position) or "?"
			local safe = safeZonePart()
			local extra = ""
			if root and guardedBySafeZone(safe, root.Position) then
				local sniper = getFolder({ "Hideout", "Sniper" })
				local sniperPart = sniper and (sniper:IsA("BasePart") and sniper or sniper:FindFirstChildWhichIsA("BasePart", true))
				extra = (", %s the compound safe zone%s"):format(
					insideSafeZone(safe, root.Position) and "INSIDE" or "OUTSIDE",
					sniperPart and (", sniper %.0f studs away"):format((sniperPart.Position - root.Position).Magnitude) or "")
			end
			pushLog(("ALERT took %.0f damage (health %.0f/%.0f) at %s%s (stage %s)"):format(last - health, health,
				humanoid.MaxHealth, where, extra, Farm.Stage), Enum.MessageType.MessageWarning)
		end
		last = health
	end)
end

local function watchCharacter(character)
	watchAttributes(character, "character")
	task.spawn(watchHealth, character)
end
if LocalPlayer.Character then
	watchCharacter(LocalPlayer.Character)
end
ctx:Connect(LocalPlayer.CharacterAdded, watchCharacter)

-- Travel events tell the farm when it's on the loading screen and when it has arrived
ctx:Connect(Remotes:WaitForChild("Travel").OnClientEvent, function(kind, text, look)
	if not EspFolder.Parent then
		return
	end
	if kind == "Depart" then
		Farm.Traveling, Farm.LastDepart, Farm.DepartText = true, os.clock(), tostring(text or "")
	elseif kind == "Arrive" then
		Farm.Traveling, Farm.LastArrive = false, os.clock()
		table.clear(Trail) -- a new place: the old breadcrumbs lead nowhere here
	end
	if Settings.AutoFarm then
		farmLog("Travel event: %s text=%q look=%s", tostring(kind), tostring(text), tostring(look))
	end
end)

task.spawn(function()
	while EspFolder.Parent do
		if Settings.AutoFarm then
			local stage = Farm.NextStage or "Locate"
			LootBusy = true -- Auto Collect and Auto Drop stand aside
			local ok, result = pcall(FarmStages[stage])
			LootBusy = false
			if ok then
				Farm.NextStage = result
			elseif result == FARM_STOPPED then
				farmLog("stopped during %s", stage)
				Farm.NextStage = nil
			else
				farmWarn("stage %s errored: %s", stage, tostring(result))
				Farm.NextStage = "Locate"
				task.wait(2)
			end
		else
			if Farm.Stage ~= "Idle" then
				Farm.Stage = "Idle"
				updateFarmStatus()
			end
			task.wait(0.5)
		end
	end
end)

--------------------------------------------------------------------------------
-- Auto Punch
--------------------------------------------------------------------------------

-- Same checks as PunchClient.canPunch: alive, not seated, no tool out, not stunned, round running
local function canPunch()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (humanoid and humanoid.Health > 0 and not humanoid.Sit) then
		return false
	end
	if character:FindFirstChildOfClass("Tool") or ReplicatedStorage:GetAttribute("EndingAt") ~= nil then
		return false
	end
	return (LocalPlayer:GetAttribute("StunnedUntil") or 0) <= workspace:GetServerTimeNow()
end

-- Alive and not already knocked out (LootClient treats KnockedOutUntil as lying down)
local function isPunchable(npc)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	return humanoid and humanoid.Health > 0
		and (npc:GetAttribute("KnockedOutUntil") or 0) <= workspace:GetServerTimeNow()
end

-- MeleeAim.target hands the server a body part (any BasePart child of the NPC except the
-- HumanoidRootPart), so send one directly instead of aiming the camera
local function getPunchPart(npc)
	local part = npc:FindFirstChild("Head") or npc:FindFirstChild("UpperTorso") or npc:FindFirstChild("Torso")
	if part and part:IsA("BasePart") then
		return part
	end
	for _, child in npc:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			return child
		end
	end
	return nil
end

-- Same as MeleeAim.inSight: nothing collidable between us and the part (ignoring us, loot and the NPC)
local function inSight(origin, part, npc)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character, workspace.CurrentCamera, getLootFolder(), npc }
	params.RespectCanCollide = true
	return workspace:Raycast(origin, part.Position - origin, params) == nil
end

-- Reach is measured from your head, which is where the camera ray starts in first person
local function findPunchTarget(origin)
	local folders = { "Npcs", "Guards" }
	if Settings.PunchPolice then
		table.insert(folders, "Police")
	end

	local best, bestDistance = nil, Settings.PunchRange
	for _, name in folders do
		local folder = workspace:FindFirstChild(name)
		for _, npc in folder and folder:GetChildren() or {} do
			local part = npc:IsA("Model") and isPunchable(npc) and getPunchPart(npc)
			if part then
				local distance = (part.Position - origin).Magnitude
				if distance <= bestDistance and inSight(origin, part, npc) then
					best, bestDistance = part, distance
				end
			end
		end
	end
	return best
end

task.spawn(function()
	local lastPunch = 0
	while EspFolder.Parent do
		local character = LocalPlayer.Character
		local head = character and character:FindFirstChild("Head")
		if Settings.AutoPunch and head and os.clock() - lastPunch >= 0.45 and canPunch() then
			local part = findPunchTarget(head.Position)
			if part then
				lastPunch = os.clock()
				Punch:FireServer(part)
			end
		end
		task.wait(0.05)
	end
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local Main = ctx:SubTab("Main", "Lucide:house")
local FarmTab = ctx:SubTab("Farm", "Lucide:coins")
local Visuals = ctx:SubTab("Visuals", "Lucide:eye")

FarmTab:AddSection("Auto Farm", "Lucide:tractor")
FarmTab:AddToggle({
	Text = "Auto Farm",
	Flag = "AutoFarm",
	Description = "Takes the job, loots houses, fills the truck, unloads at the hideout and sells, on repeat",
	Default = false,
	Callback = function(state)
		Settings.AutoFarm = state
		if state then
			farmLog("enabled (fireproximityprompt=%s)", tostring(fireproximityprompt ~= nil))
		end
	end,
})

FarmTab:AddToggle({
	Text = "Verbose Logs",
	Flag = "VerboseLogs",
	Description = "Logs every farm step to the Debug Console, warnings are always logged",
	Default = Settings.VerboseLogs,
	Callback = function(state)
		Settings.VerboseLogs = state
	end,
})

FarmTab:AddSlider({
	Text = "Grab Delay",
	Flag = "GrabDelay",
	Min = 0.1,
	Max = 2,
	Increment = 0.1,
	Default = Settings.GrabDelay,
	Suffix = "s",
	Callback = function(value)
		Settings.GrabDelay = value
	end,
})

FarmTab:AddSection("Movement", "Lucide:route")

FarmTab:AddToggle({
	Text = "Glide Movement",
	Flag = "GlideMovement",
	Description = "On glides along each route through doors, off really walks it and doors can block you",
	Default = Settings.GlideMovement,
	Callback = function(state)
		Settings.GlideMovement = state
	end,
})

FarmTab:AddToggle({
	Text = "Glide At Run Speed",
	Flag = "GlideAtRunSpeed",
	Description = "Glides as fast as you could sprint so the server accepts it, off uses Move Speed",
	Default = Settings.GlideAtRunSpeed,
	Callback = function(state)
		Settings.GlideAtRunSpeed = state
	end,
})

FarmTab:AddToggle({
	Text = "Noclip When Stuck",
	Flag = "NoclipWhenStuck",
	Description = "When a wall or door pushes you back, retry the move gliding with noclip",
	Default = Settings.NoclipWhenStuck,
	Callback = function(state)
		Settings.NoclipWhenStuck = state
	end,
})

FarmTab:AddToggle({
	Text = "Always Noclip",
	Flag = "AlwaysNoclip",
	Description = "Noclip on every glide, so the doors and glass a route passes through can't push you back",
	Default = Settings.AlwaysNoclip,
	Callback = function(state)
		Settings.AlwaysNoclip = state
	end,
})

FarmTab:AddSlider({
	Text = "Glide Speed",
	Description = "Percent of your run speed to glide at",
	Flag = "GlideSpeedPercent",
	Min = 50,
	Max = 100,
	Increment = 5,
	Default = Settings.GlideSpeedPercent,
	Suffix = "%",
	Callback = function(value)
		Settings.GlideSpeedPercent = value
	end,
})

FarmTab:AddSection("Safety", "Lucide:shield")

FarmTab:AddToggle({
	Text = "Avoid Guards",
	Flag = "AvoidGuards",
	Description = "Skip loot a security guard is near, and back off when security spots you",
	Default = Settings.AvoidGuards,
	Callback = function(state)
		Settings.AvoidGuards = state
	end,
})

FarmTab:AddSlider({
	Text = "Guard Radius",
	Flag = "GuardRadius",
	Min = 10,
	Max = 100,
	Increment = 5,
	Default = Settings.GuardRadius,
	Suffix = " studs",
	Callback = function(value)
		Settings.GuardRadius = value
	end,
})

FarmTab:AddToggle({
	Text = "Leave On Alarm",
	Flag = "LeaveOnAlarm",
	Description = "When someone calls the cops, load the truck and head home instead of getting arrested",
	Default = Settings.LeaveOnAlarm,
	Callback = function(state)
		Settings.LeaveOnAlarm = state
	end,
})

FarmTab:AddSection("Tuning", "Lucide:sliders-horizontal")

FarmTab:AddSlider({
	Text = "Min Loot Value",
	Description = "The farm only collects loot worth at least this much",
	Flag = "MinLootValue",
	Min = 1,
	Max = 500,
	Increment = 1,
	Default = Settings.MinLootValue,
	Suffix = " $",
	Callback = function(value)
		Settings.MinLootValue = value
	end,
})

FarmTab:AddSlider({
	Text = "Move Speed",
	Description = "Glide speed when Glide At Run Speed is off",
	Flag = "MoveSpeed",
	Min = 10,
	Max = 150,
	Increment = 5,
	Default = Settings.MoveSpeed,
	Suffix = " studs/s",
	Callback = function(value)
		Settings.MoveSpeed = value
	end,
})

FarmTab:AddSection("Status", "Lucide:activity")

FarmGrid = FarmTab:AddInfoGrid({
	Title = "Auto Farm",
	Description = "Current stage and totals since the hub started",
	Columns = 2,
	Items = {
		{ Label = "Stage", Value = Farm.Stage },
		{ Label = "Collected", Value = "0" },
		{ Label = "Sold", Value = "0" },
		{ Label = "Runs", Value = "0" },
	},
})

Main:AddSection("Stealth", "Lucide:footprints")

Main:AddToggle({
	Text = "Silent Walk",
	Flag = "SilentWalk",
	Description = "The server always thinks you're sneaking, so NPCs don't hear you at full speed",
	Default = false,
	Callback = function(state)
		Settings.SilentWalk = state
		Sneak:FireServer(state)
	end,
})

Main:AddToggle({
	Text = "Unlimited Stamina",
	Flag = "InfiniteStamina",
	Description = "Sprint forever and never get winded",
	Default = false,
	Callback = function(state)
		Settings.InfiniteStamina = state
		applyStamina(state)
	end,
})

Main:AddSection("Loot", "Lucide:hand-coins")

Main:AddToggle({
	Text = "Auto Collect Loot",
	Flag = "AutoCollect",
	Description = "Grabs stashable loot within range and puts it in your hotbar",
	Default = false,
	Callback = function(state)
		Settings.AutoCollect = state
	end,
})

Main:AddSlider({
	Text = "Collect Radius",
	Flag = "CollectRadius",
	Min = 4,
	Max = 30,
	Increment = 1,
	Default = Settings.CollectRadius,
	Suffix = " studs",
	Callback = function(value)
		Settings.CollectRadius = value
	end,
})

Main:AddToggle({
	Text = "Auto Drop To Truck",
	Flag = "AutoDrop",
	Description = "Loads your loot into the truck on depart and unloads it into the sell box on arrival",
	Default = false,
	Callback = function(state)
		Settings.AutoDrop = state
	end,
})

Main:AddSection("Combat", "Lucide:swords")

Main:AddToggle({
	Text = "Auto Punch",
	Flag = "AutoPunch",
	Description = "Punches the nearest resident or guard in range",
	Default = false,
	Callback = function(state)
		Settings.AutoPunch = state
	end,
})

Main:AddToggle({
	Text = "Punch Police",
	Flag = "PunchPolice",
	Description = "Auto Punch also targets police",
	Default = false,
	Callback = function(state)
		Settings.PunchPolice = state
	end,
})

Visuals:AddSection("ESP", "Lucide:scan-eye")

for _, category in Categories do
	Visuals:AddToggle({
		Text = category.Name .. " ESP",
		Flag = category.Key .. "Esp",
		Description = "Highlights " .. category.Name:lower() .. " through walls",
		Default = false,
		Callback = function(state)
			category.Enabled = state
			if not state then
				clearCategory(category)
			end
		end,
	})
end

Visuals:AddSection("Labels", "Lucide:tag")

Visuals:AddSlider({
	Text = "ESP Max Distance",
	Description = "Targets farther than this get no ESP",
	Flag = "EspMaxDistance",
	Min = 25,
	Max = 3000,
	Increment = 25,
	Default = Settings.EspMaxDistance,
	Suffix = " studs",
	Callback = function(value)
		Settings.EspMaxDistance = value
	end,
})

Visuals:AddToggle({
	Text = "Show Names",
	Flag = "ShowLabels",
	Description = "Name label above every ESP target (loot also shows its value)",
	Default = Settings.ShowLabels,
	Callback = function(state)
		Settings.ShowLabels = state
	end,
})

Visuals:AddToggle({
	Text = "Show Distance",
	Flag = "ShowDistance",
	Description = "Distance in studs under each name label",
	Default = Settings.ShowDistance,
	Callback = function(state)
		Settings.ShowDistance = state
	end,
})
