-- Kayo Sports
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local COIN_TAG = "CoinPickup"
local STEP_WAIT = 0.12 -- seconds spent on each coin so the touch registers
local PASS_WAIT = 0.5 -- seconds between sweeps

local QUEST_TAG = "QuestItemPickup"

local enabled = false
local questEnabled = false
local collected, collectedValue = 0, 0
local questCollected = 0
local setQuestEnabled -- defined below; declared here so the panel buttons can use it

-- ===== Collect loop =====

local function getRoot()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and humanoid and humanoid.Health > 0 then return root end
end

local function liveCoins(root)
	local coins = {}
	for _, coin in ipairs(CollectionService:GetTagged(COIN_TAG)) do
		if coin:IsA("BasePart") and coin:IsDescendantOf(workspace) then
			table.insert(coins, coin)
		end
	end
	table.sort(coins, function(a, b) -- nearest first keeps the trip short
		return (a.Position - root.Position).Magnitude < (b.Position - root.Position).Magnitude
	end)
	return coins
end

local onChanged -- set once the panel exists

local function sweep()
	local root = getRoot()
	if not root then return end
	local coins = liveCoins(root)
	if #coins == 0 then return end

	local home = root.CFrame
	for _, coin in ipairs(coins) do
		if not enabled then break end
		root = getRoot()
		if not root then return end
		if coin:IsDescendantOf(workspace) then -- may have been picked up meanwhile
			local value = coin:GetAttribute("Coins") or 10
			if firetouchinterest then
				pcall(firetouchinterest, root, coin, 0)
			end
			root.CFrame = CFrame.new(coin.Position)
			task.wait(STEP_WAIT)
			if firetouchinterest then
				pcall(firetouchinterest, root, coin, 1)
			end
			if not coin:IsDescendantOf(workspace) then
				collected = collected + 1
				collectedValue = collectedValue + value
				if onChanged then onChanged() end
			end
		end
	end

	root = getRoot()
	if root then
		root.CFrame = home
		root.AssemblyLinearVelocity = Vector3.new()
	end
end

-- ===== Quest items =====
-- From dump2.luau (Client.Components.QuestItemPickup): quest items are Models (or parts) tagged
-- "QuestItemPickup" with a ProximityPrompt ("Pick Up"; the client creates one if missing). When
-- the prompt is triggered the client disables it and calls QuestController:NotifyQuest(
-- QuestName, item name). We trigger each enabled prompt with fireproximityprompt after moving
-- next to the item (so it is in activation range), then return to where we were.
local questWarned = false

local function pivotOf(item)
	return item:IsA("Model") and item:GetPivot().Position or item.Position
end

local function questSweep()
	local root = getRoot()
	if not root then return end

	local items = {}
	for _, item in ipairs(CollectionService:GetTagged(QUEST_TAG)) do
		if (item:IsA("Model") or item:IsA("BasePart")) and item:IsDescendantOf(workspace) then
			local prompt = item:FindFirstChildWhichIsA("ProximityPrompt")
			if prompt and prompt.Enabled then
				table.insert(items, item)
			end
		end
	end
	if #items == 0 then return end

	if not fireproximityprompt then
		if not questWarned then
			questWarned = true
			ctx.Log("[KayoScript] executor lacks fireproximityprompt; quest items cannot be triggered", "warn")
		end
		return
	end

	table.sort(items, function(a, b)
		return (pivotOf(a) - root.Position).Magnitude < (pivotOf(b) - root.Position).Magnitude
	end)

	local home = root.CFrame
	for _, item in ipairs(items) do
		if not questEnabled then break end
		root = getRoot()
		if not root then return end
		local prompt = item:FindFirstChildWhichIsA("ProximityPrompt")
		if prompt and prompt.Enabled and item:IsDescendantOf(workspace) then
			prompt.HoldDuration = 0
			prompt.RequiresLineOfSight = false
			root.CFrame = CFrame.new(pivotOf(item) + Vector3.new(0, 3, 0))
			task.wait(STEP_WAIT)
			pcall(fireproximityprompt, prompt)
			task.wait(STEP_WAIT)
			if not prompt.Enabled or not item:IsDescendantOf(workspace) then
				questCollected = questCollected + 1
				if onChanged then onChanged() end
			end
		end
	end

	root = getRoot()
	if root then
		root.CFrame = home
		root.AssemblyLinearVelocity = Vector3.new()
	end
end

-- Coin and quest sweeps both move the character, so only one runs at a time.
local busy = false

local function runLoop(label, sweepFn, isOn)
	task.spawn(function()
		while isOn() do
			while busy do task.wait(0.05) end
			busy = true
			local ok, err = pcall(sweepFn)
			busy = false
			if not ok then ctx.Log("[KayoScript] " .. label .. " sweep failed: " .. tostring(err), "warn") end
			task.wait(PASS_WAIT)
		end
	end)
end

local function setEnabled(value)
	enabled = value
	if value then runLoop("coin", sweep, function() return enabled end) end
end

function setQuestEnabled(value)
	questEnabled = value
	if value then runLoop("quest", questSweep, function() return questEnabled end) end
end

-- ===== Auto Catch (Catching King minigame) =====
-- From dump4.luau (Minigames.CatchingKingController). The catch itself is decided inside a local
-- closure (AttemptCatch) that runs on a left click: it needs State.CanCatchBall, the mouse inside
-- the ball's 2D bounding circle, and the ball's screen depth within 3 of Common.ScreenDepth
-- (within 0.5 counts as "Perfect"). Rather than re-implement that, we make the real click:
-- every frame, while the ball is catchable and its depth is inside a small window around
-- ScreenDepth, move the cursor onto the ball (the controller's own _Get2dBallBoundingBox gives
-- its centre; GetMouseLocation includes the GUI inset, so add it back) and click.
-- "Always succeed" also needs misses to not count: _HandleMiss (called on TooEarly / TooLate /
-- Missed / ball not caught) resets the whole run after MaxMissesPerStage, so while the toggle is
-- on it is replaced with a no-op and restored afterwards.
-- The controller is the module's cached table (same one the game uses), so patching it works.
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local CATCH_DEPTH_WINDOW = 2 -- studs either side of ScreenDepth; the game accepts up to 3

