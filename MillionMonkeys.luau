-- Survive a Million Monkeys
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- UI ----------------------------------------------------------------------------
local Main = ctx:SubTab("Main", "Lucide:house")

-- Names shared between sections ---------------------------------------------------
-- Luau allows 200 local variables in one scope. Each section below is wrapped in do ... end so
-- its private helpers do not count against that; only the names another section uses are
-- declared here, grouped by the section that defines them.
-- ui
local debugLog, debugSettings, log
-- units
local AIM_HEIGHT, FROZEN_BIT, STATE_DOWN, STUCK_MOVE, UNIT_TTL, aimHeightOf, aimPoint, aimSetAt, aimUnitId, attackMonkeys, crowdTargeting, hitTotal, hitsOn, isBossUnit, isFriendlyUnit, isRangedThreat, units, weaponRange, weaponSpeed
-- upgrades
local upgradeHealth, upgradeWeapon
-- prompts
local buyFromMerchant, collectChests, promptBusy
-- dodge
local EnemyCatalog, UnitProtocol, dodgeSplash, hasGround, hazards, inAnyHazard, inHazard, refreshHazards, safeRequire
-- safe
local classOf, keepSafeDistance, liveUnitPositions, nearestDistance, safeDistance, teleportToSafety
-- farm
local FARM_TICK, autoFarm, hoverHeight, resetFarmGoal, stopFarm
-- abilities
local useAbilities, useUltimate
-- skip
local SKIP_EVERY, skipShop
-- sell
local sellDuplicates

do
	local DebugTab = ctx:SubTab("Debug", "Lucide:bug")

	-- Everything the script reports is in one of these categories, each with its own switch on the Debug
	-- tab. Errors are always shown. Defaults keep what was visible before; the per-shot line and the raw
	-- control events are noisy, so they start off.
	debugSettings = {
		Actions = true, -- toggles switching, prompts used, abilities used
		Aim = true, -- how many of the game's mouse reads were answered (every few seconds)
		Targets = true, -- how many monkeys are tracked and why some are skipped (every few seconds)
		Hits = true, -- hits the server actually registered (every few seconds)
		Shot = false, -- the target chosen for every attack tick
		Damage = true, -- every time the character loses health, and what was near
		Movement = true, -- retreats, teleports and void rescues
		Hazards = true, -- danger zones picked up from throws, spits and boss attacks
		Boss = true, -- boss attack names and the layout of boss events
		Control = false, -- the first few raw unit control events
	}

	local DEBUG_GROUPS = {
		{ "Activity", {
			{ "Actions", "Actions", "Toggles switched, prompts and abilities used" },
			{ "Movement", "Movement", "Retreats, teleports and void rescues" },
		} },
		{ "Combat", {
			{ "Aim", "Aim Hook Report", "Mouse reads answered by the aim hook, every few seconds" },
			{ "Targets", "Target Counts", "Tracked monkeys and why some are skipped" },
			{ "Hits", "Server Hits", "Hits the server registered on the target" },
			{ "Shot", "Per-Shot Target", "The monkey chosen on every attack tick (noisy)" },
			{ "Damage", "Damage Taken", "Health lost and what was around" },
		} },
		{ "Threats", {
			{ "Hazards", "Hazards", "Danger zones found from attacks" },
			{ "Boss", "Boss Events", "Boss attack names and event layouts" },
		} },
		{ "Raw Events", {
			{ "Control", "Control Events", "The first raw unit control events (noisy)" },
		} },
	}

	for _, group in DEBUG_GROUPS do
		DebugTab:AddSection(group[1], "Lucide:bug")
		for _, category in group[2] do
			local key = category[1]
			DebugTab:AddToggle({
				Text = category[2],
				Description = category[3],
				Default = debugSettings[key],
				Callback = function(enabled) debugSettings[key] = enabled end,
			})
		end
	end

	function log(message, messageType)
		ctx.Log(message, messageType)
	end

	-- Writes to the Debug Console only while the category's switch is on.
	function debugLog(category, message, messageType)
		if debugSettings[category] then log(message, messageType) end
	end
end

-- Feature state ---------------------------------------------------------------
local State = {
	AutoAttackMonkeys = false,
	AutoUpgradeHealth = false,
	AutoUpgradeWeapon = false,
	AutoChestCollection = false,
	AutoMerchantBuying = false,
	AutoDodgeSplash = false,
	SafeDistance = false,
	AutoFarm = false,
	AutoAbilities = false,
	AutoUltimate = false,
	AutoSkipShop = false,
	AutoSellDuplicates = false,
}

