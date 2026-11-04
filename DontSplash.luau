-- Don't Splash
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local State = {
	Stealth = false,
	Clearance = 1.5, -- studs between your replicated feet and the wet line
	AutoRescue = false,
	PebbleRangeOn = false,
	PebbleRange = 30, -- studs
	PebbleHold = 0.5, -- seconds to report the position at a pile
	PebbleStock = false,
	AutoFillCode = false,
	LogRemotes = false,
	Wet = false, -- local verdict, same formula as the game
}

--------------------------------------------------------------------------------
-- Game access
--------------------------------------------------------------------------------

local function knitServices()
	local ok, folder = pcall(function()
		return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
	end)
	return ok and folder or nil
end

local function rescueRemote(name)
	local services = knitServices()
	local re = services and services:FindFirstChild("RescueService")
	re = re and re:FindFirstChild("RE")
	return re and re:FindFirstChild(name)
end

-- RunWorldController gives the real (possibly rising) water level. If it can't
-- be reached from here, fall back to the top of the room's WaterZone.
local RunWorld
task.spawn(function()
	local ok, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
	if not ok then return end
	while not RunWorld do
		local ok2, rw = pcall(Knit.GetController, "RunWorldController")
		if ok2 and rw then
			RunWorld = rw
		else
			task.wait(1)
		end
	end
end)

local function getWaterZones()
	local zones = {}
	local still = workspace:FindFirstChild("StillWater")
	if still then
		for _, d in still:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "WaterZone" then
				table.insert(zones, d)
			end
		end
	end
	return zones
end

local function pointInPart(part, pos)
	local rel = part.CFrame:PointToObjectSpace(pos)
	local half = part.Size / 2
	return math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z
end

-- Returns the wet-line Y (water level + foot margin) for pos, or nil if not over water.
local function wetLineAt(pos)
	if RunWorld then
		local ok, level, margin = pcall(function()
			local room = RunWorld:RoomAt(pos)
			if room == nil then return nil end
			local noise = RunWorld.config and RunWorld.config.NOISE
			return RunWorld:WaterLevel(room, pos), noise and noise.FOOT_MARGIN or 0
		end)
		if ok then
			return level and (level + margin) or nil
		end
	end
	for _, zone in getWaterZones() do
		if pointInPart(zone, pos) then
			return zone.Position.Y + zone.Size.Y / 2
		end
	end
	return nil
end

local function creatureParts()
	local still = workspace:FindFirstChild("StillWater")
	local folder = still and still:FindFirstChild("Creatures")
	return folder and folder:GetChildren() or {}
end

local function nearestCreatureDist(pos)
	local best = math.huge
	for _, c in creatureParts() do
		if c:IsA("BasePart") then
			local d = Vector3.new(c.Position.X - pos.X, 0, c.Position.Z - pos.Z).Magnitude
			best = math.min(best, d)
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Position desync: lift the root on Heartbeat (after physics, before the
-- position is replicated), then undo the lift before anything else uses it.
-- The undo runs at three points, whichever comes first:
--   * the next Heartbeat itself (render frames can be skipped, e.g. when the
--     window is in the background, and stacked lifts leak into the real position)
--   * the start of the next render frame (so the camera never shows the fake)
--   * Stepped, right before the next physics step
-- Undo subtracts the offset instead of restoring a saved CFrame, so movement or
-- rotation applied by game scripts in between is kept.
--------------------------------------------------------------------------------

local pending -- { root = BasePart, offset = Vector3 } while an offset is applied
local pebbleTarget -- { part = BasePart, expires = number } while grabbing a pile

local function undoLift()
	if pending then
		if pending.root.Parent then
			pending.root.CFrame = pending.root.CFrame - pending.offset
		end
		pending = nil
	end
end

local Last = { lift = 0, footY = 0, wetLine = nil } -- for diagnostics

local function notifyPebbleFailed(text)
	ctx.Notify("Pebble grab failed: " .. text, "warning", 4)
end

local function log(msg, level)
	ctx.Log(tostring(msg), level)
end

-- Recent water / grab events, included in the dump so no console copying is needed.
local History = {}
local function record(msg)
	local line = ("[%.1fs] %s"):format(os.clock(), msg)
	table.insert(History, line)
	if #History > 40 then table.remove(History, 1) end
	log(msg)
end

