-- Regretevator
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------
-- Features
---------------------------------------------------------------------

-- A GPU tool is any tool with Handle.Spinning (the sound) and a "LastSpun" attribute
local function isGPU(tool)
	if not tool:IsA("Tool") then
		return false
	end
	local handle = tool:FindFirstChild("Handle")
	return handle ~= nil and handle:FindFirstChild("Spinning") ~= nil
end

local function findGPU()
	local char = LocalPlayer.Character
	if char then
		for _, v in ipairs(char:GetChildren()) do
			if isGPU(v) then
				return v, true
			end
		end
	end
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, v in ipairs(backpack:GetChildren()) do
			if isGPU(v) then
				return v, false
			end
		end
	end
end

local alwaysSpinToken = 0

local function setAlwaysGPUSpin(enabled)
	alwaysSpinToken += 1
	if not enabled then
		return
	end
	local token = alwaysSpinToken
	task.spawn(function()
		while ctx:Alive() and alwaysSpinToken == token do
			local gpu, equipped = findGPU()
			if gpu then
				if not equipped then
					local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
					if hum then
						hum:EquipTool(gpu)
					end
				end
				-- Respin once the current spin has run out
				local lastSpun = gpu:GetAttribute("LastSpun")
				local lifetime = gpu:GetAttribute("LastLifetime")
				local expired = not lastSpun or not lifetime
					or (workspace:GetServerTimeNow() - lastSpun) >= lifetime * 0.9
				if expired and gpu.Parent == LocalPlayer.Character then
					pcall(function()
						ReplicatedStorage.RE.GPU:InvokeServer(gpu)
					end)
				end
			end
			task.wait(0.25)
		end
	end)
end

-- Coins are tagged "Pickup" (see PickupManager); the server collects them on touch
local autoCoinsToken = 0

local function getTouchPart(pickup)
	if pickup:IsA("BasePart") then
		return pickup
	end
	return pickup:IsA("Model") and (pickup.PrimaryPart or pickup:FindFirstChildWhichIsA("BasePart", true)) or nil
end

local function setAutoCoins(enabled)
	autoCoinsToken += 1
	if not enabled then
		return
	end
	local token = autoCoinsToken
	task.spawn(function()
		while ctx:Alive() and autoCoinsToken == token do
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				for _, pickup in ipairs(CollectionService:GetTagged("Pickup")) do
					if pickup.Name:lower():find("coin") and pickup:IsDescendantOf(workspace) then
						local part = getTouchPart(pickup)
						if part then
							pcall(function()
								firetouchinterest(root, part, 0)
								firetouchinterest(root, part, 1)
							end)
						end
					end
				end
			end
			task.wait(0.2)
		end
	end)
end

-- Minigame timestamp label (mirrors the Timer tool: client_timer_script)
local function formatTime(t)
	return string.format("%02d:%02d.%02d", t / 60, t % 60, math.floor((t - math.floor(t)) * 100))
end

-- The attributes are looked up on every likely holder, since the game may move them
local function getAttr(name)
	local char = LocalPlayer.Character
	local holders = { char, char and char:FindFirstChildOfClass("Humanoid"), LocalPlayer, workspace }
	for _, holder in ipairs(holders) do
		local v = holder and holder:GetAttribute(name)
		if v ~= nil then
			return v
		end
	end
end

local DIRECTIONS = { "Ahead", "Ahead-Right", "Right", "Behind-Right", "Behind", "Behind-Left", "Left", "Ahead-Left" }

local function isValidInterest(inst, origin)
	if not inst:IsA("PVInstance") or not inst:IsDescendantOf(workspace) then
		return false
	end
	local range = inst:GetAttribute("CompassRange") or 1500
	if (inst:GetPivot().Position - origin.Position).Magnitude >= range then
		return false
	end
	local ok, lobby = pcall(function()
		return workspace.Values.Lobby.Value
	end)
	local inLobby = ok and lobby and inst:IsDescendantOf(lobby)
	-- Lobby interests count while in the elevator, level interests only while out of it
	return inLobby == (LocalPlayer:GetAttribute("InElevator") == true)
