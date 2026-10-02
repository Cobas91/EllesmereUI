if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EUI_ClassicEnv then setfenv(1, EUI_ClassicEnv) end -- Classic Era port: suite-private API stand-ins (EllesmereUI_ClassicCompat.lua)
-------------------------------------------------------------------------------
-- EUI_UnitFrames_SelfCombatText.lua
-- Self combat text (damage taken, heals received, avoids, combat enter/leave)
-- drawn above the player unit frame in place of Blizzard's WorldFrame-pinned
-- scrolling text.
--
-- Blizzard's CombatText frame is only hidden, never written to: its OnEvent
-- bails while hidden. Event data from C_CombatText.GetCurrentEventInfo is
-- secret, so values only reach C formatters and FontString setters; nothing
-- here compares or does arithmetic on them. Messages scroll on engine
-- animation groups (no OnUpdate). Off, nothing is created or registered.
--
-- Settings: db.profile.player.sct. ReloadFrames calls ns.SCT_Refresh, so
-- login, profile swaps and option changes all route through it. The anchor
-- box is an unlock mode element ("UF_SelfCombatText"): unlock mode applies
-- saved positions and anchor links; Build only places it once (above the
-- player frame when nothing is saved).
-------------------------------------------------------------------------------
local _, ns = ...
local EllesmereUI = _G.EllesmereUI

local POOL_SIZE  = 12
local FADE_FRAC  = 0.3   -- fade over the last 30% of the scroll
local UNLOCK_KEY = "UF_SelfCombatText"
local BOX_W, BOX_H = 200, 30

local DEFAULTS = {
    enabled = false,
    size = 16, critScale = 1.5, rise = 80, duration = 1.9,
    stagger = true,
    anim = "straight",     -- straight | fountain | static
    direction = "up",      -- up | down
    font = "__combat",     -- __combat (CombatTextFont) or a font dropdown key
    outline = "OUTLINE",   -- NONE | OUTLINE | THICKOUTLINE
    shadow = false,
    abbreviate = false,
    damage = true, heal = true, avoid = true, combat = true,
    damageColor = { r = 1,   g = 0.1, b = 0.1 },
    healColor   = { r = 0.1, g = 1,   b = 0.1 },
    avoidColor  = { r = 1,   g = 1,   b = 1   },
    combatColor = { r = 1,   g = 0.1, b = 0.1 },
}

-- type -> isCrit
local DAMAGE = {
    DAMAGE = false, SPELL_DAMAGE = false, DAMAGE_SHIELD = false,
    DAMAGE_CRIT = true, SPELL_DAMAGE_CRIT = true,
}
local HEAL = {
    HEAL = false, PERIODIC_HEAL = false,
    HEAL_CRIT = true, PERIODIC_HEAL_CRIT = true,
}
local AVOID = {
    MISS = true, DODGE = true, PARRY = true, EVADE = true, IMMUNE = true,
    DEFLECT = true, REFLECT = true, RESIST = true, BLOCK = true, ABSORB = true,
    SPELL_MISS = true, SPELL_DODGE = true, SPELL_PARRY = true, SPELL_EVADE = true,
    SPELL_IMMUNE = true, SPELL_DEFLECT = true, SPELL_REFLECT = true,
    SPELL_RESIST = true, SPELL_BLOCK = true, SPELL_ABSORB = true,
}

-- Fountain arc: quarter circle of radius 1, x toward the side, y along the scroll
local ARC = { { 0.134, 0.5 }, { 0.5, 0.866 }, { 1, 1 } }

local anchor, ev
local pool = {}
local nextIdx = 0
local enabled = false
local xDir = 1

local function Get(k)
    local p = ns.db and ns.db.profile.player
    local t = p and p.sct
    local v = t and t[k]
    if v == nil then return DEFAULTS[k] end
    return v
end

local function Enabled()
    return Get("enabled") == true
end

local function FontFile()
    local key = Get("font")
    if key == "__global" then return EllesmereUI.GetFontPath() end
    if key ~= "__combat" and EllesmereUI.ResolveFontName then
        return EllesmereUI.ResolveFontName(key)
    end
    local f = _G.CombatTextFont
    return f and f:GetFont() or STANDARD_TEXT_FONT
end

