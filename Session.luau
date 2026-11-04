-- A Session owns everything one run of the hub creates, so the next run can undo all of it.
-- Game modules receive it as `ctx` (see CONVENTIONS.md for the API they use).

local rawTask = task
local genv = (getgenv and getgenv()) or _G

local HUB_CONFIG = "Sk8rneHub_Settings"
local HUB_FLAG_PREFIX = "hub_"
local AUTOSAVE_DELAY = 1.5
local MAX_LOG_LINES = 500

local CONTROL_KINDS = {
	AddToggle = "Toggle",
	AddSlider = "Slider",
	AddDropdown = "Dropdown",
	AddTextbox = "Textbox",
	AddColorPicker = "ColorPicker",
	AddKeybind = "Keybind",
}

local LOG_TYPES = {
	info = Enum.MessageType.MessageInfo,
	warn = Enum.MessageType.MessageWarning,
	error = Enum.MessageType.MessageError,
}

local Session = {}
Session.__index = Session

---------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------

function Session.new(hub, VindUI, Window, gameDef)
	local self = setmetatable({
		Hub = hub,
		VindUI = VindUI,
		Window = Window,
		Game = gameDef,
		GameTab = nil,
		Destroyed = false,

		_cleanups = {},
		_tracked = {},
		_threads = {},
		_attributes = {},
		_hookRemovers = {},
		_toggles = {},
		_controls = {},
		_usedFlags = {},
		_deferred = nil,
		_loading = false,
		_autosaveToken = 0,
		_buildThread = nil,
		_console = nil,
		_logLines = {},
	}, Session)

	-- Plain closures so they can be passed around and called without a colon.
	function self.Log(message, level)
		self:_log(message, level)
	end

	function self.Notify(text, kind, duration)
		self.VindUI:Notify({
			Title = self.Game and self.Game.Name or self.Hub.Name,
			Text = tostring(text),
			Type = kind or "info",
			Duration = duration or 4,
		})
	end

	-- Drop-in replacement for the task library whose threads are cancelled with the session.
	self.task = setmetatable({
		spawn = function(fn, ...)
			return self:_trackThread(rawTask.spawn, fn, ...)
		end,
		defer = function(fn, ...)
			return self:_trackThread(rawTask.defer, fn, ...)
		end,
		delay = function(seconds, fn, ...)
			return self:_trackThread(rawTask.delay, seconds, fn, ...)
		end,
	}, { __index = rawTask })

	return self
end

function Session:Alive()
	return not self.Destroyed
end

---------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------

function Session:_log(message, level)
	level = level or "info"
	local prefix = self.Game and self.Game.Key or "Hub"
	local line = string.format("[%s] %s", prefix, tostring(message))

	table.insert(self._logLines, { Line = line, Type = LOG_TYPES[level] or LOG_TYPES.info })
	if #self._logLines > MAX_LOG_LINES then
		table.remove(self._logLines, 1)
	end
	if self._console then
		pcall(self._console.Log, self._console, line, LOG_TYPES[level] or LOG_TYPES.info)
	end
end

function Session:AttachConsole(console)
	self._console = console
	for _, entry in ipairs(self._logLines) do
		pcall(console.Log, console, entry.Line, entry.Type)
	end
end

function Session:GetLogText()
	local lines = {}
	for _, entry in ipairs(self._logLines) do
		table.insert(lines, entry.Line)
	end
	return table.concat(lines, "\n")
end

function Session:ClearLogs()
	table.clear(self._logLines)
	if self._console then
		pcall(self._console.Clear, self._console)
	end
end

---------------------------------------------------------------------
-- Resource tracking
---------------------------------------------------------------------

function Session:_trackThread(scheduler, ...)
	if self.Destroyed then
		return coroutine.create(function() end)
	end
	local thread = scheduler(...)
	table.insert(self._threads, thread)
	if #self._threads > 2048 then
		local alive = {}
		for _, t in ipairs(self._threads) do
			if coroutine.status(t) ~= "dead" then
				table.insert(alive, t)
			end
		end
		self._threads = alive
	end
	return thread
end

