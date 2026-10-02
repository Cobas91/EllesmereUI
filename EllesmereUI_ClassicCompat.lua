if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUI_ClassicCompat.lua
--
--  WoW Classic Era (1.15.x, Interface ~11509) ported build. Loads immediately
--  after EllesmereUI_ClientGate.lua / before EllesmereUI_Lite.lua so every
--  other file in the suite (all 19 child addons included) sees a safe API
--  surface no matter which retail-only system it touches.
--
--  Classic Era shares most of the modern "C_" namespace split with retail
--  (Blizzard backported C_Timer, C_AddOns, C_Spell, C_Item, C_Container,
--  C_UnitAuras, C_NamePlate, C_SpellBook, C_ClassColor, C_CVar, C_QuestLog,
--  C_Reputation, C_PvP, C_ActionBar, C_PetBattles and more years ago), but it
--  has NO specializations, NO modern talent trees, NO Mythic+, NO Edit Mode,
--  NO Cooldown Manager viewer, NO Garrisons/Artifacts/Azerite/Toy Box/
--  Transmog/Warband Bank/Delves/Housing/Assisted-Combat/Great Vault.
--
--  Strategy (two layers, both additive/non-destructive):
--   1. Any namespace below that does NOT exist on this client is created as
--      a stub table. Any key read from it returns a tiny function that
--      yields a type-appropriate neutral value (false for Is/Has/Can/
--      Should, 0 for Num/Count/Size, "" for Name/Label/Text, otherwise nil)
--      instead of erroring "attempt to call a nil value".
--   2. Any namespace that DOES already exist is left completely alone except
--      that unknown keys fall back the same way, in case Classic Era's real
--      table is missing one specific retail-only method. Existing, working
--      methods are never touched (the fallback only fires on a MISSING key).
--
--  This cannot fabricate real data (there is no spec, no keystone, no
--  Mythic+ score to report), so callers still see "nothing equipped/active/
--  known" -- which is the correct, honest answer on this client. It only
--  prevents a missing retail API from taking down an entire addon file.
-------------------------------------------------------------------------------

local iface = select(4, GetBuildInfo())
EllesmereUI_IS_CLASSIC_ERA = EUI_CLIENT_CLASSIC_ERA == true
    or (type(iface) == "number" and iface < 20000 and iface ~= 0 and not EUI_CLIENT_FOREVER)

-------------------------------------------------------------------------------
--  Event registration guards. On this client RegisterEvent / RegisterUnitEvent
--  / UnregisterEvent with an event name the client does not know is a Lua
--  ERROR (the installed Classic Era Details and Baganator gate theirs on
--  C_EventUtils.IsEventValid, AutoBarClassic pcalls them), which would abort
--  the rest of the calling file. The suite registers many retail-only events
--  (Mythic+, Edit Mode, housing, Warband bank, Cooldown Manager, ...), so
--  every registration of an event that is not a plain vanilla one goes
--  through these instead. Callers stay frames/objects of our own: nothing
--  here touches a shared frame metatable (that would taint Blizzard's own
--  RegisterEvent calls).
-------------------------------------------------------------------------------
local IsEventValidNative = C_EventUtils and C_EventUtils.IsEventValid

function EUI_IsEventValid(event)
    if type(event) ~= "string" then return false end
    if IsEventValidNative then return IsEventValidNative(event) and true or false end
    return true
end

local function GuardedCall(method, obj, event, ...)
    if not obj then return end
    if IsEventValidNative then
        if not EUI_IsEventValid(event) then return end
        return obj[method](obj, event, ...)
    end
    local ok, r = pcall(obj[method], obj, event, ...)
    if ok then return r end
end

function EUI_SafeRegisterEvent(obj, event, ...)     return GuardedCall("RegisterEvent", obj, event, ...) end
function EUI_SafeRegisterUnitEvent(obj, event, ...) return GuardedCall("RegisterUnitEvent", obj, event, ...) end
function EUI_SafeUnregisterEvent(obj, event, ...)   return GuardedCall("UnregisterEvent", obj, event, ...) end

