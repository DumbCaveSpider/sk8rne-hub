-- Dash World
local ctx = ...
local task = ctx.task

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LevelFolder = ReplicatedStorage.Shared.Classes.Level
local Level = require(LevelFolder)
local Player = require(LevelFolder.Player)
local DartTrail = require(LevelFolder.Player.DartTrail)
local Camera = require(LevelFolder.Camera)
local Parser = require(LevelFolder.Parser)
local TriggerManager = require(LevelFolder.TriggerManager)
local TriggerInitializers = require(LevelFolder.TriggerManager.Trigger.TriggerInitializers)
local LevelScene = require(ReplicatedStorage.UserInterface.Scenes.LevelScene)
local Networker = require(ReplicatedStorage.Packages.Networker)
local Block = require(LevelFolder.Block)
local ColorChannel = require(LevelFolder.ColorChannel)
local Toolbox = require(ReplicatedStorage.Shared.Toolbox)
local Utility = require(ReplicatedStorage.Shared.Utility)

--------------------------------------------------------------------------------
-- Settings and state
--------------------------------------------------------------------------------

local DEFAULT_TPS = 240
local REPLAY_FOLDER = "DashWorld/replays"

local S = {
	-- Level
	noclip = false,
	jumpHack = false,
	autoClicker = false,
	autoClickerCps = 10,
	forcePlatformer = false,
	showHitboxes = false,
	hitboxesOnDeath = false,
	hitboxTrail = false,
	showTriggers = false,
	stopTriggersOnDeath = false,
	fastRespawn = false,
	respawnTime = 0.3,
	-- Cosmetic
	hidePlayer = false,
	noDeathEffect = false,
	noShake = false,
	noCameraZoom = false,
	noCameraRotate = false,
	noPulse = false,
	noShaders = false,
	noGhostTrail = false,
	noTrail = false,
	trailAlwaysOn = false,
	noWaveTrail = false,
	noWavePulse = false,
	noDashFire = false,
	noRobotSwingFire = false,
	-- Speedhack
	speedhack = false,
	speed = 1,
	speedhackAudio = true,
	-- Replay
	replayRecord = false,
	replayRecordMode = "Completed Runs",
	replayPlay = false,
	-- Cheat Safety
	safeMode = false,
	autoSafeMode = true,
	-- Display
	unlockFps = false,
	fpsCap = 240,
	tps = DEFAULT_TPS,
	-- Status
	statusEnabled = false,
	statusCorner = "Top Left",
	statusScale = 1,
	statusOpacity = 1,
	percentDecimals = 2,
	message = "",
}

local running = true
local installedHooks = {}
local pendingImport = nil

local liveLevels = setmetatable({}, { __mode = "k" })
local statsByLevel = setmetatable({}, { __mode = "k" })
local wrappedDeathLevels = setmetatable({}, { __mode = "k" })
local currentLevel = nil
local currentScene = nil
local clickTimes = {}
local sessionStart = os.clock()

local replay = { data = nil, info = "Nothing recorded" }

-- Notifications raised from hooks (game thread) are shown from this thread.
local notifyQueue = {}
local function queueNotify(text, kind)
	table.insert(notifyQueue, { text, kind })
end

local function isAlive(level)
	return type(level) == "table" and not level._isDestroyed and not level._isDestroying
end

-- The level of the open level scene wins; otherwise the last level that ran.
local function getLevel()
	local sceneLevel = currentScene and currentScene._levelInstance
	if isAlive(sceneLevel) then
		return sceneLevel
	end
	if isAlive(currentLevel) then
		return currentLevel
	end
	return nil
end

local function getScene()
	if currentScene and isAlive(currentScene._levelInstance) and not currentScene:isDestroyed() then
		return currentScene
	end
	return nil
end

local function getPlayer1(level)
	return level and level.Players and level.Players[1]
end

local function cheatsActive(level)
	return S.noclip or S.jumpHack or S.autoClicker or S.forcePlatformer
		or (S.speedhack and S.speed ~= 1) or S.tps ~= DEFAULT_TPS
		or S.showHitboxes or S.hitboxTrail
		or (level ~= nil and level.replayMacro ~= nil)
end

-- Per-level stats; everything except Best Run restarts with every attempt.
local function getStats(level)
	local stats = statsByLevel[level]
	if not stats then
		stats = { best = 0 }
		statsByLevel[level] = stats
	end
	if stats.attempts ~= level.attempts then
		stats.attempts = level.attempts
		stats.noclipDeaths = 0
		stats.hitTicks = 0
		stats.playTicks = 0
		stats.lastHitTick = nil
		stats.cheated = false
	end
	return stats
end

local function hook(target, key, makeReplacement)
	local original = target[key]
	if type(original) ~= "function" then
		warn("[DashWorldScript] cannot hook missing function " .. tostring(key))
		return nil
	end
	target[key] = makeReplacement(original)
	table.insert(installedHooks, { target = target, key = key, original = original })
	return original
end

--------------------------------------------------------------------------------
-- LevelScene local functions (restart, practice, checkpoints)
--
-- They are locals of the LevelScene module, reachable as upvalues of
-- LevelScene.onEvent (… pauseLevel, createCheckpoint, removeCheckpoint,
-- restartLevel) and of pauseLevel (… restartLevel, enablePractice,
-- disablePractice). Matched by debug name, falling back to upvalue order.
--------------------------------------------------------------------------------

local getUpvalues = (debug and debug.getupvalues) or getupvalues

local function functionName(fn)
	local ok, name = pcall(debug.info, fn, "n")
	return ok and name or nil
end

local function findUpvalue(fn, name, fallbackIndex)
	if type(fn) ~= "function" or not getUpvalues then
		return nil
	end
	local ok, upvalues = pcall(getUpvalues, fn)
	if not ok or type(upvalues) ~= "table" then
		return nil
	end
	local anyNamed = false
	for _, value in upvalues do
		if type(value) == "function" then
			local valueName = functionName(value)
			if valueName and valueName ~= "" then
				anyNamed = true
				if valueName == name then
					return value
				end
			end
		end
	end
	local fallback = upvalues[fallbackIndex]
	if not anyNamed and type(fallback) == "function" then
		return fallback
	end
	return nil
end

local sceneFns = {}
do
	local pauseLevel = findUpvalue(LevelScene.onEvent, "pauseLevel", 5)
	sceneFns.createCheckpoint = findUpvalue(LevelScene.onEvent, "createCheckpoint", 6)
	sceneFns.removeCheckpoint = findUpvalue(LevelScene.onEvent, "removeCheckpoint", 7)
	sceneFns.restartLevel = findUpvalue(LevelScene.onEvent, "restartLevel", 8)
	sceneFns.enablePractice = findUpvalue(pauseLevel, "enablePractice", 4)
	sceneFns.disablePractice = findUpvalue(pauseLevel, "disablePractice", 5)
	for name, fn in sceneFns do
		if type(fn) ~= "function" then
			warn("[DashWorldScript] LevelScene." .. name .. " not found; related buttons are disabled")
		end
	end
end

--------------------------------------------------------------------------------
-- Per-level settings (applied when a level is first seen and on every toggle)
--------------------------------------------------------------------------------

local function applyShake(level)
	if S.noShake then
		if level.__dw_savedShake == nil then
			level.__dw_savedShake = { level.__shake_disabled, level.__explosion_shake_disabled }
		end
		-- __shake_disabled also stops Shake triggers (TriggerManager:_canCreate).
		level.__shake_disabled = true
		level.__explosion_shake_disabled = true
	elseif level.__dw_savedShake then
		level.__shake_disabled = level.__dw_savedShake[1]
		level.__explosion_shake_disabled = level.__dw_savedShake[2]
		level.__dw_savedShake = nil
	end
end

local function applyToLevel(level)
	if not isAlive(level) then
		return
	end
	local ok, err = pcall(function()
		if level.showHitboxes ~= S.showHitboxes then
			level:SetShowHitboxes(S.showHitboxes)
		end
		if level.showHitboxTrail ~= S.hitboxTrail then
			level:SetShowHitboxTrail(S.hitboxTrail)
		end

		if S.hitboxesOnDeath then
			level.showHitboxesOnDeath = true
		else
			local data = level.userData
			level.showHitboxesOnDeath = data and data.settings and data.settings.showHitboxesOnDeath or false
		end

		applyShake(level)
	end)
	if not ok then
		warn("[DashWorldScript] applying settings failed: " .. tostring(err))
	end
end

local function applyAll()
	for level in liveLevels do
		applyToLevel(level)
	end
end

-- Replay playback: Level:loadMacro() makes the level play the macro's inputs
-- and ignore the player's.
local function applyReplay(level)
	if not isAlive(level) or level.__is_editing then
		return
	end
	if S.replayPlay and replay.data then
		if level.replayMacro == nil then
			local ok, err = pcall(level.loadMacro, level, replay.data)
			if ok then
				level.__dw_replayLoaded = true
			else
				S.replayPlay = false
				queueNotify("Replay could not be loaded: " .. tostring(err), "error")
			end
		end
	elseif level.__dw_replayLoaded then
		level.__dw_replayLoaded = nil
		pcall(level.deleteMacro, level)
	end
end

local function saveMacro(level)
	local ok, data = pcall(function()
		return level.macro:saveMacro(true)
	end)
	if ok and type(data) == "string" and #data > 6 then
		return data
	end
	return nil
end

--------------------------------------------------------------------------------
-- Hooks: Player
--------------------------------------------------------------------------------

-- Noclip: Player.kill() is the only place that sets `died`; returning false
-- means "survived" to every caller (hazards, crushes, death barrier).
local originalKill = hook(Player, "kill", function(original)
	return function(self, ...)
		if S.noclip and not self:DoesIgnoreDamage() then
			local level = self.level_ptr
			if level and not self.isP2 then
				local stats = getStats(level)
				local tick = level.ticks
				if stats.lastHitTick ~= tick then
					stats.hitTicks += 1
					if stats.lastHitTick ~= tick - 1 then
						stats.noclipDeaths += 1
					end
					stats.lastHitTick = tick
				end
			end
			self.died = false
			return false
		end
		return original(self, ...)
	end
end)

-- Jump Hack: every gamemode's jump checks isGrounded() while jump is held.
hook(Player, "isGrounded", function(original)
	return function(self, ...)
		if S.jumpHack and self.isJumping then
			return true
		end
		return original(self, ...)
	end
end)

-- Ticks played this attempt (Noclip Accuracy) and whether any cheat was on.
hook(Player, "Tick", function(original)
	return function(self, ...)
		local level = self.level_ptr
		if level and not self.isP2 then
			local stats = getStats(level)
			stats.playTicks += 1
			if not stats.cheated and cheatsActive(level) then
				stats.cheated = true
			end
		end
		return original(self, ...)
	end
end)

-- Trails and fire: TickPlayerVisuals decides them every tick from these fields.
hook(Player, "TickPlayerVisuals", function(original)
	return function(self, ...)
		local savedAlways, savedPulse = self.trailAlwaysActive, self.dartTrailPulseEnabled
		if S.trailAlwaysOn then
			self.trailAlwaysActive = true
		end
		if S.noWavePulse then
			self.dartTrailPulseEnabled = false
		end

		local result = original(self, ...)
		self.trailAlwaysActive, self.dartTrailPulseEnabled = savedAlways, savedPulse

		pcall(function()
			if S.noTrail then
				self.object_ptr.Trails.Trail.Enabled = false
				self.object_ptr.Trails.ShipTrail.Enabled = false
			end

			if S.noWavePulse and self.dartTrail then
				if not self.__dw_pulseReset then
					self.dartTrail:setOuterWidth(0.25)
					self.__dw_pulseReset = true
				end
			else
				self.__dw_pulseReset = nil
			end

			local particles = self.level_ptr.ParticleManager.particles
			if S.noDashFire then
				for _, id in self.dash_particles do
					local particle = particles[id]
					if particle then
						particle.opacity = 0
					end
				end
			end
			if S.noRobotSwingFire and (self.gamemode == 6 or self.gamemode == 8) then
				for _, id in self.fire_particles do
					local particle = particles[id]
					if particle then
						particle.opacity = 0
					end
				end
			end
		end)

		return result
	end
end)

hook(DartTrail, "updatePosition", function(original)
	return function(self, ...)
		if S.noWaveTrail then
			return self
		end
		return original(self, ...)
	end
end)

--------------------------------------------------------------------------------
-- Hooks: Level
--------------------------------------------------------------------------------

-- RunStep runs every Heartbeat for each active level: capture it, apply
-- Physics TPS, and scale the frame delta for the speedhack.
hook(Level, "RunStep", function(original)
	return function(self, dt, ...)
		if not liveLevels[self] then
			liveLevels[self] = true
			applyToLevel(self)
		end
		currentLevel = self
		self.tick_rate = 1 / S.tps

		-- dt > 0.1 is a stall the game handles itself, so pass it through.
		if not S.speedhack or S.speed == 1 or type(dt) ~= "number" or dt > 0.1 then
			return original(self, dt, ...)
		end

		local remaining = dt * S.speed
		while remaining > 0 do
			local step = math.min(remaining, 0.09)
			original(self, step, ...)
			remaining -= step
			if not isAlive(self) then
				break
			end
		end
	end
end)

-- The scene sets the player's shake settings after creating the level.
hook(Level, "SetExternalSettings", function(original)
	return function(self, ...)
		original(self, ...)
		self.__dw_savedShake = nil
		applyShake(self)
	end
end)

-- Show Triggers: the level hides trigger sprites while it builds objects.
hook(Level, "buildFromObjectData", function(original)
	return function(self, ...)
		if S.showTriggers then
			self.hideTriggers = false
		end
		return original(self, ...)
	end
end)

hook(Level, "isPlatformer", function(original)
	return function(self, ...)
		if S.forcePlatformer and not self.__is_editing then
			return true
		end
		return original(self, ...)
	end
end)

hook(Level, "PlayExplosionEffect", function(original)
	return function(self, ...)
		if not S.noDeathEffect then
			return original(self, ...)
		end
		for _, player in self.Players do
			pcall(function()
				player.object_ptr.SurfaceGui.Enabled = false
				for _, list in { player.fire_particles, player.dash_particles } do
					for _, particle in list do
						self.ParticleManager:RemoveParticle(particle)
					end
					table.clear(list)
				end
			end)
		end
	end
end)

-- CPS counter: every jump input (keyboard, mouse, touch, auto clicker).
hook(Level, "Jump", function(original)
	return function(self, ...)
		table.insert(clickTimes, os.clock())
		return original(self, ...)
	end
end)

-- Replay recording: Reset() clears level.macro, so grab it first.
hook(Level, "Reset", function(original)
	return function(self, ...)
		if S.replayRecord and S.replayRecordMode == "Every Attempt"
			and self.replayMacro == nil and not self.__is_editing then
			local data = saveMacro(self)
			if data then
				replay.data = data
				replay.info = string.format("Attempt %d (%.2f%%)", self.attempts or 0, (self.percentage or 0) * 100)
			end
		end
		return original(self, ...)
	end
end)

hook(Level, "Complete", function(original)
	return function(self, ...)
		local result = original(self, ...)
		if S.replayRecord and self.completed and self.replayMacro == nil and not self.__is_editing then
			local data = saveMacro(self)
			if data then
				replay.data = data
				replay.info = string.format("Completed run, attempt %d", self.attempts or 0)
				queueNotify("Replay recorded: completed run")
			end
		end
		return result
	end
end)

--------------------------------------------------------------------------------
-- Hooks: triggers
--------------------------------------------------------------------------------

hook(TriggerManager, "Tick", function(original)
	return function(self, ...)
		local level = self.level_ptr
		if S.stopTriggersOnDeath and level and level.dead then
			return
		end
		return original(self, ...)
	end
end)

-- Disabling a trigger type: stop it in its initializer, before it changes
-- anything. Trigger:Run() then skips it because it is already completed.
local DISABLED_TRIGGERS = {
	noCameraZoom = { "CameraZoomTrigger" },
	noCameraRotate = { "CameraRotateTrigger" },
	noPulse = { "PulseTrigger", "PulseTrigger2" },
	noShaders = {
		"SaturationShaderTrigger", "ContrastShaderTrigger", "BrightnessShaderTrigger",
		"TintShaderTrigger", "BloomShaderTrigger", "BlurShaderTrigger",
	},
}