ctx:Connect(RunService.Heartbeat, function()
	undoLift()

	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not (root and humanoid and humanoid.Health > 0) then
		State.Wet = false
		return
	end

	local pos = root.Position
	local footY = pos.Y - root.Size.Y / 2 - humanoid.HipHeight
	local wetLine = wetLineAt(pos)
	local wet = wetLine ~= nil and footY < wetLine

	if wet ~= State.Wet then
		State.Wet = wet
		record(("Local wet -> %s | stealth=%s realFoot=%.2f wetLine=%s"):format(
			tostring(wet), tostring(State.Stealth), footY, tostring(wetLine)))
	end

	local lift = 0
	if State.Stealth and wetLine then
		lift = math.max(lift, wetLine + State.Clearance - footY)
	end

	Last.lift, Last.footY, Last.wetLine, Last.realPos = lift, footY, wetLine, pos

	local offset = Vector3.new(0, math.max(lift, 0), 0)

	if pebbleTarget then
		local part = pebbleTarget.part
		if os.clock() < pebbleTarget.expires and part:IsDescendantOf(workspace)
			and not LocalPlayer:GetAttribute("Downed") then
			local target = part.Position
			local sentFoot = target.Y
			-- With stealth on, don't let a pile in the water get you flagged.
			local targetWetLine = State.Stealth and wetLineAt(target)
			if targetWetLine then
				sentFoot = math.max(sentFoot, targetWetLine + State.Clearance)
			end
			offset = Vector3.new(target.X - pos.X, sentFoot - footY, target.Z - pos.Z)
		else
			pebbleTarget = nil
			if part:IsDescendantOf(workspace) then
				record("Pebble grab: pile still there, likely missed")
				task.spawn(notifyPebbleFailed, "A pile in range wasn't collected. The grab may have missed.")
			else
				record("Pebble grab: pile collected")
			end
		end
	end

	if offset ~= Vector3.zero then
		root.CFrame = root.CFrame + offset
		pending = { root = root, offset = offset }
	end
end)

RunService:BindToRenderStep("DontSpawnRestore", Enum.RenderPriority.First.Value, undoLift)
ctx:OnCleanup(function()
	pcall(function() RunService:UnbindFromRenderStep("DontSpawnRestore") end)
	pebbleTarget = nil
	undoLift()
end)
ctx:Connect(RunService.Stepped, undoLift)

-- Server-side verdict: if this stays false while you swim, stealth is working.
ctx:Connect(LocalPlayer:GetAttributeChangedSignal("InWater"), function()
	local v = LocalPlayer:GetAttribute("InWater")
	-- sentFoot is the foot height the server should be seeing.
	record(("Server InWater -> %s | stealth=%s downed=%s localWet=%s realFoot=%.2f sentFoot=%.2f wetLine=%s"):format(
		tostring(v), tostring(State.Stealth), tostring(LocalPlayer:GetAttribute("Downed")),
		tostring(State.Wet), Last.footY, Last.footY + Last.lift, tostring(Last.wetLine)))
	if State.Stealth and v == true and not LocalPlayer:GetAttribute("Downed") then
		ctx.Notify("Server flagged you InWater, raise Clearance", "warning", 4)
	end
end)

--------------------------------------------------------------------------------
-- Auto Self-Rescue
--------------------------------------------------------------------------------

local grabbed = false
local tokens = 0

local function trySelfRescue()
	local remote = rescueRemote("SelfRescue")
	if not remote then return end
	-- Keep trying until Freed arrives (the server may ignore it during the
	-- jumpscare), as long as we still have tokens.
	for _ = 1, 10 do
		if not (grabbed and State.AutoRescue and tokens > 0) then return end
		remote:FireServer()
		task.wait(0.75)
	end
end

task.spawn(function()
	local grabbedRE, refreshRE, freedRE
	repeat
		grabbedRE, refreshRE, freedRE = rescueRemote("Grabbed"), rescueRemote("RescueRefresh"), rescueRemote("Freed")
		if not (grabbedRE and refreshRE and freedRE) then task.wait(1) end
	until grabbedRE and refreshRE and freedRE

	ctx:Connect(grabbedRE.OnClientEvent, function(window, tokenCount, _, offer)
		grabbed = true
		tokens = tokenCount or 0
		record(("GRABBED | window=%s tokens=%s offer=%s stealth=%s localWet=%s nearestCreature=%.1f"):format(
			tostring(window), tostring(tokenCount), tostring(offer), tostring(State.Stealth),
			tostring(State.Wet), nearestCreatureDist(Last.realPos or Vector3.zero)))
		if State.AutoRescue then
			if tokens > 0 then
				task.spawn(trySelfRescue)
			else
				ctx.Notify("Grabbed with no self-rescue tokens, ask for help (H)", "error", 5)
			end
		end
	end)
	ctx:Connect(refreshRE.OnClientEvent, function(tokenCount)
		tokens = tokenCount or 0
	end)
	ctx:Connect(freedRE.OnClientEvent, function()
		grabbed = false
	end)
	ctx:Connect(LocalPlayer.CharacterAdded, function()
		grabbed = false
	end)
end)

--------------------------------------------------------------------------------
-- Remote logger (diagnostics only)
--------------------------------------------------------------------------------

local REMOTE_METHODS = { FireServer = true, InvokeServer = true }

-- The hook runs on the game's threads, so its lines are handed to the script's
-- own thread to be logged, instead of building UI from inside the hook.
local remoteLines = {}

local function remotePath(remote)
	local ok, full = pcall(function() return remote:GetFullName() end)
	return ok and full or tostring(remote)
end

ctx:HookMeta(game, "__namecall", function(oldNamecall, self, ...)
	if State.LogRemotes and not checkcaller() then
		local method = getnamecallmethod()
		if REMOTE_METHODS[method] and typeof(self) == "Instance" then
			-- pcall so an odd argument can't break the game's own remote call.
			local args = { ... }
			pcall(function()
				local parts = { method, remotePath(self) }
				for i = 1, #args do
					table.insert(parts, tostring(args[i]))
				end
				table.insert(remoteLines, table.concat(parts, " "))
				if #remoteLines > 200 then table.remove(remoteLines, 1) end
			end)
		end
	end
	return oldNamecall(self, ...)
end)

