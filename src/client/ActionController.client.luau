local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local actionUI = playerGui:WaitForChild("ActionUI")
local frame = actionUI:WaitForChild("Frame")
local playerList = frame:WaitForChild("PlayerList")
local submitButton = frame:WaitForChild("SubmitButton")

local DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)
local SELECTED_COLOR = Color3.fromRGB(0, 170, 0)

local selectedTarget: string? = nil

local function resetButtonColors()
	for _, child in playerList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectTarget(targetName: string, clickedButton: TextButton)
	selectedTarget = targetName
	resetButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populatePlayerList()
	for _, child in playerList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer then
			local button = Instance.new("TextButton")
			button.Name = player.Name
			button.Text = player.Name
			button.Size = UDim2.new(1, 0, 0, 50)
			button.BackgroundColor3 = DEFAULT_COLOR
			button.Parent = playerList

			button.MouseButton1Click:Connect(function()
				selectTarget(player.Name, button)
			end)
		end
	end
end

local function updateVisibility()
	local isSecretMeetings = CurrentGameState.Value:find("Secret Meetings") ~= nil
	actionUI.Enabled = isSecretMeetings

	if isSecretMeetings then
		populatePlayerList()
	end
end

updateVisibility()
CurrentGameState:GetPropertyChangedSignal("Value"):Connect(updateVisibility)

submitButton.MouseButton1Click:Connect(function()
	if not selectedTarget then
		return
	end

	ActionRequest:FireServer("OrderMurder", selectedTarget)
	selectedTarget = nil
	resetButtonColors()
end)
