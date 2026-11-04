-- Linglox
local ctx = ...
local task = ctx.task

local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Mouse = Players.LocalPlayer:GetMouse()

local Prompts = workspace:WaitForChild("Prompts")

local espEnabled = false
local hideSolved = false
local autoFill = false
local hoveredPart = nil -- only the panel under the mouse gets its label shown
local nearbyEnabled = false
local nearbyDistance = 50
local nearbyParts = {} -- [panel BasePart] = true while within nearbyDistance

local espFolder = Instance.new("Folder")
espFolder.Name = "LingloxAnswerESP"
espFolder.Parent = (gethui and gethui()) or CoreGui
ctx:Track(espFolder)

-- One shared highlight that follows the hovered panel.
local highlight = Instance.new("Highlight")
highlight.Name = "HoverHighlight"
highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
highlight.FillTransparency = 0.65
highlight.OutlineTransparency = 0
highlight.Parent = espFolder

-- Roblox only renders 31 Highlights at once, so nearby panels share a fixed pool (1 is left for hover).
local MAX_NEARBY_HIGHLIGHTS = 30
local nearbyHighlights = {}
for i = 1, MAX_NEARBY_HIGHLIGHTS do
	local nearbyHighlight = highlight:Clone()
	nearbyHighlight.Name = "NearbyHighlight" .. i
	nearbyHighlight.Parent = espFolder
	nearbyHighlights[i] = nearbyHighlight
end

local billboards = {} -- [panel BasePart] = BillboardGui
local connections = {}

-- Same folder discovery the game uses: workspace.Prompts plus any "Stray" PromptsFolder.
local function getPromptFolders()
	local folders = { Prompts }
	for _, folder in CollectionService:GetTagged("PromptsFolder") do
		if folder:HasTag("Stray") then
			table.insert(folders, folder)
		end
	end
	return folders
end

-- Panel layout: <BasePart>.SurfaceGui.Frame.TextBox, answer stored on the Frame.
local function getAnswerFrames(part)
	local frames = {}
	for _, descendant in part:GetDescendants() do
		if descendant:IsA("TextBox") then
			local frame = descendant.Parent
			if frame and frame:IsA("Frame") and frame:GetAttribute("awnser") ~= nil then
				table.insert(frames, { frame = frame, textBox = descendant })
			end
		end
	end
	return frames
end

local function escapeRichText(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function buildText(frames)
	local lines = {}
	for _, entry in frames do
		local frame, textBox = entry.frame, entry.textBox
		local solved = not textBox.TextEditable
		if not (hideSolved and solved) then
			local answer = frame:GetAttribute("specialrealawnser") or frame:GetAttribute("awnser")
			local line = escapeRichText(answer)

			local alt = frame:GetAttribute("awnser_alt_1")
			if alt and alt ~= "" then
				line = line .. ' <font color="#A0A0A0">| ' .. escapeRichText(alt) .. "</font>"
			end

			local bonus = frame:GetAttribute("awnser2")
			if bonus and bonus ~= "" then
				line = line .. '\n<font color="#FFD54A">★ ' .. escapeRichText(bonus) .. "</font>"
			end

			table.insert(lines, line)
		end
	end
	return table.concat(lines, "\n")
end

local function refreshBillboard(part)
	local billboard = billboards[part]
	if not billboard then
		return
	end
	local text = buildText(getAnswerFrames(part))
	billboard.Label.Text = text
	local shown = (espEnabled and part == hoveredPart) or (nearbyEnabled and nearbyParts[part] == true)
	billboard.Enabled = shown and text ~= ""

	-- Text takes the panel's color; flip the outline to white on dark panels so it stays readable.
	local color = part.Color
	local _, _, brightness = color:ToHSV()
	billboard.Label.TextColor3 = color
	billboard.Label.TextStrokeColor3 = brightness < 0.35 and Color3.new(1, 1, 1) or Color3.new(0, 0, 0)

	if part == hoveredPart then
		highlight.FillColor = color
		highlight.OutlineColor = color
		highlight.Adornee = billboard.Enabled and part or nil
	elseif highlight.Adornee == part then
		highlight.Adornee = nil
	end
end

local function removeBillboard(part)
	local billboard = billboards[part]
	if billboard then
		billboard:Destroy()
		billboards[part] = nil
	end
	if connections[part] then
		for _, connection in connections[part] do
			connection:Disconnect()
		end
		connections[part] = nil
	end
end

local function addBillboard(part)
	if billboards[part] or not part:IsA("BasePart") then
		return
	end
	local frames = getAnswerFrames(part)
	if #frames == 0 then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = part.Name
	billboard.Adornee = part
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.fromOffset(260, 60)
	billboard.ExtentsOffsetWorldSpace = Vector3.new(0, 1, 0) -- sit on top of the panel
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.5, 0)
	billboard.Enabled = false

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.RichText = true
	label.TextSize = 16
	label.TextStrokeTransparency = 0
	label.TextWrapped = true
	label.TextYAlignment = Enum.TextYAlignment.Bottom
	label.Parent = billboard

	billboard.Parent = espFolder
	billboards[part] = billboard

	-- Answers can be rewritten at runtime (name/country prompts) and solving locks the TextBox.
	local partConnections = {}
	for _, entry in frames do
		table.insert(partConnections, ctx:Connect(entry.frame.AttributeChanged, function()
			refreshBillboard(part)
		end))
		table.insert(partConnections, ctx:Connect(entry.textBox:GetPropertyChangedSignal("TextEditable"), function()
			refreshBillboard(part)
		end))
	end
	table.insert(partConnections, ctx:Connect(part.AncestryChanged, function()
		if not part:IsDescendantOf(workspace) then
			removeBillboard(part)
		end
	end))
	connections[part] = partConnections

	refreshBillboard(part)
