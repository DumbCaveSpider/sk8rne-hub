-- Combat Initiation
local ctx = ...
local task = ctx.task

-- Panel with toggles: Auto Attack (sword), Silent Aim (slingshot + scatterblaster) and Unlimited Dash.
-- Auto Attack is based on autoattack.luau / the VerifyHit call in dump3.luau.
-- Unlimited Dash is based on the character MasterScript (dump6.luau).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local RANGE = 12
local TOOL_NAME = "Sword"
local SLINGSHOT_NAME = "Slingshot"
local SHOOT_RANGE_MIN, SHOOT_RANGE_MAX = 10, 500
local shootRange = 60 -- studs; set by the Silent Aim range slider

local NO_DELAY_WAIT = 0.05 -- seconds; floor used instead of 0 so the tools' cooldown math doesn't divide by zero

local state = { AutoAttack = false, AutoShoot = false, NoDelay = false, UnlimitedDash = false, UnlimitedJetpack = false, ReflectorNoDelay = false, TrowelNoDelay = false }

-- ===== Auto Attack =====

local function getRoot(model)
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function nearestEnemy(origin, range)
	local best, bestDist, bestHumanoid
	for _, enemy in ipairs(CollectionService:GetTagged("Enemy")) do
		local humanoid = enemy:FindFirstChild("Humanoid")
		local root = getRoot(enemy)
		if humanoid and root and humanoid.Health > 0 then
			local dist = (root.Position - origin).Magnitude
			if dist <= range and (not bestDist or dist < bestDist) then
				best, bestDist, bestHumanoid = enemy, dist, humanoid
			end
		end
	end
	return best, bestHumanoid
end

-- Binds a per-tool auto loop to a toggle. step(tool, data) runs repeatedly while the tool is
-- equipped and the toggle is on; it returns how long to wait before the next iteration.
local function bindTool(toolName, stateKey, step)
	local threadId = 0
	local data = {}

	local function loop(tool, id)
		while ctx:Alive() and state[stateKey] and threadId == id and tool.Parent == LocalPlayer.Character do
			local character = LocalPlayer.Character
			local humanoid = character and character:FindFirstChild("Humanoid")
			if character and character:FindFirstChild("HumanoidRootPart") and humanoid and humanoid.Health > 0 then
				task.wait(step(tool, data) or 0.1)
			else
				task.wait(0.25)
			end
		end
	end

	-- Starts (or restarts) the loop if the toggle is on and the tool is currently equipped.
	local function refresh()
		threadId = threadId + 1 -- invalidates any running loop
		if not state[stateKey] then return end
		local character = LocalPlayer.Character
		local tool = character and character:FindFirstChild(toolName)
		if tool and tool:IsA("Tool") then
			task.spawn(loop, tool, threadId)
		end
	end

	local function watchTool(tool)
		if tool.Name == toolName and tool:IsA("Tool") then
			ctx:Connect(tool.Equipped, refresh)
			ctx:Connect(tool.Unequipped, function() threadId = threadId + 1 end)
		end
	end

	local function watchContainer(container)
		ctx:Connect(container.ChildAdded, watchTool)
		for _, child in ipairs(container:GetChildren()) do watchTool(child) end
	end

	watchContainer(LocalPlayer:WaitForChild("Backpack"))
	if LocalPlayer.Character then watchContainer(LocalPlayer.Character) end
	ctx:Connect(LocalPlayer.CharacterAdded, function(character)
		watchContainer(character)
		watchContainer(LocalPlayer:WaitForChild("Backpack"))
	end)

	return refresh
end

local refreshAttack = bindTool(TOOL_NAME, "AutoAttack", function(tool, data)
	local myRoot = LocalPlayer.Character.HumanoidRootPart
	local enemy, humanoid = nearestEnemy(myRoot.Position, RANGE)
	if not enemy then
		data.combo = 1
		return 0.1
	end

	local combo = data.combo or 1
	local targetRoot = getRoot(enemy)
	local hitPart = enemy:FindFirstChild("Head") or targetRoot
	local direction = (targetRoot.Position - myRoot.Position).Unit
	local attackType = combo >= 3 and "Lunge" or "Slash"

	tool.VerifyHit:FireServer(attackType, humanoid, direction, hitPart, false, {
		Overhead = false,
		AttackDash = false,
		ShadowDash = false,
		Backstab = false,
	})

	data.combo = combo >= 3 and 1 or combo + 1
	return attackType == "Lunge"
		and (tool:GetAttribute("LungeRate") or 0.4)
		or (tool:GetAttribute("Swingrate") or 0.3)
end)