-- Everything below is Classic Era only. The event guards above are the one
-- piece every client needs: the suite routes its non-vanilla RegisterEvent
-- calls through them on every client (a plain pass-through where the client
-- knows the event). Retail and WoW Forever stop here, so EUI_ClassicEnv stays
-- nil and the per-file setfenv line is a no-op there.
if not EllesmereUI_IS_CLASSIC_ERA then return end


local rawset, setmetatable, getmetatable, pcall, type, tostring =
      rawset, setmetatable, getmetatable, pcall, type, tostring

-------------------------------------------------------------------------------
--  PRIVATE environment. Nothing below writes a Blizzard global or touches a
--  shared table: Blizzard's own code and every other addon keep seeing the
--  real client API (in-game reports: a stub method on the real C_QuestLog
--  made Questie call a fake GetAllCompletedQuestIDs; a globally replaced
--  specialization family broke Blizzard's Classic talent frame, which reads
--  its talent tabs through that API). Every EllesmereUI file runs in
--  EUI_ClassicEnv (line 2 of each file): reads try STUBS first, then _G;
--  writes of new globals still land in _G (SavedVariables, global frames
--  and functions behave as before). STUBS holds only what this client lacks
--  or what must answer differently for the suite.
-------------------------------------------------------------------------------
local STUBS = setmetatable({}, { __index = _G })
EUI_ClassicStubs = STUBS
EUI_ClassicEnv = setmetatable({}, { __index = STUBS, __newindex = _G })
-- Enum / AnchorUtil: the suite adds its own members on an overlay, never on
-- Blizzard's tables.
STUBS.Enum = setmetatable({}, { __index = _G.Enum or {} })
STUBS.AnchorUtil = setmetatable({}, { __index = _G.AnchorUtil or {} })

-- The engine resolves the mixin of an object a C API hands back (C_Map's
-- Vector2D, ItemLocation, Color ...) by name with a RAW lookup in the calling
-- function's environment, which skips the __index chain above (in-game:
-- "unable to find mixin or metatable (Vector2DMixin)"). Mirror every
-- *Mixin / *Metatable global into the environment itself, now and whenever a
-- load-on-demand Blizzard addon defines more.
do
    local env = EUI_ClassicEnv
    local function MirrorMixins()
        for k, v in pairs(_G) do
            if type(k) == "string" and rawget(env, k) == nil
                and (k:sub(-5) == "Mixin" or k:sub(-9) == "Metatable") then
                rawset(env, k, v)
            end
        end
    end
    MirrorMixins()
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", MirrorMixins)
end
setfenv(1, EUI_ClassicEnv)

local function NeutralValueFor(key)
    local k = tostring(key)
    if k:match("^Is") or k:match("^Has") or k:match("^Can") or k:match("^Should") then
        return false
    elseif k:match("Num") or k:match("Count") or k:match("Size") or k:match("Index") then
        return 0
    elseif k:match("Name") or k:match("Label") or k:match("Text") or k:match("String") then
        return ""
    end
    return nil
end

local function MakeStubFunction(key)
    local value = NeutralValueFor(key)
    return function() return value end
end