local catchEnabled = false
local catchController, catchScreenDepth, catchModule, originalHandleMiss
local catchWarned = false
local catchConnection

local function loadCatchController()
	if catchController then return catchController end
	local ok, result = pcall(function()
		local module = game:GetService("ReplicatedStorage").Client.Controllers.Minigames.CatchingKingController
		return { controller = require(module), depth = require(module.Common).ScreenDepth, module = module }
	end)
	if ok then
		catchController, catchScreenDepth, catchModule = result.controller, result.depth, result.module
	elseif not catchWarned then
		catchWarned = true
		ctx.Log("[KayoScript] could not load CatchingKingController (are you in the cricket place?): " .. tostring(result), "warn")
	end
	return catchController
end

-- Why not send a real click: an earlier version clicked with mousemoveabs / mouse1click (the
-- executor had no VirtualInputManager). The game never saw those clicks (CanCatchBall stayed true
-- and hits stayed 0), most likely because those functions use desktop coordinates, not the game
-- window's. So instead we call the game's own AttemptCatch directly. It is the function the
-- controller connects to UserInputService.TouchStarted (dump4.luau line 576), so getconnections
-- finds it there; it takes no arguments, and it reads the cursor through
-- UserInputService:GetMouseLocation(), which we answer with the ball's position for the duration
-- of the call (a __namecall hook). All the game's own checks still run.
local attemptCatch -- the game's AttemptCatch closure for the current round
local spoofedMouse -- when set, GetMouseLocation returns this
local hookInstalled = false

local function installMouseHook()
	if hookInstalled then return true end
	if not getnamecallmethod then return false end
	local installed = ctx:HookMeta(game, "__namecall", function(old, self, ...)
		if spoofedMouse and self == UserInputService and getnamecallmethod() == "GetMouseLocation" then
			return spoofedMouse
		end
		return old(self, ...)
	end)
	if not installed then return false end
	hookInstalled = true
	return true
end

-- The AttemptCatch closure is recreated every round (_ConnectCatchingLogic), so look it up again
-- whenever the cached connection has gone.
local function findAttemptCatch()
	if attemptCatch and attemptCatch.connection.Connected ~= false then return attemptCatch.fn end
	attemptCatch = nil
	if not getconnections then return nil end

	for _, connection in ipairs(getconnections(UserInputService.TouchStarted)) do
		local fn = connection.Function
		if type(fn) == "function" then
			local matches = false
			if debug.getupvalues then
				local ok, upvalues = pcall(debug.getupvalues, fn)
				if ok and type(upvalues) == "table" then
					for _, value in pairs(upvalues) do
						if value == catchController then matches = true break end
					end
				end
			end
			if not matches and getfenv then
				local ok, env = pcall(getfenv, fn)
				matches = ok and type(env) == "table" and env.script == catchModule
			end
			if matches then
				attemptCatch = { fn = fn, connection = connection }
				return fn
			end
		end
	end
	return nil
end

local lastCatchLog = 0
local lastCatch = 0

local function catchStep()
	local controller = catchController
	local state = controller.State
	local now = os.clock()
	local active = state.IsMinigameActive and controller:_CanContinue()

	-- once every two seconds, say what the minigame looks like to this script
	if now - lastCatchLog >= 2 then
		lastCatchLog = now
		if active then
			local center, _, depth = controller:_Get2dBallBoundingBox()
			ctx.Log(string.format(
				"[AutoCatch] canCatch=%s depth=%.2f target=%.2f ball=(%d,%d) hits=%s rounds=%s",
				tostring(state.CanCatchBall), depth, catchScreenDepth, center.X, center.Y,
				tostring(state.BallsHitThisRound), tostring(state.RoundsCompleted)))
		else
			ctx.Log("[AutoCatch] minigame not active (IsMinigameActive=" .. tostring(state.IsMinigameActive) .. ")")
		end
	end

	if not (active and state.CanCatchBall) or now - lastCatch < 0.25 then return end

	local center, _, depth = controller:_Get2dBallBoundingBox()
	if not (depth > 0 and math.abs(depth - catchScreenDepth) <= CATCH_DEPTH_WINDOW) then return end

	local fn = findAttemptCatch()
	if not fn then
		if not catchWarned then
			catchWarned = true
			ctx.Log("[AutoCatch] could not find the game's AttemptCatch function (getconnections on TouchStarted)", "warn")
		end
		return
	end
	if not installMouseHook() then
		if not catchWarned then
			catchWarned = true
			ctx.Log("[AutoCatch] executor lacks getnamecallmethod or metamethod hooks; cannot place the cursor on the ball", "warn")
		end
		return
	end

	lastCatch = now
	spoofedMouse = center + GuiService:GetGuiInset() -- AttemptCatch subtracts the inset again
	local ok, err = pcall(fn)
	spoofedMouse = nil
	ctx.Log(string.format("[AutoCatch] called AttemptCatch at depth %.2f -> ok=%s hits=%s canCatch=%s%s",
		depth, tostring(ok), tostring(state.BallsHitThisRound), tostring(state.CanCatchBall),
		ok and "" or (" error=" .. tostring(err))))
end


local function setCatchEnabled(value)
	catchEnabled = value
	if value then
		if not loadCatchController() then return end
		ctx.Log("[AutoCatch] controller loaded, ScreenDepth = " .. tostring(catchScreenDepth))
		if not originalHandleMiss then
			originalHandleMiss = catchController._HandleMiss
			catchController._HandleMiss = function() end
		end
		if not catchConnection then
			catchConnection = ctx:Connect(RunService.Heartbeat, function()
				if catchEnabled then
					local ok, err = pcall(catchStep)
					if not ok and not catchWarned then
						catchWarned = true
						ctx.Log("[AutoCatch] step failed: " .. tostring(err), "warn")
					end
				end
			end)
		end
	else
		if catchConnection then
			catchConnection:Disconnect()
			catchConnection = nil
		end
		if catchController and originalHandleMiss then
			catchController._HandleMiss = originalHandleMiss
			originalHandleMiss = nil
		end
	end