-- Silent Aim: the Slingshot reports hits with VerifyHit:FireServer(Humanoid, hitPosition,
-- origin, hitPart) (slingshot.luau line 419); we send that directly instead of firing pellets.
-- Pellet capacity lives in the tool's own script and can't be read from here, so an empty
-- slingshot is simply rejected (or ignored) by the server.
local refreshShoot = bindTool(SLINGSHOT_NAME, "AutoShoot", function(tool)
	local slingshot = tool:FindFirstChild("Slingshot")
	local firingPoint = slingshot and slingshot:FindFirstChild("FiringPoint")
	local origin = firingPoint and firingPoint.WorldPosition
		or LocalPlayer.Character.HumanoidRootPart.Position

	local enemy, humanoid = nearestEnemy(origin, shootRange)
	if not enemy then return 0.1 end

	local hitPart = enemy:FindFirstChild("Head") or getRoot(enemy)
	tool.VerifyHit:FireServer(humanoid, hitPart.Position, origin, hitPart)
	if state.NoDelay then return NO_DELAY_WAIT end
	return tool:GetAttribute("Firerate") or 0.5
end)

-- Silent Aim for the Scatterblaster: its pellets report hits with
-- VerifyHit:FireServer(Humanoid, hitPosition, origin, hitPart, {FireTime, Quickdraw, AttackType,
-- Distance, Stage, ObjectBreak}) (slingshot.luau line 1049). Sent here as an uncharged (stage 0)
-- default shot; charging and pulse shots are not simulated.
local SCATTER_NAME = "Scatterblaster"
local refreshScatter = bindTool(SCATTER_NAME, "AutoShoot", function(tool)
	local body = tool:FindFirstChild("Scatterblaster")
	local firingPoint = body and body:FindFirstChild("FiringPoint")
	local origin = firingPoint and firingPoint.WorldPosition
		or LocalPlayer.Character.HumanoidRootPart.Position

	local enemy, humanoid = nearestEnemy(origin, shootRange)
	if not enemy then return 0.1 end

	local hitPart = enemy:FindFirstChild("Head") or getRoot(enemy)
	tool.VerifyHit:FireServer(humanoid, hitPart.Position, origin, hitPart, {
		FireTime = os.clock(),
		Quickdraw = false,
		AttackType = "Default",
		Distance = (origin - hitPart.Position).Magnitude,
		Stage = 0,
		ObjectBreak = false,
	})

	if state.NoDelay then return NO_DELAY_WAIT end
	return tool:GetAttribute("Firerate") or 0.5
end)

local function refreshSilentAim()
	refreshShoot()
	refreshScatter()
end

-- ===== No Delay (Rocket Launcher) =====
-- The Rocket Launcher's script builds its cooldown from the tool's "Cooldown" attribute and
-- listens for changes to it (rocket.luau lines 18-35), so we hold that attribute near zero and
-- restore it when the toggle is turned off. This only changes the client; the server may still
-- enforce its own cooldown. Silent Aim also skips its Firerate wait while this is on.
local ROCKET_NAME = "Rocket Launcher"
local originalCooldown = setmetatable({}, { __mode = "k" })

local function forEachRocket(fn)
	for _, container in ipairs({ LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character }) do
		local tool = container and container:FindFirstChild(ROCKET_NAME)
		if tool then fn(tool) end
	end
end

ctx:Connect(RunService.Heartbeat, function()
	if state.NoDelay then
		forEachRocket(function(tool)
			local current = tool:GetAttribute("Cooldown")
			if current and current > NO_DELAY_WAIT then
				originalCooldown[tool] = originalCooldown[tool] or current
				ctx:SetAttribute(tool, "Cooldown", NO_DELAY_WAIT)
			end
		end)
	end
end)

local function refreshNoDelay()
	if state.NoDelay then return end
	forEachRocket(function(tool)
		if originalCooldown[tool] then
			ctx:SetAttribute(tool, "Cooldown", originalCooldown[tool])
			originalCooldown[tool] = nil
		end
	end)
end