-- Layer 1: namespaces entirely absent on Classic Era.
local MISSING_NAMESPACES = {
    "C_AssistedCombat", "C_Bank", "C_BattleNet", "C_CampaignInfo",
    "C_ChallengeMode", "C_ChatBubbles", "C_ClassTalents", "C_Club",
    "C_ClubFinder", "C_CooldownViewer", "C_CraftingOrders", "C_CurveUtil",
    "C_DamageMeter", "C_DelvesUI", "C_EditMode", "C_Garrison", "C_Heirloom",
    "C_HouseEditor", "C_Housing", "C_ItemUpgrade", "C_LFGList", "C_LFGInfo",
    "C_MajorFactions", "C_MythicPlus", "C_NamePlateManager", "C_ReloadAll",
    "C_Scenario", "C_ScenarioInfo", "C_SeasonInfo", "C_Secrets", "C_SetEnabled",
    "C_SocialUI", "C_SpecializationInfo", "C_StringUtil", "C_SuperTrack",
    "C_SwingTimer", "C_ToyBox", "C_ToyBoxInfo", "C_Traits",
    "C_TransmogOutfitInfo", "C_TransmogCollection", "C_Transmog",
    "C_UIFileAsset", "C_UIWidgetManager", "C_VoiceChat", "C_WeeklyRewards",
    "C_AddOnProfiler", "C_AzeriteEssence", "C_AzeriteItem", "C_ArtifactUI",
    "C_PlayerInteractionManager", "C_Soulbinds", "C_Covenants",
    "C_PerksProgram", "C_SpellActivationOverlay",
    -- Not in the porting guide's list, but read unguarded by the suite's
    -- controller support (EllesmereUI_UICore.lua) and the damage meters.
    "C_GamePad", "C_InputInterfaceStyle", "C_DeathRecap",
}

-- The 1.15.x client ships several of these natively after all (the installed
-- Classic Era ElvUI reads C_BattleNet, C_Club, C_LFGList, C_VoiceChat,
-- C_CurveUtil, C_StringUtil, C_SpecializationInfo ... unguarded). A missing
-- namespace gets a private stub table; a present one a private overlay that
-- reads through to the real table and only answers missing methods with a
-- neutral stub. The real tables are never modified.
local function NeutralTable(real)
    return setmetatable({}, {
        __index = function(t, k)
            local v = real and real[k]
            if v == nil then v = MakeStubFunction(k) end
            rawset(t, k, v) -- memoize: next lookup skips the metamethod
            return v
        end,
    })
end

local EXISTING_NAMESPACES_TO_HARDEN = {
    "C_ActionBar", "C_AddOns", "C_ChatInfo", "C_ClassColor", "C_Container",
    "C_CurrencyInfo", "C_CVar", "C_EquipmentSet", "C_FriendList",
    "C_GossipInfo", "C_GuildInfo", "C_Item", "C_Map", "C_MerchantFrame",
    "C_MountJournal", "C_NamePlate", "C_PartyInfo", "C_PetBattles",
    "C_PetInfo", "C_PetJournal", "C_PlayerInfo", "C_PvP", "C_QuestLog",
    "C_Reputation", "C_Spell", "C_SpellBook", "C_Texture", "C_Timer",
    "C_TooltipInfo", "C_TradeSkillUI", "C_UnitAuras", "C_PaperDollInfo",
}

for _, list in ipairs({ MISSING_NAMESPACES, EXISTING_NAMESPACES_TO_HARDEN }) do
    for _, name in ipairs(list) do
        local real = rawget(_G, name)
        if type(real) == "table" or real == nil then
            STUBS[name] = NeutralTable(real)
        end
    end
end

