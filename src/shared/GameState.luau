local GameState = {
	CurrentState = "WaitingForPlayers",
	CurrentDay = 1,
	PendingActions = {},
}

local PlayerData = {}

return {
	GameState = GameState,
	PlayerData = PlayerData,
}