end

-- ===== Auto Perfect Hit (In The Nets minigame) =====
-- From dump6.luau (Minigames.InTheNetsController). A swing is the local closure SwingBat, wired to
-- InTheNetsInputContext.Swing.Pressed. It calls controller:_GradePress(), which grades how far the
-- press is from the ideal moment: error = (_contactAt - now) - _swingLeadTime, and Perfect needs
-- that to be inside a small window. The grade and error then drive _ApplyHit (power and angle:
-- an error of 0 gives the strongest, straightest hit).
-- Two parts, both through the game's own code:
--  1. Timing: each frame, once the ball is in flight and `_contactAt - now - _swingLeadTime`
--     reaches 0, run SwingBat (found with getconnections on the Swing.Pressed signal; firesignal
--     as a fallback), so the swing starts at the ideal moment.
--  2. Grade: while on, controller._GradePress is replaced so any swing made during a throw is
--     graded "Perfect" with error 0 (so a manual swing, or one a frame late, is still perfect).
--     The original is restored when the toggle is turned off.
-- The server also gets the grade through ReportThrow, so it may validate it.
local hitEnabled = false
local hitController, originalGradePress
local hitConnection
local hitWarned = false
local lastSwing = 0
local hitMarkerDelay -- measured seconds from starting the swing to its "StartOfHit" marker
local swungThrow, reportedThrow -- throw tokens: last one we swung at / last one we explained

local function loadHitController()
	if hitController then return hitController end
	local ok, result = pcall(function()
		return require(game:GetService("ReplicatedStorage").Client.Controllers.Minigames.InTheNetsController)
	end)
	if ok then
		hitController = result
	elseif not hitWarned then
		hitWarned = true
		ctx.Log("[AutoHit] could not load InTheNetsController (are you in the cricket place?): " .. tostring(result), "warn")
	end
	return hitController
end

-- Performs a swing the same way SwingBat does (dump6.luau lines 642-683), but without needing to
-- find that local closure. An earlier version called whatever getconnections returned for
-- Swing.Pressed; it ran at the right moment but never produced a hit (HitGrade stayed nil), so
-- that was not the real swing function. The steps are: lock the swing, stop the idle pose, play
-- the swing animation, and at its "StartOfHit" marker call the controller's own
-- _ApplyHit(grade, timingError), which launches the ball.
local function performSwing(controller, state)
	local AnimationHelper = require(game:GetService("ReplicatedStorage").Shared.Helpers.AnimationHelper)
	local swingTrack, idleTrack = state.SwingTrack, state.IdleTrack
	if not (swingTrack and idleTrack) then return false end

	state.CanSwing = false
	state.LockBatAngle = true
	idleTrack:Stop(0.1)
	swingTrack:AdjustSpeed(1)

	local startedAt = os.clock()
	task.spawn(function()
		AnimationHelper.WaitForEvent(swingTrack, "StartOfHit", 0.33)
		hitMarkerDelay = os.clock() - startedAt
		local contactAt = controller._contactAt
		ctx.Log(string.format("[AutoHit] contact marker after %.3fs (game's lead %.3fs); hit applied %s",
			hitMarkerDelay, controller._swingLeadTime,
			contactAt and string.format("%+.3fs from ball contact", os.clock() - contactAt) or "with no ball in flight"))
		controller:_ApplyHit("Perfect", 0)
		AnimationHelper.WaitForEvent(swingTrack, "EndOfHit", 0.4)
	end)
	task.spawn(function()
		AnimationHelper.WaitForFinish(swingTrack)
		if not controller:_CanContinue() then return end
		state.LockBatAngle = false
		swingTrack:Play(0.2, nil, 0)
		state.CanSwing = true
	end)
	return true
end


local function hitStep()
	local controller = hitController
	local state = controller.State
	if not (state.IsMinigameActive and controller:_CanContinue()) then return end

	local context = state.Assets and state.Assets.InTheNetsInputContext
	local ball = state.Assets and state.Assets.InTheNetsBall
	local contactAt = controller._contactAt
	local now = os.clock()

	-- if the ball reached the bat without a swing, say why (once per throw)
	local token = controller._throwToken
	if contactAt and now > contactAt + 0.15 and swungThrow ~= token and reportedThrow ~= token then
		reportedThrow = token
		ctx.Log(string.format("[AutoHit] throw %s: no swing before contact (CanSwing=%s HitGrade=%s ballInHand=%s)",
			tostring(state.CurrentThrow), tostring(state.CanSwing), tostring(state.HitGrade),
			tostring(ball and ball.BallJoint.Enabled)))
	end

	if not (context and ball and contactAt and state.CanSwing and not state.HitGrade) then return end
	if ball.BallJoint.Enabled then return end -- ball still in the bowler's hand

	-- swing so the animation's contact frame lands on the ball's contact time: use the delay we
	-- measured on the last swing, falling back to the game's own estimate for the first one
	local lead = hitMarkerDelay or controller._swingLeadTime
	local remaining = contactAt - now - lead
	if remaining > 0.01 or remaining < -0.5 or now - lastSwing < 0.5 then return end

	lastSwing = now
	swungThrow = token
	local ok, swung = pcall(performSwing, controller, state)
	if not (ok and swung) then
		if not hitWarned then
			hitWarned = true
			ctx.Log("[AutoHit] could not swing: " .. tostring(ok and "SwingTrack / IdleTrack missing" or swung), "warn")
		end
		return
	end
	local throw = state.CurrentThrow
	ctx.Log(string.format("[AutoHit] throw %s swung with %.3fs left to the ideal moment", tostring(throw), remaining))
	task.delay(0.8, function()
		ctx.Log(string.format("[AutoHit] throw %s result: grade=%s ballHit=%s",
			tostring(throw), tostring(state.HitGrade), tostring(state.WasBallHit)))
	end)