-- ===== Unlimited Dash =====
-- From the character's MasterScript (dump6.luau): dashes are stored in the character attribute
-- "Dashes" (capped by "MaxDashes"). The dash handler only dashes if Dashes >= 1 and skips the
-- decrement when workspace attribute "InfiniteDashes" is set (lines 103-110, 269). Both are read
-- on the client, so we set that flag while the toggle is on and also keep Dashes topped up
-- (covers the extra decrement on the jump-dash, and regen/refill edge cases).
local function refreshDash()
	if not state.UnlimitedDash then
		ctx:SetAttribute(workspace, "InfiniteDashes", nil)
	end
end

ctx:Connect(RunService.Heartbeat, function()
	if not state.UnlimitedDash then return end
	ctx:SetAttribute(workspace, "InfiniteDashes", true)

	local character = LocalPlayer.Character
	local maxDashes = character and character:GetAttribute("MaxDashes")
	if maxDashes and (character:GetAttribute("Dashes") or 0) < maxDashes then
		ctx:SetAttribute(character, "Dashes", maxDashes)
	end
end)


-- ===== Unlimited Jetpack =====
-- Jet boots fuel (jetpack.luau) is a plain local (u2, 0..1) inside the character's jetpack
-- LocalScript, not an attribute, so it can't be set through the instance tree. Instead we find
-- that script's InputBegan handler (onJump) with getconnections, locate its fuel upvalue (the only
-- number in 0..1 among its upvalues) and pin it to 1 every frame with debug.setupvalue.
-- Needs an executor with getconnections / debug.getupvalues / debug.setupvalue. Whenever the
-- game drops the fuel below full we also redraw the fuel bar at 100%, so it stays full on screen.
local jetpackFn, jetpackIndex, jetpackCharacter
local nextJetpackSearch = 0
local jetpackWarned = false
local jetpackReported = false

local function findJetpack(character)
	if not (getconnections and debug.getupvalues and debug.setupvalue) then
		if not jetpackWarned then
			jetpackWarned = true
			warn("[UnlimitedJetpack] executor lacks getconnections / debug.getupvalues / debug.setupvalue")
		end
		return
	end

	-- Identify onJump by its upvalues rather than its script: only the jetpack handler captures
	-- both of the character's legs (u4 / u5 in jetpack.luau) alongside the numeric fuel value.
	-- Returns the fuel upvalue index if fn looks like onJump, plus a one-line summary of its
	-- upvalues for the diagnostic below.
	local function inspect(fn)
		local okUp, upvalues = pcall(debug.getupvalues, fn)
		if not (okUp and type(upvalues) == "table") then
			return nil, "getupvalues failed: " .. tostring(upvalues)
		end
		local rightLeg, leftLeg, fuelIndex
		local summary = {}
		for index, value in pairs(upvalues) do
			local kind = typeof(value)
			if kind == "Instance" then
				kind = "Instance:" .. value.Name
				if value:IsDescendantOf(character) then
					if value.Name == "Right Leg" then rightLeg = true end
					if value.Name == "Left Leg" then leftLeg = true end
				end
			elseif kind == "number" then
				kind = "number:" .. tostring(value)
				if value >= 0 and value <= 1 then fuelIndex = index end
			end
			table.insert(summary, index .. "=" .. kind)
		end
		return (rightLeg and leftLeg and fuelIndex) and fuelIndex or nil, table.concat(summary, ", ")
	end

	local scanned, report = 0, {}
	for _, connection in ipairs(getconnections(UserInputService.InputBegan)) do
		local fn = connection.Function
		if type(fn) == "function" then
			scanned = scanned + 1
			local index, summary = inspect(fn)
			if index then return fn, index end
			table.insert(report, "  [" .. scanned .. "] " .. summary)
		end
	end

	-- fallback: the handler may not be listed on InputBegan (or its Function may be a wrapper),
	-- so scan every live Lua function instead. Heavier, which is why searches are rate limited.
	if getgc then
		local checked = 0
		for _, fn in ipairs(getgc(true)) do
			if type(fn) == "function" and not (isexecutorclosure and isexecutorclosure(fn)) then
				checked = checked + 1
				local index = inspect(fn)
				if index then return fn, index end
			end
		end
		table.insert(report, "  getgc scanned " .. checked .. " functions, no match")
	else
		table.insert(report, "  getgc unavailable")
	end

	if not jetpackReported then
		jetpackReported = true
		warn("[UnlimitedJetpack] jetpack handler not found. Upvalues of the " .. scanned
			.. " InputBegan connections:\n" .. table.concat(report, "\n"))
	end
end

