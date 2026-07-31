# Kingdom Royale — Architecture

## 1. Project Structure

```
Kingdom_Royale/
├── default.project.json          # Rojo project map (DataModel tree)
└── src/
    ├── server/
    │   ├── init.server.luau       # placeholder entry script
    │   ├── GameLoop.server.luau   # Day/Night state machine, role assignment, teleports
    │   └── ActionHandler.server.luau  # Validates/executes OrderMurder & ConfirmExecution
    ├── client/
    │   ├── init.client.luau       # placeholder entry script
    │   ├── HUDController.client.luau   # Top clock + role card display
    │   └── ActionController.client.luau # State-driven menu UI (King/Executioner)
    └── shared/
        ├── GameState.luau         # Single source of truth for GameState + PlayerData
        └── Hello.luau             # unused sample module
```

Rojo mapping (`default.project.json`):
- `src/shared` → `ReplicatedStorage.Shared`
- `src/server` → `ServerScriptService.Server`
- `src/client` → `StarterPlayer.StarterPlayerScripts.Client`

## 2. The State Machine (`GameLoop.server.luau`)

The night/day cycle is a single `while true do` loop driven by `GameState.CurrentState`, a string field on the shared `GameState` table. Each iteration waits, then transitions to the next phase:

| Current `CurrentState`   | Wait Condition                    | Action Taken                                                                 | Next `CurrentState` |
|---------------------------|------------------------------------|--------------------------------------------------------------------------------|----------------------|
| `WaitingForPlayers`       | until `#Players:GetPlayers() >= 3` | `assignRoles()`, teleport to `GrandHall.SpawnPoint_Main`                       | `DayGathering`       |
| `DayGathering`             | `task.wait(5)`                    | `runSecretMeetings()` (pairs players into `Workspace.SecretRooms`)             | `SecretMeetings`     |
| `SecretMeetings`           | `task.wait(5)`                    | teleport to `GrandHall.SpawnPoint_Main`                                        | `EveningGathering`   |
| `EveningGathering`         | `task.wait(5)`                    | teleport to `PrivateQuarters.SpawnPoint_Private`, `notifyExecutioners()`       | `NightPhase`         |
| `NightPhase`               | `task.wait(5)`                    | if `CurrentDay == 6`: `CurrentState = "GameOver"` and loop `break`; else `CurrentDay += 1`, teleport to `GrandHall.SpawnPoint_Main` | `DayGathering` (or `GameOver`) |

Exact phase string values used throughout the codebase (case-sensitive):
`"WaitingForPlayers"`, `"DayGathering"`, `"SecretMeetings"`, `"EveningGathering"`, `"NightPhase"`, `"GameOver"`.

`updateGameStateDisplay()` runs after every transition and writes a human-readable version (via `STATE_DISPLAY_NAMES`) into `ReplicatedStorage.CurrentGameState.Value`, formatted as `"Day %d: %s"` (e.g. `"Day 1: Secret Meetings"`, `"Day 1: Night Phase"`). This `StringValue` is the only channel clients read the phase from — clients pattern-match on lowercased substrings (`"secret"`, `"night"`) rather than the raw state name.

`notifyExecutioners()` (called on entering `NightPhase`) logs the full contents of `PendingActions` and every player's assigned `Role` for diagnostics, then finds the `OrderMurder` action, fires `ExecutionPrompt` to any player whose role is `Sorcerer` or `Knight`, and clears `PendingActions`.

## 3. Data & Networking

### `GameState.luau` (shared module, `ReplicatedStorage.Shared.GameState`)

Returns a table with two shared references used by both server scripts:

```lua
GameState = {
    CurrentState = "WaitingForPlayers",
    CurrentDay = 1,
    PendingActions = {},
}
PlayerData = {}
```

Because Luau tables are passed by reference, both `GameLoop.server.luau` and `ActionHandler.server.luau` `require()` this module and mutate the same underlying tables — there is no replication or ownership boundary between them; it's an in-process shared-state singleton, server-side only.

### `PlayerData`

Keyed by `player.UserId`. Each entry:

```lua
PlayerData[userId] = {
    Role = "King" | "Sorcerer" | "Knight" | ... ,  -- one of the 14 ROLES entries
    IsAlive = true | false,
}
```

Populated by `assignRoles()` in `GameLoop.server.luau` when `WaitingForPlayers` transitions to `DayGathering`. `IsAlive` is flipped to `false` by `handleConfirmExecution()` in `ActionHandler.server.luau` once a Sorcerer/Knight kill lands. Clients never read `PlayerData` directly — they learn their own role via the `GetMyRole` RemoteFunction or the `RoleAssigned` RemoteEvent.

### `PendingActions`

A table used as a short-lived mailbox for the King's nightly order, keyed by the ordering player's `UserId`:

```lua
PendingActions[kingUserId] = {
    ActionType = "OrderMurder",
    Target = "TargetPlayerName",
}
```

- Written by `handleOrderMurder()` when the King submits a target during `SecretMeetings`.
- Read by `notifyExecutioners()` on the `NightPhase` transition to find the order and notify executioners, then the whole table is `table.clear()`-ed.
- Also re-scanned by `handleConfirmExecution()` during `NightPhase` to confirm the requested target still matches a live order, then removes that specific entry (`PendingActions[orderUserId] = nil`).

### RemoteEvents / RemoteFunctions (all declared in `default.project.json` under `ReplicatedStorage`)