end

local function setHitEnabled(value)
	hitEnabled = value
	if value then
		if not loadHitController() then return end
		ctx.Log("[AutoHit] controller loaded")
		if not originalGradePress then
			originalGradePress = hitController._GradePress
			hitController._GradePress = function(self)
				local state = self.State
				local ball = state.Assets and state.Assets.InTheNetsBall
				if state.HitGrade or not ball or ball.BallJoint.Enabled or not self._contactAt then
					return nil, 0 -- same "no swing possible" answer as the original
				end
				return "Perfect", 0
			end
		end
		if not hitConnection then
			hitConnection = ctx:Connect(RunService.Heartbeat, function()
				if hitEnabled then
					local ok, err = pcall(hitStep)
					if not ok and not hitWarned then
						hitWarned = true
						ctx.Log("[AutoHit] step failed: " .. tostring(err), "warn")
					end
				end
			end)
		end
	else
		if hitConnection then
			hitConnection:Disconnect()
			hitConnection = nil
		end
		if hitController and originalGradePress then
			hitController._GradePress = originalGradePress
			originalGradePress = nil
		end
	end
end

-- ===== Auto Perfect Timing (Pit Stop Panic minigame) =====
-- From dump1.luau (Minigames.PitStopMechanicController). Each lug nut / tire step starts a power
-- meter (PowerMeter:Start). When the player presses, the meter calls its hook
-- OnPowerLevelSelected(level, value), which runs controller:_StepMinigame(level, value). Inside,
-- `level` is a key of Common.TimeValues and is the penalty added to the run time:
--   _state.StartTime = _state.StartTime - TimeValues[level]
-- so the best level is the one with the lowest TimeValues entry (read at runtime).
-- _StepMinigame ends by starting the meter for the next step, so we wrap it: after each call
-- finishes (meter running again) we wait a moment and call it ourselves with the best level,
-- exactly as the hook would. The wrapper is restored when the toggle is turned off.
-- The run time is sent to the server for the leaderboard / reward (_ShowResults), so it may
-- validate it.
local PIT_PRESS_DELAY = 0.15 -- seconds after the meter starts before the automatic "press"

local pitEnabled = false
local pitController, pitBestLevel, originalStep
local pitWarned = false
local pitToken = 0

local function loadPitController()
	if pitController then return pitController end
	local ok, result = pcall(function()
		local module = game:GetService("ReplicatedStorage").Client.Controllers.Minigames.PitStopMechanicController
		local timeValues = require(module.Common).TimeValues
		local bestLevel, bestValue
		for level, penalty in pairs(timeValues) do
			if type(penalty) == "number" and (not bestValue or penalty < bestValue
				or (penalty == bestValue and level == "Perfect")) then
				bestLevel, bestValue = level, penalty
			end
		end
		local summary = {}
		for level, penalty in pairs(timeValues) do table.insert(summary, tostring(level) .. "=" .. tostring(penalty)) end
		ctx.Log("[AutoPit] TimeValues: " .. table.concat(summary, ", ") .. " -> using " .. tostring(bestLevel))
		return { controller = require(module), level = bestLevel }
	end)
	if ok and result.level then
		pitController, pitBestLevel = result.controller, result.level
	elseif not pitWarned then
		pitWarned = true
		ctx.Log("[AutoPit] could not load PitStopMechanicController (are you in the supercars place?): " .. tostring(ok and "no TimeValues" or result), "warn")
	end
	return pitController
end

-- After a step has set the meter running, press it for the player.
local function schedulePress(controller)
	local state = controller._state
	if not (pitEnabled and controller:_CanContinue() and state.PowerMeter and state.CurrentTire <= 4) then return end

	pitToken = pitToken + 1
	local token = pitToken -- a newer step (or a manual press) cancels this one
	task.delay(PIT_PRESS_DELAY, function()
		if token ~= pitToken or not pitEnabled or not controller:_CanContinue() then return end
		ctx.Log(string.format("[AutoPit] tire %s lug nut %s -> %s", tostring(state.CurrentTire),
			tostring(state.CurrentLugNut), tostring(pitBestLevel)))
		local ok, err = pcall(controller._StepMinigame, controller, pitBestLevel, 1)
		if not ok and not pitWarned then
			pitWarned = true
			ctx.Log("[AutoPit] step failed: " .. tostring(err), "warn")
		end
	end)
end

local function setPitEnabled(value)
	pitEnabled = value
	if value then
		if not loadPitController() then return end
		if not originalStep then
			originalStep = pitController._StepMinigame
			pitController._StepMinigame = function(self, level, amount)
				originalStep(self, level, amount) -- yields until the next meter run has started
				schedulePress(self)
			end
		end
		schedulePress(pitController) -- already mid-run: press for the meter that is running now
	else
		pitToken = pitToken + 1 -- cancel any pending press
		if pitController and originalStep then
			pitController._StepMinigame = originalStep
			originalStep = nil
		end
	end
end