-------------------------------------------------------------------------------
--  Position (unlock mode owns it once saved)
-------------------------------------------------------------------------------
local function ApplyPos()
    if not anchor then return end
    local pos = Get("pos")
    anchor:ClearAllPoints()
    if pos then
        anchor:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x, pos.y)
        return
    end
    local pf = _G.EllesmereUIUnitFrames_Player
    if pf then
        anchor:SetPoint("BOTTOM", pf, "TOP", 0, 10)
    else
        anchor:SetPoint("BOTTOM", UIParent, "CENTER", 0, -140)
    end
end

local function RegisterMover()
    local MK = EllesmereUI.MakeUnlockElement
    if not (MK and EllesmereUI.RegisterUnlockElements) then return end
    EllesmereUI:RegisterUnlockElements({ MK({
        key = UNLOCK_KEY, label = "Self Combat Text", group = "Unit Frames", order = 190,
        noResize = true,
        isHidden = function() return not Enabled() end,
        getFrame = function() return enabled and anchor or nil end,
        getSize  = function() return BOX_W, BOX_H end,
        savePos = function(_, point, relPoint, x, y)
            if not point then return end
            ns.db.profile.player.sct = ns.db.profile.player.sct or {}
            ns.db.profile.player.sct.pos = { point = point, relPoint = relPoint or point, x = x, y = y }
            if not EllesmereUI._unlockActive then ApplyPos() end
        end,
        loadPos = function()
            local pos = Get("pos")
            if not pos then return nil end
            return { point = pos.point, relPoint = pos.relPoint or pos.point, x = pos.x, y = pos.y }
        end,
        clearPos = function()
            local t = ns.db.profile.player.sct
            if t then t.pos = nil end
            ApplyPos()
        end,
        applyPos = ApplyPos,
    }) })
end

-------------------------------------------------------------------------------
--  Message pool
-------------------------------------------------------------------------------
local function ApplyAnim()
    local rise, dur = Get("rise"), Get("duration")
    local dy = Get("direction") == "down" and -rise or rise
    local mode = Get("anim")
    for i = 1, POOL_SIZE do
        local fs = pool[i]
        fs.mv:SetOffset(0, mode == "straight" and dy or 0)
        fs.mv:SetDuration(dur)
        fs.path:SetDuration(dur)
        if mode ~= "fountain" then
            for j = 1, #ARC do fs.cps[j]:SetOffset(0, 0) end
        end
        fs.fade:SetStartDelay(dur * (1 - FADE_FRAC))
        fs.fade:SetDuration(dur * FADE_FRAC)
    end
end

local function Build()
    anchor = CreateFrame("Frame", nil, UIParent)
    anchor:SetSize(BOX_W, BOX_H)
    anchor:SetFrameStrata("HIGH")
    for i = 1, POOL_SIZE do
        local fs = anchor:CreateFontString(nil, "OVERLAY")
        fs:Hide()
        local ag = fs:CreateAnimationGroup()
        fs.mv = ag:CreateAnimation("Translation")
        fs.path = ag:CreateAnimation("Path")
        fs.path:SetCurveType("SMOOTH")
        fs.cps = {}
        for j = 1, #ARC do
            fs.cps[j] = fs.path:CreateControlPoint(nil, nil, j)
        end
        fs.fade = ag:CreateAnimation("Alpha")
        fs.fade:SetFromAlpha(1)
        fs.fade:SetToAlpha(0)
        ag:SetScript("OnFinished", function() fs:Hide() end)
        fs.ag = ag
        pool[i] = fs
    end
    ev = CreateFrame("Frame")
    ApplyPos()
    RegisterMover()
end

-- Round-robin pool: a burst past POOL_SIZE restarts the oldest message.
local function Emit(fmt, value, colorKey, crit)
    nextIdx = nextIdx % POOL_SIZE + 1
    local fs = pool[nextIdx]
    local c = Get(colorKey)
    local size = Get("size")
    local mode = Get("anim")
    local stagger = (not crit and Get("stagger")) and fastrandom(-20, 20) or 0
    fs.ag:Stop()
    if mode == "fountain" then
        -- Alternate sides, like Blizzard's fountain
        xDir = -xDir
        local rise = Get("rise")
        local sy = Get("direction") == "down" and -rise or rise
        for j = 1, #ARC do
            fs.cps[j]:SetOffset(xDir * ARC[j][1] * rise, ARC[j][2] * sy)
        end
    end
    fs:ClearAllPoints()
    fs:SetPoint("BOTTOM", anchor, "BOTTOM", stagger, 0)
    local outline = Get("outline")
    fs:SetFont(FontFile(), crit and size * Get("critScale") or size, outline == "NONE" and "" or outline)
    if Get("shadow") then
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowOffset(0, 0)
    end
    fs:SetTextColor(c.r, c.g, c.b)
    fs:SetFormattedText(fmt, value)
    fs:SetAlpha(1)
    fs:Show()
    fs.ag:Play()