-------------------------------------------------------------------------------
--  Flat-global polyfills (pre-namespace-split API some modules may still
--  call directly; cheap to provide even though most of these already exist
--  natively on Classic Era).
-------------------------------------------------------------------------------
-- Classic Era 1.15 ships part of the specialization API as stubs that THROW
-- "API unsupported in this version of World of Warcraft" (in-game report:
-- GetSpecializationRole), while GetSpecialization itself answers 1 (the
-- talent group). Probe the family once; when the info call is unsupported the
-- whole family is answered as "no specialization", so callers take their
-- existing no-spec paths instead of erroring one call deeper.
do
    local function Unsupported(fn, ...)
        if type(fn) ~= "function" then return false end
        local ok, err = pcall(fn, ...)
        return not ok and type(err) == "string" and err:find("unsupported", 1, true) ~= nil
    end
    local realCSI = rawget(_G, "C_SpecializationInfo")
    local CSI = STUBS.C_SpecializationInfo -- the suite's private overlay
    local infoFn = (type(realCSI) == "table" and realCSI.GetSpecializationInfo) or rawget(_G, "GetSpecializationInfo")
    if Unsupported(infoFn, 1) or Unsupported(rawget(_G, "GetSpecializationRole"), 1) then
        local none = function() return nil end
        local zero = function() return 0 end
        STUBS.GetSpecialization, STUBS.GetSpecializationInfo, STUBS.GetSpecializationRole = none, none, none
        STUBS.GetSpecializationInfoByID, STUBS.GetSpecializationRoleByID = none, none
        STUBS.GetSpecializationInfoForClassID = none
        STUBS.GetNumSpecializations, STUBS.GetNumSpecializationsForClassID = zero, zero
        if type(CSI) == "table" then
            for _, k in ipairs({ "GetSpecialization", "GetSpecializationInfo", "GetSpecializationRole",
                "GetSpecializationInfoByID", "GetSpecializationInfoForClassID", "GetActiveSpecGroup" }) do
                rawset(CSI, k, none)
            end
            for _, k in ipairs({ "GetNumSpecializationsForClassID", "GetNumSpecializations" }) do
                rawset(CSI, k, zero)
            end
        end
    end
end

if type(GetSpecialization) ~= "function" then
    function STUBS.GetSpecialization() return nil end
end
if type(GetSpecializationInfo) ~= "function" then
    function STUBS.GetSpecializationInfo() return nil end
end
if type(GetNumSpecializations) ~= "function" then
    function STUBS.GetNumSpecializations() return 0 end
end
if type(GetSpecializationRole) ~= "function" then
    function STUBS.GetSpecializationRole() return nil end
end
if type(GetSpecializationInfoByID) ~= "function" then
    function STUBS.GetSpecializationInfoByID() return nil end
end

-- Flat retail globals the suite calls unguarded on paths that run on every
-- client (controller cursor checks on bag/menu open, world marker pips, the
-- quick-keybind tooltip, the toy filter snapshot). Only filled when absent.
if type(IsUsingGamepad) ~= "function" then
    function STUBS.IsUsingGamepad() return false end
end
if type(CanAutoSetGamePadCursorControl) ~= "function" then
    function STUBS.CanAutoSetGamePadCursorControl() return false end
end
if type(SetGamePadCursorControl) ~= "function" then
    function STUBS.SetGamePadCursorControl() end
end
if type(IsRaidMarkerActive) ~= "function" then
    -- No world markers on this client: none is ever active.
    function STUBS.IsRaidMarkerActive() return false end
end
if type(GetNumExpansions) ~= "function" then
    function STUBS.GetNumExpansions() return 0 end
end
if type(GetBindingKeyForAction) ~= "function" then
    function STUBS.GetBindingKeyForAction(action) return GetBindingKey and GetBindingKey(action) end
end

-- Secret-value predicates (~580 call sites across the suite, many unguarded).
-- 1.15.x ships these natively; on a client without them nothing is ever
-- secret, so the honest answers are "not secret" / "accessible".
if type(issecretvalue) ~= "function" then
    function STUBS.issecretvalue() return false end
end
if type(issecrettable) ~= "function" then
    function STUBS.issecrettable() return false end
end
if type(canaccessvalue) ~= "function" then
    function STUBS.canaccessvalue() return true end
end
if type(canaccesstable) ~= "function" then
    function STUBS.canaccesstable() return true end
end