--------------------------------------------------------------------------------
-- ESP: a box and label drawn through walls. The targets may be invisible parts,
-- so this uses an adornment rather than a Highlight, which doesn't render on
-- fully transparent parts.
--------------------------------------------------------------------------------

local function espOrigin()
	local camera = workspace.CurrentCamera
	return Last.realPos or (camera and camera.CFrame.Position) or Vector3.zero
end

-- getTargets() returns a list of BaseParts; describe(part) returns color, text.
-- labelOnly hides the box, for targets as big as a floor.
-- Returns a function that turns this ESP on or off.
local function createEsp(name, minSize, getTargets, describe, labelOnly)
	local gui
	local items = {} -- [part] = { box, billboard, label }

	local function add(part)
		local box = Instance.new("BoxHandleAdornment")
		box.Adornee = part
		box.AlwaysOnTop = true
		box.ZIndex = 5
		box.Transparency = 0.45
		box.Visible = not labelOnly
		box.Parent = gui

		local billboard = Instance.new("BillboardGui")
		billboard.Adornee = part
		billboard.AlwaysOnTop = true
		billboard.Size = UDim2.fromOffset(200, 40)
		billboard.Parent = gui

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.3
		label.Parent = billboard

		items[part] = { box = box, billboard = billboard, label = label }
	end

	local function update()
		local seen = {}
		for _, part in getTargets() do
			seen[part] = true
			if not items[part] then
				add(part)
			end
			local item = items[part]
			local color, text = describe(part)
			-- Keep tiny parts visible from a distance.
			item.box.Size = part.Size:Max(Vector3.one * minSize)
			item.box.Color3 = color
			item.billboard.StudsOffset = Vector3.new(0, item.box.Size.Y / 2 + 2, 0)
			item.label.TextColor3 = color
			item.label.Text = text
		end

		for part, item in items do
			if not seen[part] then
				item.box:Destroy()
				item.billboard:Destroy()
				items[part] = nil
			end
		end
	end

	return function(on)
		if gui then
			gui:Destroy()
			gui = nil
			table.clear(items)
		end
		if not on then return end

		local thisGui = Instance.new("ScreenGui")
		thisGui.Name = name
		thisGui.ResetOnSpawn = false
		thisGui.Parent = gethui and gethui() or game:GetService("CoreGui")
		ctx:Track(thisGui)
		gui = thisGui

		task.spawn(function()
			while gui == thisGui do
				update()
				task.wait(0.2)
			end
		end)
	end
end

local CREATURE_STATE_COLORS = {
	Patrol = Color3.fromRGB(255, 220, 70),
	Search = Color3.fromRGB(255, 150, 40),
}
local CREATURE_ALERT_COLOR = Color3.fromRGB(255, 60, 60) -- any other state, e.g. a chase

local setCreatureEsp = createEsp("DontSplashCreatureESP", 3, function()
	local parts = {}
	for _, c in creatureParts() do
		if c:IsA("BasePart") then
			table.insert(parts, c)
		end
	end
	return parts
end, function(part)
	local state = part:GetAttribute("State") or "?"
	return CREATURE_STATE_COLORS[state] or CREATURE_ALERT_COLOR, ("%s\n%s | %d studs"):format(
		part.Name, tostring(state), math.floor((part.Position - espOrigin()).Magnitude))
end)

--------------------------------------------------------------------------------
-- Pebbles
--------------------------------------------------------------------------------

local PEBBLE_COLOR = Color3.fromRGB(90, 220, 255)

local function pebbleFolder()
	local still = workspace:FindFirstChild("StillWater")
	return still and still:FindFirstChild("PebblePickups")
end

-- One part per pickup, whether a pickup is a single Part or a Model.
local function pebbleParts()
	local parts = {}
	local folder = pebbleFolder()
	if folder then
		for _, child in folder:GetChildren() do
			local part = child:IsA("BasePart") and child or child:FindFirstChildWhichIsA("BasePart", true)
			if part then
				table.insert(parts, part)
			end
		end
	end
	return parts
end

local setPebbleEsp = createEsp("DontSplashPebbleESP", 1.5, pebbleParts, function(part)
	return PEBBLE_COLOR, ("Pebble\n%d studs"):format(math.floor((part.Position - espOrigin()).Magnitude))
end)

-- Pickup range. Piles have no prompt or touch detector and the game has no pickup
-- remote, so the server must collect them from your replicated position. This
-- briefly reports your position at a pile in range, one pile at a time, using the
-- same position spoof as Water Stealth (see the Heartbeat handler above).
-- Every grab is a position jump the anti-cheat can see, so they're kept rare.
local PEBBLE_GRAB_GAP = 6 -- minimum seconds between any two grabs
local PEBBLE_CREATURE_SAFETY = 25 -- skip piles with a creature this close