end

-- Both formatters are C-side and accept secret numbers
local function FormatAmount(n)
    if Get("abbreviate") then return AbbreviateNumbers(n) end
    return BreakUpLargeNumbers(n)
end

local function SetUnit()
    C_CombatText.SetActiveUnit(UnitHasVehicleUI("player") and "vehicle" or "player")
end

local function OnEvent(_, event, arg1, arg2)
    if event == "COMBAT_TEXT_UPDATE" then
        -- data = amount (damage) or source name (heals); arg3 = heal amount
        local crit = DAMAGE[arg1]
        if crit ~= nil then
            if not Get("damage") then return end
            local data = C_CombatText.GetCurrentEventInfo()
            Emit("-%s", FormatAmount(data), "damageColor", crit)
            return
        end
        crit = HEAL[arg1]
        if crit ~= nil then
            if not Get("heal") then return end
            local _, arg3 = C_CombatText.GetCurrentEventInfo()
            Emit("+%s", FormatAmount(arg3), "healColor", crit)
            return
        end
        if AVOID[arg1] and Get("avoid") then
            local label = _G["COMBAT_TEXT_" .. arg1:gsub("^SPELL_", "")]
            if label then Emit("%s", label, "avoidColor", false) end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        Emit("%s", _G.ENTERING_COMBAT or "+Combat", "combatColor", false)
    elseif event == "PLAYER_REGEN_ENABLED" then
        Emit("%s", _G.LEAVING_COMBAT or "-Combat", "combatColor", false)
    elseif event == "UNIT_ENTERED_VEHICLE" then
        C_CombatText.SetActiveUnit(arg2 and "vehicle" or "player")
    elseif event == "UNIT_EXITING_VEHICLE" then
        C_CombatText.SetActiveUnit("player")
    elseif event == "ADDON_LOADED" then
        if arg1 == "Blizzard_CombatText" and _G.CombatText then
            _G.CombatText:Hide()
            ev:UnregisterEvent("ADDON_LOADED")
        end
    end
end

-- Registers only the events the enabled categories need.
local function UpdateEvents()
    if Get("damage") or Get("heal") or Get("avoid") then
        EUI_SafeRegisterEvent(ev, "COMBAT_TEXT_UPDATE")
        EUI_SafeRegisterUnitEvent(ev, "UNIT_ENTERED_VEHICLE", "player")
        EUI_SafeRegisterUnitEvent(ev, "UNIT_EXITING_VEHICLE", "player")
    else
        EUI_SafeUnregisterEvent(ev, "COMBAT_TEXT_UPDATE")
        EUI_SafeUnregisterEvent(ev, "UNIT_ENTERED_VEHICLE")
        EUI_SafeUnregisterEvent(ev, "UNIT_EXITING_VEHICLE")
    end
    if Get("combat") then
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    else
        ev:UnregisterEvent("PLAYER_REGEN_DISABLED")
        ev:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end
end

local function Refresh()
    local want = Enabled()
    if want == enabled then
        if want then
            ApplyAnim()
            UpdateEvents()
        end
        return
    end
    enabled = want
    if want then
        if not anchor then Build() end
        ApplyAnim()
        anchor:Show()
        ev:SetScript("OnEvent", OnEvent)
        UpdateEvents()
        SetUnit()
        if _G.CombatText then
            _G.CombatText:Hide()
        else
            ev:RegisterEvent("ADDON_LOADED")
        end
    else
        ev:UnregisterAllEvents()
        anchor:Hide()
        if _G.CombatText then _G.CombatText:Show() end
    end
end

ns.SCT_Refresh = Refresh
ns.SCT_Get = Get
function ns.SCT_Set(k, v)
    local p = ns.db.profile.player
    if not p.sct then p.sct = {} end
    p.sct[k] = v
    Refresh()
end