end

local function refreshAll()
	for part in billboards do
		refreshBillboard(part)
	end
end

local function scanFolder(folder)
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			addBillboard(descendant)
		end
	end
end

local watchedFolders = {}

local function watchFolder(folder)
	if watchedFolders[folder] then
		return
	end
	watchedFolders[folder] = ctx:Connect(folder.DescendantAdded, function(descendant)
		-- The TextBox can replicate after its part, so resolve the owning part from either end.
		local part = descendant:IsA("BasePart") and descendant or descendant:FindFirstAncestorWhichIsA("BasePart")
		if part and part:IsDescendantOf(folder) then
			task.defer(function()
				if billboards[part] then
					refreshBillboard(part)
				else
					addBillboard(part)
				end
			end)
		end
	end)
	scanFolder(folder)
end

local function watchPromptFolders()
	for _, folder in getPromptFolders() do
		watchFolder(folder)
	end
end

local function setEspEnabled(enabled)
	espEnabled = enabled
	if enabled then
		watchPromptFolders()
	end
	refreshAll()
end

local function updateNearby()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local inRange = {}
	local sorted = {}
	if root then
		local origin = root.Position
		for part in billboards do
			local distance = (part.Position - origin).Magnitude
			if distance <= nearbyDistance then
				inRange[part] = true
				table.insert(sorted, { part = part, distance = distance })
			end
		end
	end

	local previous = nearbyParts
	nearbyParts = inRange
	for part in previous do
		if not inRange[part] then
			refreshBillboard(part)
		end
	end
	for part in inRange do
		if not previous[part] then
			refreshBillboard(part)
		end
	end

	-- Hand the highlight pool to the closest panels that actually have a visible label.
	table.sort(sorted, function(a, b)
		return a.distance < b.distance
	end)
	local used = 0
	for _, entry in sorted do
		if used >= MAX_NEARBY_HIGHLIGHTS then
			break
		end
		local billboard = billboards[entry.part]
		if billboard and billboard.Enabled then
			used = used + 1
			local nearbyHighlight = nearbyHighlights[used]
			nearbyHighlight.FillColor = entry.part.Color
			nearbyHighlight.OutlineColor = entry.part.Color
			nearbyHighlight.Adornee = entry.part
		end
	end
	for i = used + 1, MAX_NEARBY_HIGHLIGHTS do
		nearbyHighlights[i].Adornee = nil
	end
end

local nearbyThread = nil

local function setNearbyEnabled(enabled)
	nearbyEnabled = enabled
	if nearbyThread then
		task.cancel(nearbyThread)
		nearbyThread = nil
	end
	if enabled then
		watchPromptFolders()
		nearbyThread = task.spawn(function()
			while true do
				updateNearby()
				task.wait(0.2)
			end
		end)
	else
		local previous = nearbyParts
		nearbyParts = {}
		for part in previous do
			refreshBillboard(part)
		end
		for _, nearbyHighlight in nearbyHighlights do
			nearbyHighlight.Adornee = nil
		end
	end
end

-- The mouse can land on a child part of the panel, so walk up until we hit a tracked panel.
local function getPanelFromTarget(target)
	while target and target ~= workspace do
		if billboards[target] then
			return target
		end
		target = target.Parent
	end
	return nil
end

ctx:Connect(RunService.RenderStepped, function()
	local panel = espEnabled and getPanelFromTarget(Mouse.Target) or nil
	if panel == hoveredPart then
		return
	end
	local previous = hoveredPart
	hoveredPart = panel
	if previous then
		refreshBillboard(previous)
	end
	if panel then
		refreshBillboard(panel)
	end
end)

local function isInPromptFolder(instance)
	for _, folder in getPromptFolders() do
		if instance:IsDescendantOf(folder) then
			return true
		end
	end
	return false