local pebbleTried = setmetatable({}, { __mode = "k" }) -- [part] = true; one try per pile
local lastPebbleGrab = 0

-- The server owns the count (Player attribute "Kit"); it can't be set from here.
local function readPebbleCount()
	local ok, kit = pcall(function()
		return game:GetService("HttpService"):JSONDecode(LocalPlayer:GetAttribute("Kit"))
	end)
	return ok and kit.counts and kit.counts.Pebble or nil
end

-- Returns true if it started a grab, false if no pile qualifies, nil if it's too
-- soon to look.
local function grabNearestPile(maxDistance)
	local origin = Last.realPos
	if pebbleTarget or not origin or LocalPlayer:GetAttribute("Downed") then return end

	local now = os.clock()
	if now - lastPebbleGrab < PEBBLE_GRAB_GAP then return end

	local best, bestDist
	for _, part in pebbleParts() do
		local dist = (part.Position - origin).Magnitude
		if not pebbleTried[part] and dist <= maxDistance and (not best or dist < bestDist)
			and nearestCreatureDist(part.Position) > PEBBLE_CREATURE_SAFETY then
			best, bestDist = part, dist
		end
	end

	if best then
		pebbleTried[best] = true
		lastPebbleGrab = now
		pebbleTarget = { part = best, expires = now + State.PebbleHold }
		record(("Pebble grab: pile %.0f studs away, hold %.1fs, count %s"):format(
			bestDist, State.PebbleHold, tostring(readPebbleCount())))
		return true
	end
	return false
end

local warnedNoPile = false

local function resetPebbleGrabs()
	pebbleTarget = nil
	table.clear(pebbleTried)
end

task.spawn(function()
	while ctx:Alive() do
		-- Stocking only reaches for a pile once you're out.
		local outOfPebbles = State.PebbleStock and readPebbleCount() == 0
		local result
		if State.PebbleRangeOn or outOfPebbles then
			result = grabNearestPile(State.PebbleRange)
		end

		-- Warn once each time you run out with nothing to grab, not on every check.
		if not outOfPebbles then
			warnedNoPile = false
		elseif result == false and not warnedNoPile and pebbleFolder() then
			warnedNoPile = true
			notifyPebbleFailed(("You're out of pebbles and no pile is available within %d studs."):format(State.PebbleRange))
		end
		task.wait(0.2)
	end
end)

-- Log your pebble count, so it's clear whether a grab actually worked.
local lastPebbleCount
ctx:Connect(LocalPlayer:GetAttributeChangedSignal("Kit"), function()
	local count = readPebbleCount()
	if count and count ~= lastPebbleCount then
		record(("Pebble count: %s -> %d"):format(tostring(lastPebbleCount), count))
		lastPebbleCount = count
	end
end)

-- Checks whether the server honours a throw with no pebbles. Sends one UseItem and
-- reports whether a thrown item appears. Only runs at 0, so it never costs a pebble.
local function testFreeThrow()
	local count = readPebbleCount()
	if count ~= 0 then
		log(("Free throw test: needs 0 pebbles, you have %s. Throw them first."):format(tostring(count)),
			"warn")
		return
	end

	local services = knitServices()
	local kitService = services and services:FindFirstChild("RunKitService")
	local useItem = kitService and kitService.RE:FindFirstChild("UseItem")
	local items = workspace:FindFirstChild("StillWaterItems")
	local camera = workspace.CurrentCamera
	if not (useItem and items and camera) then
		log("Free throw test: not in a run", "warn")
		return
	end

	local appeared = false
	local conn = items.ChildAdded:Connect(function()
		appeared = true
	end)
	useItem:FireServer("Pebble", camera.CFrame.LookVector)
	task.wait(1.5)
	conn:Disconnect()

	if appeared then
		record("Free throw test: ACCEPTED, the server threw a pebble at 0")
	else
		record("Free throw test: rejected, the server won't throw at 0")
	end
end

--------------------------------------------------------------------------------
-- Waypoints: labels through walls on the checkpoints and the exit. Names are
-- matched anywhere in StillWater, e.g. Corridor1.Checkpoint1 and ExitCorridor.
--------------------------------------------------------------------------------

local CHECKPOINT_COLOR = Color3.fromRGB(110, 255, 140)
local EXIT_COLOR = Color3.fromRGB(255, 110, 230)
local WAYPOINT_SCAN_INTERVAL = 2 -- StillWater has thousands of descendants

local function waypointColor(inst)
	local name = inst.Name
	if string.find(name, "^Checkpoint") then
		return CHECKPOINT_COLOR
	elseif name == "ExitCorridor" then
		return EXIT_COLOR
	end
	return nil
end

local waypointInfo = {} -- [part] = { name, color }
local waypointParts = {}
local lastWaypointScan = 0