do
	-- Feature actions -------------------------------------------------------------
	-- Each function runs once per loop tick while its toggle is on.

	-- Monkeys are server-simulated units; the client only gets position snapshots through
	-- ReplicatedStorage.Shared.Units.Snapshot (see UnitViewController.onSnapshot and
	-- UnitProtocol.read): an 8-byte f64 timestamp header followed by 11-byte entries of
	-- u16 id, u8 generation, i16 x/y/z (scaled by 16), u8 state, u8 heading. The models in
	-- Workspace.UnitViews are pooled visuals, so we track units from the snapshots instead.
	-- Damage is server-validated through the equipped GunKit tool, so we aim at the nearest
	-- tracked unit and activate the tool.
	local HEADER_BYTES, ENTRY_BYTES, POSITION_SCALE = 8, 11, 16
	UNIT_TTL = 0.6 -- seconds without a snapshot entry before a unit is forgotten
	AIM_HEIGHT = 2 -- studs above the reported position to aim at (fallback; see aimHeightOf)
	local LEAD_AIM = true -- aim ahead of moving monkeys by the snapshot lag and the bullet's flight time (untested)
	hitsOn, hitTotal = {}, 0 -- unit id -> server-confirmed hits seen in the last report window
	local SNAPSHOT_LAG = 0.15 -- seconds a snapshot position is behind the server plus the shot's trip to it
	weaponRange, weaponSpeed = nil, nil -- of the equipped weapon (WeaponConfig.projectile)
	aimHeightOf = function() return AIM_HEIGHT end -- replaced once unit classes are tracked
	local leadAimPoint -- defined with attackMonkeys; declared here so the aim hook below can call it

	STATE_DOWN, FROZEN_BIT = 75, 128 -- UnitProtocol.State.Down / UnitProtocol.Frozen
	local STUCK_AFTER, STUCK_SKIP = 1.5, 4 -- seconds a target may stay put before we skip it
	STUCK_MOVE = 1 -- studs a target must move to count as progress

	units = {} -- id -> { Pos, Seen, State, Frozen, Since, AnchorPos }
	local skipUntil = {} -- id -> os.clock() deadline while a stuck unit is ignored

	local function onSnapshot(buf)
		if typeof(buf) ~= "buffer" then return end
		local len = buffer.len(buf)
		if (len - HEADER_BYTES) % ENTRY_BYTES ~= 0 then return end
		local now = os.clock()
		local serverTime = buffer.readf64(buf, 0) -- the snapshot's own timestamp
		for offset = HEADER_BYTES, len - ENTRY_BYTES, ENTRY_BYTES do
			local id = buffer.readu16(buf, offset)
			local pos = Vector3.new(
				buffer.readi16(buf, offset + 3) / POSITION_SCALE,
				buffer.readi16(buf, offset + 5) / POSITION_SCALE,
				buffer.readi16(buf, offset + 7) / POSITION_SCALE
			)
			local stateByte = buffer.readu8(buf, offset + 9)
			local unit = units[id]
			if not unit or (pos - unit.AnchorPos).Magnitude > STUCK_MOVE then
				unit = unit or {}
				unit.AnchorPos, unit.Since = pos, now
			end
			if unit.Pos and unit.ServerTime and serverTime > unit.ServerTime then
				local dt = serverTime - unit.ServerTime
				if dt > 0.02 and dt < 0.5 then
					local velocity = (pos - unit.Pos) / dt
					velocity = Vector3.new(velocity.X, 0, velocity.Z) -- ground movement only
					unit.Vel = unit.Vel and unit.Vel:Lerp(velocity, 0.5) or velocity
				end
			end
			unit.Pos, unit.Seen, unit.ServerTime = pos, now, serverTime
			unit.State = stateByte % FROZEN_BIT
			unit.Frozen = stateByte >= FROZEN_BIT
			units[id] = unit
		end
	end

	local snapshotRemote = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Units"):WaitForChild("Snapshot")
	ctx:Connect(snapshotRemote.OnClientEvent, onSnapshot)

	isFriendlyUnit = function() return false end -- replaced once unit classes are tracked
	isBossUnit = function() return false end -- likewise
	isRangedThreat = function() return false end -- likewise

	-- Target choice.
	-- * Stuck units: a monkey that has not moved for STUCK_AFTER seconds can be treated as unreachable and
	--   left for last. That helped while shots were not registering, but in a dense crowd most monkeys are
	--   simply blocked behind others (26-38 of ~40 were "stuck" in one log) and the aim went to the few that
	--   were moving. Now that hits register, it is off by default (SKIP_STUCK_UNITS).
	-- * Crowds: with crowdTargeting on, the target is the monkey with the most others within CROWD_RADIUS
	--   (minus a small penalty for distance), so a spread weapon such as the shotgun hits several at once.
	--   With it off the nearest monkey is chosen. Only monkeys inside the weapon's range are candidates.
	local SKIP_STUCK_UNITS = false
	local THREAT_PRIORITY_RANGE = 45 -- studs: ranged enemies this close are shot first
	local CROWD_RADIUS = 8 -- studs: monkeys this close to a candidate count as being in its crowd
	local CROWD_DISTANCE_WEIGHT = 0.15 -- crowd members given up per stud of extra distance
	local CROWD_CANDIDATES = 60 -- most candidates scored (nearest first), to bound the work per tick
	crowdTargeting = true

	local function nearestMonkey(origin, maxRange)
		local now = os.clock()
		local preferred, skipped = {}, {}
		for id, unit in units do
			if now - unit.Seen > UNIT_TTL then
				units[id] = nil
			elseif unit.State ~= STATE_DOWN and not unit.Frozen and not isFriendlyUnit(id) then
				local dist = (unit.Pos - origin).Magnitude
				if not maxRange or dist <= maxRange then
					local skipping = false
					if SKIP_STUCK_UNITS then
						skipping = now < (skipUntil[id] or 0)
						if not skipping then
							if now - unit.Since > STUCK_AFTER and skipUntil[id] == nil and not isBossUnit(id) then
								skipUntil[id] = now + STUCK_SKIP
								skipping = true
							else
								skipUntil[id] = nil
							end
						end
					end
					table.insert(skipping and skipped or preferred, { Id = id, Unit = unit, Dist = dist })
				end
			end
		end

		local pool = #preferred > 0 and preferred or skipped
		if #pool == 0 then return nil end

		-- Flyers (range 30), Throwers and Spitters hurt from a distance: in the logged deaths every hit was
		-- 9 damage from Flyers while the nearest ground monkey was 28 studs off. When one is close enough to
		-- be doing that, it is the target, whatever the crowd looks like.
		local threats = {}
		for _, candidate in pool do
			if candidate.Dist <= THREAT_PRIORITY_RANGE and isRangedThreat(candidate.Id) then
				table.insert(threats, candidate)
			end
		end
		if #threats > 0 then pool = threats end

		table.sort(pool, function(a, b) return a.Dist < b.Dist end)
		if not crowdTargeting then return pool[1].Unit, pool[1].Id end

		local best, bestScore = pool[1], -math.huge
		for i = 1, math.min(#pool, CROWD_CANDIDATES) do
			local candidate = pool[i]
			local crowd = 0
			for _, other in pool do
				if (other.Unit.Pos - candidate.Unit.Pos).Magnitude <= CROWD_RADIUS then crowd = crowd + 1 end
			end
			local score = crowd - candidate.Dist * CROWD_DISTANCE_WEIGHT
			if score > bestScore then best, bestScore = candidate, score end
		end
		return best.Unit, best.Id
	end

	-- GunKit's GunRigController builds every shot from LocalPlayer:GetMouse().UnitRay (cursor
	-- mode), then lets TargetWorld.aimTarget snap to a nearby unit. Rather than moving the real
	-- cursor, answer the game's mouse reads with the chosen monkey: Mouse.UnitRay / Mouse.Hit, and
	-- UserInputService:GetMouseLocation (the screen point of the target), only for the game's own
	-- scripts and only while an aim point is fresh. The aim point follows the chosen monkey every frame.
	-- The counters are logged every few seconds while attacking, to show whether the game reads the
	-- mouse at all and how many of those reads were answered.
	local AIM_TTL = 0.5 -- seconds an aim point stays valid after attackMonkeys sets it
	local AIM_REPORT_EVERY = 4 -- seconds between aim-hook reports in the Debug tab
	aimPoint, aimSetAt, aimUnitId = nil, 0, nil
	local aimReads = { Ray = 0, RayOverridden = 0, Location = 0, LocationOverridden = 0 }
	local mouse = LocalPlayer:GetMouse()
	local UserInputService = game:GetService("UserInputService")

	local function aimIsFresh()
		return aimPoint ~= nil and os.clock() - aimSetAt < AIM_TTL
	end

	ctx:HookMeta(game, "__index", function(oldIndex, self, key)
		if self == mouse and not checkcaller() then
			if key == "UnitRay" then
				aimReads.Ray = aimReads.Ray + 1
				if aimIsFresh() then
					aimReads.RayOverridden = aimReads.RayOverridden + 1
					local cam = Workspace.CurrentCamera
					return Ray.new(cam.CFrame.Position, (aimPoint - cam.CFrame.Position).Unit)
				end
			elseif key == "Hit" and aimIsFresh() then
				return CFrame.new(aimPoint)
			end
		end
		return oldIndex(self, key)
	end)

	-- Tried and removed: rewriting the gun's own GunTrigger / GunAim messages so every shot points straight
	-- at the target. With it on the server registered 0 hits (the Hit packet counter below); with it off
	-- it registered 4-12 per 4 seconds. The server evidently rejects shots whose direction it did not
	-- expect, so the gun's messages are left exactly as the game builds them.

	ctx:HookMeta(game, "__namecall", function(oldNamecall, self, ...)
		local method = getnamecallmethod()
		if self == UserInputService and not checkcaller() and method == "GetMouseLocation" then
			aimReads.Location = aimReads.Location + 1
			if aimIsFresh() then
				aimReads.LocationOverridden = aimReads.LocationOverridden + 1
				local screen = Workspace.CurrentCamera:WorldToViewportPoint(aimPoint)
				return Vector2.new(screen.X, screen.Y)
			end
		end
		return oldNamecall(self, ...)
	end)

	-- keep the aim point on the chosen monkey as it moves between attack ticks
	ctx:Connect(game:GetService("RunService").RenderStepped, function()
		local unit = aimUnitId and units[aimUnitId]
		if unit and aimIsFresh() then
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				aimPoint = leadAimPoint(unit, aimUnitId, root.Position)
			end
		end
	end)

	task.spawn(function()
		while ctx:Alive() do
			task.wait(AIM_REPORT_EVERY)
			if (State.AutoAttackMonkeys or State.AutoFarm) and (aimReads.Ray > 0 or aimReads.Location > 0) then
				debugLog("Aim", ("aim hook: UnitRay read %d times (%d answered), mouse location read %d times (%d answered)"):format(
					aimReads.Ray, aimReads.RayOverridden, aimReads.Location, aimReads.LocationOverridden))
			elseif State.AutoAttackMonkeys or State.AutoFarm then
				debugLog("Aim", "aim hook: the game has not read the mouse in the last few seconds", "warn")
			end
			if State.AutoAttackMonkeys or State.AutoFarm then
				debugLog("Hits", ("server hits seen: %d in total, %d on the current target"):format(
					hitTotal, aimUnitId and hitsOn[aimUnitId] or 0))
				hitTotal = 0
				table.clear(hitsOn)
				local tracked, down, frozen, friendly, bosses, skipped, now = 0, 0, 0, 0, 0, 0, os.clock()
				local character = LocalPlayer.Character
				local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
				local nearest, inRange = math.huge, 0
				for id, unit in units do
					if now - unit.Seen <= UNIT_TTL then
						tracked = tracked + 1
						if playerRoot and not isFriendlyUnit(id) then
							local distance = (unit.Pos - playerRoot.Position).Magnitude
							nearest = math.min(nearest, distance)
							if weaponRange and distance <= weaponRange then inRange = inRange + 1 end
						end
						if unit.State == STATE_DOWN then down = down + 1 end
						if unit.Frozen then frozen = frozen + 1 end
						if isFriendlyUnit(id) then friendly = friendly + 1 end
						if isBossUnit(id) then bosses = bosses + 1 end
						if now < (skipUntil[id] or 0) then skipped = skipped + 1 end
					end
				end
				debugLog("Targets", ("targets: %d tracked (%d down, %d frozen, %d friendly, %d boss, %d skipped as stuck) | nearest %s studs, weapon range %s, %d in range"):format(
					tracked, down, frozen, friendly, bosses, skipped,
					nearest < math.huge and ("%.0f"):format(nearest) or "-",
					weaponRange and ("%.0f"):format(weaponRange) or "unknown", inRange))
			end
			for key in aimReads do aimReads[key] = 0 end
		end
	end)

	-- The equipped weapon's WeaponConfig module (the one GunRigController reads) lists its projectile
	-- speed and maximum range. Cached per tool.
	local weaponStatsCache = setmetatable({}, { __mode = "k" })

	local function weaponStats(tool)
		local cached = weaponStatsCache[tool]
		if cached == nil then
			local module = tool:FindFirstChild("WeaponConfig")
			local ok, config = pcall(function() return module and require(module) end)
			local projectile = ok and type(config) == "table" and config.projectile
			cached = projectile and { Range = projectile.maxRange, Speed = projectile.speed } or false
			weaponStatsCache[tool] = cached
		end
		return cached or nil
	end

	-- Where to aim for `unit`: its centre of mass, led by how far it walks during the snapshot lag and the
	-- bullet's flight time.
	function leadAimPoint(unit, id, from)
		if not LEAD_AIM then return unit.Pos + Vector3.new(0, aimHeightOf(id), 0) end
		local lead = SNAPSHOT_LAG + (weaponSpeed and (unit.Pos - from).Magnitude / weaponSpeed or 0)
		local velocity = unit.Vel or Vector3.zero
		return unit.Pos + velocity * lead + Vector3.new(0, aimHeightOf(id), 0)
	end

	function attackMonkeys()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum and hum.Health > 0) then return end

		local tool = char:FindFirstChildOfClass("Tool")
		if not tool then
			tool = LocalPlayer.Backpack:FindFirstChildOfClass("Tool")
			if tool then hum:EquipTool(tool) end
			return
		end

		local stats = weaponStats(tool)
		weaponRange, weaponSpeed = stats and stats.Range, stats and stats.Speed

		local unit, unitId = nearestMonkey(root.Position, weaponRange)
		if not unit then
			-- Activate() starts the gun firing and it keeps going; with nothing in reach it would
			-- keep shooting wherever the real mouse is, so stop it
			aimPoint, aimUnitId = nil, nil
			tool:Deactivate()
			return
		end
		local target = unit.Pos

		if debugSettings.Shot then
			log(("unit %d state %d | target %s | dist %.1f | still for %.1fs"):format(
				unitId, unit.State, tostring(target), (target - root.Position).Magnitude, os.clock() - unit.Since))
		end
		aimPoint = leadAimPoint(unit, unitId, root.Position)
		aimSetAt, aimUnitId = os.clock(), unitId
		tool:Activate()
		return aimPoint
	end
end

do
	-- Upgrades are bought with Remotes.UpgradeRequest:FireServer("<Name>"). Each upgrade's
	-- cost/availability is exposed as player attributes (e.g. HealthUpgradeCost, Cash).
	-- Only "Health" is a confirmed remote argument; "Weapon" is a guess from the attribute names -
	-- correct it once captured with Cobalt. Each toggle buys its own upgrade.
	local HEALTH = { { Arg = "Health", Cost = "HealthUpgradeCost", Available = "HealthUpgradeAvailable" } }
	local WEAPON = { { Arg = "Weapon", Cost = "WeaponUpgradeCost", Available = "WeaponUpgradeAvailable" } }

	-- Buys every affordable upgrade in `group`, spending from the player's Cash.
	local function buyGroup(group)
		local remote = ReplicatedStorage.Remotes:FindFirstChild("UpgradeRequest")
		if not remote then return end
		local cash = LocalPlayer:GetAttribute("Cash") or 0
		for _, up in group do
			local cost = LocalPlayer:GetAttribute(up.Cost)
			local available = up.Available == nil or LocalPlayer:GetAttribute(up.Available) == true
			if available and type(cost) == "number" and cost <= cash then
				remote:FireServer(up.Arg)
				cash = cash - cost
			end
		end
	end

	function upgradeHealth() buyGroup(HEALTH) end
	function upgradeWeapon() buyGroup(WEAPON) end
