local GameState = {
	CurrentState = "WaitingForPlayers",
	CurrentDay = 1,
	PendingActions = {},
	SecretPairs = {},
	SpyConnections = {},
	SpyTarget = nil,
}

local PlayerData = {}

return {
	GameState = GameState,
	PlayerData = PlayerData,
}