end

-- Typing the answer into the TextBox triggers the game's own Text-changed solve check.
ctx:Connect(UserInputService.TextBoxFocused, function(textBox)
	if not autoFill or not textBox.TextEditable then
		return
	end
	local frame = textBox.Parent
	local answer = frame and frame:GetAttribute("awnser")
	if not answer or answer == "" or not isInPromptFolder(textBox) then
		return
	end
	-- Defer so ClearTextOnFocus runs first and doesn't wipe the filled answer.
	task.defer(function()
		textBox:ReleaseFocus()
		textBox.Text = answer
	end)
end)

-- Progress counter
local progressGui = Instance.new("ScreenGui")
progressGui.Name = "LingloxProgress"
progressGui.ResetOnSpawn = false
progressGui.IgnoreGuiInset = true
progressGui.DisplayOrder = 50
progressGui.Enabled = false
progressGui.Parent = espFolder.Parent
ctx:Track(progressGui)

local progressFrame = Instance.new("Frame")
progressFrame.AnchorPoint = Vector2.new(0.5, 0)
progressFrame.Position = UDim2.new(0.5, 0, 0, 12)
progressFrame.Size = UDim2.fromOffset(240, 58)
progressFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 24)
progressFrame.BackgroundTransparency = 0.2
progressFrame.BorderSizePixel = 0
progressFrame.Parent = progressGui
Instance.new("UICorner", progressFrame).CornerRadius = UDim.new(0, 10)

local progressLabel = Instance.new("TextLabel")
progressLabel.BackgroundTransparency = 1
progressLabel.Position = UDim2.fromOffset(12, 6)
progressLabel.Size = UDim2.new(1, -24, 0, 30)
progressLabel.Font = Enum.Font.GothamBold
progressLabel.RichText = true
progressLabel.TextSize = 16
progressLabel.TextColor3 = Color3.new(1, 1, 1)
progressLabel.Text = ""
progressLabel.Parent = progressFrame

local progressBarBack = Instance.new("Frame")
progressBarBack.Position = UDim2.new(0, 12, 1, -16)
progressBarBack.Size = UDim2.new(1, -24, 0, 6)
progressBarBack.BackgroundColor3 = Color3.fromRGB(60, 64, 68)
progressBarBack.BorderSizePixel = 0
progressBarBack.Parent = progressFrame
Instance.new("UICorner", progressBarBack).CornerRadius = UDim.new(1, 0)

local progressBarFill = progressBarBack:Clone()
progressBarFill.Position = UDim2.fromScale(0, 0)
progressBarFill.Size = UDim2.fromScale(0, 1)
progressBarFill.BackgroundColor3 = Color3.fromRGB(80, 220, 120)
progressBarFill.Parent = progressBarBack

-- A panel is solved once the game locks its TextBox (TextEditable = false).
local function countProgress()
	local solved, total = 0, 0
	for _, folder in getPromptFolders() do
		for _, descendant in folder:GetDescendants() do
			if descendant:IsA("TextBox") then
				local frame = descendant.Parent
				if frame and frame:IsA("Frame") and frame:GetAttribute("awnser") ~= nil then
					total = total + 1
					if not descendant.TextEditable then
						solved = solved + 1
					end
				end
			end
		end
	end
	return solved, total
end

local function updateProgress()
	local solved, total = countProgress()
	progressLabel.Text = string.format(
		'<font color="#50DC78">Solved %d</font>   <font color="#FF8A65">Left %d</font>',
		solved,
		total - solved
	)
	progressBarFill.Size = UDim2.fromScale(total > 0 and solved / total or 0, 1)
end

local progressThread = nil

local function setProgressEnabled(enabled)
	progressGui.Enabled = enabled
	if progressThread then
		task.cancel(progressThread)
		progressThread = nil
	end
	if enabled then
		progressThread = task.spawn(function()
			while true do
				updateProgress()
				task.wait(1)
			end
		end)
	end
end

-- Auto solve: teleport to the closest unsolved panel, type its answer, repeat.
local autoSolveDelay = 0.5
local autoSolveThread = nil
local autoSolveSkipped = {} -- [TextBox] = true for panels that refused to solve
local autoSolveToggle = nil

-- Skips panels still locked behind a prereq (the game hides their TextBox or SurfaceGui).
local function isSolvable(textBox)
	if not textBox.TextEditable or not textBox.Visible or autoSolveSkipped[textBox] then
		return false
	end
	local surfaceGui = textBox:FindFirstAncestorWhichIsA("SurfaceGui")
	if not surfaceGui or not surfaceGui.Enabled then
		return false
	end
	local answer = textBox.Parent:GetAttribute("awnser")
	return type(answer) == "string" and answer ~= ""
end