local function scanWaypoints()
	if os.clock() - lastWaypointScan < WAYPOINT_SCAN_INTERVAL then
		return waypointParts
	end
	lastWaypointScan = os.clock()
	waypointInfo, waypointParts = {}, {}

	local still = workspace:FindFirstChild("StillWater")
	if still then
		for _, d in still:GetDescendants() do
			local color = (d:IsA("BasePart") or d:IsA("Model")) and waypointColor(d)
			-- A match inside a match is the same waypoint, e.g. a Checkpoint's parts.
			if color and not waypointColor(d.Parent) then
				local part = d:IsA("BasePart") and d or d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart", true)
				if part then
					waypointInfo[part] = { name = d.Name, color = color }
					table.insert(waypointParts, part)
				end
			end
		end
	end
	return waypointParts
end

local setWaypoints = createEsp("DontSplashWaypoints", 4, scanWaypoints, function(part)
	local info = waypointInfo[part]
	return info.color, ("%s\n%d studs"):format(info.name, math.floor((part.Position - espOrigin()).Magnitude))
end, true)

--------------------------------------------------------------------------------
-- Memory room: PoolStagesService.RE.MemFlash(startTime, { { MemId, order } }, ...)
-- gives the client the real tiles before they light up. Every other tile drops.
--------------------------------------------------------------------------------

local SAFE_TILE_COLOR = Color3.fromRGB(110, 255, 140)

local safeTileIds = {} -- [MemId] = true, from the last MemFlash
local sawMemoryEvent = false
local poolStages

local function getPoolStages()
	if not poolStages then
		local ok, controller = pcall(function()
			return require(ReplicatedStorage.Packages.Knit).GetController("PoolStagesController")
		end)
		poolStages = ok and controller or nil
	end
	return poolStages
end

-- If the flash came before this script loaded, the game's controller still has it.
-- It only knows tiles that had loaded by then, so the event is preferred.
local function controllerSaysSafe(tile)
	local controller = getPoolStages()
	return controller ~= nil and controller.memReal ~= nil and controller.memReal[tile] == true
end

local function safeTiles()
	local tiles = {}
	local still = workspace:FindFirstChild("StillWater")
	local room = still and still:FindFirstChild("Room7_MemoryBridge")
	if room then
		for _, d in room:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute("MemTile") and not d:GetAttribute("Dropped") then
				local safe
				if sawMemoryEvent then
					safe = safeTileIds[d:GetAttribute("MemId")]
				else
					safe = controllerSaysSafe(d)
				end
				if safe then
					table.insert(tiles, d)
				end
			end
		end
	end
	return tiles
end

local setSafeTiles = createEsp("DontSplashSafeTiles", 0, safeTiles, function()
	return SAFE_TILE_COLOR, ""
end)

local function serviceRemote(service, name)
	local services = knitServices()
	local folder = services and services:FindFirstChild(service)
	local re = folder and folder:FindFirstChild("RE")
	return re and re:FindFirstChild(name)
end

task.spawn(function()
	local memFlash, restart
	repeat
		memFlash, restart = serviceRemote("PoolStagesService", "MemFlash"), serviceRemote("RunSessionService", "Restart")
		if not (memFlash and restart) then task.wait(1) end
	until memFlash and restart

	ctx:Connect(memFlash.OnClientEvent, function(_, tiles)
		if type(tiles) ~= "table" then return end
		sawMemoryEvent = true
		table.clear(safeTileIds)
		local count = 0
		for _, entry in tiles do
			safeTileIds[entry[1]] = true
			count = count + 1
		end
		record(("Memory room: %d safe tiles"):format(count))
	end)

	-- A restart makes the old path stale, and the controller keeps it until the
	-- next flash, so show nothing rather than tiles that might drop you.
	ctx:Connect(restart.OnClientEvent, function()
		sawMemoryEvent = true
		table.clear(safeTileIds)
	end)
end)

--------------------------------------------------------------------------------
-- Room 9 code: the digits are the room's CodeNumber parts. The game's camera sends
-- PoolStagesService.RE.Photo(look, position) and the server replies with
-- PhotoResult(slot, digit), with slot 0 for a miss. config.CODE sets the limits:
-- PHOTO_RANGE to the number, PHOTO_ANGLE off the look direction, and
-- PHOTO_CAMERA_REACH for how far the camera may be from the character.
-- The numbers are spread out, so this keeps running while you're in the room.
--------------------------------------------------------------------------------

local CODE_SHOT_GAP = 1.2 -- the game's camera allows one photo per second
local CODE_RETRY = 5 -- seconds before photographing the same number again
local CODE_NUMBER_COLOR = Color3.fromRGB(255, 220, 70)

local codeDone, codeLastTry = {}, {} -- per CodeNumber part, for the current run
local codeAnnounced = false
local codeSlots = {} -- [slot] = digit, from PhotoResult
local lastPhotoSlot

local function codeConfig()
	local controller = getPoolStages()
	return controller and controller.config and controller.config.CODE or {}
end

local function codeTaken()
	local controller = getPoolStages()
	local still = controller and controller.stillWater or workspace:FindFirstChild("StillWater")
	return still and still:GetAttribute("CodeTaken") or ""
end

-- The higher of what the game has stored and what photo results have reported.
local function codeProgress()
	local slots = 0
	for _ in codeSlots do
		slots = slots + 1
	end
	local _, taken = string.gsub(codeTaken(), "%d", "")
	return math.max(slots, taken), codeConfig().DIGITS or 4
end