for setting, triggerNames in DISABLED_TRIGGERS do
	for _, name in triggerNames do
		if TriggerInitializers[name] then
			hook(TriggerInitializers, name, function(original)
				return function(trigger, ...)
					if S[setting] then
						trigger:Stop()
						return
					end
					return original(trigger, ...)
				end
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Hooks: scene and server
--------------------------------------------------------------------------------

-- Respawn Time: LevelScene's died() waits 0.5-1 s before restartLevel(); we
-- restart earlier. died() sets scene._triggeredDeathEvent before waiting and
-- restartLevel() clears it, so whichever runs second does nothing.
local function wrapOnDied(scene, level)
	local original = level.onDied
	if wrappedDeathLevels[level] or type(original) ~= "function" then
		return
	end
	wrappedDeathLevels[level] = original

	level.onDied = function(diedLevel, playerIndex, ...)
		task.spawn(original, diedLevel, playerIndex, ...)
		if not S.fastRespawn or not sceneFns.restartLevel then
			return
		end
		local token = scene._triggeredDeathEvent
		task.wait(S.respawnTime)
		while scene._levelInstance == diedLevel and diedLevel:IsPaused() do
			task.wait()
		end
		if running and token ~= nil and scene._triggeredDeathEvent == token
			and scene._levelInstance == diedLevel and diedLevel.dead then
			sceneFns.restartLevel(scene)
		end
	end
end

hook(LevelScene, "update", function(original)
	return function(self, ...)
		local level = self._levelInstance
		if level then
			currentScene = self
			wrapOnDied(self, level)
			applyReplay(level)
		end
		return original(self, ...)
	end
end)

local function attemptCheated()
	local level = getLevel()
	local stats = level and statsByLevel[level]
	return (stats ~= nil and stats.cheated) or cheatsActive(level)
end

-- Cheat Safety: LevelScene sends every death / completion as "LevelAttempt".
hook(Networker, "InvokeServer", function(original)
	return function(self, name, ...)
		if name == "LevelAttempt" and (S.safeMode or (S.autoSafeMode and attemptCheated())) then
			queueNotify("Safe Mode: attempt was not sent to the server")
			return { ok = false, body = {} }
		end
		return original(self, name, ...)
	end
end)

--------------------------------------------------------------------------------
-- Per-frame effects and auto clicker (this script's thread)
--------------------------------------------------------------------------------

local playerHiddenByUs = false
local audioChangedLevels = setmetatable({}, { __mode = "k" })

ctx:Connect(RunService.RenderStepped, function()
	for level in liveLevels do
		if isAlive(level) then
			for _, player in level.Players or {} do
				if S.noGhostTrail then
					player.ghostTrailEnabled = false
				end
				local gui = player.object_ptr and player.object_ptr:FindFirstChild("SurfaceGui")
				if gui then
					if S.hidePlayer then
						gui.Enabled = false
					elseif playerHiddenByUs and not player.isHidden and not level.dead then
						gui.Enabled = true
					end
				end
			end

			-- soundInstance is a Soundkit Sound wrapper, recreated every attempt;
			-- setPlaybackSpeed also covers its Sound instance, created on play.
			local sound = level.soundInstance
			if sound then
				if S.speedhack and S.speedhackAudio then
					if sound:getPlaybackSpeed() ~= S.speed then
						sound:setPlaybackSpeed(S.speed)
					end
					audioChangedLevels[level] = true
				elseif audioChangedLevels[level] then
					sound:setPlaybackSpeed(1)
					audioChangedLevels[level] = nil
				end
			end
		end
	end
	playerHiddenByUs = S.hidePlayer
end)

task.spawn(function()
	while running do
		local level = getLevel()
		if S.autoClicker and level and not level.paused and not level.dead
			and not level.completed and not level.__is_editing then
			local interval = 1 / math.max(1, S.autoClickerCps)
			pcall(level.Jump, level, false)
			task.wait(interval / 2)
			pcall(level.StopJump, level, false)
			task.wait(interval / 2)
		else
			task.wait(0.1)
		end
	end
end)

--------------------------------------------------------------------------------
-- Status overlay
--------------------------------------------------------------------------------

local STATUS_FIELDS = {
	{ key = "cheat", name = "Cheat Indicator", default = true },
	{ key = "fps", name = "FPS Counter", default = true },
	{ key = "cps", name = "CPS Counter" },
	{ key = "attempts", name = "Attempts", default = true },
	{ key = "jumps", name = "Jumps" },
	{ key = "percentage", name = "Percentage", default = true },
	{ key = "best", name = "Best Run" },
	{ key = "levelTime", name = "Level Time" },
	{ key = "sessionTime", name = "Session Time" },
	{ key = "clock", name = "Clock" },
	{ key = "position", name = "Position" },
	{ key = "velocity", name = "Velocity" },
	{ key = "dead", name = "Dead" },
	{ key = "startPos", name = "StartPos" },
	{ key = "noclipDeaths", name = "Noclip Deaths" },
	{ key = "noclipAccuracy", name = "Noclip Accuracy" },
	{ key = "replayState", name = "Replay State" },
	{ key = "message", name = "Message" },
}

local statusShown = {}
for _, field in STATUS_FIELDS do
	statusShown[field.key] = field.default == true
end

local STATUS_CORNERS = {
	["Top Left"] = { Vector2.new(0, 0), UDim2.new(0, 10, 0, 10), Enum.TextXAlignment.Left },
	["Top Right"] = { Vector2.new(1, 0), UDim2.new(1, -10, 0, 10), Enum.TextXAlignment.Right },
	["Bottom Left"] = { Vector2.new(0, 1), UDim2.new(0, 10, 1, -10), Enum.TextXAlignment.Left },
	["Bottom Right"] = { Vector2.new(1, 1), UDim2.new(1, -10, 1, -10), Enum.TextXAlignment.Right },
}

local statusGui = Instance.new("ScreenGui")
statusGui.Name = "DashWorldStatus"
statusGui.ResetOnSpawn = false
statusGui.IgnoreGuiInset = true
statusGui.DisplayOrder = 1000
statusGui.Enabled = false
ctx:Track(statusGui)

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.AutomaticSize = Enum.AutomaticSize.XY
statusLabel.Size = UDim2.fromOffset(0, 0)
statusLabel.RichText = true
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 16
statusLabel.TextColor3 = Color3.new(1, 1, 1)
statusLabel.TextStrokeTransparency = 0.4
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Text = ""
statusLabel.Parent = statusGui

local statusScale = Instance.new("UIScale")
statusScale.Parent = statusLabel

local guiParentOk = pcall(function()
	statusGui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not guiParentOk then
	statusGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
end

local function applyStatusLayout()
	local corner = STATUS_CORNERS[S.statusCorner] or STATUS_CORNERS["Top Left"]
	statusLabel.AnchorPoint = corner[1]
	statusLabel.Position = corner[2]
	statusLabel.TextXAlignment = corner[3]
	statusScale.Scale = S.statusScale
	statusLabel.TextTransparency = 1 - S.statusOpacity
	statusLabel.TextStrokeTransparency = 1 - S.statusOpacity * 0.6
	statusGui.Enabled = S.statusEnabled
end
applyStatusLayout()

local function formatTime(seconds)
	seconds = math.max(0, seconds or 0)
	return string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

local function escapeRichText(text)
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

local function formatPercent(value)
	return string.format("%." .. S.percentDecimals .. "f%%", value * 100)
end

local function buildStatusText(fps, cps)
	local lines = {}
	local function add(text)
		table.insert(lines, text)
	end

	local level = getLevel()
	local player = getPlayer1(level)

	if statusShown.cheat then
		local cheated = level and statsByLevel[level] and statsByLevel[level].cheated
		add((cheated or cheatsActive(level)) and '<font color="#ff4040">●</font>' or '<font color="#40ff70">●</font>')
	end
	if statusShown.fps then
		add(string.format("FPS: %d", fps))
	end
	if statusShown.cps then
		add(string.format("CPS: %d", cps))
	end

	if level then
		local stats = getStats(level)
		if statusShown.attempts then
			add("Attempt " .. tostring(level.attempts or 0))
		end
		if statusShown.jumps then
			add("Jumps: " .. tostring(level.jumps or 0))
		end
		if statusShown.percentage then
			add(formatPercent(level.percentage or 0))
		end
		if statusShown.best then
			add("Best Run: " .. formatPercent(stats.best))
		end
		if statusShown.levelTime then
			add("Time: " .. formatTime(level.attemptTimeSpent))
		end
		if statusShown.position and player and player.position then
			add(string.format("X: %.2f  Y: %.2f", player.position.X, player.position.Y))
		end
		if statusShown.velocity and player then
			add(string.format("VX: %.2f  VY: %.2f", player.velocityX or 0, player.velocityY or 0))
		end
		if statusShown.dead then
			add("Dead: " .. tostring(level.dead == true))
		end
		if statusShown.startPos then
			local ok, list = pcall(level.GetGameplayAffectingStartPos, level)
			if ok and #list > 0 then
				add(string.format("StartPos: %d/%d", level.currentStartPosId or 0, #list))
			end
		end
		if statusShown.noclipDeaths then
			add("Noclip Deaths: " .. tostring(stats.noclipDeaths))
		end
		if statusShown.noclipAccuracy then
			local accuracy = stats.playTicks > 0 and (1 - stats.hitTicks / stats.playTicks) or 1
			add(string.format("Accuracy: %.2f%%", accuracy * 100))
		end
		if statusShown.replayState then
			if level.replayMacro ~= nil then
				add("Replay: Playing")
			elseif S.replayRecord then
				add("Replay: Recording")
			end
		end
	end

	if statusShown.sessionTime then
		add("Session: " .. formatTime(os.clock() - sessionStart))
	end
	if statusShown.clock then
		add(os.date("%H:%M:%S"))
	end
	if statusShown.message and S.message ~= "" then
		add(escapeRichText(S.message))
	end

	return table.concat(lines, "\n")
end

do
	local frames, fps = 0, 0
	local fpsWindowStart = os.clock()
	local lastUpdate = 0

	ctx:Connect(RunService.RenderStepped, function()
		frames += 1
		local now = os.clock()
		if now - fpsWindowStart >= 0.5 then
			fps = math.floor(frames / (now - fpsWindowStart) + 0.5)
			frames = 0
			fpsWindowStart = now
		end

		while clickTimes[1] and now - clickTimes[1] > 1 do
			table.remove(clickTimes, 1)
		end

		local level = getLevel()
		if level then
			local stats = getStats(level)
			stats.best = math.max(stats.best, level.percentage or 0)
		end

		if S.statusEnabled and now - lastUpdate >= 0.1 then
			lastUpdate = now
			statusLabel.Text = buildStatusText(fps, #clickTimes)
		end
	end)
end

--------------------------------------------------------------------------------
-- Display and file helpers
--------------------------------------------------------------------------------

local setFpsCap = setfpscap or (syn and syn.set_fps_cap)

local function applyFpsCap()
	if setFpsCap then
		pcall(setFpsCap, S.unlockFps and S.fpsCap or 60)
	end
end

local LOG_FOLDER = "DashWorld/logs"

-- Writes data as JSON to workspace/DashWorld/logs; returns ok, path or error.
local function writeLog(fileName, data)
	if type(writefile) ~= "function" then
		return false, "your executor has no writefile()"
	end
	pcall(function()
		if not isfolder("DashWorld") then
			makefolder("DashWorld")
		end
		if not isfolder(LOG_FOLDER) then
			makefolder(LOG_FOLDER)
		end
	end)
	local path = LOG_FOLDER .. "/" .. fileName
	local ok, err = pcall(function()
		writefile(path, HttpService:JSONEncode(data))
	end)
	return ok, ok and path or tostring(err)
end

local hasFiles = type(writefile) == "function" and type(readfile) == "function"
	and type(listfiles) == "function" and type(makefolder) == "function"

local function ensureReplayFolder()
	if not hasFiles then
		return false
	end
	pcall(function()
		if not isfolder("DashWorld") then
			makefolder("DashWorld")
		end
		if not isfolder(REPLAY_FOLDER) then
			makefolder(REPLAY_FOLDER)
		end
	end)
	return true
end

local NO_REPLAYS = "(no saved replays)"

local function listReplays()
	local names = {}
	if ensureReplayFolder() then
		local ok, files = pcall(listfiles, REPLAY_FOLDER)
		if ok and type(files) == "table" then
			for _, path in files do
				local name = string.match(path, "([^/\\]+)%.dwr$")
				if name then
					table.insert(names, name)
				end
			end
		end
	end
	table.sort(names)
	return names
end

--------------------------------------------------------------------------------
-- .gdlvl import
--
-- .gdlvl = base64url( gzip( plist XML ) ), plist key k4 holds the level:
-- k4 = base64url( gzip( "header;obj;obj;..." ) ), obj = "key,value,key,value"
-- Units: 30 GD units = 1 stud (Physics.Speeds are GD speeds / 30) and a block
-- resting on the ground has y = 0 in DW, y = 15 in GD.
--
-- Importing arms a pending level. The next LoadFromLevelData outside LevelScene
-- (i.e. opening a custom level in the editor) builds it instead of its saved
-- data. Levels opened for play are left alone: LevelScene reports their
-- attempts to the server under the real level's id.
--------------------------------------------------------------------------------

local IMPORT_FOLDER = "gdlvl"
local IMPORT_SENTINEL = "__DashWorld_gdlvl_import__"
local NO_FILES = "(no .gdlvl files found)"

local importStatusText = nil
local levelSceneLoads = 0

-- Safe from the game's thread: the UI loop shows the text.
local function setImportStatus(text)
	importStatusText = text
end

local gdlvl = {}
do
	local B64 = {}
	do
		local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		for i = 1, 64 do
			B64[string.byte(chars, i)] = i - 1
		end
		B64[string.byte("-")] = 62
		B64[string.byte("_")] = 63
	end

	local function base64Decode(s: string): (buffer, number)
		local out = buffer.create(math.floor(#s * 3 / 4) + 3)
		local n, acc, bits = 0, 0, 0
		for i = 1, #s do
			local v = B64[string.byte(s, i)]
			if v then
				acc = bit32.bor(bit32.lshift(acc, 6), v)
				bits += 6
				if bits >= 8 then
					bits -= 8
					buffer.writeu8(out, n, bit32.band(bit32.rshift(acc, bits), 0xFF))
					n += 1
				end
				acc = bit32.band(acc, bit32.lshift(1, bits) - 1)
			end
		end
		return out, n
	end

	--------------------------------------------------------------------------------
	-- DEFLATE (RFC 1951) with gzip / zlib wrappers
	--------------------------------------------------------------------------------

	local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
	local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
	local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
	local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
	local CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

	-- Canonical Huffman table: count[len] = codes of that length, symbol[] sorted by code.
	local function buildHuffman(lengths, n)
		local count = {}
		for len = 0, 15 do
			count[len] = 0
		end
		for sym = 0, n - 1 do
			local len = lengths[sym] or 0
			count[len] += 1
		end
		local offs = { [1] = 0 }
		for len = 1, 14 do
			offs[len + 1] = offs[len] + count[len]
		end
		local symbol = {}
		for sym = 0, n - 1 do
			local len = lengths[sym] or 0
			if len ~= 0 then
				symbol[offs[len]] = sym
				offs[len] += 1
			end
		end
		return { count = count, symbol = symbol }
	end

	local fixedLit, fixedDist
	local function getFixedTables()
		if not fixedLit then
			local lit = {}
			for i = 0, 143 do lit[i] = 8 end
			for i = 144, 255 do lit[i] = 9 end
			for i = 256, 279 do lit[i] = 7 end
			for i = 280, 287 do lit[i] = 8 end
			local dist = {}
			for i = 0, 29 do dist[i] = 5 end
			fixedLit = buildHuffman(lit, 288)
			fixedDist = buildHuffman(dist, 30)
		end
		return fixedLit, fixedDist
	end

	local function inflate(src: buffer, srcLen: number, pos: number): string
		local outCap = math.max(srcLen * 4, 1024)
		local out = buffer.create(outCap)
		local outLen = 0
		local bitBuf, bitCnt = 0, 0
		local work = 0

		local function bits(n)
			if n == 0 then
				return 0
			end
			while bitCnt < n do
				if pos >= srcLen then
					error("unexpected end of compressed data", 0)
				end
				bitBuf += bit32.lshift(buffer.readu8(src, pos), bitCnt)
				pos += 1
				bitCnt += 8
			end
			local v = bit32.band(bitBuf, bit32.lshift(1, n) - 1)
			bitBuf = bit32.rshift(bitBuf, n)
			bitCnt -= n
			return v
		end

		local function decode(h)
			local count, symbol = h.count, h.symbol
			local code, first, index = 0, 0, 0
			for len = 1, 15 do
				code += bits(1)
				local c = count[len]
				if code - c < first then
					return symbol[index + (code - first)]
				end
				index += c
				first = (first + c) * 2
				code *= 2
			end
			error("invalid Huffman code", 0)
		end

		local function reserve(extra)
			if outLen + extra > outCap then
				while outCap < outLen + extra do
					outCap *= 2
				end
				local grown = buffer.create(outCap)
				buffer.copy(grown, 0, out, 0, outLen)
				out = grown
			end
		end

		repeat
			local final = bits(1)
			local blockType = bits(2)

			if blockType == 0 then
				-- Stored block: drop the rest of the current byte, then LEN/NLEN.
				bitBuf, bitCnt = 0, 0
				if pos + 4 > srcLen then
					error("truncated stored block", 0)
				end
				local len = buffer.readu16(src, pos)
				pos += 4
				if pos + len > srcLen then
					error("truncated stored block", 0)
				end
				reserve(len)
				buffer.copy(out, outLen, src, pos, len)
				outLen += len
				pos += len
			elseif blockType == 1 or blockType == 2 then
				local lit, dist
				if blockType == 1 then
					lit, dist = getFixedTables()
				else
					local nLit = bits(5) + 257
					local nDist = bits(5) + 1
					local nCode = bits(4) + 4
					local codeLengths = {}
					for i = 0, 18 do
						codeLengths[i] = 0
					end
					for i = 1, nCode do
						codeLengths[CODE_LENGTH_ORDER[i]] = bits(3)
					end
					local codeTable = buildHuffman(codeLengths, 19)

					local lengths = {}
					local index = 0
					while index < nLit + nDist do
						local sym = decode(codeTable)
						if sym < 16 then
							lengths[index] = sym
							index += 1
						else
							local value, repeatCount = 0, 0
							if sym == 16 then
								if index == 0 then
									error("repeat with no previous length", 0)
								end
								value = lengths[index - 1]
								repeatCount = 3 + bits(2)
							elseif sym == 17 then
								repeatCount = 3 + bits(3)
							else
								repeatCount = 11 + bits(7)
							end
							if index + repeatCount > nLit + nDist then
								error("too many code lengths", 0)
							end
							for _ = 1, repeatCount do
								lengths[index] = value
								index += 1
							end
						end
					end

					local litLengths, distLengths = {}, {}
					for i = 0, nLit - 1 do
						litLengths[i] = lengths[i]
					end
					for i = 0, nDist - 1 do
						distLengths[i] = lengths[nLit + i]
					end
					lit = buildHuffman(litLengths, nLit)
					dist = buildHuffman(distLengths, nDist)
				end

				while true do
					local sym = decode(lit)
					if sym < 256 then
						reserve(1)
						buffer.writeu8(out, outLen, sym)
						outLen += 1
					elseif sym == 256 then
						break
					else
						sym -= 257
						if sym >= 29 then
							error("invalid length symbol", 0)
						end
						local len = LEN_BASE[sym + 1] + bits(LEN_EXTRA[sym + 1])
						local distSym = decode(dist)
						if distSym >= 30 then
							error("invalid distance symbol", 0)
						end
						local distance = DIST_BASE[distSym + 1] + bits(DIST_EXTRA[distSym + 1])
						if distance > outLen then
							error("distance too far back", 0)
						end
						reserve(len)
						local from = outLen - distance
						if distance >= len then
							buffer.copy(out, outLen, out, from, len)
						else
							-- Overlapping copy repeats the last `distance` bytes.
							for i = 0, len - 1 do
								buffer.writeu8(out, outLen + i, buffer.readu8(out, from + i))
							end
						end
						outLen += len
					end

					work += 1
					if work % 200000 == 0 then
						task.wait()
					end
				end
			else
				error("invalid block type", 0)
			end
		until final == 1

		return buffer.readstring(out, 0, outLen)
	end

	local function decompress(buf: buffer, len: number): string
		if len < 2 then
			error("data too short", 0)
		end
		local b0, b1 = buffer.readu8(buf, 0), buffer.readu8(buf, 1)

		if b0 == 0x1F and b1 == 0x8B then
			local flags = buffer.readu8(buf, 3)
			local pos = 10
			if bit32.btest(flags, 4) then -- FEXTRA
				pos += 2 + buffer.readu16(buf, pos)
			end
			if bit32.btest(flags, 8) then -- FNAME
				while buffer.readu8(buf, pos) ~= 0 do pos += 1 end
				pos += 1
			end
			if bit32.btest(flags, 16) then -- FCOMMENT
				while buffer.readu8(buf, pos) ~= 0 do pos += 1 end
				pos += 1
			end
			if bit32.btest(flags, 2) then -- FHCRC
				pos += 2
			end
			return inflate(buf, len, pos)
		elseif bit32.band(b0, 0x0F) == 8 and (b0 * 256 + b1) % 31 == 0 then
			return inflate(buf, len, 2)
		end

		return inflate(buf, len, 0)
	end

	local function decodeBlob(text: string): string
		local buf, len = base64Decode(text)
		return decompress(buf, len)
	end

	--------------------------------------------------------------------------------
	-- .gdlvl file -> GD level string
	--------------------------------------------------------------------------------

	-- Linear scan: a "^%s*(.-)%s*$" pattern backtracks badly on multi-MB strings.
	local function trim(s: string): string
		local first = string.find(s, "%S")
		if not first then
			return ""
		end
		local last = #s
		while last > first do
			local byte = string.byte(s, last)
			if byte ~= 32 and (byte < 9 or byte > 13) then
				break
			end
			last -= 1
		end
		return string.sub(s, first, last)
	end

	local function unescapeXml(s: string): string
		s = string.gsub(s, "&lt;", "<")
		s = string.gsub(s, "&gt;", ">")
		s = string.gsub(s, "&quot;", "\"")
		s = string.gsub(s, "&apos;", "'")
		s = string.gsub(s, "&amp;", "&")
		return s
	end

	local function plistValue(xml: string, key: string): string?
		return string.match(xml, "<k>" .. key .. "</k>%s*<s>(.-)</s>")
			or string.match(xml, "<key>" .. key .. "</key>%s*<string>(.-)</string>")
	end

	local function isLevelString(s: string): boolean
		-- Anchored: "kS38" can occur by chance anywhere inside long base64 text.
		return string.match(s, "^k[SA]%d+,") ~= nil or string.match(s, "^1,%d+,") ~= nil
	end

	local function readGdlvl(fileText: string): (string, string)
		local text = trim(fileText)
		local xml

		if string.sub(text, 1, 1) == "<" then
			xml = text
		else
			local ok, result = pcall(decodeBlob, text)
			if not ok then
				error("could not decode file: " .. tostring(result), 0)
			end
			if isLevelString(result) then
				return "Imported Level", result
			end
			xml = result
		end

		local k4 = plistValue(xml, "k4")
		if not k4 then
			error("file has no level data (k4)", 0)
		end
		k4 = trim(unescapeXml(k4))

		local levelString
		if isLevelString(k4) then
			levelString = k4
		else
			local ok, result = pcall(decodeBlob, k4)
			if not ok then
				error("could not decode level data: " .. tostring(result), 0)
			end
			levelString = result
		end

		local name = plistValue(xml, "k2")
		return name and unescapeXml(name) or "Imported Level", levelString
	end

	--------------------------------------------------------------------------------
	-- GD object id -> Dash World toolbox name
	--
	-- Dash World's block sets follow GD's 7-piece order (square, top, outer
	-- corner, inner corner, inner, top pillar, pillar); its "Light*" sets are GD's
	-- "Colored" sets. `kind` is checked against the DW prefab's tags so a wrong
	-- guess is skipped instead of turning decoration into a hazard:
	--   solid  -> must be Collidable and not Hazard
	--   hazard -> must be Hazard
	--   decor  -> must be neither
	--   special (orbs, pads, portals, ...) -> not checked
	--------------------------------------------------------------------------------

	local GD_TO_DW = {}

	local function map(kind, gdIds, dwNames)
		for i, gdId in gdIds do
			GD_TO_DW[gdId] = { name = dwNames[i], kind = kind }
		end
	end

	local function series(prefix, count)
		local names = {}
		for i = 1, count do
			names[i] = string.format("%s%02d", prefix, i)
		end
		return names
	end

	-- Blocks
	map("solid", { 1 }, { "RegularBlock01" })
	-- One set of DW blocks. decorPiece has no hitbox (the prefab dump's tags): the
	-- "inner" square of each set.
	local function blockSet(prefix, gdIds, decorPiece)
		for i, gdId in gdIds do
			map(i == decorPiece and "decor" or "solid", { gdId }, { string.format("%s%02d", prefix, i) })
		end
	end

	-- GridBlock06 is an extra piece GD doesn't have: GD's pillars are 07 and 08.
	map("solid", { 83, 2, 3, 4, 6, 7 }, { "GridBlock01", "GridBlock02", "GridBlock03", "GridBlock04", "GridBlock07", "GridBlock08" })
	map("decor", { 5 }, { "GridBlock05" })
	blockSet("TileBlock", { 69, 70, 71, 72, 73, 74, 75 }, 5)
	blockSet("ChippedBlock", { 76, 77, 78, 80, 81, 82 }, 4)
	map("solid", { 90, 91, 92, 93, 94, 95, 96 }, series("BlackBlock", 7))
	blockSet("BrickBlock", { 116, 117, 118, 119, 120, 121, 122 }, 5)
	blockSet("LightBlock", { 207, 208, 209, 210, 211, 212, 213 }, 5)
	-- LightGridBlock has no hitbox at all; its solid twin skips number 05.
	map("solid", { 247, 248, 249, 250, 252, 253, 254 }, { "LightHitboxGridBlock01", "LightHitboxGridBlock02", "LightHitboxGridBlock03", "LightHitboxGridBlock04", "LightHitboxGridBlock06", "LightHitboxGridBlock07", "LightHitboxGridBlock08" })
	map("decor", { 251 }, { "LightGridBlock05" })
	blockSet("LightTileBlock", { 255, 256, 257, 258, 259, 260, 261 }, 5)
	blockSet("LightChippedBlock", { 263, 264, 265, 266, 267, 268 }, 4)
	map("solid", { 269, 270, 271, 272, 274, 275 }, { "LightBrickBlock01", "LightBrickBlock02", "LightBrickBlock03", "LightBrickBlock04", "LightBrickBlock06", "LightBrickBlock07" })
	map("decor", { 273 }, { "LightBrickBlock05" })
	map("solid", { 40 }, { "RegularStep01" })

	-- Slopes
	map("solid", { 371, 372 }, { "Slope01", "Slope02" })
	map("solid", { 1338, 1339 }, { "Slope01", "Slope02" })
	map("solid", { 289, 291 }, { "GridSlope01", "GridSlope02" })
	map("solid", { 305, 307 }, { "ChippedSlope01", "ChippedSlope02" })
	map("solid", { 673, 674 }, { "InvisSlope01", "InvisSlope02" })

	-- Hazards (full, half, small, tiny)
	map("hazard", { 8, 39, 103, 392 }, series("RegularSpike", 4))
	map("hazard", { 216, 217, 218, 458 }, series("ColorSpike", 4))
	map("hazard", { 144, 205, 145, 459 }, series("InvisSpike", 4))
	map("hazard", { 177, 178, 179 }, series("IceSpike", 3))
	map("hazard", { 88, 89, 98 }, series("RegularSaw", 3))
	map("hazard", { 183, 184, 185 }, series("RegularBlade", 3))
	map("hazard", { 9, 1715 }, { "ThornPit01", "ThornPit01" })
	map("hazard", { 61, 243, 244 }, series("WavyPit", 3))
	map("hazard", { 363, 364, 365 }, { "ThornPit04", "ThornPit05", "ThornPit06" })
	map("hazard", { 366, 367, 368 }, { "WavyPit04", "WavyPit05", "WavyPit06" })
	map("hazard", { 135 }, { "Pit01" })
	-- Colorable twins of the pit / slope hazards above (GD 1716-1724)
	map("hazard", { 1716, 1717, 1718 }, { "ThornPit06", "ThornPit04", "ThornPit05" })
	map("hazard", { 1719, 1720, 1721 }, series("WavyPit", 3))
	map("hazard", { 1722, 1723, 1724 }, { "WavyPit06", "WavyPit04", "WavyPit05" })

	-- Decoration
	map("decor", { 191, 198, 199, 393 }, series("FakeSpike", 4))
	map("decor", { 18, 19, 20, 21 }, series("ThornGroundDecor", 4))
	map("decor", { 15, 16, 17 }, series("Rod", 3))
	map("decor", { 123, 124, 125, 126, 127, 128 }, series("Thorn", 6))
	map("decor", { 113, 114, 115 }, series("BrickDecor", 3))
	map("decor", { 85, 86, 87, 97 }, series("Cogwheel", 4))
	map("decor", { 137, 138, 139 }, series("Wheel", 3))
	map("decor", { 154, 155, 156 }, series("SpikeWheel", 3))
	map("decor", { 180, 181, 182 }, series("CartWheel", 3))
	map("decor", { 222, 223, 224 }, series("RoundCloud", 3))

	-- Pads, orbs, portals, misc
	map("special", { 35, 140, 1332, 67, 3005 }, { "PadYellow", "PadPink", "PadRed", "PadGravity", "PadSpider" })
	map("special", { 36, 141, 1333, 84, 1022, 1330, 1704, 1751, 3004 }, { "OrbYellow", "OrbPink", "OrbRed", "OrbGravity", "OrbGravityGreen", "OrbBlack", "OrbDash", "OrbDashGravity", "OrbSpider" })
	map("special", { 10, 11, 2926 }, { "PortalNormalGravity", "PortalReverseGravity", "PortalSwitchGravity" })
	map("special", { 99, 101, 286, 287 }, { "PortalNormal", "PortalMini", "PortalDualA", "PortalDualB" })
	map("special", { 200, 201, 202, 203, 1334 }, { "PortalBoostSlow", "PortalBoostNormal", "PortalBoostFast", "PortalBoostFaster", "PortalBoostFastest" })
	map("special", { 12, 13, 47, 111, 660, 745, 1331, 1933 }, { "PortalGamemodeCube", "PortalGamemodeShip", "PortalGamemodeBall", "PortalGamemodeBird", "PortalGamemodeDart", "PortalGamemodeRobot", "PortalGamemodeSpider", "PortalGamemodeSwing" })
	map("special", { 143 }, { "DestructibleBrick01" })
	map("special", { 1329, 142 }, { "SecretCoin", "SecretCoin" })

	-- Sets that match GD's piece for piece (same names and piece counts).
	map("solid", { 62, 63, 64, 65, 66, 68 }, series("WavyStep", 6))
	map("solid", { 146, 147, 204, 206 }, series("InvisOutline", 4))
	map("solid", { 170, 171, 172, 173, 174, 175, 176, 192, 194, 197 }, series("MetallicPlatform", 10))
	map("solid", { 326, 327, 328, 329 }, series("MetallicSlope", 4))
	map("solid", { 1743, 1744 }, { "GridSlope01", "GridSlope02" })
	map("solid", { 299, 301, 1745, 1746 }, { "TileSlope01", "TileSlope02", "TileSlope01", "TileSlope02" })
	map("solid", { 309, 311, 1747, 1748 }, { "BlackSlope01", "BlackSlope02", "BlackSlope01", "BlackSlope02" })
	map("solid", { 321, 323, 1749, 1750 }, { "BrickSlope01", "BrickSlope02", "BrickSlope01", "BrickSlope02" })
	map("solid", { 315, 317 }, { "ChequeredSlope01", "ChequeredSlope03" })
	map("decor", { 691, 692, 324, 325, 358 }, { "ChequeredSlope02", "ChequeredSlope04", "ChequeredSlope05", "ChequeredSlope06", "ChequeredSlope07" })
	map("solid", { 337, 339 }, { "WhiteGridSlope01", "WhiteGridSlope02" })
	map("solid", { 349, 351 }, { "ChippedWhiteSlope01", "ChippedWhiteSlope02" })
	map("solid", { 353, 355 }, { "WhiteBrickSlope01", "WhiteBrickSlope02" })
	map("decor", { 681, 682 }, { "BaseGridSlope01", "BaseGridSlope02" })
	map("decor", { 683, 684 }, { "BaseTileSlope01", "BaseTileSlope02" })
	map("decor", { 685, 686 }, { "BaseChippedSlope01", "BaseChippedSlope02" })
	map("decor", { 687, 688 }, { "BaseBlackSlope01", "BaseBlackSlope02" })
	map("decor", { 689, 690 }, { "BaseBrickSlope01", "BaseBrickSlope02" })
	map("decor", { 693, 694 }, { "BaseWhiteSlope01", "BaseWhiteSlope02" })
	map("decor", { 695, 696 }, { "BaseWhiteGridSlope01", "BaseWhiteGridSlope02" })
	map("decor", { 697, 698 }, { "BaseWhiteTileSlope01", "BaseWhiteTileSlope02" })
	map("decor", { 699, 700 }, { "BaseWhiteChippedSlope01", "BaseWhiteChippedSlope02" })
	map("decor", { 701, 702 }, { "BaseWhiteBrickSlope01", "BaseWhiteBrickSlope02" })
	map("decor", { 467, 468, 469, 470, 471, 472, 473, 474, 475 }, series("BlockOutline", 9))
	map("decor", { 41, 110, 106, 107 }, series("ChainDecor", 4))
	map("decor", { 498, 499 }, series("ChainLinkDecor", 2))
	map("decor", { 132, 460, 494 }, series("AudioArrow", 3))
	map("decor", { 375, 376, 377, 378 }, series("RotatingLine", 4))
	map("decor", { 1058, 1059, 1060, 1061 }, series("SpiralShape", 4))
	map("decor", { 1889, 1890, 1891, 1892 }, series("FakeSpike", 4))
	map("decor", { 719, 721, 990, 992 }, series("SerratedPitOutline", 4))
	map("decor", { 678, 679, 680 }, series("Cogwheel", 3))
	map("hazard", { 740, 741, 742 }, series("InvisibleBlade", 3))
	map("hazard", { 397, 398, 399 }, series("BlackBlade", 3))
	map("hazard", { 1705, 1706, 1707 }, series("LightBlade", 3))
	map("hazard", { 1708, 1709, 1710 }, series("PointyBlade", 3))
	map("hazard", { 1734, 1735, 1736 }, series("BlackCogwheel", 3))
	map("hazard", { 1619, 1620 }, series("SpinBlade", 2))
	map("hazard", { 1701, 1702, 1703 }, series("BladeTrap", 3))
	map("hazard", { 421, 422, 768 }, series("JaggedPit", 3))
	map("hazard", { 1725, 1726, 1727 }, series("JaggedPit", 3))
	map("hazard", { 446, 447 }, series("CurvedPit", 2))
	map("hazard", { 1728, 1729 }, series("CurvedPit", 2))
	map("hazard", { 667, 720, 991 }, { "SerratedPit01", "SerratedPit02", "SerratedPit03" })
	map("hazard", { 1730, 1731, 1733, 1732 }, series("SerratedPit", 4))
	map("hazard", { 3610, 3611 }, series("HazardBlock", 2))
	map("special", { 1594 }, { "OrbCustom" })
	map("special", { 914 }, { "TextObject" })
	map("special", { 3027 }, { "OrbTeleport" })
	-- GD's modifier blocks are DW's square triggers (Player.square_trigs_touched).
	map("special", { 1755, 1813, 1829, 1859 }, { "TriggerD", "TriggerJ", "TriggerS", "TriggerH" })
	map("special", { 747 }, { "PortalTeleportA" })
	map("special", { 2902, 2064 }, { "PortalTeleportSA", "PortalTeleportSB" })

	-- Same kind of object, but the exact shape or piece order is inferred.
	-- The Approximate Matches toggle controls all of these.
	local function approxMap(kind, gdIds, dwNames, noAudioScale)
		map(kind, gdIds, dwNames)
		for _, gdId in gdIds do
			GD_TO_DW[gdId].approx = true
			GD_TO_DW[gdId].noAudioScale = noAudioScale
		end
	end

	-- DW's Particle objects are GD's particle sheet, checked against the textures:
	-- Particle001 is the square just before 3801 (hexagon), Particle003 the circle at
	-- 3802, Particle200 the heart at 3999. Particle201-214 have no GD match: GD's ids
	-- from 4000 on are pixel art.
	for gdId = 3800, 3999 do
		GD_TO_DW[gdId] = { name = string.format("Particle%03d", gdId - 3799), kind = "decor", approx = true }
	end

	approxMap("decor", { 50, 51, 52, 53, 54, 60, 148, 149, 405 }, series("AudioBall", 9))
	approxMap("decor", { 133, 136, 150 }, series("AudioMark", 3))
	approxMap("decor", { 236, 497, 495, 496 }, series("AudioLarge", 4))
	approxMap("decor", { 3621, 3622, 3623, 3624, 3625, 3626, 3627, 3628, 3629 }, series("AudioBall", 9), true)
	approxMap("decor", { 3633, 3634, 3635 }, series("AudioMark", 3), true)
	approxMap("decor", { 3636, 3637, 3638, 3639 }, series("AudioLarge", 4), true)
	approxMap("decor", { 3630, 3631, 3632 }, series("AudioArrow", 3), true)
	approxMap("decor", { 48, 49, 129, 130, 131 }, series("CloudDecor", 5))
	approxMap("decor", { 157, 158, 159 }, series("WaveDecor", 3))
	approxMap("decor", { 151, 152, 153 }, series("Pillar", 3))
	approxMap("decor", { 997, 998, 999, 1000 }, series("RotatingBall", 4))
	approxMap("decor", { 394, 395, 396 }, series("GeometricShape", 3))
	approxMap("decor", { 1019, 1020, 1021 }, series("FlashRing", 3))
	approxMap("decor", { 1055, 1056, 1057 }, series("PickupCircle", 3))
	map("decor", { 1831, 1833, 1832, 1834 }, series("ScaleFadeRing", 4))
	-- The same pictures without the rotation; DW's are always rotating objects.
	approxMap("decor", { 1835, 1837, 1836, 1838 }, series("ScaleFadeRing", 4))
	approxMap("decor", { 1525, 1526, 1527, 1528 }, series("RotatingSquare", 4))
	approxMap("decor", { 1516 }, { "WaterFallAnim" })
	approxMap("decor", { 1142, 1140, 1141, 1143, 1144, 1150, 1151, 1146, 1147, 1153, 1148, 1149, 1145, 1152 }, series("ChequeredBlock", 14))
	approxMap("decor", { 1011, 1012, 1013, 1269, 1270, 1293, 1762, 1763, 1888 }, series("Gradient", 9))
	approxMap("decor", { 503, 504, 505, 1273, 1274, 1291, 1758, 1759, 1886 }, series("GradientSmall", 9))
	approxMap("decor", { 1292, 1009, 1010, 1271, 1272 }, series("GradientSmaller", 5))
	approxMap("decor", { 1760, 1761, 1887 }, { "GradientSmaller07", "GradientSmaller08", "GradientSmaller09" })
	approxMap("decor", { 2943, 2952 }, { "LightBlock05", "LightBlock05" })
	-- DW's plain colored slopes have no hitbox, so these keep the collision instead.
	approxMap("solid", { 331, 333, 343, 345 }, { "WhiteGridSlope01", "WhiteGridSlope02", "WhiteGridSlope01", "WhiteGridSlope02" })
	approxMap("solid", { 160, 161, 162, 163, 165, 166, 167, 168, 169 }, series("ChequeredHitboxBlock", 9))
	approxMap("solid", { 369, 370, 196 }, { "RegularStep01", "RegularStep01", "RegularStep01" })
	approxMap("decor", { 373, 374 }, { "BaseBlackSlope01", "BaseBlackSlope02" })
	approxMap("hazard", { 186, 187, 188 }, series("LightBlade", 3))
	approxMap("hazard", { 1711, 1712, 1713, 1714 }, { "ThornPit01", "ThornPit01", "ThornPit01", "ThornPit01" })

	-- DW's 15 Persp sets follow GD's 15 3DL sets: 9 pieces each, from id 506.
	for setIndex, dwName in {
		"PerspOutline", "PerspGridBlock", "PerspTileBlock", "PerspTransparentBlock", "PerspBlackBlock",
		"PerspBrickBlock", "PerspChequeredBlock", "PerspMetallicBlock", "PerspLightBlock", "PerspLightGridBlock",
		"PerspLightTileBlock", "PerspLightTransparentBlock", "PerspLightBrickBlock", "PerspBeamBlock", "PerspPatternedBlock",
	} do
		local gdIds = {}
		for piece = 1, 9 do
			gdIds[piece] = 506 + (setIndex - 1) * 9 + piece - 1
		end
		approxMap("decor", gdIds, series(dwName, 9))
	end
	approxMap("decor", { 476, 477, 478, 479, 480, 481, 482 }, series("BeamBlock", 7))
	approxMap("decor", { 485, 486, 487, 488, 489, 490, 491 }, series("PatternedBlock", 7))
	approxMap("decor", { 650, 644, 641, 646, 1075, 642, 739, 643, 645, 647, 648, 649, 1077, 1298, 1076 }, series("CrossBlock", 15))
	approxMap("decor", { 703, 704 }, series("BeamSlope", 2))
	approxMap("decor", { 705, 706 }, series("PatternedSlope", 2))
	approxMap("decor", { 707, 708 }, series("CrossSlope", 2))
	approxMap("decor", { 225, 226, 500, 501 }, series("Swirve", 4))
	approxMap("decor", { 237, 238, 239, 240, 241 }, { "Link01_01", "Link01_02", "Link01_03", "Link01_04", "Link01_05" })
	approxMap("decor", { 231, 232, 283, 284, 285 }, series("Smallbar", 5))
	approxMap("decor", { 229, 230 }, { "Bar03", "Bar04" })
	approxMap("decor", { 1001, 1002, 1003, 1004, 1005 }, { "Link04_01", "Link04_02", "Link04_03", "Link04_04", "Link04_05" })
	-- No DW equivalent, closest shape instead. Animated in GD, static here.
	approxMap("decor", { 3000, 1050, 3002, 1052 }, { "Swirve01", "Swirve01", "Swirve01", "Swirve01" })
	approxMap("decor", { 3001, 1051 }, { "Swirve03", "Swirve03" })
	approxMap("decor", { 3034, 3038, 3042, 3046 }, { "FakeSpike01", "FakeSpike01", "FakeSpike01", "FakeSpike01" })
	approxMap("decor", { 3035, 3039, 3043, 3047 }, { "FakeSpike03", "FakeSpike03", "FakeSpike03", "FakeSpike03" })
	approxMap("decor", { 3036, 3040, 3044, 3048, 3037, 3041, 3045, 3049 }, { "FakeSpike04", "FakeSpike04", "FakeSpike04", "FakeSpike04", "FakeSpike04", "FakeSpike04", "FakeSpike04", "FakeSpike04" })
	approxMap("decor", { 3054, 3055, 3056, 3057, 3058, 3059, 3060 }, { "BlockOutline02", "BlockOutline02", "BlockOutline02", "BlockOutline02", "BlockOutline02", "BlockOutline02", "BlockOutline02" })
	approxMap("decor", { 658, 656, 653 }, { "PaneBlock01_01", "PaneBlock01_02", "PaneBlock01_03" })
	approxMap("decor", { 657, 725 }, { "PanePatternBlock01", "PanePatternBlock01" })
	approxMap("decor", { 713, 714 }, { "PaneSlope01_01", "PaneSlope01_02" })
	approxMap("decor", { 659, 655, 654 }, { "PaneBlock02_01", "PaneBlock02_02", "PaneBlock02_03" })
	approxMap("decor", { 715, 716 }, { "PaneSlope02_01", "PaneSlope02_02" })
	approxMap("decor", { 722, 723, 724 }, { "PaneBlock03_01", "PaneBlock03_02", "PaneBlock03_03" })
	approxMap("decor", { 730, 731 }, { "PaneSlope03_01", "PaneSlope03_02" })
	approxMap("decor", { 734, 735, 736 }, { "PaneBlock04_01", "PaneBlock04_02", "PaneBlock04_03" })
	approxMap("decor", { 732, 733 }, { "PaneSlope04_01", "PaneSlope04_02" })

	-- GD header kA4 speed -> DW gameplaySpeed (index into Physics.Speeds)
	local GD_SPEED_TO_DW = { [0] = 2, [1] = 1, [2] = 3, [3] = 4, [4] = 5 }

	-- Level art. GD numbers these from 1 like DW's tables, with 0 meaning the first
	-- one; a missing entry would error in Level:updateBackground and friends.
	local LevelInfo = ReplicatedStorage.Shared.Info
	local Backgrounds = require(LevelInfo.Backgrounds)
	local Grounds = require(LevelInfo.Grounds)
	local MiddleGrounds = require(LevelInfo.MiddleGrounds)
	local Lines = require(LevelInfo.Lines)
	local LevelFonts = require(LevelInfo.LevelFonts)

	local function artId(list, value: string?): number
		local id = tonumber(value) or 1
		return list[id] and id or 1
	end

	local function parsePairs(segment: string, separator: string)
		local parts = string.split(segment, separator)
		local props = {}
		for i = 1, #parts - 1, 2 do
			props[parts[i]] = parts[i + 1]
		end
		return props
	end

	--------------------------------------------------------------------------------
	-- Colour channels
	--
	-- DW uses GD's special channel names but different numbers: user channels are
	-- 1-999 in both, while DW's specials are BG -3, G -4, OBJ -7, ..., WHITE 1000,
	-- BLACK 1001 (GD's BG is 1000!). So GD ids go through the name:
	--   * blocks, triggers and copiedChannelId store the number from
	--     ColorChannel:resolveNumberId(name or number)
	--   * levelSettings.colorChannels is keyed by resolveChannelId(), which
	--     returns the name for specials; setColorChannelData does that itself.
	--------------------------------------------------------------------------------

	local GD_SPECIAL_CHANNELS = {
		[1000] = "BG", [1001] = "G", [1002] = "L", [1003] = "3DL", [1004] = "OBJ",
		[1005] = "P1", [1006] = "P2", [1009] = "G2", [1010] = "BLACK", [1011] = "WHITE",
		[1013] = "MG", [1014] = "MG2",
	}

	-- Channel name (specials) or number (user channels), as setColorChannelData takes.
	local function channelKey(gdChannel: number?)
		if not gdChannel or gdChannel <= 0 then
			return nil
		end
		if gdChannel >= 1000 then
			return GD_SPECIAL_CHANNELS[gdChannel]
		end
		return gdChannel
	end

	local channelIdCache = {}

	-- Numeric DW channel id, as stored in basecolor_id / trigger ids.
	local function channelId(gdChannel: number?): number?
		local key = channelKey(gdChannel)
		if key == nil then
			return nil
		end
		local cached = channelIdCache[key]
		if cached ~= nil then
			return cached or nil
		end
		local ok, id = pcall(ColorChannel.resolveNumberId, ColorChannel, key)
		local result = ok and type(id) == "number" and id or nil
		channelIdCache[key] = result or false
		return result
	end

	local function num(p, key: string, default: number): number
		return tonumber(p[key]) or default
	end

	local function flag(p, key: string): boolean
		return p[key] == "1"
	end

	local function rgb(p, rKey: string, gKey: string, bKey: string): Color3
		return Color3.fromRGB(num(p, rKey, 255), num(p, gKey, 255), num(p, bKey, 255))
	end

	-- GD HSV string: "h a s a b a saturationAdditive a brightnessAdditive"
	local function applyHsv(data, hsv: string?)
		if not hsv or hsv == "" then
			return
		end
		local parts = string.split(hsv, "a")
		data.hue = tonumber(parts[1]) or 0
		data.saturation = tonumber(parts[2]) or 1
		data.brightness = tonumber(parts[3]) or 1
		data.useAdditiveSaturation = parts[4] == "1"
		data.useAdditiveBrightness = parts[5] == "1"
	end

	-- Header kS38: "key_value_..." entries separated by "|"
	-- 1/2/3 = rgb, 4 = player colour (1/2), 5 = blending, 6 = channel,
	-- 7 = opacity, 9 = copied channel, 10 = HSV (on the copied colour), 17 = copy opacity
	local function parseColorChannels(kS38: string?)
		local channels = {}
		if not kS38 then
			return channels
		end
		for _, entry in string.split(kS38, "|") do
			if entry ~= "" then
				local c = parsePairs(entry, "_")
				local key = channelKey(tonumber(c["6"]))
				if key then
					local fields = {
						color = rgb(c, "1", "2", "3"),
						opacity = num(c, "7", 1),
						blending = c["5"] == "1",
						pCol1 = c["4"] == "1",
						pCol2 = c["4"] == "2",
					}
					local copied = channelId(tonumber(c["9"]))
					if copied then
						fields.copyColor = true
						fields.copiedChannelId = copied
						fields.copyOpacity = c["17"] == "1"
						-- ColorChannel has the same hue/saturation/brightness fields.
						applyHsv(fields, c["10"])
					end
					table.insert(channels, { key = key, fields = fields })
				end
			end
		end
		return channels
	end

	--------------------------------------------------------------------------------
	-- Triggers: GD object keys -> DW triggerData (Block.TriggerData)
	--
	-- Missing triggerData fields are filled with defaults by Block:RefreshTriggerData.
	-- A converter returning nil means "GD mode DW doesn't support", which is skipped.
	--
	-- Verified against TriggerManager.Trigger.TriggerHandlers: DW keeps GD's raw
	-- values (moveX is scaled by 0.1, or 1/30 with small_step, like GD; rotate
	-- degrees are clockwise-positive like GD; Camera adds offsetX/Y and shake
	-- strength scaled by 0.1, also like GD). Easing ids index Shared.Info.Easing
	-- EASINGS, which is GD's easing list in the same order but 1-based.
	--------------------------------------------------------------------------------

	local EASING_OFFSET = 1

	local function easing(p)
		return num(p, "30", 0) + EASING_OFFSET, num(p, "85", 2)
	end


	local TRIGGERS = {}

	local function trigger(gdId: number, dwName: string, convert, noBasicOptions: boolean?)
		TRIGGERS[gdId] = { convert = convert, noBasicOptions = noBasicOptions }
		GD_TO_DW[gdId] = { name = dwName, kind = "trigger" }
	end

	local function noData()
		return {}
	end

	trigger(899, "ColorTrigger", function(p)
		local target = channelId(num(p, "23", 1))
		if not target then
			return nil
		end
		local copied = channelId(tonumber(p["50"]))
		local data = {
			id = target,
			color = rgb(p, "7", "8", "9"),
			duration = num(p, "10", 0.5),
			opacity = num(p, "35", 1),
			blending = flag(p, "17"),
			pcol1 = flag(p, "15"),
			pcol2 = flag(p, "16"),
			copy_color = copied ~= nil,
			copy_channel_id = copied or 0,
			copy_opacity = flag(p, "60"),
		}
		applyHsv(data, p["49"])
		return data
	end)

	-- PulseTrigger2 is GD's pulse: an overlay on the channel with fade in, hold
	-- and fade out (absent keys are 0), instead of overwriting the channel colour.
	trigger(1006, "PulseTrigger2", function(p)
		if flag(p, "52") then
			return nil -- group pulses: DW only pulses colour channels
		end
		local target = channelId(num(p, "51", 0))
		if not target then
			return nil
		end
		local data = {
			channelId = target,
			color = rgb(p, "7", "8", "9"),
			fadeIn = num(p, "45", 0),
			hold = num(p, "46", 0),
			fadeOut = num(p, "47", 0),
			isExclusive = flag(p, "86"),
			pulseMode = 0,
			copiedChannelId = 0,
		}
		-- HSV mode shifts the copied channel; no copy id means the target itself.
		if flag(p, "48") then
			data.pulseMode = 1
			data.copiedChannelId = channelId(tonumber(p["50"])) or target
			applyHsv(data, p["49"])
		end
		return data
	end)

	trigger(901, "MoveTrigger", function(p)
		if flag(p, "100") or flag(p, "394") then
			return nil -- move-to-target / direction modes
		end
		local ease, rate = easing(p)
		return {
			moveX = num(p, "28", 0),
			moveY = num(p, "29", 0),
			lockX_player = flag(p, "58"),
			lockY_player = flag(p, "59"),
			lockX_camera = flag(p, "141"),
			lockY_camera = flag(p, "142"),
			small_step = flag(p, "393"),
			duration = num(p, "10", 0.5),
			easing = ease,
			easing_rate = rate,
			group_id = num(p, "51", 0),
		}
	end)

	trigger(1346, "RotateTrigger", function(p)
		if flag(p, "100") or flag(p, "394") then
			return nil -- aim / follow modes
		end
		local ease, rate = easing(p)
		return {
			degrees = num(p, "68", 0),
			x360 = num(p, "69", 0),
			duration = num(p, "10", 0.5),
			easing = ease,
			easing_rate = rate,
			group_id = num(p, "51", 0),
			center_id = num(p, "71", 0),
		}
	end)

	trigger(2067, "ScaleTrigger", function(p)
		local ease, rate = easing(p)
		return {
			scaleX = num(p, "150", 1),
			scaleY = num(p, "151", 1),
			divByX = flag(p, "153"),
			divByY = flag(p, "154"),
			duration = num(p, "10", 0.5),
			easing = ease,
			easing_rate = rate,
			group_id = num(p, "51", 0),
			center_id = num(p, "71", 0),
			onlyMove = flag(p, "133"),
		}
	end)

	trigger(1268, "SpawnTrigger", function(p)
		return { group_id = num(p, "51", 0), delay = num(p, "63", 0) }
	end)

	trigger(1049, "ToggleTrigger", function(p)
		return { group_id = num(p, "51", 0), activate_group = flag(p, "56") }
	end)

	trigger(1812, "OnDeathTrigger", function(p)
		return { group_id = num(p, "51", 0), activate_group = flag(p, "56") }
	end)

	trigger(1007, "AlphaTrigger", function(p)
		return { group_id = num(p, "51", 0), duration = num(p, "10", 0.5), opacity = num(p, "35", 1) }
	end)

	trigger(1520, "ShakeTrigger", function(p)
		return {
			shake_strength = num(p, "75", 0),
			shake_interval = num(p, "84", 0),
			shake_duration = num(p, "10", 0.5),
		}
	end)

	trigger(1347, "FollowTrigger", function(p)
		return {
			xMod = num(p, "72", 1),
			yMod = num(p, "73", 1),
			duration = num(p, "10", 0.5),
			group_id = num(p, "51", 0),
			follow_id = num(p, "71", 0),
		}
	end)

	trigger(1616, "StopTrigger", function(p)
		if flag(p, "535") then
			return nil -- control ids
		end
		-- GD 0 stop / 1 pause / 2 resume; DW default action 1 = stop
		return { group_id = num(p, "51", 0), action = num(p, "580", 0) + 1 }
	end)

	trigger(1913, "CameraZoomTrigger", function(p)
		local ease, rate = easing(p)
		return { zoom = num(p, "371", 1), duration = num(p, "10", 0.5), easing = ease, easing_rate = rate }
	end)

	trigger(2015, "CameraRotateTrigger", function(p)
		local ease, rate = easing(p)
		return {
			degrees = num(p, "68", 0),
			add = flag(p, "70"),
			snap360 = flag(p, "394"),
			duration = num(p, "10", 0.5),
			easing = ease,
			easing_rate = rate,
		}
	end)

	trigger(1916, "CameraOffsetTrigger", function(p)
		local ease, rate = easing(p)
		return {
			offsetX = num(p, "28", 0),
			offsetY = num(p, "29", 0),
			onlyAxis = num(p, "101", 0),
			duration = num(p, "10", 0.5),
			easing = ease,
			easing_rate = rate,
		}
	end)

	trigger(1914, "CameraStaticTrigger", function(p)
		local ease, rate = easing(p)
		return {
			exitStatic = flag(p, "110"),
			exitInstant = flag(p, "465"),
			onlyAxis = num(p, "101", 0),
			duration = num(p, "10", 0.5),
			easing = ease,
			easing_rate = rate,
			follow = flag(p, "212"),
			followEasing = num(p, "213", 1),
			smoothVelocity = flag(p, "453"),
			modifier = num(p, "454", 0),
			group_id = num(p, "71", 0),
		}
	end)

	trigger(2066, "GravityTrigger", function(p)
		-- DW applyType: 0 all players, 1/2 that player, 3 the player who touched it.
		local applyType = 0
		if flag(p, "201") then
			applyType = 3
		elseif flag(p, "138") then
			applyType = 1
		elseif flag(p, "200") then
			applyType = 2
		end
		return { gravity = num(p, "148", 1), applyType = applyType }
	end)

	trigger(3600, "EndTrigger", function(p)
		return {
			spawnId = num(p, "51", 0),
			targetId = num(p, "71", 0),
			noEffects = flag(p, "460"),
			noSfx = flag(p, "461"),
			instant = flag(p, "487"),
		}
	end)

	trigger(1912, "RandomTrigger", function(p)
		return { groupId1 = num(p, "51", 0), groupId2 = num(p, "71", 0), chance = num(p, "10", 50) }
	end)

	trigger(1935, "TimeWarpTrigger", function(p)
		return { timeMod = num(p, "120", 1) }
	end)

	trigger(1611, "CountTrigger", function(p)
		return {
			itemId = num(p, "80", 0),
			targetId = num(p, "51", 0),
			targetCount = num(p, "77", 0),
			activateGroup = flag(p, "56"),
			multiActivate = flag(p, "104"),
		}
	end)

	trigger(1811, "InstantCountTrigger", function(p)
		return {
			itemId = num(p, "80", 0),
			targetId = num(p, "51", 0),
			targetCount = num(p, "77", 0),
			activateGroup = flag(p, "56"),
			checkType = num(p, "88", 0),
		}
	end)

	trigger(1817, "PickupTrigger", function(p)
		return {
			itemId = num(p, "80", 0),
			count = num(p, "77", 0),
			addType = num(p, "88", 0),
			modifier = num(p, "449", 1),
			override = flag(p, "139"),
		}
	end)

	trigger(1595, "TouchTrigger", function(p)
		return {
			groupId = num(p, "51", 0),
			holdMode = flag(p, "81"),
			dualMode = flag(p, "89"),
			playerExclusivity = num(p, "198", 0),
			toggle = num(p, "82", 0),
		}
	end)

	trigger(32, "PlayerGhostTrailEnableTrigger", noData)
	trigger(33, "PlayerGhostTrailDisableTrigger", noData)
	trigger(1612, "PlayerHideTrigger", noData)
	trigger(1613, "PlayerShowTrigger", noData)
	trigger(1818, "BGEffectEnableTrigger", noData)
	trigger(1819, "BGEffectDisableTrigger", noData)

	trigger(2062, "CameraEdgeTrigger", function(p)
		return { direction = num(p, "164", 0), group_id = num(p, "51", 0) }
	end)

	local function forceBlock(p)
		return {
			force = num(p, "149", 0),
			maxforce = num(p, "527", 0),
			relative = flag(p, "528"),
			range = flag(p, "529"),
		}
	end
	trigger(2069, "ForceBlock01", forceBlock, true)
	trigger(3645, "ForceBlock02", forceBlock, true)

	trigger(2063, "PlatformerCheckpoint", function(p)
		return { respawnId = num(p, "448", 0) }
	end, true)

	-- Start positions keep their own level settings as kA keys in the object.
	trigger(31, "StartPos", function(p)
		local gamemode = tonumber(p.kA2)
		return {
			gamemode = gamemode and gamemode >= 0 and gamemode <= 7 and gamemode + 1 or 1,
			gameplay_speed = GD_SPEED_TO_DW[tonumber(p.kA4) or 0] or 2,
			is_mini = flag(p, "kA3"),
			is_dual = flag(p, "kA8"),
			flip_gravity = flag(p, "kA11"),
		}
	end, true)

	-- Dash orb settings live in __specialData (Block.SpecialData.OrbDash).
	local DASH_ORBS = { [1704] = true, [1751] = true }

	local resolvedCache = {}
	local forcedNoTouch = {}
	local useApproximate = true

	function gdlvl.setApproximate(enabled)
		useApproximate = enabled
		table.clear(resolvedCache)
		table.clear(forcedNoTouch)
	end

	-- Returns the DW toolbox id for a GD id, or nil plus a reason.
	local function resolve(gdId: number): (number?, string?)
		local cached = resolvedCache[gdId]
		if cached ~= nil then
			if cached == false then
				return nil, "rejected"
			end
			return cached
		end

		local entry = GD_TO_DW[gdId]
		if not entry or (entry.approx and not useApproximate) then
			return nil, "unmapped"
		end

		local toolboxId = Toolbox.nameIndexed[entry.name]
		local prefab = toolboxId and Block:GetPhysicalBlockFromToolboxId(toolboxId)
		local ok = prefab ~= nil
		local kind = entry.kind

		if ok and (kind == "solid" or kind == "hazard" or kind == "decor") then
			local isHazard = prefab:HasTag("Hazard")
			local isSolid = prefab:HasTag("Collidable")
			if kind == "solid" then
				ok = isSolid and not isHazard
			elseif kind == "hazard" then
				ok = isHazard
			else
				-- Decoration on a solid DW prefab stays, but must not collide.
				ok = not isHazard
				forcedNoTouch[gdId] = isSolid or nil
			end
		end

		if not ok then
			warn(string.format("[gdlvl] GD %d -> %s rejected (%s)", gdId, entry.name, prefab and "tag mismatch" or "no prefab"))
			resolvedCache[gdId] = false
			return nil, "rejected"
		end

		resolvedCache[gdId] = toolboxId
		return toolboxId
	end

	local SpecialData = require(LevelFolder.Block.SpecialData)

	-- The Block.SpecialData defaults of a prefab, if it has any.
	local function specialDefaults(prefab)
		local name = prefab:GetAttribute("SpecialData")
		return name and SpecialData[name] or nil
	end

	-- GD teleport keys -> Block.SpecialData.ObjectTeleport (HitboxFunctions.teleport).
	local TELEPORTS = { [747] = true, [2902] = true, [3027] = true }

	local function teleportData(p)
		return {
			group_id = num(p, "51", 0),
			save_offset = flag(p, "351"),
			instant_camera = flag(p, "464"),
			ignore_axis = flag(p, "352") and 1 or (flag(p, "353") and 2 or 0),
			gravity_change = num(p, "354", 0),
		}
	end

	-- GD object flags -> Block.__extraData names the game checks.
	local GD_EXTRA_FLAGS = {
		["135"] = "Hide",
		["121"] = "NoTouch",
		["134"] = "Passable",
		["103"] = "HighDetail",
		["137"] = "IceBlock",
		["193"] = "GripSlope",
		["96"] = "NoGlow",
		["507"] = "NoParticle",
		["372"] = "NoAudioScale",
		["116"] = "NoEffects",
	}

	-- GD draws by layer, then blending (below non-blending), then Z order, then
	-- placement. The player sits between B1 and T1. DW only has one number
	-- (SurfaceGui.ZOffset), so convertLevel ranks the objects by those rules.
	local GD_LAYERS = { B5 = -5, B4 = -3, B3 = -1, B2 = 1, B1 = 3, T1 = 5, T2 = 7, T3 = 9, T4 = 11 }

	local function zLayerAndOrder(p, toolboxId: number): (number, number)
		local prefab = Block:GetPhysicalBlockFromToolboxId(toolboxId)
		local layer = tonumber(p["24"])
		if not layer or layer == 0 then
			layer = prefab and GD_LAYERS[prefab:GetAttribute("DefaultZLayer")] or 5
		end
		local order = tonumber(p["25"])
		if not order then
			local default = prefab and prefab:GetAttribute("DefaultZOrder")
			order = type(default) == "number" and default or 0
		end
		return layer, order
	end

	-- GD keeps rotation in key 6, or per axis in keys 131 (X) and 132 (Y) for skewed
	-- objects. DW can't skew, so this takes the angle halfway between the axes; a Y axis
	-- about 180 degrees off is really a flip.
	local function gdRotation(p): (number, boolean)
		local rotationX, rotationY = tonumber(p["131"]), tonumber(p["132"])
		if not rotationX or not rotationY then
			return tonumber(p["6"]) or 0, false
		end
		local difference = (rotationY - rotationX + 180) % 360 - 180
		local flipped = math.abs(difference) > 90
		if flipped then
			difference += difference > 0 and -180 or 180
		end
		return rotationX + difference / 2, flipped
	end

	-- DW channel ids that blend. Level.new turns it on for L, P1 and P2 by default.
	local blendingChannels = {}

	-- DW has no per-object HSV, but a channel can copy another with an HSV shift.
	-- Each distinct colour + HSV pair gets its own channel, from 999 down.
	local hsvChannels, hsvList, usedChannels, nextHsvChannel = {}, {}, {}, 999

	local function hsvChannel(baseChannel, hsv: string?): number?
		if not hsv or hsv == "" then
			return nil
		end
		local cacheKey = tostring(baseChannel) .. "|" .. hsv
		local existing = hsvChannels[cacheKey]
		if existing then
			return existing
		end
		while usedChannels[nextHsvChannel] do
			nextHsvChannel -= 1
		end
		if nextHsvChannel < 1 then
			return nil
		end
		local id = nextHsvChannel
		nextHsvChannel -= 1
		hsvChannels[cacheKey] = id

		local fields = {
			copyColor = true,
			copiedChannelId = baseChannel,
			copyOpacity = true,
			blending = blendingChannels[baseChannel] == true,
		}
		applyHsv(fields, hsv)
		table.insert(hsvList, { key = id, fields = fields })
		return id
	end

	local function convertLevel(levelString: string)
		local segments = string.split(levelString, ";")
		local settings = {}
		local channels = {}
		local blocks = {}
		local stats = { total = 0, converted = 0, triggers = 0, unsupported = 0, unmapped = 0, rejected = 0 }
		local unmappedCounts = {}
		local unsupportedCounts = {}
		local rejectedCounts = {}
		local linkedPortals = 0
		local syntheticGroup = 0

		table.clear(hsvChannels)
		table.clear(hsvList)
		table.clear(usedChannels)
		nextHsvChannel = 999

		-- Channels the level itself uses are off limits for HSV copies.
		for i = 1, #segments do
			local p = parsePairs(segments[i], ",")
			for _, key in { "21", "22", "23", "50", "51" } do
				local value = tonumber(p[key])
				if value and value > 0 and value < 1000 and (key ~= "51" or p["1"] == "1006") then
					usedChannels[value] = true
				end
			end
			syntheticGroup = math.max(syntheticGroup, tonumber(p["33"]) or 0)
			for _, group in string.split(p["57"] or "", ".") do
				syntheticGroup = math.max(syntheticGroup, tonumber(group) or 0)
			end
			if i % 5000 == 0 then
				task.wait()
			end
		end

		table.clear(blendingChannels)
		for _, channelName in { "L", "P1", "P2" } do
			local resolved, channelNumber = pcall(ColorChannel.resolveNumberId, ColorChannel, channelName)
			if resolved and channelNumber then
				blendingChannels[channelNumber] = true
			end
		end
		local zEntries = {}

		local firstObject = 1
		if string.find(segments[1] or "", "k", 1, true) then
			firstObject = 2
			local header = parsePairs(segments[1], ",")

			local gamemode = tonumber(header.kA2)
			if gamemode and gamemode >= 0 and gamemode <= 7 then
				settings.gamemode = gamemode + 1
			end
			local speed = tonumber(header.kA4)
			if speed and GD_SPEED_TO_DW[speed] then
				settings.gameplaySpeed = GD_SPEED_TO_DW[speed]
			end
			settings.startMini = header.kA3 == "1"
			settings.dualMode = header.kA8 == "1"
			settings.twoPlayer = header.kA10 == "1"
			settings.flipGravity = header.kA11 == "1"
			settings.playMode = header.kA22 == "1" and 1 or 0
			settings.bgId = artId(Backgrounds, header.kA6)
			settings.gId = artId(Grounds, header.kA7)
			settings.lId = artId(Lines, header.kA17)
			-- 0 is no middleground in both games.
			local middleGround = tonumber(header.kA25) or 0
			settings.mgId = MiddleGrounds[middleGround] and middleGround or 0
			-- GD's font 0 is DW's first font, "bigFont"; font N is "fontN".
			local fontId = (tonumber(header.kA18) or 0) + 1
			settings.fontId = LevelFonts.fonts[fontId] and fontId or 1
			settings.songOffset = tonumber(header.kA13) or 0
			-- GD's key for this isn't confirmed yet. Don't inherit the replaced level's.
			settings.spawnGroup = 0
			channels = parseColorChannels(header.kS38)
			for _, channel in channels do
				local resolved, channelNumber = pcall(ColorChannel.resolveNumberId, ColorChannel, channel.key)
				if resolved and channelNumber then
					blendingChannels[channelNumber] = channel.fields.blending
				end
			end
		for _, channel in channels do
			if type(channel.key) == "number" then
				usedChannels[channel.key] = true
			end
		end
		end

		for i = firstObject, #segments do
			local segment = segments[i]
			if segment ~= "" then
				local p = parsePairs(segment, ",")
				local gdId = tonumber(p["1"])

				if gdId then
					stats.total += 1
					local toolboxId, reason = resolve(gdId)

					local triggerData
					local triggerInfo = TRIGGERS[gdId]
					if toolboxId and triggerInfo then
						triggerData = triggerInfo.convert(p)
						if triggerData then
							if not triggerInfo.noBasicOptions then
								triggerData.touch = flag(p, "11")
								triggerData.spawn = flag(p, "62")
								triggerData.multi = flag(p, "87")
							end
							stats.triggers += 1
						else
							toolboxId, reason = nil, "unsupported"
						end
					end

					if toolboxId then
						local uniformScale = tonumber(p["32"]) or 1
						local groupIds = {}
						local singleGroup = tonumber(p["33"])
						if singleGroup then
							groupIds[singleGroup] = false
						end
						if p["57"] then
							for _, group in string.split(p["57"], ".") do
								local groupId = tonumber(group)
								if groupId then
									groupIds[groupId] = false
								end
							end
						end
						-- Group parents are the centres of rotate / scale / follow /
						-- static camera triggers (Block:IsGroupParent checks == true).
						if p["34"] == "1" and not p["274"] then
							for groupId in groupIds do
								groupIds[groupId] = true
							end
						elseif p["274"] then
							for _, group in string.split(p["274"], ".") do
								local groupId = tonumber(group)
								if groupId then
									groupIds[groupId] = true
								end
							end
						end

						local gdAngle, axisFlip = gdRotation(p)
						local block = {
							toolbox_id = toolboxId,
							position = Vector3.new((tonumber(p["2"]) or 0) / 30 - 0.5, (tonumber(p["3"]) or 0) / 30 - 0.5, 0),
							-- GD rotation is clockwise, CFrame.Angles about Z is counter-clockwise.
							rotation = (-gdAngle) % 360,
							scaleX = tonumber(p["128"]) or uniformScale,
							scaleY = tonumber(p["129"]) or uniformScale,
							flipX = p["4"] == "1" and -1 or 1,
							flipY = (p["5"] == "1") ~= axisFlip and -1 or 1,
							editor_layer = tonumber(p["20"]) or 0,
							group_ids = groupIds,
							triggerData = triggerData,
						}

						local prefab = Block:GetPhysicalBlockFromToolboxId(toolboxId)
						local baseColor = channelId(tonumber(p["21"]))
						local baseChannel = baseColor or prefab:GetAttribute("BaseColorId") or 1000
						if flag(p, "41") then
							baseColor = hsvChannel(baseChannel, p["43"]) or baseColor
						end
						if baseColor then
							block.basecolor_id = baseColor
						end
						local detailColor = channelId(tonumber(p["22"]))
						if flag(p, "42") then
							detailColor = hsvChannel(detailColor or prefab:GetAttribute("DetailColorId") or 1, p["44"]) or detailColor
						end
						if detailColor then
							block.detailcolor_id = detailColor
						end

						local extraData = {}
						for key, extraName in GD_EXTRA_FLAGS do
							if p[key] == "1" then
								extraData[extraName] = true
							end
						end
						if forcedNoTouch[gdId] then
							extraData.NoTouch = true
							extraData.NoGlow = true
						end
						local mapping = GD_TO_DW[gdId]
						if mapping and mapping.noAudioScale then
							extraData.NoAudioScale = true
						end
						block.__extraData = extraData

						if gdId == 1594 then
							block.__specialData = {
								group_id = num(p, "51", 0),
								activate_group = flag(p, "56"),
								claim_touch = flag(p, "445"),
								spawn_only = flag(p, "504"),
								multi = flag(p, "99"),
							}
						elseif gdId == 914 and p["31"] then
							local textOk, text = pcall(function()
								local textBuffer, textLength = base64Decode(p["31"])
								return buffer.readstring(textBuffer, 0, textLength)
							end)
							if textOk then
								block.__specialData = { text = text }
							end
						end

						if DASH_ORBS[gdId] then
							block.__specialData = {
								speed = num(p, "586", 1),
								end_boost = num(p, "588", 1),
								max_duration = num(p, "590", 0),
								allow_collide = flag(p, "587"),
								stop_slide = flag(p, "589"),
							}
						end

						if TELEPORTS[gdId] then
							block.__specialData = teleportData(p)
						end

						local defaults = specialDefaults(prefab)
						if defaults then
							block.__specialData = block.__specialData or {}
							-- Orbs, pads and portals: the game inverts "multi" in
							-- platformer, like GD's separate no-multi key there.
							if defaults.multi ~= nil then
								block.__specialData.multi = flag(p, settings.playMode == 1 and "444" or "99")
							end
							if defaults.rotation_speed ~= nil and (p["97"] or p["98"]) then
								block.__specialData.rotation_speed = flag(p, "98") and 0 or num(p, "97", defaults.rotation_speed)
							end
							if gdId >= 1835 and gdId <= 1838 then
								block.__specialData.rotation_speed = 0
							end
						end

						table.insert(blocks, block)
						stats.converted += 1

						local zLayer, zSortOrder = zLayerAndOrder(p, toolboxId)
						local blends = blendingChannels[baseChannel] == true
						table.insert(zEntries, { block = block, layer = zLayer, order = zSortOrder, blends = blends, index = #zEntries })

						-- Linked portals are one GD object but two DW objects. The exit
						-- is also the entrance's target group, which teleport() falls
						-- back to when the Linker has no pair.
						local exitToolboxId = gdId == 747 and Toolbox.nameIndexed.PortalTeleportB
						if exitToolboxId and Block:GetPhysicalBlockFromToolboxId(exitToolboxId) then
							linkedPortals += 1
							syntheticGroup += 1
							block.pairGroup = linkedPortals
							block.__specialData.group_id = syntheticGroup
							table.insert(blocks, {
								toolbox_id = exitToolboxId,
								position = block.position + Vector3.new(0, num(p, "54", 100) / 30, 0),
								rotation = block.rotation,
								scaleX = block.scaleX,
								scaleY = block.scaleY,
								flipX = block.flipX,
								flipY = block.flipY,
								editor_layer = block.editor_layer,
								group_ids = { [syntheticGroup] = true },
								pairGroup = linkedPortals,
							})
							table.insert(zEntries, { block = blocks[#blocks], layer = zLayer, order = zSortOrder, blends = blends, index = #zEntries })
						end
					elseif reason == "rejected" then
						stats.rejected += 1
						rejectedCounts[gdId] = (rejectedCounts[gdId] or 0) + 1
					elseif reason == "unsupported" then
						stats.unsupported += 1
						unsupportedCounts[gdId] = (unsupportedCounts[gdId] or 0) + 1
					else
						stats.unmapped += 1
						unmappedCounts[gdId] = (unmappedCounts[gdId] or 0) + 1
					end
				end
			end

			if i % 5000 == 0 then
				task.wait()
			end
		end

		-- One unique zorder per object. Placement order can't be left to DW's tie-break:
		-- Level:getLevelData saves from GameObjects, keyed by instance, which loses it.
		table.sort(zEntries, function(a, b)
			if a.layer ~= b.layer then
				return a.layer < b.layer
			end
			if a.blends ~= b.blends then
				return a.blends
			end
			if a.order ~= b.order then
				return a.order < b.order
			end
			return a.index < b.index
		end)
		local belowPlayer = 0
		for _, entry in zEntries do
			if entry.layer < GD_LAYERS.T1 then
				belowPlayer += 1
			end
		end
		-- The players use 0 and 1, the wave trail -1 and -2.
		local nextZ = -2 - belowPlayer
		for _, entry in zEntries do
			if entry.layer >= GD_LAYERS.T1 and nextZ < 2 then
				nextZ = 2
			end
			entry.block.zorder = nextZ
			nextZ += 1
		end

		local unmappedList = {}
		for gdId, count in unmappedCounts do
			table.insert(unmappedList, { gdId, count })
		end
		table.sort(unmappedList, function(a, b)
			return a[2] > b[2]
		end)
		stats.topUnmapped = unmappedList
		stats.unsupportedCounts = unsupportedCounts
		stats.rejectedCounts = rejectedCounts
		for _, channel in hsvList do
			table.insert(channels, channel)
		end
		stats.channels = #channels

		return settings, channels, blocks, stats
	end

	gdlvl.export = (function()
		------------------------------------------------------------------------
		-- gzip (stored, i.e. uncompressed, deflate blocks) and base64url
		------------------------------------------------------------------------

		local crcTable = {}
		for i = 0, 255 do
			local value = i
			for _ = 1, 8 do
				if bit32.band(value, 1) == 1 then
					value = bit32.bxor(0xEDB88320, bit32.rshift(value, 1))
				else
					value = bit32.rshift(value, 1)
				end
			end
			crcTable[i] = value
		end

		local function crc32(data: string): number
			local crc = 0xFFFFFFFF
			for i = 1, #data do
				crc = bit32.bxor(crcTable[bit32.band(bit32.bxor(crc, string.byte(data, i)), 255)], bit32.rshift(crc, 8))
				if i % 500000 == 0 then
					task.wait()
				end
			end
			return bit32.bxor(crc, 0xFFFFFFFF)
		end

		local function gzip(data: string): string
			local parts = { "\31\139\8\0\0\0\0\0\0\255" }
			local position = 1
			repeat
				local length = math.min(65535, #data - position + 1)
				local final = position + length > #data
				table.insert(parts, string.pack("<BI2I2", final and 1 or 0, length, bit32.bxor(length, 0xFFFF)))
				table.insert(parts, string.sub(data, position, position + length - 1))
				position += length
			until final
			table.insert(parts, string.pack("<I4I4", crc32(data), #data % 4294967296))
			return table.concat(parts)
		end

		local BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

		local function base64Encode(data: string): string
			local out = buffer.create(math.ceil(#data / 3) * 4)
			local outPosition = 0
			for i = 1, #data, 3 do
				local a, b, c = string.byte(data, i, i + 2)
				local triple = a * 65536 + (b or 0) * 256 + (c or 0)
				buffer.writeu8(out, outPosition, string.byte(BASE64_CHARS, bit32.rshift(triple, 18) + 1))
				buffer.writeu8(out, outPosition + 1, string.byte(BASE64_CHARS, bit32.band(bit32.rshift(triple, 12), 63) + 1))
				buffer.writeu8(out, outPosition + 2, b and string.byte(BASE64_CHARS, bit32.band(bit32.rshift(triple, 6), 63) + 1) or 61)
				buffer.writeu8(out, outPosition + 3, c and string.byte(BASE64_CHARS, bit32.band(triple, 63) + 1) or 61)
				outPosition += 4
				if i % 600000 == 1 and i > 1 then
					task.wait()
				end
			end
			return buffer.tostring(out)
		end

		------------------------------------------------------------------------
		-- Dash World -> GD values
		------------------------------------------------------------------------

		local GD_CHANNEL_BY_NAME = {}
		for gdId, channelName in GD_SPECIAL_CHANNELS do
			GD_CHANNEL_BY_NAME[channelName] = gdId
		end

		local GD_SPEED_BY_DW = {}
		for gdSpeed, dwSpeed in GD_SPEED_TO_DW do
			GD_SPEED_BY_DW[dwSpeed] = gdSpeed
		end

		local function gdChannel(dwChannel)
			if dwChannel == nil or dwChannel == 0 then
				return nil
			end
			local key = ColorChannel:resolveChannelId(dwChannel)
			if type(key) == "string" then
				return GD_CHANNEL_BY_NAME[key]
			end
			return key
		end

		local function formatNumber(value: number): string
			if value == math.floor(value) and math.abs(value) < 1e15 then
				return string.format("%d", value)
			end
			local text = string.gsub(string.format("%.4f", value), "0+$", "")
			return (string.gsub(text, "%.$", ""))
		end

		local function hsvString(data): string
			return string.format("%sa%sa%sa%da%d",
				formatNumber(data.hue or 0), formatNumber(data.saturation or 1), formatNumber(data.brightness or 1),
				data.useAdditiveSaturation and 1 or 0,
				data.useAdditiveBrightness and 1 or 0)
		end

		-- The lowest GD id for each DW object, exact matches first. Hazards take
		-- the highest id instead: those are GD's colorable versions.
		local gdIdByName = nil

		-- DW objects with no hitbox whose only GD match is solid: exported as No Touch.
		local NON_SOLID_EXPORTS = {
			LightGridBlock01 = 247, LightGridBlock02 = 248, LightGridBlock03 = 249, LightGridBlock04 = 250,
			LightGridBlock06 = 252, LightGridBlock07 = 253, LightGridBlock08 = 254,
			WhiteSlope01 = 331, WhiteSlope02 = 333, WhiteTileSlope01 = 343, WhiteTileSlope02 = 345,
		}

		local function gdIdForName(name: string): number?
			if not gdIdByName then
				gdIdByName = {}
				local best = {}
				for gdId, entry in GD_TO_DW do
					local current = best[entry.name]
					local better = not current
					if current then
						if (entry.approx == true) ~= (current.approx == true) then
							better = not entry.approx
						elseif entry.kind == "hazard" then
							better = gdId > gdIdByName[entry.name]
						else
							better = gdId < gdIdByName[entry.name]
						end
					end
					if better then
						best[entry.name] = entry
						gdIdByName[entry.name] = gdId
					end
				end
				-- DW objects the importer no longer produces, or only as a pair.
				gdIdByName.PulseTrigger = 1006
				gdIdByName.PortalTeleportB = 2064
				-- Solid DW objects whose closest GD object the importer maps elsewhere.
				gdIdByName.DW1Step01 = 40
				for dwName, nonSolidGdId in NON_SOLID_EXPORTS do
					gdIdByName[dwName] = nonSolidGdId
				end
			end
			return gdIdByName[name]
		end

		local function makeWriter(parts)
			return function(key, value)
				if value == nil or value == false then
					return
				end
				table.insert(parts, tostring(key))
				if value == true then
					table.insert(parts, "1")
				elseif type(value) == "number" then
					table.insert(parts, formatNumber(value))
				else
					table.insert(parts, tostring(value))
				end
			end
		end

		local function writeColor(write, color)
			if typeof(color) == "Color3" then
				write(7, math.round(color.R * 255))
				write(8, math.round(color.G * 255))
				write(9, math.round(color.B * 255))
			end
		end

		local function writeEasing(write, data)
			write(30, (data.easing or 1) - 1)
			write(85, data.easing_rate)
		end

		------------------------------------------------------------------------
		-- Triggers: the reverse of the import converters (DW triggerData -> keys)
		------------------------------------------------------------------------

		local function writeGroupToggle(write, d)
			write(51, d.group_id)
			write(56, d.activate_group)
		end

		local TRIGGER_WRITERS = {
			ColorTrigger = function(write, d)
				write(23, gdChannel(d.id))
				writeColor(write, d.color)
				write(10, d.duration)
				write(35, d.opacity)
				write(17, d.blending)
				write(15, d.pcol1)
				write(16, d.pcol2)
				if d.copy_color then
					write(50, gdChannel(d.copy_channel_id))
					write(49, hsvString(d))
					write(60, d.copy_opacity)
				end
			end,
			PulseTrigger = function(write, d)
				write(51, gdChannel(d.id))
				writeColor(write, d.color)
				write(45, d.fadein)
				write(46, d.hold)
				write(47, d.fadeout)
				if d.copy_color then
					write(48, true)
					write(50, gdChannel(d.copy_channel_id))
					write(49, hsvString(d))
				end
			end,
			PulseTrigger2 = function(write, d)
				write(51, gdChannel(d.channelId))
				writeColor(write, d.color)
				write(45, d.fadeIn)
				write(46, d.hold)
				write(47, d.fadeOut)
				write(86, d.isExclusive)
				if d.pulseMode ~= 0 then
					write(48, true)
					write(50, gdChannel(d.copiedChannelId))
					write(49, hsvString(d))
				end
			end,
			MoveTrigger = function(write, d)
				write(10, d.duration)
				write(28, d.moveX)
				write(29, d.moveY)
				writeEasing(write, d)
				write(51, d.group_id)
				write(58, d.lockX_player)
				write(59, d.lockY_player)
				write(141, d.lockX_camera)
				write(142, d.lockY_camera)
				write(393, d.small_step)
			end,
			RotateTrigger = function(write, d)
				write(10, d.duration)
				write(68, d.degrees)
				write(69, d.x360)
				writeEasing(write, d)
				write(51, d.group_id)
				write(71, d.center_id)
			end,
			ScaleTrigger = function(write, d)
				write(10, d.duration)
				write(150, d.scaleX)
				write(151, d.scaleY)
				write(153, d.divByX)
				write(154, d.divByY)
				writeEasing(write, d)
				write(51, d.group_id)
				write(71, d.center_id)
				write(133, d.onlyMove)
			end,
			SpawnTrigger = function(write, d)
				write(51, d.group_id)
				write(63, d.delay)
			end,
			ToggleTrigger = writeGroupToggle,
			OnDeathTrigger = writeGroupToggle,
			AlphaTrigger = function(write, d)
				write(51, d.group_id)
				write(10, d.duration)
				write(35, d.opacity)
			end,
			ShakeTrigger = function(write, d)
				write(75, d.shake_strength)
				write(84, d.shake_interval)
				write(10, d.shake_duration)
			end,
			FollowTrigger = function(write, d)
				write(72, d.xMod)
				write(73, d.yMod)
				write(10, d.duration)
				write(51, d.group_id)
				write(71, d.follow_id)
			end,
			StopTrigger = function(write, d)
				write(51, d.group_id)
				write(580, (d.action or 1) - 1)
			end,
			CameraZoomTrigger = function(write, d)
				write(371, d.zoom)
				write(10, d.duration)
				writeEasing(write, d)
			end,
			CameraRotateTrigger = function(write, d)
				write(68, d.degrees)
				write(70, d.add)
				write(394, d.snap360)
				write(10, d.duration)
				writeEasing(write, d)
			end,
			CameraOffsetTrigger = function(write, d)
				write(28, d.offsetX)
				write(29, d.offsetY)
				write(101, d.onlyAxis)
				write(10, d.duration)
				writeEasing(write, d)
			end,
			CameraStaticTrigger = function(write, d)
				write(110, d.exitStatic)
				write(465, d.exitInstant)
				write(101, d.onlyAxis)
				write(10, d.duration)
				writeEasing(write, d)
				write(212, d.follow)
				write(213, d.followEasing)
				write(453, d.smoothVelocity)
				write(454, d.modifier)
				write(71, d.group_id)
			end,
			CameraEdgeTrigger = function(write, d)
				write(164, d.direction)
				write(51, d.group_id)
			end,
			GravityTrigger = function(write, d)
				write(148, d.gravity)
				write(201, d.applyType == 3)
				write(138, d.applyType == 1)
				write(200, d.applyType == 2)
			end,
			EndTrigger = function(write, d)
				write(51, d.spawnId)
				write(71, d.targetId)
				write(460, d.noEffects)
				write(461, d.noSfx)
				write(487, d.instant)
			end,
			RandomTrigger = function(write, d)
				write(51, d.groupId1)
				write(71, d.groupId2)
				write(10, d.chance)
			end,
			TimeWarpTrigger = function(write, d)
				write(120, d.timeMod)
			end,
			CountTrigger = function(write, d)
				write(80, d.itemId)
				write(51, d.targetId)
				write(77, d.targetCount)
				write(56, d.activateGroup)
				write(104, d.multiActivate)
			end,
			InstantCountTrigger = function(write, d)
				write(80, d.itemId)
				write(51, d.targetId)
				write(77, d.targetCount)
				write(56, d.activateGroup)
				write(88, d.checkType)
			end,
			PickupTrigger = function(write, d)
				write(80, d.itemId)
				write(77, d.count)
				write(88, d.addType)
				write(449, d.modifier)
				write(139, d.override)
			end,
			TouchTrigger = function(write, d)
				write(51, d.groupId)
				write(81, d.holdMode)
				write(89, d.dualMode)
				write(198, d.playerExclusivity)
				write(82, d.toggle)
			end,
			ForceBlock01 = function(write, d)
				write(149, d.force)
				write(527, d.maxforce)
				write(528, d.relative)
				write(529, d.range)
			end,
			PlatformerCheckpoint = function(write, d)
				write(448, d.respawnId)
			end,
			StartPos = function(write, d)
				write("kA2", (d.gamemode or 1) - 1)
				write("kA4", GD_SPEED_BY_DW[d.gameplay_speed or 2] or 0)
				write("kA3", d.is_mini)
				write("kA8", d.is_dual)
				write("kA11", d.flip_gravity)
			end,
		}
		TRIGGER_WRITERS.ForceBlock02 = TRIGGER_WRITERS.ForceBlock01

		-- Triggers with no fields of their own.
		local EMPTY_TRIGGERS = {
			PlayerGhostTrailEnableTrigger = true, PlayerGhostTrailDisableTrigger = true,
			PlayerHideTrigger = true, PlayerShowTrigger = true,
			BGEffectEnableTrigger = true, BGEffectDisableTrigger = true,
		}

		local function writeSpecial(write, name, special, isPlatformer)
			if name == "OrbDash" or name == "OrbDashGravity" then
				write(586, special.speed)
				write(588, special.end_boost)
				write(590, special.max_duration)
				write(587, special.allow_collide)
				write(589, special.stop_slide)
			elseif name == "OrbCustom" then
				write(51, special.group_id)
				write(56, special.activate_group)
				write(445, special.claim_touch)
				write(504, special.spawn_only)
			elseif name == "OrbTeleport" or name == "PortalTeleportA" or name == "PortalTeleportSA" then
				write(51, special.group_id)
				write(351, special.save_offset)
				write(464, special.instant_camera)
				write(352, special.ignore_axis == 1)
				write(353, special.ignore_axis == 2)
				write(354, special.gravity_change)
			elseif name == "TextObject" and type(special.text) == "string" then
				write(31, base64Encode(special.text))
			end
			if special.multi then
				write(isPlatformer and 444 or 99, true)
			end
			if special.rotation_speed == 0 then
				write(98, true)
			elseif special.rotation_speed ~= nil and special.rotation_speed ~= 360 then
				write(97, special.rotation_speed)
			end
		end

		-- GD draws by Z layer, then tileset, then blending, then Z order, then placement:
		-- inside one layer the tileset and blending outrank Z order. DW only has its one
		-- number, so its values are spread over GD's layers, the same object count in
		-- each, which keeps objects that are far apart in DW in the right order.
		-- The players are at 0 and 1, so anything from 0 up covers P1.
		local BELOW_PLAYER, ABOVE_PLAYER = { -5, -3, -1, 1, 3 }, { 5, 7, 9, 11 }
		local exportSlots = {}

		local function spreadOverLayers(zValues, zCounts, layers, firstLayer)
			table.sort(zValues)
			local remaining = 0
			for _, z in zValues do
				remaining += zCounts[z]
			end
			local layer, inLayer, order = firstLayer, 0, 0
			local target = remaining / (#layers - layer + 1)
			for i, z in zValues do
				local layersLeft = #layers - layer
				local valuesLeft = #zValues - i + 1
				if inLayer > 0 and layersLeft > 0 and (valuesLeft <= layersLeft or inLayer + zCounts[z] / 2 > target) then
					layer += 1
					inLayer, order = 0, 0
					target = remaining / (#layers - layer + 1)
				end
				-- GD reads Z order 0 as "the object's default", so it starts at 1.
				order += 1
				exportSlots[z] = { layer = layers[layer], order = math.min(order, 999) }
				inLayer += zCounts[z]
				remaining -= zCounts[z]
			end
		end

		local function buildExportSlots(blocks)
			table.clear(exportSlots)
			local below, above, zCounts = {}, {}, {}
			for _, block in blocks do
				local z = math.round(block.zorder or 0)
				if not zCounts[z] then
					zCounts[z] = 0
					table.insert(z < 0 and below or above, z)
				end
				zCounts[z] += 1
			end
			-- With few values, stay on the layers next to the player.
			spreadOverLayers(below, zCounts, BELOW_PLAYER, math.max(1, #BELOW_PLAYER - #below + 1))
			spreadOverLayers(above, zCounts, ABOVE_PLAYER, 1)
		end

		local function writeZOrder(write, zorder)
			local slot = exportSlots[math.round(zorder or 0)]
			write(24, slot.layer)
			write(25, slot.order)
		end

		local function exportBlock(block, isPlatformer, portalExits)
			local name = Toolbox.idIndexed[block.toolbox_id]
			local gdId = name and gdIdForName(name)
			if not gdId then
				return nil, name or ("toolbox " .. tostring(block.toolbox_id))
			end

			local parts = {}
			local write = makeWriter(parts)
			local pairedExit = name == "PortalTeleportA" and portalExits[block.pairGroup]

			write(1, gdId)
			write(2, (block.position.X + 0.5) * 30)
			write(3, (block.position.Y + 0.5) * 30)
			write(4, block.flipX == -1)
			write(5, block.flipY == -1)
			local rotation = (-(block.rotation or 0)) % 360
			if rotation ~= 0 then
				write(6, rotation)
			end
			if (block.scaleX or 1) ~= 1 then
				write(128, block.scaleX)
			end
			if (block.scaleY or 1) ~= 1 then
				write(129, block.scaleY)
			end
			if (block.editor_layer or 0) ~= 0 then
				write(20, block.editor_layer)
			end
			writeZOrder(write, block.zorder)

			local prefab = Block:GetPhysicalBlockFromToolboxId(block.toolbox_id)
			if prefab then
				if block.basecolor_id ~= (prefab:GetAttribute("BaseColorId") or 1000) then
					write(21, gdChannel(block.basecolor_id))
				end
				if block.detailcolor_id ~= (prefab:GetAttribute("DetailColorId") or 1) then
					write(22, gdChannel(block.detailcolor_id))
				end
			end

			local groups, parents = {}, {}
			for groupId, isParent in block.group_ids or {} do
				table.insert(groups, groupId)
				if isParent == true then
					table.insert(parents, groupId)
				end
			end
			if #groups > 0 then
				table.sort(groups)
				write(57, table.concat(groups, "."))
			end
			if #parents > 0 then
				table.sort(parents)
				write(274, table.concat(parents, "."))
			end

			if NON_SOLID_EXPORTS[name] and not (block.__extraData and block.__extraData.NoTouch == true) then
				write(121, true)
			end
			for key, extraName in GD_EXTRA_FLAGS do
				if block.__extraData and block.__extraData[extraName] == true then
					write(key, true)
				end
			end

			local data = block.triggerData
			local writer = TRIGGER_WRITERS[name]
			local isTrigger = writer ~= nil or EMPTY_TRIGGERS[name] == true
			if isTrigger then
				write(36, name ~= "StartPos")
				if writer then
					writer(write, data or {})
				end
				if data then
					write(11, data.touch)
					write(62, data.spawn)
					write(87, data.multi)
				end
			elseif data and next(data) ~= nil and TRIGGERS[gdId] then
				return nil, name
			end

			local special = table.clone(block.__specialData or {})
			if pairedExit then
				special.group_id = nil
			end
			writeSpecial(write, name, special, isPlatformer)

			if pairedExit then
				write(54, (pairedExit.position.Y - block.position.Y) * 30)
			end

			return table.concat(parts, ","), nil
		end

		local function exportChannels(channels): string
			local parts = {}
			for key, channel in channels or {} do
				local gdId = gdChannel(key)
				if gdId and typeof(channel.color) == "Color3" then
					local fields = {
						"1", math.round(channel.color.R * 255),
						"2", math.round(channel.color.G * 255),
						"3", math.round(channel.color.B * 255),
						"11", 255, "12", 255, "13", 255,
						"4", channel.pCol1 and 1 or (channel.pCol2 and 2 or -1),
						"6", gdId,
						"5", channel.blending and 1 or 0,
						"7", formatNumber(channel.opacity or 1),
						"8", 1, "15", 1, "18", 0,
					}
					local copied = channel.copyColor and gdChannel(channel.copiedChannelId)
					if copied then
						table.insert(fields, "9")
						table.insert(fields, copied)
						table.insert(fields, "10")
						table.insert(fields, hsvString(channel))
						table.insert(fields, "17")
						table.insert(fields, channel.copyOpacity and 1 or 0)
					end
					table.insert(parts, table.concat(fields, "_"))
				end
			end
			return table.concat(parts, "|") .. (#parts > 0 and "|" or "")
		end

		local function exportHeader(settings): string
			local function bool(value)
				return value and "1" or "0"
			end
			return table.concat({
				"kS38", exportChannels(settings.colorChannels),
				"kA13", tostring(settings.songOffset or 0), "kA15", "0", "kA16", "0", "kA14", "",
				"kA6", tostring(settings.bgId or 1), "kA7", tostring(settings.gId or 1),
				"kA25", tostring(settings.mgId or 0), "kA17", tostring(settings.lId or 1),
				"kA18", tostring((settings.fontId or 1) - 1),
				"kA2", tostring((settings.gamemode or 1) - 1),
				"kA3", bool(settings.startMini),
				"kA8", bool(settings.dualMode),
				"kA4", tostring(GD_SPEED_BY_DW[settings.gameplaySpeed or 2] or 0),
				"kA10", bool(settings.twoPlayer),
				"kA22", bool(settings.playMode == 1),
				"kA11", bool(settings.flipGravity),
			}, ",")
		end

		local function escapeXml(text: string): string
			text = string.gsub(text, "&", "&amp;")
			text = string.gsub(text, "<", "&lt;")
			text = string.gsub(text, ">", "&gt;")
			return text
		end

		------------------------------------------------------------------------
		-- gdlvl.export(level, name) -> file text, stats
		------------------------------------------------------------------------

		return function(level, levelName: string)
			assert(crc32("123456789") == 0xCBF43926, "CRC32 self-test failed")

			-- The originals are untouched by triggers; the editor edits GameObjects.
			local source = level.OriginalGameObjects
			if level.__is_editing or not source or next(source) == nil then
				source = level.GameObjects
			end
			local settings = level.__is_editing and level.levelSettings or level.OriginalLevelSettings or level.levelSettings
			local isPlatformer = settings.playMode == 1

			local blocks, portalExits = {}, {}
			local exitToolboxId = Toolbox.nameIndexed.PortalTeleportB
			for _, block in source do
				table.insert(blocks, block)
				if block.toolbox_id == exitToolboxId and (block.pairGroup or 0) ~= 0 then
					portalExits[block.pairGroup] = block
				end
			end
			-- File order is GD's placement order, so it follows DW's draw order: zorder,
			-- then the tie-break Level:buildFromObjectData stored in load order.
			local function tieBreak(block)
				return block.__values and block.__values._zOffset or 0
			end
			table.sort(blocks, function(a, b)
				local zA, zB = math.round(a.zorder or 0), math.round(b.zorder or 0)
				if zA ~= zB then
					return zA < zB
				end
				local tieA, tieB = tieBreak(a), tieBreak(b)
				if tieA ~= tieB then
					return tieA < tieB
				end
				return a.position.X < b.position.X
			end)

			local objects = {}
			local skipped = {}
			local stats = { total = #blocks, exported = 0, skipped = 0, pairedExits = 0 }

			buildExportSlots(blocks)
			for index, block in blocks do
				-- A paired exit is written as part of its GD linked portal.
				if block.toolbox_id == exitToolboxId and portalExits[block.pairGroup] == block then
					stats.pairedExits += 1
				else
					local text, skippedName = exportBlock(block, isPlatformer, portalExits)
					if text then
						table.insert(objects, text)
						stats.exported += 1
					else
						stats.skipped += 1
						skipped[skippedName] = (skipped[skippedName] or 0) + 1
					end
				end
				if index % 3000 == 0 then
					task.wait()
				end
			end

			stats.skippedObjects = {}
			for name, count in skipped do
				table.insert(stats.skippedObjects, { name = name, count = count })
			end
			table.sort(stats.skippedObjects, function(a, b)
				return a.count > b.count
			end)

			local levelString = exportHeader(settings) .. ";" .. table.concat(objects, ";") .. ";"
			local xml = table.concat({
				'<?xml version="1.0"?><plist version="1.0" gjver="2.0"><dict>',
				"<k>kCEK</k><i>4</i>",
				"<k>k2</k><s>", escapeXml(levelName), "</s>",
				"<k>k4</k><s>", base64Encode(gzip(levelString)), "</s>",
				"<k>k101</k><s>0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0</s>",
				"<k>k13</k><t />",
				"<k>k21</k><i>2</i>",
				"<k>k50</k><i>51</i>",
				"<k>k48</k><i>", tostring(#objects), "</i>",
				"</dict></plist>",
			})
			local fileText = base64Encode(gzip(xml))

			-- Read it back with the importer's own decoder before trusting it.
			local _, readBack = readGdlvl(fileText)
			assert(readBack == levelString, "the exported file did not read back correctly")

			return fileText, stats
		end
	end)()

	gdlvl.read = readGdlvl
	gdlvl.convert = convertLevel
	gdlvl.trim = trim
end

hook(LevelScene, "onActivated", function(original)
	return function(self, ...)
		levelSceneLoads += 1
		local results = table.pack(pcall(original, self, ...))
		levelSceneLoads -= 1
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end
end)

hook(Level, "LoadFromLevelData", function(original)
	return function(self, info, ...)
		local pending = pendingImport
		if not pending or levelSceneLoads > 0 then
			return original(self, info, ...)
		end
		pendingImport = nil

		local patched = typeof(info) == "table" and table.clone(info) or {}
		patched.data = IMPORT_SENTINEL

		-- Overlay the GD colour channels on this level's current channels;
		-- setColorChannelData resolves the channel and type-checks every field.
		-- They must be in the settings: applyLevelSettings snapshots those for Reset.
		local settings = table.clone(pending.settings)
		if #pending.channels > 0 then
			local current = type(self.levelSettings) == "table" and self.levelSettings.colorChannels or {}
			local target = { colorChannels = Utility:deepCopy(current) }
			for _, channel in pending.channels do
				local channelOk, channelErr = pcall(self.setColorChannelData, self, channel.key, channel.fields, nil, target)
				if not channelOk then
					warn("[gdlvl] colour channel " .. tostring(channel.key) .. ": " .. tostring(channelErr))
				end
			end
			settings.colorChannels = target.colorChannels
		end

		local originalParserLoad = Parser.LoadLevelData
		Parser.LoadLevelData = function(parser, data, ...)
			if data == IMPORT_SENTINEL then
				return settings, pending.blocks, 3
			end
			return originalParserLoad(parser, data, ...)
		end
		local ok, err = pcall(original, self, patched, ...)
		Parser.LoadLevelData = originalParserLoad

		if not ok then
			warn("[gdlvl] Loading the imported level failed: " .. tostring(err))
			setImportStatus("Import failed while loading: " .. tostring(err))
			queueNotify("Loading the imported level failed, see console", "error")
			error(err, 0)
		end

		-- The editor flag is set by its scene, possibly after loading, so check
		-- shortly afterwards. Anything else (not the editor) -> stay armed.
		task.delay(1, function()
			if self.__is_editor == true then
				setImportStatus(string.format("Imported \"%s\" into the editor. Press Save in the editor to keep it.", pending.name))
				queueNotify("Level imported into the editor. Save it to keep it.", "success")
			elseif running and pendingImport == nil and not pending.cancelled then
				pendingImport = pending
				setImportStatus(string.format("\"%s\" is still armed. Open a custom level in the editor.", pending.name))
			end
		end)
	end
end)

local function scanImportFiles()
	local found, seen = {}, {}
	if type(listfiles) ~= "function" then
		return found
	end
	pcall(function()
		if not isfolder(IMPORT_FOLDER) then
			makefolder(IMPORT_FOLDER)
		end
	end)
	for _, folder in { IMPORT_FOLDER, "" } do
		local ok, files = pcall(listfiles, folder)
		if ok and type(files) == "table" then
			for _, path in files do
				if string.match(string.lower(path), "%.gdlvl$") and not seen[path] then
					seen[path] = true
					table.insert(found, path)
				end
			end
		end
	end
	table.sort(found)
	return found
end

--------------------------------------------------------------------------------
-- Unload
--------------------------------------------------------------------------------

local function unload()
	if not running then
		return
	end
	running = false

	for i = #installedHooks, 1, -1 do
		local installed = installedHooks[i]
		installed.target[installed.key] = installed.original
	end
	table.clear(installedHooks)
	pendingImport = nil

	for level, original in wrappedDeathLevels do
		if isAlive(level) then
			level.onDied = original
		end
	end

	-- Undo per-level effects with every toggle back at its default.
	local wasHidden = S.hidePlayer
	S.showHitboxes, S.hitboxTrail, S.hitboxesOnDeath, S.noShake = false, false, false, false
	S.hidePlayer, S.speedhack, S.replayPlay = false, false, false
	for level in liveLevels do
		if isAlive(level) then
			applyToLevel(level)
			applyReplay(level)
			level.tick_rate = 1 / DEFAULT_TPS
			if audioChangedLevels[level] and level.soundInstance then
				level.soundInstance:setPlaybackSpeed(1)
			end
			if wasHidden and not level.dead then
				for _, player in level.Players or {} do
					if not player.isHidden and player.object_ptr then
						player.object_ptr.SurfaceGui.Enabled = true
					end
				end
			end
		end
	end

	statusGui:Destroy()

	if S.unlockFps then
		S.unlockFps = false
		applyFpsCap()
	end
end

ctx:OnCleanup(unload)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function notify(text, kind)
	ctx.Notify(text, kind or "info", 5)
end

task.spawn(function()
	while running do
		while #notifyQueue > 0 do
			local item = table.remove(notifyQueue, 1)
			pcall(notify, item[1], item[2])
		end
		task.wait(0.2)
	end
end)

local function addToggle(tab, key, text, description, onChange)
	return tab:AddToggle({
		Text = text,
		Flag = key,
		Description = description,
		Default = S[key],
		Callback = function(enabled)
			S[key] = enabled
			if onChange then
				onChange(enabled)
			end
		end,
	})
end

local function requireLevel()
	local level = getLevel()
	if not level then
		notify("No level is running", "error")
	end
	return level
end

-- Scene actions need the level scene (not the editor) and the scene function.
local function sceneAction(fnName, action)
	return function()
		local scene = getScene()
		local fn = sceneFns[fnName]
		if not scene then
			notify("Open a level first (not the editor)", "error")
		elseif not fn then
			notify("Not available: your executor has no debug.getupvalues", "error")
		else
			local ok, err = pcall(action, scene, fn)
			if not ok then
				notify("Failed: " .. tostring(err), "error")
			end
		end
	end
end

local function switchStartPos(scene, restartLevel, delta)
	local level = scene._levelInstance
	local count = #level:GetGameplayAffectingStartPos()
	if count == 0 then
		notify("This level has no start positions", "error")
		return
	end
	local id = delta == 0 and 0 or (level:getCurrentStartPosId() + delta) % (count + 1)
	level:setCurrentStartPosId(id)
	level:resetLevelStateViaCheckpoint()
	restartLevel(scene)
	notify(id == 0 and "Starting from the beginning" or string.format("StartPos %d/%d", id, count))
end

-- Level -----------------------------------------------------------------------

local LevelTab = ctx:SubTab("Main", "Lucide:house")

LevelTab:AddSection("Player", "Lucide:user")
addToggle(LevelTab, "noclip", "Noclip", "Spikes, crashes and the death barrier no longer kill you")
addToggle(LevelTab, "jumpHack", "Jump Hack", "Jump in mid-air while jump is held")
addToggle(LevelTab, "forcePlatformer", "Force Platformer", "Play any level in platformer mode (outside the editor)")

LevelTab:AddSection("Auto Clicker", "Lucide:mouse-pointer-click")
addToggle(LevelTab, "autoClicker", "Auto Clicker", "Presses jump automatically while a level is playing")
LevelTab:AddSlider({
	Text = "Clicks Per Second",
	Flag = "autoClickerCps",
	Min = 1,
	Max = 30,
	Increment = 1,
	Default = S.autoClickerCps,
	Callback = function(value)
		S.autoClickerCps = value
	end,
})

LevelTab:AddSection("Practice", "Lucide:flag")
LevelTab:AddButton({
	Text = "Toggle Practice Mode",
	Description = "Same as the practice button in the pause menu",
	Callback = function()
		local scene = getScene()
		local fnName = scene and scene._isPracticeEnabled and "disablePractice" or "enablePractice"
		sceneAction(fnName, function(target, fn)
			fn(target)
		end)()
	end,
})
LevelTab:AddButton({
	Text = "Place Checkpoint",
	Callback = sceneAction("createCheckpoint", function(scene, fn)
		if not scene._isPracticeEnabled then
			notify("Turn on practice mode first", "error")
			return
		end
		fn(scene)
	end),
})
LevelTab:AddButton({
	Text = "Remove Checkpoint",
	Callback = sceneAction("removeCheckpoint", function(scene, fn)
		fn(scene)
	end),
})

LevelTab:AddSection("Restart", "Lucide:rotate-ccw")
LevelTab:AddButton({
	Text = "Restart Level",
	Description = "From the last checkpoint in practice mode",
	Callback = sceneAction("restartLevel", function(scene, fn)
		if scene._levelInstance:IsCompleted() or scene._triggeredCompletedEvent then
			notify("The level is already complete", "error")
			return
		end
		fn(scene)
	end),
})
addToggle(LevelTab, "fastRespawn", "Fast Respawn", "Respawn faster after dying (the game waits 0.5-1 s)")
LevelTab:AddSlider({
	Text = "Respawn Delay",
	Flag = "respawnTime",
	Min = 0,
	Max = 1,
	Increment = 0.05,
	Default = S.respawnTime,
	Suffix = "s",
	Callback = function(value)
		S.respawnTime = value
	end,
})

LevelTab:AddSection("StartPos Switcher", "Lucide:map-pin")
LevelTab:AddButton({
	Text = "Previous StartPos",
	Callback = sceneAction("restartLevel", function(scene, fn)
		switchStartPos(scene, fn, -1)
	end),
})
LevelTab:AddButton({
	Text = "Next StartPos",
	Callback = sceneAction("restartLevel", function(scene, fn)
		switchStartPos(scene, fn, 1)
	end),
})
LevelTab:AddButton({
	Text = "Start From Beginning",
	Callback = sceneAction("restartLevel", function(scene, fn)
		switchStartPos(scene, fn, 0)
	end),
})

LevelTab:AddSection("Hitboxes", "Lucide:scan")
addToggle(LevelTab, "showHitboxes", "Show Hitboxes", nil, applyAll)
addToggle(LevelTab, "hitboxesOnDeath", "Show Hitboxes on Death", nil, applyAll)
addToggle(LevelTab, "hitboxTrail", "Show Hitboxes Trail", "Trail of the player's past hitboxes", applyAll)

LevelTab:AddSection("Triggers", "Lucide:zap")
addToggle(LevelTab, "showTriggers", "Show Triggers", "Draw trigger objects in play mode (applies to the next level loaded)")
addToggle(LevelTab, "stopTriggersOnDeath", "Stop Triggers on Death", "Freeze moving objects, colours and the camera when you die")

LevelTab:AddSection("Actions", "Lucide:play")
LevelTab:AddButton({
	Text = "Kill Player",
	Description = "Dies instantly, even with Noclip on",
	Callback = function()
		local player = getPlayer1(requireLevel())
		if player and originalKill then
			originalKill(player)
		end
	end,
})
LevelTab:AddButton({
	Text = "Instant Complete",
	Description = "Completes the current level (blocked from the server while Auto Safe Mode is on)",
	Callback = function()
		local level = requireLevel()
		if level then
			if not level:IsRegularPlay() then
				notify("Instant Complete only works when playing a level", "error")
				return
			end
			getStats(level).cheated = true
			level:Complete()
		end
	end,
})

LevelTab:AddSection("Level Info", "Lucide:info")
do
	local Director = require(ReplicatedStorage.Packages.Nodekit).Director

	local passcodeInfo = LevelTab:AddParagraph({ Title = "Level Passcode", Text = "Open a level, then press Show Level Passcode" })

	-- LevelScene keeps it in _levelData. Other scenes aren't dumped, so look for a
	-- level-like table: it has an id and a name, like the data LevelScene receives.
	local function findLevelData(scene)
		if type(scene._levelData) == "table" then
			return scene._levelData
		end
		for key, value in scene do
			local lowerKey = string.lower(tostring(key))
			if type(value) == "table" and key ~= "_levelInstance"
				and (string.find(lowerKey, "level", 1, true) or string.find(lowerKey, "data", 1, true))
				and value.id ~= nil and value.name ~= nil then
				return value
			end
		end
		return nil
	end

	local function collectPasscodes(data, prefix, found, depth)
		for key, value in data do
			local keyText = tostring(key)
			local lowerKey = string.lower(keyText)
			if type(value) == "table" then
				if depth > 0 then
					collectPasscodes(value, prefix .. keyText .. ".", found, depth - 1)
				end
			elseif string.find(lowerKey, "pass", 1, true) or string.find(lowerKey, "code", 1, true) then
				-- The length limit skips encoded level data.
				if type(value) == "number" or (type(value) == "string" and #value <= 64) then
					table.insert(found, prefix .. keyText .. " = " .. tostring(value))
				end
			end
		end
	end

	-- Field names and types only, to find the real name if the search misses it.
	local function fieldList(data)
		local fields = {}
		for key, value in data do
			table.insert(fields, tostring(key) .. ": " .. typeof(value))
		end
		table.sort(fields)
		return fields
	end

	LevelTab:AddButton({
		Text = "Show Level Passcode",
		Description = "Shows the passcode of the level being viewed, if the game sent it to your client",
		Callback = function()
			local director = Director:getInstance()
			local scene = (director and director:getRunningScene()) or getScene()
			local levelData = scene and findLevelData(scene)
			if not levelData then
				writeLog("level_data_fields.json", { sceneFields = scene and fieldList(scene) or {} })
				passcodeInfo:Set("No level data found on this screen. Scene fields saved to DashWorld/logs/level_data_fields.json")
				notify("No level found on this screen", "error")
				return
			end

			local found = {}
			collectPasscodes(levelData, "", found, 2)
			table.sort(found)
			writeLog("level_data_fields.json", { level = tostring(levelData.name), levelFields = fieldList(levelData) })
			if #found == 0 then
				passcodeInfo:Set(string.format("\"%s\": no passcode in the level's data. Field names saved to DashWorld/logs/level_data_fields.json", tostring(levelData.name)))
				notify("This level's data has no passcode", "error")
				return
			end
			passcodeInfo:Set(string.format("\"%s\"\n%s", tostring(levelData.name), table.concat(found, "\n")))
			notify("Found the level's passcode field", "success")
		end,
	})
end

-- Cosmetic ----------------------------------------------------------------------

local CosmeticTab = ctx:SubTab("Visuals", "Lucide:eye")

CosmeticTab:AddSection("Player", "Lucide:user")
addToggle(CosmeticTab, "hidePlayer", "Hide Player")
addToggle(CosmeticTab, "noDeathEffect", "No Death Effect", "No explosion when you die")
addToggle(CosmeticTab, "noGhostTrail", "No Ghost Trail")

CosmeticTab:AddSection("Trails", "Lucide:sparkles")
addToggle(CosmeticTab, "noTrail", "No Trail", "Hide the player and ship trails")
addToggle(CosmeticTab, "trailAlwaysOn", "Trail Always On", "Show the trail even when not jumping")
addToggle(CosmeticTab, "noWaveTrail", "No Wave Trail")
addToggle(CosmeticTab, "noWavePulse", "No Wave Pulse", "Wave trail width stops pulsing to the music")

CosmeticTab:AddSection("Fire", "Lucide:flame")
addToggle(CosmeticTab, "noDashFire", "No Dash Fire")
addToggle(CosmeticTab, "noRobotSwingFire", "No Robot / Swing Fire")

CosmeticTab:AddSection("Camera", "Lucide:camera")
addToggle(CosmeticTab, "noShake", "No Shake", "No shake triggers and no death shake", applyAll)
addToggle(CosmeticTab, "noCameraZoom", "No Camera Zoom", "Ignore camera zoom triggers")
addToggle(CosmeticTab, "noCameraRotate", "No Camera Rotation", "Ignore camera rotate triggers")

CosmeticTab:AddSection("Effects", "Lucide:wand-sparkles")
addToggle(CosmeticTab, "noPulse", "No Pulse", "Ignore pulse triggers")
addToggle(CosmeticTab, "noShaders", "No Shaders", "Ignore saturation, contrast, brightness, tint, bloom and blur triggers")

-- Status --------------------------------------------------------------------------

local StatusTab = ctx:SubTab("Status", "Lucide:activity")

StatusTab:AddSection("Overlay", "Lucide:layers")
addToggle(StatusTab, "statusEnabled", "Show Status", "On-screen overlay with the items below", applyStatusLayout)
StatusTab:AddDropdown({
	Text = "Position",
	Flag = "statusCorner",
	Options = { "Top Left", "Top Right", "Bottom Left", "Bottom Right" },
	Default = S.statusCorner,
	Callback = function(value)
		S.statusCorner = value
		applyStatusLayout()
	end,
})
StatusTab:AddSlider({
	Text = "Scale",
	Flag = "statusScale",
	Min = 0.5,
	Max = 2,
	Increment = 0.1,
	Default = S.statusScale,
	Suffix = "x",
	Callback = function(value)
		S.statusScale = value
		applyStatusLayout()
	end,
})
StatusTab:AddSlider({
	Text = "Opacity",
	Flag = "statusOpacity",
	Min = 0.1,
	Max = 1,
	Increment = 0.05,
	Default = S.statusOpacity,
	Callback = function(value)
		S.statusOpacity = value
		applyStatusLayout()
	end,
})
StatusTab:AddDropdown({
	Text = "Percentage Decimals",
	Flag = "percentDecimals",
	Options = { "0", "1", "2", "3" },
	Default = tostring(S.percentDecimals),
	Callback = function(value)
		S.percentDecimals = tonumber(value) or 2
	end,
})

StatusTab:AddSection("Items", "Lucide:list")
for _, field in STATUS_FIELDS do
	StatusTab:AddToggle({
		Text = field.name,
		Flag = "status_" .. field.key,
		Default = statusShown[field.key],
		Callback = function(enabled)
			statusShown[field.key] = enabled
		end,
	})
end
StatusTab:AddTextbox({
	Text = "Message Text",
	Flag = "message",
	Placeholder = "Shown when Message is on",
	Callback = function(text)
		S.message = text or ""
	end,
})

-- Speedhack -----------------------------------------------------------------------

local SpeedTab = ctx:SubTab("Speedhack", "Lucide:gauge")

addToggle(SpeedTab, "speedhack", "Enabled", "Speeds up or slows down the whole game")
SpeedTab:AddSlider({
	Text = "Speed",
	Flag = "speed",
	Min = 0.1,
	Max = 3,
	Increment = 0.05,
	Default = S.speed,
	Suffix = "x",
	Callback = function(value)
		S.speed = value
	end,
})
addToggle(SpeedTab, "speedhackAudio", "Speedhack Audio", "Change the music speed too, so it stays in sync")

-- Replay --------------------------------------------------------------------------

local ReplayTab = ctx:SubTab("Replay", "Lucide:circle-play")

local replayInfo = ReplayTab:AddParagraph({ Title = "Current Replay", Text = replay.info })
local function refreshReplayInfo()
	replayInfo:Set(replay.info)
end

ReplayTab:AddSection("Record / Play", "Lucide:circle-dot")
addToggle(ReplayTab, "replayRecord", "Record", "Keep the inputs of your runs as the current replay")
ReplayTab:AddDropdown({
	Text = "Record",
	Flag = "replayRecordMode",
	Description = "Which runs replace the current replay",
	Options = { "Completed Runs", "Every Attempt" },
	Default = S.replayRecordMode,
	Callback = function(value)
		S.replayRecordMode = value
	end,
})
ReplayTab:AddToggle({
	Text = "Play",
	Description = "Restarts the level and plays the current replay (your inputs are ignored)",
	Default = false,
	Callback = function(enabled)
		if enabled and not replay.data then
			notify("Record or load a replay first", "error")
			S.replayPlay = false
			return
		end
		S.replayPlay = enabled
		local scene = getScene()
		if scene then
			applyReplay(scene._levelInstance)
			if sceneFns.restartLevel and not scene._levelInstance:IsCompleted() then
				pcall(sceneFns.restartLevel, scene)
			end
		end
	end,
})
ReplayTab:AddButton({
	Text = "Clear Replay",
	Callback = function()
		replay.data = nil
		replay.info = "Nothing recorded"
		refreshReplayInfo()
	end,
})

ReplayTab:AddSection("Files", "Lucide:folder")
local replayName = ""
ReplayTab:AddTextbox({
	Text = "Filename",
	Placeholder = "my-run",
	Callback = function(text)
		replayName = string.gsub(text or "", "[^%w%-_ ]", "")
	end,
})
ReplayTab:AddButton({
	Text = "Save",
	Description = "Saves to workspace/" .. REPLAY_FOLDER,
	Callback = function()
		if not hasFiles then
			notify("Your executor has no file functions", "error")
		elseif not replay.data then
			notify("Nothing to save", "error")
		elseif replayName == "" then
			notify("Enter a filename first", "error")
		else
			ensureReplayFolder()
			local ok, err = pcall(writefile, REPLAY_FOLDER .. "/" .. replayName .. ".dwr", replay.data)
			notify(ok and ("Saved " .. replayName) or ("Save failed: " .. tostring(err)), ok and "success" or "error")
		end
	end,
})

local selectedReplay = nil
local initialReplays = listReplays()
selectedReplay = initialReplays[1]
local replayDropdown = ReplayTab:AddDropdown({
	Text = "Saved Replays",
	Options = #initialReplays > 0 and initialReplays or { NO_REPLAYS },
	Default = initialReplays[1] or NO_REPLAYS,
	Callback = function(value)
		selectedReplay = value ~= NO_REPLAYS and value or nil
	end,
})
local function refreshReplayList()
	local names = listReplays()
	replayDropdown:Refresh(#names > 0 and names or { NO_REPLAYS })
	selectedReplay = names[1]
end
ReplayTab:AddButton({ Text = "Refresh List", Callback = refreshReplayList })
ReplayTab:AddButton({
	Text = "Load",
	Callback = function()
		if not selectedReplay then
			notify("No replay selected", "error")
			return
		end
		local ok, data = pcall(readfile, REPLAY_FOLDER .. "/" .. selectedReplay .. ".dwr")
		if ok and type(data) == "string" and string.sub(data, 1, 3) == "MCX" then
			replay.data = data
			replay.info = "File: " .. selectedReplay
			refreshReplayInfo()
			notify("Loaded " .. selectedReplay, "success")
		else
			notify("Not a valid replay file", "error")
		end
	end,
})
ReplayTab:AddButton({
	Text = "Delete",
	Callback = function()
		if selectedReplay and type(delfile) == "function" then
			pcall(delfile, REPLAY_FOLDER .. "/" .. selectedReplay .. ".dwr")
			refreshReplayList()
		end
	end,
})

task.spawn(function()
	local lastInfo = replay.info
	while running do
		if replay.info ~= lastInfo then
			lastInfo = replay.info
			pcall(refreshReplayInfo)
		end
		task.wait(0.5)
	end
end)

-- Import/Export Level ------------------------------------------------------------------

local ImportTab = ctx:SubTab("Import/Export", "Lucide:file-up")

ImportTab:AddSection("File", "Lucide:file")

local initialImportFiles = scanImportFiles()
local selectedImportPath = initialImportFiles[1]

local importFileDropdown = ImportTab:AddDropdown({
	Text = "File",
	Description = "Put .gdlvl files in your executor's workspace/" .. IMPORT_FOLDER .. " folder",
	Options = #initialImportFiles > 0 and initialImportFiles or { NO_FILES },
	Default = initialImportFiles[1] or NO_FILES,
	Callback = function(value)
		if value ~= NO_FILES then
			selectedImportPath = value
		end
	end,
})

ImportTab:AddButton({
	Text = "Refresh File List",
	Callback = function()
		local files = scanImportFiles()
		importFileDropdown:Refresh(#files > 0 and files or { NO_FILES })
		selectedImportPath = files[1]
		notify(string.format("Found %d .gdlvl file(s)", #files))
	end,
})

ImportTab:AddTextbox({
	Text = "Or Enter Path",
	Description = "Path relative to the workspace folder, e.g. gdlvl/mylevel.gdlvl",
	Placeholder = "gdlvl/mylevel.gdlvl",
	Callback = function(text)
		text = gdlvl.trim(text or "")
		if text ~= "" then
			selectedImportPath = text
		end
	end,
})

ImportTab:AddSection("Import", "Lucide:file-down")

ImportTab:AddToggle({
	Text = "Approximate Matches",
	Flag = "importApproximate",
	Description = "Also place objects whose exact Dash World shape is a best guess (press Load & Arm again after changing)",
	Default = true,
	Callback = function(enabled)
		gdlvl.setApproximate(enabled)
	end,
})

local importStatusParagraph = ImportTab:AddParagraph({
	Title = "Status",
	Text = "Pick a file, then press Load & Arm Import.",
})

task.spawn(function()
	while running do
		if importStatusText then
			local text = importStatusText
			importStatusText = nil
			pcall(importStatusParagraph.Set, importStatusParagraph, text)
		end
		task.wait(0.2)
	end
end)

ImportTab:AddButton({
	Text = "Load & Arm Import",
	Description = "Converts the file; the next level you open in the editor gets replaced",
	Callback = function()
		if not selectedImportPath then
			notify("No file selected", "error")
			return
		end
		if type(readfile) ~= "function" then
			notify("Your executor has no readfile()", "error")
			return
		end

		setImportStatus("Reading " .. selectedImportPath .. " ...")
		local ok, err = pcall(function()
			local name, levelString = gdlvl.read(readfile(selectedImportPath))
			setImportStatus(string.format("Converting \"%s\" ...", name))
			local settings, channels, blocks, stats = gdlvl.convert(levelString)

			if #blocks == 0 then
				error(string.format("none of the %d objects could be converted", stats.total), 0)
			end

			if pendingImport then
				pendingImport.cancelled = true
			end
			pendingImport = {
				name = name,
				settings = settings,
				channels = channels,
				blocks = blocks,
			}

			setImportStatus(string.format(
				"\"%s\": %d/%d objects converted (%d triggers), %d colour channels.\n%d unmapped, %d unsupported trigger modes, %d rejected.\nArmed: open a custom level in the editor (it will be REPLACED), then press Save.",
				name, stats.converted, stats.total, stats.triggers, stats.channels,
				stats.unmapped, stats.unsupported, stats.rejected
			))
			notify(string.format("%d/%d objects converted. Open a level in the editor.", stats.converted, stats.total), "success")

			if #stats.topUnmapped > 0 then
				local lines = {}
				for i = 1, math.min(20, #stats.topUnmapped) do
					local entry = stats.topUnmapped[i]
					table.insert(lines, string.format("GD %d x%d", entry[1], entry[2]))
				end
				ctx.Log("[gdlvl] Most common unmapped GD object ids: " .. table.concat(lines, ", "))
			end
			local function countList(counts)
				local list = {}
				for gdId, count in counts do
					table.insert(list, { id = gdId, count = count })
				end
				table.sort(list, function(a, b)
					return a.count > b.count
				end)
				return list
			end
			local unmappedList = {}
			for _, entry in stats.topUnmapped do
				table.insert(unmappedList, { id = entry[1], count = entry[2] })
			end
			local logOk, logResult = writeLog("last_import.json", {
				level = name,
				total = stats.total,
				converted = stats.converted,
				triggers = stats.triggers,
				channels = stats.channels,
				unmapped = unmappedList,
				unsupportedTriggerModes = countList(stats.unsupportedCounts),
				rejected = countList(stats.rejectedCounts),
			})
			ctx.Log(logOk and ("[gdlvl] Import log written to workspace/" .. logResult) or ("[gdlvl] Import log failed: " .. logResult))
		end)

		if not ok then
			setImportStatus("Import failed: " .. tostring(err))
			notify("Import failed: " .. tostring(err), "error")
		end
	end,
})

ImportTab:AddButton({
	Text = "Cancel Import",
	Description = "Disarm, so the next level loads normally",
	Callback = function()
		local pending = pendingImport
		if pending then
			pending.cancelled = true
		end
		pendingImport = nil
		setImportStatus("Import cancelled.")
	end,
})

ImportTab:AddButton({
	Text = "Create New Custom Level",
	Description = "Same as the New button in My Levels; reopen My Levels to see it",
	Callback = function()
		local ok, response = pcall(function()
			return Networker:InvokeServer("CreateUserLevel")
		end)
		if ok and type(response) == "table" and response.ok then
			notify("New custom level created. Open it in the editor to import.", "success")
		else
			notify("Could not create a level: " .. tostring(ok and (response and response.body) or response), "error")
		end
	end,
})

ImportTab:AddSection("Export", "Lucide:file-up")

local exportInProgress = false

ImportTab:AddButton({
	Text = "Export Current Level",
	Description = "Saves the level you're playing or editing as a .gdlvl file in workspace/" .. IMPORT_FOLDER,
	Callback = function()
		local level = requireLevel()
		if not level or exportInProgress then
			return
		end
		if type(writefile) ~= "function" then
			notify("Your executor has no writefile()", "error")
			return
		end

		exportInProgress = true
		setImportStatus("Exporting the current level...")
		local ok, err = pcall(function()
			local levelData = currentScene and currentScene._levelInstance == level and currentScene._levelData
			local name = levelData and levelData.name
			if type(name) ~= "string" or name == "" then
				name = "Dash World Level"
			end

			local fileText, stats = gdlvl.export(level, name)

			pcall(function()
				if not isfolder(IMPORT_FOLDER) then
					makefolder(IMPORT_FOLDER)
				end
			end)
			local fileName = string.gsub(name, "[^%w%-_ ]", "_") .. " export " .. os.date("%Y%m%d-%H%M%S") .. ".gdlvl"
			local path = IMPORT_FOLDER .. "/" .. fileName
			writefile(path, fileText)

			writeLog("last_export.json", {
				level = name,
				file = path,
				total = stats.total,
				exported = stats.exported,
				skipped = stats.skipped,
				skippedObjects = stats.skippedObjects,
			})

			setImportStatus(string.format(
				"Exported \"%s\": %d/%d objects to workspace/%s.\n%d objects have no GD equivalent (see logs/last_export.json).",
				name, stats.exported + stats.pairedExits, stats.total, path, stats.skipped
			))
			notify(string.format("Exported %d/%d objects to workspace/%s", stats.exported + stats.pairedExits, stats.total, path), "success")
			for _, entry in stats.skippedObjects do
				ctx.Log(string.format("[gdlvl] Export skipped %s x%d", entry.name, entry.count))
			end

			local files = scanImportFiles()
			importFileDropdown:Refresh(#files > 0 and files or { NO_FILES })
		end)
		exportInProgress = false

		if not ok then
			warn("[gdlvl] Export failed: " .. tostring(err))
			setImportStatus("Export failed: " .. tostring(err))
			notify("Export failed: " .. tostring(err), "error")
		end
	end,
})

-- Cheat Safety ----------------------------------------------------------------------

local SafetyTab = ctx:SubTab("Cheat Safety", "Lucide:shield-check")

addToggle(SafetyTab, "safeMode", "Safe Mode", "Never send attempts or completions to the server")
addToggle(SafetyTab, "autoSafeMode", "Auto Safe Mode",
	"Don't send an attempt if any cheat (noclip, speedhack, replay...) was on during it")

-- Display -------------------------------------------------------------------------

local DisplayTab = ctx:SubTab("Display", "Lucide:monitor")

DisplayTab:AddSection("Frame Rate", "Lucide:gauge")
addToggle(DisplayTab, "unlockFps", "Unlock FPS", setFpsCap and "Raise the Roblox frame rate cap" or "Your executor has no setfpscap()", applyFpsCap)
DisplayTab:AddSlider({
	Text = "FPS Cap",
	Flag = "fpsCap",
	Min = 30,
	Max = 1000,
	Increment = 10,
	Default = S.fpsCap,
	Callback = function(value)
		S.fpsCap = value
		if S.unlockFps then
			applyFpsCap()
		end
	end,
})

DisplayTab:AddSection("Physics", "Lucide:atom")
DisplayTab:AddDropdown({
	Text = "Physics TPS",
	Flag = "tps",
	Description = "Physics steps per second (game default 240)",
	Options = { "240", "360", "480", "720", "960" },
	Default = tostring(S.tps),
	Callback = function(value)
		S.tps = tonumber(value) or DEFAULT_TPS
	end,
})

-- Utility -------------------------------------------------------------------------

-- JSON-safe copy of a value, for the dump log.
local function describeValue(value, depth)
	local kind = typeof(value)
	if kind == "boolean" or kind == "string" then
		return value
	elseif kind == "number" then
		return (value == value and math.abs(value) ~= math.huge) and value or tostring(value)
	elseif kind == "Vector3" then
		return { x = value.X, y = value.Y, z = value.Z }
	elseif kind == "Vector2" then
		return { x = value.X, y = value.Y }
	elseif kind == "Color3" then
		return "#" .. value:ToHex()
	elseif kind == "table" then
		depth = depth or 0
		if depth >= 6 then
			return "<too deep>"
		end
		local out = {}
		for key, item in value do
			out[tostring(key)] = describeValue(item, depth + 1)
		end
		return out
	end
	return tostring(value)
end

local VISUAL_PROPERTIES = {
	ImageLabel = { "Image", "ImageRectOffset", "ImageRectSize", "ImageColor3", "Size", "Position", "Rotation" },
	ImageButton = { "Image", "ImageRectOffset", "ImageRectSize", "ImageColor3", "Size", "Position", "Rotation" },
	TextLabel = { "Text", "Size", "Position" },
	Decal = { "Texture", "Color3", "Face" },
	Texture = { "Texture", "Color3", "Face" },
	ParticleEmitter = { "Texture", "Rate", "Enabled" },
	Trail = { "Texture" },
	Beam = { "Texture" },
}

local function dumpPrefab(prefab, folderName, root)
	local toolboxIds = {}
	for id, name in Toolbox.idIndexed do
		if name == prefab.Name then
			table.insert(toolboxIds, id)
		end
	end
	table.sort(toolboxIds)

	local visuals = {}
	for _, descendant in prefab:GetDescendants() do
		local properties = VISUAL_PROPERTIES[descendant.ClassName]
		if properties then
			local visual = {
				class = descendant.ClassName,
				path = string.sub(descendant:GetFullName(), #root:GetFullName() + 2),
			}
			for _, property in properties do
				visual[property] = describeValue(descendant[property])
			end
			table.insert(visuals, visual)
		end
	end

	local entry = {
		name = prefab.Name,
		category = folderName,
		class = prefab.ClassName,
		toolboxIds = toolboxIds,
		tags = prefab:GetTags(),
		attributes = describeValue(prefab:GetAttributes()),
		visuals = visuals,
	}
	if prefab:IsA("BasePart") then
		entry.size = describeValue(prefab.Size)
		local hitbox = prefab:FindFirstChild("Hitbox")
		if hitbox and hitbox:IsA("BasePart") then
			entry.hitbox = {
				size = describeValue(hitbox.Size),
				offset = describeValue(hitbox.Position - prefab.Position),
			}
		end
	end
	return entry
end

local function dumpPrefabs()
	local root = ReplicatedStorage.Prefabs.GameObjects
	local prefabs, seen = {}, {}
	for _, folder in root:GetChildren() do
		for _, prefab in folder:GetChildren() do
			seen[prefab.Name] = true
			table.insert(prefabs, dumpPrefab(prefab, folder.Name, root))
			if #prefabs % 50 == 0 then
				task.wait()
			end
		end
	end
	table.sort(prefabs, function(a, b)
		return (a.toolboxIds[1] or math.huge) < (b.toolboxIds[1] or math.huge)
	end)

	local withoutPrefab = {}
	for id, name in Toolbox.idIndexed do
		if not seen[name] then
			table.insert(withoutPrefab, { id = id, name = name })
		end
	end

	local info = {}
	for _, moduleName in { "AnimatedObjects", "ObjectVariations" } do
		local ok, result = pcall(require, ReplicatedStorage.Shared.Info[moduleName])
		info[moduleName] = ok and describeValue(result) or ("failed: " .. tostring(result))
	end

	return { prefabs = prefabs, toolboxWithoutPrefab = withoutPrefab, info = info }, #prefabs
end

local UtilityTab = ctx:SubTab("Debug", "Lucide:bug")

UtilityTab:AddButton({
	Text = "Dump Object Prefabs",
	Description = "Writes every Dash World object's images, size, hitbox and tags to workspace/" .. LOG_FOLDER,
	Callback = function()
		notify("Dumping object prefabs...")
		local ok, data, count = pcall(dumpPrefabs)
		if not ok then
			notify("Dump failed: " .. tostring(data), "error")
			return
		end
		local written, result = writeLog("prefab_dump.json", data)
		ctx.Log(written and ("[DashWorldScript] Prefab dump written to workspace/" .. result) or ("[DashWorldScript] Prefab dump failed: " .. result))
		notify(written and string.format("Dumped %d objects to workspace/%s", count, result) or ("Dump failed: " .. result), written and "success" or "error")
	end,
})
