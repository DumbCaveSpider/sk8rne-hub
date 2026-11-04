-- Unseen Liminality
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Stats = LocalPlayer:WaitForChild("PlayerData"):WaitForChild("Stats")
local GameObjects = workspace:WaitForChild("GameObjects")
local PictureSpots = Stats:WaitForChild("PictureSpots")

-- [id] = { title, image, description }; only used for nicer names.
local pictureSpotData = {}
do
	local ok, data = pcall(require, game:GetService("ReplicatedStorage").Data.PictureSpots)
	if ok and type(data) == "table" then
		pictureSpotData = data
	end
end

local function getPictureSpotTitle(id)
	local entry = pictureSpotData[id]
	return entry and entry[1] or id
end

local DISCOVER_TIMEOUT = 3 -- seconds to wait at a target for the server to record it
local HOP_DELAY = 0.25
local PICTURE_DISTANCE = 6 -- studs to stand away from a picture spot
local SNAP_INTERVAL = 1 -- seconds between camera tool activations at a spot
local MAX_PASSES = 3 -- skipped targets are retried until this many passes are done
local SCAN_SPACING = 200 -- studs between areas loaded when scanning for picture spots
local ESP_COLOR = Color3.fromRGB(255, 200, 80)

local running = true
local busy = false -- only one discovery job teleports at a time

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function notify(text, kind)
	ctx.Notify(text, kind or "info", 5)
end

local function getRoot()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function touch(root, part)
	if firetouchinterest then
		pcall(firetouchinterest, root, part, 0)
		pcall(firetouchinterest, root, part, 1)
	end
end

-- Nearest still-existing part of a target, and its distance.
local function nearestPart(parts, position)
	local best, bestDistance = nil, math.huge
	for _, part in parts do
		if part.Parent then
			local distance = (part.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = part, distance
			end
		end
	end
	return best, bestDistance
end

-- Where a target is: its nearest loaded part, or the position remembered when it
-- was scanned (parts unload when you teleport far away from them).
local function targetPosition(target, from)
	local part = nearestPart(target.parts, from)
	return part and part.Position or target.position
end

local function popNearest(targets, position)
	local bestIndex, bestDistance = nil, math.huge
	for i, target in targets do
		local at = targetPosition(target, position)
		local distance = at and (at - position).Magnitude or math.huge
		if distance < bestDistance then
			bestIndex, bestDistance = i, distance
		end
	end
	-- A target with no known position still gets its turn instead of stalling the list.
	return table.remove(targets, bestIndex or 1)
end

-- Asks the server to load the map around a position (StreamingEnabled). Yields.
local function streamAround(position)
	if workspace.StreamingEnabled then
		pcall(function()
			LocalPlayer:RequestStreamAroundAsync(position, 5)
		end)
	end
end

--------------------------------------------------------------------------------
-- Discovery jobs
--------------------------------------------------------------------------------

-- Each job lists undiscovered targets ({ name, parts }) and the stat folder whose
-- attributes mark a target as discovered.
local jobs = {
	poi = {
		label = "point(s) of interest",
		store = Stats:WaitForChild("PointsOfInterest"),
		folder = GameObjects:WaitForChild("PointsOfInterest"),
		id = 0,
	},
	region = {
		label = "region(s)",
		store = Stats:WaitForChild("Levels"),
		folder = GameObjects:WaitForChild("RegionParts"),
		id = 0,
	},
	picture = {
		label = "picture spot(s)",
		store = PictureSpots,
		timeout = 6, -- equipping and taking the photo takes longer than a touch
		id = 0,
	},
}

local function isActive(job, id)
	return running and job.id == id
end

-- Default checks/visits; jobs can override them.
local function isDone(job, target)
	if job.isDone then
		return job:isDone(target)
	end
	return job.store:GetAttribute(target.name) ~= nil
end

-- part is the target's nearest loaded part (nil if none is loaded; only custom
-- visits are called then).
local function visit(job, root, target, part)
	if job.visit then
		job:visit(root, target, part)
		return
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = part.CFrame
	touch(root, part)
end