local function codeComplete()
	local progress, digits = codeProgress()
	return progress >= digits
end

local function codeNumbers(room)
	local parts = {}
	for _, d in (room:FindFirstChild("Gen") or room):GetDescendants() do
		if d.Name == "CodeNumber" and d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

local function lockedExitRoom()
	local still = workspace:FindFirstChild("StillWater")
	return still and still:FindFirstChild("Room9_LockedExit")
end

-- Takes one photo if a number is available. Returns true if it did.
local function photographNextNumber()
	local controller = getPoolStages()
	local room = lockedExitRoom()
	local photo = serviceRemote("PoolStagesService", "Photo")
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (controller and controller.inLastRoom and room and photo and root)
		or LocalPlayer:GetAttribute("Downed") then
		return false
	end

	local config = codeConfig()
	local range = config.PHOTO_RANGE or 70
	local reach = (config.PHOTO_CAMERA_REACH or 26) - 2 -- stay inside the limit
	local now = os.clock()
	local numbers = codeNumbers(room)
	local target, targetDist

	for _, part in numbers do
		local dist = (part.Position - root.Position).Magnitude
		if not codeDone[part] and now - (codeLastTry[part] or 0) >= CODE_RETRY
			and dist <= range + reach and (not target or dist < targetDist) then
			target, targetDist = part, dist
		end
	end

	if not target then
		-- A hit can credit a different number in frame, so try them all again.
		local remaining = 0
		for _, part in numbers do
			if not codeDone[part] then
				remaining = remaining + 1
			end
		end
		if remaining == 0 then
			table.clear(codeDone)
		end
		return false
	end

	-- Put the camera as close as the game allows, within its own limit.
	local offset = math.clamp(targetDist - 10, 0, reach)
	local from = root.Position + (target.Position - root.Position).Unit * offset
	codeLastTry[target] = now
	lastPhotoSlot = nil
	record(("Room 9 code: photo of a number %.0f studs away"):format(targetDist))
	photo:FireServer((target.Position - from).Unit, from)
	task.wait(CODE_SHOT_GAP)
	if lastPhotoSlot and lastPhotoSlot > 0 then
		codeDone[target] = true
	end
	return true
end

task.spawn(function()
	while ctx:Alive() do
		if State.AutoFillCode then
			if codeComplete() then
				if not codeAnnounced then
					codeAnnounced = true
					record(("Room 9 code: complete, CodeTaken '%s'"):format(codeTaken()))
					ctx.Notify("Auto Fill Code: all digits collected", "success", 5)
				end
			elseif not photographNextNumber() then
				task.wait(0.3)
			end
		else
			task.wait(0.3)
		end
		task.wait()
	end
end)

local setCodeWaypoints = createEsp("DontSplashCodeWaypoints", 3, function()
	local room = lockedExitRoom()
	return room and codeNumbers(room) or {}
end, function(part)
	-- Each part carries its digit in SurfaceGui.TextLabel.
	local gui = part:FindFirstChild("SurfaceGui")
	local label = gui and gui:FindFirstChild("TextLabel")
	return CODE_NUMBER_COLOR, ("Code Number: %s\n%d studs"):format(
		label and label.Text or "?", math.floor((part.Position - espOrigin()).Magnitude))
end)

task.spawn(function()
	local photoResult, doorOpen, restart
	repeat
		photoResult = serviceRemote("PoolStagesService", "PhotoResult")
		doorOpen = serviceRemote("PoolStagesService", "DoorOpen")
		restart = serviceRemote("RunSessionService", "Restart")
		if not (photoResult and doorOpen and restart) then task.wait(1) end
	until photoResult and doorOpen and restart

	ctx:Connect(photoResult.OnClientEvent, function(slot, digit)
		lastPhotoSlot = slot
		if type(slot) == "number" and slot > 0 then
			codeSlots[slot] = digit
		end
		record(("Photo result: slot %s, digit %s, CodeTaken '%s'"):format(tostring(slot), tostring(digit), codeTaken()))
	end)
	ctx:Connect(doorOpen.OnClientEvent, function()
		record("Room 9 code: the door opened")
	end)
	ctx:Connect(restart.OnClientEvent, function()
		table.clear(codeSlots)
		table.clear(codeDone)
		table.clear(codeLastTry)
		codeAnnounced = false
	end)
end)

--------------------------------------------------------------------------------
-- Dump helper
--------------------------------------------------------------------------------

