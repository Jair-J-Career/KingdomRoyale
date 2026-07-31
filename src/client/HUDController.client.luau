local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local RoleAssigned = ReplicatedStorage:WaitForChild("RoleAssigned")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mainHUD = playerGui:WaitForChild("MainHUD")
local topClock = mainHUD:WaitForChild("TopClock")
local roleCard = mainHUD:WaitForChild("RoleCard")

local function updateClock()
	topClock.Text = CurrentGameState.Value
end

updateClock()
CurrentGameState:GetPropertyChangedSignal("Value"):Connect(updateClock)

RoleAssigned.OnClientEvent:Connect(function(role: string)
	roleCard.Text = "Role: " .. role
end)
