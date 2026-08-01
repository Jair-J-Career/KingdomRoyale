# Kingdom Royale — Architecture

## 1. Project Structure

```
Kingdom_Royale/
├── default.project.json          # Rojo project map (DataModel tree)
└── src/
    ├── server/
    │   ├── init.server.luau       # placeholder entry script
    │   ├── GameLoop.server.luau   # Day/Night state machine, role assignment, teleports, ghost CollisionGroups, cooldown ticking
    │   ├── ActionHandler.server.luau  # Validates/executes OrderMurder, OrderFakeMurder, ConfirmExecution, Assassinate
    │   └── ChatFilter.server.luau # ShouldDeliverCallback-based Graveyard chat filter
    ├── client/
    │   ├── init.client.luau       # placeholder entry script
    │   ├── HUDController.client.luau   # Top clock + role card display
    │   └── ActionController.client.luau # State-driven menu UI (King/Executioner/Assassination/Usurper) + ghost visibility polling
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
| `NightPhase`               | `task.wait(5)`                    | if `CurrentDay == 6`: `CurrentState = "GameOver"` and loop `break`; else `CurrentDay += 1`, teleport to `GrandHall.SpawnPoint_Main`, `tickCooldowns()`, `broadcastAliveStatus()` | `DayGathering` (or `GameOver`) |

Exact phase string values used throughout the codebase (case-sensitive):
`"WaitingForPlayers"`, `"DayGathering"`, `"SecretMeetings"`, `"EveningGathering"`, `"NightPhase"`, `"GameOver"`.

`updateGameStateDisplay()` runs after every transition and writes a human-readable version (via `STATE_DISPLAY_NAMES`) into `ReplicatedStorage.CurrentGameState.Value`, formatted as `"Day %d: %s"` (e.g. `"Day 1: Secret Meetings"`, `"Day 1: Night Phase"`). This `StringValue` is the only channel clients read the phase from — clients pattern-match on lowercased substrings (`"secret"`, `"night"`, `"day gathering"`) rather than the raw state name.

`notifyExecutioners()` (called on entering `NightPhase`) logs `PendingActions.ActiveMurder` and every player's assigned `Role` for diagnostics, then — if an `ActiveMurder` exists — fires `ExecutionPrompt` with its `Target` to any player whose role is `Sorcerer` or `Knight`. The executioner has no way to tell from this prompt alone whether the order came from the King or the Usurper (see §10).

Every time the loop lands back on `DayGathering` from `NightPhase`, `tickCooldowns()` decrements every player's `Cooldown` (floor 0) and `broadcastAliveStatus()` pushes the updated values to clients — this is what re-enables the Usurper's menu two `DayGathering`s after a fake order gets caught.

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
    Role = "King" | "Sorcerer" | "Knight" | ... ,  -- one of the 15 ROLES entries
    IsAlive = true | false,
    Cooldown = 0,  -- optional; only set once a role has an active cooldown (currently just the Usurper)
}
```

Populated by `assignRoles()` in `GameLoop.server.luau` when `WaitingForPlayers` transitions to `DayGathering`. `IsAlive` is flipped to `false` by `handleConfirmExecution()`/`handleAssassination()` in `ActionHandler.server.luau` once a kill lands. `Cooldown` is set by `handleConfirmExecution()` when a Usurper's fake order gets executed (see §10), and decremented once per day by `tickCooldowns()` in `GameLoop.server.luau`. Clients never read `PlayerData` directly — they learn their own role via the `GetMyRole` RemoteFunction/`RoleAssigned` RemoteEvent, and their `IsAlive`/`Cooldown` via the `AliveStatusUpdate` broadcast (see §8).

### `PendingActions`

A single-slot mailbox for whichever murder order is currently active — see **§10 (Usurper & King Precedence)** for the full `ActiveMurder` structure and lifecycle. In short:

```lua
PendingActions.ActiveMurder = {
    RequesterRole = "King" | "Usurper",
    Target = "TargetPlayerName",
    RequesterId = 123456789,
}
```

Only one order can be active at a time — a King's order always overwrites a Usurper's, never the reverse. The whole `PendingActions` table is `table.clear()`-ed on the `NightPhase → DayGathering` transition.

### RemoteEvents / RemoteFunctions (all declared in `default.project.json` under `ReplicatedStorage`)