-- Parts of discovered points are removed by the game; the attribute check covers stale duplicates.
function jobs.poi.collect(job)
	local targets = {}
	for _, child in job.folder:GetChildren() do
		if child:IsA("BasePart") and job.store:GetAttribute(child.Name) == nil then
			table.insert(targets, { name = child.Name, parts = { child }, position = child.Position })
		end
	end
	return targets
end

-- A region can be made of several parts anywhere under RegionParts; visit it once.
function jobs.region.collect(job)
	local byName, targets = {}, {}
	for _, descendant in job.folder:GetDescendants() do
		local name = descendant.Name
		if descendant.ClassName == "Part" and job.store:GetAttribute(name) == nil then
			local target = byName[name]
			if not target then
				target = { name = name, parts = {}, position = descendant.Position }
				byName[name] = target
				table.insert(targets, target)
			end
			table.insert(target.parts, descendant)
		end
	end
	return targets
end

-- The game tags a child of each spot part with "PictureSpot"; the part's name is
-- the spot id. Taken spots get PictureSpots[id] = true (or CLAIMED on the part).
local function isPictureTaken(spot)
	return PictureSpots:GetAttribute(spot.Name) == true or spot:GetAttribute("CLAIMED") ~= nil
end

-- [id] = { cframe, part }: every spot seen since the script first ran. Spots unload
-- when you're far away, so their position is remembered.
local spotCache = {}

local function cacheSpot(tagged)
	local spot = tagged.Parent
	if spot and spot:IsA("BasePart") and spot:IsDescendantOf(workspace) then
		spotCache[spot.Name] = { cframe = spot.CFrame, part = spot }
	end
end

for _, tagged in CollectionService:GetTagged("PictureSpot") do
	cacheSpot(tagged)
end
ctx:Connect(CollectionService:GetInstanceAddedSignal("PictureSpot"), function(tagged)
	-- The tag can be added before the object is parented.
	task.defer(cacheSpot, tagged)
end)

local function liveSpot(id)
	local entry = spotCache[id]
	local part = entry and entry.part
	return part and part.Parent and part or nil
end

local function isSpotDone(id)
	local spot = liveSpot(id)
	return PictureSpots:GetAttribute(id) == true or (spot ~= nil and spot:GetAttribute("CLAIMED") ~= nil)
end

-- Spot ids the game lists in Data.PictureSpots that aren't taken and were never loaded.
local function getUnseenSpotIds()
	local ids = {}
	for id in pictureSpotData do
		if not spotCache[id] and PictureSpots:GetAttribute(id) ~= true then
			table.insert(ids, id)
		end
	end
	return ids
end

