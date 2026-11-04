-- Prospecting
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- Remotes (captured with Cobalt)
--   <Pan>.Scripts.Pan     : InvokeServer()
--   <Pan>.Scripts.Collect : InvokeServer(1, false)
--   <Pan>.Scripts.Shake   : FireServer()
--   Shop.SellAll          : InvokeServer()
--   Shop.BuyItem          : InvokeServer(ShopItem, 1)
--   CustomBackpack.EquipRemote : FireServer(tool)
--   Quests.QuestCollect  : InvokeServer(npcName, { items })        -> success, count
--   Quests.CanStartQuest  : InvokeServer(questModule)               -> _, "Started" | ...
--   Quests.GetCurrentQuestStep : InvokeServer(questName)            -> { StepProgress = { ... } }
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShopRemotes = Remotes:WaitForChild("Shop")
local QuestRemotes = Remotes:WaitForChild("Quests")

local Settings = {
	PanDelay = 0.5,
	CollectDelay = 0.5,
	ShakeDelay = 0.3,
	SellDelay = 10,
	DailyDelay = 60,
	GeodeDelay = 2,
	ClaimDelay = 3,
	UseGeodeDelay = 2,
	FarmDelay = 0.3,
	FarmWashPercent = 100,
	AutoSellTrips = true,
	SellAtItems = 100,
	SellerName = "",
	SellerPosition = nil, -- Vector3 waypoint, takes priority over SellerName
	WaterWaypoint = nil,
	SandWaypoint = nil,
	QuestDelay = 5,
	AutoStartQuests = true,
	MaxActiveQuests = 10,
	QuestRadiusEnabled = true,
	QuestRadius = 250,
	QuestWalk = true,
	FarmWithQuests = false, -- Auto Farm also runs Auto Quest (off: dig, wash and sell only)
	BuyDelay = 2,
	BuyAmount = 1,
	BuyItem = "Plastic Pan",
	VerboseLogs = false,
}

-- Logs go to the hub's Debug Console. UI updates are queued and applied by one pump thread, because
-- some threads (loop threads, button callbacks) are not allowed to touch the library's ScreenGui.
local uiQueue = {}

local lastMessage

local function log(message, messageType)
	if message == lastMessage then return end
	lastMessage = message
	local level = "info"
	if messageType == Enum.MessageType.MessageWarning then
		level = "warn"
	elseif messageType == Enum.MessageType.MessageError then
		level = "error"
	end
	ctx.Log(tostring(message), level)
end

local function logVerbose(message)
	if Settings.VerboseLogs then log(message) end
end

-- Queues a :Set on a library control (label, textbox, toggle).
local function safeSet(control, ...)
	if not control then return false end
	local args = table.pack(...)
	table.insert(uiQueue, function() control:Set(table.unpack(args, 1, args.n)) end)
	return true
end

task.spawn(function()
	while ctx:Alive() do
		if #uiQueue > 0 then
			local batch = uiQueue
			uiQueue = {}
			for _, action in ipairs(batch) do
				local ok, err = pcall(action)
				if not ok then ctx.Log("UI update failed: " .. tostring(err), "warn") end
			end
		end
		task.wait(0.1)
	end
end)

-- Shown in the Farm tab's state label, so it is always clear what the bot is doing right now.
local statusLabel
local currentStatus = "Idle"

local function setStatus(text)
	if text == currentStatus then return end
	currentStatus = text
	safeSet(statusLabel, "State: " .. text)
end

-- Tool containers, character first. The game keeps most items in BackpackTwo rather than Backpack.
local function getContainers()
	return {
		LocalPlayer.Character,
		LocalPlayer:FindFirstChildOfClass("Backpack"),
		LocalPlayer:FindFirstChild("BackpackTwo"),
	}
end

local function getRemote(tool, remoteName)
	local scripts = tool:FindFirstChild("Scripts")
	return scripts and scripts:FindFirstChild(remoteName)
end

-- Finds a tool whose Scripts folder already has the remote.
local function findPan(remoteName)
	for _, container in ipairs(getContainers()) do
		for _, tool in ipairs(container and container:GetChildren() or {}) do
			if tool:IsA("Tool") then
				local remote = getRemote(tool, remoteName)
				if remote then return tool, remote end
			end
		end
	end
	return nil
end

-- Fallback for pans that only get their Scripts folder once equipped: a stored tool named "...Pan".
local function findStoredPan()
	for _, container in ipairs(getContainers()) do
		if container and container ~= LocalPlayer.Character then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") and tool.Name:match("Pan$") then return tool end
			end
		end
	end
	return nil
end

local function describeTools()
	local parts = {}
	for _, container in ipairs(getContainers()) do
		local names = {}
		for _, tool in ipairs(container and container:GetChildren() or {}) do
			if tool:IsA("Tool") then table.insert(names, tool.Name) end
		end
		table.insert(parts, (container and container.Name or "?") .. "=[" .. table.concat(names, ", ") .. "]")
	end
	return table.concat(parts, " ")
end

-- Returns the remote on the player's pan, equipping the pan from storage first if needed.
local function getPanScript(remoteName)
	local tool, remote = findPan(remoteName)
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not tool then
		tool = findStoredPan()
		if not (tool and humanoid) then return nil end
	end

	if tool.Parent ~= character then
		-- The game's custom backpack equips through its own remote; only fire it for a stored
		-- tool, since firing it for an equipped one is likely to unequip it.
		local equip = Remotes:FindFirstChild("CustomBackpack")
		equip = equip and equip:FindFirstChild("EquipRemote")
		if equip then
			equip:FireServer(tool)
			for _ = 1, 10 do
				if tool.Parent == character then break end
				task.wait(0.1)
			end
		end
		if tool.Parent ~= character and humanoid then
			humanoid:EquipTool(tool)
			task.wait(0.2)
		end
		if tool.Parent ~= character then
			log("Failed to equip " .. tool.Name, Enum.MessageType.MessageWarning)
			return nil
		end
		log("Equipped " .. tool.Name)
	end

	remote = remote or getRemote(tool, remoteName)
	if not remote then
		local scripts = tool:WaitForChild("Scripts", 2)
		remote = scripts and scripts:WaitForChild(remoteName, 2)
	end
	if not remote then return nil end
	return remote, tool
end

local function getShopItem()
	local town = workspace:FindFirstChild("Purchasable")
	town = town and town:FindFirstChild("StarterTown")
	local item = town and town:FindFirstChild(Settings.BuyItem)
	return item and item:FindFirstChild("ShopItem")
end

-- Each loop has a run token; flipping the toggle off invalidates it so the loop exits cleanly.
local tokens = {}
local enabledLoops = {}

local function jitter(delay)
	return delay * (0.9 + math.random() * 0.2)
end

local function startLoop(key, delayKey, step)
	tokens[key] = (tokens[key] or 0) + 1
	local token = tokens[key]
	task.spawn(function()
		while tokens[key] == token do
			local ok, err = pcall(step)
			if not ok then
				log(key .. " error: " .. tostring(err), Enum.MessageType.MessageError)
			end
			task.wait(jitter(Settings[delayKey]))
		end
	end)
end

local function stopLoop(key)
	tokens[key] = (tokens[key] or 0) + 1
end

local function bindToggle(key, delayKey, step)
	return function(enabled)
		enabledLoops[key] = enabled
		log(key .. (enabled and " enabled" or " disabled"))
		if enabled then
			startLoop(key, delayKey, step)
		else
			stopLoop(key)
		end
	end
end

local function usePan(remoteName, invoke)
	local remote, tool = getPanScript(remoteName)
	if not remote then
		log(remoteName .. ": no pan with that remote found. Tools: " .. describeTools(), Enum.MessageType.MessageWarning)
		return
	end
	local result = invoke(remote)
	logVerbose(remoteName .. " -> " .. tool.Name .. " (" .. tostring(result) .. ")")
end

-- Quest turn-in, mirroring the game's DialogHandlerLocal bring-item flow.
local BRING_TYPES = { "Bring", "BringMap", "BringEquipment" }
local dialogCache = {}

local function getDialogData(npc)
	local cached = dialogCache[npc]
	if cached ~= nil then return cached or nil end
	local data = false
	local dialog = npc:FindFirstChild("Dialog")
	if dialog then
		local ok, result = pcall(function()
			return require(dialog:IsA("ObjectValue") and dialog.Value or dialog)
		end)
		if ok and typeof(result) == "table" then data = result end
	end
	dialogCache[npc] = data
	return data or nil
end

local function getQuestInventory()
	local items = {}
	local backpackTwo = LocalPlayer:FindFirstChild("BackpackTwo")
	if backpackTwo then
		for _, child in ipairs(backpackTwo:GetChildren()) do
			if child:IsA("Tool") then table.insert(items, child) end
		end
	end
	local equipped = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
	if equipped then table.insert(items, equipped) end
	return items
end

local function itemStat(tool, attribute)
	local data = tool:FindFirstChild("ItemData")
	return data and data:GetAttribute(attribute)
end

-- Cheapest valuables go first so heavier ones are kept for selling.
local function sortByWeight(items)
	table.sort(items, function(a, b)
		local wa, wb = itemStat(a, "Weight") or math.huge, itemStat(b, "Weight") or math.huge
		if wa == wb then return a.Name < b.Name end
		return wa < wb
	end)
end

-- Bring strings look like "Npc_Item_minAmount"; returns the NPC part when the tool satisfies it.
local function matchBring(tool, objective, bring)
	if typeof(bring) ~= "string" then return nil end
	local parts = string.split(bring, "_")
	local npcName, target = parts[1], parts[2]
	if not (npcName and target) then return nil end
	local minimum = tonumber(parts[3])
	local itemType = tool:GetAttribute("ItemType")

	if objective == "Bring" then
		if itemType == "Valuable" and tool.Name == target and (not minimum or (itemStat(tool, "Weight") or 0) >= minimum) then
			return npcName
		end
	elseif objective == "BringMap" then
		if itemType == "TreasureMap" and (tool:GetAttribute("Region") or itemStat(tool, "Region")) == target then
			return npcName
		end
	elseif objective == "BringEquipment" then
		if itemType == "Equipment" and tool.Name == target and (not minimum or (itemStat(tool, "Quality") or 0) >= minimum) then
			return npcName
		end
	end
	return nil
end

-- Quest automation. Progress comes from UpdateQuestData, the same event the game's quest UI
-- listens to: quest name -> true when complete, or a table with Step and StepProgress entries
-- ({ Text, Progress, Amount, Talk, ... }). The first message is the full list, later ones deltas.
local questData = {}
local lastQuestRefresh = 0

ctx:Connect(QuestRemotes.UpdateQuestData.OnClientEvent, function(update)
	if typeof(update) == "table" then
		for name, value in pairs(update) do questData[name] = value end
	end
end)

local function refreshQuestData()
	if next(questData) == nil or os.clock() - lastQuestRefresh > 30 then
		lastQuestRefresh = os.clock()
		QuestRemotes.UpdateQuestData:FireServer()
		task.wait(0.5)
	end
end

local function isActiveQuest(entry)
	return typeof(entry) == "table" and not entry.Badge and not entry.Calendar
end

local function bringKind(objective)
	for _, kind in ipairs(BRING_TYPES) do
		if objective[kind] then return kind end
	end
	return nil
end

local function hasPendingNonTalk(entry)
	if typeof(entry.StepProgress) ~= "table" then return false end
	for _, objective in pairs(entry.StepProgress) do
		if not objective.Talk and (objective.Amount or 1) - (objective.Progress or 0) > 0 then
			return true
		end
	end
	return false
end

-- The quest of this NPC that is waiting on the player: active, but its requirements (items to
-- bring, things to collect) are not met yet. Talking to such an NPC achieves nothing, so Auto Quest
-- leaves them alone until the requirements are met.
local waitingNotes = {}

local function npcWaitingOn(npc)
	local dialog = getDialogData(npc)
	if not (dialog and typeof(dialog.Quests) == "table") then return nil end
	for _, quest in ipairs(dialog.Quests) do
		local entry = questData[quest.Name]
		if isActiveQuest(entry) and hasPendingNonTalk(entry) then
			if waitingNotes[npc] ~= quest.Name then
				waitingNotes[npc] = quest.Name
				logVerbose(string.format("Quest: leaving %s alone until the requirements of %s are met", npc.Name, quest.Name))
			end
			return quest.Name
		end
	end
	waitingNotes[npc] = nil
	return nil
end

-- The pushed data may not carry the Bring fields, so ask the server for the step like the game's
-- turn-in dialog does. Cached per quest step to keep remote calls down.
local stepCache = {}

local function getStepProgress(name, entry)
	local key = name .. ":" .. tostring(entry.Step)
	local cached = stepCache[key]
	if cached and os.clock() - cached.Time < 10 then return cached.Progress end
	local step = QuestRemotes.GetCurrentQuestStep:InvokeServer(name)
	local progress = typeof(step) == "table" and typeof(step.StepProgress) == "table" and step.StepProgress
		or entry.StepProgress
	stepCache[key] = { Time = os.clock(), Progress = progress }
	return progress
end