-------------------------------------------------------------------------------
--  Real (not neutral-stub) polyfills for the "secret value" visualization
--  API introduced alongside Retail's combat-log secrecy system. Classic Era
--  has NO secret values at all -- every unit's health/power is a directly
--  readable plain number -- so these can be fully, correctly reimplemented
--  rather than just made crash-safe. Several callers across UnitFrames/
--  RaidFrames/Nameplates chain `:SetType()`/`:AddPoint()` onto the curve and
--  then immediately pass it into UnitHealthPercent/UnitPowerPercent, so a
--  bare neutral-value stub (returning nil) would crash on the very next
--  line; this gives them a real, working object instead.
--
--  NOTE for module ports: several call sites in this suite ALREADY carry a
--  "clean number" twin of this exact math (built for the options-preview
--  path, which never had secret values to begin with -- e.g.
--  ns.UF_ResolveDynamicColor / ns.UF_ResolveClassicColor in
--  EllesmereUIUnitFrames.lua). Prefer routing the LIVE path to that existing
--  clean twin over relying on this polyfill: it's simpler, already
--  hand-verified against the same gradients, and avoids the curve machinery
--  entirely. This polyfill exists as the correctness net for call sites
--  where no such twin exists.
-------------------------------------------------------------------------------
if not Enum.LuaCurveType then
    Enum.LuaCurveType = { Linear = 0, Step = 1, Smooth = 2, EaseIn = 3, EaseOut = 4 }
end

local function LerpColor(a, b, f)
    local ar, ag, ab, aa = a.r or a[1], a.g or a[2], a.b or a[3], a.a or a[4] or 1
    local br, bg, bb, ba = b.r or b[1], b.g or b[2], b.b or b[3], b.a or b[4] or 1
    return CreateColor(ar + (br - ar) * f, ag + (bg - ag) * f, ab + (bb - ab) * f, aa + (ba - aa) * f)
end