-- ===== Auto Play (Sharpshooter minigame) =====
-- From dump1.luau (Minigames.SharpshooterController). One kick is two inputs, both of which end in
-- a public controller method, so we call those directly instead of timing meters:
--   1. controller:SetPower(scale)      (the power meter's result; State.PowerScale = scale)
--   2. controller:SetDirection(posts)  with posts = { Current, Post1..Post4 } (the aim meter's result)
-- SetDirection is a goal if Post2 - tol <= Current <= Post3 + tol, where tol = lerp(0.1, 0, scale),
-- and the kick reaches only if horizontal distance to the aim point <= scale * Common.MaxPower.
-- The meter's Post values are only compared against Current, so we pass our own consistent set:
-- Post2 = 0, Post3 = 1 and Current = 0.5, which maps to the exact middle of the posts
-- (math.map(Current, Post2, Post3, 0, 1) = 0.5 -> halfway between KickGoalPost2 and KickGoalPost3).
-- Power: scale starts at 1, and is raised to whatever the current distance needs (the tolerance
-- window stays wide enough up to about 5x), so far rounds are not under-powered.
-- Loop: whenever a round is ready (power meter enabled), wait a moment, SetPower, SetDirection.
-- SetDirection returns after the whole kick, then the controller re-enables the meter for the next
-- kick, so the loop simply repeats. Start the minigame from the game's own menu; this plays it.
local SHARP_DELAY = 0.6 -- seconds before each automatic kick
local SHARP_POSTS = { Current = 0.5, Post1 = -1, Post2 = 0, Post3 = 1, Post4 = 2 }

local sharpEnabled = false
local sharpController, sharpMaxPower
local sharpWarned = false
local sharpRunning = false

local function loadSharpController()
	if sharpController then return sharpController end
	local ok, result = pcall(function()
		local module = game:GetService("ReplicatedStorage").Client.Controllers.Minigames.SharpshooterController
		return { controller = require(module), maxPower = require(module.Common).MaxPower }
	end)
	if ok then
		sharpController, sharpMaxPower = result.controller, result.maxPower
	elseif not sharpWarned then
		sharpWarned = true
		ctx.Log("[AutoSharp] could not load SharpshooterController (are you in the AFL place?): " .. tostring(result), "warn")
	end
	return sharpController
end

-- Power needed to reach the middle of the goal from where the ball is now.
local function neededScale(state)
	local posts = state.Scene.KickGoalPost2.Position:Lerp(state.Scene.KickGoalPost3.Position, 0.5)
	local delta = posts - state.CurrentBall.Position
	local distance = math.sqrt(delta.X ^ 2 + delta.Z ^ 2)
	return math.clamp(distance / sharpMaxPower * 1.02, 1, 4)
end

local function sharpLoop()
	if sharpRunning then return end
	sharpRunning = true
	while sharpEnabled do
		local controller = sharpController
		local state = controller.State
		local ready = controller:_CanContinue() and state.PowerMeterComponent and state.KickDirectionComponent
			and state.Scene and state.CurrentBall

		if ready then
			task.wait(SHARP_DELAY)
			if sharpEnabled and controller:_CanContinue() then
				local ok, err = pcall(function()
					controller:SetPower(1)
					local scale = neededScale(state)
					state.PowerScale = scale
					task.wait(0.15)
					ctx.Log(string.format("[AutoSharp] round %s kick %s: power %.2f, aiming at the middle of the posts",
						tostring(state.RoundsCompleted), tostring((state.BallsKickedThisRound or 0) + 1), scale))
					controller:SetDirection(table.clone(SHARP_POSTS))
					-- the aim meter was never clicked, so close it the way a click would, if it can
					local meter = state.KickDirectionComponent
					if meter and type(meter.Disable) == "function" then pcall(meter.Disable, meter) end
				end)
				if not ok then
					ctx.Log("[AutoSharp] kick failed: " .. tostring(err), "warn")
					task.wait(1)
				end
			end
		else
			task.wait(0.5)
		end
	end
	sharpRunning = false
end

local function setSharpEnabled(value)
	sharpEnabled = value
	if value then
		if not loadSharpController() then return end
		ctx.Log("[AutoSharp] controller loaded; start the minigame from the game's menu")
		task.spawn(sharpLoop)
	end
end

-- ===== Auto Play (Cone Sprint Gauntlet minigame) =====
-- From dump1.luau (Minigames.ConeSprintGauntletController). While running, the game moves the
-- character forward on its own (Player:Move along State.CourseOrigin.LookVector); the player only
-- picks one of three lanes (controller:_MoveToLane(lane), what the left / right buttons call) or
-- jumps (Humanoid.Jump). Touching any part tagged Common.ObstacleTag fails the course
-- (Humanoid.Touched handler, line 430). At the end of the course the ball is kicked and the
-- player must stand within 2.5 studs of its landing spot (State.BallShadow marks it, line 575) when
-- it lands.
-- Each frame:
--  * RUNNING: look at the obstacles ahead on the current course. For the current lane and the two
--    neighbours, find the nearest obstacle that overlaps that lane; if the current lane is
--    blocked, move to whichever of the three has the most room (one lane at a time, like the
--    buttons). If no lane is better and the obstacle is low enough to clear, jump.
--  * CATCHING: while the ball is in the air, stand on its shadow (the landing spot).
-- Start the minigame from the game's menu; this plays it from there, round after round.
local LANE_HALF_WIDTH = 1.2 -- studs; the character's half width when judging overlap
local LANE_MOVE_COOLDOWN = 0.3 -- a lane change takes about 0.25 s (animation + tween)
local JUMPABLE_HEIGHT = 4.5 -- studs; JumpHeight is 5, minus a margin for the body
local JUMP_LEAD = 0.235 -- seconds before the obstacle's centre to take off (apex is at ~0.225 s)
local jumpedOver = setmetatable({}, { __mode = "k" }) -- obstacle -> when we last jumped for it
local jumpCourse -- the course jumpedOver belongs to
local watchedHumanoid, lastFailLog = nil, 0 -- humanoid whose Touched we log failures from
local lastInfo -- what the planner last saw, for the failure log
local pendingLane -- lane of the lane change currently in flight

local coneEnabled = false
local coneController, coneCommon
local coneConnection
local coneWarned = false
local lastLaneMove = 0
local wasCatching = false

local function loadConeController()
	if coneController then return coneController end
	local ok, result = pcall(function()
		local module = game:GetService("ReplicatedStorage").Client.Controllers.Minigames.ConeSprintGauntletController
		return { controller = require(module), common = require(module.Common) }
	end)
	if ok then
		coneController, coneCommon = result.controller, result.common
	elseif not coneWarned then
		coneWarned = true
		ctx.Log("[AutoCone] could not load ConeSprintGauntletController (are you in the AFL place?): " .. tostring(result), "warn")
	end
	return coneController
end

-- Position of a lane in the world, whether LaneOffsets holds CFrames or Vector3s.
local function lanePosition(origin, lane)
	local result = origin * coneCommon.LaneOffsets[lane]
	return typeof(result) == "CFrame" and result.Position or result
end

-- Half extent of a part measured along `axis` (a unit vector).
local function halfExtent(part, axis)
	local cf, size = part.CFrame, part.Size
	return 0.5 * (math.abs(axis:Dot(cf.RightVector)) * size.X
		+ math.abs(axis:Dot(cf.UpVector)) * size.Y
		+ math.abs(axis:Dot(cf.LookVector)) * size.Z)
end

-- Obstacles named like "AgilityHurdle" are jumped, never dodged.
local function isHurdle(part)
	return part.Name:lower():find("hurdle") ~= nil
		or (part.Parent ~= nil and part.Parent.Name:lower():find("hurdle") ~= nil)
end

-- Everything ahead on the course that can fail us, sorted by how soon we reach it.
-- Each entry: near / far (distance along the run to its near and far face), blocked[lane] (does it
-- overlap that lane), height above the floor, jumpable, and the part itself.
local function scanObstacles(state, root, humanoid, laneX, window)
	local origin = state.CourseOrigin
	local look, right = origin.LookVector, origin.RightVector
	local floorY = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
	local up = Vector3.new(0, 1, 0)

	local list = {}
	for _, obstacle in ipairs(game:GetService("CollectionService"):GetTagged(coneCommon.ObstacleTag)) do
		if obstacle:IsA("BasePart") and obstacle:IsDescendantOf(state.CurrentCourse) then
			local ahead = look:Dot(obstacle.Position - root.Position)
			local halfDepth = halfExtent(obstacle, look)
			if ahead + halfDepth > -1 and ahead - halfDepth < window then
				local lateral = right:Dot(obstacle.Position - origin.Position)
				local halfWidth = halfExtent(obstacle, right)
				local blocked, any = {}, false
				for lane = 1, 3 do
					blocked[lane] = math.abs(laneX[lane] - lateral) < halfWidth + LANE_HALF_WIDTH
					any = any or blocked[lane]
				end
				if any then
					local height = obstacle.Position.Y + halfExtent(obstacle, up) - floorY
					table.insert(list, {
						part = obstacle,
						near = math.max(ahead - halfDepth, 0),
						far = ahead + halfDepth,
						centre = ahead,
						depth = 2 * halfDepth,
						blocked = blocked,
						height = height,
						-- hurdles are meant to be jumped whatever the bounding box says
						jumpable = height <= JUMPABLE_HEIGHT or isHurdle(obstacle),
					})
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.near < b.near end)
	return list
end

-- Chooses the lane to be in while passing the FIRST obstacle so that the whole sequence ahead can
-- be passed with the fewest lane changes. A lane change needs room: about stepDist studs between
-- one obstacle's far face and the next one's near face. An obstacle blocks a lane unless it is low
-- enough to jump (that costs a little, so a free lane is preferred). Returns nil if no sequence of
-- lanes gets through everything.
local function planLane(obstacles, current, stepDist)
	local best = { [current] = { cost = 0 } }
	local passedFar = 0
	for index, obstacle in ipairs(obstacles) do
		local gap = obstacle.near - passedFar -- room to change lane before this obstacle
		local nextBest = {}
		for lane, info in pairs(best) do
			for target = 1, 3 do
				local steps = math.abs(target - lane)
				if steps == 0 or steps * stepDist <= gap then
					local passCost
					if not obstacle.blocked[target] then
						passCost = 0
					elseif obstacle.jumpable then
						passCost = 0.5
					end
					if passCost then
						local total = info.cost + steps + passCost
						local existing = nextBest[target]
						if not existing or total < existing.cost then
							nextBest[target] = { cost = total, first = index == 1 and target or info.first }
						end
					end
				end
			end
		end
		best = nextBest
		if next(best) == nil then return nil end
		passedFar = math.max(passedFar, obstacle.far)
	end

	local choice
	for _, info in pairs(best) do
		if not choice or info.cost < choice.cost then choice = info end
	end
	return choice and choice.first
end

-- Fallback when no lane sequence gets through: among the current lane and its neighbours, pick the
-- one whose first obstacle that cannot be jumped is farthest away (ties prefer staying put).
local function bestLaneByRoom(obstacles, current)
	local bestLane, bestRoom = current, -1
	for _, lane in ipairs({ current, current - 1, current + 1 }) do
		if lane >= 1 and lane <= 3 then
			local room = math.huge
			for _, obstacle in ipairs(obstacles) do
				if obstacle.blocked[lane] and not obstacle.jumpable then
					room = obstacle.near
					break
				end
			end
			if room > bestRoom then bestLane, bestRoom = lane, room end
		end
	end
	return bestLane
end

local planNote -- course we already logged a tight-sequence note for
local lastCensusCourse

-- Prints every obstacle of the course once, so unknown obstacle types can be identified from the log.
local function logCensus(state, root, humanoid, laneX)
	if lastCensusCourse == state.CurrentCourse then return end
	lastCensusCourse = state.CurrentCourse
	local origin = state.CourseOrigin
	local playerX = origin.RightVector:Dot(root.Position - origin.Position)
	local nearestLane, nearestGap = nil, math.huge
	for lane = 1, 3 do
		if math.abs(laneX[lane] - playerX) < nearestGap then
			nearestLane, nearestGap = lane, math.abs(laneX[lane] - playerX)
		end
	end
	local rawOffsets = {}
	for key, value in pairs(coneCommon.LaneOffsets) do
		table.insert(rawOffsets, string.format("[%s]=%s", tostring(key), tostring(value)))
	end
	table.sort(rawOffsets)
	local lines = {
		string.format("[AutoCone] course %s: lanes at x = %.1f / %.1f / %.1f; you are at x = %.1f (nearest lane %s, game says lane %s)",
			tostring(state.CurrentCourse.Name), laneX[1], laneX[2], laneX[3], playerX,
			tostring(nearestLane), tostring(state.CurrentLane)),
		"  LaneOffsets: " .. table.concat(rawOffsets, " "),
		string.format("  course origin %s, run direction %s", tostring(origin.Position), tostring(origin.LookVector)),
	}
	for _, o in ipairs(scanObstacles(state, root, humanoid, laneX, 10000)) do
		local lanes = {}
		for lane = 1, 3 do if o.blocked[lane] then table.insert(lanes, lane) end end
		table.insert(lines, string.format("  %s (%s) %.0f studs ahead, %.1f deep, %.1f tall, size %s, blocks lane(s) %s%s",
			o.part.Name, o.part.ClassName, o.near, o.far - o.near, o.height, tostring(o.part.Size),
			table.concat(lanes, ","), o.jumpable and " [jumpable]" or ""))
		if #lines > 40 then table.insert(lines, "  ...") break end
	end
	ctx.Log(table.concat(lines, "\n"))
end

local function dodgeStep(controller, state, root, humanoid)
	local origin = state.CourseOrigin
	local right = origin.RightVector
	local speed = humanoid.WalkSpeed
	local now = os.clock()

	-- lateral position (along the course's right axis) of each lane
	local laneX = {}
	for lane = 1, 3 do
		laneX[lane] = right:Dot(lanePosition(origin, lane) - origin.Position)
	end

	logCensus(state, root, humanoid, laneX)

	-- Failing a course = the humanoid touching an obstacle. Log exactly what we were doing then.
	if watchedHumanoid ~= humanoid then
		watchedHumanoid = humanoid
		ctx:Connect(humanoid.Touched, function(part)
			if not coneEnabled or not game:GetService("CollectionService"):HasTag(part, coneCommon.ObstacleTag) then return end
			local t = os.clock()
			if t - lastFailLog < 1 then return end
			lastFailLog = t

			local rootNow = humanoid.RootPart
			local info = lastInfo
			local up = Vector3.new(0, 1, 0)
			local top = part.Position.Y + halfExtent(part, up)
			local feet = rootNow and (rootNow.Position.Y - humanoid.HipHeight - rootNow.Size.Y / 2) or 0
			local jumpedAt = jumpedOver[part]
			ctx.Log(string.format(
				"[AutoCone] FAILED on course %s: touched %s (%s, size %s, %s). You were in lane %s%s, feet %.1f vs obstacle top %.1f, %s, %s, speed %.1f. Nearest obstacle at the last check: %s (centre %.1f ahead, blocks your lane: %s).",
				info and info.course or "?", part.Name, part.ClassName, tostring(part.Size),
				isHurdle(part) and "hurdle" or "not a hurdle",
				tostring(info and info.lane), (t - lastLaneMove < LANE_MOVE_COOLDOWN) and " (mid lane change)" or "",
				feet, top,
				humanoid.FloorMaterial == Enum.Material.Air and "airborne" or "on the ground",
				jumpedAt and string.format("jumped %.2fs ago", t - jumpedAt) or "never jumped for it",
				info and info.speed or 0,
				info and info.first and info.first.part.Name or "none",
				info and info.first and info.first.centre or 0,
				tostring(info and info.first and info.first.blocked[info.lane])))
		end)
	end

	-- The course models are reused every lap, so "already jumped" must not outlive a course.
	if jumpCourse ~= state.CurrentCourse then
		jumpCourse = state.CurrentCourse
		table.clear(jumpedOver)
	end

	local obstacles = scanObstacles(state, root, humanoid, laneX, speed * 2.5 + 25)
	local first = obstacles[1]
	if not first then return end

	-- While a lane change is in flight State.CurrentLane is still the old lane, so use the lane we
	-- are heading for. Lane planning waits for the change to land, but jumping must not.
	local moving = now - lastLaneMove < LANE_MOVE_COOLDOWN
	local current = (moving and pendingLane) or state.CurrentLane

	lastInfo = { first = first, lane = current, speed = speed, course = state.CurrentCourse.Name }

	-- Jump over any jumpable obstacle that fills our lane when it is about JUMP_LEAD seconds away.
	-- Every obstacle is checked (not just the nearest one), because a long or already-passed
	-- obstacle can sort ahead of the one we need to jump.
	local function jumpIfNeeded()
		if humanoid.FloorMaterial == Enum.Material.Air then return end
		for _, o in ipairs(obstacles) do
			if o.jumpable and o.blocked[current] and o.far > 0
				and o.centre <= speed * JUMP_LEAD and o.centre > -o.depth / 2 then
				local jumpedAt = jumpedOver[o.part]
				if not (jumpedAt and now - jumpedAt < 2.5) then
					jumpedOver[o.part] = now
					humanoid.Jump = true
					ctx.Log(string.format("[AutoCone] jumping %s (%.1f studs tall, %.1f deep, centre %.1f studs ahead, speed %.1f)",
						o.part.Name, o.height, o.depth, o.centre, speed))
					return
				end
			end
		end
	end

	if moving then
		jumpIfNeeded()
		return
	end

	-- A lane change lands about 0.25 s after the call (0.15 s animation + 0.1 s tween).
	local stepDist = speed * 0.25 + 1
	local target = planLane(obstacles, current, stepDist)
	local mode = "normal"

	-- Tight sequence (for example a hurdle right in front of a guard in the same lane): the safe
	-- route needs lane changes closer together than assumed. Try again with less room per change,
	-- then with none, so we still head for the lane that gets through the most.
	if not target then
		target, mode = planLane(obstacles, current, stepDist * 0.5), "half room"
	end
	if not target then
		target, mode = planLane(obstacles, current, 0), "no room"
	end
	-- Still nothing: no lane sequence clears everything. Take the neighbouring lane whose first
	-- un-jumpable obstacle is farthest away (the old fallback only looked at the nearest obstacle,
	-- which can be a hurdle in another lane).
	if not target then
		target, mode = bestLaneByRoom(obstacles, current), "most room"
	end
	if mode ~= "normal" and planNote ~= state.CurrentCourse then
		planNote = state.CurrentCourse
		ctx.Log(string.format("[AutoCone] tight sequence on %s: planning with %s (target lane %d)",
			state.CurrentCourse.Name, mode, target))
	end

	if target ~= current then
		-- one lane at a time, like the left / right buttons
		local nextLane = current + (target > current and 1 or -1)
		lastLaneMove = now
		pendingLane = nextLane
		task.spawn(function() controller:_MoveToLane(nextLane) end)
		ctx.Log(string.format("[AutoCone] %s ahead in %.1f studs -> lane %d (heading for %d)",
			first.part.Name, first.near, nextLane, target))
		return
	end

	-- staying in this lane: if the nearest obstacle fills it, it has to be jumped
	jumpIfNeeded()
end


local function coneStep()
	local controller = coneController
	local state = controller.State
	if not controller:_CanContinue() then return end

	local character = state.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and humanoid) then return end

	if state.IsRunning and state.CurrentCourse and state.CourseOrigin and state.CurrentLane then
		dodgeStep(controller, state, root, humanoid)
	elseif state.IsCatching and state.BallShadow and state.BallShadow.Parent then
		-- the ball is in the air: stand on its landing spot (the shadow)
		local target = state.BallShadow.Position
		if not wasCatching then
			wasCatching = true
			ctx.Log(string.format("[AutoCone] ball in the air, moving to its landing spot (%.0f, %.0f)", target.X, target.Z))
		end
		root.CFrame = CFrame.new(target.X, root.Position.Y, target.Z) * root.CFrame.Rotation
		root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0) -- don't drift off the spot
	else
		wasCatching = false
	end