local function dumpInfo()
	local lines = {}
	local function add(s) table.insert(lines, s) end

	local function attrs(inst)
		local parts = {}
		for k, v in inst:GetAttributes() do
			table.insert(parts, ("%s=%s"):format(k, tostring(v)))
		end
		return #parts > 0 and (" {" .. table.concat(parts, ", ") .. "}") or ""
	end

	add("== StillWater: WaterZones / Creatures ==")
	local still = workspace:FindFirstChild("StillWater")
	if still then
		for _, zone in getWaterZones() do
			add(("%s CanTouch=%s%s"):format(zone:GetFullName(), tostring(zone.CanTouch), attrs(zone)))
		end
		for _, c in creatureParts() do
			add(("%s [%s]%s"):format(c:GetFullName(), c.ClassName, attrs(c)))
		end
		add("StillWater attrs:" .. attrs(still))

		add("\n== PebblePickups ==")
		local pebbles = pebbleFolder()
		if pebbles then
			local origin = espOrigin()
			local function distanceTo(child)
				local ok, pivot = pcall(function() return child:GetPivot() end)
				return ok and (pivot.Position - origin).Magnitude or math.huge
			end

			local loaded, empty, classes = {}, {}, {}
			for _, child in pebbles:GetChildren() do
				table.insert(#child:GetDescendants() > 0 and loaded or empty, child)
				for _, d in child:GetDescendants() do
					classes[d.ClassName] = (classes[d.ClassName] or 0) + 1
				end
			end
			table.sort(loaded, function(a, b) return distanceTo(a) < distanceTo(b) end)

			add(("%d loaded, %d empty"):format(#loaded, #empty))
			for class, count in classes do
				add(("  %s x%d"):format(class, count))
			end
			add("Nearest loaded piles in full:")
			for i = 1, math.min(2, #loaded) do
				local child = loaded[i]
				add(("%s [%s] dist=%.0f%s"):format(child:GetFullName(), child.ClassName, distanceTo(child), attrs(child)))
				for _, d in child:GetDescendants() do
					add(("  %s [%s]%s"):format(d.Name, d.ClassName, attrs(d)))
				end
			end
			add("Empty piles (does the position still work?):")
			for i = 1, math.min(3, #empty) do
				local ok, pivot = pcall(function() return empty[i]:GetPivot() end)
				add(("  %s pivot=%s"):format(empty[i].Name, ok and tostring(pivot.Position) or "error"))
			end
		else
			add("(missing)")
		end

		add("\n== Possible waypoints (name [class] x count) ==")
		local waypointNames = {}
		for _, d in still:GetDescendants() do
			local lower = string.lower(d.Name)
			for _, word in { "checkpoint", "corridor", "exit", "door", "gate", "finish", "goal", "victory" } do
				if string.find(lower, word, 1, true) then
					local key = ("%s [%s]"):format(d.Name, d.ClassName)
					waypointNames[key] = (waypointNames[key] or 0) + 1
					break
				end
			end
		end
		for key, count in waypointNames do
			add(("  %s x%d"):format(key, count))
		end

		add("\n== Workspace.StillWaterItems ==")
		local items = workspace:FindFirstChild("StillWaterItems")
		if items then
			local names = {}
			for _, d in items:GetDescendants() do
				local key = ("%s [%s]"):format(d.Name, d.ClassName)
				names[key] = (names[key] or 0) + 1
			end
			for key, count in names do
				add(("  %s x%d"):format(key, count))
			end
		else
			add("(missing)")
		end
	else
		add("(missing)")
	end

	add("\n== Water check ==")
	add("RunWorldController reachable: " .. tostring(RunWorld ~= nil))
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then
		add("Wet line here: " .. tostring(wetLineAt(root.Position)) .. "  local wet: " .. tostring(State.Wet))
	end
	add(("Toggles: stealth=%s clearance=%.1f autoRescue=%s"):format(
		tostring(State.Stealth), State.Clearance, tostring(State.AutoRescue)))
	add(("Now: realFoot=%.2f sentFoot=%.2f lift=%.2f"):format(Last.footY, Last.footY + Last.lift, Last.lift))

	add("\n== Recent events (oldest first) ==")
	if #History == 0 then
		add("(none yet - you haven't entered water since the script started)")
	end
	for _, line in History do
		add(line)
	end

	add("\n== LocalPlayer / Character attributes ==")
	add("Player" .. attrs(LocalPlayer))
	if char then
		add("Character" .. attrs(char))
	end

	local text = table.concat(lines, "\n")
	if writefile then
		writefile("DontSpawn_dump.txt", text)
	end
	for _, line in lines do
		log(line)
	end
	return #lines
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function notifyToggle(title, on)
	log(("%s: %s"):format(title, on and "enabled" or "disabled"))
	ctx.Notify(("%s: %s"):format(title, on and "Enabled" or "Disabled"), on and "success" or "info", 3)
end

local Main = ctx:SubTab("Main", "Lucide:house")
Main:AddSection("Water", "Lucide:waves")

Main:AddToggle({
	Text = "Water Stealth",
	Description = "Server sees your feet above the water, so creatures don't detect you",
	Default = false,
	Callback = function(on)
		State.Stealth = on
		notifyToggle("Water Stealth", on)
	end,
})

Main:AddSlider({
	Text = "Clearance",
	Description = "How far above the wet line the server sees your feet",
	Min = 0.5,
	Max = 8,
	Increment = 0.5,
	Default = State.Clearance,
	Suffix = " studs",
	Callback = function(v)
		State.Clearance = v
	end,
})

Main:AddToggle({
	Text = "Auto Self-Rescue",
	Description = "If grabbed and you have tokens, self-rescue immediately",
	Default = false,
	Callback = function(on)
		State.AutoRescue = on
		notifyToggle("Auto Self-Rescue", on)
		if on and grabbed and tokens > 0 then
			task.spawn(trySelfRescue)
		end
	end,
})

Main:AddSection("Room 9", "Lucide:door-open")

Main:AddToggle({
	Text = "Auto Fill Code",
	Description = "While you're in Room 9, photographs the code numbers as they come in range",
	Default = false,
	Callback = function(on)
		State.AutoFillCode = on
		notifyToggle("Auto Fill Code", on)
	end,
})

Main:AddSection("Pebbles", "Lucide:circle-dot")

Main:AddToggle({
	Text = "Increase Pebble Range",
	Description = "Automatically collects pebbles within range, without walking to them",
	Default = false,
	Callback = function(on)
		State.PebbleRangeOn = on
		resetPebbleGrabs()
		notifyToggle("Pebble Range", on)
	end,
})

Main:AddSlider({
	Text = "Pebble Range",
	Description = "Distance you collect pebbles from. Higher is more likely to trip anti-cheat",
	Min = 10,
	Max = 60,
	Increment = 5,
	Default = State.PebbleRange,
	Suffix = " studs",
	Callback = function(v)
		State.PebbleRange = v
	end,
})

Main:AddToggle({
	Text = "Keep Pebble In Stock",
	Description = "At 0 pebbles, grabs the nearest loaded pile within Pebble Range",
	Default = false,
	Callback = function(on)
		State.PebbleStock = on
		resetPebbleGrabs()
		notifyToggle("Keep Pebble In Stock", on)
	end,
})

local Visual = ctx:SubTab("Visuals", "Lucide:eye")
Visual:AddSection("ESP", "Lucide:scan-eye")

Visual:AddToggle({
	Text = "Creature ESP",
	Description = "Shows creatures through walls, with their state and distance",
	Default = false,
	Callback = function(on)
		setCreatureEsp(on)
		notifyToggle("Creature ESP", on)
	end,
})

Visual:AddToggle({
	Text = "Pebble ESP",
	Description = "Shows pebble pickups through walls, with their distance",
	Default = false,
	Callback = function(on)
		setPebbleEsp(on)
		notifyToggle("Pebble ESP", on)
	end,
})

Visual:AddSection("Waypoints", "Lucide:map-pin")

Visual:AddToggle({
	Text = "Checkpoint & Exit Waypoints",
	Description = "Shows checkpoints (green) and exits (pink) through walls, with distance",
	Default = false,
	Callback = function(on)
		setWaypoints(on)
		notifyToggle("Waypoints", on)
	end,
})

Visual:AddToggle({
	Text = "Code Number Waypoints",
	Description = "Shows Room 9's CodeNumber parts through walls, with distance",
	Default = false,
	Callback = function(on)
		setCodeWaypoints(on)
		notifyToggle("Code Number Waypoints", on)
	end,
})

Visual:AddSection("Memory Room", "Lucide:grid-3x3")

Visual:AddToggle({
	Text = "Highlight Safe Tiles",
	Description = "Highlights only the tiles you can stand on, once the room sends its pattern",
	Default = false,
	Callback = function(on)
		setSafeTiles(on)
		notifyToggle("Highlight Safe Tiles", on)
	end,
})

local Debug = ctx:SubTab("Debug", "Lucide:bug")
Debug:AddSection("Diagnostics", "Lucide:activity")

task.spawn(function()
	while ctx:Alive() do
		while #remoteLines > 0 do
			ctx.Log(table.remove(remoteLines, 1), "info")
		end
		task.wait(0.1)
	end
end)

-- Add the game's own output too. This executor's prints don't reach LogService,
-- so anything logged here comes from the game.
ctx:Connect(game:GetService("LogService").MessageOut, function(message, messageType)
	local level = "info"
	if messageType == Enum.MessageType.MessageWarning then
		level = "warn"
	elseif messageType == Enum.MessageType.MessageError then
		level = "error"
	end
	ctx.Log(message, level)
end)

Debug:AddToggle({
	Text = "Log Remotes",
	Description = "Also prints every remote call the game makes (noisy)",
	Flag = false,
	Default = false,
	Callback = function(on)
		State.LogRemotes = on
	end,
})

Debug:AddSlider({
	Text = "Pebble Grab Hold",
	Description = "How long the server sees you at a pile. Longer is more visible to anti-cheat",
	Min = 0.5,
	Max = 3,
	Increment = 0.5,
	Default = State.PebbleHold,
	Suffix = "s",
	Callback = function(v)
		State.PebbleHold = v
	end,
})

Debug:AddButton({
	Text = "Test Free Throw",
	Description = "At 0 pebbles, checks if the server allows a throw. Result shows in the console",
	Callback = function()
		task.spawn(testFreeThrow)
	end,
})

Debug:AddButton({
	Text = "Dump Game Info",
	Description = "Writes DontSpawn_dump.txt to your workspace folder and logs it to the Debug Console",
	Callback = function()
		local n = dumpInfo()
		ctx.Notify(("Wrote %d lines to DontSpawn_dump.txt"):format(n), "success", 4)
	end,
})

ctx.Notify("This game has an anti-cheat that triggers when you stay in the water for too long", "warning", 8)
