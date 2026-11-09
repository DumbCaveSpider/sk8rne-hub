-- Scripting School
local ctx = ...
local task = ctx.task

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local Settings = {
	AutoAnswer = false,
}

-- The active lesson keeps its answer in a "Required" StringValue inside its ScreenGui.
local function findLesson()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("StringValue") and descendant.Name == "Required" then
			local value = descendant.Value
			if type(value) == "string" and value ~= "" then
				local gui = descendant
				while gui.Parent and gui.Parent ~= playerGui do
					gui = gui.Parent
				end
				if gui.Parent == playerGui and gui:IsA("ScreenGui") and gui.Enabled then
					return gui, value
				end
			end
		end
	end
	return nil
end

local function answerTextBox(textBox)
	if not textBox or not Settings.AutoAnswer then
		return
	end
	local gui, answer = findLesson()
	if not gui then
		return
	end
	-- Only answer the lesson's own input, never the chat bar or other text boxes.
	if not textBox:IsDescendantOf(gui) then
		return
	end
	textBox.Text = answer
end

ctx:Connect(UserInputService.TextBoxFocused, function(textBox)
	if Settings.AutoAnswer then
		task.defer(answerTextBox, textBox)
	end
end)

ctx:Connect(UserInputService.InputBegan, function(input)
	if not Settings.AutoAnswer then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	-- Let the click focus the text box, then fill it with the answer.
	task.defer(function()
		local textBox = UserInputService:GetFocusedTextBox()
		if textBox then
			answerTextBox(textBox)
		end
	end)
end)

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local Main = ctx:SubTab("Main", "Lucide:house")

Main:AddSection("Lessons", "Lucide:code")
Main:AddToggle({
	Text = "Auto Answer",
	Description = "Fills the lesson text box with the required answer when you click it",
	Icon = "Lucide:keyboard",
	Default = false,
	Flag = "ss_auto_answer",
	Callback = function(value)
		Settings.AutoAnswer = value
	end,
})

ctx:OnCleanup(function()
	Settings.AutoAnswer = false
end)