local function findNearestUnsolved(origin)
	local best, bestDistance = nil, math.huge
	for _, folder in getPromptFolders() do
		for _, descendant in folder:GetDescendants() do
			if descendant:IsA("TextBox") then
				local frame = descendant.Parent
				if frame and frame:IsA("Frame") and frame:GetAttribute("awnser") ~= nil and isSolvable(descendant) then
					local part = descendant:FindFirstAncestorWhichIsA("BasePart")
					if part then
						local distance = (part.Position - origin).Magnitude
						if distance < bestDistance then
							best, bestDistance = descendant, distance
						end
					end
				end
			end
		end
	end
	return best
end

-- Stand a few studs out from the face the SurfaceGui is drawn on, looking at the panel.
local function teleportToPanel(root, textBox)
	local part = textBox:FindFirstAncestorWhichIsA("BasePart")
	local surfaceGui = textBox:FindFirstAncestorWhichIsA("SurfaceGui")
	local localNormal = Vector3.FromNormalId(surfaceGui.Face)
	local normal = part.CFrame:VectorToWorldSpace(localNormal)
	local extent = (part.Size * localNormal).Magnitude / 2
	local position = part.Position + normal * (extent + 4)
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.lookAt(position, Vector3.new(part.Position.X, position.Y, part.Position.Z))
end

local function stopAutoSolve(message)
	autoSolveThread = nil
	if autoSolveToggle then
		autoSolveToggle:Set(false, true)
	end
	ctx.Notify(message, "info", 4)
end

-- Returns false once there's nothing left to solve.
local function solveNextPanel(root)
	local textBox = findNearestUnsolved(root.Position)
	if not textBox then
		return false
	end

	teleportToPanel(root, textBox)
	task.wait(autoSolveDelay)

	if textBox.Parent and textBox.TextEditable then
		-- Same path as typing it: the game's Text-changed handler checks and saves the solve.
		textBox.Text = textBox.Parent:GetAttribute("awnser")
		local started = os.clock()
		while textBox.Parent and textBox.TextEditable and os.clock() - started < 2 do
			task.wait(0.1)
		end
		if textBox.Parent and textBox.TextEditable then
			autoSolveSkipped[textBox] = true
		end
	end
	return true
end

local function autoSolveLoop()
	while true do
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			task.wait(1)
		elseif not solveNextPanel(root) then
			stopAutoSolve("No unsolved panels left.")
			return
		end
	end
end

local function setAutoSolveEnabled(enabled)
	if autoSolveThread then
		task.cancel(autoSolveThread)
		autoSolveThread = nil
	end
	if enabled then
		table.clear(autoSolveSkipped)
		autoSolveThread = task.spawn(autoSolveLoop)
	end
end

-- UI
local MainTab = ctx:SubTab("Main", "Lucide:house")

MainTab:AddSection("Hover for Answer", "Lucide:eye")

MainTab:AddToggle({
	Text = "Hover for Answer",
	Description = "Shows a panel's answer above it while you hover it",
	Default = false,
	Callback = setEspEnabled,
})

MainTab:AddToggle({
	Text = "Hide Solved",
	Description = "Skips panels you've already answered",
	Default = false,
	Callback = function(enabled)
		hideSolved = enabled
		refreshAll()
	end,
})

MainTab:AddSection("Nearby Answers", "Lucide:radar")

MainTab:AddToggle({
	Text = "Nearby Answers",
	Description = "Shows and highlights answers for panels around you",
	Default = false,
	Callback = setNearbyEnabled,
})

MainTab:AddSlider({
	Text = "Nearby Distance",
	Min = 10,
	Max = 500,
	Default = nearbyDistance,
	Increment = 5,
	Suffix = " studs",
	Callback = function(value)
		nearbyDistance = value
	end,
})

MainTab:AddSection("Auto Fill", "Lucide:pencil")

MainTab:AddToggle({
	Text = "Auto Fill Answer",
	Description = "Clicking a panel's textbox types the answer in",
	Default = false,
	Callback = function(enabled)
		autoFill = enabled
	end,
})

MainTab:AddSection("Auto Solve", "Lucide:zap")

autoSolveToggle = MainTab:AddToggle({
	Text = "Auto Solve",
	Description = "Teleports to the nearest unsolved panel and solves it, then moves on",
	Default = false,
	Callback = setAutoSolveEnabled,
})

MainTab:AddSlider({
	Text = "Auto Solve Delay",
	Min = 0.1,
	Max = 3,
	Default = autoSolveDelay,
	Increment = 0.1,
	Suffix = "s",
	Callback = function(value)
		autoSolveDelay = value
	end,
})

MainTab:AddSection("Progress", "Lucide:list-checks")

MainTab:AddToggle({
	Text = "Show Progress",
	Description = "On-screen count of solved and remaining panels",
	Default = false,
	Callback = setProgressEnabled,
})