end

do
	-- ProximityPrompts are validated by the server against your real character position, so a
	-- bare fireproximityprompt from across the map is ignored. usePrompt briefly moves the
	-- character beside the prompt, forces it usable (the client disables prompts it doesn't
	-- "want"), fires it, then restores everything. One prompt at a time, with a per-prompt
	-- cooldown so a prompt that doesn't accept doesn't get hammered.
	local PROMPT_COOLDOWN = 3 -- seconds before the same prompt is tried again
	local PROMPT_SETTLE = 0.25 -- seconds to let the new position replicate before/after firing
	promptBusy = false
	local promptCooldown = setmetatable({}, { __mode = "k" })

	local function usePrompt(prompt, label)
		if promptBusy or os.clock() < (promptCooldown[prompt] or 0) then return false end

		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local part = prompt.Parent
		if part and part:IsA("Attachment") then part = part.Parent end
		if not (root and part and part:IsA("BasePart")) then return false end

		promptBusy = true
		promptCooldown[prompt] = os.clock() + PROMPT_COOLDOWN
		local home = root.CFrame
		local enabled, hold, needsSight = prompt.Enabled, prompt.HoldDuration, prompt.RequiresLineOfSight

		local ok, err = pcall(function()
			prompt.Enabled, prompt.HoldDuration, prompt.RequiresLineOfSight = true, 0, false
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
			task.wait(PROMPT_SETTLE)
			fireproximityprompt(prompt)
			task.wait(PROMPT_SETTLE)
		end)

		if prompt.Parent then
			prompt.Enabled, prompt.HoldDuration, prompt.RequiresLineOfSight = enabled, hold, needsSight
		end
		if root.Parent then
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = home
		end
		promptBusy = false

		if ok then
			debugLog("Actions", "used prompt: " .. label)
		else
			log(("prompt %s failed: %s"):format(label, tostring(err)), "error")
		end
		return ok
	end

	-- Boss chests. What a boss chest looks like in the world has not been captured, so this is a net:
	--   * a chest in Workspace.Chests with no "Price" attribute (below) counts as free, and
	--   * anything else sitting directly in Workspace or Workspace.Transients whose name mentions a
	--     chest, boss, reward or loot, and that holds an enabled ProximityPrompt, is opened too.
	-- Range does not matter: usePrompt moves the character to the prompt. The names found are written to
	-- the Debug tab (Actions) once each, so the net can be narrowed to the real name.
	local collectBossChests
	do
		local WORDS = { "boss", "chest", "reward", "loot" }
		local HANDLED = { Chests = true, FloorItems = true, UnitViews = true, Vendor = true }
		local reported = {}

		local function matches(name)
			local lowered = name:lower()
			for _, word in WORDS do
				if lowered:find(word, 1, true) then return true end
			end
			return false
		end

		collectBossChests = function(cash)
			for _, root in { Workspace, Workspace:FindFirstChild("Transients") } do
				for _, child in root:GetChildren() do
					if not HANDLED[child.Name] and child ~= LocalPlayer.Character and matches(child.Name) then
						local prompt = child:IsA("ProximityPrompt") and child or child:FindFirstChildWhichIsA("ProximityPrompt", true)
						local price = child:GetAttribute("Price")
						if prompt and not reported[child] then
							reported[child] = true
							debugLog("Actions", ("boss chest candidate: %s (%s, price %s)"):format(
								child:GetFullName(), child.ClassName, tostring(price)))
						end
						if prompt and prompt.Enabled and (type(price) ~= "number" or price <= cash)
							and not child:GetAttribute("Leaving") then
							if usePrompt(prompt, "boss chest " .. child.Name) and type(price) == "number" then
								cash = cash - price
							end
						end
					end
				end
			end
		end
	end

	-- Chests: Workspace.Chests holds Models with a "Price" attribute (paid in the player's
	-- "Cash" attribute) and a ProximityPrompt. Opened chests are listed in the player's
	-- "OpenedChests" attribute. Loot drops land as Models in Workspace.FloorItems, also
	-- picked up through a ProximityPrompt (the client disables it when you can't take it).
	function collectChests()
		local cash = LocalPlayer:GetAttribute("Cash") or 0

		local opened = {}
		for _, name in string.split(LocalPlayer:GetAttribute("OpenedChests") or "", ",") do
			opened[name] = true
		end

		local chests = Workspace:FindFirstChild("Chests")
		if chests then
			for _, chest in chests:GetChildren() do
				local price = chest:GetAttribute("Price") or 0 -- a chest with no price (a boss chest) is free
				local prompt = chest:FindFirstChildWhichIsA("ProximityPrompt", true)
				if prompt and not opened[chest.Name] and not chest:GetAttribute("Leaving")
					and type(price) == "number" and price <= cash then
					if usePrompt(prompt, ("chest %s ($%d)"):format(chest.Name, price)) then
						cash = cash - price
					end
				end
			end
		end

		local floorItems = Workspace:FindFirstChild("FloorItems")
		if floorItems then
			for _, item in floorItems:GetChildren() do
				local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
				if prompt and prompt.Enabled then
					usePrompt(prompt, "floor item " .. tostring(item:GetAttribute("Item") or item.Name))
				end
			end
		end

		collectBossChests(cash)
	end

	-- Workspace.Vendor is a Model with parts named "Good_<slot>", each holding a
	-- ProximityPrompt. Stock lives in the LocalPlayer attribute "VendorStock" as
	-- "slot=itemId:price:count,..." (see VendorController). Purchases go through the prompt.
	local function parseStock(raw)
		local stock = {}
		for _, entry in string.split(raw or "", ",") do
			local slot, id, price, count = entry:match("^([^=]+)=([^:]+):(%d+):(%d+)$")
			if slot then
				stock[slot] = { Id = id, Price = tonumber(price), Count = tonumber(count) }
			end
		end
		return stock
	end

	function buyFromMerchant()
		local vendor = Workspace:FindFirstChild("Vendor")
		if not vendor or vendor:GetAttribute("Leaving") then return end
		local arrivedAt = (vendor:GetAttribute("ArrivedAt") or 0) + (vendor:GetAttribute("Landed") or 0)
		if Workspace:GetServerTimeNow() < arrivedAt then return end

		local cash = LocalPlayer:GetAttribute("Cash") or 0
		for slot, item in parseStock(LocalPlayer:GetAttribute("VendorStock")) do
			if item.Count > 0 and item.Price <= cash then
				local good = vendor:FindFirstChild("Good_" .. slot, true)
				local prompt = good and good:FindFirstChildWhichIsA("ProximityPrompt")
				if prompt and usePrompt(prompt, ("vendor %s (%s, $%d)"):format(slot, item.Id, item.Price)) then
					cash = cash - item.Price
				end
			end
		end
	end
end

do
	-- Splash dodging ----------------------------------------------------------------
	-- Hazards come from server-driven sources (see the matching client controllers):
	--   * Acid pools: Workspace.Transients children named "Pool" with attributes At (Vector3),
	--     Radius and Ends (server time) - ExplosionController.drawPool.
	--   * Thrown payloads: Shared.Effects.Throw(id, class, origin, hitPos, restPos, up, launchAt,
	--     landAt); the AoE fires Aoe.Windup seconds after it settles - GrenadeController.thrown.
	--   * Spitter cones: Shared.Effects.Spit(id, origin, direction, groundY); a 36 stud cone that
	--     lands after Spit.Land and lasts Spit.Spray - SpitterController.
	--   * Boss attacks: Shared.Bosses.Fx - ring bursts, residue pools, volley shots, charges and bullets.
	local DODGE_MARGIN = 4 -- extra studs to keep clear of any hazard edge
	local DEFAULT_THROW_RADIUS = 10 -- used when the payload's Aoe has no radius we can read
	local SPIT_LENGTH = 36
	local BOSS_SHOT_RADIUS = 8 -- fallback when a volley attack's size isn't in Bosses.Definitions
	local BOSS_CHARGE_WIDTH = 10 -- fallback when a charge's width isn't in Bosses.Definitions
	local BOSS_BULLET_WIDTH = 3 -- guess: how wide a boss bullet's path is
	local BOSS_SPOT_RADIUS = 14 -- fallback radius when an attack's size isn't in Bosses.Definitions
	local BOSS_SPOT_SECONDS = 2 -- how long such an area stays dangerous
	local SPIT_FALLBACK_ANGLE = 60 -- degrees, used if AoePatterns can't be read

	function safeRequire(path)
		local ok, result = pcall(function()
			local node = ReplicatedStorage
			for _, name in string.split(path, ".") do node = node[name] end
			return require(node)
		end)
		return ok and result or nil
	end

	EnemyCatalog = safeRequire("Shared.Units.EnemyCatalog")
	UnitProtocol = safeRequire("Shared.Units.UnitProtocol")
	local AoePatterns = safeRequire("Shared.Content.AoePatterns")

	-- Every boss attack's danger area is defined in Shared.Bosses.Definitions.<Boss>.Attacks.<Name>.
	-- The size lives in different places per attack, so take the largest that applies:
	--   Landing.Radius (Pogo), Hits[].Radius (CaneSlam), Zones.Radius (Eclipse), Shots[].Radius
	--   (Volley attacks), then Aoe.Radius / Aoe.Width (Circle / Line). A radius of 1 is only a
	--   placeholder for attacks that have no ground area (Gaze, Feast, BulletHose...), so ignore it.
	local attackSize = {} -- attack name -> studs
	local PLACEHOLDER_SIZE = 1

	local function sizeOfAttack(attack)
		local size = 0
		local function consider(value)
			if type(value) == "number" and value > PLACEHOLDER_SIZE then size = math.max(size, value) end
		end
		consider(attack.Landing and attack.Landing.Radius)
		consider(attack.Zones and attack.Zones.Radius)
		consider(attack.Aoe and (attack.Aoe.Radius or attack.Aoe.Width))
		for _, hit in attack.Hits or {} do
			if type(hit) == "table" then consider(hit.Radius) end
		end
		for _, shot in attack.Shots or {} do
			if type(shot) == "table" then consider(shot.Radius) end
		end
		return size > 0 and size or nil
	end

	do
		local definitions = ReplicatedStorage.Shared:FindFirstChild("Bosses")
		definitions = definitions and definitions:FindFirstChild("Definitions")
		for _, module in definitions and definitions:GetChildren() or {} do
			local ok, boss = pcall(require, module)
			if ok and type(boss) == "table" and type(boss.Attacks) == "table" then
				for name, attack in boss.Attacks do
					local size = sizeOfAttack(attack)
					if size then attackSize[name] = math.max(attackSize[name] or 0, size) end
				end
			end
		end
	end

	local spitSettings = EnemyCatalog and EnemyCatalog.Spitter and EnemyCatalog.Spitter.Spit
	local spitAngle = SPIT_FALLBACK_ANGLE
	if spitSettings and AoePatterns then
		local pattern = AoePatterns.Patterns[spitSettings.Pattern]
		spitAngle = pattern and pattern[1] and pattern[1].Angle or spitAngle
	end

	hazards = {} -- list of { Kind, Until, Center/Radius or Origin/Dir/Length/HalfAngle }

	local function addHazard(hazard)
		table.insert(hazards, hazard)
		if not hazard.Quiet then
			debugLog("Hazards", ("hazard: %s %s"):format(hazard.Kind, tostring(hazard.Center or hazard.Origin)))
		end
	end

	local flat = function(v) return Vector3.new(v.X, 0, v.Z) end

	function inHazard(hazard, point)
		local p = flat(point)
		if hazard.Inner then -- ring: Center, Inner, Outer
			local d = (p - flat(hazard.Center)).Magnitude
			return d > hazard.Inner - DODGE_MARGIN and d < hazard.Outer + DODGE_MARGIN
		end
		if hazard.Radius then
			return (p - flat(hazard.Center)).Magnitude < hazard.Radius + DODGE_MARGIN
		end
		local rel = p - flat(hazard.Origin)
		local along = rel:Dot(hazard.Dir)
		if along < -DODGE_MARGIN or along > hazard.Length + DODGE_MARGIN then return false end
		local perp = (rel - hazard.Dir * along).Magnitude
		if hazard.Width then -- line: Origin, Dir, Length, Width
			return perp < hazard.Width / 2 + DODGE_MARGIN
		end
		return perp < math.max(along, 0) * math.tan(hazard.HalfAngle) + DODGE_MARGIN
	end

	function inAnyHazard(point)
		for _, hazard in hazards do
			if inHazard(hazard, point) then return true end
		end
		return false
	end

	local function trackHazards()
		local effects = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects")

		ctx:Connect(effects:WaitForChild("Throw").OnClientEvent, 
			function(_, class, _, hitPos, restPos, _, _, landAt)
				if typeof(hitPos) ~= "Vector3" then return end
				local payload = UnitProtocol and UnitProtocol.ClassPayload[class]
				local aoe = payload and payload.Aoe
				local radius = aoe and (aoe.Radius or aoe.Range) or DEFAULT_THROW_RADIUS
				local fall = math.sqrt(math.max(hitPos.Y - restPos.Y, 0) * 2 / Workspace.Gravity)
				addHazard({
					Kind = "throw", Center = hitPos, Radius = radius,
					Until = landAt + fall + (aoe and aoe.Windup or 1) + 0.5,
				})
			end
		)

		ctx:Connect(effects:WaitForChild("Spit").OnClientEvent, function(_, origin, direction)
			if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then return end
			local dir = flat(direction)
			if dir.Magnitude < 0.001 then return end
			local now = Workspace:GetServerTimeNow()
			addHazard({
				Kind = "spit", Origin = origin, Dir = dir.Unit, Length = SPIT_LENGTH,
				HalfAngle = math.rad(spitAngle) / 2,
				Until = now + (spitSettings and (spitSettings.Land + spitSettings.Spray) or 3),
			})
		end)

		-- Boss attacks: Shared.Bosses.Fx(id, generation, phase, attackName, data), handled by
		-- BossViewController. Only the phases whose data carries a position are turned into hazards.
		local bossFx = ReplicatedStorage.Shared:WaitForChild("Bosses"):WaitForChild("Fx")
		local seenFx = {}
		ctx:Connect(bossFx.OnClientEvent, function(_, _, phase, attackName, data)
			if phase == "Windup" then
				debugLog("Boss", ("boss windup: %s"):format(tostring(attackName)))
			end
			if type(data) ~= "table" then return end
			local now = Workspace:GetServerTimeNow()

			if phase == "Burst" and typeof(data.Center) == "Vector3" and data.Inner and data.Outer then
				addHazard({ Kind = "boss ring", Center = data.Center, Inner = data.Inner,
					Outer = data.Outer, Until = (data.Land or now) + 0.6 })
			elseif phase == "Residue" and typeof(data.At) == "Vector3" and data.Radius then
				addHazard({ Kind = "boss residue", Center = data.At, Radius = data.Radius,
					Until = data.Ends or now + 3 })
			elseif phase == "Shot" and typeof(data.At) == "Vector3" and data.Land then
				addHazard({ Kind = "boss shot", Center = data.At, Radius = attackSize[attackName] or BOSS_SHOT_RADIUS,
					Until = data.Land + 0.5 })
			elseif (phase == "Charge" or phase == "Dash") and data.At and data.Direction and data.Distance then
				local dir = Vector3.new(data.Direction.X, 0, data.Direction.Z)
				if dir.Magnitude > 0.001 then
					addHazard({ Kind = "boss charge", Origin = Vector3.new(data.At.X, 0, data.At.Z),
						Dir = dir.Unit, Length = data.Distance,
						Width = attackSize[attackName] or BOSS_CHARGE_WIDTH,
						Until = (data.Start or now) + (data.Duration or 1) + 0.3 })
				end
			elseif phase == "Bullets" and typeof(data.From) == "Vector3" and type(data.Directions) == "table" then
				-- BossViewController.Bullets.fire: each direction is a bullet travelling Stops[i]
				-- studs from From at Speed, starting at Time (+ the unit interpolation delay).
				local startsAt = (data.Time or now) + (UnitProtocol and UnitProtocol.InterpolationDelay or 0.15)
				for i, direction in data.Directions do
					local dir = Vector3.new(direction.X, 0, direction.Z)
					local length = data.Stops and data.Stops[i] or data.Reach
					if dir.Magnitude > 0.001 and length then
						addHazard({ Kind = "boss bullet", Origin = Vector3.new(data.From.X, 0, data.From.Z),
							Dir = dir.Unit, Length = length, Width = BOSS_BULLET_WIDTH,
							Until = startsAt + length / math.max(data.Speed or 60, 1) + 0.3, Quiet = true })
					end
				end
				debugLog("Boss", ("boss bullets: %d bullets"):format(#data.Directions))
			elseif phase == "Shockwave" then
				local keys = {}
				for k in data do table.insert(keys, tostring(k)) end
				debugLog("Boss", "boss shockwave (not dodged yet), data keys: " .. table.concat(keys, ", "))
			elseif typeof(data.At) == "Vector3" then
				-- Any other phase that points at a spot (e.g. "Impact" for the attack "Danse"):
				-- treat it as a circle there, sized from the attack's definition when we know it.
				addHazard({ Kind = ("boss %s/%s"):format(tostring(attackName), tostring(phase)),
					Center = data.At, Radius = data.Radius or attackSize[attackName] or BOSS_SPOT_RADIUS,
					Until = data.Ends or (data.Land and data.Land + 0.5) or now + BOSS_SPOT_SECONDS })
			end

			-- Log the layout of every phase we haven't seen before, so unknown attacks can be tuned.
			local seenKey = tostring(attackName) .. "/" .. tostring(phase)
			if not seenFx[seenKey] then
				seenFx[seenKey] = true
				local keys = {}
				for k, v in data do table.insert(keys, ("%s=%s"):format(tostring(k), typeof(v))) end
				debugLog("Boss", ("boss fx %s data: %s"):format(seenKey, table.concat(keys, ", ")))
			end
		end)
	end
	task.spawn(trackHazards)

	function refreshHazards()
		local now = Workspace:GetServerTimeNow()
		for i = #hazards, 1, -1 do
			if hazards[i].Until < now then table.remove(hazards, i) end
		end

		local transients = Workspace:FindFirstChild("Transients")
		if not transients then return end
		for _, child in transients:GetChildren() do
			local ends, at, radius = child:GetAttribute("Ends"), child:GetAttribute("At"), child:GetAttribute("Radius")
			if child.Name == "Pool" and not child:GetAttribute("DodgeSeen") and type(ends) == "number"
				and typeof(at) == "Vector3" and type(radius) == "number" then
				child:SetAttribute("DodgeSeen", true)
				addHazard({ Kind = "pool", Center = at, Radius = radius, Until = ends })
			end
		end
	end

	local ESCAPE_DIRECTIONS, ESCAPE_DISTANCES = 16, { 6, 10, 14, 18, 24 }

	function hasGround(point)
		local result = Workspace:Raycast(point + Vector3.new(0, 20, 0), Vector3.new(0, -120, 0))
		return result ~= nil
	end

	function dodgeSplash()
		refreshHazards()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum and hum.Health > 0) or not inAnyHazard(root.Position) then return end

		for _, distance in ESCAPE_DISTANCES do
			for i = 0, ESCAPE_DIRECTIONS - 1 do
				local angle = i / ESCAPE_DIRECTIONS * math.pi * 2
				local candidate = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * distance
				if not inAnyHazard(candidate) and hasGround(candidate) then
					hum:MoveTo(candidate)
					return
				end
			end
		end
	end
end

do
	-- Safe distance -------------------------------------------------------------------
	-- Keeps the character at least `safeDistance` studs from the nearest monkey. When one gets
	-- closer, it scores spots around the character (far from every tracked monkey, outside every
	-- hazard, with ground underneath), then asks PathfindingService for a route to the best few and
	-- walks the first route whose waypoints also stay clear of hazards and monkeys. It re-plans every
	-- tick, so the route follows the monkeys as they move. Falls back to a straight line if no path
	-- is found. Monkey positions come from the same snapshot table Auto Attack uses; by default only
	-- melee monkeys count (see MELEE_ONLY).
	local PathfindingService = game:GetService("PathfindingService")

	safeDistance = 25 -- studs, set by the slider
	local SAFE_ANGLES = 16
	local SAFE_RINGS = { 12, 20, 28 }
	local SAFE_TRY_PATHS = 4 -- how many of the best-scored spots to path-find to
	local WAYPOINT_CLEARANCE = 4 -- a route waypoint must stay this far from any monkey
	local TRAVEL_PENALTY = 0.15 -- prefer closer retreat spots over equally safe far ones
	local lastRetreatLog = 0

	-- Unit classes arrive in Shared.Units.Control "Present" events (UnitViewController.onControl:
	-- code, id, generation, class, ...). UnitProtocol.ClassRange[class] is false for enemies with no
	-- ranged attack; Exploders (Range 3) and the bosses (Range 4) have a short one, so anything with a
	-- Range up to MELEE_RANGE also counts as melee. Friendly classes are never a threat.
	local MELEE_ONLY = true -- only melee monkeys trigger and shape the retreat
	local MELEE_RANGE = 8 -- studs; attack range up to this counts as melee
	classOf = {} -- unit id -> class index

	isFriendlyUnit = function(id)
		local class = classOf[id]
		return class ~= nil and UnitProtocol ~= nil and UnitProtocol.ClassFriendly[class] == true
	end

	aimHeightOf = function(id)
		local class = classOf[id]
		local row = EnemyCatalog and class and EnemyCatalog.Ordered[class]
		local height = row and (row.HitHeight or row.Height)
		return height and height / 2 or AIM_HEIGHT
	end

	task.spawn(function()
		local hit = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Units"):WaitForChild("Hit")
		ctx:Connect(hit.OnClientEvent, function(buf)
			if not UnitProtocol or typeof(buf) ~= "buffer" then return end
			pcall(UnitProtocol.decodeHits, buf, function(id)
				hitsOn[id] = (hitsOn[id] or 0) + 1
				hitTotal = hitTotal + 1
			end)
		end)
	end)

	isBossUnit = function(id)
		local class = classOf[id]
		return class ~= nil and UnitProtocol ~= nil and UnitProtocol.ClassHasBody[class] == true
	end

	-- A hostile enemy whose attack reaches further than MELEE_RANGE (Flyer 30, Thrower 60, ...)
	isRangedThreat = function(id)
		local class = classOf[id]
		local row = EnemyCatalog and class and EnemyCatalog.Ordered[class]
		return row ~= nil and not row.Friendly and row.Range ~= nil and row.Range > MELEE_RANGE
	end

	local function isMelee(id)
		local class = classOf[id]
		if not (class and UnitProtocol) then return true end -- class not seen yet: assume melee
		local range = UnitProtocol.ClassRange[class]
		return (range == false or range <= MELEE_RANGE) and not UnitProtocol.ClassFriendly[class]
	end

	task.spawn(function()
		local control = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Units"):WaitForChild("Control")
		local present = UnitProtocol and UnitProtocol.Present or 2
		local reset = UnitProtocol and UnitProtocol.Reset or 1
		local shown = 0
		ctx:Connect(control.OnClientEvent, function(code, id, generation, class, ...)
			if debugSettings.Control and shown < 8 then
				shown = shown + 1
				debugLog("Control", ("control event %s: %s, %s, %s (%s)"):format(tostring(code), typeof(id), typeof(generation), typeof(class), tostring(class)))
			end
			if code == present and type(id) == "number" and type(class) == "number" then
				classOf[id] = class
			elseif code == reset then
				table.clear(classOf)
			end
		end)
	end)

	function liveUnitPositions()
		local now, positions = os.clock(), {}
		for id, unit in units do
			if now - unit.Seen <= UNIT_TTL and unit.State ~= STATE_DOWN and not unit.Frozen
				and (not MELEE_ONLY or isMelee(id)) then
				table.insert(positions, unit.Pos)
			end
		end
		return positions
	end

	function nearestDistance(point, positions)
		local best = math.huge
		for _, pos in positions do
			local d = (pos - point).Magnitude
			if d < best then best = d end
		end
		return best
	end

	local function routeIsClear(waypoints, positions)
		for i = 2, #waypoints do
			local point = waypoints[i].Position
			if inAnyHazard(point) or nearestDistance(point, positions) < WAYPOINT_CLEARANCE then
				return false
			end
		end
		return true
	end

	-- Stuck handling (Auto Farm only): while a monkey is inside the safe distance, a character that
	-- has moved less than STUCK_MOVE studs for STUCK_SECONDS is stuck (a wall, a prop, a failed path),
	-- so it is teleported to the best clear spot instead of walking.
	local STUCK_SECONDS = 1 -- how long without progress before teleporting
	local STUCK_MOVE = 2 -- studs the character must move to count as progress
	local TELEPORT_RINGS = { 28, 40, 55 }
	local stuckAnchor, stuckSince = nil, 0

	function teleportToSafety(root, positions, reason)
		local best, bestScore = nil, -math.huge
		for _, ring in TELEPORT_RINGS do
			for i = 0, SAFE_ANGLES - 1 do
				local angle = i / SAFE_ANGLES * math.pi * 2
				local point = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * ring
				if not inAnyHazard(point) and hasGround(point) then
					local score = math.min(nearestDistance(point, positions), safeDistance * 1.5) - ring * TRAVEL_PENALTY
					if score > bestScore then best, bestScore = point, score end
				end
			end
		end
		if not best then return false end
		local distance = (best - root.Position).Magnitude
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(best + Vector3.new(0, 3, 0)) * root.CFrame.Rotation
		debugLog("Movement", ("%s: teleported %.0f studs to %s"):format(reason or "stuck", distance, tostring(best)))
		return true
	end

	function keepSafeDistance(allowTeleport)
		if State.AutoFarm then return end -- Auto Farm positions the character itself
		if promptBusy then return end
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum and hum.Health > 0) then return end

		local positions = liveUnitPositions()
		local nearest = nearestDistance(root.Position, positions)
		if nearest >= safeDistance then
			stuckAnchor = nil
			return
		end

		refreshHazards()

		if allowTeleport then
			local now = os.clock()
			if not stuckAnchor or (root.Position - stuckAnchor).Magnitude >= STUCK_MOVE then
				stuckAnchor, stuckSince = root.Position, now
			elseif now - stuckSince >= STUCK_SECONDS and teleportToSafety(root, positions) then
				stuckAnchor = nil
				return
			end
		end

		local spots = {}
		for _, ring in SAFE_RINGS do
			for i = 0, SAFE_ANGLES - 1 do
				local angle = i / SAFE_ANGLES * math.pi * 2
				local point = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * ring
				if not inAnyHazard(point) and hasGround(point) then
					local clear = math.min(nearestDistance(point, positions), safeDistance * 1.5)
					table.insert(spots, { Point = point, Score = clear - ring * TRAVEL_PENALTY })
				end
			end
		end
		table.sort(spots, function(a, b) return a.Score > b.Score end)

		local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 5, AgentCanJump = true })
		for i = 1, math.min(SAFE_TRY_PATHS, #spots) do
			local ok = pcall(path.ComputeAsync, path, root.Position, spots[i].Point)
			if ok and path.Status == Enum.PathStatus.Success then
				local waypoints = path:GetWaypoints()
				if #waypoints >= 2 and routeIsClear(waypoints, positions) then
					local step = waypoints[math.min(3, #waypoints)]
					if step.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
					hum:MoveTo(step.Position)
					if os.clock() - lastRetreatLog > 3 then
						lastRetreatLog = os.clock()
						debugLog("Movement", ("retreating: nearest monkey %.1f studs, heading to %s"):format(nearest, tostring(spots[i].Point)))
					end
					return
				end
			end
		end

		-- no clear route found: take the best open spot in a straight line
		if spots[1] then hum:MoveTo(spots[1].Point) end
	end
end

do
	-- Auto farm -----------------------------------------------------------------------
	-- Attack and hover, nothing else (no upgrades, no collecting). Each tick: Auto Attack's aiming and
	-- shooting, then the character is held `hoverHeight` studs up at a stand-off point beside the nearest
	-- group of monkeys, facing its target, keeping clear of hazards. A per-physics-step handler
	-- (see startHold) moves the root part toward that point, cancels gravity's velocity and turns collision
	-- off (noclip) while hovering, and pauses while a chest/item prompt is being used (usePrompt moves
	-- the character itself). The root part is NOT anchored: the server would never see an anchored part
	-- move.
	-- Void protection: the character only hovers while there is a monkey to attack; with none left it is
	-- lowered back onto the floor. A check on every tick also rescues a character that ends up near
	-- FallenPartsDestroyHeight or over nothing, sending it to the last spot it stood on.
	-- Stand-off: height does not stop melee hits (the damage log showed hits landing from 20 studs
	-- above), so the character keeps `safeDistance` along the ground from the monkeys (never further than
	-- the weapon can reach) and out of every danger zone. Hovering right over them got it killed.
	hoverHeight = 20 -- studs above the floor, set by the slider
	local FARM_SPEED = 70 -- studs per second toward the hover point
	local FLY_LIMIT = 100 -- studs: a hover point further than this is teleported to, not flown to
	local JUMP_COOLDOWN = 1 -- seconds between teleports to the monkeys
	local lastJump = 0
	FARM_TICK = 0.1 -- seconds between farm ticks
	local FARM_CLUSTER_RADIUS = 25 -- monkeys this close to the nearest one count as its cluster
	local RANGED_MARGIN = 5 -- studs beyond a ranged enemy's attack range to stay
	local RANGED_CAP = 40 -- ...but never ask for more than this from any one enemy
	local VOID_MARGIN = 60 -- never go within this many studs of FallenPartsDestroyHeight
	local RunService = game:GetService("RunService")
	local holdConnection
	local airborne = false -- true while the character is being held in the air
	local lastSafeCFrame -- last place the character stood on the floor
	local farmGoal -- world position the character is being moved to, or nil
	local farmFace -- world position the character turns to face, or nil

	local function characterParts()
		local char = LocalPlayer.Character
		return char, char and char:FindFirstChild("HumanoidRootPart"), char and char:FindFirstChildOfClass("Humanoid")
	end

	-- The floor straight above/below `position`, ignoring the character and the monkey models.
	local function floorAt(position, char)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char, Workspace:FindFirstChild("UnitViews") }
		return Workspace:Raycast(position + Vector3.new(0, 150, 0), Vector3.new(0, -400, 0), params)
	end

	-- Centre of the nearest group of hostile monkeys, all their positions, and for each the distance it
	-- must be kept at (nil = the normal stand-off). A ranged enemy has to be kept beyond its own attack
	-- range, or it shoots the character however far off the melee monkeys are.
	local function farmCentre(from)
		local now, positions, needs = os.clock(), {}, {}
		for id, unit in units do
			local class = classOf[id]
			local friendly = class and UnitProtocol and UnitProtocol.ClassFriendly[class]
			if now - unit.Seen <= UNIT_TTL and unit.State ~= STATE_DOWN and not unit.Frozen and not friendly then
				table.insert(positions, unit.Pos)
				if isRangedThreat(id) then
					local row = EnemyCatalog.Ordered[class]
					needs[#positions] = math.min(row.Range + RANGED_MARGIN, RANGED_CAP)
				end
			end
		end

		local nearest, nearestDist = nil, math.huge
		for _, pos in positions do
			local d = (pos - from).Magnitude
			if d < nearestDist then nearest, nearestDist = pos, d end
		end
		if not nearest then return nil end

		local sum, count = Vector3.zero, 0
		for _, pos in positions do
			if (pos - nearest).Magnitude <= FARM_CLUSTER_RADIUS then sum, count = sum + pos, count + 1 end
		end
		return sum / count, positions, needs
	end

	-- Stay where we are while at least STANDOFF_SLACK of the stand-off distance from every monkey and out
	-- of hazards; otherwise pick the spot on a ring around the group that is clear of both and the
	-- shortest move from here.
	local STANDOFF_ANGLES = 16
	local STANDOFF_SLACK = 0.85
	local WEAPON_REACH_SHARE = 0.6 -- stand off at most this fraction of the weapon's range

	local function standoffPoint(root, centre, positions, needs)
		-- a spread weapon (shotgun) only lands pellets close up, so never stand further off than the
		-- weapon can reliably reach, whatever the Safe Distance slider says
		local standoff = weaponRange and math.min(safeDistance, weaponRange * WEAPON_REACH_SHARE) or safeDistance

		-- how far inside its required distance the closest monkey is (negative = too close)
		local function margin(point)
			local worst = math.huge
			for i, pos in positions do
				local m = (pos - point).Magnitude - math.max(standoff, needs[i] or 0)
				if m < worst then worst = m end
			end
			return worst
		end

		local here = Vector3.new(root.Position.X, centre.Y, root.Position.Z)
		if margin(here) >= -standoff * (1 - STANDOFF_SLACK) and not inAnyHazard(here) then
			return here
		end

		local reach = standoff
		for _, need in needs do reach = math.max(reach, need) end

		local best, bestScore = nil, -math.huge
		for _, extra in { 0, 8, 16 } do
			for i = 0, STANDOFF_ANGLES - 1 do
				local angle = i / STANDOFF_ANGLES * math.pi * 2
				local point = centre + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (reach + FARM_CLUSTER_RADIUS * 0.5 + extra)
				if not inAnyHazard(point) then
					local clear = math.min(margin(point), standoff * 0.5)
					local score = clear - (point - here).Magnitude * 0.05
					if score > bestScore then best, bestScore = point, score end
				end
			end
		end
		return best or here
	end

	-- Runs before every physics step while hovering. Deliberately NOT anchoring: an anchored root part
	-- belongs to the server, so the server would never see the character move.
	local function startHold()
		if holdConnection then return end
		holdConnection = ctx:Connect(RunService.Stepped, function(_, dt)
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not (root and airborne) or promptBusy then return end
			-- noclip: the character is held in the air (no gravity), so nothing is lost by passing
			-- through monkeys, props and walls. Not applied on the floor or during a pickup, where
			-- having no collision would drop the character through the ground.
			for _, part in char:GetDescendants() do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			local position = root.Position
			if farmGoal then
				local delta = farmGoal - position
				if delta.Magnitude > 0.25 then
					position = position + delta.Unit * math.min(delta.Magnitude, FARM_SPEED * dt)
				end
			end
			if farmFace and (Vector3.new(farmFace.X, position.Y, farmFace.Z) - position).Magnitude > 0.5 then
				root.CFrame = CFrame.lookAt(position, Vector3.new(farmFace.X, position.Y, farmFace.Z))
			elseif position ~= root.Position then
				root.CFrame = CFrame.new(position) * root.CFrame.Rotation
			end
		end)
	end

	-- Put the character back on solid ground and hand physics back to the humanoid.
	local function surface(root, hum, char)
		airborne = false
		farmGoal = nil
		farmFace = nil
		root.Anchored = false
		local hit = floorAt(root.Position, char)
		local target = hit and (hit.Position + Vector3.new(0, 4, 0)) or (lastSafeCFrame and lastSafeCFrame.Position)
		if target then
			root.CFrame = CFrame.new(target) * root.CFrame.Rotation
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CanCollide = true
		for _, name in { "Head", "Torso", "UpperTorso", "LowerTorso" } do
			local part = char:FindFirstChild(name)
			if part and part:IsA("BasePart") then part.CanCollide = true end
		end
		hum.PlatformStand = false
	end

	-- Hover at the stand-off point beside the nearest group, or come down when there is none.
	local function hoverAbove()
		local char, root, hum = characterParts()
		if not (root and hum and hum.Health > 0) then return end

		local floor = floorAt(root.Position, char)

		-- rescue: close to the void, or hovering over nothing
		local voidLine = Workspace.FallenPartsDestroyHeight + VOID_MARGIN
		if root.Position.Y < voidLine or (airborne and not floor) then
			debugLog("Movement", "void protection: rescued the character", "warn")
			surface(root, hum, char)
			return
		end

		if not airborne and floor and root.Position.Y - floor.Position.Y < 8 then
			lastSafeCFrame = root.CFrame
		end

		local centre, positions, needs = farmCentre(root.Position)
		if not centre then
			-- nothing to attack: do not stay (or sink) in the air
			if airborne or hum.PlatformStand then surface(root, hum, char) end
			return
		end

		refreshHazards()
		local goal = standoffPoint(root, centre, positions, needs) + Vector3.new(0, hoverHeight, 0)
		farmGoal = goal
		airborne = true
		startHold()
		hum.PlatformStand = true

		-- Out of reach: no monkey within the weapon's range, or the hover point is further than is worth
		-- flying to. Go straight there instead of crossing the map at FARM_SPEED.
		local outOfReach = weaponRange and nearestDistance(root.Position, positions) > weaponRange
		local tooFar = (goal - root.Position).Magnitude > FLY_LIMIT
		if (outOfReach or tooFar) and not promptBusy and os.clock() - lastJump >= JUMP_COOLDOWN then
			lastJump = os.clock()
			local distance = (goal - root.Position).Magnitude
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = CFrame.new(goal) * root.CFrame.Rotation
			debugLog("Movement", ("farm: monkeys out of reach, teleported %.0f studs to %s"):format(distance, tostring(goal)))
		end
	end

	function autoFarm()
		farmFace = attackMonkeys() -- the aim point, or nil when nothing is in reach
		hoverAbove()
	end

	-- Forget the current hover point (used after the character is teleported elsewhere).
	function resetFarmGoal()
		farmGoal = nil
	end

	-- a respawned character starts on the floor, whatever state the old one was in
	ctx:Connect(LocalPlayer.CharacterAdded, function() airborne = false end)

	-- Toggled off: back onto the floor.
	function stopFarm()
		if holdConnection then
			holdConnection:Disconnect()
			holdConnection = nil
		end
		local char, root, hum = characterParts()
		if root and hum then surface(root, hum, char) end
	end
end

do
	-- Damage log ------------------------------------------------------------------------
	-- Writes one line to the Debug tab whenever the character loses health: how much, how high above
	-- the nearest monkeys it was, the ground distance to them, which kinds are close, and which
	-- hazards it was standing in. Use it to see what is actually hurting the character.
	local DAMAGE_LOG_COOLDOWN = 0.4 -- seconds between lines, so a burst of ticks is one line
	local DAMAGE_NEARBY_RADIUS = 40 -- studs within which monkeys are listed
	local lastDamageLog = 0
	local DAMAGE_TELEPORT_COOLDOWN = 1.5 -- seconds between damage-triggered teleports
	local lastDamageTeleport = 0

	local function className(class)
		local row = EnemyCatalog and class and EnemyCatalog.Ordered[class]
		return row and row.Name or "unknown"
	end

	local function describeSurroundings(root)
		local now = os.clock()
		local nearest, nearestGround, nearestHeight = nil, math.huge, 0
		local counts = {}
		for id, unit in units do
			if now - unit.Seen <= UNIT_TTL then
				local offset = unit.Pos - root.Position
				local ground = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if ground < nearestGround then
					nearest, nearestGround, nearestHeight = id, ground, -offset.Y
				end
				if ground <= DAMAGE_NEARBY_RADIUS then
					local name = className(classOf[id])
					counts[name] = (counts[name] or 0) + 1
				end
			end
		end

		local nearby = {}
		for name, count in counts do table.insert(nearby, ("%s x%d"):format(name, count)) end
		table.sort(nearby)

		local inside = {}
		for _, hazard in hazards do
			if inHazard(hazard, root.Position) then table.insert(inside, hazard.Kind) end
		end

		return ("nearest %s: %.1f studs along the ground, %.1f above | nearby: %s | in hazards: %s"):format(
			nearest and className(classOf[nearest]) or "none",
			nearest and nearestGround or 0, nearestHeight,
			#nearby > 0 and table.concat(nearby, ", ") or "none",
			#inside > 0 and table.concat(inside, ", ") or "none")
	end

	local function watchDamage(char)
		local hum = char:WaitForChild("Humanoid", 5)
		if not hum then return end
		local last = hum.Health
		ctx:Connect(hum.HealthChanged, function(health)
			local lost = last - health
			last = health
			local root = char:FindFirstChild("HumanoidRootPart")

			-- hurt while farming: get out of reach now instead of waiting for the next stand-off step
			if lost > 0.5 and root and State.AutoFarm and not promptBusy
				and os.clock() - lastDamageTeleport >= DAMAGE_TELEPORT_COOLDOWN then
				lastDamageTeleport = os.clock()
				refreshHazards()
				if teleportToSafety(root, liveUnitPositions(), "hit") then
					resetFarmGoal() -- the next farm tick picks the hover point from the new spot
				end
			end

			if lost > 0.5 and root and os.clock() - lastDamageLog > DAMAGE_LOG_COOLDOWN then
				lastDamageLog = os.clock()
				debugLog("Damage", ("took %.0f damage (%.0f left, farming: %s) | %s"):format(
					lost, health, tostring(State.AutoFarm), describeSurroundings(root)),
					"warn")
			end
		end)
	end

	if LocalPlayer.Character then task.spawn(watchDamage, LocalPlayer.Character) end
	ctx:Connect(LocalPlayer.CharacterAdded, watchDamage)
end

do
	-- Auto abilities --------------------------------------------------------------------
	-- Ability state is exposed as player attributes (Ability1Id/Ability2Id/UltimateId, <name>ReadyAt in
	-- server time, UltimateCharge 0..1). No dump shows how an ability is *activated*, so this presses
	-- the ability's key through VirtualInputManager like a player would. The keys below are read off
	-- the on-screen ability cards (Grenade G, Barricade X, Ultimate Q) - check them against your
	-- own bindings. Before each press the aim point is set to the middle of the nearest group of
	-- monkeys, so thrown/placed abilities land on them (see the UnitRay hook above).
	local VirtualInputManager = game:GetService("VirtualInputManager")

	local ABILITIES = {
		{ Name = "Ability1", Group = "Abilities", Key = Enum.KeyCode.G, ReadyAt = "Ability1ReadyAt" },
		{ Name = "Ability2", Group = "Abilities", Key = Enum.KeyCode.X, ReadyAt = "Ability2ReadyAt" },
		{ Name = "Ultimate", Group = "Ultimate", Key = Enum.KeyCode.Q, ReadyAt = "UltimateReadyAt", Charge = "UltimateCharge" },
	}
	local ABILITY_RANGE = 60 -- studs: only use abilities when monkeys are this close
	local ABILITY_MIN_TARGETS = 3 -- ...and at least this many of them (Ability 1 and 2)
	local ULTIMATE_MIN_TARGETS = 3 -- same, for the Ultimate
	local ABILITY_RETRY = 1.5 -- seconds before the same ability is pressed again
	local lastAbilityPress = {}

	local function monkeyCluster(from, minTargets)
		local now, near = os.clock(), {}
		for id, unit in units do
			local class = classOf[id]
			local friendly = class and UnitProtocol and UnitProtocol.ClassFriendly[class]
			if now - unit.Seen <= UNIT_TTL and unit.State ~= STATE_DOWN and not unit.Frozen and not friendly
				and (unit.Pos - from).Magnitude <= ABILITY_RANGE then
				table.insert(near, unit.Pos)
			end
		end
		if #near < minTargets then return nil end
		local sum = Vector3.zero
		for _, pos in near do sum = sum + pos end
		return sum / #near
	end

	local function pressKey(keyCode)
		VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
		task.wait(0.05)
		VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
	end

	-- Uses the ready abilities of one group (see ABILITIES) when enough monkeys are close.
	local function useGroup(group, minTargets)
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum and hum.Health > 0) or LocalPlayer:GetAttribute("Dead") then return end

		local centre = monkeyCluster(root.Position, minTargets)
		if not centre then return end

		local now = Workspace:GetServerTimeNow()
		for _, ability in ABILITIES do
			if ability.Group == group then
				local readyAt = LocalPlayer:GetAttribute(ability.ReadyAt)
				local charged = not ability.Charge or (LocalPlayer:GetAttribute(ability.Charge) or 0) >= 1
				if type(readyAt) == "number" and readyAt <= now and charged
					and os.clock() - (lastAbilityPress[ability.Name] or 0) >= ABILITY_RETRY then
					lastAbilityPress[ability.Name] = os.clock()
					aimPoint, aimSetAt, aimUnitId = centre + Vector3.new(0, AIM_HEIGHT, 0), os.clock(), nil
					pressKey(ability.Key)
					local id = LocalPlayer:GetAttribute(ability.Name .. "Id")
					debugLog("Actions", ("used %s%s"):format(ability.Name, id and (" (" .. tostring(id) .. ")") or ""))
				end
			end
		end
	end

	function useAbilities() useGroup("Abilities", ABILITY_MIN_TARGETS) end
	function useUltimate() useGroup("Ultimate", ULTIMATE_MIN_TARGETS) end
end

do
	-- Monkey highlight ------------------------------------------------------------------
	-- Tints the real monkey models (Workspace.UnitViews) through walls. Roblox draws at most ~31
	-- highlights at once, so only the nearest few inside the range are tinted. Monkeys further away
	-- than the range have their highlight removed.
	local HIGHLIGHT_MAX = 30
	local HIGHLIGHT_REFRESH = 0.5 -- seconds between passes

	local highlightSettings = {
		Enabled = false,
		Range = 300,
	}

	local VisualsTab = ctx:SubTab("Visuals", "Lucide:eye")

	VisualsTab:AddSection("Highlights", "Lucide:highlighter")
	VisualsTab:AddToggle({ Text = "Highlight Monkeys", Description = "Tints the nearest monkey models",
		Default = false, Callback = function(v) highlightSettings.Enabled = v end })
	VisualsTab:AddSlider({ Text = "Highlight Range", Suffix = " studs", Description = "Monkeys further than this are not highlighted",
		Min = 50, Max = 1000, Increment = 10, Default = highlightSettings.Range,
		Callback = function(v) highlightSettings.Range = v end })

	-- RunService:Set3dRenderingEnabled(false) stops the 3D world being drawn (the screen goes blank apart
	-- from this UI) while the game keeps running, so farming carries on and the GPU does far less. It is
	-- a setting of the game client, not of this script: if the script is closed or re-run with rendering
	-- off, turn it back on here (or rejoin) to see the world again.
	VisualsTab:AddSection("Performance", "Lucide:gauge")
	VisualsTab:AddToggle({
		Text = "Disable 3D Rendering",
		Description = "Stops drawing the 3D world to save GPU and CPU while the game keeps running",
		Default = false,
		Callback = function(disabled)
			local ok, err = pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(not disabled) end)
			if ok then
				debugLog("Actions", "3D rendering " .. (disabled and "disabled" or "enabled"))
			else
				log("could not change 3D rendering: " .. tostring(err), "error")
			end
		end,
	})

	ctx:OnCleanup(function() pcall(function() game:GetService("RunService"):Set3dRenderingEnabled(true) end) end)
	task.spawn(function()
		while ctx:Alive() do
			task.wait(HIGHLIGHT_REFRESH)
			local folder = Workspace:FindFirstChild("UnitViews")
			if folder then
				local char = LocalPlayer.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				local origin = root and root.Position or Workspace.CurrentCamera.CFrame.Position

				-- nearest first, so the highlight limit is spent on the closest monkeys
				local candidates = {}
				for _, model in folder:GetChildren() do
					if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then
						table.insert(candidates, { Model = model, Distance = (model:GetPivot().Position - origin).Magnitude })
					end
				end
				table.sort(candidates, function(a, b) return a.Distance < b.Distance end)

				local count = 0
				for _, candidate in candidates do
					local model = candidate.Model
					local existing = model:FindFirstChild("MM_ESP")
					if highlightSettings.Enabled and candidate.Distance <= highlightSettings.Range and count < HIGHLIGHT_MAX then
						count = count + 1
						if not existing then
							local highlight = Instance.new("Highlight")
							highlight.Name = "MM_ESP"
							highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
							highlight.FillColor = Color3.fromRGB(255, 60, 60)
							highlight.FillTransparency = 0.55
							highlight.OutlineColor = Color3.new(1, 1, 1)
							highlight.Parent = model
							ctx:Track(highlight)
						end
					elseif existing then
						existing:Destroy()
					end
				end
			end
		end
	end)

	-- Chest and collectable ESP ---------------------------------------------------------
	-- Chests are the models in Workspace.Chests (price in their "Price" attribute; opened ones are
	-- listed in the player's "OpenedChests" attribute). Collectables are the loot models in
	-- Workspace.FloorItems (the item in their "Item" attribute). Each gets a highlight that shows
	-- through walls plus a floating label with its name, price (chests) and distance. There are few of
	-- them, so the label is a BillboardGui on the model itself rather than anything drawn by the
	-- executor.
	local ITEM_REFRESH = 0.25 -- seconds between passes

	local itemSettings = {
		Chests = false,
		Collectables = false,
		Range = 400,
	}

	VisualsTab:AddSection("Chests and Collectables", "Lucide:package")
	VisualsTab:AddToggle({ Text = "Chest ESP", Description = "Highlights chests, with price and distance",
		Default = false, Callback = function(v) itemSettings.Chests = v end })
	VisualsTab:AddToggle({ Text = "Collectable ESP", Description = "Highlights dropped items, with distance",
		Default = false, Callback = function(v) itemSettings.Collectables = v end })
	VisualsTab:AddSlider({ Text = "Item ESP Range", Suffix = " studs", Description = "Items further than this are not shown",
		Min = 50, Max = 1000, Increment = 10, Default = itemSettings.Range,
		Callback = function(v) itemSettings.Range = v end })

	local CHEST_COLOUR = Color3.fromRGB(255, 200, 40)
	local COLLECTABLE_COLOUR = Color3.fromRGB(80, 220, 255)

	local function anchorPart(model)
		if model.PrimaryPart then return model.PrimaryPart end
		return model:FindFirstChildWhichIsA("BasePart", true)
	end

	local function removeItemEsp(model)
		local highlight = model:FindFirstChild("MM_ITEM_ESP")
		if highlight then highlight:Destroy() end
		local part = anchorPart(model)
		local label = part and part:FindFirstChild("MM_ITEM_LABEL")
		if label then label:Destroy() end
	end

	local function showItemEsp(model, colour, text)
		local part = anchorPart(model)
		if not part then return end

		if not model:FindFirstChild("MM_ITEM_ESP") then
			local highlight = Instance.new("Highlight")
			highlight.Name = "MM_ITEM_ESP"
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.FillColor, highlight.OutlineColor = colour, Color3.new(1, 1, 1)
			highlight.FillTransparency = 0.5
			highlight.Adornee, highlight.Parent = model, model
			ctx:Track(highlight)
		end

		local gui = part:FindFirstChild("MM_ITEM_LABEL")
		if not gui then
			gui = Instance.new("BillboardGui")
			gui.Name = "MM_ITEM_LABEL"
			gui.AlwaysOnTop, gui.Size = true, UDim2.fromOffset(200, 22)
			gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
			gui.Adornee, gui.Parent = part, part
			ctx:Track(gui)
			local label = Instance.new("TextLabel")
			label.Name = "Text"
			label.BackgroundTransparency, label.Size = 1, UDim2.fromScale(1, 1)
			label.Font, label.TextSize, label.TextStrokeTransparency = Enum.Font.GothamBold, 14, 0
			label.Parent = gui
		end
		gui.Text.Text, gui.Text.TextColor3 = text, colour
	end

	-- one pass over a folder of models; `describe` returns the label text, or nil to hide the model
	local function updateItems(folder, enabled, colour, origin, describe)
		if not folder then return end
		for _, model in folder:GetChildren() do
			if model:IsA("Model") then
				local part = anchorPart(model)
				local distance = part and (part.Position - origin).Magnitude
				local text = enabled and distance and distance <= itemSettings.Range and describe(model, distance)
				if text then
					showItemEsp(model, colour, text)
				else
					removeItemEsp(model)
				end
			end
		end
	end

	task.spawn(function()
		while ctx:Alive() do
			task.wait(ITEM_REFRESH)
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local origin = root and root.Position or Workspace.CurrentCamera.CFrame.Position

			local opened = {}
			for _, name in string.split(LocalPlayer:GetAttribute("OpenedChests") or "", ",") do
				opened[name] = true
			end

			updateItems(Workspace:FindFirstChild("Chests"), itemSettings.Chests, CHEST_COLOUR, origin,
				function(chest, distance)
					if opened[chest.Name] then return nil end -- already opened
					local price = chest:GetAttribute("Price")
					return ("%s%s  %dm"):format(chest.Name, type(price) == "number" and (" $" .. price) or "", math.floor(distance))
				end)

			updateItems(Workspace:FindFirstChild("FloorItems"), itemSettings.Collectables, COLLECTABLE_COLOUR, origin,
				function(item, distance)
					return ("%s  %dm"):format(tostring(item:GetAttribute("Item") or item.Name), math.floor(distance))
				end)
		end
	end)
end

do
	-- Auto skip shop ----------------------------------------------------------------
	-- Between waves the shop can be skipped by voting: Shared.Waves.Vote:FireServer("Skip") (captured with
	-- Cobalt). The shop is open when ANY of these says so:
	--   * Shared.Waves has CanSkip = true
	--   * Shared.Waves has Shop = true
	--   * the vendor is standing in the world: a model named "Vendor" in Workspace that has landed
	--     (ArrivedAt + Landed has passed) and is not Leaving - this is how VendorController decides the
	--     shop is up. An earlier version trusted CanSkip alone and never voted while it read false.
	-- If none of those attributes exist at all, it falls back to voting after a quiet spell with no hostile
	-- monkeys. Each vote is written to the Debug tab (Actions) with the values that triggered it, at most every
	-- VOTE_REPORT_EVERY seconds, so a shop that is still not skipped can be diagnosed.
	SKIP_EVERY = 1 -- seconds between checks
	local QUIET_BEFORE_SKIP = 2 -- seconds without any hostile monkey before voting (fallback only)
	local VOTE_REPORT_EVERY = 5 -- seconds between vote reports in the Debug tab
	local lastHostileSeen = os.clock()
	local lastVoteReport = 0

	-- true when the vendor is standing in the world and can be bought from
	local function vendorOpen()
		local vendor = Workspace:FindFirstChild("Vendor")
		if not (vendor and vendor:IsA("Model")) or vendor:GetAttribute("Leaving") then return false end
		local landedAt = (vendor:GetAttribute("ArrivedAt") or 0) + (vendor:GetAttribute("Landed") or 0)
		return Workspace:GetServerTimeNow() >= landedAt
	end

	function skipShop()
		local waves = ReplicatedStorage.Shared:FindFirstChild("Waves")
		local vote = waves and waves:FindFirstChild("Vote")
		if not vote then return end

		local canSkip, shop = waves:GetAttribute("CanSkip"), waves:GetAttribute("Shop")
		local vendor = vendorOpen()

		local reasons = {}
		if canSkip == true then table.insert(reasons, "CanSkip") end
		if shop == true then table.insert(reasons, "Shop") end
		if vendor then table.insert(reasons, "vendor open") end

		if #reasons == 0 and canSkip == nil and shop == nil then
			-- no shop attributes at all: wait for a quiet spell with no hostile monkeys
			local now = os.clock()
			for id, unit in units do
				if now - unit.Seen <= UNIT_TTL and not isFriendlyUnit(id) then lastHostileSeen = now break end
			end
			if now - lastHostileSeen >= QUIET_BEFORE_SKIP then table.insert(reasons, "quiet spell") end
		end

		if #reasons == 0 then return end

		vote:FireServer("Skip")

		if os.clock() - lastVoteReport >= VOTE_REPORT_EVERY then
			lastVoteReport = os.clock()
			debugLog("Actions", ("skip shop: voted (%s) | CanSkip=%s Shop=%s Phase=%s Votes=%s/%s"):format(
				table.concat(reasons, ", "), tostring(canSkip), tostring(shop), tostring(waves:GetAttribute("Phase")),
				tostring(waves:GetAttribute("Votes")), tostring(waves:GetAttribute("MaxVotes"))))
		end
	end
end

do
	-- Auto sell duplicate contraband -----------------------------------------------------
	-- Contraband counts live on the player as attributes, read through Shared.Runtime.Contraband
	-- (Contraband.All lists every item, Contraband.count(player, id) says how many are held). A duplicate
	-- is every copy beyond the first. The call that actually sells is not captured yet - none of the
	-- remotes seen so far is named for it - so for now this only works out and reports what it would sell
	-- (Debug tab, Actions). Wire sellContraband below once the Cobalt call for selling is known.
	-- (declared above) sellDuplicates
	do
		local Contraband = safeRequire("Shared.Runtime.Contraband")
		local lastReport = ""
		local warned = false

		local function sellContraband(id, amount)
			-- TODO: fire the sell remote with (id, amount) once its call has been captured
			return false
		end

		sellDuplicates = function()
			if not (Contraband and type(Contraband.All) == "table") then return end
			local report = {}
			for _, item in Contraband.All do
				local ok, held = pcall(Contraband.count, LocalPlayer, item.Id)
				if ok and type(held) == "number" and held > 1 then
					local extra = held - 1
					local name = item.Display and item.Display.Name or item.Id
					table.insert(report, ("%s x%d"):format(tostring(name), extra))
					if sellContraband(item.Id, extra) then
						debugLog("Actions", ("sold %d duplicate %s"):format(extra, tostring(name)))
					end
				end
			end
			table.sort(report)
			local text = table.concat(report, ", ")
			if text ~= lastReport then
				lastReport = text
				debugLog("Actions", "duplicate contraband: " .. (text ~= "" and text or "none"))
			end
			if #report > 0 and not warned then
				warned = true
				debugLog("Actions", "auto sell: the sell call is not wired yet, nothing was sold", "warn")
			end
		end
	end
end

-- Loop runner -----------------------------------------------------------------
local function startLoop(stateKey, action, interval)
	task.spawn(function()
		while State[stateKey] do
			local ok, err = pcall(action)
			if not ok then
				log(("%s error: %s"):format(stateKey, tostring(err)), "error")
			end
			task.wait(interval)
		end
	end)
end

local function bindToggle(tab, text, description, stateKey, action, interval, onDisable)
	tab:AddToggle({
		Text = text,
		Description = description,
		Default = false,
		Callback = function(enabled)
			State[stateKey] = enabled
			debugLog("Actions", text .. (enabled and " enabled" or " disabled"))
			if enabled then
				startLoop(stateKey, action, interval)
			elseif onDisable then
				task.delay(interval * 2, onDisable) -- let the running loop finish its last tick first
			end
		end,
	})
end

-- Toggles ---------------------------------------------------------------------
Main:AddSection("Combat", "Lucide:swords")
bindToggle(Main, "Auto Farm", "Auto kills monkeys while hovering above them, buying upgrades and collecting drops", "AutoFarm", autoFarm, FARM_TICK, stopFarm)
ctx:OnCleanup(function() pcall(stopFarm) end) -- the toggle's delayed stop is cancelled at shutdown
Main:AddToggle({
	Text = "Target Crowds",
	Description = "Aims at the thickest group of monkeys instead of the nearest one",
	Default = crowdTargeting,
	Callback = function(enabled) crowdTargeting = enabled end,
})
bindToggle(Main, "Auto Attack Monkeys", "Automatically attacks monkeys", "AutoAttackMonkeys", attackMonkeys, 0.1)
Main:AddSlider({
	Text = "Hover Height",
	Suffix = " studs",
	Description = "How far above the floor Auto Farm stays",
	Min = 8,
	Max = 60,
	Increment = 1,
	Default = hoverHeight,
	Callback = function(value) hoverHeight = value end,
})

Main:AddSection("Abilities", "Lucide:zap")
bindToggle(Main, "Auto Abilities", "Uses Ability 1 and Ability 2 when monkeys are close", "AutoAbilities", useAbilities, 0.25)
bindToggle(Main, "Auto Ultimate", "Uses the Ultimate when it is charged and monkeys are close", "AutoUltimate", useUltimate, 0.25)

Main:AddSection("Progression", "Lucide:trending-up")
bindToggle(Main, "Auto Upgrade Health", "Buys the health upgrade whenever you can afford it", "AutoUpgradeHealth", upgradeHealth, 0.5)
bindToggle(Main, "Auto Upgrade Weapon", "Buys the weapon upgrade whenever you can afford it", "AutoUpgradeWeapon", upgradeWeapon, 0.5)

Main:AddSection("Waves", "Lucide:waves")
bindToggle(Main, "Auto Skip Shop", "Votes to skip the shop when it is open (or between waves)", "AutoSkipShop", skipShop, SKIP_EVERY)

Main:AddSection("Collection", "Lucide:coins")
bindToggle(Main, "Auto Chest Collection", "Automatically collects chests", "AutoChestCollection", collectChests, 1)
bindToggle(Main, "Auto Sell Duplicate Contraband", "Sells every copy beyond the first of each contraband", "AutoSellDuplicates", sellDuplicates, 2)
bindToggle(Main, "Auto Merchant Buying", "Automatically buys from the merchant", "AutoMerchantBuying", buyFromMerchant, 1)

Main:AddSection("Survival", "Lucide:shield")
bindToggle(Main, "Auto Dodge Splash", "Steps out of acid pools, grenade blasts and spit cones", "AutoDodgeSplash", dodgeSplash, 0.1)
bindToggle(Main, "Safe Distance", "Walks away from monkeys that get too close, avoiding hazards", "SafeDistance", keepSafeDistance, 0.35)
Main:AddSlider({
	Text = "Safe Distance",
	Suffix = " studs",
	Description = "How far to stay from the nearest monkey",
	Min = 5,
	Max = 80,
	Increment = 1,
	Default = safeDistance,
	Callback = function(value) safeDistance = value end,
})