-- Loads the map around every known landmark (region parts, points of interest,
-- NPCs, cached spots) so spots that never loaded get tagged and cached. Positions
-- closer than SCAN_SPACING are merged so each area is requested once.
local function scanForSpots(job, id)
	if not workspace.StreamingEnabled or #getUnseenSpotIds() == 0 then
		return
	end

	local points = {}
	local function addPoint(position)
		for _, point in points do
			if (point - position).Magnitude < SCAN_SPACING then
				return
			end
		end
		table.insert(points, position)
	end
	for _, folderName in { "RegionParts", "PointsOfInterest", "NPCs" } do
		local folder = GameObjects:FindFirstChild(folderName)
		for _, descendant in folder and folder:GetDescendants() or {} do
			if descendant:IsA("BasePart") then
				addPoint(descendant.Position)
			end
		end
	end
	for _, entry in spotCache do
		addPoint(entry.cframe.Position)
	end

	notify(string.format("Scanning %d area(s) for %d unloaded picture spot(s)", #points, #getUnseenSpotIds()))
	for _, point in points do
		if not isActive(job, id) or #getUnseenSpotIds() == 0 then
			break
		end
		streamAround(point)
		for _, tagged in CollectionService:GetTagged("PictureSpot") do
			cacheSpot(tagged)
		end
	end
end

function jobs.picture.collect()
	for _, tagged in CollectionService:GetTagged("PictureSpot") do
		cacheSpot(tagged)
	end
	local targets = {}
	for id, entry in spotCache do
		if not isSpotDone(id) then
			local spot = liveSpot(id)
			table.insert(targets, {
				name = id,
				parts = spot and { spot } or {},
				position = entry.cframe.Position,
				cframe = entry.cframe,
			})
		end
	end
	return targets
end

function jobs.picture.isDone(_, target)
	return isSpotDone(target.name)
end

jobs.picture.scan = scanForSpots

function jobs.picture.summary()
	local unseen = #getUnseenSpotIds()
	if unseen == 0 then
		return ""
	end
	return string.format(" (%d spot(s) never loaded: walk around and run it again)", unseen)
end

-- The camera tool: any Tool with "camera" in its name, held or in the backpack.
local function findCameraTool()
	for _, container in { LocalPlayer.Character, LocalPlayer:FindFirstChildOfClass("Backpack") } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") and string.find(string.lower(child.Name), "camera", 1, true) then
					return child
				end
			end
		end
	end
	return nil
end

local GameMiscFunction = game:GetService("ReplicatedStorage"):WaitForChild("Events")
	:WaitForChild("RemoteFunctions"):WaitForChild("GameMisc")

local lastSnap = 0

-- Equips the camera tool, then sends the photo the same way the camera does:
-- GameMisc:InvokeServer({ "PictureSpot", { spotId, ...other things in frame } }).
-- Sent at most every SNAP_INTERVAL seconds. Returns false when there's no camera tool.
local function snapPicture(spotId)
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local tool = findCameraTool()
	if humanoid and tool and tool.Parent ~= character then
		humanoid:EquipTool(tool)
		return true -- give the tool a moment to equip before taking the photo
	end
	if os.clock() - lastSnap >= SNAP_INTERVAL then
		lastSnap = os.clock()
		task.spawn(pcall, function()
			GameMiscFunction:InvokeServer({ "PictureSpot", { spotId } })
		end)
	end
	return tool ~= nil
end

-- Where to stand for each attempt at a spot: in front, behind, then right above
-- it, in case one side is inside a wall.
local PICTURE_STANDS = {
	function(cframe)
		return cframe.Position + cframe.LookVector * PICTURE_DISTANCE
	end,
	function(cframe)
		return cframe.Position - cframe.LookVector * PICTURE_DISTANCE
	end,
	function(cframe)
		return cframe.Position + Vector3.new(0, 3, 0)
	end,
}

-- Stand near the spot facing it, aim the camera at it, equip the camera tool and
-- send the photo. Prompts on the spot are fired too, in case it has one.
function jobs.picture.visit(job, root, target, spot)
	local cframe = spot and spot.CFrame or target.cframe
	local focus = cframe.Position
	local stand = PICTURE_STANDS[(target.attempt - 1) % #PICTURE_STANDS + 1]
	local standAt = stand(cframe)
	root.AssemblyLinearVelocity = Vector3.zero
	if (standAt - focus).Magnitude > 0.5 then
		root.CFrame = CFrame.lookAt(standAt, Vector3.new(focus.X, standAt.Y, focus.Z))
	else
		root.CFrame = CFrame.new(standAt)
	end

	-- Re-aimed on every visit tick because the default camera script keeps moving it.
	local camera = workspace.CurrentCamera
	local head = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Head")
	if camera then
		local eye = head and head.Position or camera.CFrame.Position
		camera.CFrame = CFrame.lookAt(eye, focus)
	end

	if not snapPicture(target.name) and not job.warnedNoTool then
		job.warnedNoTool = true
		notify("No camera tool found; sending the photo without it", "info")
	end

	if not spot then
		return
	end
	if fireproximityprompt then
		for _, descendant in spot:GetDescendants() do
			if descendant:IsA("ProximityPrompt") and descendant.Enabled then
				pcall(fireproximityprompt, descendant)
			end
		end
	end
	touch(root, spot)
end

local function discover(job, target, id)
	local root = getRoot()
	if root and not nearestPart(target.parts, root.Position) and target.position then
		-- The target unloaded since it was scanned: go there and load the area first.
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(target.position + Vector3.new(0, 3, 0))
		streamAround(target.position)
		if job.collect then
			for _, fresh in job:collect() do
				if fresh.name == target.name and #fresh.parts > 0 then
					target.parts = fresh.parts
				end
			end
		end
	end

	local deadline = os.clock() + (job.timeout or DISCOVER_TIMEOUT)
	while os.clock() < deadline do
		if not isActive(job, id) or isDone(job, target) then
			break
		end
		root = getRoot()
		local part = root and nearestPart(target.parts, root.Position)
		if root and (part or job.visit) then
			visit(job, root, target, part)
		end
		task.wait(0.1)
	end
	return isDone(job, target)
end

local function runJob(job, id)
	while busy and isActive(job, id) do
		task.wait(0.2)
	end
	if not isActive(job, id) then
		return
	end
	busy = true

	if job.scan then
		job.scan(job, id)
	end

	local remaining = job:collect()
	if #remaining == 0 then
		if isActive(job, id) then
			notify("Every " .. job.label .. " already discovered")
		end
		busy = false
		return
	end
	notify(string.format("Teleporting to %d undiscovered %s", #remaining, job.label))

	-- queued[name] = true for every target already in a pass, so targets that load
	-- in while teleporting around get added once.
	local queued = {}
	for _, target in remaining do
		queued[target.name] = true
		target.attempt = 1
	end

	local found, retry = 0, {}
	local pass = 1
	while isActive(job, id) do
		local root = getRoot()
		if not root then
			task.wait(0.5)
		else
			local target = popNearest(remaining, root.Position)
			if target then
				if not isDone(job, target) then
					if discover(job, target, id) then
						found = found + 1
					elseif isActive(job, id) then
						table.insert(retry, target)
					end
					task.wait(HOP_DELAY)
				end

				for _, fresh in job:collect() do
					if not queued[fresh.name] then
						queued[fresh.name] = true
						fresh.attempt = pass
						table.insert(remaining, fresh)
					end
				end
			elseif #retry > 0 and pass < MAX_PASSES then
				-- Try the skipped ones again, from a different spot.
				pass = pass + 1
				remaining, retry = retry, {}
				for _, skippedTarget in remaining do
					skippedTarget.attempt = pass
				end
				notify(string.format("Retrying %d skipped %s (pass %d/%d)", #remaining, job.label, pass, MAX_PASSES))
			else
				break
			end
		end
	end

	if isActive(job, id) then
		local text = string.format("Done: %d %s discovered, %d skipped", found, job.label, #retry)
		if job.summary then
			text = text .. job.summary()
		end
		notify(text, #retry > 0 and "info" or "success")
	end

	busy = false
end

local function setJob(job, enabled)
	job.id = job.id + 1
	job.warnedNoTool = nil
	if enabled then
		task.spawn(runJob, job, job.id)
	end
end

--------------------------------------------------------------------------------
-- NPC ESP
--------------------------------------------------------------------------------

local NpcFolder = GameObjects:WaitForChild("NPCs")

local espEnabled = false
local espEntries = {} -- [model] = { highlight, billboard, label }

local espGui = Instance.new("Folder")
espGui.Name = "LuminalityESP"
do
	local ok, parent = pcall(function()
		return gethui and gethui() or game:GetService("CoreGui")
	end)
	espGui.Parent = ok and parent or LocalPlayer:WaitForChild("PlayerGui")
end
ctx:Track(espGui)

-- Top-level models anywhere under the NPCs folder (sub-folders included). The
-- ancestor walk stops at the NPCs folder: Workspace itself IsA("Model"), so
-- FindFirstAncestorWhichIsA("Model") would reject every NPC.
local function isNpc(instance)
	if not instance:IsA("Model") then
		return false
	end
	local parent = instance.Parent
	while parent and parent ~= NpcFolder do
		if parent:IsA("Model") then
			return false
		end
		parent = parent.Parent
	end
	return parent == NpcFolder
end

local function getAnchor(model)
	return model.PrimaryPart
		or model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChild("Head")
		or model:FindFirstChildWhichIsA("BasePart", true)
end

local function getNpcName(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.DisplayName ~= "" then
		return humanoid.DisplayName
	end
	return model.Name
end

local function removeEsp(model)
	local entry = espEntries[model]
	if entry then
		entry.highlight:Destroy()
		entry.billboard:Destroy()
		espEntries[model] = nil
	end
end

local function addEsp(model)
	if espEntries[model] then
		return
	end

	-- Parented to the NPC itself: a Highlight there always renders, while one in
	-- gethui()/CoreGui depends on the executor.
	local highlight = Instance.new("Highlight")
	highlight.Name = "LuminalityHighlight"
	highlight.FillColor = ESP_COLOR
	highlight.FillTransparency = 0.6
	highlight.OutlineColor = ESP_COLOR
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = model
	highlight.Parent = model

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(200, 36)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = espGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = ESP_COLOR
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard

	espEntries[model] = { highlight = highlight, billboard = billboard, label = label }
end

local function refreshEsp()
	local root = getRoot()
	for model, entry in espEntries do
		if not model.Parent then
			removeEsp(model)
		else
			-- Put the highlight back if the game removed or destroyed it.
			if entry.highlight.Parent ~= model and not pcall(function()
				entry.highlight.Parent = model
			end) then
				local highlight = entry.highlight:Clone()
				highlight.Parent = model
				entry.highlight = highlight
			end

			local anchor = getAnchor(model)
			entry.billboard.Adornee = anchor
			local text = getNpcName(model)
			if anchor and root then
				text = string.format("%s\n[%d studs]", text, math.floor((anchor.Position - root.Position).Magnitude))
			end
			entry.label.Text = text
		end
	end
end

local function setEsp(enabled)
	espEnabled = enabled
	if enabled then
		for _, descendant in NpcFolder:GetDescendants() do
			if isNpc(descendant) then
				addEsp(descendant)
			end
		end
		refreshEsp()
		local count = 0
		for _ in espEntries do
			count = count + 1
		end
		notify(string.format("NPC ESP on: %d NPC(s) found", count), count > 0 and "success" or "error")
	else
		for model in espEntries do
			removeEsp(model)
		end
	end
end

ctx:Connect(NpcFolder.DescendantAdded, function(descendant)
	if espEnabled and isNpc(descendant) then
		addEsp(descendant)
	end
end)
ctx:Connect(NpcFolder.DescendantRemoving, function(descendant)
	removeEsp(descendant)
end)

do
	local elapsed = 0
	ctx:Connect(RunService.Heartbeat, function(dt)
		elapsed = elapsed + dt
		if espEnabled and elapsed >= 0.2 then
			elapsed = 0
			refreshEsp()
		end
	end)
end

--------------------------------------------------------------------------------
-- Waypoints
--------------------------------------------------------------------------------

-- POI titles, if Data.PointsOfInterest has any; the part name is the fallback.
local poiData = {}
do
	local ok, data = pcall(require, game:GetService("ReplicatedStorage").Data.PointsOfInterest)
	if ok and type(data) == "table" then
		poiData = data
	end
end

local function getPoiTitle(id)
	local entry = poiData[id]
	if type(entry) == "string" then
		return entry
	elseif type(entry) == "table" and type(entry.Title or entry[1]) == "string" then
		return entry.Title or entry[1]
	end
	return id
end

-- Each set marks the targets its discovery job still has to visit, so markers
-- disappear once a point is discovered or a picture is taken.
local waypointSets = {
	poi = { job = jobs.poi, color = Color3.fromRGB(90, 200, 255), title = getPoiTitle },
	picture = { job = jobs.picture, color = Color3.fromRGB(255, 120, 200), title = getPictureSpotTitle },
}
for _, set in waypointSets do
	set.enabled = false
	set.entries = {} -- [part] = { billboard, label, name }
end

local function createWaypoint(set, part, name)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "LuminalityWaypoint"
	billboard.Size = UDim2.fromOffset(200, 46)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = math.huge
	billboard.Adornee = part
	billboard.Parent = espGui

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0)
	dot.Position = UDim2.fromScale(0.5, 0)
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Rotation = 45
	dot.BackgroundColor3 = set.color
	dot.BorderSizePixel = 0
	dot.Parent = billboard

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(0, 14)
	label.Size = UDim2.new(1, 0, 1, -14)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = set.color
	label.TextStrokeTransparency = 0.4
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Parent = billboard

	set.entries[part] = { billboard = billboard, label = label, name = set.title(name) }
end

local function clearWaypoints(set)
	for part, entry in set.entries do
		entry.billboard:Destroy()
		set.entries[part] = nil
	end
end

-- Adds markers for new targets and drops the ones that are done or gone.
local function rescanWaypoints(set)
	local wanted = {}
	for _, target in set.job:collect() do
		for _, part in target.parts do
			wanted[part] = target.name
		end
	end
	for part in set.entries do
		if not wanted[part] then
			set.entries[part].billboard:Destroy()
			set.entries[part] = nil
		end
	end
	for part, name in wanted do
		if not set.entries[part] then
			createWaypoint(set, part, name)
		end
	end
end

local function refreshWaypoints(set)
	local root = getRoot()
	for part, entry in set.entries do
		if root then
			entry.label.Text = string.format("%s\n[%d studs]", entry.name,
				math.floor((part.Position - root.Position).Magnitude))
		else
			entry.label.Text = entry.name
		end
	end
end

local function setWaypoints(set, enabled)
	set.enabled = enabled
	if enabled then
		rescanWaypoints(set)
		refreshWaypoints(set)
		local count = 0
		for _ in set.entries do
			count = count + 1
		end
		notify(string.format("%d %s waypoint(s) shown", count, set.job.label))
	else
		clearWaypoints(set)
	end
end

do
	local sinceRefresh, sinceRescan = 0, 0
	ctx:Connect(RunService.Heartbeat, function(dt)
		sinceRefresh = sinceRefresh + dt
		sinceRescan = sinceRescan + dt
		if sinceRefresh < 0.2 then
			return
		end
		local rescan = sinceRescan >= 1
		sinceRefresh = 0
		if rescan then
			sinceRescan = 0
		end
		for _, set in waypointSets do
			if set.enabled then
				if rescan then
					rescanWaypoints(set)
				end
				refreshWaypoints(set)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Teleports
--------------------------------------------------------------------------------

local NONE_SELECTED = "Select..."
local npcSafeDistance = 8

local function teleportTo(cframe)
	local root = getRoot()
	if not root then
		notify("Your character isn't loaded", "error")
		return false
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = cframe
	return true
end

-- Builds dropdown options from { label, value } pairs, numbering duplicate labels.
local function buildOptions(items)
	table.sort(items, function(a, b)
		return a.label < b.label
	end)
	local options, lookup, seen = { NONE_SELECTED }, {}, {}
	for _, item in items do
		local count = (seen[item.label] or 0) + 1
		seen[item.label] = count
		local label = count > 1 and string.format("%s #%d", item.label, count) or item.label
		table.insert(options, label)
		lookup[label] = item.value
	end
	return options, lookup
end

local function getPictureSpots()
	local items = {}
	for _, tagged in CollectionService:GetTagged("PictureSpot") do
		local spot = tagged.Parent
		if spot and spot:IsA("BasePart") and spot:IsDescendantOf(workspace) then
			local prefix = isPictureTaken(spot) and "[done] " or ""
			table.insert(items, { label = prefix .. getPictureSpotTitle(spot.Name), value = spot })
		end
	end
	return buildOptions(items)
end

local function teleportToPictureSpot(spot)
	if not spot or not spot.Parent then
		notify("That picture spot no longer exists, refresh the list", "error")
		return
	end
	if teleportTo(spot.CFrame + Vector3.new(0, 3, 0)) then
		notify("Teleported to picture spot " .. getPictureSpotTitle(spot.Name))
	end
end

local function getNpcs()
	local items = {}
	for _, descendant in NpcFolder:GetDescendants() do
		if isNpc(descendant) then
			table.insert(items, { label = getNpcName(descendant), value = descendant })
		end
	end
	return buildOptions(items)
end

-- Lands npcSafeDistance studs in front of the NPC, facing it.
local function teleportToNpc(model)
	local anchor = model and model.Parent and getAnchor(model)
	if not anchor then
		notify("That NPC isn't loaded, refresh the list", "error")
		return
	end
	local target = anchor.Position
	local position = (anchor.CFrame * CFrame.new(0, 0, -npcSafeDistance)).Position
	if teleportTo(CFrame.lookAt(position, Vector3.new(target.X, position.Y, target.Z))) then
		notify(string.format("Teleported %d studs from %s", npcSafeDistance, getNpcName(model)))
	end
end

ctx:OnCleanup(function()
	running = false
	for _, job in jobs do
		job.id = job.id + 1
	end
	setEsp(false)
	for _, set in waypointSets do
		set.enabled = false
		clearWaypoints(set)
	end
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local MainTab = ctx:SubTab("Main", "Lucide:house")

MainTab:AddSection("Discovery", "Lucide:compass")
MainTab:AddToggle({
	Text = "Discover Points Of Interest",
	Description = "Teleports to every point of interest you haven't discovered yet",
	Default = false,
	Callback = function(enabled)
		setJob(jobs.poi, enabled)
	end,
})
MainTab:AddToggle({
	Text = "Discover Regions",
	Description = "Teleports to every region you haven't discovered yet",
	Default = false,
	Callback = function(enabled)
		setJob(jobs.region, enabled)
	end,
})
MainTab:AddToggle({
	Text = "Auto Picture Spots",
	Description = "Goes to every picture spot you haven't taken yet and tries to claim it",
	Default = false,
	Callback = function(enabled)
		setJob(jobs.picture, enabled)
	end,
})

local VisualsTab = ctx:SubTab("Visuals", "Lucide:eye")

VisualsTab:AddSection("ESP", "Lucide:scan-eye")
VisualsTab:AddToggle({
	Text = "NPC ESP",
	Description = "Shows a highlight, name and distance for every NPC",
	Default = false,
	Callback = setEsp,
})

VisualsTab:AddSection("Waypoints", "Lucide:map-pin")
VisualsTab:AddToggle({
	Text = "Point Of Interest Waypoints",
	Description = "Marker and distance for every point of interest you haven't discovered",
	Default = false,
	Callback = function(enabled)
		setWaypoints(waypointSets.poi, enabled)
	end,
})
VisualsTab:AddToggle({
	Text = "Picture Spot Waypoints",
	Description = "Marker and distance for every picture spot you haven't taken",
	Default = false,
	Callback = function(enabled)
		setWaypoints(waypointSets.picture, enabled)
	end,
})

local TeleportTab = ctx:SubTab("Teleports", "Lucide:map-pin")

-- A dropdown that teleports on select, plus Refresh and Teleport Again buttons
-- (picking the same option twice doesn't fire the callback).
local function addTeleportDropdown(text, description, getItems, teleport)
	local options, lookup = getItems()
	local selected

	local dropdown = TeleportTab:AddDropdown({
		Text = text,
		Description = description,
		Options = options,
		Default = NONE_SELECTED,
		Flag = false,
		Callback = function(value)
			selected = lookup[value]
			if selected then
				teleport(selected)
			end
		end,
	})
	TeleportTab:AddButton({
		Text = "Refresh List",
		Icon = "Lucide:refresh-cw",
		Callback = function()
			options, lookup = getItems()
			selected = nil
			dropdown:Refresh(options)
			notify(string.format("%s: %d found", text, #options - 1))
		end,
	})
	TeleportTab:AddButton({
		Text = "Teleport Again",
		Icon = "Lucide:rotate-ccw",
		Callback = function()
			if selected then
				teleport(selected)
			else
				notify("Pick one from the list first", "error")
			end
		end,
	})
end

TeleportTab:AddSection("Picture Spots", "Lucide:camera")
addTeleportDropdown("Picture Spots", "Teleports to the picture spot ([done] = already taken)",
	getPictureSpots, teleportToPictureSpot)

TeleportTab:AddSection("NPCs", "Lucide:users")
TeleportTab:AddSlider({
	Text = "Safe Distance",
	Description = "How far in front of the NPC you land",
	Suffix = " studs",
	Min = 3,
	Max = 30,
	Increment = 1,
	Default = npcSafeDistance,
	Callback = function(value)
		npcSafeDistance = value
	end,
})
addTeleportDropdown("NPCs", "Teleports in front of the NPC, facing it", getNpcs, teleportToNpc)