local function NewLuaCurve()
    local points, isStep = {}, false
    local curve = {}
    function curve:SetType(t)
        isStep = (t == Enum.LuaCurveType.Step)
    end
    function curve:AddPoint(x, value)
        points[#points + 1] = { x = x, value = value }
        table.sort(points, function(a, b) return a.x < b.x end)
    end
    function curve:ClearPoints()
        for i = #points, 1, -1 do points[i] = nil end
    end
    -- Internal evaluation entry point used by our UnitHealthPercent /
    -- UnitPowerPercent polyfills below (not part of the real retail API
    -- surface, which never exposes curve evaluation to Lua directly).
    function curve:_EUIEvaluate(t)
        local n = #points
        if n == 0 then return 0 end
        if t <= points[1].x then return points[1].value end
        if t >= points[n].x then return points[n].value end
        for i = 1, n - 1 do
            local a, b = points[i], points[i + 1]
            if t >= a.x and t <= b.x then
                if isStep then return a.value end
                local span = b.x - a.x
                local f = (span > 0) and ((t - a.x) / span) or 0
                if type(a.value) == "table" or (type(a.value) == "userdata") then
                    return LerpColor(a.value, b.value, f)
                end
                return a.value + (b.value - a.value) * f
            end
        end
        return points[n].value
    end
    return curve
end

-- Only fill in what the client does NOT provide natively. Classic Era 1.15.x
-- ships a real C_CurveUtil (the installed Classic Era ElvUI reads
-- C_CurveUtil.CreateCurve unguarded); overwriting it would hand our Lua-table
-- curve to a NATIVE UnitHealthPercent, which only accepts its own curve
-- userdata. rawget so the Layer 2 fallback metamethod can't fake presence.
local function NativeFn(nsName, key)
    local real = rawget(_G, nsName)
    return type(real) == "table" and type(real[key]) == "function"
end
if type(C_CurveUtil) == "table" and not NativeFn("C_CurveUtil", "CreateColorCurve") then
    rawset(C_CurveUtil, "CreateCurve", NewLuaCurve)
    rawset(C_CurveUtil, "CreateColorCurve", NewLuaCurve)
end
if type(C_CurveUtil) == "table" and not NativeFn("C_CurveUtil", "EvaluateColorValueFromBoolean") then
    rawset(C_CurveUtil, "EvaluateColorValueFromBoolean", function(cond, whenFalse, whenTrue)
        if cond then return whenTrue end
        return whenFalse
    end)
end

-- Evaluates either our Lua curve or (mixed case: native curves present but no
-- native UnitHealthPercent) a native curve object through its own :Evaluate.
local function EvalCurve(curve, pct)
    if curve._EUIEvaluate then return curve:_EUIEvaluate(pct) end
    if curve.Evaluate then return curve:Evaluate(pct) end
    return pct
end

if type(UnitHealthPercent) ~= "function" then
    function STUBS.UnitHealthPercent(unit, deadIsZero, curve)
        if not unit or not UnitExists(unit) then return 0 end
        local cur, max = UnitHealth(unit), UnitHealthMax(unit)
        local pct = (max and max > 0) and (cur / max) or 0
        if deadIsZero and UnitIsDeadOrGhost(unit) then pct = 0 end
        if curve then return EvalCurve(curve, pct) end
        return pct
    end
end
if type(UnitPowerPercent) ~= "function" then
    -- Retail signature is (unit, powerType, unmodified, curve); every caller
    -- in the suite passes all four. A table in the third slot is accepted as
    -- the curve too, for a three-argument call.
    function STUBS.UnitPowerPercent(unit, powerType, unmodified, curve)
        if curve == nil and type(unmodified) == "table" then curve = unmodified end
        if not unit or not UnitExists(unit) then return 0 end
        local cur = powerType and UnitPower(unit, powerType) or UnitPower(unit)
        local max = powerType and UnitPowerMax(unit, powerType) or UnitPowerMax(unit)
        local pct = (max and max > 0) and (cur / max) or 0
        if curve then return EvalCurve(curve, pct) end
        return pct
    end
end

-- CurveConstants: retail's prebuilt 0..1 -> 0..100 curves, a bare global
-- (not a C_* namespace) read unguarded by RaidFrames, UnitFrames and
-- ResourceBars. Built from whichever CreateCurve is live (native or ours
-- above), so the curve always matches the UnitHealthPercent/UnitPowerPercent
-- that will receive it.
STUBS.CurveConstants = setmetatable({}, { __index = rawget(_G, "CurveConstants") or {} })
if C_CurveUtil and C_CurveUtil.CreateCurve then
    local function Linear(y0, y1)
        local c = C_CurveUtil.CreateCurve()
        c:SetType(Enum.LuaCurveType.Linear)
        c:AddPoint(0, y0)
        c:AddPoint(1, y1)
        return c
    end
    if not CurveConstants.ScaleTo100 then CurveConstants.ScaleTo100 = Linear(0, 100) end
    if not CurveConstants.ReverseTo100 then CurveConstants.ReverseTo100 = Linear(100, 0) end
end

-------------------------------------------------------------------------------
--  Real polyfills for the C_StringUtil formatting helpers used for bar/text
--  display. A neutral nil-returning stub would crash the common
--  `string.format("%s", C_StringUtil.TruncateWhenZero(n))` pattern (format
--  rejects a nil %s argument), so these return actual strings.
-------------------------------------------------------------------------------
if type(C_StringUtil) == "table" and not NativeFn("C_StringUtil", "TruncateWhenZero") then
    rawset(C_StringUtil, "TruncateWhenZero", function(n)
        n = tonumber(n) or 0
        if n == 0 then return "" end
        return tostring(math.floor(n + 0.5))
    end)
end
if type(C_StringUtil) == "table" and not NativeFn("C_StringUtil", "CreateNumericRuleFormatter") then
    rawset(C_StringUtil, "CreateNumericRuleFormatter", function()
        return {
            Format = function(_, n)
                n = tonumber(n) or 0
                return tostring(math.floor(n + 0.5))
            end,
        }
    end)
end