ctx:Connect(RunService.Heartbeat, function()
	if not state.UnlimitedJetpack then return end
	local character = LocalPlayer.Character
	if not character then return end

	if jetpackCharacter ~= character or not jetpackFn then
		if os.clock() < nextJetpackSearch then return end
		nextJetpackSearch = os.clock() + 3
		jetpackFn, jetpackIndex = findJetpack(character)
		jetpackCharacter = jetpackFn and character or nil
		if not jetpackFn then return end
		print("[UnlimitedJetpack] found fuel upvalue #" .. tostring(jetpackIndex))
	end

	-- the game lowers the fuel while thrusting; whenever it's below full, reset it and redraw the
	-- fuel bar at 100% (same ToolVisualClient update the game's changeFuel() sends, jetpack.luau 56-69)
	local ok, upvalues = pcall(debug.getupvalues, jetpackFn)
	if ok and upvalues[jetpackIndex] ~= 1 then
		pcall(debug.setupvalue, jetpackFn, jetpackIndex, 1)
		local weapons = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
		local visual = weapons and weapons:FindFirstChild("Weapons") and weapons.Weapons:FindFirstChild("ToolVisualClient")
		if visual then
			visual:Fire({
				Type = "Update",
				Instances = { JetBootsGear = { SetCooldown = 0, SetCooldownText = false } },
			})
		end
	end
end)

-- ===== Gear cooldown removal (Reflector, Trowel, Hammer) =====
-- Both gears keep their cooldown in a Cooldown object held in a local inside their own script
-- (reflector.luau lines 77-96, trowel.luau lines 26-34), so there is no attribute to change for
-- the object itself. makeCooldownPatcher finds the object(s) with getgc (a table that has an
-- OnCooldown method and carries the params table with Cause = <cause>) and replaces OnCooldown
-- with a function that always returns false, which is the check each gear's use handler makes.
-- The Trowel also reads the tool attribute "Cooldown" when it sets the cooldown, so for tools
-- named in config.toolName that attribute is held near zero as well (restored when turned off).
-- Not removed: timing inside the scripts (task.wait calls, animations) and the short cooldown the
-- server resets after a successful trowel placement (trowel.luau line 222).
local function makeCooldownPatcher(config)
	local patched = {} -- cooldown object -> { original = previous raw OnCooldown }
	local patchedCount = 0
	local lastCharacter
	local nextSearch = 0
	local reported = false
	local originalAttribute = setmetatable({}, { __mode = "k" })
	local tag = "[" .. config.label .. "]"
	local causes = {}
	for _, cause in ipairs(config.causes) do causes[cause] = true end
	local lastTools = ""

	local function isCooldownObject(candidate)
		local ok, result = pcall(function()
			if type(candidate.OnCooldown) ~= "function" then return false end
			local function tagged(value)
				return type(value) == "table" and causes[rawget(value, "Cause")] == true
			end
			if tagged(candidate) then return true end
			for _, value in pairs(candidate) do
				if tagged(value) then return true end
			end
			return false
		end)
		return ok and result
	end

	local function forEachTool(fn)
		for _, toolName in ipairs(config.toolNames or {}) do
			for _, container in ipairs({ LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character }) do
				local tool = container and container:FindFirstChild(toolName)
				if tool then fn(tool) end
			end
		end
	end

	local function restore()
		for object, info in pairs(patched) do
			pcall(rawset, object, "OnCooldown", info.original)
		end
		patched, patchedCount = {}, 0
		forEachTool(function(tool)
			if originalAttribute[tool] then
				ctx:SetAttribute(tool, "Cooldown", originalAttribute[tool])
				originalAttribute[tool] = nil
			end
		end)
	end

	ctx:Connect(RunService.Heartbeat, function()
		if not state[config.stateKey] then return end
		local character = LocalPlayer.Character
		if not character then return end

		local present = {}
		forEachTool(function(tool)
			table.insert(present, tool.Name)
			local current = tool:GetAttribute("Cooldown")
			if type(current) == "number" and current > NO_DELAY_WAIT then
				originalAttribute[tool] = originalAttribute[tool] or current
				ctx:SetAttribute(tool, "Cooldown", NO_DELAY_WAIT)
			end
		end)

		local needSearch
		if lastCharacter ~= character then
			-- respawn: the gear script (and its cooldown objects) was recreated
			patched, patchedCount = {}, 0
			lastCharacter = character
			lastTools = ""
			needSearch = true
		elseif config.toolNames then
			-- gear with tools: search again whenever the set of owned tools changes, and keep
			-- retrying (below) while nothing has been found
			table.sort(present)
			local signature = table.concat(present, ",")
			needSearch = signature ~= lastTools or patchedCount == 0
			lastTools = signature
		else
			needSearch = patchedCount < (config.expected or 1)
		end
		if config.toolNames and #present == 0 then return end
		if not needSearch or os.clock() < nextSearch then return end
		nextSearch = os.clock() + 3

		if not getgc then
			if not reported then
				reported = true
				warn(tag .. " executor lacks getgc")
			end
			return
		end

		for _, candidate in ipairs(getgc(true)) do
			if type(candidate) == "table" and not patched[candidate] and isCooldownObject(candidate) then
				patched[candidate] = { original = rawget(candidate, "OnCooldown") }
				patchedCount = patchedCount + 1
				rawset(candidate, "OnCooldown", function() return false end)
			end
		end
		if patchedCount > 0 then
			print(tag .. " patched " .. patchedCount .. " cooldown object(s)")
		elseif not reported then
			reported = true
			warn(tag .. " no cooldown objects found yet (do you have the gear?); retrying")
		end
	end)

	return function()
		if not state[config.stateKey] then restore() end
	end
end

-- Reflector: u11 (2.5 s blast) and u13 (20 s shield), so two objects are expected.
local refreshReflector = makeCooldownPatcher({
	stateKey = "ReflectorNoDelay", causes = { "Reflector" }, label = "NoReflectorDelay", expected = 2,
})
-- Trowel (trowel.luau: one object, Cause "Trowel") and Hammer (the second tool script pasted into
-- trowel.luau: u13 = build / upgrade, u15 = pocket / throw, both Cause "Hammer"), plus each tool's
-- "Cooldown" attribute. Whichever of the two tools you own gets patched.
local refreshTrowel = makeCooldownPatcher({
	stateKey = "TrowelNoDelay", causes = { "Trowel", "Hammer" }, label = "NoTrowelDelay",
	toolNames = { "Trowel", "Hammer" },
})



-- ===== UI =====

local Main = ctx:SubTab("Main", "Lucide:house")

local function addToggle(tab, text, description, icon, flag, key, onChange)
	tab:AddToggle({
		Text = text,
		Description = description,
		Icon = icon,
		Default = false,
		Flag = flag,
		Callback = function(value)
			state[key] = value
			if onChange then onChange() end
		end,
	})
end

Main:AddSection("Combat", "Lucide:swords")
addToggle(Main, "Auto Attack", "Swings the sword at the nearest enemy in range", "Lucide:sword", "ci_auto_attack", "AutoAttack", refreshAttack)
addToggle(Main, "Silent Aim", "Slingshot and scatterblaster hit the nearest enemy in range", "Lucide:crosshair", "ci_silent_aim", "AutoShoot", refreshSilentAim)
Main:AddSlider({
	Text = "Silent Aim Range",
	Description = "How far away an enemy can be and still take damage",
	Icon = "Lucide:ruler",
	Min = SHOOT_RANGE_MIN,
	Max = SHOOT_RANGE_MAX,
	Default = shootRange,
	Increment = 1,
	Suffix = " studs",
	Flag = "ci_silent_aim_range",
	Callback = function(value)
		shootRange = math.floor(value + 0.5)
	end,
})

Main:AddSection("Movement", "Lucide:user")
addToggle(Main, "Unlimited Dash", "Dashes are never used up", "Lucide:wind", "ci_unlimited_dash", "UnlimitedDash", refreshDash)
addToggle(Main, "Unlimited Jetpack", "Jet boots fuel stays full", "Lucide:rocket", "ci_unlimited_jetpack", "UnlimitedJetpack")

Main:AddSection("Cooldowns", "Lucide:timer")
addToggle(Main, "No Delay", "Removes the rocket launcher cooldown and the slingshot fire delay", "Lucide:zap", "ci_no_delay", "NoDelay", refreshNoDelay)
addToggle(Main, "No Reflector Delay", "Removes the reflector cooldowns", "Lucide:shield", "ci_no_reflector_delay", "ReflectorNoDelay", refreshReflector)
addToggle(Main, "No Trowel Delay", "Removes the trowel and hammer cooldowns", "Lucide:hammer", "ci_no_trowel_delay", "TrowelNoDelay", refreshTrowel)