| Name                 | Type            | Direction        | Purpose                                                                 |
|----------------------|-----------------|-------------------|--------------------------------------------------------------------------|
| `RoleAssigned`        | RemoteEvent     | Server → Client   | Fired once per player in `assignRoles()`; tells the client its role string. |
| `ActionRequest`       | RemoteEvent     | Client → Server   | Generic action channel; payload is `(actionType: string, targetName: string)`. Handles `"OrderMurder"`, `"OrderFakeMurder"`, `"ConfirmExecution"`, and `"Assassinate"`. |
| `ExecutionPrompt`     | RemoteEvent     | Server → Client   | Fired to Sorcerer/Knight players in `notifyExecutioners()` with the active order's target name. |
| `GetMyRole`           | RemoteFunction  | Client → Server   | Invoked once at client script start; returns the caller's `Role` from `PlayerData`, or `nil`. |
| `AliveStatusUpdate`   | RemoteEvent     | Server → Client   | Broadcasts a snapshot of every player's `{UserId, Name, IsAlive, Cooldown}` — see §8. |
| `OrderVoided`         | RemoteEvent     | Server → Client   | Fired to an executioner whose order died with its requester, or to a Usurper whose fake order was overwritten by the King — see §10. |
| `FakeOrderRevealed`   | RemoteEvent     | Server → Client   | Fired to the executioner immediately after they complete a kill that turns out to have been the Usurper's fake order — see §10. |

Plus the non-Remote `CurrentGameState` `StringValue`, which acts as a passive, poll-free broadcast channel: clients listen to its `Changed`/`GetPropertyChangedSignal("Value")` event rather than receiving a dedicated event per phase change.

## 4. UI Architecture — State-Driven UI (`ActionController.client.luau`)

The client menu system was refactored from ad-hoc `.Visible` toggling into a strict single-source-of-truth pattern to avoid race conditions as more role-specific menus are added:

- **`activeMenu`** (`local activeMenu = "None"`) is the *only* piece of state that determines what's on screen. Valid values currently: `"None"`, `"KingMurder"`, `"Executioner"`, `"Assassination"`, `"Usurper"`.
- **`renderUI()`** is the *only* function in the script allowed to touch `.Visible`:
  ```lua
  local function renderUI()
      kingMurderAbility.Visible = (activeMenu == "KingMurder")
      executionerMenu.Visible = (activeMenu == "Executioner")
      assassinationMenu.Visible = (activeMenu == "Assassination")
      usurperMenu.Visible = (activeMenu == "Usurper")
  end
  ```
- Every other piece of logic — the `CurrentGameState` listener (`updateVisibility`), the `ExecutionPrompt` handler, and the button click handlers — only ever *decides a new value for `activeMenu`* and then calls `renderUI()`. None of them touch frame `.Visible` directly, and the old blanket `hideAllMenus()` helper has been removed entirely.

