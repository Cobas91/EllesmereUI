if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EUI_ClassicEnv then setfenv(1, EUI_ClassicEnv) end -- Classic Era port: suite-private API stand-ins (EllesmereUI_ClassicCompat.lua)
-------------------------------------------------------------------------------
--  EllesmereUIDamageMeters_ClassicEngine.lua  (WoW Classic Era ONLY)
--
--  Retail's C_DamageMeter is Blizzard's own built-in personal meter (added
--  ~patch 11.0). It does not exist on Classic Era and there is no way to
--  shim it into reporting real numbers -- the feature genuinely isn't on
--  this client. This file is a from-scratch replacement data source: it
--  parses COMBAT_LOG_EVENT_UNFILTERED itself and republishes the results
--  through a drop-in C_DamageMeter-shaped API (same function names, same
--  Enum.DamageMeterType / Enum.DamageMeterSessionType constants, same
--  return-table shapes) so EllesmereUIDamageMeters.lua's existing
--  window/render/skin code needs no changes at all.
--
--  Loads BEFORE EllesmereUIDamageMeters.lua (see the .toc) so Enum.DamageMeterType
--  and Enum.DamageMeterSessionType already exist as real tables -- not the
--  core compat shim's stub -- the moment the main file reads them as
--  literal keys at file scope (e.g. `DM_TYPE_NAMES[Enum.DamageMeterType.DamageDone]`).
--
--  FIDELITY, honestly stated:
--   - Real: per-source (player/pet, pets folded into owner) totals for
--     Damage Done, Healing Done, Damage Taken, Interrupts, Dispels, Deaths,
--     and Enemy Damage Taken, each with a live-updating per-spell/per-source
--     breakdown, for a "Current" segment (current pull / since combat start)
--     and an "Overall" segment (since login or last manual reset), plus a
--     rolling history of up to 20 past segments ("Select Segment" menu).
--   - DPS/HPS = plain total / elapsed segment seconds (no sliding window;
--     retail's C_DamageMeter does not document a windowed average either,
--     and the main file's AmountPerSecond() already does flat division).
--   - Simplified/stubbed, and WHY:
--     * AvoidableDamageTaken is NOT filtered to "avoidable" hits -- Classic
--       Era's combat log carries no server-side avoidability flag for this,
--       so it is an alias of the DamageTaken bucket. Honest approximation,
--       not a fabricated metric.
--     * Death recap (the "last 5 hits before death" replay) is NOT
--       implemented: it depends on Retail's C_DeathRecap, which the core
--       compat shim already stubs to inert no-ops. A Deaths row still shows
--       the correct name/time; opening it shows nothing instead of a hit
--       replay. Out of scope for a combat-log parser to fabricate.
--     * Threat / overheal-exact / resource-specific icon fields: not
--       produced (retail-only convenience fields the main file already
--       guards as optional almost everywhere).
--     * Overkill on Deaths rows is not tracked (would require per-hit HP
--       snapshots identical to death-recap machinery); always nil/omitted.
-------------------------------------------------------------------------------
local _, ns = ...
if not EllesmereUI or not EllesmereUI.IS_CLASSIC_ERA then return end -- Retail/Forever already have the real C_DamageMeter
-- Real API already present: never override it. rawget, because the core compat
-- shim (EllesmereUI_ClassicCompat.lua) installs C_DamageMeter as a stub table
-- whose every key reads back a callable no-op.
if type(C_DamageMeter) == "table" and type(rawget(C_DamageMeter, "GetAvailableCombatSessions")) == "function" then return end

-------------------------------------------------------------------------------
--  Enum constants. Stable, arbitrary integers -- these get persisted raw
--  into SavedVariables (window curDMType/curSession), so once chosen they
--  must never change across versions of this file.
-------------------------------------------------------------------------------
Enum.DamageMeterType = Enum.DamageMeterType or {
    DamageDone           = 1,
    HealingDone          = 2,
    DamageTaken          = 3,
    AvoidableDamageTaken = 4,
    EnemyDamageTaken      = 5,
    Interrupts           = 6,
    Dispels              = 7,
    Deaths               = 8,
}
Enum.DamageMeterSessionType = Enum.DamageMeterSessionType or {
    Current = 1,
    Overall = 2,
}
-- A client that ships a partial Enum.DamageMeterType still needs every key the
-- main file indexes; missing ones get fresh values above the existing ones.
do
    local function Fill(t, keys)
        local top = 0
        for _, v in pairs(t) do if type(v) == "number" and v > top then top = v end end
        for _, k in ipairs(keys) do
            if t[k] == nil then top = top + 1; t[k] = top end
        end
    end
    Fill(Enum.DamageMeterType, { "DamageDone", "HealingDone", "DamageTaken", "AvoidableDamageTaken",
        "EnemyDamageTaken", "Interrupts", "Dispels", "Deaths" })
    Fill(Enum.DamageMeterSessionType, { "Current", "Overall" })
end

local DMT = Enum.DamageMeterType
local DMST = Enum.DamageMeterSessionType

-------------------------------------------------------------------------------
--  Small local helpers
-------------------------------------------------------------------------------
local GetTime, UnitGUID, UnitName, UnitClass, UnitExists = GetTime, UnitGUID, UnitName, UnitClass, UnitExists
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local bAND = bit and bit.band

-- COMBATLOG_OBJECT_* bitmask constants exist as globals on Classic Era too
-- (same combat log security model fields, just no secret-value wrapping).
local FLAG_MINE   = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1
local FLAG_PARTY  = COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2
local FLAG_RAID   = COMBATLOG_OBJECT_AFFILIATION_RAID or 0x4
local FLAG_PET    = COMBATLOG_OBJECT_TYPE_PET or 0x1000
local FLAG_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x2000
local FLAG_OBJECT = COMBATLOG_OBJECT_TYPE_OBJECT or 0x4000
local MY_GROUP = FLAG_MINE + FLAG_PARTY + FLAG_RAID

-------------------------------------------------------------------------------
--  Pet/guardian -> owner GUID resolution.
--
--  Classic Era does not send an explicit "owner GUID" field on pet combat
--  log lines the way Retail sometimes annotates, so ownership is resolved
--  the same way every Classic-era meter (Details included) does it: watch
--  UNIT_PET for the player/party/raid pet slots and snapshot
--  UnitGUID("pet")/UnitGUID("partyN pet")/UnitGUID("raidN pet") into a
--  guid->ownerGUID map whenever the slot changes. A damage/heal line whose
--  source GUID matches a known pet slot is folded into its owner's totals;
--  anything else flagged PET/GUARDIAN but not in the map is left standing
--  on its own name (e.g. a hunter's pet seen before its first UNIT_PET, or
--  another group's pet in an Enemy Damage Taken read) rather than guessed.
-------------------------------------------------------------------------------
local petOwnerGUID = {}   -- [petGUID] = ownerGUID
local petOwnerName = {}   -- [petGUID] = ownerName (cached, avoids UnitName races on roster churn)

local PET_UNITS = { "pet", "party1pet", "party2pet", "party3pet", "party4pet" }
do
    local raidPets = {}
    for i = 1, 40 do raidPets[i] = "raid" .. i .. "pet" end
    local function RescanPets()
        for _, u in ipairs(PET_UNITS) do
            if UnitExists(u) then
                local pg = UnitGUID(u)
                local ownerUnit = u:gsub("pet$", "")
                if ownerUnit == "" then ownerUnit = "player" end
                local og = UnitGUID(ownerUnit)
                if pg and og then
                    petOwnerGUID[pg] = og
                    petOwnerName[pg] = UnitName(ownerUnit)
                end
            end
        end
        for _, u in ipairs(raidPets) do
            if UnitExists(u) then
                local pg = UnitGUID(u)
                local ownerUnit = u:gsub("pet$", "")
                local og = UnitGUID(ownerUnit)
                if pg and og then
                    petOwnerGUID[pg] = og
                    petOwnerName[pg] = UnitName(ownerUnit)
                end
            end
        end
    end
    ns._DMRescanPets = RescanPets

    local petFrame = CreateFrame("Frame")
    petFrame:RegisterEvent("UNIT_PET")
    petFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    petFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    petFrame:SetScript("OnEvent", RescanPets)
end

-- Resolve a combat log source/dest GUID+name+flags to the "attribution
-- identity" actually credited in the meter: pets/guardians fold into their
-- owner; everyone else is themselves. Returns guid, name, isMine(boolean).
local function ResolveAttribution(guid, name, flags)
    if guid and petOwnerGUID[guid] then
        return petOwnerGUID[guid], petOwnerName[guid] or name, true
    end
    local isMine = flags and bAND and bAND(flags, MY_GROUP) ~= 0
    return guid, name, isMine
end

-------------------------------------------------------------------------------
--  Per-segment accumulator. One of these exists for "current" (live/last
--  pull) and one for "overall" (whole session). Each holds:
--    sources: ordered array of { guid, name, class, totalAmount, ... }
--    byGUID:  guid -> that same table (for O(1) accumulation)
--  for each of the tracked DamageMeterType buckets, PLUS a parallel
--  "enemiesHit" structure (keyed by destGUID) used only to answer Enemy
--  Damage Taken / Damage Done-targets queries.
-------------------------------------------------------------------------------
local function NewBucket()
    return { sources = {}, byGUID = {} }
end

local function NewSegment()
    return {
        startTime = GetTime(),
        buckets = {
            [DMT.DamageDone]  = NewBucket(),
            [DMT.HealingDone] = NewBucket(),
            [DMT.DamageTaken] = NewBucket(),
            [DMT.Interrupts]  = NewBucket(),
            [DMT.Dispels]     = NewBucket(),
        },
        deaths = {},       -- array of { guid, name, class, deathTimeSeconds, deathRecapID }
        enemyTaken = {},   -- destGUID -> { guid, name, totalAmount, spells = { [srcGUID] = { spellID/name per attacker, combatSpellDetails } } }
        enemyOrder = {},   -- ordered destGUIDs seen (for stable Enemy Damage Taken listing)
    }
end

local current = NewSegment()
local overall = NewSegment()
local history = {}        -- array of { sessionID, name, durationSeconds, segment }
local nextSessionID = 1
local inCombat = false
local lastDamageTime = 0

-- A fake "deathRecapID" generator: NeverSecret unique integer, same
-- contract the main file already expects (> 0 == real, used only as a
-- dedupe/lookup key, never dereferenced into recap event data here).
local nextRecapID = 1

-------------------------------------------------------------------------------
--  Accumulation
-------------------------------------------------------------------------------
local function GetOrCreateSource(bucket, guid, name, class)
    local src = bucket.byGUID[guid]
    if not src then
        src = {
            sourceGUID = guid,
            name = name,
            classFilename = class,
            specIconID = nil,
            totalAmount = 0,
            amountPerSecond = 0,
            combatSpells = {},
            spellByID = {},
            isLocalPlayer = (guid ~= nil and guid == UnitGUID("player")),
        }
        bucket.byGUID[guid] = src
        bucket.sources[#bucket.sources + 1] = src
    elseif name and src.name ~= name then
        src.name = name -- keep the latest known display name (realm-join races, etc.)
    end
    return src
end

local function AddSpellAmount(src, spellID, spellName, amount)
    local key = spellID or spellName or 0
    local sp = src.spellByID[key]
    if not sp then
        sp = { spellID = spellID, creatureName = spellName, totalAmount = 0 }
        src.spellByID[key] = sp
        src.combatSpells[#src.combatSpells + 1] = sp
    end
    sp.totalAmount = sp.totalAmount + amount
end

local function AddToBucket(seg, dmType, guid, name, class, spellID, spellName, amount)
    if amount == nil or amount <= 0 then return end
    local bucket = seg.buckets[dmType]
    if not bucket then return end
    local src = GetOrCreateSource(bucket, guid, name, class)
    src.totalAmount = src.totalAmount + amount
    AddSpellAmount(src, spellID, spellName, amount)
end

local function AddCount(seg, dmType, guid, name, class)
    local bucket = seg.buckets[dmType]
    if not bucket then return end
    local src = GetOrCreateSource(bucket, guid, name, class)
    src.totalAmount = (src.totalAmount or 0) + 1
end

-- Enemy Damage Taken: credit the hit to the destination (the enemy), broken
-- down by attacking player/pet-owner, mirroring the shape
-- AggregateEnemyPlayers()/BuildAllPlayerTargets() in the main file expect
-- (srcData.combatSpells[i].combatSpellDetails.{unitName,unitClassFilename}).
local function AddEnemyTaken(seg, destGUID, destName, srcGUID, srcName, srcClass, spellID, spellName, amount)
    if not destGUID or amount == nil or amount <= 0 then return end
    local e = seg.enemyTaken[destGUID]
    if not e then
        e = { sourceGUID = destGUID, sourceCreatureID = tonumber(destGUID and destGUID:match("Creature%-.-%-.-%-.-%-.-%-(%d+)")),
              name = destName, totalAmount = 0, combatSpells = {}, byAttacker = {} }
        seg.enemyTaken[destGUID] = e
        seg.enemyOrder[#seg.enemyOrder + 1] = destGUID
    elseif destName then
        e.name = destName
    end
    e.totalAmount = e.totalAmount + amount
    local atk = e.byAttacker[srcGUID or srcName or "?"]
    if not atk then
        atk = {
            spellID = spellID,
            creatureName = spellName,
            totalAmount = 0,
            combatSpellDetails = { unitName = srcName, unitClassFilename = srcClass, specIconID = nil },
        }
        e.byAttacker[srcGUID or srcName or "?"] = atk
        e.combatSpells[#e.combatSpells + 1] = atk
    end
    atk.totalAmount = atk.totalAmount + amount
end

-------------------------------------------------------------------------------
--  Combat log dispatch. One registration, table-driven on sub-event so this
--  stays cheap at high log volume (matches the dispatch style every mature
--  Classic Era parser -- Details included -- uses instead of a long
--  if/elseif chain).
-------------------------------------------------------------------------------
local DAMAGE_SUBEVENTS = {
    SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true, DAMAGE_SHIELD = true, ENVIRONMENTAL_DAMAGE = true,
}
local HEAL_SUBEVENTS = {
    SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true,
}

local function HandleCombatLogEvent()
    local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags, _,
          destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        -- Only track deaths of units we actually care about (group members and their pets/guardians)
        local attribGUID, attribName, isMine = ResolveAttribution(destGUID, destName, destFlags)
        if isMine or (destFlags and bAND and bAND(destFlags, MY_GROUP) ~= 0) then
            local _, class = UnitClass and (destGUID == UnitGUID("player") and "player" or nil) -- best-effort; class resolved below from cache
            local rid = nextRecapID; nextRecapID = nextRecapID + 1
            local deathEntry = {
                sourceGUID = attribGUID, sourceCreatureID = nil,
                name = attribName, classFilename = ns._DMKnownClass and ns._DMKnownClass[attribGUID] or nil,
                deathTimeSeconds = GetTime() - current.startTime,
                deathRecapID = rid, totalAmount = 0,
            }
            current.deaths[#current.deaths + 1] = deathEntry
            local overallEntry = {}
            for k, v in pairs(deathEntry) do overallEntry[k] = v end
            overallEntry.deathTimeSeconds = GetTime() - overall.startTime
            overall.deaths[#overall.deaths + 1] = overallEntry
        end
        return
    end

    if subevent == "SPELL_INTERRUPT" then
        local spellID, spellName = select(12, CombatLogGetCurrentEventInfo())
        local attribGUID, attribName, isMine = ResolveAttribution(sourceGUID, sourceName, sourceFlags)
        if isMine then
            local _, class = sourceGUID == UnitGUID("player") and UnitClass("player") or nil
            AddCount(current, DMT.Interrupts, attribGUID, attribName, class)
            AddCount(overall, DMT.Interrupts, attribGUID, attribName, class)
        end
        return
    end

    if subevent == "SPELL_DISPEL" or subevent == "SPELL_STOLEN" then
        local attribGUID, attribName, isMine = ResolveAttribution(sourceGUID, sourceName, sourceFlags)
        if isMine then
            local _, class = sourceGUID == UnitGUID("player") and UnitClass("player") or nil
            AddCount(current, DMT.Dispels, attribGUID, attribName, class)
            AddCount(overall, DMT.Dispels, attribGUID, attribName, class)
        end
        return
    end

    if not (DAMAGE_SUBEVENTS[subevent] or HEAL_SUBEVENTS[subevent]) then return end

    local isHeal = HEAL_SUBEVENTS[subevent] and true or false
    local spellID, spellName, amount, overkillOrOverheal

    if subevent == "SWING_DAMAGE" then
        spellID, spellName = nil, "Melee"
        amount = select(12, CombatLogGetCurrentEventInfo())
        overkillOrOverheal = select(13, CombatLogGetCurrentEventInfo())
    elseif subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE" or subevent == "DAMAGE_SHIELD" then
        spellID, spellName = select(12, CombatLogGetCurrentEventInfo())
        amount = select(15, CombatLogGetCurrentEventInfo())
        overkillOrOverheal = select(16, CombatLogGetCurrentEventInfo())
    elseif subevent == "SPELL_PERIODIC_DAMAGE" then
        spellID, spellName = select(12, CombatLogGetCurrentEventInfo())
        amount = select(15, CombatLogGetCurrentEventInfo())
        overkillOrOverheal = select(16, CombatLogGetCurrentEventInfo())
    elseif subevent == "ENVIRONMENTAL_DAMAGE" then
        -- environmentalType, amount, ... -- no attacker; skip (no source to credit)
        return
    elseif isHeal then
        spellID, spellName = select(12, CombatLogGetCurrentEventInfo())
        amount = select(15, CombatLogGetCurrentEventInfo())
        overkillOrOverheal = select(16, CombatLogGetCurrentEventInfo()) -- overhealing
    end

    amount = tonumber(amount) or 0
    -- Healing Done counts effective healing, as Blizzard's meter does: the
    -- overheal part of a heal is dropped.
    if isHeal then
        local over = tonumber(overkillOrOverheal) or 0
        if over > 0 then amount = amount - over end
    end
    if amount <= 0 then return end

    local attribGUID, attribName, isMine = ResolveAttribution(sourceGUID, sourceName, sourceFlags)
    if not attribGUID then return end

    -- Only credit hits where the ATTRIBUTED source is our own player/pet/party/raid.
    -- This is the standard Classic Era meter filter: it also naturally drops
    -- enemy-vs-enemy and unrelated-player combat log noise from other groups.
    if not isMine then
        -- Not ours to credit as Damage/Healing Done, but still useful for
        -- Enemy Damage Taken IF the destination is an enemy and the true
        -- source (post pet-fold) is some other tracked ally -- out of scope
        -- for solo/small-group play; skip.
        -- Fall through to Damage Taken handling below if WE are the destination.
    else
        local _, srcClass
        if attribGUID == UnitGUID("player") then
            _, srcClass = UnitClass("player")
        else
            srcClass = ns._DMKnownClass and ns._DMKnownClass[attribGUID]
        end
        if isHeal then
            AddToBucket(current, DMT.HealingDone, attribGUID, attribName, srcClass, spellID, spellName, amount)
            AddToBucket(overall, DMT.HealingDone, attribGUID, attribName, srcClass, spellID, spellName, amount)
        else
            AddToBucket(current, DMT.DamageDone, attribGUID, attribName, srcClass, spellID, spellName, amount)
            AddToBucket(overall, DMT.DamageDone, attribGUID, attribName, srcClass, spellID, spellName, amount)
            -- Enemy Damage Taken view: credit the destination enemy, broken
            -- down by attacker (us).
            if destGUID and destFlags and bAND and bAND(destFlags, MY_GROUP) == 0 then
                AddEnemyTaken(current, destGUID, destName, attribGUID, attribName, srcClass, spellID, spellName, amount)
                AddEnemyTaken(overall, destGUID, destName, attribGUID, attribName, srcClass, spellID, spellName, amount)
            end
        end
    end

    -- Damage Taken: destination is one of ours (group member or our pet),
    -- regardless of who/what hit them.
    if not isHeal and destGUID and destFlags and bAND and bAND(destFlags, MY_GROUP) ~= 0 then
        local destAttribGUID, destAttribName = ResolveAttribution(destGUID, destName, destFlags)
        local destClass = (destAttribGUID == UnitGUID("player")) and select(2, UnitClass("player"))
            or (ns._DMKnownClass and ns._DMKnownClass[destAttribGUID])
        AddToBucket(current, DMT.DamageTaken, destAttribGUID, destAttribName, destClass, spellID, spellName, amount)
        AddToBucket(overall, DMT.DamageTaken, destAttribGUID, destAttribName, destClass, spellID, spellName, amount)
    end

    if not isHeal then lastDamageTime = GetTime() end
end

-------------------------------------------------------------------------------
--  Known-class cache: populated from the group roster so pet/party/raid
--  members' classFilename is available without a UnitClass(guid) call
--  (which doesn't exist -- UnitClass needs a unit token, not a GUID).
-------------------------------------------------------------------------------
do
    ns._DMKnownClass = {}
    local function RescanClasses()
        local g, _, class = UnitGUID("player"), UnitClass("player")
        if g then ns._DMKnownClass[g] = select(2, UnitClass("player")) end
        if IsInRaid and IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local u = "raid" .. i
                if UnitExists(u) then
                    local ug = UnitGUID(u)
                    if ug then ns._DMKnownClass[ug] = select(2, UnitClass(u)) end
                end
            end
        elseif IsInGroup and IsInGroup() then
            for i = 1, GetNumGroupMembers() - 1 do
                local u = "party" .. i
                if UnitExists(u) then
                    local ug = UnitGUID(u)
                    if ug then ns._DMKnownClass[ug] = select(2, UnitClass(u)) end
                end
            end
        end
    end
    local classFrame = CreateFrame("Frame")
    classFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    classFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    classFrame:SetScript("OnEvent", RescanClasses)
    RescanClasses()
end

-------------------------------------------------------------------------------
--  Segment lifecycle: ENCOUNTER_START/END where available (Classic Era DOES
--  fire these for the handful of encounters flagged by Blizzard, e.g. some
--  Classic dungeon/raid bosses), otherwise PLAYER_REGEN_DISABLED/ENABLED.
--  Mirrors the main file's own existing combat-state frame (it does not
--  touch this engine file at all -- it only reads results through
--  C_DamageMeter), firing the SAME custom events
--  (DAMAGE_METER_COMBAT_SESSION_UPDATED / DAMAGE_METER_CURRENT_SESSION_UPDATED
--  / DAMAGE_METER_RESET) the main file already listens for, so its refresh
--  plumbing needs no changes.
-------------------------------------------------------------------------------
-- The main file's session frame cannot RegisterEvent these retail event
-- names here (an unknown event is a Lua error on this client, so its
-- registrations go through EUI_SafeRegisterEvent and are skipped); it hands
-- the frame to ns.DM_ClassicListen instead, and the engine calls that frame's
-- OnEvent script with the same event names. Nothing here touches the shared
-- Frame metatable: hooking RegisterEvent there would taint Blizzard's calls.
local listeners = {}

function ns.DM_ClassicListen(frame)
    if not frame then return end
    for i = 1, #listeners do if listeners[i] == frame then return end end
    listeners[#listeners + 1] = frame
end

local function FireCustomEvent(name)
    for i = 1, #listeners do
        local f = listeners[i]
        local fn = f.GetScript and f:GetScript("OnEvent")
        if fn then
            local ok, err = pcall(fn, f, name)
            if not ok then geterrorhandler()(err) end
        end
    end
end

-- Debounced: combat log events fire far too often to re-signal "session
-- updated" on every single one; batch to ~10/sec like the main file's own
-- 0.1s debounce on the real event already assumes.
local pendingSessionUpdate = false
local function SignalSessionUpdated()
    if pendingSessionUpdate then return end
    pendingSessionUpdate = true
    C_Timer.After(0.1, function()
        pendingSessionUpdate = false
        FireCustomEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
    end)
end

local engineFrame = CreateFrame("Frame")
engineFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
engineFrame:RegisterEvent("ENCOUNTER_START")
engineFrame:RegisterEvent("ENCOUNTER_END")
engineFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
engineFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local function ArchiveCurrentSegment()
    if #current.buckets[DMT.DamageDone].sources == 0
       and #current.buckets[DMT.HealingDone].sources == 0
       and #current.deaths == 0 then
        return -- nothing happened; don't clutter the segment history with empty pulls
    end
    local sid = nextSessionID; nextSessionID = nextSessionID + 1
    history[#history + 1] = {
        sessionID = sid,
        name = "Combat",
        durationSeconds = math.max(0, GetTime() - current.startTime),
        segment = current,
    }
    -- Cap history like the main file's own "last 20" menu window
    while #history > 20 do table.remove(history, 1) end
end

local function RollCurrentSegment()
    ArchiveCurrentSegment()
    current = NewSegment()
    FireCustomEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
end

engineFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local ok, err = pcall(HandleCombatLogEvent)
        if not ok then geterrorhandler()(err) end
        SignalSessionUpdated()
        return
    end
    if event == "ENCOUNTER_START" then
        inCombat = true
        RollCurrentSegment()
        return
    end
    if event == "ENCOUNTER_END" then
        local success = select(5, ...)
        if success == 1 then
            -- Clean kill: close the segment promptly rather than waiting on
            -- PLAYER_REGEN_ENABLED, which can lag by several seconds.
            C_Timer.After(0.3, function()
                if not InCombatLockdown() then
                    inCombat = false
                    ArchiveCurrentSegment()
                    FireCustomEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
                end
            end)
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        RollCurrentSegment()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        -- Short delay mirrors the main file's own 0.5s "let data finalize"
        -- pause after combat end.
        C_Timer.After(0.5, function()
            ArchiveCurrentSegment()
            FireCustomEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
        end)
        return
    end
end)

-------------------------------------------------------------------------------
--  C_DamageMeter-shaped public API
-------------------------------------------------------------------------------
-- C_DamageMeter is the suite-private stub table (EllesmereUI_ClassicCompat.lua);
-- the engine fills it in place, so no other addon ever sees this API.

local function SegmentFor(sessionType, sessionID)
    if sessionID then
        for i = 1, #history do
            if history[i].sessionID == sessionID then return history[i].segment, history[i].durationSeconds end
        end
        return nil
    end
    if sessionType == DMST.Overall then return overall, math.max(0, GetTime() - overall.startTime) end
    return current, math.max(0, GetTime() - current.startTime)
end

local function SortedSources(bucket, duration)
    local list = bucket.sources
    table.sort(list, function(a, b) return (a.totalAmount or 0) > (b.totalAmount or 0) end)
    for i = 1, #list do
        local s = list[i]
        s.amountPerSecond = (duration and duration > 0) and (s.totalAmount / duration) or 0
        table.sort(s.combatSpells, function(a, b) return (a.totalAmount or 0) > (b.totalAmount or 0) end)
    end
    return list
end

local function SortedDeaths(seg)
    -- API semantics (see main file): "most recent first"
    local out = {}
    for i = #seg.deaths, 1, -1 do out[#out + 1] = seg.deaths[i] end
    return out
end

local function SortedEnemyTaken(seg, duration)
    local list = {}
    for i = 1, #seg.enemyOrder do
        local g = seg.enemyOrder[i]
        local e = seg.enemyTaken[g]
        if e then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return (a.totalAmount or 0) > (b.totalAmount or 0) end)
    for i = 1, #list do
        list[i].amountPerSecond = (duration and duration > 0) and (list[i].totalAmount / duration) or 0
    end
    return list
end

function C_DamageMeter.GetSessionDurationSeconds(sessionType)
    local _, duration = SegmentFor(sessionType)
    return duration or 0
end

function C_DamageMeter.GetAvailableCombatSessions()
    local out = {}
    for i = 1, #history do
        out[i] = { sessionID = history[i].sessionID, name = history[i].name, durationSeconds = history[i].durationSeconds }
    end
    return out
end

function C_DamageMeter.ResetAllCombatSessions()
    current = NewSegment()
    overall = NewSegment()
    history = {}
    FireCustomEvent("DAMAGE_METER_RESET")
end

local function BuildSessionResult(seg, duration, dmType)
    if dmType == DMT.Deaths then
        return { combatSources = SortedDeaths(seg) }
    end
    if dmType == DMT.Interrupts or dmType == DMT.Dispels then
        return { combatSources = SortedSources(seg.buckets[dmType], duration) }
    end
    if dmType == DMT.EnemyDamageTaken then
        return { combatSources = SortedEnemyTaken(seg, duration) }
    end
    -- DamageDone, HealingDone, DamageTaken, AvoidableDamageTaken(alias of DamageTaken)
    local bucketType = (dmType == DMT.AvoidableDamageTaken) and DMT.DamageTaken or dmType
    local bucket = seg.buckets[bucketType]
    if not bucket then return { combatSources = {} } end
    return { combatSources = SortedSources(bucket, duration) }
end

function C_DamageMeter.GetCombatSessionFromType(sessionType, dmType)
    local seg, duration = SegmentFor(sessionType)
    if not seg then return nil end
    return BuildSessionResult(seg, duration, dmType)
end

function C_DamageMeter.GetCombatSessionFromID(sessionID, dmType)
    local seg, duration = SegmentFor(nil, sessionID)
    if not seg then return nil end
    return BuildSessionResult(seg, duration, dmType)
end

local function FindSourceData(seg, duration, dmType, guid, creatureID)
    if dmType == DMT.EnemyDamageTaken then
        local e = guid and seg.enemyTaken[guid]
        if not e then return nil end
        local spells = {}
        for i = 1, #e.combatSpells do spells[i] = e.combatSpells[i] end
        table.sort(spells, function(a, b) return (a.totalAmount or 0) > (b.totalAmount or 0) end)
        return { sourceGUID = e.sourceGUID, name = e.name, totalAmount = e.totalAmount, combatSpells = spells }
    end
    local bucketType = (dmType == DMT.AvoidableDamageTaken) and DMT.DamageTaken or dmType
    local bucket = seg.buckets[bucketType]
    if not bucket then return nil end
    local src = guid and bucket.byGUID[guid]
    if not src then return nil end
    return src
end

function C_DamageMeter.GetCombatSessionSourceFromType(sessionType, dmType, guid, creatureID)
    local seg, duration = SegmentFor(sessionType)
    if not seg then return nil end
    return FindSourceData(seg, duration, dmType, guid, creatureID)
end

function C_DamageMeter.GetCombatSessionSourceFromID(sessionID, dmType, guid, creatureID)
    local seg, duration = SegmentFor(nil, sessionID)
    if not seg then return nil end
    return FindSourceData(seg, duration, dmType, guid, creatureID)
end