end

local function setConeEnabled(value)
	coneEnabled = value
	if value then
		if not loadConeController() then return end
		ctx.Log("[AutoCone] controller loaded; start the minigame from the game's menu")
		if not coneConnection then
			coneConnection = ctx:Connect(RunService.Heartbeat, function()
				if coneEnabled then
					local ok, err = pcall(coneStep)
					if not ok and not coneWarned then
						coneWarned = true
						ctx.Log("[AutoCone] step failed: " .. tostring(err), "warn")
					end
				end
			end)
		end
	elseif coneConnection then
		coneConnection:Disconnect()
		coneConnection = nil
	end
end


-- ===== Panel =====
-- Subtabs group the features by place:
--   Universal: works anywhere (coins, quest items).
--   Cricket: Catching King, In The Nets.  Supercars: Pit Stop Panic.
--   AFL: Sharpshooter, Cone Sprint.

local Universal = ctx:SubTab("Universal", "Lucide:globe")
local Cricket = ctx:SubTab("Cricket", "Lucide:trophy")
local Supercars = ctx:SubTab("Supercars", "Lucide:car")
local AFL = ctx:SubTab("AFL", "Lucide:goal")

Universal:AddSection("Pickups", "Lucide:coins")

Universal:AddToggle({
	Text = "Auto Coin Pickup",
	Flag = "AutoCoinPickup",
	Description = "Teleports to every coin, nearest first, then returns",
	Default = false,
	Callback = setEnabled,
})