-- Accepts a connection, Instance, thread, cleanup function, or any object with
-- Disconnect/Destroy/Remove (Drawing objects included). Returns what it was given.
function Session:Track(resource)
	if self.Destroyed then
		self:_release(resource)
		return resource
	end
	table.insert(self._tracked, resource)
	return resource
end

function Session:_release(resource)
	local kind = typeof(resource)
	if kind == "function" then
		pcall(resource)
	elseif kind == "thread" then
		pcall(rawTask.cancel, resource)
	elseif kind == "RBXScriptConnection" then
		pcall(resource.Disconnect, resource)
	elseif kind == "Instance" then
		pcall(resource.Destroy, resource)
	else
		for _, method in ipairs({ "Disconnect", "Destroy", "Remove" }) do
			local ok, fn = pcall(function()
				return resource[method]
			end)
			if ok and type(fn) == "function" then
				pcall(fn, resource)
				break
			end
		end
	end
end

function Session:Connect(signal, callback)
	return self:Track(signal:Connect(callback))
end

function Session:OnCleanup(fn)
	table.insert(self._cleanups, fn)
	return fn
end

-- Sets an attribute and remembers the original value so it is put back when the session ends.
function Session:SetAttribute(instance, name, value)
	local byName = self._attributes[instance]
	if not byName then
		byName = {}
		self._attributes[instance] = byName
	end
	if byName[name] == nil then
		byName[name] = { Original = instance:GetAttribute(name) }
	end
	instance:SetAttribute(name, value)
end

---------------------------------------------------------------------
-- Hooks
--
-- The hook itself lives in getgenv() and is only ever installed once, so running the hub again
-- never stacks hooks. Each session plugs handlers into it and removes them when it ends; with
-- no handlers left the hook just calls straight through to the original.
--
-- A handler receives the next function in the chain first: handler(nextFn, ...).
---------------------------------------------------------------------

local function getHookRegistry()
	local registry = genv.__Sk8rneHooks
	if not registry then
		registry = { Meta = {}, Functions = {} }
		genv.__Sk8rneHooks = registry
	end
	return registry
end

local function rebuildChain(entry)
	local call = function(...)
		return entry.Original(...)
	end
	for _, handler in ipairs(entry.Handlers) do
		local nextFn = call
		call = function(...)
			return handler(nextFn, ...)
		end
	end
	entry.Call = call
end

local function newEntry()
	local entry = { Handlers = {} }
	rebuildChain(entry)
	entry.Dispatch = function(...)
		return entry.Call(...)
	end
	return entry
end

function Session:_addHandler(entry, handler)
	table.insert(entry.Handlers, handler)
	rebuildChain(entry)
	local function remove()
		local index = table.find(entry.Handlers, handler)
		if index then
			table.remove(entry.Handlers, index)
			rebuildChain(entry)
		end
	end
	table.insert(self._hookRemovers, remove)
	return remove
end

function Session:HookMeta(object, method, handler)
	if not hookmetamethod then
		self.Log("hookmetamethod is unavailable; skipped " .. method .. " hook", "warn")
		return nil
	end
	local registry = getHookRegistry()
	local byMethod = registry.Meta[object]
	if not byMethod then
		byMethod = {}
		registry.Meta[object] = byMethod
	end
	local entry = byMethod[method]
	if not entry then
		entry = newEntry()
		local replacement = newcclosure and newcclosure(entry.Dispatch) or entry.Dispatch
		entry.Original = hookmetamethod(object, method, replacement)
		byMethod[method] = entry
	end
	return self:_addHandler(entry, handler)
end

function Session:HookFunction(target, handler)
	if not hookfunction then
		self.Log("hookfunction is unavailable; skipped a function hook", "warn")
		return nil
	end
	local registry = getHookRegistry()
	local entry = registry.Functions[target]
	if not entry then
		entry = newEntry()
		local isC = iscclosure and iscclosure(target)
		local replacement = (isC and newcclosure) and newcclosure(entry.Dispatch) or entry.Dispatch
		entry.Original = hookfunction(target, replacement)
		registry.Functions[target] = entry
	end
	return self:_addHandler(entry, handler)
end

---------------------------------------------------------------------
-- UI: tab proxies add saved flags, safe callbacks and shutdown tracking to every control
---------------------------------------------------------------------