| Name              | Type            | Direction        | Purpose                                                                 |
|-------------------|-----------------|-------------------|--------------------------------------------------------------------------|
| `RoleAssigned`     | RemoteEvent     | Server → Client   | Fired once per player in `assignRoles()`; tells the client its role string. |
| `ActionRequest`    | RemoteEvent     | Client → Server   | Generic action channel; payload is `(actionType: string, targetName: string)`. Handles `"OrderMurder"` and `"ConfirmExecution"`. |
| `ExecutionPrompt`  | RemoteEvent     | Server → Client   | Fired to Sorcerer/Knight players in `notifyExecutioners()` with the King's target name. |
| `GetMyRole`        | RemoteFunction  | Client → Server   | Invoked once at client script start; returns the caller's `Role` from `PlayerData`, or `nil`. |

Plus the non-Remote `CurrentGameState` `StringValue`, which acts as a passive, poll-free broadcast channel: clients listen to its `Changed`/`GetPropertyChangedSignal("Value")` event rather than receiving a dedicated event per phase change.

## 4. UI Architecture — State-Driven UI (`ActionController.client.luau`)

The client menu system was refactored from ad-hoc `.Visible` toggling into a strict single-source-of-truth pattern to avoid race conditions as more role-specific menus are added:

- **`activeMenu`** (`local activeMenu = "None"`) is the *only* piece of state that determines what's on screen. Valid values currently: `"None"`, `"KingMurder"`, `"Executioner"`.
- **`renderUI()`** is the *only* function in the script allowed to touch `.Visible`:
  ```lua
  local function renderUI()
      kingMurderAbility.Visible = (activeMenu == "KingMurder")
      executionerMenu.Visible = (activeMenu == "Executioner")
  end
  ```
- Every other piece of logic — the `CurrentGameState` listener (`updateVisibility`), the `ExecutionPrompt` handler, and the two button click handlers — only ever *decides a new value for `activeMenu`* and then calls `renderUI()`. None of them touch frame `.Visible` directly, and the old blanket `hideAllMenus()` helper has been removed entirely.

State transitions:
- **`updateVisibility()`** (bound to `CurrentGameState:GetPropertyChangedSignal("Value")`, and also called once at script init): lowercases the current state string and applies:
  - if it contains `"secret"` and the local player's role is `"King"` → `activeMenu = "KingMurder"` (and repopulates the target `playerList`).
  - else if it contains `"night"` **and** `activeMenu` is already `"Executioner"` → leave `activeMenu` untouched, so an execution prompt that just opened isn't slammed shut by the same state-change tick.
  - else → `activeMenu = "None"`.
- **`ExecutionPrompt.OnClientEvent`**: stores `pendingExecutionTarget`, sets `activeMenu = "Executioner"`, updates `targetDisplay.Text`, calls `renderUI()`.
- **`submitButton.MouseButton1Click`** (King confirms a murder target): fires `ActionRequest("OrderMurder", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`confirmKillButton.MouseButton1Click`** (Executioner confirms the kill): fires `ActionRequest("ConfirmExecution", ...)`, then `activeMenu = "None"`, `renderUI()`.
- Script init calls both `updateVisibility()` (to evaluate current state/role immediately, e.g. on late join) and `renderUI()` (to paint the resulting `activeMenu`).

This design means adding a new role-specific menu is a matter of adding one more `activeMenu` value and one more line in `renderUI()` — no new `hideAllMenus()`-style call sites are needed anywhere else.

## 5. Completed Mechanics — King → Executioner Murder Loop

End-to-end flow, currently working:

1. **Role assignment**: on reaching 3+ players, `assignRoles()` hands out roles from the `ROLES` list (with `Player1`/`Player2` test-rigged to King/Sorcerer respectively for solo testing), populating `PlayerData` and firing `RoleAssigned` to each client.
2. **Order phase (`SecretMeetings`)**: the King's client shows the `KingMurderAbility` menu (via `activeMenu = "KingMurder"`), lists other players, and on submit fires `ActionRequest("OrderMurder", targetName)`. Server-side, `handleOrderMurder()` validates the state, the caller's role, and the target, then writes `PendingActions[kingUserId] = { ActionType = "OrderMurder", Target = targetName }`.
3. **Night transition**: `notifyExecutioners()` runs when `NightPhase` begins, scans `PendingActions` for the `OrderMurder` entry, and fires `ExecutionPrompt` to every connected Sorcerer/Knight with the target's name, then clears `PendingActions`.
4. **Execution prompt (client)**: any Sorcerer/Knight client receiving `ExecutionPrompt` sets `activeMenu = "Executioner"`, displaying the `ExecutionerMenu` with the target's name — protected from being immediately hidden by the `NightPhase` state-change tick via the `updateVisibility()` preserve-if-already-open rule.
5. **Confirmation**: clicking `ConfirmKill` fires `ActionRequest("ConfirmExecution", targetName)`. Server-side, `handleConfirmExecution()` validates the state is `NightPhase`, the caller is Sorcerer/Knight, re-locates a matching (now server-authoritative, re-derived) pending order record, sets the target's `Humanoid.Health = 0`, marks `PlayerData[target].IsAlive = false`, and removes the order.

Diagnostic logging (added during debugging) remains in place in `notifyExecutioners()` (dumps every `PendingActions` entry and every player's role) to make future King/Executioner desync issues easy to trace.
