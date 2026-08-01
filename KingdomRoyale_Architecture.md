# Kingdom Royale — Architecture

## 1. Project Structure

```
Kingdom_Royale/
├── default.project.json          # Rojo project map (DataModel tree)
└── src/
    ├── server/
    │   ├── init.server.luau       # placeholder entry script
    │   ├── GameLoop.server.luau   # Day/Night state machine, role assignment, teleports, ghost CollisionGroups, cooldown ticking
    │   ├── ActionHandler.server.luau  # Validates/executes OrderMurder, OrderFakeMurder, MartyrOath, ConfirmExecution, Assassinate, Eavesdrop
    │   └── ChatFilter.server.luau # ShouldDeliverCallback-based Graveyard chat filter
    ├── client/
    │   ├── init.client.luau       # placeholder entry script
    │   ├── HUDController.client.luau   # Top clock + role card display
    │   └── ActionController.client.luau # State-driven menu UI (King/Executioner/Assassination/Usurper/Spy/Martyr) + ghost visibility polling
    └── shared/
        ├── GameState.luau         # Single source of truth for GameState + PlayerData (incl. SecretPairs, SpyConnections, SpyTarget)
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
| `DayGathering`             | `task.wait(5)`                    | decrement any living Bishop's `BishopCooldown` (if `> 0`) — see §13 — then `runSecretMeetings()` (pairs players into `Workspace.SecretRooms`, including forced Martyr/protected-target pairing — see §11) | `SecretMeetings`     |
| `SecretMeetings`           | `task.wait(20)`                   | `table.clear(GameState.SecretPairs)`, `GameState.SpyTarget = nil`, `removeSpyInvisibility()` for every living Spy, teleport to `GrandHall.SpawnPoint_Main` | `EveningGathering`   |
| `EveningGathering`         | `task.wait(5)`                    | teleport to `PrivateQuarters.SpawnPoint_Private`, `notifyExecutioners()`       | `NightPhase`         |
| `NightPhase`               | `task.wait(5)`                    | if `CurrentDay == 6`: `CurrentState = "GameOver"` and loop `break`; else `CurrentDay += 1`, teleport to `GrandHall.SpawnPoint_Main`, `tickCooldowns()`, `broadcastAliveStatus()` | `DayGathering` (or `GameOver`) |

`SecretMeetings` gets a longer 20-second window (vs. 5 for every other phase) because it's the only phase where players are expected to actually *do* something interactively — hold a private conversation, have the King issue an order, let a Spy eavesdrop, let a Martyr swear their oath — rather than just observe a teleport/prompt.

Exact phase string values used throughout the codebase (case-sensitive):
`"WaitingForPlayers"`, `"DayGathering"`, `"SecretMeetings"`, `"EveningGathering"`, `"NightPhase"`, `"GameOver"`.

`updateGameStateDisplay()` runs after every transition and writes a human-readable version (via `STATE_DISPLAY_NAMES`) into `ReplicatedStorage.CurrentGameState.Value`, formatted as `"Day %d: %s"` (e.g. `"Day 1: Secret Meetings"`, `"Day 1: Night Phase"`). This `StringValue` is the only channel clients read the phase from — clients pattern-match on lowercased substrings (`"secret"`, `"night"`, `"day gathering"`) rather than the raw state name.

`notifyExecutioners()` (called on entering `NightPhase`) logs `PendingActions.ActiveMurder` and every player's assigned `Role` for diagnostics, then — if an `ActiveMurder` exists — fires `ExecutionPrompt` with its `Target` to any player whose role is `Sorcerer` or `Knight`. The executioner has no way to tell from this prompt alone whether the order came from the King or the Usurper (see §10).

Every time the loop lands back on `DayGathering` from `NightPhase`, `tickCooldowns()` decrements every player's `Cooldown` (floor 0) and `broadcastAliveStatus()` pushes the updated values to clients — this is what re-enables the Usurper's menu two `DayGathering`s after a fake order gets caught.

## 3. Data & Networking

### `GameState.luau` (shared module, `ReplicatedStorage.Shared.GameState`)

Returns a table with two shared references used by all three server scripts:

```lua
GameState = {
    CurrentState = "WaitingForPlayers",
    CurrentDay = 1,
    PendingActions = {},
    SecretPairs = {},      -- bidirectional map: [UserId] = partnerUserId, for the current SecretMeetings room pairing
    SpyConnections = {},   -- [UserId] = the Spy's active DescendantAdded RBXScriptConnection, while eavesdropping
    SpyTarget = nil,       -- UserId the currently-eavesdropping Spy is standing over, or nil
}
PlayerData = {}
```

Because Luau tables are passed by reference, `GameLoop.server.luau`, `ActionHandler.server.luau`, and `ChatFilter.server.luau` all `require()` this module and mutate/read the same underlying tables — there is no replication or ownership boundary between them; it's an in-process shared-state singleton, server-side only. `SecretPairs`, `SpyConnections`, and `SpyTarget` are all Spy/room-pairing state — see §11 for how they're written, and §7 for how `ChatFilter.server.luau` reads them.

### `PlayerData`

Keyed by `player.UserId`. Each entry:

```lua
PlayerData[userId] = {
    Role = "King" | "Sorcerer" | "Knight" | ... ,  -- one of the 15 ROLES entries
    IsAlive = true | false,
    Cooldown = 0,  -- optional; only set once a role has an active cooldown (currently just the Usurper)
    ProtectedTargetUserId = nil,  -- Martyr only; the UserId they've sworn their oath to protect, or nil until sworn — see §11
    BishopCooldown = 0,  -- Bishop only; days remaining before the next scan is allowed — see §13
    ScannedPlayers = {},  -- Bishop only; UserIds already revealed, never re-scannable — see §13
}
```

Populated by `assignRoles()` in `GameLoop.server.luau` when `WaitingForPlayers` transitions to `DayGathering` (`ProtectedTargetUserId` always starts `nil`, `BishopCooldown` always starts `0`, and `ScannedPlayers` always starts as a fresh empty table, regardless of role). `IsAlive` is flipped to `false` by `handleConfirmExecution()`/`handleAssassination()` in `ActionHandler.server.luau` once a kill lands — or by `redirectToMartyr()` on the *Martyr's own* entry when a strike is intercepted (see §11). `Cooldown` is set by `handleConfirmExecution()` when a Usurper's fake order gets executed (see §10), and decremented once per day by `tickCooldowns()` in `GameLoop.server.luau`. `ProtectedTargetUserId` is set exactly once, by `handleMartyrOath()`, and is never cleared for the rest of that game. `BishopCooldown` is set to `2` by `handleBishopReveal()` on every successful scan and decremented once per day by a dedicated loop at the start of `DayGathering` (see §2/§13) — deliberately **not** `tickCooldowns()`, which only touches the generic `Cooldown` field. `ScannedPlayers` only ever grows (`table.insert`), never shrinks, for the rest of that game. Clients never read `PlayerData` directly — they learn their own role via the `GetMyRole` RemoteFunction/`RoleAssigned` RemoteEvent, and their `IsAlive`/`Cooldown`/`ProtectedTargetUserId`/`BishopCooldown`/`ScannedPlayers` via the `AliveStatusUpdate` broadcast (see §8) — **with a caveat**, see §8.

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
| `ActionRequest`       | RemoteEvent     | Client → Server   | Generic action channel; payload is `(actionType: string, targetName: string?)` — `targetName` is optional, `nil` for `"BishopReveal"` (see §13), a required string for every other action type. Handles `"OrderMurder"`, `"OrderFakeMurder"`, `"MartyrOath"`, `"ConfirmExecution"`, `"Assassinate"`, `"Eavesdrop"`, and `"BishopReveal"`. |
| `ExecutionPrompt`     | RemoteEvent     | Server → Client   | Fired to Sorcerer/Knight players in `notifyExecutioners()` with the active order's target name. |
| `GetMyRole`           | RemoteFunction  | Client → Server   | Invoked once at client script start; returns the caller's `Role` from `PlayerData`, or `nil`. |
| `AliveStatusUpdate`   | RemoteEvent     | Server → Client   | Broadcasts a snapshot of every player's `{UserId, Name, IsAlive, Cooldown, ProtectedTarget, BishopCooldown?, ScannedPlayers?}` — see §8 (the last two fields are only populated by `GameLoop.server.luau`'s copy of this broadcaster; see the caveat there). |
| `OrderVoided`         | RemoteEvent     | Server → Client   | Fired to an executioner whose order died with its requester, or to a Usurper whose fake order was overwritten by the King — see §10. |
| `FakeOrderRevealed`   | RemoteEvent     | Server → Client   | Fired to the executioner immediately after they complete a kill that turns out to have been the Usurper's fake order — see §10. |
| `RoomPartnerSync`     | RemoteEvent     | Server → Client   | Fired to each player in `pairPlayersInRoom()` (and to solo players, with `""`) whenever `SecretMeetings` pairing runs; tells the client the name of its current room partner — see §11. |
| `PartnerDitched`      | RemoteEvent     | Server → Client   | Fired by `handleEavesdrop()` to a Spy's original room partner the moment the Spy abandons them to go eavesdrop elsewhere — see §11. |
| `StrikeIntercepted`   | RemoteEvent     | Server → Client   | Fired by `redirectToMartyr()` to the attacker (King/Usurper's executioner, or a Revolutionary) whose lethal strike was redirected onto a sworn Martyr instead of the intended target — see §11. |
| `RoleRevealed`        | RemoteEvent     | Server → Client   | Fired by `handleBishopReveal()` to the Bishop only, carrying `(targetName, winCondition)` for whoever they just secretly scanned — see §13. |

Plus the non-Remote `CurrentGameState` `StringValue`, which acts as a passive, poll-free broadcast channel: clients listen to its `Changed`/`GetPropertyChangedSignal("Value")` event rather than receiving a dedicated event per phase change.

## 4. UI Architecture — State-Driven UI (`ActionController.client.luau`)

The client menu system was refactored from ad-hoc `.Visible` toggling into a strict single-source-of-truth pattern to avoid race conditions as more role-specific menus are added:

- **`activeMenu`** (`local activeMenu = "None"`) is the *only* piece of state that determines what's on screen. Valid values currently: `"None"`, `"KingMurder"`, `"Executioner"`, `"Assassination"`, `"Usurper"`, `"Spy"`, `"Martyr"`, `"Bishop"`.
- **`renderUI()`** is the *only* function in the script allowed to touch `.Visible`:
  ```lua
  local function renderUI()
      kingMurderAbility.Visible = (activeMenu == "KingMurder")
      executionerMenu.Visible = (activeMenu == "Executioner")
      assassinationMenu.Visible = (activeMenu == "Assassination")
      usurperMenu.Visible = (activeMenu == "Usurper")
      spyMenu.Visible = (activeMenu == "Spy")
      martyrMenu.Visible = (activeMenu == "Martyr")
      bishopMenu.Visible = (activeMenu == "Bishop")
  end
  ```
- Every other piece of logic — the `CurrentGameState` listener (`updateVisibility`), the `ExecutionPrompt` handler, and the button click handlers — only ever *decides a new value for `activeMenu`* and then calls `renderUI()`. None of them touch frame `.Visible` directly, and the old blanket `hideAllMenus()` helper has been removed entirely.
- Three additional pieces of client-local state feed into `updateVisibility()` beyond `aliveStatus`/`cooldownStatus`: **`currentRoomPartner`**, set by the `RoomPartnerSync.OnClientEvent` handler (coerced from `""`/`nil` to Lua `nil` — see §11); **`localProtectedTarget`**, extracted for the local player's own `UserId` out of every `AliveStatusUpdate` snapshot (see §8) — it mirrors the local player's server-side `ProtectedTargetUserId` and is what makes the Martyr menu's hide-after-oath behavior possible (see below); and **`localBishopCooldown`**/**`localScannedPlayers`**, extracted the same way, mirroring the Bishop's own `BishopCooldown`/`ScannedPlayers` — see §13.

State transitions:
- **`updateVisibility()`** (bound to `CurrentGameState:GetPropertyChangedSignal("Value")`, and also called once at script init): lowercases the current state string and applies, in order:
  - if it contains `"secret"` and the local player's role is `"King"` → `activeMenu = "KingMurder"` (and repopulates the target `playerList`).
  - else if it contains `"secret"` and the local player's role is `"Spy"` → `activeMenu = "Spy"` (and repopulates `spyTargetList` via `populateSpyList()` — see §11).
  - else if it contains `"secret"` and the local player's role is `"Martyr"` **and** `localProtectedTarget == nil` → `activeMenu = "Martyr"` (and repopulates `martyrTargetList` via `populateMartyrList()` — see §11). Once the oath is sworn, `localProtectedTarget` becomes non-`nil` on the next `AliveStatusUpdate` and this branch permanently stops matching for the rest of the game — no branch below it matches a Martyr either, so the menu falls through to `"None"` and never reopens.
  - else if it contains `"secret"` and the local player's role is `"Bishop"` **and** `localBishopCooldown == 0` **and** `currentRoomPartner ~= nil` **and not** `bishopPartnerAlreadyScanned` → `activeMenu = "Bishop"` — see §13 for how `bishopPartnerAlreadyScanned` is computed and why there's no `populateBishopList()` call here.
  - else if it contains `"night"` and the local player's role is `"Revolutionary"` → `activeMenu = "Assassination"` (and repopulates `targetList`).
  - else if it contains `"night"` **and** `activeMenu` is already `"Executioner"` → leave `activeMenu` untouched, so an execution prompt that just opened isn't slammed shut by the same state-change tick.
  - else if it contains `"day gathering"` (an exact-phrase match, so it doesn't also fire on `"evening gathering"`) and the local player's role is `"Usurper"` and their `Cooldown` is `0`/`nil` → `activeMenu = "Usurper"` (and repopulates `usurperTargetList`).
  - else → `activeMenu = "None"`.
- **`ExecutionPrompt.OnClientEvent`**: stores `pendingExecutionTarget`, sets `activeMenu = "Executioner"`, updates `targetDisplay.Text`, calls `renderUI()`.
- **`submitButton.MouseButton1Click`** (King confirms a murder target): fires `ActionRequest("OrderMurder", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`confirmKillButton.MouseButton1Click`** (Executioner confirms the kill): fires `ActionRequest("ConfirmExecution", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`assassinateButton.MouseButton1Click`** (Revolutionary confirms a target): fires `ActionRequest("Assassinate", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`fakeOrderButton.MouseButton1Click`** (Usurper confirms a fake target): fires `ActionRequest("OrderFakeMurder", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`eavesdropButton.MouseButton1Click`** (Spy confirms an eavesdrop target): fires `ActionRequest("Eavesdrop", ...)`, then `activeMenu = "None"`, `renderUI()`.
- **`oathButton.MouseButton1Click`** (Martyr swears their oath): fires `ActionRequest("MartyrOath", ...)`, then `activeMenu = "None"`, `renderUI()`. (The menu would have hidden itself on the next `AliveStatusUpdate` regardless — see above — but this avoids a one-frame flash of a now-stale menu.)
- **`revealButton.MouseButton1Click`** (Bishop scans their room partner): fires `ActionRequest:FireServer("BishopReveal")` with **no** second argument (unlike every other action button — see §3's `ActionRequest` row), then `activeMenu = "None"`, `renderUI()`. There's no `selectedX`/`resetXButtonColors()` pair for the Bishop, since there's nothing to select — see §13.
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

## 7. Chat Filtering — Graveyard & Spy Eavesdropping

All players share the same `RBXGeneral` text channel — there is no separate `"Graveyard"` `TextChannel`, no per-room `TextChannel`, and no channel-switching (`AddUserAsync`/`RemoveUserAsync`) anywhere. Every filtering rule (ghosts, room privacy, Spy eavesdropping) is enforced purely at delivery time, per sender/recipient pair, by a single `ShouldDeliverCallback`.

**Server (`ChatFilter.server.luau`):**
- `local textChannels = TextChatService:WaitForChild("TextChannels")` then `textChannels:WaitForChild("RBXGeneral")` — both use `WaitForChild` because the engine creates its default `TextChannels` folder asynchronously; indexing `TextChatService.TextChannels` directly can run before it exists and throw `"TextChannels is not a valid member of TextChatService"`.
- `generalChannel.ShouldDeliverCallback = function(textChatMessage, targetTextSource) ... end` is set once at script start and runs once per `(sender, recipient)` pair for every message. It looks up `GameState.PlayerData[senderUserId]` and `GameState.PlayerData[targetUserId]`; if either is missing (e.g. chat before roles are assigned), it fails open and returns `true`. The remaining logic runs in this order:
  1. **Ghost filter** (all phases): if the sender's `IsAlive == false` and the recipient's `IsAlive == true`, it `print("[CHAT FILTER] Blocked ghost message to living player")` and returns `false` — a dead player's message is invisible to any living recipient, in every game phase, regardless of room/pairing state.
  2. **Room privacy + Spy eavesdropping** (`SecretMeetings` only — everything below is skipped entirely outside this phase, so normal Day/Evening/Night chat is unrestricted aside from the ghost filter):
     ```lua
     local spyTarget = GameState.SpyTarget

     if senderData.Role == "Spy" and spyTarget ~= nil then
         return false
     end

     if targetData.Role == "Spy" and spyTarget ~= nil then
         if senderId == spyTarget then
             return true
         end
         if senderId == GameState.SecretPairs[spyTarget] then
             return true
         end
         return false
     end

     if senderData.IsAlive == true and targetData.IsAlive == true then
         if GameState.SecretPairs[senderId] == targetId then
             return true
         end
     end

     return false
     ```
     - **Baseline room privacy**: during `SecretMeetings`, two living players can hear each other only if they're each other's current room partner (`GameState.SecretPairs[senderId] == targetId`, the same bidirectional map `pairPlayersInRoom()` writes — see §11). Any other living-to-living pair falls through to the final `return false`, so cross-room chat is blocked entirely during this phase.
     - **The Spy's own messages are silent** whenever they've actively infiltrated a room (`GameState.SpyTarget ~= nil`, set by `handleEavesdrop()` — see §11): `senderData.Role == "Spy" and spyTarget ~= nil` returns `false` unconditionally, for every recipient. This is what makes eavesdropping *read-only* — the Spy is physically standing in someone else's private conversation, invisible and silent, not an active third participant.
     - **The Spy hears exactly the infiltrated pair, and no one else**: when the *recipient* being evaluated is the Spy (`targetData.Role == "Spy"`) and `spyTarget ~= nil`, delivery is allowed only if the sender is the eavesdropped-on player (`senderId == spyTarget`) or that player's original room partner (`senderId == GameState.SecretPairs[spyTarget]`) — i.e. the two people actually in the room the Spy pivoted into. Every other sender is denied, so the Spy can't accidentally overhear unrelated rooms just by being alive during `SecretMeetings`.
     - Because `GameState.SpyTarget` is a single value (not a list), only one room can be under active surveillance at a time — consistent with there being exactly one `Spy` role in `ROLES`.
- Because this runs per-recipient at the engine's delivery layer, it doesn't matter which channel a client's `ChatInputBarConfiguration.TargetTextChannel` happens to be pointed at — filtering is enforced server-side regardless of client UI state.
- `GameState.SpyTarget` is reset to `nil` (and `GameState.SecretPairs` cleared) on the `SecretMeetings → EveningGathering` transition in `GameLoop.server.luau` (see §2), so the eavesdropping/room-privacy branch above only ever evaluates non-`nil` state while `SecretMeetings` is actually active.

**Client (`ActionController.client.luau`):** the `AliveStatusUpdate` handler detects the local player's own alive→dead transition (`wasLocalPlayerAlive and not isPlayerAlive(localPlayer)`) and calls `TextChatService.TextChannels.RBXGeneral:DisplaySystemMessage(...)` with a red-tagged message: *"Welcome to the Graveyard chat. The living cannot hear you."* This is a purely local system message (not an actual chat message), so it only ever appears in that one client's own chat window. There is no equivalent client-side system message for the Spy — eavesdropping is silent by design, so the Spy gets no special chat UI beyond simply receiving the infiltrated room's messages.

## 8. UI State Syncing

`AliveStatusUpdate` is the single channel clients use to learn who's alive and whose ability is on cooldown. `broadcastAliveStatus()` exists in both `GameLoop.server.luau` and `ActionHandler.server.luau` (kept as two independent, identically-shaped implementations — a known duplication, not a shared helper) and fires:

```lua
{
    { UserId = 123, Name = "Player1", IsAlive = true, Cooldown = 0, ProtectedTarget = nil, BishopCooldown = 0, ScannedPlayers = {} },
    ...
}
```

Both copies were briefly out of sync — `ActionHandler.server.luau`'s went unpatched when the Bishop fields were first added to `GameLoop.server.luau`'s, so a broadcast fired right after `handleConfirmExecution()`/`handleAssassination()` landed a kill would momentarily reset the client's cached `localBishopCooldown`/`localScannedPlayers` to their zero-values. Both copies now include `BishopCooldown`/`ScannedPlayers` and are back in sync — if a third `broadcastAliveStatus()` implementation is ever added, or either of these two is extended again, keep the field lists identical, since nothing enforces that structurally.

`ProtectedTarget` mirrors that player's `PlayerData.ProtectedTargetUserId` — `nil` for everyone except a Martyr who has sworn their oath, in which case it's the `UserId` they're protecting. `BishopCooldown`/`ScannedPlayers` mirror the like-named `PlayerData` fields — see §13. The client only ever reads its own entry's fields (see §4/§11/§13), but the server includes every player's for shape-consistency with the rest of the snapshot.

The client stores this into two parallel lookup tables, `aliveStatus: {[UserId]: boolean}` and `cooldownStatus: {[UserId]: number}`. `isPlayerAlive(player)` defaults to `true` for any `UserId` not yet present (e.g. before the first broadcast lands); cooldown reads default to `0` the same way (`cooldownStatus[UserId] or 0`). `localProtectedTarget` (a plain local, not a table) is overwritten every broadcast from whichever snapshot entry matches `localPlayer.UserId`.

The four target-selection menus share a common shape — `populatePlayerList()` (King), `populateAssassinationList()` (Revolutionary), `populateUsurperList()` (Usurper), and `populateSpyList()` (Spy) — with two deliberate variations:
1. Destroy any previously-spawned target buttons and clear a previous `"NoValidTargetsLabel"` (looked up and destroyed by that fixed name, so it never stacks across repopulations).
2. Loop `Players:GetPlayers()`, filtering to `player ~= localPlayer and isPlayerAlive(player)`, spawning one `TextButton` per valid target and counting them. `populateSpyList()` adds one more filter on top — it `continue`s past whichever player's name equals `currentRoomPartner`, since eavesdropping on the room you're already in isn't a meaningful action.
3. If the count is `0`: disable the menu's action button (`Active = false`, `AutoButtonColor = false`, via the shared `setActionButtonEnabled` helper) and spawn a `"NO VALID TARGETS"` `TextLabel` (red-gray, `Color3.fromRGB(200, 60, 60)`) into the list container. If the count is `> 0`, the button is (re-)enabled — so a menu that was previously empty doesn't stay stuck disabled once valid targets exist again.

`populateMartyrList()` (Martyr — see §11) does **not** follow this shape: rather than looping every living player, it builds at most one button, for whichever player's name matches `currentRoomPartner` (looked up via `Players:FindFirstChild`, filtered to alive and not the local player). This is a deliberate restriction, not a filtered version of the general list — the oath can only ever target the Martyr's current room partner, so there is never more than one valid choice to present.

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

## 11. The Spy (Room Crasher)

The Spy trades their own `SecretMeetings` room pairing for the ability to physically relocate into someone else's room, invisible, and read that room's private chat — at the cost of abandoning their own partner and being unable to speak while eavesdropping.

**Room partner tracking (`GameState.SecretPairs` / `RoomPartnerSync`)**: every `SecretMeetings` phase, `runSecretMeetings()` in `GameLoop.server.luau` builds room pairs via `pairPlayersInRoom(playerA, playerB, room)`, which writes both directions of the pairing into the shared, bidirectional `GameState.SecretPairs` map (`SecretPairs[a] = b` and `SecretPairs[b] = a`) and fires `RoomPartnerSync:FireClient(...)` to each of the two players with the *other's* name (an unpaired solo player gets fired `""`). The client's `RoomPartnerSync.OnClientEvent` handler stores this as `currentRoomPartner`, coercing both `nil` and `""` to Lua `nil` (`(partnerName and partnerName ~= "") and partnerName or nil`) so downstream code can do simple truthiness checks. `SecretPairs` is `table.clear()`-ed on the `SecretMeetings → EveningGathering` transition (see §2), so it only ever reflects the *current* day's pairing.

**Eavesdrop action (`handleEavesdrop()` in `ActionHandler.server.luau`)**: fired via `ActionRequest("Eavesdrop", targetName)` from the client's `EavesdropButton` (see §4/§8 for `SpyMenu`/`populateSpyList()`/`spyTargetList`). Validates, in order: `GameState.CurrentState == "SecretMeetings"`; caller's `PlayerData.Role == "Spy"`; caller `IsAlive == true`; the target exists and isn't the caller; both the Spy's and the target's characters have a resolvable `HumanoidRootPart`. Only then does it act:
1. **Partner notification**: looks up the Spy's *own* current partner via `GameState.SecretPairs[player.UserId]` (i.e. before any state changes) and, if one exists, fires `PartnerDitched:FireClient(partnerPlayer)`. The client's `PartnerDitched.OnClientEvent` shows a 6-second red banner: *"YOUR PARTNER HAS ABANDONED YOU. YOU ARE ALONE."* This does not touch `SecretPairs` itself — the Spy's original partner is still nominally "paired" with the Spy in the data (it's a notification, not a repairing), it's only chat delivery (§7) and the Spy's own physical presence that actually change.
2. **Physical infiltration — teleport**: `spyCharacter:PivotTo(targetRoot.CFrame * CFrame.new(0, 5, 0))` moves the Spy's entire character to a position 5 studs above the target's `HumanoidRootPart`, i.e. directly into the target's Secret Room, hovering above them.
3. **Physical infiltration — invisibility & collision bypass**: `applySpyInvisibility(spyCharacter)` walks `spyCharacter:GetDescendants()` and, for every `BasePart`, sets `Transparency = 1` and `CollisionGroup = "Spies"`; for every `Decal`, `Transparency = 1`; for every `BillboardGui` (nametags etc.), `Enabled = false`. The `"Spies"` collision group is registered at `GameLoop.server.luau` script start alongside `"Alive"`/`"Ghosts"`, with `PhysicsService:CollisionGroupSetCollidable("Alive", "Spies", false)` — so a Spy mid-eavesdrop can stand inside/walk through the room's other occupants (and vice versa) without being physically blocked or shoved out, the same non-collision trick used for ghosts.
4. **Physical infiltration — catching late-loading parts**: `hookSpyDescendantListener(player, spyCharacter)` connects `spyCharacter.DescendantAdded` and applies the exact same transparency/`CollisionGroup` treatment to any descendant added *after* the initial pass — necessary because accessories/limbs can stream in asynchronously after a teleport/respawn, and a late-loading hat or hair that skipped the initial `GetDescendants()` sweep would otherwise render visibly and collide normally, giving the Spy away. The connection is stored per-player in `GameState.SpyConnections[player.UserId]`, disconnecting (and replacing) any pre-existing connection for that player first, so re-eavesdropping mid-game never leaks a stale listener.
5. **Server bookkeeping**: `GameState.SpyTarget = targetPlayer.UserId` — this is the flag `ChatFilter.server.luau` reads to grant the Spy read access to the infiltrated room's chat (see §7), and is also what the client's `updateVisibility()`/menu logic on the *Spy's own client* doesn't need to know about (the Spy client only cares about `currentRoomPartner` for its own target list).

**Cleanup**: on the `SecretMeetings → EveningGathering` transition (`GameLoop.server.luau`, see §2), every living Spy has `removeSpyInvisibility(character, player)` called on them: it walks `GetDescendants()` again, restoring every `BasePart`'s `CollisionGroup` to `"Alive"` and `Transparency` to `0` — **except** `HumanoidRootPart`, which is explicitly forced to `Transparency = 1` (matching how every character's root part is invisible by default in Roblox, Spy or not), restores `Decal` transparency to `0` and re-`Enabled`s every `BillboardGui`, then disconnects and clears that player's `GameState.SpyConnections` entry so no stale `DescendantAdded` listener keeps re-applying invisibility on the next respawn.

**Client target list (`populateSpyList()`)**: mirrors the generic target-list shape (see §8) but excludes whichever player's name matches `currentRoomPartner` — you can't "eavesdrop" on the room you're already in.

## 12. The Martyr (Room Crasher)

The Martyr can swear a one-time, irrevocable oath to protect their current room partner. Once sworn, they're permanently paired with that player every remaining day, and will die in that player's place if anyone tries to kill them.

**The Permanent Blood Oath (`handleMartyrOath()` in `ActionHandler.server.luau`)**: fired via `ActionRequest("MartyrOath", targetName)` from the client's `OathButton` (see §4/§8 for `MartyrMenu`/`populateMartyrList()`/`martyrTargetList`, and the client-side rule that the menu only ever shows one candidate — the current room partner). Validates, in order: `GameState.CurrentState == "SecretMeetings"`; caller's `PlayerData.Role == "Martyr"`; caller `IsAlive == true`; caller's `ProtectedTargetUserId` is currently `nil` (an oath can only be sworn once — a second attempt is silently rejected, which is also what makes the client-side permanent-hide behavior in §4 safe to rely on); the target exists and isn't the caller; and — the server-side enforcement mirroring the client's UI restriction — `GameState.SecretPairs[player.UserId] == targetPlayer.UserId`, i.e. the target really is the Martyr's *current* room partner per the server's own pairing state, not just whatever the client happened to send. If all of that holds, `requesterData.ProtectedTargetUserId = targetPlayer.UserId` is set and never touched again for the rest of the game (nothing clears it — not `table.clear(GameState.SecretPairs)`, not the day/night loop; only a fresh `assignRoles()` at game restart resets `PlayerData` entirely). The next `AliveStatusUpdate` broadcast propagates this to every client via the `ProtectedTarget` field (see §8), which is how the oath-taker's own client learns to permanently hide the `MartyrMenu` (see §4).

**Forced Matchmaking (`runSecretMeetings()` in `GameLoop.server.luau`)**: before the normal sequential pairing pass runs, `runSecretMeetings()` scans the (name-sorted) list of living players for one whose `PlayerData.Role == "Martyr"` and `ProtectedTargetUserId ~= nil`. If found, and the protected player (`Players:GetPlayerByUserId(data.ProtectedTargetUserId)`) is currently connected and alive, both the Martyr and their protected target are removed from the pool of players eligible for the normal pairing loop, and `pairPlayersInRoom(martyr, protectedPlayer, room)` forcibly seats them together in the next available room (`roomIndex`, starting at `Room1`) — with an extra debug note (`" (Martyr's forced oath pairing)"`) appended to the print log so this path is distinguishable from an organic pairing in server logs. This means that from the day the oath is sworn onward, the Martyr and their protected target are placed in the same Secret Room **every single day** for the rest of the game, regardless of how the rest of the player pool would have shuffled — the oath isn't just a protection flag, it's also a standing room assignment. The scan `break`s after handling the first oathbound Martyr it finds — with only one `Martyr` role in `ROLES`, this isn't a practical limitation today, but it means a hypothetical second Martyr wouldn't get the same forced-pairing treatment without further changes.

**The Night Sacrifice (`findLivingMartyrProtecting()` / `redirectToMartyr()`, both in `ActionHandler.server.luau`)**: `findLivingMartyrProtecting(targetUserId)` is a shared lookup — scanning all connected players for a living `Martyr` whose `ProtectedTargetUserId == targetUserId` — called from **both** lethal-action handlers immediately before they'd otherwise apply fatal damage:
- `handleConfirmExecution()` (King/Usurper-ordered kill, confirmed by a Sorcerer/Knight): checked right after confirming the target isn't the Prince and resolving a valid `Humanoid`, *before* setting `Health = 0`.
- `handleAssassination()` (Revolutionary's instant night kill): checked right after resolving a valid `Humanoid`, *before* setting `Health = 0`.

If a protecting Martyr is found, `redirectToMartyr(martyrPlayer, attackerPlayer, originalTargetPlayer)` runs instead of the normal kill: it sets the **Martyr's own** `Humanoid.Health = 0` and flips the **Martyr's own** `PlayerData.IsAlive = false` — the original target takes no damage and survives — then fires `StrikeIntercepted:FireClient(attackerPlayer, martyrPlayer.Name, originalTargetPlayer.Name)` to just the attacker (the executioner who confirmed the kill, or the Revolutionary), not a broadcast, so only the person responsible for the strike learns it was intercepted (and by whom). Both call sites then run their normal post-kill bookkeeping exactly as if the kill had landed on the original target: `handleConfirmExecution()` still fires `FakeOrderRevealed`/assigns the Usurper's `Cooldown = 3` if `activeMurder.RequesterRole == "Usurper"` (the King/Usurper distinction is about who gave the order, not who ended up dead), clears `PendingActions.ActiveMurder`, and calls `broadcastAliveStatus()`; `handleAssassination()` likewise calls `broadcastAliveStatus()` (its Rule-of-Chronology `OrderVoided` check, keyed on the *original* target's `UserId`, correctly does **not** fire here, since the player whose order might have been voided by dying is the Martyr, not the original target, and the Martyr was never a `RequesterId` for anything). A dead Martyr is not exempt from being someone else's kill target in a later round — `findLivingMartyrProtecting()` filters on `IsAlive == true`, so once a Martyr has sacrificed themselves, no future strike can be redirected to them.

**Client notification (`StrikeIntercepted.OnClientEvent` in `ActionController.client.luau`)**: shows a 6-second red banner via the shared `showTemporaryBanner` helper: *"YOUR STRIKE ON `<ORIGINAL TARGET, UPPERCASE>` WAS INTERCEPTED BY `<MARTYR NAME, UPPERCASE>`!"* — only the attacking client sees this; there's no corresponding UI event for the original target (who is simply still alive) or for the wider room (the interception is invisible to everyone except the would-be killer).

## 13. The Bishop

The Bishop has a stealthy, cooldown-gated ability that reveals which of the four win conditions their *current room partner* is fighting for — without ever notifying the target they were scanned.

**Data layer (`PlayerData.BishopCooldown` / `PlayerData.ScannedPlayers`)**: both fields are initialized by `assignRoles()` in `GameLoop.server.luau` — `BishopCooldown = 0` (scan immediately available) and `ScannedPlayers = {}` (a fresh, empty array-style table of previously-revealed `UserId`s) — for every player regardless of role, same as `ProtectedTargetUserId`. `BishopCooldown` is decremented once per day by a dedicated loop at the very start of the `DayGathering` branch in the main `while true do` loop (see §2): it iterates every alive player and, if their `Role == "Bishop"` and `BishopCooldown > 0`, subtracts `1`. This is a separate mechanism from `tickCooldowns()` (which only touches the generic `Cooldown` field used by the Usurper — see §10) and runs on a different cadence: `tickCooldowns()` fires once per `NightPhase → DayGathering` transition, while the Bishop's decrement fires every time the loop *enters* `DayGathering`, including the very first day. `ScannedPlayers` only ever grows via `table.insert()` in `handleBishopReveal()` and is never cleared for the rest of the game, so a given target can only ever be scanned once, permanently.

**Win Condition Map (`WIN_CONDITIONS` in `ActionHandler.server.luau`)**: a local, static dictionary — not stored on `PlayerData`, computed fresh from `targetData.Role` on every reveal:

```lua
local WIN_CONDITIONS = {
    King = "The Crown", Sorcerer = "The Crown", Prince = "The Crown", Knight = "The Crown", Double = "The Crown",
    Revolutionary = "The Uprising", Peasant = "The Uprising", Spy = "The Uprising",
    Usurper = "The Rogue",
    Martyr = "The Oathbound",
}
```

Notably, `Bishop` itself has no entry — scanning another Bishop would resolve `winCondition` to `nil` and reveal `"nil"` in the banner text; this hasn't come up in testing since the test rig only ever seats one Bishop.

**The Server Action (`handleBishopReveal(player)` in `ActionHandler.server.luau`)**: fired via `ActionRequest("BishopReveal")` from the client's `RevealButton` — deliberately called with **no** `targetName` argument, unlike every other action in the dispatcher (see §3's `ActionRequest` row for the resulting dispatcher-level change: the top-level guard was loosened from requiring `targetName` to be a string to allowing it to be `nil`, specifically to let this action through). Validates, in order: `GameState.CurrentState == "SecretMeetings"`; caller's `PlayerData.Role == "Bishop"`; caller `IsAlive == true`; caller's `BishopCooldown == 0`. It then:
1. **Resolves the target implicitly**: `targetId = GameState.SecretPairs[player.UserId]` — there's no target *parameter* at all; the Bishop can only ever scan whoever they're currently room-paired with (see §11 for how `SecretPairs` is populated). If `targetId` is `nil` (the Bishop is solo that day), the function returns early — a solo Bishop cannot scan.
2. **Rejects repeat scans**: `table.find(requesterData.ScannedPlayers, targetId)` — if the target has already been revealed at any point this game, the action is silently rejected (no cooldown is spent, no error is surfaced to the client beyond the menu simply not being offered — see the client-side gating below).
3. **Applies the cooldown and records the scan**: `requesterData.BishopCooldown = 2` and `table.insert(requesterData.ScannedPlayers, targetId)` — both happen together, unconditionally, once every validation above has passed and *before* the reveal is resolved, so even if something downstream were to fail the cooldown/record has already been committed (there's no rollback path).
4. **The stealth reveal**: resolves `targetPlayer`/`targetData` from `targetId`, looks up `WIN_CONDITIONS[targetData.Role]`, and fires `RoleRevealed:FireClient(player, targetPlayer.Name, winCondition)` — to the Bishop **only**. Nothing is fired to the target, no broadcast happens, and `broadcastAliveStatus()` is never called from this handler — the scan leaves no trace visible to anyone but the Bishop (aside from the delayed, incidental `BishopCooldown`/`ScannedPlayers` sync described in §8's gap).

**The Client UI (`ActionController.client.luau`)**: the `BishopMenu` contains only a `RevealButton` — no `PlayerList`, since there's nothing to choose (the target is implicit, same rationale as the Martyr's old partner-only restriction). `updateVisibility()` computes a local `bishopPartnerAlreadyScanned` boolean ahead of its branch chain: if `currentRoomPartner` is set, it resolves the corresponding `Player` via `Players:FindFirstChild(currentRoomPartner)` and checks `table.find(localScannedPlayers, partnerPlayer.UserId)`. The `"Bishop"` branch then requires **all** of: state contains `"secret"`, role is `"Bishop"`, `localBishopCooldown == 0`, `currentRoomPartner ~= nil`, and `not bishopPartnerAlreadyScanned` — mirroring the server's validation client-side so the menu only ever appears when a reveal would actually succeed. `revealButton.MouseButton1Click` fires `ActionRequest:FireServer("BishopReveal")` with no second argument, then closes the menu (`activeMenu = "None"`, `renderUI()`) without waiting for a response.

**The banner (`RoleRevealed.OnClientEvent`)**: shows *"`<TARGET, UPPERCASE>` FIGHTS FOR: `<WIN CONDITION, UPPERCASE>`"* for 6 seconds. This is the first banner that isn't red: `showTemporaryBanner(name, text, duration, color: Color3?)` was extended with an optional fourth `color` parameter (defaulting to the existing `BANNER_TEXT_COLOR` red when omitted, so every pre-existing call site — `OrderVoided`, `FakeOrderRevealed`, `PartnerDitched`, `StrikeIntercepted` — is unaffected), and a new `BANNER_SUCCESS_COLOR = Color3.fromRGB(0, 200, 0)` (green) is passed explicitly for this one call, signaling that a Bishop reveal is a "win," not a warning, unlike every other banner in the game.
