local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")
local ExecutionPrompt = ReplicatedStorage:WaitForChild("ExecutionPrompt")
local RoleAssigned = ReplicatedStorage:WaitForChild("RoleAssigned")
local GetMyRole = ReplicatedStorage:WaitForChild("GetMyRole")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local actionUI = playerGui:WaitForChild("ActionUI")
local kingMurderAbility = actionUI:WaitForChild("KingMurderAbility")
local playerList = kingMurderAbility:WaitForChild("PlayerList")
local submitButton = kingMurderAbility:WaitForChild("SubmitButton")

local executionerMenu = actionUI:WaitForChild("ExecutionerMenu")
local targetDisplay = executionerMenu:WaitForChild("TargetDisplay")
local confirmKillButton = executionerMenu:WaitForChild("ConfirmKill")

local DEFAULT_COLOR = Color3.fromRGB(50, 50, 50)
local SELECTED_COLOR = Color3.fromRGB(0, 170, 0)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)

local selectedTarget: string? = nil
local localPlayerRole: string? = GetMyRole:InvokeServer()
local pendingExecutionTarget: string? = nil

local function hideAllMenus()
	kingMurderAbility.Visible = false
	executionerMenu.Visible = false
end

actionUI.Enabled = true
hideAllMenus()

RoleAssigned.OnClientEvent:Connect(function(role: string)
	localPlayerRole = role
end)

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
			button.TextScaled = true
			button.BackgroundColor3 = DEFAULT_COLOR
			button.TextColor3 = TEXT_COLOR
			button.Parent = playerList

			button.MouseButton1Click:Connect(function()
				selectTarget(player.Name, button)
			end)
		end
	end
end

local function updateVisibility()
	hideAllMenus()

	print("VISIBILITY CHECK -> Role: ", tostring(localPlayerRole), " | State: ", tostring(CurrentGameState.Value))

	local isSecretMeetings = string.find(string.lower(CurrentGameState.Value), "secret") ~= nil

	if isSecretMeetings and localPlayerRole == "King" then
		kingMurderAbility.Visible = true
		populatePlayerList()
	else
		kingMurderAbility.Visible = false
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
	hideAllMenus()
end)

ExecutionPrompt.OnClientEvent:Connect(function(targetName: string)
	pendingExecutionTarget = targetName
	executionerMenu.Visible = true
	targetDisplay.Text = "The King demands the death of: " .. targetName
end)

confirmKillButton.MouseButton1Click:Connect(function()
	if pendingExecutionTarget then
		ActionRequest:FireServer("ConfirmExecution", pendingExecutionTarget)
		pendingExecutionTarget = nil
	end

	hideAllMenus()
end)