State transitions:
- **`updateVisibility()`** (bound to `CurrentGameState:GetPropertyChangedSignal("Value")`, and also called once at script init): lowercases the current state string and applies, in order:
  - if it contains `"secret"` and the local player's role is `"King"` → `activeMenu = "KingMurder"` (and repopulates the target `playerList`).
  - else if it contains `"night"` and the local player's role is `"Revolutionary"` → `activeMenu = "Assassination"` (and repopulates `targetList`).
  - else if it contains `"night"` **and** `activeMenu` is already `"Executioner"` → leave `activeMenu` untouched, so an execution prompt that just opened isn't slammed shut by the same state-change tick.
  - else if it contains `"day gathering"` (an exact-phrase match, so it doesn't also fire on `"evening gathering"`) and the local player's role is `"Usurper"` and their `Cooldown` is `0`/`nil` → `activeMenu = "Usurper"` (and repopulates `usurperTargetList`).
  - else → `activeMenu = "None"`.
- **`ExecutionPrompt.OnClientEvent`**: stores `pendingExecutionTarget`, sets `activeMenu = "Executioner"`, updates `targetDisplay.Text`, calls `renderUI()`.
- **`submitButton.MouseButton1Click`** (King confirms a murder target): fires `ActionRequest("OrderMurder", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`confirmKillButton.MouseButton1Click`** (Executioner confirms the kill): fires `ActionRequest("ConfirmExecution", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`assassinateButton.MouseButton1Click`** (Revolutionary confirms a target): fires `ActionRequest("Assassinate", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`fakeOrderButton.MouseButton1Click`** (Usurper confirms a fake target): fires `ActionRequest("OrderFakeMurder", ...)`, then `activeMenu = "None"`, `renderUI()`.
- Script init calls both `updateVisibility()` (to evaluate current state/role immediately, e.g. on late join) and `renderUI()` (to paint the resulting `activeMenu`).

This design means adding a new role-specific menu is a matter of adding one more `activeMenu` value and one more line in `renderUI()` — no new `hideAllMenus()`-style call sites are needed anywhere else.

## 5. Completed Mechanics — King → Executioner Murder Loop

End-to-end flow, currently working:

1. **Role assignment**: on reaching 3+ players, `assignRoles()` hands out roles from the `ROLES` list (with `Player1`/`Player2`/`Player3` test-rigged to King/Sorcerer/Usurper respectively for solo testing), populating `PlayerData` and firing `RoleAssigned` to each client.
2. **Order phase (`SecretMeetings`)**: the King's client shows the `KingMurderAbility` menu (via `activeMenu = "KingMurder"`), lists other players, and on submit fires `ActionRequest("OrderMurder", targetName)`. Server-side, `handleOrderMurder()` validates the state, the caller's role, and the target, then writes `PendingActions.ActiveMurder = { RequesterRole = "King", Target = targetName, RequesterId = kingUserId }` (see §10 for what happens if a Usurper order was already sitting there).
3. **Night transition**: `notifyExecutioners()` runs when `NightPhase` begins, reads `PendingActions.ActiveMurder`, and fires `ExecutionPrompt` to every connected Sorcerer/Knight with the target's name. `PendingActions` is cleared later, on the `NightPhase → DayGathering` transition.
4. **Execution prompt (client)**: any Sorcerer/Knight client receiving `ExecutionPrompt` sets `activeMenu = "Executioner"`, displaying the `ExecutionerMenu` with the target's name — protected from being immediately hidden by the `NightPhase` state-change tick via the `updateVisibility()` preserve-if-already-open rule.
5. **Confirmation**: clicking `ConfirmKill` fires `ActionRequest("ConfirmExecution", targetName)`. Server-side, `handleConfirmExecution()` validates the state is `NightPhase`, the caller is Sorcerer/Knight and alive, confirms `PendingActions.ActiveMurder.Target` still matches, sets the target's `Humanoid.Health = 0`, marks `PlayerData[target].IsAlive = false`, and clears `ActiveMurder` — with an extra reveal step if the order turns out to have been the Usurper's fake one (see §10).

Diagnostic logging (added during debugging) remains in place in `notifyExecutioners()` (dumps `PendingActions.ActiveMurder` and every player's role) to make future King/Executioner desync issues easy to trace.

## 6. Ghost & Respawn System

Dead players stay in the game as visible-to-themselves, invisible-to-the-living "ghosts." This is split across a server-side physics layer and a client-side visuals layer — they solve different problems and don't depend on each other.

**Server (`GameLoop.server.luau`) — collision:**
- At script start, `PhysicsService:RegisterCollisionGroup(...)` creates two groups, `"Alive"` and `"Ghosts"` (wrapped in `pcall` since re-registering an existing group errors on script re-run), then `PhysicsService:CollisionGroupSetCollidable("Alive", "Ghosts", false)` makes them mutually non-collidable.
- `applyGhostState(character)` — called from `catchRespawn()` whenever `PlayerData[player.UserId].IsAlive == false` on `CharacterAdded` — sets every `BasePart`'s `CollisionGroup = "Ghosts"` *and* `CanCollide = false` (belt-and-suspenders: `CanCollide` alone wasn't sufficient because Roblox's Humanoid/rig-building code can reset it on limbs after `CharacterAdded`, whereas the `CollisionGroup` assignment survives that reset). It also disables every `BillboardGui` (e.g. nametags) and sets `Humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None` so the ghost doesn't render in other players' nameplate/health-bar UI.
- `applyAliveState(character)` — the else-branch of `catchRespawn()` — sets `CollisionGroup = "Alive"` on every `BasePart` for a player who is (re)spawning alive.
- `catchRespawn()` is hooked on every player's `CharacterAdded` from script start plus `Players.PlayerAdded`, so it runs for every respawn, not just the first spawn.

**Client (`ActionController.client.luau`) — visuals:**
- `updateGhostVisibility()` is the single function that owns ghost transparency. For every player who is dead (per the client's `aliveStatus` table), it calls `setCharacterTransparency(character, transparency)`, which sets `Transparency` on every `BasePart`/`Decal` descendant. The transparency value depends on the *viewer*: `LIVING_VIEW_OF_DEAD_TRANSPARENCY = 1` (fully invisible) if the local player is alive, `DEAD_VIEW_OF_DEAD_TRANSPARENCY = 0.5` (translucent) if the local player is also dead — so ghosts can see each other and themselves, but the living see nothing.
- A separate explicit block handles the local player's *own* dead character: it calls both `setCharacterTransparency` and `setLocalTransparencyModifier` (which sets `LocalTransparencyModifier` on every `BasePart`). The modifier is required because Roblox's default camera/occlusion scripts (the ones that fade out parts blocking the camera) can silently override a plain `Transparency` write on the local client's own character — `LocalTransparencyModifier` is the property those scripts actually respect for the local avatar.
- Both the main loop and the local-player block guard every character lookup with `if character and character.Parent then` before touching descendants, so a character that's mid-destruction (e.g. respawning at that exact instant) is skipped instead of erroring on stale/unparented instances.
- Visibility updates fire two ways: reactively, whenever `AliveStatusUpdate` lands (so a death/revive updates visuals immediately), and via a **1-second polling loop** — `task.spawn(function() while task.wait(1) do updateGhostVisibility() end end)` at the bottom of the script. The polling loop exists because earlier event-driven approaches (`CharacterAppearanceLoaded`, `DescendantAdded` listeners for late-streamed accessories/limbs) proved to race with Roblox's asset streaming and produced an intermittent "opaque ghost" bug; polling trades a little latency (worst case ~1s) for a guarantee that any part that exists gets corrected shortly after it loads, with no event-ordering assumptions.

## 7. Graveyard Chat Filter

Dead players share the same `RBXGeneral` text channel as the living — there is no separate `"Graveyard"` `TextChannel` or channel-switching (`AddUserAsync`/`RemoveUserAsync`) anymore. Filtering happens purely at delivery time.

**Server (`ChatFilter.server.luau`):**
- `local textChannels = TextChatService:WaitForChild("TextChannels")` then `textChannels:WaitForChild("RBXGeneral")` — both use `WaitForChild` because the engine creates its default `TextChannels` folder asynchronously; indexing `TextChatService.TextChannels` directly can run before it exists and throw `"TextChannels is not a valid member of TextChatService"`.
- `generalChannel.ShouldDeliverCallback = function(textChatMessage, targetTextSource) ... end` is set once at script start. For every message/recipient pair, it looks up `GameState.PlayerData[senderUserId]` and `GameState.PlayerData[targetUserId]`; if either is missing (e.g. chat before roles are assigned), it fails open and returns `true`. Otherwise: if the sender's `IsAlive == false` and the target's `IsAlive == true`, it `print("[CHAT FILTER] Blocked ghost message to living player")` and returns `false` (message dropped for that recipient only); every other combination returns `true`.
- Because this runs per-recipient at the engine's delivery layer, it doesn't matter which channel a client's `ChatInputBarConfiguration.TargetTextChannel` happens to be pointed at — a dead sender's message is invisible to a living recipient regardless.

**Client (`ActionController.client.luau`):** the `AliveStatusUpdate` handler detects the local player's own alive→dead transition (`wasLocalPlayerAlive and not isPlayerAlive(localPlayer)`) and calls `TextChatService.TextChannels.RBXGeneral:DisplaySystemMessage(...)` with a red-tagged message: *"Welcome to the Graveyard chat. The living cannot hear you."* This is a purely local system message (not an actual chat message), so it only ever appears in that one client's own chat window.

## 8. UI State Syncing

`AliveStatusUpdate` is the single channel clients use to learn who's alive and whose ability is on cooldown. `broadcastAliveStatus()` exists in both `GameLoop.server.luau` and `ActionHandler.server.luau` (kept as two independent, identically-shaped implementations — a known duplication, not a shared helper) and fires:

```lua
{
    { UserId = 123, Name = "Player1", IsAlive = true, Cooldown = 0 },
    ...
}
```

The client stores this into two parallel lookup tables, `aliveStatus: {[UserId]: boolean}` and `cooldownStatus: {[UserId]: number}`. `isPlayerAlive(player)` defaults to `true` for any `UserId` not yet present (e.g. before the first broadcast lands); cooldown reads default to `0` the same way (`cooldownStatus[UserId] or 0`).

All three target-selection menus — `populatePlayerList()` (King), `populateAssassinationList()` (Revolutionary), and `populateUsurperList()` (Usurper) — follow the same shape:
1. Destroy any previously-spawned target buttons and clear a previous `"NoValidTargetsLabel"` (looked up and destroyed by that fixed name, so it never stacks across repopulations).
2. Loop `Players:GetPlayers()`, filtering to `player ~= localPlayer and isPlayerAlive(player)`, spawning one `TextButton` per valid target and counting them.
3. If the count is `0`: disable the menu's action button (`Active = false`, `AutoButtonColor = false`, via the shared `setActionButtonEnabled` helper) and spawn a `"NO VALID TARGETS"` `TextLabel` (red-gray, `Color3.fromRGB(200, 60, 60)`) into the list container. If the count is `> 0`, the button is (re-)enabled — so a menu that was previously empty doesn't stay stuck disabled once valid targets exist again.

## 9. Role Mechanics — Revolutionary

The Revolutionary's `Assassinate` action (`handleAssassination()` in `ActionHandler.server.luau`) is deliberately **not** a two-step order/confirm flow like the King/Executioner pair — it validates `NightPhase`, that the caller is an alive `Revolutionary`, and that the target exists and isn't the caller, then immediately sets `Humanoid.Health = 0` and `PlayerData[target].IsAlive = false` in the same call. There's no `ExecutionPrompt` round trip, so the kill always lands the instant the Revolutionary submits it that night.

**Rule of Chronology**: because the kill is instantaneous, it's possible for the Revolutionary's target to be the very player who placed the night's `PendingActions.ActiveMurder` (a King or a Usurper). After the kill lands, `handleAssassination()` checks `activeMurder.RequesterId == targetPlayer.UserId` — if the order's *requester* just died, the order dies with them: `PendingActions.ActiveMurder` is cleared and `OrderVoided` is fired to every connected Sorcerer/Knight, so an executioner who already has an `ExecutionPrompt` open for that now-orphaned order gets told to stand down instead of executing on a dead man's orders.

## 10. Usurper & King Precedence

`PendingActions.ActiveMurder` is a single slot (not keyed by `UserId`) precisely because only one murder order can be "the" active order heading into `NightPhase` — the King's order always wins if both are placed the same day, and the data structure enforces that by only ever holding one entry:

```lua
PendingActions.ActiveMurder = {
    RequesterRole = "King" | "Usurper",
    Target = "TargetPlayerName",
    RequesterId = 123456789,
}
```

- **Usurper's fake order** (`handleFakeMurder()`, valid only during `DayGathering`, caller must be an alive `Usurper`): if `ActiveMurder` already holds a `"King"` order, the King has already spoken that cycle — the Usurper's attempt is rejected outright and `OrderVoided` fires back to them immediately. Otherwise, `ActiveMurder` is written with `RequesterRole = "Usurper"`.
- **King's real order** (`handleOrderMurder()`, valid only during `SecretMeetings` — a later, separate phase from the Usurper's window): if `ActiveMurder` currently holds a `"Usurper"` order, `OrderVoided` fires to that Usurper (their earlier fake order is being overridden) *before* `ActiveMurder` is overwritten with `RequesterRole = "King"`. King precedence is therefore just a consequence of the King's phase coming after the Usurper's in the same day cycle, not an explicit priority check on the target.
- **The executioner never knows which is which up front** — `ExecutionPrompt` only ever carries a target name, whether the order came from the King or the Usurper. The distinction only surfaces in `handleConfirmExecution()`, *after* the kill successfully lands: if `activeMurder.RequesterRole == "Usurper"`, the server fires `FakeOrderRevealed` to the executioner (client shows a temporary red *"THE KING DID NOT ORDER THAT!"* banner for 5 seconds) and sets `PlayerData[activeMurder.RequesterId].Cooldown = 3`.
- **Cooldown math**: `tickCooldowns()` runs on every `NightPhase → DayGathering` transition — including the very next one right after the fake order was caught. A `Cooldown` of `3` therefore takes three ticks to reach `0`, which means the Usurper's menu (gated on `Cooldown == 0` in `updateVisibility()`) stays hidden through two full `DayGathering`s before becoming available again on the third.
- **Client wiring**: `UsurperMenu` (`PlayerList` + `FakeOrderButton`) mirrors the `AssassinationMenu` pattern exactly — see §8 for `populateUsurperList()`. `OrderVoided.OnClientEvent` has two independent branches: the pre-existing one resets the Executioner UI when `activeMenu == "Executioner"`, and a second one — gated on `isPlayerAlive(localPlayer) and localPlayerRole == "Usurper"` — shows a temporary red *"THE KING HAS MADE THEIR DECREE. YOUR ORDER IS VOID."* banner for 6 seconds. Both this banner and the `FakeOrderRevealed` banner are built by a shared `showTemporaryBanner(name, text, duration)` helper.