Universal:AddToggle({
	Text = "Auto Quest Items",
	Flag = "AutoQuestItems",
	Description = "Picks up every quest item through its prompt, then returns",
	Default = false,
	Callback = setQuestEnabled,
})

local StatsGrid = Universal:AddInfoGrid({
	Title = "Collected",
	Description = "Picked up since the script started",
	Columns = 3,
	Items = {
		{ Label = "Coins", Value = "0" },
		{ Label = "Coin Value", Value = "+0" },
		{ Label = "Quest Items", Value = "0" },
	},
})

Cricket:AddSection("Catching King", "Lucide:hand")

Cricket:AddToggle({
	Text = "Auto Catch Ball",
	Flag = "AutoCatchBall",
	Description = "Catches every ball at the right depth; misses don't count while on",
	Default = false,
	Callback = setCatchEnabled,
})

Cricket:AddSection("In The Nets", "Lucide:target")

Cricket:AddToggle({
	Text = "Auto Perfect Hit",
	Flag = "AutoPerfectHit",
	Description = "Swings at the ideal moment; every swing during a throw is graded Perfect",
	Default = false,
	Callback = setHitEnabled,
})

Supercars:AddSection("Pit Stop Panic", "Lucide:wrench")

Supercars:AddToggle({
	Text = "Auto Perfect Timing",
	Flag = "AutoPerfectTiming",
	Description = "Presses every lug nut / tire meter with the lowest time penalty",
	Default = false,
	Callback = setPitEnabled,
})

AFL:AddSection("Sharpshooter", "Lucide:goal")

AFL:AddToggle({
	Text = "Auto Play",
	Flag = "AutoSharpshooter",
	Description = "Kicks every ball through the middle of the posts; start the minigame from its menu",
	Default = false,
	Callback = setSharpEnabled,
})

AFL:AddSection("Cone Sprint", "Lucide:cone")

AFL:AddToggle({
	Text = "Auto Play",
	Flag = "AutoConeSprint",
	Description = "Dodges or jumps obstacles and catches the ball; start the minigame from its menu",
	Default = false,
	Callback = setConeEnabled,
})

onChanged = function()
	StatsGrid:SetValue("Coins", collected)
	StatsGrid:SetValue("Coin Value", "+" .. collectedValue)
	StatsGrid:SetValue("Quest Items", questCollected)
end
onChanged()

-- Turn every feature off at shutdown so the loops stop and the minigame controllers get their
-- original functions back.
ctx:OnCleanup(function()
	spoofedMouse = nil
	setEnabled(false)
	setQuestEnabled(false)
	setCatchEnabled(false)
	setHitEnabled(false)
	setPitEnabled(false)
	setSharpEnabled(false)
	setConeEnabled(false)
end)