end

local function getBestInterest(origin)
	local best, bestDist
	for _, inst in ipairs(CollectionService:GetTagged("Interest")) do
		if isValidInterest(inst, origin) then
			local dist = (inst:GetPivot().Position - origin.Position).Magnitude
			local prio = inst:GetAttribute("CompassPriority") or 0
			local bestPrio = best and (best:GetAttribute("CompassPriority") or 0) or 0
			if not best or prio > bestPrio or (prio == bestPrio and dist < bestDist) then
				best, bestDist = inst, dist
			end
		end
	end
	return best, bestDist
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Main = ctx:SubTab("Main", "Lucide:house")
local Info = ctx:SubTab("Info", "Lucide:info")

Main:AddSection("Farm", "Lucide:coins")
Main:AddToggle({
	Text = "Always GPU Spin",
	Description = "Equips the GPU and respins it whenever the spin runs out",
	Icon = "Lucide:cpu",
	Default = false,
	Flag = "regret_gpu_spin",
	Callback = function(value)
		setAlwaysGPUSpin(value)
	end,
})
Main:AddToggle({
	Text = "Auto Pickup Coins",
	Description = "Collects every coin pickup in the level",
	Icon = "Lucide:coins",
	Default = false,
	Flag = "regret_auto_coins",
	Callback = function(value)
		setAutoCoins(value)
	end,
})

Info:AddSection("Timers", "Lucide:timer")
local timerLabel = Info:AddLabel("Minigame: --\nFloor: --")
Info:AddSection("Compass", "Lucide:compass")
local compassLabel = Info:AddLabel("Compass: --")

local lastTimerText, lastCompassText
local function setTimer(text)
	if text ~= lastTimerText then
		lastTimerText = text
		timerLabel:Set(text)
	end
end
local function setCompass(text)
	if text ~= lastCompassText then
		lastCompassText = text
		compassLabel:Set(text)
	end
end

ctx:Connect(RunService.Heartbeat, function()
	local now = workspace:GetServerTimeNow()
	local start = getAttr("MinigameTimestampStart")
	local finish = getAttr("MinigameTimestampEnd")
	local ace = getAttr("MinigameTimestampAce")
	local floorEnd = getAttr("FloorTimestampEnd")

	local t
	if start and finish then
		t = finish - start
	elseif finish then
		t = finish - now
	elseif start then
		t = now - start
	end

	local line1 = t and ("Minigame: " .. formatTime(math.max(t, 0))) or "Minigame: --"
	if t and ace and t <= ace then
		line1 = line1 .. " [ACE]"
	end
	local line2 = "Floor: " .. (floorEnd and formatTime(math.max(floorEnd - now, 0)) or "--")
	setTimer(line1 .. "\n" .. line2)
end)

ctx:Connect(RunService.Heartbeat, function()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local target, dist = getBestInterest(root.CFrame)
	if not target then
		setCompass("Compass: nothing nearby")
		return
	end

	local pos = target:GetPivot().Position
	local rel = root.CFrame:PointToObjectSpace(pos)
	local angle = math.deg(math.atan2(rel.X, -rel.Z)) -- 0 = straight ahead, positive = right
	local dir = DIRECTIONS[math.floor((angle + 22.5) / 45) % 8 + 1]
	local vertical = rel.Y > 6 and ", above" or (rel.Y < -6 and ", below" or "")

	setCompass(string.format(
		"Compass: %s (%d° %s)\n%s - %d studs%s",
		dir,
		math.abs(math.floor(angle + 0.5)),
		angle >= 0 and "R" or "L",
		target.Name,
		math.floor(dist),
		vertical
	))
end)

ctx:OnCleanup(function()
	alwaysSpinToken += 1
	autoCoinsToken += 1
end)