local function sanitize(text)
	return (tostring(text):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

function Session:_autoFlag(scope, text)
	local base = sanitize(scope) .. "_" .. sanitize(text)
	local flag = base
	local suffix = 2
	while self._usedFlags[flag] do
		flag = base .. "_" .. suffix
		suffix += 1
	end
	return flag
end

function Session:_safeCall(label, callback, ...)
	local results = table.pack(xpcall(callback, debug.traceback, ...))
	if not results[1] then
		self.Log(label .. " failed:\n" .. tostring(results[2]), "error")
	end
end

function Session:_addControl(realTab, method, scope, options)
	options = table.clone(options or {})
	local kind = CONTROL_KINDS[method]
	local label = options.Text or kind
	local saved = options.Flag ~= false

	if saved then
		options.Flag = options.Flag or self:_autoFlag(scope, label)
		self._usedFlags[options.Flag] = true
	else
		options.Flag = nil
	end

	local callback = options.Callback
	local control
	options.Callback = function(...)
		if kind == "Toggle" and self._deferred then
			-- While a config loads, toggles wait until every slider and dropdown has its value.
			table.insert(self._deferred, { callback, label, table.pack(...) })
		elseif callback then
			self:_safeCall(label, callback, ...)
		end

		local isKeypress = kind == "Keybind" and select(2, ...) == "press"
		if saved and not isKeypress then
			self:MarkDirty()
		end
	end

	control = realTab[method](realTab, options)

	if kind == "Toggle" then
		table.insert(self._toggles, control)
	end
	if saved then
		table.insert(self._controls, { Flag = options.Flag, Kind = kind, Control = control, Default = options.Default })
	end
	return control
end

function Session:_proxy(realTab, scope)
	local session = self
	return setmetatable({ Real = realTab }, {
		__index = function(proxy, key)
			local value = realTab[key]
			if type(value) ~= "function" then
				return value
			end

			local wrapped
			if CONTROL_KINDS[key] then
				wrapped = function(_, options)
					return session:_addControl(realTab, key, scope, options)
				end
			elseif key == "AddButton" then
				wrapped = function(_, options)
					options = table.clone(options or {})
					local callback = options.Callback
					options.Callback = function(...)
						if callback then
							session:_safeCall(options.Text or "Button", callback, ...)
						end
					end
					return value(realTab, options)
				end
			else
				wrapped = function(_, ...)
					return value(realTab, ...)
				end
			end
			rawset(proxy, key, wrapped)
			return wrapped
		end,
	})
end

function Session:AttachGameTab(tab)
	self.GameTab = tab
end

-- Used by game modules to create their subtabs.
function Session:SubTab(name, icon)
	local real = self.GameTab:AddSubTab({ Name = name, Icon = icon })
	return self:_proxy(real, name)
end

-- Used by the hub's own tabs.
function Session:WrapTab(tab, scope)
	return self:_proxy(tab, scope)
end

function Session:FinishGameTab()
	pcall(function()
		self.GameTab:SelectSubTab(1)
	end)
end

function Session:ShowGameError(message)
	if not self.GameTab then
		return
	end
	pcall(function()
		self.GameTab:AddParagraph({
			Title = "Failed to Load",
			Icon = "Lucide:triangle-alert",
			Text = message,
		})
	end)
end

function Session:SetBuildThread(thread)
	self._buildThread = thread
end

---------------------------------------------------------------------
-- Config
--
-- Hub settings and each game's settings live in separate files, so saving in one game never
-- overwrites another game's values and the toggle key is shared by all of them. SaveConfig always
-- writes every registered flag, so the flag table is narrowed for the duration of each save.
---------------------------------------------------------------------

local function isHubFlag(flag)
	return string.sub(flag, 1, #HUB_FLAG_PREFIX) == HUB_FLAG_PREFIX
end

function Session:_saveScoped(name, wantHubFlags)
	local VindUI = self.VindUI
	local allFlags = VindUI.Flags
	local scoped = {}
	for flag, api in pairs(allFlags) do
		if isHubFlag(flag) == wantHubFlags then
			scoped[flag] = api
		end
	end
	VindUI.Flags = scoped
	local ok, success, err = pcall(VindUI.SaveConfig, VindUI, name)
	VindUI.Flags = allFlags
	if not ok then
		return false, success
	end
	return success, err
end

function Session:GameConfigName()
	return self.Game and ("Sk8rneHub_" .. self.Game.Key) or nil
end

function Session:SaveConfig()
	local ok, err = self:_saveScoped(HUB_CONFIG, true)
	local gameConfig = self:GameConfigName()
	if ok and gameConfig then
		ok, err = self:_saveScoped(gameConfig, false)
	end
	if not ok then
		self.Log("Could not save config: " .. tostring(err), "error")
	end
	return ok, err
end

function Session:LoadHubConfig()
	self._loading = true
	local ok = self.VindUI:LoadConfig(HUB_CONFIG, false)
	self._loading = false
	return ok == true
end

-- Applies saved values with callbacks on (`false` = not silent), so features actually start.
function Session:LoadGameConfig()
	local gameConfig = self:GameConfigName()
	if not gameConfig then
		return false
	end

	self._loading = true
	self._deferred = {}
	local ok, err = pcall(self.VindUI.LoadConfig, self.VindUI, gameConfig, false)
	local deferred = self._deferred
	self._deferred = nil

	for _, entry in ipairs(deferred) do
		local callback, label, args = entry[1], entry[2], entry[3]
		if callback then
			rawTask.spawn(function()
				self:_safeCall(label, callback, table.unpack(args, 1, args.n))
			end)
		end
	end
	self._loading = false

	if not ok then
		self.Log("Could not load config: " .. tostring(err), "error")
		return false
	end
	return err == true
end

-- Puts every game control back to its default and removes the saved file.
function Session:ResetGameConfig()
	self._loading = true
	for _, entry in ipairs(self._controls) do
		if not isHubFlag(entry.Flag) then
			local default = entry.Default
			if default == nil and entry.Kind == "Toggle" then
				default = false
			end
			if default ~= nil then
				pcall(entry.Control.Set, entry.Control, default)
			end
		end
	end
	self._loading = false

	local gameConfig = self:GameConfigName()
	if gameConfig then
		pcall(self.VindUI.DeleteConfig, self.VindUI, gameConfig)
	end
end

function Session:SetAutoSave(enabled)
	self._autosave = enabled
end

function Session:MarkDirty()
	if self._loading or self.Destroyed or not self._autosave then
		return
	end
	self._autosaveToken += 1
	local token = self._autosaveToken
	rawTask.delay(AUTOSAVE_DELAY, function()
		if token == self._autosaveToken and not self.Destroyed and self._autosave then
			self:SaveConfig()
		end
	end)
end

---------------------------------------------------------------------
-- Shutdown
---------------------------------------------------------------------

function Session:Destroy()
	if self.Destroyed then
		return
	end
	-- Autosave must stop first: switching the toggles off below must not overwrite the saved config.
	self._autosave = false
	self._autosaveToken += 1
	self._deferred = nil

	-- Non-silent, so each feature's own callback runs and restores what it changed.
	for _, toggle in ipairs(self._toggles) do
		pcall(function()
			if toggle:Get() then
				toggle:Set(false)
			end
		end)
	end
	self.Destroyed = true
	rawTask.wait(0.05)

	for index = #self._cleanups, 1, -1 do
		rawTask.spawn(pcall, self._cleanups[index])
	end
	table.clear(self._cleanups)

	for _, remove in ipairs(self._hookRemovers) do
		pcall(remove)
	end
	table.clear(self._hookRemovers)

	for index = #self._tracked, 1, -1 do
		self:_release(self._tracked[index])
	end
	table.clear(self._tracked)

	local current = coroutine.running()
	for _, thread in ipairs(self._threads) do
		if thread ~= current then
			pcall(rawTask.cancel, thread)
		end
	end
	table.clear(self._threads)
	if self._buildThread and self._buildThread ~= current then
		pcall(rawTask.cancel, self._buildThread)
	end

	for instance, byName in pairs(self._attributes) do
		for name, saved in pairs(byName) do
			pcall(instance.SetAttribute, instance, name, saved.Original)
		end
	end
	table.clear(self._attributes)

	self._console = nil
	pcall(function()
		self.VindUI:Unload()
	end)
	if genv.__Sk8rneHub == self then
		genv.__Sk8rneHub = nil
	end
end

return Session