-- Hands in inventory items that active quests ask for (QuestCollect(npcName, tools)).
local function submitQuestItems()
	local inventory = getQuestInventory()
	if #inventory == 0 then return 0 end
	sortByWeight(inventory)

	local used, grouped = {}, {}
	for name, entry in pairs(questData) do
		if isActiveQuest(entry) and hasPendingNonTalk(entry) then
			for _, objective in pairs(getStepProgress(name, entry) or {}) do
				local kind = bringKind(objective)
				local remaining = kind and (objective.Amount or 1) - (objective.Progress or 0) or 0
				for _, tool in ipairs(inventory) do
					if remaining <= 0 then break end
					if not used[tool] then
						local target = matchBring(tool, kind, objective[kind])
						if target then
							used[tool] = true
							grouped[target] = grouped[target] or {}
							table.insert(grouped[target], tool)
							remaining = remaining - 1
						end
					end
				end
			end
		end
	end

	local submitted = 0
	for npcName, tools in pairs(grouped) do
		local ok, count = QuestRemotes.QuestCollect:InvokeServer(npcName, tools)
		log(string.format("Quest: gave %d item(s) to %s (%s)", #tools, npcName, tostring(ok and (count or #tools) or "rejected")))
		if ok then
			submitted = submitted + (count or #tools)
		end
	end
	return submitted
end

-- Auto Farm, modelled on the game's own Auto Pan (PanClient): dig at a Deposit until the pan is
-- full, walk to Water, wash until the server clears the Panning attribute, then repeat. Movement
-- is Humanoid:MoveTo only (normal walk speed, no teleporting).
local PointToRegion
pcall(function()
	PointToRegion = require(ReplicatedStorage.Modules.Location.PointToRegion)
end)

local SCAN_RADIUS, SCAN_STEP = 30, 3
local farmWashes = 0 -- completed washes this run, quest trips wait for the first one
local farmingAnnounced = false -- "started farming" is logged once per stretch of farming
local rememberedSpots = {} -- last place a Deposit (dug) or Water (washed) was used this session
-- Diagnostics for "it stopped doing anything": the farm loop records where it is (farmTrace) and
-- when it last made progress (farmHeartbeat); a watchdog reports if that goes quiet, and each new
-- decision (dig / wash / walk / sell) is logged once.
local farmHeartbeat = 0
local farmTrace = ""
local lastDecision
local farmWatchdog = 0

local function fieldNamesOf(instance)
	local names = {}
	for _, child in ipairs(instance:GetChildren()) do table.insert(names, child.Name) end
	return table.concat(names, ", ")
end

-- Logged only when the decision changes; `detail` (pan fill, region) rides along with that line.
local function farmDecision(text, detail)
	farmHeartbeat = os.clock()
	farmTrace = text
	if text ~= lastDecision then
		lastDecision = text
		log("Farm: " .. text .. (detail and (" (" .. detail .. ")") or ""))
	end
end
local farmBlockedAt = -math.huge -- last time farming could not find or reach sand/water
local PathfindingService = game:GetService("PathfindingService")

local function regionAt(position)
	if not PointToRegion then return nil end
	local ok, region = pcall(PointToRegion.GetPanningRegion, position)
	return ok and region or nil
end

local function getRoot()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart"), character and character:FindFirstChildOfClass("Humanoid")
end

-- Same grid scan as the game's getAutoPanLocations: nearest Deposit point and the nearest Water
-- point that still has water one step further out.
local function scanFarmSpots(origin)
	local deposit, water
	local depositDist, waterDist = math.huge, math.huge
	for dx = -SCAN_RADIUS, SCAN_RADIUS, SCAN_STEP do
		for dz = -SCAN_RADIUS, SCAN_RADIUS, SCAN_STEP do
			local point = origin + Vector3.new(dx, 0, dz)
			local distance = (point - origin).Magnitude
			local region = regionAt(point)
			if region == "Deposit" and distance < depositDist then
				deposit, depositDist = point, distance
			elseif region == "Water" and distance < waterDist and distance > 0 then
				local beyond = point + (point - origin).Unit
				if regionAt(beyond) == "Water" then
					water, waterDist = beyond, distance
				end
			end
		end
	end
	return { Origin = origin, Water = water, Deposit = deposit }
end

local function haltMovement()
	local rootPart, humanoid = getRoot()
	if rootPart and humanoid then humanoid:MoveTo(rootPart.Position) end
end

-- The game's own panning code freezes the player (WalkSpeed 0, anchored) and unfreezes them when
-- it finishes. Make sure nothing is left frozen before walking.
local function restoreMovement()
	local rootPart, humanoid = getRoot()
	if not (rootPart and humanoid) then return end
	rootPart.Anchored = false
	if humanoid.WalkSpeed == 0 then
		humanoid.WalkSpeed = humanoid:GetAttribute("BaseWalkSpeed") or 16
		if typeof(_G.updateWalkSpeed) == "function" then pcall(_G.updateWalkSpeed) end
	end
	if humanoid.JumpPower == 0 then
		humanoid.JumpPower = humanoid:GetAttribute("BaseJumpPower") or 50
	end
	humanoid.AutoRotate = true
end

-- Anti-stuck helpers. Walking only ever uses Humanoid:MoveTo (no teleporting).

-- Makes the character jump, and makes sure jumping isn't disabled (the game zeroes it while
-- digging and washing).
local function jump(humanoid)
	if humanoid.UseJumpPower then
		if humanoid.JumpPower <= 0 then humanoid.JumpPower = humanoid:GetAttribute("BaseJumpPower") or 50 end
	elseif humanoid.JumpHeight <= 0 then
		humanoid.JumpHeight = 7.2
	end
	humanoid.Jump = true
	pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
end

-- Moves to a point and reports "finished", "stuck" or "timeout". The character jumps as soon as it
-- stops moving (every 0.4s while it stays put), and the third check without movement counts as stuck.
local function moveWatched(humanoid, rootPart, destination, timeout)
	humanoid:MoveTo(destination)
	local finished = false
	local connection = humanoid.MoveToFinished:Connect(function() finished = true end)
	local start, lastCheck, lastPosition, strikes = os.clock(), os.clock(), rootPart.Position, 0
	local result = "timeout"

	while os.clock() - start < timeout do
		if finished then
			result = "finished"
			break
		end
		task.wait(0.1)
		if os.clock() - lastCheck >= 0.4 then
			if (rootPart.Position - lastPosition).Magnitude < 0.4 then
				strikes = strikes + 1
				jump(humanoid)
				if strikes >= 3 then
					result = "stuck"
					break
				end
			else
				strikes = 0
			end
			lastPosition, lastCheck = rootPart.Position, os.clock()
		end
	end

	connection:Disconnect()
	return result
end

-- Backs off a little and steps sideways around whatever is blocking the way (alternating sides on
-- repeated attempts), jumping as it goes.
local function unstick(target, attempt)
	local rootPart, humanoid = getRoot()
	if not (rootPart and humanoid) then return end
	local toTarget = Vector3.new(target.X - rootPart.Position.X, 0, target.Z - rootPart.Position.Z)
	if toTarget.Magnitude < 0.1 then return end
	local forward = toTarget.Unit
	local side = Vector3.new(-forward.Z, 0, forward.X) * (attempt % 2 == 0 and 1 or -1)
	jump(humanoid)
	humanoid:MoveTo(rootPart.Position - forward * 3 + side * (4 + attempt))
	task.wait(0.35)
	jump(humanoid) -- a second jump partway through the sidestep clears low obstacles
	task.wait(0.45)
end

-- Used when walking straight at the target stalls (rocks, fences, water edges).
local function followPath(target, region)
	local rootPart, humanoid = getRoot()
	if not (rootPart and humanoid) then return end
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local ok = pcall(function() path:ComputeAsync(rootPart.Position, target) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		logVerbose("Farm: no walkable path to " .. region)
		unstick(target, 0)
		return
	end
	for _, waypoint in ipairs(path:GetWaypoints()) do
		rootPart, humanoid = getRoot()
		if not (enabledLoops.Farm and rootPart and humanoid) then return end
		if regionAt(rootPart.Position) == region then return end
		if waypoint.Action == Enum.PathWaypointAction.Jump then jump(humanoid) end
		local result = moveWatched(humanoid, rootPart, waypoint.Position, 3)
		if result == "stuck" then
			unstick(target, 1)
			return
		elseif result ~= "finished" then
			return
		end
	end
end

local function describePosition(position)
	return string.format("%.0f, %.0f, %.0f", position.X, position.Y, position.Z)
end

local function walkToRegion(target, region, timeout)
	local start = os.clock()
	local lastPosition, lastCheck = nil, os.clock()
	restoreMovement()
	local first = getRoot()
	if first and regionAt(first.Position) ~= region then
		log(string.format("Walk: straight to the %s, from (%s) to (%s), %.0f studs", region == "Water" and "water" or "sand",
			describePosition(first.Position), describePosition(target), (first.Position - target).Magnitude))
	end
	while enabledLoops.Farm and os.clock() - start < timeout do
		local rootPart, humanoid = getRoot()
		if not (rootPart and humanoid) then return false end
		if regionAt(rootPart.Position) == region then
			humanoid:MoveTo(rootPart.Position)
			return true
		end
		humanoid:MoveTo(target)
		task.wait(0.1)
		if os.clock() - lastCheck >= 2 then
			if lastPosition and (rootPart.Position - lastPosition).Magnitude < 1 then
				logVerbose("Farm: walk stalled, using pathfinding")
				followPath(target, region)
			end
			lastPosition, lastCheck = rootPart.Position, os.clock()
		end
	end

	local rootPart, humanoid = getRoot()
	if rootPart and humanoid then
		log(string.format("Farm: could not reach %s (distance %.0f, walkspeed %s, anchored %s, standing in %s)",
			region, (rootPart.Position - target).Magnitude, tostring(humanoid.WalkSpeed),
			tostring(rootPart.Anchored), tostring(regionAt(rootPart.Position))), Enum.MessageType.MessageWarning)
	end
	return false
end

local function digOnce(scriptsFolder, stats)
	local collect = scriptsFolder:FindFirstChild("Collect")
	local toggle = scriptsFolder:FindFirstChild("ToggleShovelActive")
	if not collect then
		log("Farm: the pan has no Collect remote (Scripts contains: " .. fieldNamesOf(scriptsFolder) .. ")", Enum.MessageType.MessageWarning)
		task.wait(2)
		return
	end
	local speed = (stats and stats:GetAttribute("DigSpeed")) or 1

	if not farmingAnnounced then
		farmingAnnounced = true
		log("Farm: started farming (digging at the sand)")
	end
	local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
	local capacity = stats and stats:GetAttribute("Capacity")
	setStatus(string.format("Digging at the sand (pan %s/%s)",
		tostring(tool and tool:GetAttribute("Fill") or 0), tostring(capacity or "?")))

	ctx:SetAttribute(LocalPlayer, "BackpackLocked", true)
	if toggle then toggle:FireServer(true) end
	farmTrace = "digOnce: waiting for Collect:InvokeServer() to return"
	local ok, reason = collect:InvokeServer()
	farmHeartbeat = os.clock()
	if ok then
		-- Wait for the dig bar to reach the top (perfect zone), then submit like the client does.
		task.wait(1 / (speed * 1.5) + 0.17 / speed)
		collect:InvokeServer(1, false)
		task.wait(0.95 / speed)
	else
		logVerbose("Farm: dig refused (" .. tostring(reason) .. ")")
		task.wait(0.5)
	end
	if toggle then toggle:FireServer(false) end
	ctx:SetAttribute(LocalPlayer, "BackpackLocked", false)
end

local function washOnce(tool, scriptsFolder, stats)
	local pan = scriptsFolder:FindFirstChild("Pan")
	local shake = scriptsFolder:FindFirstChild("Shake")
	local character = LocalPlayer.Character
	if not (pan and shake and character) then
		log("Farm: the pan is missing its Pan or Shake remote (Scripts contains: " .. fieldNamesOf(scriptsFolder) .. ")", Enum.MessageType.MessageWarning)
		task.wait(2)
		return
	end

	if not farmingAnnounced then
		farmingAnnounced = true
		log("Farm: started farming (washing the pan)")
	end
	setStatus("Washing the pan in the water")

	ctx:SetAttribute(LocalPlayer, "BackpackLocked", true)
	local before = tool:GetAttribute("Fill") or 0
	farmTrace = "washOnce: waiting for Pan:InvokeServer() to return"
	if pan:InvokeServer() then
		farmHeartbeat = os.clock()
		local waited = os.clock()
		while not character:GetAttribute("Panning") and os.clock() - waited < 1 do task.wait(0.05) end
		local cooldown = 0.3 / math.max((stats and stats:GetAttribute("ShakeSpeed")) or 1, 0.1)
		local started = os.clock()
		while enabledLoops.Farm and character:GetAttribute("Panning") and os.clock() - started < 90 do
			shake:FireServer()
			task.wait(cooldown)
		end
		log(string.format("Farm: washed pan (fill %s -> %s, quality %d%%)", tostring(before),
			tostring(tool:GetAttribute("Fill") or 0), math.round((tool:GetAttribute("Quality") or 0) * 100)))
		farmWashes = farmWashes + 1
		-- The game waits this long after Panning ends before it lets the player move again.
		local shakeSpeed = (stats and stats:GetAttribute("ShakeSpeed")) or 1
		task.wait(math.max(1 / ((shakeSpeed - 1) / 2 + 1), 0.4))
		restoreMovement()
	else
		logVerbose("Farm: wash refused")
		task.wait(1)
	end
	ctx:SetAttribute(LocalPlayer, "BackpackLocked", false)
end

-- Selling trips. Which NPC buys valuables isn't in any dump, so the seller is picked by the user
-- (name in Settings, or "Set Seller Here" while standing next to them).
local sellAll -- assigned once Actions exists
local lastSellTrip = 0
local SELL_TRIP_COOLDOWN = 20

local function horizontalDistance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

-- Walks along a computed path until within stopDistance (studs, ignoring height) of the target.
-- `active` says whether to keep going (defaults to Auto Farm being on). `label` names the
-- destination in the logs and the state label ("Walk: <label> ...").
-- Anti-stuck: every step is watched, a stuck character jumps and sidesteps, the path is recomputed
-- with a different agent size each time, and the walk gives up after repeated sticking or when it
-- stops getting closer.
local PATH_AGENTS = { { Radius = 2, Height = 5 }, { Radius = 3.5, Height = 5 }, { Radius = 1, Height = 4 } }
local MAX_STUCK = 6
local NO_PROGRESS_LIMIT = 20

local function pathWalk(target, stopDistance, timeout, active, label)
	active = active or function() return enabledLoops.Farm end
	label = label or "somewhere"
	local start = os.clock()
	local stuckCount, attempt, recomputes = 0, 0, 0
	local bestDistance, lastImprovement = math.huge, os.clock()
	local lastStatus = 0
	local announced = false

	-- One summary line per walk: where it was going and how it ended.
	local function finish(arrived, why, distance)
		if announced then
			if arrived then
				log(string.format("Walk: %s -> arrived in %.1fs", label, os.clock() - start))
			else
				log(string.format("Walk: %s -> stopped (%s) after %.1fs, %.0f studs left, %d path(s), %d stuck",
					label, why, os.clock() - start, distance or 0, recomputes, stuckCount), Enum.MessageType.MessageWarning)
			end
		end
		return arrived
	end

	while active() and os.clock() - start < timeout do
		local rootPart, humanoid = getRoot()
		if not (rootPart and humanoid) then return finish(false, "no character") end
		local distance = horizontalDistance(rootPart.Position, target)

		if not announced and distance > stopDistance + 6 then
			announced = true
			log(string.format("Walk: %s -> from (%s) to (%s), %.0f studs", label,
				describePosition(rootPart.Position), describePosition(target), distance))
		end
		if distance <= stopDistance then
			humanoid:MoveTo(rootPart.Position)
			return finish(true)
		end
		if announced and os.clock() - lastStatus >= 1 then
			lastStatus = os.clock()
			setStatus(string.format("Walking to %s (%.0f studs left)", label, distance))
		end

		if distance < bestDistance - 1 then
			bestDistance, lastImprovement = distance, os.clock()
		elseif os.clock() - lastImprovement > NO_PROGRESS_LIMIT then
			return finish(false, "no progress for " .. NO_PROGRESS_LIMIT .. "s", distance)
		end

		local agent = PATH_AGENTS[attempt % #PATH_AGENTS + 1]
		local path = PathfindingService:CreatePath({
			AgentRadius = agent.Radius, AgentHeight = agent.Height, AgentCanJump = true,
		})
		local ok = pcall(function() path:ComputeAsync(rootPart.Position, target) end)
		local stuck = false
		recomputes = recomputes + 1

		if not ok or path.Status ~= Enum.PathStatus.Success then
			logVerbose(string.format("Walk: %s: no path (agent radius %.1f), walking straight", label, agent.Radius))
			stuck = moveWatched(humanoid, rootPart, target, 3) == "stuck"
		else
			local waypoints = path:GetWaypoints()
			logVerbose(string.format("Walk: %s: path #%d has %d waypoints (agent radius %.1f), %.0f studs left",
				label, recomputes, #waypoints, agent.Radius, distance))
			for _, waypoint in ipairs(waypoints) do
				rootPart, humanoid = getRoot()
				if not (active() and rootPart and humanoid) then return finish(false, "cancelled") end
				if horizontalDistance(rootPart.Position, target) <= stopDistance then break end
				if waypoint.Action == Enum.PathWaypointAction.Jump then jump(humanoid) end
				local result = moveWatched(humanoid, rootPart, waypoint.Position, 3)
				if result ~= "finished" then
					stuck = result == "stuck"
					break -- recompute the path from where we are
				end
			end
		end

		if stuck then
			stuckCount = stuckCount + 1
			attempt = attempt + 1
			logVerbose(string.format("Walk: %s: stuck at (%s), sidestepping (%d/%d)", label,
				describePosition(rootPart.Position), stuckCount, MAX_STUCK))
			if stuckCount >= MAX_STUCK then
				return finish(false, "keeps getting stuck", horizontalDistance(rootPart.Position, target))
			end
			unstick(target, stuckCount)
		end
	end

	local rootPart = getRoot()
	return finish(false, active() and "timed out" or "cancelled", rootPart and horizontalDistance(rootPart.Position, target))
end

local function getSellerPosition()
	if Settings.SellerPosition then return Settings.SellerPosition end
	if Settings.SellerName ~= "" then
		local npcs = workspace:FindFirstChild("NPCs")
		for _, npc in ipairs(npcs and npcs:GetDescendants() or {}) do
			if npc:IsA("Model") and npc.Name == Settings.SellerName then
				return npc:GetPivot().Position
			end
		end
	end
	return Settings.SellerPosition
end

local function countValuables()
	local count = 0
	local backpackTwo = LocalPlayer:FindFirstChild("BackpackTwo")
	for _, item in ipairs(backpackTwo and backpackTwo:GetChildren() or {}) do
		if item:GetAttribute("ItemType") == "Valuable" and not item:GetAttribute("Locked") then
			count = count + 1
		end
	end
	return count
end

-- With the SellAnywhere pass the game lets you sell from anywhere, so no walking is needed.
local function canSellAnywhere()
	return LocalPlayer:GetAttribute("SellAnywhere")
end

local function shouldSell()
	return Settings.AutoSellTrips
		and os.clock() - lastSellTrip >= SELL_TRIP_COOLDOWN
		and (canSellAnywhere() or getSellerPosition() ~= nil)
		and countValuables() >= Settings.SellAtItems
end

-- The game shows "used/total" inventory space in a GUI tagged InventoryCounterText.
local function inventorySpaceText()
	for _, label in ipairs(CollectionService:GetTagged("InventoryCounterText")) do
		if label:IsDescendantOf(LocalPlayer.PlayerGui) and label:IsA("TextLabel") then
			return label.Text
		end
	end
	return "?"
end

local function sellTrip()
	lastSellTrip = os.clock()
	setStatus("Selling valuables")
	log(string.format("Farm: selling %d items (inventory %s)", countValuables(), inventorySpaceText()))
	farmingAnnounced = false
	if canSellAnywhere() then
		local ok, err = pcall(sellAll)
		if not ok then log("Farm: sell failed: " .. tostring(err), Enum.MessageType.MessageError) end
		return
	end
	local rootPart = getRoot()
	local seller = getSellerPosition()
	if not (rootPart and seller) then return end

	restoreMovement()
	setStatus("Walking to the seller")
	if pathWalk(seller, 6, 90, nil, "the seller") then
		task.wait(0.3)
		local ok, err = pcall(sellAll)
		if not ok then log("Farm: sell failed: " .. tostring(err), Enum.MessageType.MessageError) end
		task.wait(0.5)
	else
		log("Farm: could not reach the seller", Enum.MessageType.MessageWarning)
	end
	-- No walk back to where the trip began: that spot can be halfway along some route, and the farm
	-- loop already heads for the sand or water (waypoint or last used spot) on its next step.
	log("Farm: sell trip over, going back to farming")
	lastSellTrip = os.clock()
end

-- Walks to the saved waypoint for a region ("Water" or "Deposit"); with no waypoint it falls back
-- to scanning for the nearest spot like the game's Auto Pan does.
local function goToSpot(region, waypoint)
	local label = region == "Water" and "water" or "sand"
	waypoint = waypoint or rememberedSpots[region] -- no saved waypoint: go back to where it last worked
	setStatus("Walking to the " .. label)
	if waypoint then
		if not pathWalk(waypoint, 1.5, 60, nil, "the " .. label .. " waypoint") then
			farmBlockedAt = os.clock()
			logVerbose("Farm: could not reach the " .. label .. " waypoint")
			return
		end
		-- Regions can be small, so finish by stepping onto the exact saved point until the game
		-- reports the region (the path only gets within 1.5 studs of it).
		walkToRegion(waypoint, region, 8)
		local rootPart = getRoot()
		if rootPart and regionAt(rootPart.Position) ~= region then
			farmBlockedAt = os.clock()
			log("Farm: the " .. label .. " waypoint isn't on " .. label .. ", set it again while standing on it", Enum.MessageType.MessageWarning)
			task.wait(3)
		end
		return
	end

	local rootPart = getRoot()
	if not rootPart then return end
	local spots = scanFarmSpots(rootPart.Position)
	local target = region == "Water" and spots.Water or spots.Deposit
	if not target then
		farmBlockedAt = os.clock()
		setStatus("Waiting: no " .. label .. " nearby, set a waypoint")
		log("Farm: no " .. label .. " within " .. SCAN_RADIUS .. " studs, stand near it or set a waypoint", Enum.MessageType.MessageWarning)
		task.wait(3)
	elseif not walkToRegion(target, region, 15) then
		farmBlockedAt = os.clock()
		logVerbose("Farm: could not reach the " .. label)
	end
end

-- Quest talking. QuestTalked(talkKey) is what the game fires when you talk to a quest NPC: talk
-- objectives carry the key in `Talk` and NPC models carry it in the TalkKey attribute. The server
-- may want you near the NPC, so a pending talk walks there first. While Auto Farm is on, the farm
-- loop runs the queue itself so the two never fight over the character.
local talkQueue = {}
local lastTalk = {}
local TALK_COOLDOWN = 15

-- Distance from the player to an NPC (nil when either is missing).
local function distanceToNpc(npc)
	local rootPart = getRoot()
	if not (rootPart and npc and npc.Parent) then return nil end
	return (npc:GetPivot().Position - rootPart.Position).Magnitude
end

-- Quest NPCs further away than the radius setting are ignored, so Auto Quest works the area around
-- the player instead of walking across the whole map.
local function withinQuestRadius(npc)
	if not Settings.QuestRadiusEnabled then return true end
	local distance = distanceToNpc(npc)
	return distance ~= nil and distance <= Settings.QuestRadius
end

-- The NPC with this talk key (or name); the closest one if several match.
local function findTalkNpc(talkKey)
	local npcs = workspace:FindFirstChild("NPCs")
	local best, bestDistance = nil, math.huge
	for _, npc in ipairs(npcs and npcs:GetDescendants() or {}) do
		if npc:IsA("Model") and (npc:GetAttribute("TalkKey") == talkKey or npc.Name == talkKey) then
			local distance = distanceToNpc(npc) or math.huge
			if not best or distance < bestDistance then
				best, bestDistance = npc, distance
			end
		end
	end
	return best
end

local startChecked = {} -- "npc/quest" -> time of the last start attempt (used by startQuests)
local failedNpcs = {} -- NPCs a quest start already failed with: tried once, then left alone
local questPhase = false -- Auto Farm waits while Auto Quest first asks the nearby NPCs for quests
local questPhaseDeadline = 0

local function queueTalk(talkKey, npc, reason, quest, startKey)
	local id = talkKey .. "/" .. reason
	if lastTalk[id] and os.clock() - lastTalk[id] < TALK_COOLDOWN then return end
	lastTalk[id] = os.clock()

	npc = npc or findTalkNpc(talkKey)
	if npc and not withinQuestRadius(npc) then
		logVerbose(string.format("Quest: %s is %.0f studs away, outside the %d stud radius", talkKey,
			distanceToNpc(npc) or 0, Settings.QuestRadius))
		return
	end
	table.insert(talkQueue, { Key = talkKey, Npc = npc, Reason = reason, Quest = quest, StartKey = startKey })
end

-- Starting a quest by walking the NPC's dialog tree. Each NPC has a Dialog module with
-- GetInitialPrompt(npc) -> { Text, Responses = { { Response, Path | ConditionalPath } } }. The game
-- runs a response's ConditionalPath when it is clicked, and that is what starts quests, so the same
-- functions are called here. CanStartQuest is checked after every response so it stops as soon as
-- the quest has started, and responses that look like declining are skipped.
local DECLINE_WORDS = { "no", "bye", "goodbye", "leave", "later", "nevermind", "never mind", "not now", "cancel", "nothing", "see you" }
local DIALOG_NODE_LIMIT = 25

local function isDeclineResponse(text)
	local lower = string.lower(text)
	for _, word in ipairs(DECLINE_WORDS) do
		if string.find(lower, "%f[%a]" .. word .. "%f[%A]") then return true end
	end
	return false
end

local function questStatus(quest)
	local _, status = QuestRemotes.CanStartQuest:InvokeServer(quest)
	return status
end

-- A quest counts as started once the server has pushed data for it, or CanStartQuest says so.
local function isQuestStarted(quest)
	return typeof(questData[quest.Name]) == "table" or questStatus(quest) == "Started"
end

local function activeQuestNames()
	local names = {}
	for name, entry in pairs(questData) do
		if isActiveQuest(entry) then names[name] = true end
	end
	return names
end

local function fieldNames(tbl)
	local names = {}
	for key in pairs(tbl) do table.insert(names, tostring(key)) end
	table.sort(names)
	return table.concat(names, ", ")
end

-- Returns started, reason (the reason says why it could not start the quest).
local function startQuestViaDialog(npc, quest)
	local dialog = getDialogData(npc)
	if not dialog then return false, "no Dialog module could be loaded" end
	if typeof(dialog.GetInitialPrompt) ~= "function" then
		return false, "Dialog has no GetInitialPrompt (fields: " .. fieldNames(dialog) .. ")"
	end
	local ok, root = pcall(dialog.GetInitialPrompt, npc)
	if not ok then return false, "GetInitialPrompt error: " .. tostring(root) end
	if typeof(root) ~= "table" then return false, "GetInitialPrompt returned " .. typeof(root) end
	if typeof(root.Responses) ~= "table" or #root.Responses == 0 then
		return false, "initial prompt has no responses (fields: " .. fieldNames(root) .. ")"
	end

	local visited, tried = 0, {}
	local function visit(node, depth)
		if depth > 6 or typeof(node.Responses) ~= "table" then return false end
		for _, response in ipairs(node.Responses) do
			if visited >= DIALOG_NODE_LIMIT then return false end
			local label = tostring(response.Response)
			if not isDeclineResponse(label) then
				visited = visited + 1
				table.insert(tried, label)
				local path = response.Path
				if response.ConditionalPath then
					local pathOk, result = pcall(response.ConditionalPath)
					path = pathOk and result or nil
				end
				logVerbose(string.format("Quest dialog %s: '%s'", npc.Name, label))
				if questStatus(quest) == "Started" then return true end
				if typeof(path) == "table" and visit(path, depth + 1) then return true end
			end
		end
		return false
	end

	if visit(root, 1) then return true end
	return false, string.format("%d response(s) tried, none started it: %s", visited, table.concat(tried, " | "))
end

-- Debug aid: logs the dialog structure of an NPC (initial prompt, response texts and whether each
-- leads to a prompt table or a function), without running any response.
local function describeDialogNode(node, depth)
	if typeof(node) ~= "table" or depth > 3 then return end
	local indent = string.rep("  ", depth)
	if typeof(node.Responses) ~= "table" then
		log(indent .. "(no responses)")
		return
	end
	for index, response in ipairs(node.Responses) do
		local kind = response.ConditionalPath and "function" or typeof(response.Path)
		log(string.format("%s%d. '%s' -> %s", indent, index, tostring(response.Response), kind))
		if typeof(response.Path) == "table" then describeDialogNode(response.Path, depth + 1) end
	end
end

local function dumpNpcDialog(npc)
	local dialog = getDialogData(npc)
	if not dialog then
		log("Dialog dump: " .. npc.Name .. " has no loadable Dialog module", Enum.MessageType.MessageWarning)
		return
	end
	log("Dialog dump: " .. npc.Name .. " | TalkKey=" .. tostring(npc:GetAttribute("TalkKey")) ..
		" | fields: " .. fieldNames(dialog))
	if typeof(dialog.Quests) == "table" then
		local names = {}
		for _, quest in ipairs(dialog.Quests) do table.insert(names, quest.Name) end
		log("  quests: " .. table.concat(names, ", "))
	end
	if typeof(dialog.GetInitialPrompt) == "function" then
		local ok, root = pcall(dialog.GetInitialPrompt, npc)
		if ok and typeof(root) == "table" then
			log("  initial text: " .. (typeof(root.Text) == "table" and table.concat(root.Text, " / ") or tostring(root.Text)))
			describeDialogNode(root, 1)
		else
			log("  GetInitialPrompt failed: " .. tostring(root), Enum.MessageType.MessageWarning)
		end
	end
end

-- Talking to an NPC the way a player does. The game's DialogHandler puts a "DialogPrompt"
-- ProximityPrompt on every NPC that has a Dialog; triggering it opens the dialog UI (ResponseUI),
-- and clicking a response runs the NPC's own dialog code, which is what starts quests and advances
-- talk objectives. Needs an executor with fireproximityprompt (or firesignal / getconnections).
local function fireSignalSafe(signal, ...)
	local args = table.pack(...)

	-- Preferred: call the connected handlers from a fresh thread. Handlers that yield (remote
	-- calls, like Steve's dialog responses) fail with "attempt to yield across metamethod/C-call
	-- boundary" when run through firesignal, but work in their own thread.
	if type(getconnections) == "function" then
		local fired = false
		for _, connection in ipairs(getconnections(signal)) do
			local ok, handler = pcall(function() return connection.Function end)
			if ok and type(handler) == "function" then
				task.spawn(handler, table.unpack(args, 1, args.n))
				fired = true
			end
		end
		if fired then return true end
	end

	if type(firesignal) == "function" then
		return (pcall(firesignal, signal, ...))
	end
	if type(getconnections) == "function" then
		for _, connection in ipairs(getconnections(signal)) do
			pcall(function() connection:Fire(table.unpack(args, 1, args.n)) end)
		end
		return true
	end
	return false
end

local function triggerPrompt(prompt)
	if type(fireproximityprompt) == "function" and pcall(fireproximityprompt, prompt) then
		return true
	end
	return fireSignalSafe(prompt.Triggered, LocalPlayer)
end

-- The clickable responses currently shown, in display order, plus the ResponseUI itself.
local function getResponseButtons()
	local ui = LocalPlayer.PlayerGui:FindFirstChild("ResponseUI")
	local holder = ui and ui:FindFirstChild("HoldingFrame")
	local buttons = {}
	for _, child in ipairs(holder and holder:GetChildren() or {}) do
		local text = child:FindFirstChild("ResponseText")
		if text and not child:IsA("UIListLayout") and child.Interactable ~= false then
			local label = string.gsub(text.Text, "<[^<>]->", "")
			label = string.gsub(label, "^%s*%d+%.%s*", "")
			table.insert(buttons, { Button = child, Label = label, Order = child.LayoutOrder })
		end
	end
	table.sort(buttons, function(a, b) return a.Order < b.Order end)
	return buttons, ui
end

local function clickResponse(option)
	return fireSignalSafe(option.Button.MouseButton1Click)
end

-- Ends an open dialog by picking a "goodbye"-style response (or the last one) until it closes, so
-- the NPC's prompts and the next dialog are not left blocked.
local function closeDialog()
	for _ = 1, 8 do
		local buttons, ui = getResponseButtons()
		if not ui then return end
		if #buttons > 0 then
			local pick = buttons[#buttons]
			for _, option in ipairs(buttons) do
				if isDeclineResponse(option.Label) then
					pick = option
					break
				end
			end
			clickResponse(pick)
		end
		task.wait(1.5)
	end
end

-- Opens the NPC's dialog and clicks through it, preferring responses that don't look like
-- declining, until isDone() says so (or the dialog ends). Returns done, reason.
local MAX_DIALOG_CLICKS = 12

-- What the NPC last said (the dialog bubble lingers a couple of seconds after the dialog ends).
local function getNpcText()
	local dialogUi = LocalPlayer.PlayerGui:FindFirstChild("DialogUI")
	local frame = dialogUi and dialogUi:FindFirstChild("Frame")
	local text = frame and frame:FindFirstChild("DialogText")
	if not text then return "" end
	local clean = string.gsub(text.Text, "<[^<>]->", "")
	return string.sub(clean, 1, 160)
end

local function interactCore(npc, isDone)
	if type(fireproximityprompt) ~= "function" and type(firesignal) ~= "function" and type(getconnections) ~= "function" then
		return false, "this executor has no fireproximityprompt, firesignal or getconnections"
	end
	local prompt = npc:FindFirstChild("DialogPrompt") or npc:WaitForChild("DialogPrompt", 3)
	if not prompt then return false, "the NPC has no DialogPrompt" end

	if LocalPlayer.PlayerGui:FindFirstChild("ResponseUI") then closeDialog() end
	if not triggerPrompt(prompt) then return false, "could not trigger the prompt" end

	local chosen, seen, clicks = {}, {}, 0
	local sawUi = false
	local opened = os.clock()
	local done = false
	local lastText = ""

	while enabledLoops.Quest and os.clock() - opened < 120 and clicks < MAX_DIALOG_CLICKS do
		local buttons, ui = getResponseButtons()
		local said = getNpcText()
		if said ~= "" then lastText = said end
		if ui then
			sawUi = true
		elseif sawUi then
			break -- the dialog ended
		elseif os.clock() - opened > 5 then
			return false, "the dialog never opened (too far away, or another dialog is open?)"
		end

		if #buttons == 0 then
			task.wait(0.25) -- still typing out the NPC's text
		else
			if isDone and isDone() then
				done = true
				break
			end
			local pick
			for _, option in ipairs(buttons) do
				if not seen[option.Label] and not isDeclineResponse(option.Label) then
					pick = option
					break
				end
			end
			if not pick then break end
			seen[pick.Label] = true
			clicks = clicks + 1
			table.insert(chosen, pick.Label)
			logVerbose(string.format("Quest dialog %s: clicked '%s'", npc.Name, pick.Label))
			clickResponse(pick)

			local waited = os.clock()
			while pick.Button.Parent and os.clock() - waited < 6 do task.wait(0.2) end
			task.wait(0.3)
		end
	end

	if not done and isDone and isDone() then done = true end
	closeDialog()
	if done then return true end
	return false, string.format("dialog finished without it (clicked: %s)%s",
		#chosen > 0 and table.concat(chosen, " | ") or "nothing",
		lastText ~= "" and (" | NPC said: '" .. lastText .. "'") or "")
end

-- Same, but also captures the game's own "[DialogHandler] Dialog step failed" warnings: they are
-- printed when a response returns something the dialog UI can't use, which closes the dialog.
local LogService = game:GetService("LogService")

local function interactWithNpc(npc, isDone)
	local warnings = {}
	local connection = LogService.MessageOut:Connect(function(message)
		if string.find(message, "[DialogHandler]", 1, true) then
			table.insert(warnings, (string.match(message, "[^\n]+")))
		end
	end)
	local done, reason = interactCore(npc, isDone)
	connection:Disconnect()
	if not done and #warnings > 0 then
		reason = tostring(reason) .. " | game warning: " .. string.sub(warnings[1], 1, 220)
	end
	return done, reason
end

-- Not safe to walk off while digging or washing.
local function canTravel()
	local character = LocalPlayer.Character
	return character ~= nil and not character:GetAttribute("Panning") and not LocalPlayer:GetAttribute("BackpackLocked")
end

-- True while some active quest still has this talk key as an objective whose other requirements
-- are met. A talk queued a while ago may be stale by the time the trip happens (the quest moved
-- on or finished), and walking across the map for it would be pointless.
local function talkObjectivePending(talkKey)
	for _, entry in pairs(questData) do
		if isActiveQuest(entry) and typeof(entry.StepProgress) == "table" and not hasPendingNonTalk(entry) then
			for _, objective in pairs(entry.StepProgress) do
				if objective.Talk == talkKey and (objective.Amount or 1) - (objective.Progress or 0) > 0 then
					return true
				end
			end
		end
	end
	return false
end

local function runTalkQueue()
	if #talkQueue == 0 or not canTravel() then return end
	local items = {}
	for _, item in ipairs(talkQueue) do
		if item.Quest or talkObjectivePending(item.Key) then
			table.insert(items, item)
		else
			log("Quest: dropping the queued talk to " .. item.Key .. " (" .. tostring(item.Reason) .. "), it is no longer needed")
		end
	end
	talkQueue = {}
	if #items == 0 then return end
	local rootPart = getRoot()
	if not rootPart then return end

	log(string.format("Quest: trip with %d stop(s): %s", #items, (function()
		local names = {}
		for _, item in ipairs(items) do table.insert(names, item.Key .. (item.Quest and " (" .. item.Quest.Name .. ")" or "")) end
		return table.concat(names, ", ")
	end)()))

	local home = rootPart.Position
	local moved = false
	local function active() return enabledLoops.Quest end

	for _, item in ipairs(items) do
		local reachable = true
		local npcPosition = item.Npc and item.Npc.Parent and item.Npc:GetPivot().Position
		if npcPosition and Settings.QuestWalk then
			local current = getRoot()
			if current and horizontalDistance(current.Position, npcPosition) > 10 then
				moved = true
				restoreMovement()
				setStatus("Walking to " .. item.Key .. (item.Quest and " to ask for a quest" or " to talk"))
				reachable = pathWalk(npcPosition, 6, 90, active, "NPC " .. item.Key)
			end
		end

		if reachable then
			if item.Quest then
				if questData[item.Quest.Name] ~= nil then
					-- An earlier dialog this pass already started (or finished) it.
					logVerbose("Quest: " .. item.Quest.Name .. " is already active or done, skipping")
				elseif item.Npc and failedNpcs[item.Npc] then
					logVerbose("Quest: skipping " .. item.Quest.Name .. ", " .. item.Key .. " already failed once")
				elseif item.Npc and npcWaitingOn(item.Npc) then
					-- The NPC gave us another quest that is still waiting on us; don't bother them.
					logVerbose("Quest: not talking to " .. item.Key .. ", " .. npcWaitingOn(item.Npc) .. " is still in progress")
				else
					-- 1) talk to the NPC like a player, 2) walk the dialog data, 3) QuestTalked.
					local before = activeQuestNames()
					local function isStarted() return isQuestStarted(item.Quest) end
					local method, started, reason = "prompt", false, "NPC not found in workspace.NPCs"
					setStatus("Talking to " .. item.Key .. " about " .. item.Quest.Name)
					if item.Npc then started, reason = interactWithNpc(item.Npc, isStarted) end
					if not started then
						method = "dialog data"
						local dataReason
						if item.Npc then started, dataReason = startQuestViaDialog(item.Npc, item.Quest) end
						if not started and dataReason then reason = tostring(reason) .. " | data walk: " .. tostring(dataReason) end
					end
					if not started then
						method = "QuestTalked"
						QuestRemotes.QuestTalked:FireServer(item.Key)
						task.wait(0.4)
						started = isStarted()
						if not started and item.Npc and item.Npc.Name ~= item.Key then
							QuestRemotes.QuestTalked:FireServer(item.Npc.Name)
							task.wait(0.4)
							started = isStarted()
						end
					end

					-- The NPC may have given a different quest than the one being checked.
					task.wait(0.5)
					local newly = {}
					for name in pairs(activeQuestNames()) do
						if not before[name] then table.insert(newly, name) end
					end
					if started or #newly > 0 then
						log(string.format("Quest: %s -> STARTED %s (%s)", item.Key,
							#newly > 0 and table.concat(newly, ", ") or item.Quest.Name, method))
					else
						log(string.format("Quest: could not start %s from %s: %s", item.Quest.Name, item.Key,
							tostring(reason)), Enum.MessageType.MessageWarning)
						-- One failed attempt is enough: leave this NPC alone from now on (until Auto
						-- Quest is switched off and on again), and don't re-check this quest.
						if item.Npc then failedNpcs[item.Npc] = true end
						if item.StartKey then startChecked[item.StartKey] = os.clock() + 540 end
						log("Quest: won't try " .. item.Key .. " again this session")
					end
				end
			else
				-- Talk objective: open the NPC's dialog and click through it, then tell the server.
				setStatus("Talking to " .. item.Key .. " (" .. tostring(item.Reason) .. ")")
				if item.Npc then
					local _, reason = interactWithNpc(item.Npc, nil)
					if reason then logVerbose("Quest: talk to " .. item.Key .. ": " .. tostring(reason)) end
				end
				QuestRemotes.QuestTalked:FireServer(item.Key)
				log(string.format("Quest: talked to %s (%s)", item.Key, item.Reason))
				-- If the talk did not complete the objective, do not walk back for the same one right away.
				lastTalk[item.Key .. "/" .. item.Reason] = os.clock() + 75
			end
		else
			log("Quest: could not reach " .. item.Key, Enum.MessageType.MessageWarning)
		end
	end

	if moved then
		if enabledLoops.Farm then
			-- The farm loop walks to the sand or water by itself, no need to retrace to `home`.
			log("Quest: trip over, going back to farming")
		else
			setStatus("Walking back")
			pathWalk(home, 4, 90, active, "back where the trip began")
		end
	end
	farmingAnnounced = false -- log "started farming" again once farming resumes
end

-- Starting quests: for quests the player has no data for yet, CanStartQuest(questModule) says
-- whether they are available, and talking to the NPC starts them. A cap on active quests and a
-- per-pass budget of checks keep the remote traffic down.
local START_RETRY = 60
local START_BUDGET = 8
local lastCapNote

local function startQuests()
	local npcs = workspace:FindFirstChild("NPCs")
	if not npcs then return true end

	-- Daily and weekly quests are always on the list, so they don't count toward the cap.
	local active = 0
	for _, entry in pairs(questData) do
		if isActiveQuest(entry) and not entry.Daily and not entry.Weekly then active = active + 1 end
	end
	if active >= Settings.MaxActiveQuests then
		local note = string.format("Quest: not starting new quests, %d active (max %d, see Settings)", active, Settings.MaxActiveQuests)
		if note ~= lastCapNote then
			lastCapNote = note
			log(note)
		end
		return true -- nothing more can be started, so there is nothing left to ask for
	end
	lastCapNote = nil
	local budget = START_BUDGET

	-- Quest NPCs inside the radius, closest first so the per-pass budget goes to nearby ones.
	local candidates = {}
	for _, npc in ipairs(npcs:GetDescendants()) do
		local dialog = npc:IsA("Model") and getDialogData(npc)
		if dialog and typeof(dialog.Quests) == "table" and withinQuestRadius(npc) and not failedNpcs[npc] and not npcWaitingOn(npc) then
			table.insert(candidates, { Npc = npc, Dialog = dialog, Distance = distanceToNpc(npc) or math.huge })
		end
	end
	table.sort(candidates, function(a, b) return a.Distance < b.Distance end)

	for _, candidate in ipairs(candidates) do
		local npc, dialog = candidate.Npc, candidate.Dialog
		do
			for _, quest in ipairs(dialog.Quests) do
				if active >= Settings.MaxActiveQuests then return true end
				if budget <= 0 then return false end -- more to check on the next pass
				local key = npc.Name .. "/" .. quest.Name
				local last = startChecked[key]
				if questData[quest.Name] == nil and (not last or os.clock() - last >= START_RETRY) then
					startChecked[key] = os.clock()
					budget = budget - 1
					local canStart, status = QuestRemotes.CanStartQuest:InvokeServer(quest)
					logVerbose(string.format("CanStartQuest %s -> %s, %s", quest.Name, tostring(canStart), tostring(status)))
					if canStart and status ~= "Started" then
						local talkKey = npc:GetAttribute("TalkKey")
						if typeof(talkKey) ~= "string" or talkKey == "" then talkKey = npc.Name end
						queueTalk(talkKey, npc, "start " .. quest.Name, quest, key)
						active = active + 1 -- assume it starts, so the cap holds
					end
				end
			end
		end
	end
	return true -- every quest NPC in range has been checked
end

local lastObjective = {}
local seenActive = {}

local function questTick()
	refreshQuestData()

	for name, entry in pairs(questData) do
		if isActiveQuest(entry) then
			seenActive[name] = true
			for _, objective in pairs(typeof(entry.StepProgress) == "table" and entry.StepProgress or {}) do
				local progress, amount = objective.Progress or 0, objective.Amount or 1
				if amount - progress > 0 then
					if objective.Talk and not hasPendingNonTalk(entry) then
						queueTalk(objective.Talk, nil, name)
					end
					-- Anything else (bring items are handled below) needs normal gameplay.
					local id = name .. ":" .. tostring(objective.Text)
					if lastObjective[id] ~= progress then
						lastObjective[id] = progress
						log(string.format("Quest %s (step %s): %s %d/%d", name, tostring(entry.Step),
							tostring(objective.Text), progress, amount))
					end
				end
			end
		elseif entry == true and seenActive[name] then
			seenActive[name] = nil
			log("Quest complete: " .. name)
			-- Finishing a quest often unlocks the next one in its chain, so check everything again.
			startChecked = {}
		end
	end

	local given = submitQuestItems()
	if given > 0 then log("Quest: submitted " .. given .. " item(s) total") end

	local askedEveryone = true
	if Settings.AutoStartQuests then askedEveryone = startQuests() end

	-- Auto Farm waits for this first round of asking. It is over once every quest NPC around has
	-- been checked and no trip is left to make (or after a few minutes, whatever happens first).
	if questPhase then
		setStatus("Asking the nearby NPCs for quests")
		if (askedEveryone and #talkQueue == 0) or os.clock() > questPhaseDeadline then
			questPhase = false
			log(string.format("Quest: finished asking for quests around here (radius %s), starting to farm",
				Settings.QuestRadiusEnabled and (Settings.QuestRadius .. " studs") or "whole map"))
		end
	end

	if not enabledLoops.Farm then runTalkQueue() end
end

-- Waypoint unlock data (from FastTravelClient): GetFastTravelData pushes waypoint name -> true for
-- the unlocked ones. Used by Fast Travel, the waypoint ESP and Auto Claim Waypoints.
local MiscRemotes = Remotes:WaitForChild("Misc")
local unlockedWaypoints = {}
local lastWaypointDataRequest = 0

ctx:Connect(MiscRemotes.GetFastTravelData.OnClientEvent, function(data)
	if typeof(data) == "table" then unlockedWaypoints = data end
end)

local function requestWaypointData()
	lastWaypointDataRequest = os.clock()
	pcall(function() MiscRemotes.GetFastTravelData:FireServer() end)
end
requestWaypointData()

local function getWaypointsFolder()
	local map = workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Waypoints")
end

-- Auto Claim Waypoints: walking up to a waypoint and triggering its WaypointPrompt is how a player
-- unlocks it. The prompt also opens the game's travel menu, which is closed again here. Whether it
-- worked is checked against the unlock data afterwards.
local waypointCooldown = {} -- waypoint -> time before which it isn't tried again
local lastClaimNote

local function nextUnclaimedWaypoint()
	local folder = getWaypointsFolder()
	local rootPart = getRoot()
	if not (folder and rootPart) then return nil end
	local best, bestDistance = nil, math.huge
	for _, waypoint in ipairs(folder:GetChildren()) do
		if unlockedWaypoints[waypoint.Name] ~= true and (waypointCooldown[waypoint] or 0) <= os.clock()
			and waypoint:FindFirstChild("WaypointPrompt", true) then
			local distance = (waypoint:GetPivot().Position - rootPart.Position).Magnitude
			if distance < bestDistance then best, bestDistance = waypoint, distance end
		end
	end
	return best
end

-- The travel menu (FastTravelClient's frame: Content.List plus a Header.Close button).
local function closeTravelMenu()
	for _, gui in ipairs(LocalPlayer.PlayerGui:GetDescendants()) do
		if gui:IsA("GuiObject") and gui.Visible then
			local content, header = gui:FindFirstChild("Content"), gui:FindFirstChild("Header")
			if content and header and content:FindFirstChild("List") and header:FindFirstChild("Close") then
				gui.Visible = false
			end
		end
	end
end

local function claimWaypointTrip(waypoint)
	local prompt = waypoint:FindFirstChild("WaypointPrompt", true)
	if not prompt then return end
	local function active() return enabledLoops.ClaimWaypoints end

	restoreMovement()
	setStatus("Walking to the " .. waypoint.Name .. " waypoint to claim it")
	if not pathWalk(waypoint:GetPivot().Position, 5, 150, active, "waypoint " .. waypoint.Name) then
		log("Waypoint: could not reach " .. waypoint.Name .. ", trying again later", Enum.MessageType.MessageWarning)
		waypointCooldown[waypoint] = os.clock() + 120
		return
	end

	-- A real prompt trigger reaches the server (firesignal on Triggered would only run local code).
	setStatus("Claiming the " .. waypoint.Name .. " waypoint")
	local triggered = type(fireproximityprompt) == "function" and pcall(fireproximityprompt, prompt)
	if not triggered then
		pcall(function()
			prompt:InputHoldBegin()
			task.wait(prompt.HoldDuration + 0.1)
			prompt:InputHoldEnd()
		end)
	end
	task.wait(1)
	closeTravelMenu()

	requestWaypointData()
	local waited = os.clock()
	while unlockedWaypoints[waypoint.Name] ~= true and os.clock() - waited < 4 do task.wait(0.25) end
	if unlockedWaypoints[waypoint.Name] == true then
		log("Waypoint: claimed " .. waypoint.Name)
	else
		log("Waypoint: " .. waypoint.Name .. " still isn't unlocked after triggering its prompt; skipping it for a while",
			Enum.MessageType.MessageWarning)
		waypointCooldown[waypoint] = os.clock() + 300
	end
	setStatus("Idle")
end

-- Auto Claim Waypoints loop. With Auto Farm on, the farm loop makes the trip itself.
local function claimStep()
	if os.clock() - lastWaypointDataRequest > 30 then
		requestWaypointData()
		task.wait(1)
	end
	local waypoint = nextUnclaimedWaypoint()
	local note = waypoint and nil or "no unclaimed waypoints left (or none loaded)"
	if note ~= lastClaimNote then
		lastClaimNote = note
		if note then log("Waypoint: " .. note) end
	end
	if not waypoint or enabledLoops.Farm or not canTravel() then return end
	claimWaypointTrip(waypoint)
end

-- Geodes. How a Geode is collected isn't in any dump, so this tries the usual interactions in
-- order (a ProximityPrompt on the model, a ClickDetector, then touching it) and checks whether the
-- Geode disappeared. The log says which one worked.
local geodeCooldown = {} -- geode -> time before which it isn't tried again (after a failed attempt)

-- workspace.Geode may be a single model, several models with that name, or a folder of them.
local function getGeodes()
	local geodes = {}
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == "Geode" then
			if child:IsA("Folder") then
				for _, geode in ipairs(child:GetChildren()) do table.insert(geodes, geode) end
			else
				table.insert(geodes, child)
			end
		end
	end
	return geodes
end

local function geodePart(geode)
	if geode:IsA("BasePart") then return geode end
	if geode:IsA("Model") and geode.PrimaryPart then return geode.PrimaryPart end
	return geode:FindFirstChildWhichIsA("BasePart", true)
end

-- The closest Geode that isn't cooling down after a failed attempt.
local function nextGeode()
	local rootPart = getRoot()
	if not rootPart then return nil end
	local best, bestDistance = nil, math.huge
	for _, geode in ipairs(getGeodes()) do
		local part = geodePart(geode)
		if part and (geodeCooldown[geode] or 0) <= os.clock() then
			local distance = (part.Position - rootPart.Position).Magnitude
			if distance < bestDistance then best, bestDistance = geode, distance end
		end
	end
	return best
end

-- Tries to collect a Geode we are standing next to; returns the method used.
local function interactWithGeode(geode, part)
	local prompt = geode:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		if type(fireproximityprompt) == "function" and pcall(fireproximityprompt, prompt) then
			return "ProximityPrompt"
		end
		local ok = pcall(function()
			prompt:InputHoldBegin()
			task.wait(prompt.HoldDuration + 0.1)
			prompt:InputHoldEnd()
		end)
		if ok then return "ProximityPrompt (held)" end
	end

	local clicker = geode:FindFirstChildWhichIsA("ClickDetector", true)
	if clicker and type(fireclickdetector) == "function" and pcall(fireclickdetector, clicker) then
		return "ClickDetector"
	end

	local rootPart, humanoid = getRoot()
	if rootPart and type(firetouchinterest) == "function" then
		for _, descendant in ipairs(geode:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.CanTouch then
				pcall(firetouchinterest, rootPart, descendant, 0)
				task.wait()
				pcall(firetouchinterest, rootPart, descendant, 1)
			end
		end
		return "touch"
	end

	if humanoid then
		humanoid:MoveTo(part.Position)
		task.wait(1.5)
	end
	return "walking into it"
end

local function collectGeodeTrip(geode)
	local part = geodePart(geode)
	if not part then return end
	local function active() return enabledLoops.Geode end

	restoreMovement()
	setStatus("Walking to the Geode")
	if not pathWalk(part.Position, 5, 120, active, "the Geode") then
		log("Geode: could not reach it, trying again in a minute", Enum.MessageType.MessageWarning)
		geodeCooldown[geode] = os.clock() + 60
		return
	end

	setStatus("Collecting the Geode")
	local method = interactWithGeode(geode, part)
	local waited = os.clock()
	while geode.Parent and os.clock() - waited < 5 do task.wait(0.25) end

	if not geode.Parent then
		log("Geode: collected (" .. method .. ")")
	else
		log("Geode: still there after trying " .. method .. "; if this keeps happening, a dump of the Geode's script would show how it's collected",
			Enum.MessageType.MessageWarning)
		geodeCooldown[geode] = os.clock() + 60
	end
	setStatus("Idle")
end

-- Auto Collect Geode loop. With Auto Farm on, the farm loop makes the trip itself (between digs
-- and washes) so the two never fight over the character.
local lastGeodeNote

local function geodeStep()
	local geode = nextGeode()
	local note = geode and nil or "waiting for a Geode to appear"
	if note ~= lastGeodeNote then
		lastGeodeNote = note
		if note then log("Geode: " .. note) end
	end
	if not geode or enabledLoops.Farm or not canTravel() then return end
	collectGeodeTrip(geode)
end

-- Auto Use Geodes: Geode tools in BackpackTwo get equipped (CustomBackpack.EquipRemote, like the
-- pans) and activated, which is what clicking with a tool does. How the game opens a Geode isn't in
-- any dump, so success is checked by the tool being used up; if it isn't, the log lists what the
-- tool contains so the real call can be found.
local geodeToolCooldown = {} -- tool -> time before which it isn't tried again

local function findGeodeTool()
	local containers = { LocalPlayer.Character, LocalPlayer:FindFirstChild("BackpackTwo"), LocalPlayer:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		for _, tool in ipairs(container and container:GetChildren() or {}) do
			if tool:IsA("Tool") and string.find(tool.Name, "Geode") and (geodeToolCooldown[tool] or 0) <= os.clock() then
				return tool
			end
		end
	end
	return nil
end

local function useGeodeTool(tool)
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and humanoid) then return end

	setStatus("Opening a " .. tool.Name)
	if tool.Parent ~= character then
		local equip = Remotes:FindFirstChild("CustomBackpack")
		equip = equip and equip:FindFirstChild("EquipRemote")
		if equip then
			equip:FireServer(tool)
			local waited = os.clock()
			while tool.Parent ~= character and os.clock() - waited < 1.5 do task.wait(0.1) end
		end
		if tool.Parent ~= character then pcall(function() humanoid:EquipTool(tool) end) end
		task.wait(0.3)
	end
	if tool.Parent ~= character then
		log("Geode: could not equip " .. tool.Name, Enum.MessageType.MessageWarning)
		geodeToolCooldown[tool] = os.clock() + 60
		return
	end

	pcall(function() tool:Activate() end)
	local waited = os.clock()
	while tool.Parent and os.clock() - waited < 4 do task.wait(0.25) end

	if not tool.Parent then
		log("Geode: opened a " .. tool.Name)
	else
		log("Geode: " .. tool.Name .. " wasn't used up by activating it (it contains: " .. fieldNamesOf(tool) ..
			"); skipping it for a minute", Enum.MessageType.MessageWarning)
		geodeToolCooldown[tool] = os.clock() + 60
	end
	setStatus("Idle")
end

-- Loop step. With Auto Farm on, the farm loop opens them itself between digs and washes, since
-- equipping a Geode means putting the pan away.
local function useGeodeStep()
	if enabledLoops.Farm or not canTravel() then return end
	local tool = findGeodeTool()
	if tool then useGeodeTool(tool) end
end

local function farmStep()
	farmHeartbeat = os.clock()
	farmTrace = "farmStep start"
	if not PointToRegion then
		log("Farm: PointToRegion module not found, cannot detect sand/water", Enum.MessageType.MessageError)
		task.wait(5)
		return
	end
	local remote, tool = getPanScript("Pan")
	if not remote then
		log("Farm: no pan found. Tools: " .. describeTools(), Enum.MessageType.MessageWarning)
		task.wait(2)
		return
	end
	local rootPart = getRoot()
	local stats = LocalPlayer:FindFirstChild("Stats")
	if not (rootPart and stats) then
		farmDecision("waiting for the character and Stats to load")
		task.wait(1)
		return
	end

	local scriptsFolder = tool:FindFirstChild("Scripts")
	local character = LocalPlayer.Character
	local capacity = stats:GetAttribute("Capacity") or 1
	local fill = tool:GetAttribute("Fill") or 0
	local needsWash = fill >= capacity * Settings.FarmWashPercent / 100 and fill > 0
	local region = regionAt(rootPart.Position)
	local where = string.format("pan %s/%s, standing in %s", tostring(fill), tostring(capacity), tostring(region))

	-- First round: ask the quest NPCs around for quests before farming (Auto Quest ends the phase).
	if questPhase and not enabledLoops.Quest then questPhase = false end
	if questPhase then
		farmDecision("waiting for Auto Quest to finish asking NPCs for quests")
		if #talkQueue > 0 and canTravel() then
			runTalkQueue()
		else
			setStatus("Asking the nearby NPCs for quests")
			task.wait(0.5)
		end
		return
	end

	-- Auto Collect Geode: a Geode is worth more than the next dig, so go for it whenever we're
	-- free to move (not in the middle of digging or washing).
	if enabledLoops.Geode and canTravel() then
		local geode = nextGeode()
		if geode then
			farmDecision("collecting a Geode", where)
			collectGeodeTrip(geode)
			farmingAnnounced = false
			return
		end
	end

	-- Auto Use Geodes: open any Geode in the inventory before picking the pan back up.
	if enabledLoops.UseGeode and canTravel() then
		local geodeTool = findGeodeTool()
		if geodeTool then
			farmDecision("opening a " .. geodeTool.Name, where)
			useGeodeTool(geodeTool)
			return
		end
	end

	-- Auto Claim Waypoints: same idea, a trip to the next waypoint that isn't unlocked yet.
	if enabledLoops.ClaimWaypoints and canTravel() then
		local waypoint = nextUnclaimedWaypoint()
		if waypoint then
			farmDecision("claiming the " .. waypoint.Name .. " waypoint", where)
			claimWaypointTrip(waypoint)
			farmingAnnounced = false
			return
		end
	end

	-- After that farming comes first. Quest talks queued by Auto Quest run here (so only one loop
	-- moves the character) but only at a quiet moment: with a freshly washed, empty pan after at
	-- least one wash, or when farming has been unable to find or reach sand/water for a moment.
	if #talkQueue > 0 then
		if not enabledLoops.Quest then
			talkQueue = {}
		elseif canTravel() then
			local freshPan = fill <= 0 and farmWashes > 0
			local farmBlocked = os.clock() - farmBlockedAt < 15
			if freshPan or farmBlocked then
				farmDecision("making a quest trip", where)
				runTalkQueue()
				return
			end
		end
	end

	if not character:GetAttribute("Panning") and shouldSell() then
		farmDecision("selling", where)
		sellTrip()
	elseif character:GetAttribute("Panning") or (needsWash and region == "Water") then
		farmDecision("washing the pan", where)
		rememberedSpots.Water = rootPart.Position
		washOnce(tool, scriptsFolder, stats)
	elseif needsWash then
		farmDecision("pan is full, heading to the water", where)
		goToSpot("Water", Settings.WaterWaypoint)
	elseif region == "Deposit" then
		farmDecision("digging", where)
		rememberedSpots.Deposit = rootPart.Position
		digOnce(scriptsFolder, stats)
	else
		farmDecision("heading to the sand", where)
		goToSpot("Deposit", Settings.SandWaypoint)
	end
end

local Actions = {
	Farm = farmStep,
	Geode = geodeStep,
	ClaimWaypoints = claimStep,
	UseGeode = useGeodeStep,
	Quest = questTick,
	Pan = function()
		usePan("Pan", function(remote) return remote:InvokeServer() end)
	end,
	Collect = function()
		usePan("Collect", function(remote) return remote:InvokeServer(1, false) end)
	end,
	Shake = function()
		usePan("Shake", function(remote) remote:FireServer() end)
	end,
	SellAll = function()
		-- Valuables are also quest items, so hand in anything a quest needs before selling.
		if enabledLoops.Quest then submitQuestItems() end
		-- The game's button treats the return value as the amount sold (0 = nothing sold).
		local result = ShopRemotes.SellAll:InvokeServer()
		if type(result) == "number" and result > 0 then
			log("SellAll: sold for $" .. result)
		elseif result == 0 or not result then
			log("SellAll: nothing sold" .. (LocalPlayer:GetAttribute("SellAnywhere") and ""
				or " (no SellAnywhere pass, you may need to stand at the seller)"), Enum.MessageType.MessageWarning)
		else
			logVerbose("SellAll (" .. tostring(result) .. ")")
		end
		return result
	end,
	-- Mirrors DailyRewardLocal: it waits for these attributes, asks the server for the reward
	-- state (first return is the day, nil/false when nothing to claim) and then claims.
	Daily = function()
		if not (LocalPlayer:GetAttribute("TutorialCompleted") and LocalPlayer:GetAttribute("DailyRewardUnlocked")) then
			return
		end
		local miscRemotes = Remotes:FindFirstChild("Misc")
		local day, _, amount = miscRemotes.GetDailyRewardData:InvokeServer()
		if not day then return end
		local claimed = miscRemotes.ClaimDailyReward:InvokeServer()
		log(string.format("Daily reward: day %s%s -> %s", tostring(day),
			amount and (", $" .. tostring(amount)) or "", claimed and "claimed" or "rejected"))
	end,
	BuyItem = function()
		local item = getShopItem()
		if not item then
			log("BuyItem: " .. Settings.BuyItem .. " not found in StarterTown", Enum.MessageType.MessageWarning)
			return
		end
		local result = ShopRemotes.BuyItem:InvokeServer(item, Settings.BuyAmount)
		logVerbose("BuyItem " .. Settings.BuyItem .. " x" .. Settings.BuyAmount .. " (" .. tostring(result) .. ")")
	end,
}

sellAll = Actions.SellAll

-- Locate: ESP trackers. Each tracked object gets a Highlight (visible through walls) and a label
-- with its name and distance. Everything is created on the UI thread (see the pump at the top) and
-- kept in a folder under the camera, so it is local only and never touches the objects themselves.
local function espPart(object)
	if object:IsA("BasePart") then return object end
	if object:IsA("Model") and object.PrimaryPart then return object.PrimaryPart end
	return object:FindFirstChildWhichIsA("BasePart", true)
end

-- options: Name (for logs), Color, TextColor, FolderName, Describe(object) -> extra label text (optional),
-- GetTargets() -> list or nil when there is
-- nothing to track, MissingText (logged once when GetTargets returns nil).
local function makeEspTracker(options)
	local tracker = { Enabled = false }
	local esp = {} -- object -> { Highlight, Billboard, Label }
	local folder
	local lastCount

	local function remove(object)
		local entry = esp[object]
		if entry then
			entry.Highlight:Destroy()
			entry.Billboard:Destroy()
			esp[object] = nil
		end
	end

	local function clear()
		for object in pairs(esp) do remove(object) end
	end

	local function create(object, part)
		local highlight = Instance.new("Highlight")
		highlight.Adornee = object
		highlight.FillColor = options.Color
		highlight.FillTransparency = 0.55
		highlight.OutlineColor = Color3.new(1, 1, 1)
		highlight.OutlineTransparency = 0
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = folder

		local billboard = Instance.new("BillboardGui")
		billboard.Adornee = part
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = math.huge
		billboard.Size = UDim2.fromOffset(180, 40)
		billboard.StudsOffset = Vector3.new(0, 3, 0)

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.TextColor3 = options.TextColor
		label.TextStrokeTransparency = 0.3
		label.Parent = billboard
		billboard.Parent = folder

		esp[object] = { Highlight = highlight, Billboard = billboard, Label = label }
		return esp[object]
	end

	-- Runs on the UI thread: adds ESP for new objects, removes it for ones that are gone, and
	-- updates the distance labels.
	function tracker.Refresh()
		if not tracker.Enabled then
			clear()
			lastCount = nil
			return
		end
		local targets = options.GetTargets()
		if not targets then
			clear()
			if lastCount ~= -1 then
				lastCount = -1
				log("Locate: " .. options.MissingText, Enum.MessageType.MessageWarning)
			end
			return
		end

		if not (folder and folder.Parent) then
			folder = ctx:Track(Instance.new("Folder"))
			folder.Name = options.FolderName
			folder.Parent = workspace.CurrentCamera
		end

		local rootPart = getRoot()
		local seen, count = {}, 0
		for _, object in ipairs(targets) do
			local part = espPart(object)
			if part then
				seen[object] = true
				count = count + 1
				local entry = esp[object] or create(object, part)
				local distance = rootPart and (part.Position - rootPart.Position).Magnitude
				local extra = options.Describe and options.Describe(object)
				entry.Label.Text = object.Name .. (extra and (" " .. extra) or "")
					.. (distance and string.format("\n%.0f studs", distance) or "")
			end
		end
		for object in pairs(esp) do
			if not seen[object] then remove(object) end
		end

		if count ~= lastCount then
			lastCount = count
			log(string.format("Locate: showing %d %s(s)", count, options.Name))
		end
	end

	function tracker.Set(enabled)
		if enabled == tracker.Enabled then return end -- e.g. a config load firing the toggle again
		tracker.Enabled = enabled
		if not enabled then
			table.insert(uiQueue, tracker.Refresh) -- clears everything
			log("Locate: " .. options.Name .. " ESP off")
			return
		end
		task.spawn(function()
			while tracker.Enabled and ctx:Alive() do
				table.insert(uiQueue, tracker.Refresh)
				task.wait(0.5)
			end
		end)
	end

	return tracker
end

local runeTracker = makeEspTracker({
	Name = "rune",
	Color = Color3.fromRGB(170, 90, 255),
	TextColor = Color3.fromRGB(215, 175, 255),
	FolderName = "RuneESP",
	MissingText = "workspace.Map.FindableRunes not found (not loaded yet?)",
	GetTargets = function()
		local map = workspace:FindFirstChild("Map")
		local folder = map and map:FindFirstChild("FindableRunes")
		return folder and folder:GetChildren() or nil
	end,
})

local waypointTracker = makeEspTracker({
	Name = "waypoint",
	Color = Color3.fromRGB(80, 200, 255),
	TextColor = Color3.fromRGB(170, 230, 255),
	FolderName = "WaypointESP",
	MissingText = "workspace.Map.Waypoints not found (not loaded yet?)",
	Describe = function(waypoint)
		return unlockedWaypoints[waypoint.Name] == true and "(claimed)" or "(locked)"
	end,
	GetTargets = function()
		local folder = getWaypointsFolder()
		return folder and folder:GetChildren() or nil
	end,
})

local geodeTracker = makeEspTracker({
	Name = "geode",
	Color = Color3.fromRGB(255, 160, 60),
	TextColor = Color3.fromRGB(255, 205, 140),
	FolderName = "GeodeESP",
	MissingText = "no Geode in workspace right now (it will show up when one appears)",
	GetTargets = function()
		local geodes = getGeodes() -- same lookup Auto Collect Geode uses
		return #geodes > 0 and geodes or nil
	end,
})

-- Fast travel, from the game's FastTravelClient: its menu fires
-- FastTravel:FireServer(fromWaypoint, toWaypoint), where fromWaypoint is the waypoint whose prompt
-- was used (nil when a Warp Relic opened the menu). The menu only offers waypoints that
-- GetFastTravelData reports as unlocked; that check is client side, so here the remote is called for
-- any waypoint. The server still has the final say, and the result is checked afterwards.
local travelBusy = false

-- Dropdown entries: the waypoint name, marked when the game says it isn't unlocked yet.
local function waypointOptions()
	local options = {}
	local folder = getWaypointsFolder()
	for _, waypoint in ipairs(folder and folder:GetChildren() or {}) do
		table.insert(options, waypoint.Name .. (unlockedWaypoints[waypoint.Name] == true and "" or " (locked)"))
	end
	table.sort(options)
	return options
end

local function nearestWaypoint()
	local rootPart = getRoot()
	local folder = getWaypointsFolder()
	if not (rootPart and folder) then return nil end
	local best, bestDistance = nil, math.huge
	for _, waypoint in ipairs(folder:GetChildren()) do
		local distance = (waypoint:GetPivot().Position - rootPart.Position).Magnitude
		if distance < bestDistance then best, bestDistance = waypoint, distance end
	end
	return best, bestDistance
end

local function fastTravel(option)
	if travelBusy then return end
	if enabledLoops.Farm then
		log("Fast travel: turn off Auto Farm first, it would walk you straight back", Enum.MessageType.MessageWarning)
		return
	end
	local targetName = string.gsub(tostring(option or ""), " %(locked%)$", "")
	local folder = getWaypointsFolder()
	local target = folder and folder:FindFirstChild(targetName)
	if not target then
		log("Fast travel: pick a waypoint first (or it isn't loaded: " .. targetName .. ")", Enum.MessageType.MessageWarning)
		return
	end

	travelBusy = true
	local origin, distance = nearestWaypoint()
	if origin == target then
		log("Fast travel: you are already at " .. target.Name)
		travelBusy = false
		return
	end

	-- Asks the server to move us (the game's own fast travel, so its anti-cheat expects it) and
	-- reports whether we arrived.
	local function requestTravel(from)
		setStatus("Fast travelling to " .. target.Name)
		log(string.format("Fast travel: %s -> %s%s", from and from.Name or "(no waypoint)", target.Name,
			unlockedWaypoints[target.Name] == true and "" or " (locked)"))
		MiscRemotes.FastTravel:FireServer(from, target)
		task.wait(3)
		local rootPart = getRoot()
		return rootPart ~= nil and (rootPart.Position - target:GetPivot().Position).Magnitude < 75
	end

	-- 1) Right away, from wherever we are.
	local arrived = requestTravel(origin)

	-- 2) Refused and not at a waypoint: the game fires this from a waypoint's prompt, so walk to the
	--    nearest one and ask again.
	if not arrived and origin and distance > 12 then
		log("Fast travel: not allowed from here, walking to the " .. origin.Name .. " waypoint and trying again")
		setStatus("Walking to the " .. origin.Name .. " waypoint")
		restoreMovement()
		if pathWalk(origin:GetPivot().Position, 6, 120, function() return travelBusy end, "waypoint " .. origin.Name) then
			arrived = requestTravel(origin)
		else
			log("Fast travel: could not reach the " .. origin.Name .. " waypoint", Enum.MessageType.MessageWarning)
		end
	end

	if arrived then
		log("Fast travel: arrived at " .. target.Name)
	else
		log("Fast travel: still here, the server refused it (" ..
			(unlockedWaypoints[target.Name] == true and "maybe not close enough to a waypoint" or "the waypoint is locked") .. ")",
			Enum.MessageType.MessageWarning)
	end
	setStatus("Idle")
	travelBusy = false
end

local Farm = ctx:SubTab("Farm", "Lucide:coins")

Farm:AddSection("Auto Farm", "Lucide:repeat")

statusLabel = Farm:AddLabel("State: " .. currentStatus)

local farmToggle = bindToggle("Farm", "FarmDelay", Actions.Farm)

-- Auto Farm also runs Auto Quest (starting quests, turning in items, talking to NPCs), so the
-- quest loop is switched on with it, and switched off again with it unless it was already on.
local questBind = bindToggle("Quest", "QuestDelay", Actions.Quest)
local questToggle
local questStartedByFarm = false

local function setQuestLoop(enabled)
	if (enabledLoops.Quest or false) == enabled then return end
	if enabled then failedNpcs = {} end -- a fresh run gets a fresh chance with every NPC
	questBind(enabled)
end

Farm:AddToggle({
	Text = "Auto Farm",
	Description = "Walks to sand to dig, then to water to wash, and sells, based on pan fill. Turn off Auto Pan/Collect/Shake first",
	Default = false,
	Flag = "auto_farm",
	Callback = function(enabled)
		if enabled then
			farmWashes = 0
			farmingAnnounced = false
			if Settings.FarmWithQuests then
				-- Auto Quest goes first: it asks the quest NPCs around for quests, and farming waits
				-- for that (questPhase) so the bot does not start farming and then walk off again.
				if not enabledLoops.Quest then
					questStartedByFarm = true
					setQuestLoop(true)
					safeSet(questToggle, true)
				end
				questPhase = true
				questPhaseDeadline = os.clock() + 180
				setStatus("Asking the nearby NPCs for quests")
			else
				-- Dig, wash and sell only.
				questPhase = false
				setStatus("Starting to farm")
			end
			lastDecision = nil
			farmHeartbeat = os.clock()
			farmToggle(true)

			-- Watchdog: if the farm loop makes no progress for a while, say where it is stuck.
			farmWatchdog = farmWatchdog + 1
			local mine = farmWatchdog
			task.spawn(function()
				while enabledLoops.Farm and farmWatchdog == mine do
					task.wait(10)
					local quiet = os.clock() - farmHeartbeat
					if enabledLoops.Farm and farmWatchdog == mine and quiet > 25 then
						log(string.format("Farm: no progress for %ds, last seen: %s | state: %s",
							quiet, farmTrace, currentStatus), Enum.MessageType.MessageWarning)
					end
				end
			end)
		else
			farmToggle(false)
			haltMovement()
			questPhase = false
			setStatus("Idle")
			if questStartedByFarm then
				questStartedByFarm = false
				setQuestLoop(false)
				safeSet(questToggle, false)
			end
		end
	end,
})

Farm:AddToggle({
	Text = "Auto Farm Does Quests",
	Description = "Off: Auto Farm only digs, washes and sells. On: it also turns on Auto Quest and asks nearby NPCs for quests first (applies next time Auto Farm is switched on)",
	Default = Settings.FarmWithQuests,
	Flag = "farm_with_quests",
	Callback = function(value) Settings.FarmWithQuests = value end,
})

Farm:AddToggle({
	Text = "Auto Pan",
	Description = "Fires the Pan remote on the pan in your inventory (equips it if needed)",
	Default = false,
	Flag = "auto_pan",
	Callback = bindToggle("Pan", "PanDelay", Actions.Pan),
})

Farm:AddToggle({
	Text = "Auto Collect",
	Description = "Fires the Collect remote on your pan",
	Default = false,
	Flag = "auto_collect",
	Callback = bindToggle("Collect", "CollectDelay", Actions.Collect),
})

Farm:AddToggle({
	Text = "Auto Shake",
	Description = "Fires the Shake remote on your pan",
	Default = false,
	Flag = "auto_shake",
	Callback = bindToggle("Shake", "ShakeDelay", Actions.Shake),
})

questToggle = Farm:AddToggle({
	Text = "Auto Quest",
	Description = "Starts quests, hands in items and talks to quest NPCs (switched on by Auto Farm too)",
	Default = false,
	Flag = "auto_quest",
	Callback = function(enabled)
		if not enabled then questStartedByFarm = false end
		setQuestLoop(enabled)
	end,
})

Farm:AddToggle({
	Text = "Auto Sell All",
	Description = "Sells your inventory on an interval (hands in quest items first if Auto Quest is on)",
	Default = false,
	Flag = "auto_sell",
	Callback = bindToggle("SellAll", "SellDelay", Actions.SellAll),
})

Farm:AddToggle({
	Text = "Auto Buy Item",
	Description = "Repeatedly buys the item set in Settings",
	Default = false,
	Flag = "auto_buy",
	Callback = bindToggle("BuyItem", "BuyDelay", Actions.BuyItem),
})

Farm:AddToggle({
	Text = "Auto Daily Reward",
	Description = "Claims the daily reward whenever it is available",
	Default = false,
	Flag = "auto_daily",
	Callback = bindToggle("Daily", "DailyDelay", Actions.Daily),
})

Farm:AddSection("Waypoints", "Lucide:map-pin")

-- Waypoints are stored as "x, y, z" text in flagged textboxes so the library's config saving keeps
-- them (it only saves controls that have a Flag) and they can be edited by hand.
local waypointBoxes = {}

local function formatWaypoint(position)
	return position and string.format("%.1f, %.1f, %.1f", position.X, position.Y, position.Z) or ""
end

local function parseWaypoint(text)
	local x, y, z = string.match(tostring(text), "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
	if x and tonumber(x) and tonumber(y) and tonumber(z) then
		return Vector3.new(tonumber(x), tonumber(y), tonumber(z))
	end
	return nil
end

local function addWaypointBox(settingKey, text, flag)
	waypointBoxes[settingKey] = Farm:AddTextbox({
		Text = text,
		Description = "x, y, z (empty = not set)",
		Placeholder = "x, y, z",
		Default = formatWaypoint(Settings[settingKey]),
		Flag = flag,
		Callback = function(value) Settings[settingKey] = parseWaypoint(value) end,
	})
end

local function updateWaypoint(settingKey, position)
	Settings[settingKey] = position
	-- Silent: Settings is already updated, so the textbox's own callback has nothing left to do.
	if not safeSet(waypointBoxes[settingKey], formatWaypoint(position), true) then
		log("Waypoint: kept for this session, but the textbox could not be updated so it will not be saved",
			Enum.MessageType.MessageWarning)
	end
end

addWaypointBox("WaterWaypoint", "Water Waypoint", "waypoint_water")
addWaypointBox("SandWaypoint", "Sand Waypoint", "waypoint_sand")
addWaypointBox("SellerPosition", "Seller Waypoint", "waypoint_seller")

-- Saves where the player is standing. Water and sand waypoints must be inside that region, since
-- Auto Farm only starts washing/digging once the game reports the matching region.
local function setWaypoint(settingKey, label, region)
	local rootPart = getRoot()
	if not rootPart then return end
	if region and regionAt(rootPart.Position) ~= region then
		log("Waypoint: you are not standing on " .. label .. ", move onto it and try again", Enum.MessageType.MessageWarning)
		return
	end
	updateWaypoint(settingKey, rootPart.Position)
	log("Waypoint: saved " .. label .. " at " .. formatWaypoint(rootPart.Position))
end

Farm:AddButton({
	Text = "Set Water Waypoint",
	Description = "Stand in the water where you want to wash",
	Icon = "Lucide:waves",
	Callback = function() setWaypoint("WaterWaypoint", "the water", "Water") end,
})

Farm:AddButton({
	Text = "Set Sand Waypoint",
	Description = "Stand on the deposit where you want to dig",
	Icon = "Lucide:mountain",
	Callback = function() setWaypoint("SandWaypoint", "the sand", "Deposit") end,
})

Farm:AddButton({
	Text = "Set Seller Waypoint",
	Description = "Stand next to the NPC that buys valuables",
	Icon = "Lucide:store",
	Callback = function() setWaypoint("SellerPosition", "the seller", nil) end,
})

Farm:AddButton({
	Text = "Clear Waypoints",
	Description = "Auto Farm goes back to scanning for nearby sand and water",
	Icon = "Lucide:trash-2",
	Callback = function()
		updateWaypoint("WaterWaypoint", nil)
		updateWaypoint("SandWaypoint", nil)
		updateWaypoint("SellerPosition", nil)
		log("Waypoint: cleared all waypoints")
	end,
})

Farm:AddSection("Locate", "Lucide:locate")

Farm:AddToggle({
	Text = "Locate All Runes",
	Description = "Shows where every rune in workspace.Map.FindableRunes is, through walls, with its distance",
	Default = false,
	Flag = "locate_runes",
	Callback = function(enabled) runeTracker.Set(enabled) end,
})

Farm:AddToggle({
	Text = "Locate Geode",
	Description = "Shows where the Geode (workspace.Geode) is, through walls, with its distance",
	Default = false,
	Flag = "locate_geode",
	Callback = function(enabled) geodeTracker.Set(enabled) end,
})

Farm:AddToggle({
	Text = "Auto Collect Geode",
	Description = "Walks to the Geode and collects it (with Auto Farm on, it goes between digs and washes)",
	Default = false,
	Flag = "auto_collect_geode",
	Callback = bindToggle("Geode", "GeodeDelay", Actions.Geode),
})

Farm:AddToggle({
	Text = "Auto Use Geodes",
	Description = "Opens Geode tools from your inventory (BackpackTwo) by equipping and using them (with Auto Farm on, between digs and washes)",
	Default = false,
	Flag = "auto_use_geodes",
	Callback = bindToggle("UseGeode", "UseGeodeDelay", Actions.UseGeode),
})

Farm:AddToggle({
	Text = "Locate Waypoints",
	Description = "Shows every waypoint (workspace.Map.Waypoints) through walls, marked claimed or locked, with its distance",
	Default = false,
	Flag = "locate_waypoints",
	Callback = function(enabled) waypointTracker.Set(enabled) end,
})

Farm:AddToggle({
	Text = "Auto Claim Waypoints",
	Description = "Walks to the nearest waypoint that isn't unlocked yet and triggers its prompt to claim it (with Auto Farm on, it goes between digs and washes)",
	Default = false,
	Flag = "auto_claim_waypoints",
	Callback = bindToggle("ClaimWaypoints", "ClaimDelay", Actions.ClaimWaypoints),
})

Farm:AddSection("Fast Travel", "Lucide:map")

local selectedWaypoint
local waypointDropdown = Farm:AddDropdown({
	Text = "Waypoint",
	Description = "Where to travel; '(locked)' ones are not unlocked yet and the server may refuse them",
	Options = waypointOptions(),
	MultiSelect = false,
	Flag = false,
	Callback = function(value) selectedWaypoint = value end,
})

-- The unlock data usually arrives a moment after the panel is built, so relist once it has.
task.delay(3, function()
	local options = waypointOptions()
	table.insert(uiQueue, function() waypointDropdown:Refresh(options) end)
end)

Farm:AddButton({
	Text = "Fast Travel",
	Description = "Travels to the waypoint picked above right away; walks to the nearest waypoint only if the server refuses",
	Icon = "Lucide:send",
	Callback = function() task.spawn(fastTravel, selectedWaypoint) end,
})

Farm:AddButton({
	Text = "Refresh Waypoints",
	Description = "Reloads the waypoint list and which ones are unlocked",
	Icon = "Lucide:refresh-cw",
	Callback = function()
		pcall(function() MiscRemotes.GetFastTravelData:FireServer() end)
		task.delay(1, function()
			local options = waypointOptions()
			table.insert(uiQueue, function() waypointDropdown:Refresh(options) end)
			log(string.format("Fast travel: %d waypoint(s) listed", #options))
		end)
	end,
})

local Config = ctx:SubTab("Settings", "Lucide:settings")

Config:AddSection("Delays", "Lucide:timer")

local function delaySlider(text, flag, key, min, max, default, increment)
	Config:AddSlider({
		Text = text,
		Min = min,
		Max = max,
		Default = default,
		Increment = increment,
		Suffix = "s",
		Flag = flag,
		Callback = function(value) Settings[key] = value end,
	})
end

-- Floors stay above 0.2s so the remotes are never spammed faster than a normal player could.
delaySlider("Pan Delay", "pan_delay", "PanDelay", 0.2, 5, Settings.PanDelay, 0.1)
delaySlider("Collect Delay", "collect_delay", "CollectDelay", 0.2, 5, Settings.CollectDelay, 0.1)
delaySlider("Shake Delay", "shake_delay", "ShakeDelay", 0.2, 5, Settings.ShakeDelay, 0.1)
delaySlider("Quest Delay", "quest_delay", "QuestDelay", 3, 60, Settings.QuestDelay, 1)
Config:AddSlider({
	Text = "Wash At Fill",
	Description = "Auto Farm walks to water once the pan is at least this full",
	Min = 10,
	Max = 100,
	Default = Settings.FarmWashPercent,
	Increment = 5,
	Suffix = "%",
	Flag = "farm_wash_percent",
	Callback = function(value) Settings.FarmWashPercent = value end,
})

delaySlider("Daily Reward Check", "daily_delay", "DailyDelay", 30, 600, Settings.DailyDelay, 10)
delaySlider("Sell Delay", "sell_delay", "SellDelay", 1, 120, Settings.SellDelay, 1)
delaySlider("Buy Delay", "buy_delay", "BuyDelay", 0.5, 30, Settings.BuyDelay, 0.5)

Config:AddSection("Auto Farm Selling", "Lucide:coins")

Config:AddToggle({
	Text = "Sell Trips",
	Description = "Auto Farm walks to the seller and sells valuables when your inventory has enough",
	Default = Settings.AutoSellTrips,
	Flag = "auto_sell_trips",
	Callback = function(value) Settings.AutoSellTrips = value end,
})

Config:AddSlider({
	Text = "Sell At Items",
	Description = "Auto Farm sells once this many sellable items are in your inventory (e.g. 100 of 500 space)",
	Min = 1,
	Max = 500,
	Default = Settings.SellAtItems,
	Increment = 1,
	Flag = "sell_at_items",
	Callback = function(value) Settings.SellAtItems = value end,
})

local sellerBox = Config:AddTextbox({
	Text = "Seller NPC",
	Description = "Exact name of the NPC that buys valuables",
	Placeholder = "NPC name",
	Default = Settings.SellerName,
	Flag = "seller_npc",
	Callback = function(text) Settings.SellerName = text end,
})

Config:AddButton({
	Text = "Set Seller Here",
	Description = "Stand next to the seller first. Uses the closest NPC within 20 studs",
	Icon = "Lucide:map-pin",
	Callback = function()
		local rootPart = getRoot()
		local npcs = workspace:FindFirstChild("NPCs")
		if not (rootPart and npcs) then return end
		local nearest, nearestDistance = nil, 20
		for _, npc in ipairs(npcs:GetDescendants()) do
			if npc:IsA("Model") and npc:FindFirstChild("Dialog") then
				local distance = (npc:GetPivot().Position - rootPart.Position).Magnitude
				if distance < nearestDistance then nearest, nearestDistance = npc, distance end
			end
		end
		if nearest then
			Settings.SellerName = nearest.Name
			safeSet(sellerBox, nearest.Name)
			updateWaypoint("SellerPosition", nil) -- a saved waypoint would override the NPC
			log("Seller set to NPC " .. nearest.Name)
		else
			updateWaypoint("SellerPosition", rootPart.Position)
			log("No NPC within 20 studs, saved your current position as the seller spot", Enum.MessageType.MessageWarning)
		end
	end,
})

Config:AddSection("Quests", "Lucide:scroll")

Config:AddToggle({
	Text = "Auto Start Quests",
	Description = "Auto Quest also starts quests the server says can be started (talks to the NPC)",
	Default = Settings.AutoStartQuests,
	Flag = "auto_start_quests",
	Callback = function(value) Settings.AutoStartQuests = value end,
})

Config:AddSlider({
	Text = "Max Active Quests",
	Description = "Auto Quest stops starting new quests once this many are in progress",
	Min = 1,
	Max = 30,
	Default = Settings.MaxActiveQuests,
	Increment = 1,
	Flag = "max_active_quests",
	Callback = function(value) Settings.MaxActiveQuests = value end,
})

Config:AddToggle({
	Text = "Limit Quest NPCs To Radius",
	Description = "Auto Quest only uses quest NPCs close to you instead of the whole map",
	Default = Settings.QuestRadiusEnabled,
	Flag = "quest_radius_enabled",
	Callback = function(value) Settings.QuestRadiusEnabled = value end,
})

Config:AddSlider({
	Text = "Quest NPC Radius",
	Description = "Studs around you that count as close enough for starting quests and talking to NPCs",
	Min = 25,
	Max = 2000,
	Default = Settings.QuestRadius,
	Increment = 25,
	Suffix = " studs",
	Flag = "quest_radius",
	Callback = function(value) Settings.QuestRadius = value end,
})

Config:AddToggle({
	Text = "Walk To Quest NPCs",
	Description = "Walk up to an NPC (pathfinding) before talking to them, then walk back",
	Default = Settings.QuestWalk,
	Flag = "quest_walk",
	Callback = function(value) Settings.QuestWalk = value end,
})

Config:AddSection("Buy Item", "Lucide:shopping-cart")

Config:AddSlider({
	Text = "Buy Amount",
	Min = 1,
	Max = 10,
	Default = Settings.BuyAmount,
	Increment = 1,
	Flag = "buy_amount",
	Callback = function(value) Settings.BuyAmount = value end,
})

Config:AddSection("Performance", "Lucide:gauge")

Config:AddToggle({
	Text = "Disable 3D Rendering",
	Description = "Stops drawing the 3D world (black screen) to save GPU/CPU while farming. The UI and scripts keep running",
	Default = false,
	Flag = "disable_3d_rendering",
	Callback = function(disabled)
		local ok, err = pcall(function() RunService:Set3dRenderingEnabled(not disabled) end)
		if ok then
			log("3D rendering " .. (disabled and "disabled" or "enabled"))
		else
			log("Could not change 3D rendering: " .. tostring(err), Enum.MessageType.MessageError)
		end
	end,
})

local Debug = ctx:SubTab("Debug", "Lucide:bug")

Debug:AddToggle({
	Text = "Verbose Logs",
	Description = "Also log every successful remote call and its return value",
	Default = Settings.VerboseLogs,
	Flag = "verbose_logs",
	Callback = function(value) Settings.VerboseLogs = value end,
})

Debug:AddButton({
	Text = "Dump Nearby NPC Dialog",
	Description = "Logs the dialog structure of the closest NPC (within 30 studs) to the Debug Console",
	Icon = "Lucide:message-square",
	Callback = function()
		local rootPart = getRoot()
		local npcs = workspace:FindFirstChild("NPCs")
		if not (rootPart and npcs) then return end
		local nearest, nearestDistance = nil, 30
		for _, npc in ipairs(npcs:GetDescendants()) do
			if npc:IsA("Model") and npc:FindFirstChild("Dialog") then
				local distance = (npc:GetPivot().Position - rootPart.Position).Magnitude
				if distance < nearestDistance then nearest, nearestDistance = npc, distance end
			end
		end
		if nearest then
			dumpNpcDialog(nearest)
		else
			log("Dialog dump: no NPC with a dialog within 30 studs", Enum.MessageType.MessageWarning)
		end
	end,
})

log("Panel loaded")
