if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EUI_ClassicEnv then setfenv(1, EUI_ClassicEnv) end -- Classic Era port: suite-private API stand-ins (EllesmereUI_ClassicCompat.lua)
-------------------------------------------------------------------------------
--  EllesmereUIActionBars.lua  Custom Action Bars
--  Own secure action bar frames AND buttons (EABButton/ActionBarButtonTemplate),
--  eliminating the taint surface from reusing Blizzard's protected buttons.
--  Stance/Pet bars still reuse Blizzard buttons (own secure handling).
--  Keybinds: SetOverrideBindingClick for all bars. Paging: RegisterStateDriver
--  + _childupdate-eab-page with explicit action attrs.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
if not (EllesmereUI and EllesmereUI._ModuleNS and EllesmereUI.NewCombatQueue) then EUI_CLIENT_BLOCKED = true; return end -- stale-parent guard: a partially updated install (old parent, new child) goes dormant via the line-1 failsafe instead of erroring
EllesmereUI._ModuleNS[ADDON_NAME] = ns  -- LOD options files read this module ns via the registry
local EAB = EllesmereUI.Lite.NewAddon(ADDON_NAME)
ns.EAB = EAB

local PP = EllesmereUI.PP

-- CPU-attribution shell pool: the engine bills a handler's whole call tree to the addon
-- whose context CREATED the frame it entered through, so frames born in build/enable
-- code bill the PARENT forever (probe-verified, see EllesmereUI_Ticker.lua). Shells
-- born in this main chunk stamp to ActionBars; runtime code should call ns.TakeShell()
-- instead of CreateFrame for persistent hosts carrying events/scripts. No release, so
-- transient throwaway frames keep using CreateFrame.
do
    local pool = {}
    local n = 40
    for i = 1, n do pool[i] = CreateFrame("Frame") end
    ns.TakeShell = function()
        if n > 0 then
            local f = pool[n]
            pool[n] = nil
            n = n - 1
            return f
        end
        -- Pool exhausted (not expected): frame just bills the parent; bump n if it happens.
        return CreateFrame("Frame")
    end
end

-- "Run once after combat" for every combat-gated deferral in this file. The shell is
-- taken in the main chunk, so drained work bills ActionBars. Keys are per purpose, and
-- sites that defer the same work share a key (e.g. "UpdateKeybinds").
ns.CombatQueue = EllesmereUI.NewCombatQueue(ns.TakeShell())

-- "Hide Count at 0" (Icon Effects): hide a zero charge/stack count via the
-- count fontstring's ALPHA, never its text -- text is co-owned: Blizzard's
-- mixin keeps SPELL_UPDATE_CHARGES registered and rewrites Count with the raw
-- value every charge event, but nothing engine-side touches alpha (same as
-- the CDM twin). Memoized so only real changes write; fails open on SECRET
-- values (combat) so the count shows rather than risk a tainted compare. Off
-- = one profile read + memo compare, zero machinery. (On ns: main chunk is at
-- the 200-local cap.)
ns._EABZeroCountAlpha = function(fd, fs, v, action)
    local pdb = EAB.db and EAB.db.profile
    if not (pdb and pdb.hideZeroCount) then
        -- OFF fast path: reads + memo compare only, except healing a leftover hidden
        -- stamp so a button can't stay stuck invisible after a toggle/profile switch.
        -- Profile read IS the gate: a cached flag would go stale across profiles.
        if fd._zeroCountAlpha == 0 then
            fd._zeroCountAlpha = 1
            fs:SetAlpha(1)
        end
        return
    end
    local a = 1
    if action then
        -- Charge spells route EXCLUSIVELY through the count: SetAlpha clamps
        -- to [0,1], so alpha := currentCharges hides at exactly 0 and shows
        -- at 1+ with no comparison needed. Never infer zero charges from an active
        -- cooldown record -- charges banked while the main cooldown runs (e.g. Feint)
        -- would hide a real count. SetAlpha accepts secret numbers
        -- (AllowedWhenTainted), so the same write runs in and out of instanced combat;
        -- a secret count writes through with the memo dirtied, never stored/compared.
        local ci = C_ActionBar.GetActionCharges and C_ActionBar.GetActionCharges(action)
        local mc = ci and ci.maxCharges
        if mc ~= nil and not (issecretvalue and issecretvalue(mc)) and mc > 1 then
            local cc = ci.currentCharges
            -- issecretvalue FIRST, and type() rather than == nil for the missing
            -- case. The count is secret whenever cooldowns are restricted, and
            -- comparing a secret to nil is the operation our own secret rules
            -- forbid -- so ordering the nil "belt" ahead of the guard made the
            -- belt the hazard, and a throw strands the count HIDDEN rather than
            -- protecting it. Same defect and same fix as the CDM counterpart in
            -- EllesmereUICdmHooks (EvalZeroChargeTextFrame).
            if issecretvalue and issecretvalue(cc) then
                fd._zeroCountAlpha = nil
                fs:SetAlpha(cc)
            elseif type(cc) ~= "number" then
                if fd._zeroCountAlpha ~= 1 then
                    fd._zeroCountAlpha = 1
                    fs:SetAlpha(1)
                end
            else
                a = cc > 1 and 1 or cc
                if fd._zeroCountAlpha ~= a then
                    fd._zeroCountAlpha = a
                    fs:SetAlpha(a)
                end
            end
            return
        end
        -- Non-charge: mixin shows GetActionCount for consumables/stackables
        -- (including 0); display string is only the cheap first check.
        -- issecretvalue FIRST: v is GetActionDisplayCount's return, which the
        -- API documents as secret whenever cooldowns are restricted, and
        -- comparing a secret to nil is the operation our own rules forbid --
        -- the same ordering defect this function's charge branch above already
        -- carries a comment about. The nil case needs no test of its own:
        -- nil == 0 is simply false.
        if not (issecretvalue and issecretvalue(v))
           and (v == 0 or v == "0") then
            a = 0
        elseif (IsConsumableAction and IsConsumableAction(action))
            or (IsStackableAction and IsStackableAction(action)) then
            local c = GetActionCount and GetActionCount(action)
            if c ~= nil and not (issecretvalue and issecretvalue(c)) and c == 0 then
                a = 0
            end
        end
    end
    if fd._zeroCountAlpha ~= a then
        fd._zeroCountAlpha = a
        fs:SetAlpha(a)
    end
end

-- Cold-path helper table for module-level behavior that benefits from a
-- shared dispatch surface without adding more direct top-level helpers.
local EAB_VTABLE = {
    ExtraBars = {},
    CooldownFonts = {},
    Hover = {},
    MainBarPageSync = {},
}
ns.EAB_VTABLE = EAB_VTABLE

EAB.VisibilityCompat = EAB.VisibilityCompat or {}


-------------------------------------------------------------------------------
--  Upvalues
-------------------------------------------------------------------------------
local _G = _G
local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
local abs, ceil, floor, min, max = math.abs, math.ceil, math.floor, math.min, math.max
local wipe, tinsert = wipe, table.insert
local InCombatLockdown = InCombatLockdown
local hooksecurefunc = hooksecurefunc
local C_Timer_After = C_Timer.After

-- External weak-keyed lookup for per-frame state (avoids writing custom
-- properties onto Blizzard-owned frame tables, which causes taint).
-- Stored on ns to avoid consuming file-scope local slots (200 cap).
ns._eabFD = setmetatable({}, { __mode = "k" })
function ns.EFD(frame)
    local d = ns._eabFD[frame]
    if not d then d = {}; ns._eabFD[frame] = d end
    return d
end

-- Local alias for hot-path EFD access
local EFD = ns.EFD

-- Empty-slot parks live in EFD(btn).parkA0, so no decision reads a button's
-- alpha (another addon may write a secret one there). nil = our last write was
-- alpha 1, or there was none (default 1). 1 = we wrote alpha 0. 2 = we wrote
-- alpha 0 on a button the secure un-park code can reveal; that code sets alpha 1
-- on every hidden->shown edge, so the button is parked only while hidden. Our
-- own Show() keeps alpha, so each Lua Show site turns a surfaced 2 into 1.
function ns._eabParked(btn)
    local d = ns._eabFD[btn]
    local p = d and d.parkA0
    if p == 2 then return not btn:IsShown() end
    return p == 1
end

-- Record an alpha-0 park on btn, right after the write. afterOwnHide: our
-- out-of-combat Hide() came after the 0, and the secure OnHide re-check can
-- re-show the button at alpha 1 inside that Hide; 2 covers both outcomes.
function ns._eabMarkParked(btn, info, afterOwnHide)
    local revealable = not info.isStance and not info.isPetBar
    EFD(btn).parkA0 = (revealable and (afterOwnHide or not btn:IsShown())) and 2 or 1
end

-- The style Action Bars render: "eui" | "blizzard" | "classic". A LIVE
-- profile read, no latch: the Style page reloads the UI on every change, so
-- build-time gating is safe. "eui" without a profile; both flags set resolves
-- classic. Stock-mode sites ask `~= "eui"`, kit sites ask `== "classic"`.
function ns.AB_Style()
    local p = EAB.db and EAB.db.profile
    if not p then return "eui" end
    return (p.useClassicStyle and "classic") or (p.useBlizzardStyle and "blizzard") or "eui"
end

-- The WoW Forever variant of Blizzard Style (the Forever client only): the
-- bars render Blizzard Style (AB_Style() stays "blizzard", every stock site
-- is unchanged) and the profile's sibling useForeverStyle flag, set together
-- with the Blizzard flag, adds the Forever-only pieces. A LIVE read like
-- AB_Style; false on every other client.
function ns.AB_Forever()
    if EllesmereUI.IS_FOREVER ~= true then return false end
    local p = EAB.db and EAB.db.profile
    if not (p and p.useForeverStyle == true) then return false end
    return ns.AB_Style() == "blizzard"
end

-- WoW Forever's frame and dividers behind a bar (Show Bar Background), under
-- the variant only: the bar's own foreverBarBg. nil reads the bar's default:
-- Action Bar 1 follows the profile-wide foreverHideBarBg (shown unless it is
-- set), every other bar is off.
function ns.AB_ForeverBg(key)
    if not ns.AB_Forever() then return false end
    local p = EAB.db.profile
    local s = p.bars and p.bars[key]
    local v = s and s.foreverBarBg
    if v == nil then v = key == "MainBar" and p.foreverHideBarBg ~= true end
    return v and true or false
end

-- SetAtlas for a stock-look texture: EllesmereUI.StockAtlas (retail art
-- where the Forever client swaps the name), native under the WoW Forever
-- look. Plain SetAtlas on retail.
function ns.AB_StockAtlas(tex, name, ...)
    if ns.AB_Forever() then return tex:SetAtlas(name, ...) end
    return EllesmereUI.StockAtlas(tex, name, ...)
end

-- The button shape the bar LAYOUT sizes for. Stock styles draw no custom
-- shape (ApplyShapesForBar and the options preview skip it), so their
-- buttons take neither the shape expansion nor the Cropped squash, whatever
-- the EllesmereUI-style setting holds. Icon Size itself applies in every
-- style (stock buttons scale their native art to it).
function ns.AB_LayoutShape(s)
    if ns.AB_Style() ~= "eui" then return "none" end
    return (s and s.buttonShape) or "none"
end
local RegisterStateDriver = RegisterStateDriver
local RegisterAttributeDriver = RegisterAttributeDriver
local GetBindingKey = GetBindingKey
local NUM_ACTIONBAR_BUTTONS = NUM_ACTIONBAR_BUTTONS or 12

-------------------------------------------------------------------------------
--  Bar configuration
-------------------------------------------------------------------------------
local BAR_CONFIG = {
    -- nativeMainBar: MainBar buttons keep native IDs (1-12), action via
    -- CalculateAction path 1; the bar's _onstate-page handler sets actionpage
    -- from the restricted env for form/vehicle/override paging. Keys flow via
    -- Blizzard's native ActionButtonDown/Up -> GetActionButtonForID -> _G["ActionButton"..id].
    { key = "MainBar",   label = "Action Bar 1 (Main)", barID = 1,  count = 12, blizzBtnPrefix = "ActionButton",              blizzFrame = "MainMenuBar", nativeMainBar = true },
    -- nativeActionPage: the Blizzard actionpage for this bar's slot range.
    -- Buttons keep native IDs; action = ID + (page-1)*12 (CalculateAction path
    -- 1). Keys flow via native MultiActionButtonDown/Up so UseAction gets
    -- isKeyPress=true (required for press-and-hold casting).
    { key = "Bar2",      label = "Action Bar 2",        barID = 2,  count = 12, blizzBtnPrefix = "MultiBarBottomLeftButton",   blizzFrame = "MultiBarBottomLeft",  nativeActionPage = 6 },
    { key = "Bar3",      label = "Action Bar 3",        barID = 3,  count = 12, blizzBtnPrefix = "MultiBarBottomRightButton",  blizzFrame = "MultiBarBottomRight", nativeActionPage = 5 },
    { key = "Bar4",      label = "Action Bar 4",        barID = 4,  count = 12, blizzBtnPrefix = "MultiBarRightButton",        blizzFrame = "MultiBarRight",       nativeActionPage = 3 },
    { key = "Bar5",      label = "Action Bar 5",        barID = 5,  count = 12, blizzBtnPrefix = "MultiBarLeftButton",         blizzFrame = "MultiBarLeft",        nativeActionPage = 4 },
    { key = "Bar6",      label = "Action Bar 6",        barID = 6,  count = 12, blizzBtnPrefix = "MultiBar5Button",          blizzFrame = "MultiBar5",           nativeActionPage = 13 },
    { key = "Bar7",      label = "Action Bar 7",        barID = 7,  count = 12, blizzBtnPrefix = "MultiBar6Button",          blizzFrame = "MultiBar6",           nativeActionPage = 14 },
    { key = "Bar8",      label = "Action Bar 8",        barID = 8,  count = 12, blizzBtnPrefix = "MultiBar7Button",          blizzFrame = "MultiBar7",           nativeActionPage = 15 },
    -- Bar9/Bar10: extra bars with NO native Blizzard frame; our own
    -- EABButton<slot> buttons, paged like Bars 2-8 via explicit-action +
    -- _childupdate-eab-page. customPage = the action page the slots live on:
    -- Bar9 = page 2 (slots 13-24, so converts' existing spells stay placed),
    -- Bar10 = page 10 (slots 109-120). Neither page has a Blizzard binding
    -- command, so keys route via SetOverrideBindingClick through the
    -- EUI_BAR9/10_BUTTON commands in Bindings.xml.
    { key = "Bar9",      label = "Action Bar 9",        barID = 0,  count = 12, customPage = 2 },
    { key = "Bar10",     label = "Action Bar 10",       barID = 0,  count = 12, customPage = 10 },
    { key = "StanceBar", label = "Stance Bar",          barID = 0,  count = 10, blizzBtnPrefix = "StanceButton",               blizzFrame = "StanceBar", isStance = true },
    { key = "PetBar",    label = "Pet Bar",             barID = 0,  count = 10, blizzBtnPrefix = "PetActionButton",            blizzFrame = "PetActionBar", isPetBar = true },
}

-- Aliases for the options file (which references these field names)
for _, info in ipairs(BAR_CONFIG) do
    info.buttonPrefix = info.blizzBtnPrefix
    info.frameName    = info.blizzFrame
    info.fallbackFrame = nil
end

local EXTRA_BARS = {
    { key = "MicroBar", label = "Micro Menu Bar", frameName = "MicroMenuContainer", hoverFrame = "MicroMenu", visibilityOnly = true, blizzOwnedVisibility = true },
    { key = "BagBar",   label = "Bag Bar",        frameName = "BagsBar", visibilityOnly = true, blizzOwnedVisibility = true },
    { key = "QueueStatus", label = "Queue Status", frameName = "QueueStatusButton", visibilityOnly = true, blizzOwnedVisibility = true, noManagedVisibility = true },
    { key = "XPBar",    label = "XP Bar",         visibilityOnly = true, isDataBar = true },
    { key = "RepBar",   label = "Reputation Bar",  visibilityOnly = true, isDataBar = true },
    { key = "FavorBar", label = "House Favor Bar", visibilityOnly = true, isDataBar = true },
    { key = "ExtraActionButton", label = "Extra Action Button", visibilityOnly = true, isBlizzardMovable = true },
    { key = "EncounterBar",      label = "Encounter Bar",         visibilityOnly = true, isBlizzardMovable = true },
}

local ALL_BARS = {}
for _, info in ipairs(BAR_CONFIG) do ALL_BARS[#ALL_BARS + 1] = info end
for _, info in ipairs(EXTRA_BARS) do ALL_BARS[#ALL_BARS + 1] = info end

local BAR_LOOKUP = {}
for _, info in ipairs(BAR_CONFIG) do BAR_LOOKUP[info.key] = info end
for _, info in ipairs(EXTRA_BARS) do BAR_LOOKUP[info.key] = info end

-- Expose AB bar keys immediately so unlock mode's ApplyAnchorPosition can gate
-- edge logic to CDM/AB without waiting for deferred RegisterWithUnlockMode.
if not EllesmereUI._abBarKeys then EllesmereUI._abBarKeys = {} end
for _, info in ipairs(BAR_CONFIG) do EllesmereUI._abBarKeys[info.key] = true end

local BAR_DROPDOWN_VALUES = {}
local BAR_DROPDOWN_ORDER = {}
do
    local _DROPDOWN_EXCLUDE = { ExtraActionButton = true, EncounterBar = true, QueueStatus = true }
    for _, info in ipairs(ALL_BARS) do
        if not _DROPDOWN_EXCLUDE[info.key] then
            BAR_DROPDOWN_VALUES[info.key] = info.label
            BAR_DROPDOWN_ORDER[#BAR_DROPDOWN_ORDER + 1] = info.key
        end
    end
end

local VISIBILITY_ONLY = {}
for _, info in ipairs(EXTRA_BARS) do
    VISIBILITY_ONLY[info.key] = true
end

local DATA_BAR = {}
for _, info in ipairs(EXTRA_BARS) do
    if info.isDataBar then DATA_BAR[info.key] = true end
end

ns.BAR_DROPDOWN_VALUES = BAR_DROPDOWN_VALUES
ns.BAR_DROPDOWN_ORDER  = BAR_DROPDOWN_ORDER
ns.VISIBILITY_ONLY     = VISIBILITY_ONLY
ns.DATA_BAR            = DATA_BAR
ns.BAR_LOOKUP          = BAR_LOOKUP
ns.ALL_BARS            = ALL_BARS
ns.EXTRA_BARS          = EXTRA_BARS

function EAB.VisibilityCompat.ApplyMode(settings, mode)
    if not settings then return "always" end

    mode = mode or "always"
    settings.barVisibility = mode
    settings.alwaysHidden = (mode == "never")

    local wasMouseover = settings.mouseoverEnabled
    settings.mouseoverEnabled = (mode == "mouseover")
    if mode == "mouseover" then
        if not settings._savedBarAlpha then
            settings._savedBarAlpha = settings.mouseoverAlpha or 1
        end
        settings.mouseoverAlpha = 0
    elseif wasMouseover and settings._savedBarAlpha then
        settings.mouseoverAlpha = settings._savedBarAlpha
        settings._savedBarAlpha = nil
    end

    settings.combatHideEnabled = (mode == "out_of_combat")
    settings.combatShowEnabled = (mode == "in_combat")
    return mode
end

function EAB.VisibilityCompat.Normalize(settings)
    if not settings then return "always" end
    if settings.barVisibility then
        return EAB.VisibilityCompat.ApplyMode(settings, settings.barVisibility)
    end
    if settings.alwaysHidden then
        return EAB.VisibilityCompat.ApplyMode(settings, "never")
    end
    if settings.mouseoverEnabled then
        return EAB.VisibilityCompat.ApplyMode(settings, "mouseover")
    end
    if settings.combatShowEnabled then
        return EAB.VisibilityCompat.ApplyMode(settings, "in_combat")
    end
    if settings.combatHideEnabled then
        return EAB.VisibilityCompat.ApplyMode(settings, "out_of_combat")
    end
    return EAB.VisibilityCompat.ApplyMode(settings, "always")
end

function EAB.VisibilityCompat.Copy(dst, src, dstNoGroupModes)
    if not dst or not src then return end

    local mode = EAB.VisibilityCompat.Normalize(src)
    EAB.VisibilityCompat.ApplyMode(dst, mode)

    if mode == "mouseover" then
        dst._savedBarAlpha = src._savedBarAlpha or src.mouseoverAlpha or 1
        dst.mouseoverAlpha = 0
    else
        dst.mouseoverAlpha = src.mouseoverAlpha
        dst._savedBarAlpha = nil
    end

    -- Show During Drag / Show When Spellbook Is Open travel with the copy
    -- (inert unless target mode is Never).
    dst.dragShow = src.dragShow
    dst.spellbookShow = src.spellbookShow

    -- Multi-select set travels with the copy (after ApplyMode, so scalar/set stay
    -- consistent). Group-axis items are stripped for targets that can't express them
    -- (Pet Bar); the stripped selection re-normalizes through the shared setter,
    -- routing the scalar back through ApplyMode to keep the legacy booleans synced.
    if EllesmereUI and EllesmereUI.VisCopySelection then
        EllesmereUI.VisCopySelection(dst, src, "barVisibility",
            dstNoGroupModes and EllesmereUI.VIS_CAPS_NO_GROUP or nil,
            EAB.VisibilityCompat.ApplyMode)
    else
        dst.visibilityModes = nil
        dst.visibilityMatch = src.visibilityMatch or nil
    end
end

-------------------------------------------------------------------------------
--  Media paths
-------------------------------------------------------------------------------
local MEDIA_DIR = "Interface\\AddOns\\EllesmereUIActionBars\\Media\\"
local FONT_PATH = (EllesmereUI.GetFontPath("actionBars"))
    or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"
local HIGHLIGHT_TEXTURES = {
    MEDIA_DIR .. "highlight-2.png",
    MEDIA_DIR .. "highlight-3.png",
    MEDIA_DIR .. "highlight-4.png",
}
ns.HIGHLIGHT_TEXTURES = HIGHLIGHT_TEXTURES

local SHAPE_MASKS = EllesmereUI.SHAPE_MASKS
local SHAPE_BORDERS = EllesmereUI.SHAPE_BORDERS
local SHAPE_INSETS = EllesmereUI.SHAPE_INSETS
local SHAPE_ZOOM_DEFAULTS = {
    none = 5.5, cropped = 2, square = 6.0, circle = 6.0, csquare = 6.0,
    diamond = 6.0, hexagon = 6.0, portrait = 6.0, shield = 6.0,
}
ns.SHAPE_ZOOM_DEFAULTS = SHAPE_ZOOM_DEFAULTS
ns.SHAPE_MASKS   = SHAPE_MASKS
ns.SHAPE_BORDERS = SHAPE_BORDERS

local SHAPE_BTN_EXPAND  = 10
local SHAPE_ICON_EXPAND = 7
ns.SHAPE_BTN_EXPAND  = SHAPE_BTN_EXPAND
ns.SHAPE_ICON_EXPAND = SHAPE_ICON_EXPAND

local SHAPE_ICON_EXPAND_OFFSETS = {
    circle = 2, csquare = 4, diamond = 2, hexagon = 4,
    portrait = 2, shield = 2, square = 4,
}
ns.SHAPE_ICON_EXPAND_OFFSETS = SHAPE_ICON_EXPAND_OFFSETS
ns.SHAPE_INSETS = SHAPE_INSETS

-- Per-shape edge scale so the circular edge path stays inside the mask.
local SHAPE_EDGE_SCALES = {
    circle = 0.75, csquare = 0.75, diamond = 0.70,
    hexagon = 0.65, portrait = 0.70, shield = 0.65, square = 0.75,
}

-- Border thickness mapping
ns.BORDER_THICKNESS = {
    none   = { regular = 0, shape = 0 },
    thin   = { regular = 1, shape = 0 },
    normal = { regular = 2, shape = 0 },
    heavy  = { regular = 3, shape = 0 },
    strong = { regular = 4, shape = 7 },
}
ns.BORDER_THICKNESS_ORDER  = { "none", "thin", "normal", "heavy", "strong" }
ns.BORDER_THICKNESS_LABELS = { none="None", thin="Thin", normal="Normal", heavy="Heavy", strong="Strong" }
ns.BORDER_THICKNESS_DEFAULT_REGULAR = "thin"
ns.BORDER_THICKNESS_DEFAULT_SHAPE   = "strong"

-- Per-addon border texture defaults (central registry)
EllesmereUI.RegisterBorderDefaults("actionbars", EllesmereUI.BORDER_DEFAULTS_BUTTONS)

-------------------------------------------------------------------------------
--  Defaults
-------------------------------------------------------------------------------
local defaults = {
    profile = {
        squareIcons = true,
        iconZoom = 5.5,
        selectedBar = "MainBar",
        cooldownEdgeSize = 2.1,
        cooldownEdgeColor = { r = 0.973, g = 0.839, b = 0.604, a = 1 },
        cooldownEdgeUseClassColor = false,
        pushedTextureType = 2,
        pushedUseClassColor = false,
        pushedCustomColor = { r = 0.973, g = 0.839, b = 0.604, a = 1 },
        pushedBorderSize = 4,
        highlightTextureType = 2,
        highlightUseClassColor = false,
        highlightCustomColor = { r = 0.973, g = 0.839, b = 0.604, a = 1 },
        highlightBorderSize = 4,
        -- Match Bar Border: on bars with a textured Border Style, a press
        -- (pushed Border type), a hover (highlight Border type) or the active
        -- spell lights up a tinted copy of the button's own border instead of
        -- the flat lines or the checked fill. Off = today's look.
        pushedBorderMatchBar = false,
        highlightBorderMatchBar = false,
        castHighlightBorder = false,
        showCastHighlight = true,
        -- Show the recharge countdown on charge spells while a charge is
        -- still banked (mirrors "Show numbers for cooldowns" CVar onto the
        -- recharge timer). Off = Blizzard default (number only at 0 charges).
        showChargeRechargeNumbers = true,
        desaturateOnCooldown = false,
        -- 100 = disabled (zero cost); below 100 dims the icon to that opacity
        -- while on a real cooldown, same detection as Desaturate on Cooldown.
        alphaWhenOnCD = 100,
        -- Cooldown swipe colour+opacity; defaults mirror Blizzard (black, 80%)
        -- so applying them is a no-op until customized.
        cdSwipeColor = { r = 0, g = 0, b = 0 },
        cdSwipeAlpha = 80,
        procGlowType = 1,
        procGlowColor = { r = 1, g = 0.776, b = 0.376 },
        procGlowUseClassColor = false,
        procGlowEnabled = false,
        -- Assisted Highlight ring: extra pixels per side beyond the button
        -- footprint. 0 = Blizzard's size (art sits exactly on the button).
        -- Positive pushes the blue swirl outward so it reads apart from a proc
        -- glow on the same edge; negative pulls it inward.
        assistGlowOutset = 0,
        -- How the Assisted Highlight is drawn: 1 = Blizzard's glow ring only
        -- (default, unchanged behavior), 2 = flat tint over the whole button
        -- instead, 3 = both. The overlay leaves the button edge free for the
        -- proc glow, which is the point of offering it.
        assistGlowStyle = 1,
        -- On Cropped bars, size the glow ring to the button's rectangle
        -- instead of scaling the square art by width. Off = today's ring.
        assistGlowFitCropped = false,
        assistGlowOverlayColor = { r = 0.15, g = 0.5, b = 1 },
        assistGlowOverlayAlpha = 30,
        useBlizzardStyle = false,
        useClassicStyle = false,
        showBlizzIconBg = false,
        blizzIconBgAlpha = 1,
        -- Flat color background behind every button icon; defaults keep the
        -- legacy look (0.15 gray at 50%) so nothing changes until customized.
        slotBgColor = { r = 0.15, g = 0.15, b = 0.15 },
        slotBgOpacity = 50,
        hideCastingAnimations = true,
        mouseoverShowAll = false,
        barPositions = {},
        bars = {},
    },
}

for _, info in ipairs(BAR_CONFIG) do
    defaults.profile.bars[info.key] = {
        enabled = true,
        borderEnabled = true,
        borderColor = { r = 0, g = 0, b = 0, a = 1 },
        borderSize = 1,
        borderClassColor = false,
        borderTexture = "solid",
        borderThickness = "thin",
        borderBehind = false,
        -- Textured border drawn above proc glows, the assisted highlight and
        -- the cooldown swipe. Show Behind wins over it.
        borderAboveEffects = false,
        buttonPadding = 2,
        buttonWidth = 0,
        buttonHeight = 0,
        mouseoverEnabled = false,
        mouseoverAlpha = 1,
        combatShowEnabled = false,
        combatHideEnabled = false,
        housingHideEnabled = false,
        barVisibility = "always",
        dragShow = false,
        -- Hide Bar When Using Gamepad: off by default; inert until a
        -- controller is connected with gamepad support enabled.
        gamepadHideBar = false,
        visHideHousing = false,
        visOnlyInstances = false,
        visHideMounted = false,
        visHideNoTarget = false,
        visHideNoEnemy = false,
        hideKeybind = false,
        keybindFontSize = 12,
        keybindFontColor = { r = 1, g = 1, b = 1 },
        hideMacroText = false,
        macroFontSize = 12,
        macroFontColor = { r = 1, g = 1, b = 1 },
        countFontSize = 12,
        countFontColor = { r = 1, g = 1, b = 1 },
        alwaysHidden = false,
        mouseoverSpeed = 0.15,
        clickThrough = false,
        overrideNumIcons = nil,
        overrideNumRows  = nil,
        growDirection    = "up",
        -- Legacy flag, superseded by iconOrder. iconOrder has no default:
        -- nil means "derive from reverseIconOrder" so old profiles keep layout.
        reverseIconOrder = false,
        alwaysShowButtons = true,
        showPagingArrows = false,
        pagingArrowsRight = false,
        paging = {},
        -- Auto-paging opt-outs (MainBar only; see BuildPagingConditions).
        disableFormPaging = false,
        disableSkyridingPaging = false,
        bgEnabled = false,
        bgColor = { r = 0, g = 0, b = 0, a = 0.5 },
        bgBorderColor = { r = 0, g = 0, b = 0, a = 1 },
        bgBorderTexture = "solid",
        bgBorderBehind = false,
        bgBorderSize = 1,
        bgBorderThickness = "none",
        bgMultiplierX = 1,
        bgMultiplierY = 1,
        bgExpandDirectionX = "right",
        bgExpandDirectionY = "up",
        outOfRangeColoring = false,
        outOfRangeColor = { r = 0.8, g = 0.1, b = 0.1 },
        buttonShape = "none",
        shapeBorderEnabled = true,
        shapeBorderColor = { r = 0, g = 0, b = 0, a = 1 },
        shapeBorderSize = 7,
        shapeBorderClassColor = nil,
        iconZoom = nil,
        keybindOffsetX = 0,
        keybindOffsetY = 0,
        macroOffsetX = 0,
        macroOffsetY = 0,
        countOffsetX = 0,
        countOffsetY = 0,
        -- Text anchors: nil or false keeps the stock placement (keybind top-right,
        -- charges bottom-right, macro name bottom-center). Any value from
        -- EAB.TEXT_ANCHOR_ORDER pins the text to that button corner/edge and
        -- justifies it the same way, so multi-digit text grows away from it.
        keybindAnchor = nil,
        countAnchor = nil,
        macroAnchor = nil,
        cooldownFontSize = 12,
        cooldownTextXOffset = 0,
        cooldownTextYOffset = 0,
        cooldownTextColor = { r = 1, g = 1, b = 1 },
        disableTooltips = false,
        showRankIcon = false,
        orientation = "horizontal",
        numIcons = 12,
        numRows = 1,
        targetWidth = 0,
        targetHeight = 0,
        -- End caps (the End Caps checklist and its cog) and WoW Forever's bar
        -- background, per bar. nil reads the bar's default (ns.AB_CapsSides,
        -- ns.AB_CapsVal, ns.AB_ForeverBg): Action Bar 1 falls back to the
        -- profile-wide keys, every other bar starts without them. The micro
        -- menu and bag bar read the same endCap* keys; the profile keys
        -- endCapSpanLeft / endCapSpanRight (written only by the first-install
        -- capture, in no defaults table) move bar 1's defaults to another bar.
        endCapLeft = nil,
        endCapRight = nil,
        endCapArt = nil,
        endCapScale = nil,
        endCapOffsetX = nil,
        endCapOffsetY = nil,
        foreverBarBg = nil,
    }
end

-- Bar9/Bar10 default to Hidden visibility (what the Visibility dropdown's
-- Hidden option sets) so they never show until the user picks another mode.
for _, k in ipairs({ "Bar9", "Bar10" }) do
    local b = defaults.profile.bars[k]
    if b then
        b.barVisibility = "never"
        b.alwaysHidden  = true
    end
end

for _, info in ipairs(EXTRA_BARS) do
    defaults.profile.bars[info.key] = {
        mouseoverEnabled = false,
        mouseoverAlpha = 1,
        combatShowEnabled = false,
        combatHideEnabled = false,
        housingHideEnabled = false,
        alwaysHidden = false,
        mouseoverSpeed = 0.15,
        clickThrough = false,
    }
    if info.isDataBar then
        local d = defaults.profile.bars[info.key]
        d.width = 400
        d.height = 18
        d.orientation = "HORIZONTAL"
        d.clickThrough = true  -- default on for data bars
        -- Custom Border (opt-in): off keeps the built-in 1px black line. The
        -- style keys below are what the option starts from (solid, thin, black)
        -- and render that same line. Offsets, shifts and borderThicknessPx have
        -- no default (nil = the style's own).
        d.customBorder = false
        d.borderTexture = "solid"
        d.borderThickness = "thin"
        d.borderColor = { r = 0, g = 0, b = 0, a = 1 }
        d.borderBehind = false
    end
end
-- House Favor bar ships opt-in: hidden until the user turns it on.
if defaults.profile.bars.FavorBar then
    defaults.profile.bars.FavorBar.alwaysHidden = true
end

-- Blizzard data bar override (let Blizzard control XP + Rep via Edit Mode). WoW
-- Forever keeps Blizzard's own bars by default (the per-client default rule).
defaults.profile.useBlizzardDataBars = (EllesmereUI.IS_FOREVER == true)
-- Stock vehicle / override bar suppression. Opt-in, and inert until switched
-- on: no frame, no events and no hook exist while it is false.
defaults.profile.hideBlizzardVehicleBar = false

ns.defaults = defaults

-------------------------------------------------------------------------------
--  Utility helpers
-------------------------------------------------------------------------------
local function SafeEnableMouse(frame, enable)
    if not frame then return end
    if frame.IsProtected and frame:IsProtected() and InCombatLockdown() then return end
    if frame.SetMouseClickEnabled then
        frame:SetMouseClickEnabled(enable)
        frame:SetMouseMotionEnabled(enable)
    else
        frame:EnableMouse(enable)
    end
end

-- Like SafeEnableMouse but only mouse motion (OnEnter/OnLeave); keeps
-- click-through so clicks pass to frames behind.
local function SafeEnableMouseMotionOnly(frame, enable)
    if not frame then return end
    if frame.IsProtected and frame:IsProtected() and InCombatLockdown() then return end
    if frame.SetMouseClickEnabled then
        frame:SetMouseClickEnabled(false)
        frame:SetMouseMotionEnabled(enable)
    else
        frame:EnableMouse(enable)
    end
end

-- The alpha THIS addon last wrote to each fade target (bar frames, data bar
-- and extra bar holders, MicroMenuContainer, BagsBar). Fades start from here,
-- never from GetAlpha: another addon may write a secret alpha onto these
-- frames, and math on that read throws. A side table, not a frame field: two
-- targets are Blizzard frames. No entry = never written by us = the default 1.
-- Every alpha write to a fade target goes through the fader, StopFade(frame,
-- alpha), or a record beside its SetAlpha.
local _fadeAlpha = {}

-- The micro menu's and bag bar's end caps ride our own follower frame, not
-- the Blizzard frame, so every alpha written to that Blizzard frame is copied
-- onto their cap layer: ns._abFadeTwin[blizzFrame] = cap layer (weak keys),
-- set only while that bar shows caps (ns.AB_ExtraCaps); nil otherwise.
function ns.AB_FadeTwin(frame, a)
    local tw = ns._abFadeTwin
    local h = tw and tw[frame]
    if h then h:SetAlpha(a) end
end

-- The one fader for every fade target: a shared OnUpdate queue.
-- AnimationGroups spread taint on Blizzard frames and cost 0.7-4ms to start
-- on secure bar frames.
local _extraFadeQueue = {}
local _extraFadeFrame = CreateFrame("Frame")

local function _ExtraFadeOnUpdate(_, elapsed)
    local anyActive = false
    local tw = ns._abFadeTwin
    for frame, info in pairs(_extraFadeQueue) do
        info.elapsed = info.elapsed + elapsed
        local t = info.elapsed / info.duration
        local a
        if t >= 1 then
            a = info.toAlpha
            frame:SetAlpha(a)
            _fadeAlpha[frame] = a
            _extraFadeQueue[frame] = nil
        else
            -- Smooth in/out easing
            local e = t < 0.5 and (2 * t * t) or (1 - (-2 * t + 2)^2 / 2)
            a = info.fromAlpha + (info.toAlpha - info.fromAlpha) * e
            frame:SetAlpha(a)
            _fadeAlpha[frame] = a
            anyActive = true
        end
        if tw then
            local h = tw[frame]
            if h then h:SetAlpha(a) end
        end
    end
    if not anyActive then
        _extraFadeFrame:SetScript("OnUpdate", nil)
    end
end

-- Drag visibility state (file-scope so ApplyAll can reset strata on spec change)
local _dragState = { visible = false, strataCache = {} }

-- Grid show/hide state (show empty slots during spell drag)
local _gridState = { shown = false, visPending = false, spellsPending = false,
    want = nil, settlePending = false, showFns = {}, hideFns = {} }

-- Grid edges arrive in pairs from scripted cursor use: every
-- PickupContainerItem fires ACTIONBAR_SHOWGRID and every place fires
-- ACTIONBAR_HIDEGRID, hundreds of pairs per frame during a bag sort, and
-- applying each edge re-walked every bar and flipped mouseover bars between
-- alpha 1 and 0 (the visible blinking). Settle instead: a pair that nets back
-- to the applied state (_gridState.shown, owned by the appliers) costs
-- nothing, a real drag still surfaces the grid 50ms later. Appliers register
-- into showFns/hideFns at their own definition sites.
function ns.EABQueueGrid(show)
    _gridState.want = show
    if _gridState.settlePending then return end
    _gridState.settlePending = true
    C_Timer_After(0.05, function()
        _gridState.settlePending = false
        local want = _gridState.want
        if want == _gridState.shown then return end
        local list = want and _gridState.showFns or _gridState.hideFns
        for i = 1, #list do list[i]() end
    end)
end
local _quickKeybindState = { open = false, closePending = false, art = {}, FinishClose = nil }

local function ShouldQuickKeybindSurfaceBar(s)
    if not _quickKeybindState.open or not s or s.enabled == false then
        return false
    end

    -- Surfaces bars hidden by transient runtime rules, but explicit "Never" wins.
    -- Hide Bar When Using Gamepad is not a Never: its verdict (EAB._padHide) is
    -- off while this mode is open, so a controller player can bind those bars.
    local vis = s.barVisibility or "always"
    return not s.alwaysHidden and vis ~= "never"
end

local function FadeTo(frame, toAlpha, duration)
    duration = duration or 0.1
    local cur = _fadeAlpha[frame] or 1
    if abs(cur - toAlpha) < 0.01 then
        frame:SetAlpha(toAlpha)
        _fadeAlpha[frame] = toAlpha
        ns.AB_FadeTwin(frame, toAlpha)
        return
    end
    local existing = _extraFadeQueue[frame]
    if existing and existing.toAlpha == toAlpha then return end
    _extraFadeQueue[frame] = {
        fromAlpha = cur,
        toAlpha   = toAlpha,
        duration  = duration,
        elapsed   = 0,
    }
    _extraFadeFrame:SetScript("OnUpdate", _ExtraFadeOnUpdate)
end

-- Stop a running fade. With an alpha, also paint and record it: the one path
-- for a direct write that must win over a fade.
local function StopFade(frame, alpha)
    _extraFadeQueue[frame] = nil
    if alpha then
        frame:SetAlpha(alpha)
        _fadeAlpha[frame] = alpha
        ns.AB_FadeTwin(frame, alpha)
    end
end

-- Unlock mode blanks a bar for one frame around a resize (0, then 1) and
-- reports both writes here, so a later fade still starts where the frame
-- really is. Frames this addon never wrote stay untracked.
function EllesmereUI._EABNoteAlpha(frame, a)
    if _fadeAlpha[frame] ~= nil then _fadeAlpha[frame] = a end
end

-- Resolve borderThickness dropdown to actual pixel values. The ONE size source
-- for a bar's square border: every paint path (bar borders, the shape repaint,
-- the flyout, the keybind-mode restore) takes both results from here. Second
-- result: the exact size from borderThicknessPx (EllesmereUI.BorderPx) while it
-- still pairs with this step and the bar's texture, else nil = the legacy path.
-- A custom shape's ring is on/off only: no exact size there.
local function ResolveBorderThickness(s)
    local thickness = s.borderThickness or "thin"
    local entry = ns.BORDER_THICKNESS[thickness]
    if not entry then entry = ns.BORDER_THICKNESS["thin"] end
    local shape = s.buttonShape or "none"
    if shape ~= "none" and shape ~= "cropped" then
        if thickness == "thin" and s.shapeBorderSize and s.shapeBorderSize ~= entry.shape then
            return s.shapeBorderSize, nil
        end
        return entry.shape, nil
    else
        local sz = entry.regular
        return sz, EllesmereUI.BorderPx(s.borderThicknessPx, sz, s.borderTexture)
    end
end
ns.ResolveBorderThickness = ResolveBorderThickness

-- Condense keybind text (CTRL-2 C2, Mouse Button 4 M4, etc.)
local function FormatHotkeyText(text)
    if not text or text == "" then return "" end
    -- Gamepad binds resolve to glyph markup (no atlas name matches a substitution
    -- below); keyboard binds keep the raw tokens the substitutions are written against.
    local resolved = GetBindingText(text, 1)
    if resolved and resolved:find("|A:", 1, true) then
        text = resolved
    end
    text = text:gsub("CTRL%-", "C")
    text = text:gsub("ALT%-", "A")
    text = text:gsub("SHIFT%-", "S")
    text = text:gsub("META%-", "M")  -- Mac Command key (CMD-E -> ME)
    text = text:gsub("Mouse Button ", "M")
    text = text:gsub("MOUSEWHEELUP", "MwU")
    text = text:gsub("MOUSEWHEELDOWN", "MwD")
    text = text:gsub("CAPSLOCK", "Caps")
    -- Specific NUMPAD keys must be handled before the generic NUMPAD prefix,
    -- or the prefix replacement makes them unmatchable (N. showed as NDECIMAL).
    text = text:gsub("NUMPADDECIMAL", "N.")
    text = text:gsub("NUMPADPLUS", "N+")
    text = text:gsub("NUMPADMINUS", "N-")
    text = text:gsub("NUMPADMULTIPLY", "N*")
    text = text:gsub("NUMPADDIVIDE", "N/")
    text = text:gsub("NUMPAD", "N")
    text = text:gsub("BUTTON", "M")
    return text
end

-- Check if a button has an action assigned
local function ButtonHasAction(btn, prefix)
    if not btn then return false end
    if btn.HasAction then
        local ok, has = pcall(btn.HasAction, btn)
        if ok then return has end
    end
    return btn.icon and btn.icon:IsShown() and btn.icon:GetTexture() ~= nil
end
ns.ButtonHasAction = ButtonHasAction

-- Force-paint a Blizzard-native button's cooldown swipe/text from current action state.
-- The stock cooldown broadcasters are killed at load, so buttons we don't rebuild
-- (OverrideActionBarButton1-6, ExtraActionButton1) would show no swipe/number for an
-- already-active cooldown until the next broadcast. Reads the slot via
-- GetAttribute("action"), never btn.action (protected -- reading it in combat taints).
-- Clears when no active duration resolves so a stale swipe is never left behind.
local function ForceCooldownPaint(btn)
    if not btn then return end
    local cd = btn.cooldown
    local action = btn:GetAttribute("action")
    if cd and action and HasAction(action) and C_ActionBar and C_ActionBar.GetActionCooldown then
        local cdInfo = C_ActionBar.GetActionCooldown(action)
        local durObj = cdInfo and cdInfo.isActive and C_ActionBar.GetActionCooldownDuration
            and C_ActionBar.GetActionCooldownDuration(action)
        if durObj then
            cd:SetCooldownFromDurationObject(durObj)
        else
            cd:Clear()
        end
    end
end
ns.ForceCooldownPaint = ForceCooldownPaint

-- Paint the One Button Assist button's cooldown from the SUGGESTED spell rather
-- than from its action slot. That button draws two things from two sources: the
-- icon is the suggestion sampled on the assist ticker, while the slot's own
-- cooldown mirrors whatever the engine is suggesting at the instant it is read.
-- The suggestion moves faster than the 5 Hz tick, so consecutive reads land on
-- different abilities and the swipe flips on and off under a still icon.
-- spellID nil means no suggestion, where RepaintAssistIcons falls the icon back
-- to the slot's own texture, so the swipe follows it there. isActive is
-- NeverSecret and the duration object carries the timing: no secret is read.
-- On ns, not a local: this file's main chunk is at the 200-local cap.
ns.PaintAssistCooldown = function(btn, spellID)
    if not spellID then return ForceCooldownPaint(btn) end
    local cd = btn and btn.cooldown
    if not cd then return end
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    local durObj = info and info.isActive and C_Spell.GetSpellCooldownDuration
        and C_Spell.GetSpellCooldownDuration(spellID)
    if durObj then
        cd:SetCooldownFromDurationObject(durObj)
    else
        cd:Clear()
    end
end

-- Stock bar frames to disable. Each entry carries flags for how to handle it:
--   retainEvents  = true  -> do NOT unregister events (needed for override state)
local STOCK_BAR_DISPOSAL = {
    { name = "MainActionBar",       retainEvents = true },
    { name = "MainMenuBar" },
    { name = "MultiBarBottomLeft" },
    { name = "MultiBarBottomRight" },
    { name = "MultiBarRight" },
    { name = "MultiBarLeft" },
    { name = "MultiBar5" },
    { name = "MultiBar6" },
    { name = "MultiBar7" },
    { name = "StanceBar" },
    { name = "PetActionBar" },
}

-------------------------------------------------------------------------------
--  Hidden Dump Frame -- reparenting stock frames here is safer than :Hide(),
--  which can trigger taint chains in protected code paths. Full-size so
--  reparented frames keep valid rect queries.
-------------------------------------------------------------------------------
local hiddenParent = CreateFrame("Frame", "EABHiddenParent", UIParent)
hiddenParent:SetAllPoints(UIParent)
hiddenParent:Hide()

-- Quietly hide a Blizzard action button without ever calling a protected
-- Hide()/SetShown(): Blizzard's own UpdateShownButtons (ActionBar.lua) reads
-- the statehidden attribute on its next pass and calls SetShown(false)
-- itself. That next pass is not immediate, so this alone does not guarantee
-- the button reports Hidden right away -- every caller already reparents or
-- hides the button's bar ancestor first, which is what keeps it invisible
-- in the meantime. On ns: file is at the 200-local ceiling.
function ns.QuietlyHideBlizzButton(btn)
    btn:UnregisterAllEvents()
    btn:SetAttributeNoHandler("statehidden", true)
end

-- Re-hide a stock bar Blizzard just re-Show()'d, without calling Hide() or
-- HideBase(): both route through a protected setter (SetShownBase, reached
-- either directly or via Edit Mode's HideOverride/UpdateVisibility) from
-- addon-context Lua, and the next combat-transition SetShownBase call then
-- hits ADDON_ACTION_BLOCKED -- the confirmed cause of the
-- MultiBarBottomLeftButton1 SetShown crash reported from Cooldown Manager
-- play. Reparenting under hiddenParent needs no protected call and achieves
-- the same result: the bar stays effectively invisible regardless of its
-- own Shown state. On ns: file is at the 200-local ceiling.
function ns.ReassertHiddenOnShow(bar)
    bar:HookScript("OnShow", function(self)
        if not InCombatLockdown() then
            self:SetParent(hiddenParent)
        end
    end)
end

-- Blizzard's two event broadcasters dispatch to ALL registered buttons, causing
-- mass redraws; our central dispatcher handles the needed events with
-- HasAction() filtering (GCD swipes ride its ACTIONBAR_UPDATE_COOLDOWN). The
-- block below quiets them at file load, before any button exists, keeping
-- exactly two of Blizzard's own registrations alive (see there), and adds the
-- rest back only while the vehicle/override bar or ExtraActionButton1 shows.
do
    -- The tick set "full" mode adds and removes: what the vehicle/override
    -- bar and ExtraActionButton1 need painted. NEVER the two seeding events.
    local _abefEvents = {
        "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_STATE",
        "ACTIONBAR_UPDATE_USABLE",
        -- Spell-typed extra-action buttons (delve abilities) carry no action
        -- slot, so their cooldown fires SPELL_UPDATE_COOLDOWN not this event.
        "SPELL_UPDATE_COOLDOWN",
        "UPDATE_SHAPESHIFT_FORM",
    }
    local _aaefEvents = {
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
    }
    -- The rest of what ActionBarButtonEventsFrame registers in its own OnLoad.
    -- ACTIONBAR_SLOT_CHANGED and PLAYER_ENTERING_WORLD are in neither list and
    -- are never registered or unregistered by us in any mode: those two stay
    -- Blizzard's own registrations, so their dispatch runs UNTAINTED. They are
    -- the only way Blizzard's hidden ActionButtonN twins ever learn
    -- pressAndHoldAction (Update -> UpdatePressAndHoldAction -> SetAttribute;
    -- a natively routed empower key drives those twins, not ours), and
    -- untainted is what lets that Update write the attribute in combat and
    -- hand secret cooldown values to SetCooldown in restricted content, where
    -- a dispatch of ours would raise once per twin with a running cooldown. A
    -- registration made by us taints every dispatch of that event, which is
    -- why every other event is dropped here and added back only while the
    -- vehicle/extra buttons need painting. Our EABButtons are removed from the
    -- broadcaster's frames list at creation (GetOrCreateButton), so the
    -- untainted loop only ever reaches Blizzard-owned entries.
    local _abefQuiet = {
        "UPDATE_BINDINGS", "GAME_PAD_ACTIVE_CHANGED", "PET_BAR_UPDATE",
        "UNIT_FLAGS", "UNIT_AURA", "PLAYER_MOUNT_DISPLAY_CHANGED",
    }
    -- Drops every registration except the two seeding events. Also the reset
    -- step of every mode change, and the setup path's safety net. Never
    -- UnregisterAllEvents on ActionBarButtonEventsFrame anywhere: it would take
    -- the seeding registrations with it, and nothing of ours can put them
    -- back untainted.
    ns.QuietBroadcasters = function()
        local abef = ActionBarButtonEventsFrame
        if abef then
            for _, ev in ipairs(_abefQuiet) do EUI_SafeUnregisterEvent(abef, ev) end
            for _, ev in ipairs(_abefEvents) do EUI_SafeUnregisterEvent(abef, ev) end
        end
        local aaef = ActionBarActionEventsFrame
        if aaef then aaef:UnregisterAllEvents() end
    end
    ns.QuietBroadcasters()
    -- Add the tick set back only while needed, tracked as two independent
    -- flags so one turning off never strands the other: the vehicle/override
    -- bar (OverrideActionBarButton1-6) and ExtraActionButton1 (delve abilities
    -- with no action slot -- only this broadcaster paints them). The cost story
    -- of the quiet state: SLOT_CHANGED fires only when a slot actually changes
    -- and Blizzard's handler gates on "arg1 == 0 or arg1 == self.action", so a
    -- single twin does real work per event; PLAYER_ENTERING_WORLD is one pass
    -- over the twins per loading screen. ACTIONBAR_UPDATE_COOLDOWN, the event
    -- the perf campaign profiled out (~11x/sec at total idle), is in the tick set.
    local _vehNeed, _extraNeed = false, false
    local _broadcasterMode = "off"
    -- Cooldowns read SECRET in restricted content (instance-gated, not
    -- combat-gated), and the tick set is a registration of OURS: its dispatch
    -- runs under our taint, so Blizzard's own ActionButton_UpdateCooldown ->
    -- SetCooldown is rejected on every twin with a running cooldown, at the
    -- tick rate. No tick set there at all; the vehicle/extra buttons keep the
    -- two seeding events plus our dispatcher's direct paints.
    local function CooldownsSecret()
        if not (C_Secrets and C_Secrets.ShouldCooldownsBeSecret) then return false end
        local ok, secret = pcall(C_Secrets.ShouldCooldownsBeSecret)
        return (ok and secret) and true or false
    end
    local function ApplyBroadcaster()
        local want = (_vehNeed or _extraNeed) and "full" or "off"
        -- Folded into `want` so the mode comparison below sees the change and
        -- re-applies; PLAYER_ENTERING_WORLD and the REGEN edges re-run this.
        if want == "full" and CooldownsSecret() then want = "off" end
        if want == _broadcasterMode then return end
        _broadcasterMode = want
        -- Drop to the quiet state first (the two seeding registrations survive
        -- it), then add the tick set.
        ns.QuietBroadcasters()
        if want == "full" then
            if ActionBarButtonEventsFrame then
                for _, ev in ipairs(_abefEvents) do
                    EUI_SafeRegisterEvent(ActionBarButtonEventsFrame, ev)
                end
            end
            if ActionBarActionEventsFrame then
                for _, ev in ipairs(_aaefEvents) do
                    EUI_SafeRegisterUnitEvent(ActionBarActionEventsFrame, ev, "player")
                end
            end
        end
    end
    -- For callers that quiet the broadcasters DIRECTLY rather than through
    -- ApplyBroadcaster (the setup path's safety net, which can run after "full"
    -- has registered): the tick set is gone while _broadcasterMode still claims
    -- it, and the mode check above would early-out forever. Any direct
    -- quieting must come back through here.
    ns.ResyncBroadcaster = function()
        _broadcasterMode = nil   -- the caller has just quieted the frames; never early-out
        ApplyBroadcaster()
    end
    -- Recompute from ground truth (the buttons' actual visibility) on a broad event set
    -- rather than tracking enter/exit: the extra button's OnShow doesn't fire on delve
    -- entry, and vehicle enter events don't reliably fire/keep state.
    local function RefreshBroadcasterNeeds()
        _vehNeed = (OverrideActionBarButton1 and OverrideActionBarButton1:IsShown()) and true or false
        _extraNeed = (ExtraActionButton1 and ExtraActionButton1:IsShown()) and true or false
        ApplyBroadcaster()
    end
    -- Exposed for the extra action button's Show-hook refresh in
    -- SetupBlizzardMovableFrame (a reliable trigger for delve entry).
    ns.RefreshBroadcaster = RefreshBroadcasterNeeds
    local barFrame = ns.TakeShell()
    EUI_SafeRegisterEvent(barFrame, "UNIT_ENTERED_VEHICLE")
    EUI_SafeRegisterEvent(barFrame, "UNIT_EXITED_VEHICLE")
    EUI_SafeRegisterEvent(barFrame, "UPDATE_VEHICLE_ACTIONBAR")
    EUI_SafeRegisterEvent(barFrame, "UPDATE_OVERRIDE_ACTIONBAR")
    EUI_SafeRegisterEvent(barFrame, "UPDATE_EXTRA_ACTIONBAR")
    barFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    barFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    barFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    barFrame:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            -- Undeferred, and a secrecy re-check only: the needs are unchanged
            -- at a combat edge, so this early-outs unless the secret state moved.
            ApplyBroadcaster()
            return
        end
        C_Timer.After(0, RefreshBroadcasterNeeds) -- deferred so IsShown reflects post-event state
        -- On vehicle/override entry, force-paint OverrideActionBar cooldowns:
        -- the broadcaster only catches the NEXT change, so an already-running
        -- cooldown needs an initial paint.
        if (event == "UNIT_ENTERED_VEHICLE" or event == "UPDATE_VEHICLE_ACTIONBAR"
            or event == "UPDATE_OVERRIDE_ACTIONBAR") and not (unit and unit ~= "player") then
            C_Timer.After(0, function()
                for i = 1, 6 do
                    local btn = _G["OverrideActionBarButton" .. i]
                    if btn then
                        -- Cooldown-only refresh; avoids passing secret cooldown values through a tainted call.
                        ForceCooldownPaint(btn)
                        local hk = btn.HotKey
                        if hk then
                            local key1 = GetBindingKey("ACTIONBUTTON" .. i)
                            if key1 then
                                hk:SetText(FormatHotkeyText(key1))
                                hk:Show()
                            end
                        end
                    end
                end
            end)
        end
    end)
end

-------------------------------------------------------------------------------
--  Early Blizzard Bar Disposal (file load time): runs before combat state is
--  restored, so protected calls (Hide, SetParent) execute cleanly without
--  tainting Blizzard's ActionBarController call chain.
-------------------------------------------------------------------------------
do
    -- Make Blizzard's action bar pager unclickable. MainActionBar stays in
    -- Blizzard's parent chain and is alpha-hidden, so its children stay live
    -- -- ActionBarPageNumber (frameLevel 100, above our buttons) holds
    -- UpButton/DownButton that page the main bar on click: invisible but
    -- fully clickable. Reached by parentKey (no global name for the modern
    -- frame), every step guarded so a rename degrades to a no-op. Mouse state
    -- only, never Hide(): the parent has taint history around its protected
    -- shown state, and these are ordinary QuickKeybindButtonTemplate buttons,
    -- so disabling mouse is unprotected, combat-safe, and enough. Nothing of
    -- ours clicks them -- EUI's paging arrows drive their own secure buttons.
    local function KillPagerMouse(bar)
        local pager = bar and bar.ActionBarPageNumber
        if not pager then return end
        local function killOne(f)
            if not f or type(f.IsMouseEnabled) ~= "function" then return end
            if not f:IsMouseEnabled() then return end -- no-op after first pass
            f:EnableMouse(false)
            if f.EnableMouseClicks then f:EnableMouseClicks(false) end
            if f.EnableMouseMotion then f:EnableMouseMotion(false) end
        end
        killOne(pager)
        killOne(pager.UpButton)
        killOne(pager.DownButton)
        -- Cover anything else Blizzard parents in here later (ResizeLayoutFrame).
        -- Runs on every MainActionBar Show (form, stance and page flips), so
        -- it reads the live list instead of building a table.
        if type(pager.GetChildren) == "function" then
            for i = 1, pager:GetNumChildren() do
                killOne((select(i, pager:GetChildren())))
            end
        end
    end

    local framesToHide = {
        "MainActionBar",
        "MultiBar5",
        "MultiBar6",
        "MultiBar7",
        "MultiBarBottomLeft",
        "MultiBarBottomRight",
        "MultiBarLeft",
        "MultiBarRight",
    }

    local keepEvents = {
        MainActionBar = true,
    }

    for _, frameName in ipairs(framesToHide) do
        local frame = _G[frameName]
        if frame then
            if not keepEvents[frameName] then
                frame:UnregisterAllEvents()
            end

            -- MainActionBar stays in Blizzard's parent chain so pet battle
            -- restoration of MicroMenu works; all others safely reparent.
            if frameName == "MainActionBar" then
                (frame.HideBase or frame.Hide)(frame)
                -- Keep MainActionBar invisible when Blizzard re-shows it on
                -- spec/zone/vehicle/bonus-bar transitions WITHOUT touching its
                -- protected shown state: Hide() from this insecure hook taints the
                -- frame, and ValidateActionBarTransition then hits ADDON_ACTION_BLOCKED
                -- on the next combat SetShownBase. SetAlpha is unprotected, inherits to
                -- children, and works in combat, so the bar stays hidden taint-free.
                hooksecurefunc(frame, "Show", function(self)
                    self:SetAlpha(0)
                    KillPagerMouse(self) -- re-assert: layout apply can re-enable pager mouse
                end)
                -- Disable mouse on MainActionBar: Blizzard can Show() it in
                -- combat (mount/dismount), and at alpha 0 / level 50 it would
                -- invisibly intercept clicks above our EABButtons.
                frame:EnableMouse(false)
                if frame.EnableMouseClicks then frame:EnableMouseClicks(false) end
                if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
                -- EnableMouse(false) on a parent does NOT disable children, so
                -- the pager's invisible arrows would still eat clicks.
                KillPagerMouse(frame)
                if frame.Selection then frame.Selection:Hide(); frame.Selection:SetAlpha(0) end -- Edit Mode selection/mover
                local caps = frame.EndCaps
                if caps then
                    caps:Hide() -- artwork (gryphons/endcaps/border)
                    -- WoW Forever: each end cap is an Edit Mode system of its own that
                    -- shows itself and its selection overlay whenever Edit Mode opens
                    -- (the overlay ignores the bar's alpha). Silence both overlays like
                    -- the bar's own; Edit Mode's Show never resets alpha or mouse.
                    local l, r = caps.LeftEndCap, caps.RightEndCap
                    if l and l.Selection then l.Selection:SetAlpha(0); l.Selection:EnableMouse(false) end
                    if r and r.Selection then r.Selection:SetAlpha(0); r.Selection:EnableMouse(false) end
                end
                if frame.BorderArt then frame.BorderArt:Hide() end
                frame:SetAlpha(0)
            else
                -- No Hide()/HideBase() here: reparenting to hiddenParent (kept
                -- permanently Hidden) makes the bar effectively invisible
                -- regardless of its own Shown state -- see ReassertHiddenOnShow's
                -- note above hiddenParent's creation for the taint this avoids.
                frame:SetParent(hiddenParent)
            end

            if frame.actionButtons and type(frame.actionButtons) == "table" then
                for _, button in pairs(frame.actionButtons) do
                    ns.QuietlyHideBlizzButton(button)
                end
            end
        end
    end

    -- Hide ActionBarParent (stock bars' container) -- cosmetic only, the
    -- individual bars are already reparented; OverrideActionBar hangs off
    -- UIParent so it's unaffected. Done at file load rather than via
    -- RegisterAttributeDriver to avoid tainting protected frame state.
    if ActionBarParent then
        ActionBarParent:Hide()
        ActionBarParent:SetParent(hiddenParent)
    end
end

-------------------------------------------------------------------------------
--  Central Action Button Controller: a SecureHandlerAttributeTemplate that
--  manages ALL action buttons. Tracks button-to-action mappings in a secure
--  table, implements bitwise showgrid, and defers visibility flush so rapid
--  state changes batch into a single update pass.
-------------------------------------------------------------------------------
local ActionButtonController = CreateFrame("Frame", "EABActionButtonController", UIParent, "SecureHandlerAttributeTemplate")

-- Showgrid reasons (bitwise flags)
local SHOWGRID = {
    GAME_EVENT = 2,
    SPELLBOOK  = 4,
    KEYBOUND   = 16,
    ALWAYS     = 32,
}

-- Lua-side button registry: [button] = actionSlot
local _controllerButtons = {}

ActionButtonController:Execute([[
    _eabBtnMap = table.new()
    _eabPendingVis = table.new()
]])

-- Secure method: SetShowGrid (bitwise flag toggle). Restricted Lua has no bit
-- library, so modular arithmetic tests/flips individual bits in the bitmask.
ActionButtonController:SetAttributeNoHandler("SetShowGrid", [[
    local show, reason, force = ...
    local cur = self:GetAttribute("showgrid") or 0
    local prev = cur

    if show then
        if cur % (reason * 2) < reason then cur = cur + reason end
    elseif cur % (reason * 2) >= reason then
        cur = cur - reason
    end

    if (prev ~= cur) or force then
        self:SetAttribute("showgrid", cur)
        for btn in pairs(_eabBtnMap) do
            btn:RunAttribute("SetShowGrid", show, reason)
        end
    end
]])

-- Secure method: run a named RunAttribute on every button matching an action slot
ActionButtonController:SetAttributeNoHandler("ForActionSlot", [[
    local slot, method = ...
    for btn, act in pairs(_eabBtnMap) do
        if act == slot then btn:RunAttribute(method) end
    end
]])

-- Deferred visibility: "flush"=0 marks dirty; the attribute driver resets it
-- to 1 after ~200ms, applying pending changes in one batch instead of per-change.
RegisterAttributeDriver(ActionButtonController, "flush", 1)

ActionButtonController:SetAttributeNoHandler("_onattributechanged", [[
    if name == "flush" and value == 1 then
        for btn in pairs(_eabPendingVis) do
            btn:RunAttribute("UpdateShown")
            _eabPendingVis[btn] = nil
        end
    end
]])

-- Per-button secure snippets (installed via WrapScript during registration)
local BTN_ON_ATTRIBUTE_CHANGED = [[
    if name == "action" then
        local prev = _eabBtnMap[self]
        if prev ~= value then
            _eabBtnMap[self] = value
            _eabPendingVis[self] = value
            control:SetAttribute("flush", 0)
        end
    end
]]

local BTN_POST_CLICK = [[
    control:RunAttribute("ForActionSlot", self:GetAttribute("action"), "UpdateShown")
]]

-- Forward the drag kind so the post-handler can refresh visibility for the
-- affected action slot.
local BTN_ON_RECEIVE_DRAG_BEFORE = [[
    if kind then return "message", kind end
]]

local BTN_ON_RECEIVE_DRAG_AFTER = [[
    control:RunAttribute("ForActionSlot", self:GetAttribute("action"), "UpdateShown")
]]

-- Re-evaluate on show/hide to catch delayed state changes from the secure environment.
local BTN_ON_SHOW_HIDE = [[
    self:RunAttribute("UpdateShown")
]]

-- Showgrid monitor: when Blizzard changes ActionButton1's showgrid
-- (e.g. during spell drag in combat), propagate to all our buttons.
local function InitShowGridMonitor()
    if not ActionButton1 then return end
    ActionButtonController:WrapScript(ActionButton1, "OnAttributeChanged", [[
        if name ~= "showgrid" then return end
        for r = 2, 4, 2 do
            local on = value % (r * 2) >= r
            control:RunAttribute("SetShowGrid", on, r)
        end
    ]])
end

-- Register a button with the controller (adds WrapScript handlers + secure table entry)
local function RegisterButtonWithController(btn)
    if _controllerButtons[btn] then return end

    -- On /reload, Lua locals reset but frames survive: if the button already
    -- carries our secure snippets, skip WrapScript+Execute (re-wrapping in
    -- combat taints the restricted env) and just restore the Lua registry.
    if btn:GetAttribute("_eabControllerRegistered") then
        _controllerButtons[btn] = true
        return
    end

    ActionButtonController:WrapScript(btn, "OnAttributeChanged", BTN_ON_ATTRIBUTE_CHANGED)
    ActionButtonController:WrapScript(btn, "PostClick", BTN_POST_CLICK)
    ActionButtonController:WrapScript(btn, "OnReceiveDrag", BTN_ON_RECEIVE_DRAG_BEFORE, BTN_ON_RECEIVE_DRAG_AFTER)
    ActionButtonController:WrapScript(btn, "OnShow", BTN_ON_SHOW_HIDE)
    ActionButtonController:WrapScript(btn, "OnHide", BTN_ON_SHOW_HIDE)
    -- Combat drag belt: dragging FROM one of our buttons reveals empty drop
    -- targets via the controller's secure broadcast, independent of the
    -- ActionButton1 showgrid monitor (which depends on Blizzard's retained
    -- MainActionBar event chain staying secure end to end). Pre-wrap returns
    -- nothing so the native drag proceeds untouched; the matching grid-off
    -- arrives via the monitor or, failing that, the regen apply -- but only
    -- when a pickup actually happens, which is what the guard below is for.
    -- OnDragStart fires on the GESTURE, not on a successful pickup. Blizzard's
    -- own handler no-ops when the bars are locked and the PICKUPACTION modifier
    -- is not held, so an unconditional reveal here lit every empty slot on a
    -- plain left-drag over a locked bar -- and since no pickup happened, no
    -- ACTIONBAR_HIDEGRID ever arrived to turn it back off. It then sat there
    -- until some unrelated repaint cleared it (reported: "goes away in 5-15
    -- seconds, or when I use the spell"). Mirror Blizzard's own condition so
    -- the reveal only fires when the drag will actually pick the action up.
    -- IsModifiedClick is whitelisted in the restricted environment.
    ActionButtonController:WrapScript(btn, "OnDragStart", [[
        if control:GetAttribute("eab-barslocked") ~= 1 or IsModifiedClick("PICKUPACTION") then
            control:RunAttribute("SetShowGrid", true, 2)
        end
    ]])

    -- Per-button showgrid: toggle the flag bit and update visibility. With "Always Show
    -- Buttons" off, empty slots are parked statehidden+Hidden+ alpha0+mouse-off, and
    -- insecure reversal is gated out of combat, so a combat spell drag needs drop
    -- targets revealed entirely INSIDE the restricted env: TRANSIENT grid reasons
    -- (every bit below ALWAYS) override statehidden for within-cutoff buttons, and
    -- Show/alpha/mouse restore on the hidden->shown edge only (so a live on-CD alpha on
    -- a visible button is never stomped). eab-withincutoff keeps icon-cutoff buttons
    -- out of the override; eab-click carries the bar's click-through setting so a
    -- reveal never turns a click-through bar clickable.
    btn:SetAttributeNoHandler("SetShowGrid", [[
        local show, reason, force = ...
        local cur = self:GetAttribute("showgrid") or 0
        local prev = cur

        if show then
            if cur % (reason * 2) < reason then cur = cur + reason end
        elseif cur % (reason * 2) >= reason then
            cur = cur - reason
        end

        if (prev ~= cur) or force then
            self:SetAttribute("showgrid", cur)
            local vis
            -- >= 2, NOT > 0: Blizzard's own SetShowGrid writes this same
            -- attribute on native buttons, and its CVAR reason is bit 1 --
            -- stamped at every login when the user has Blizzard's Always
            -- Show Buttons on. Counting it here made empty slots
            -- un-hideable (v8.7.5 report). Transient means bits 2+ only.
            if (cur % 32) >= 2 and (self:GetAttribute("eab-withincutoff") or 1) ~= 0 then
                vis = true
            else
                vis = (cur > 0 or HasAction(self:GetAttribute("action") or 0))
                    and not self:GetAttribute("statehidden")
            end
            if vis then
                if not self:IsShown() then
                    self:SetAlpha(1)
                    if (self:GetAttribute("eab-click") or 1) ~= 0 then
                        self:EnableMouse(true)
                    end
                end
                self:Show(true)
            else
                self:Hide(true)
            end
        end
    ]])

    -- Visibility: show if grid active or action exists, unless explicitly
    -- state-hidden. Same transient-grid override and edge-gated alpha/mouse
    -- restore as SetShowGrid, so a mid-drag flush cannot re-hide a revealed target.
    btn:SetAttributeNoHandler("UpdateShown", [[
        local cur = self:GetAttribute("showgrid") or 0
        local hasAct = HasAction(self:GetAttribute("action") or 0)
        local hidden = self:GetAttribute("statehidden")
        local vis
        -- >= 2, not > 0: bit 1 is Blizzard's CVAR reason (see SetShowGrid
        -- above) and must never count as a transient reveal.
        if (cur % 32) >= 2 and (self:GetAttribute("eab-withincutoff") or 1) ~= 0 then
            vis = true
        else
            vis = (cur > 0 or hasAct) and not hidden
        end
        if vis then
            if not self:IsShown() then
                self:SetAlpha(1)
                if (self:GetAttribute("eab-click") or 1) ~= 0 then
                    self:EnableMouse(true)
                end
            end
            self:Show(true)
        else
            self:Hide(true)
        end
    ]])

    -- Add to the secure button map
    ActionButtonController:SetFrameRef("add", btn)
    ActionButtonController:Execute([[
        local b = self:GetFrameRef("add")
        _eabBtnMap[b] = b:GetAttribute("action") or 0
    ]])

    -- Mark the button so we can detect it survived a /reload
    btn:SetAttributeNoHandler("_eabControllerRegistered", true)

    _controllerButtons[btn] = true
end

-- Lua-side showgrid manipulation (out of combat only)
local function SetShowGridInsecure(btn, show, reason, force)
    if InCombatLockdown() then ns._eabApplyDeferred = true return end
    if type(reason) ~= "number" then return end

    local value = btn:GetAttribute("showgrid") or 0
    local prevValue = value

    if show then
        value = bit.bor(value, reason)
    else
        value = bit.band(value, bit.bnot(reason))
    end

    if (value ~= prevValue) or force then
        btn:SetAttribute("showgrid", value)
    end
end

-------------------------------------------------------------------------------
--  Override Controller: monitors vehicle/override/possess/form/petbattle
--  states via attribute drivers and propagates changes to all registered bar
--  frames. Parented to UIParent -- never parent addon frames to
--  OverrideActionBar, which taints its child hierarchy and blocks BeginActionBarTransition.
-------------------------------------------------------------------------------
local OverrideController
do
    OverrideController = CreateFrame("Frame", "EABOverrideController", UIParent,
        "SecureHandlerAttributeTemplate")

    OverrideController:SetAttributeNoHandler("_onattributechanged", [[
        -- Propagate known state attributes to all registered bar frames
        if name == "overrideui" or name == "petbattleui" or name == "overridepage" then
            for _, f in pairs(_eabBarFrames) do
                f:SetAttribute("state-" .. name, name == "overridepage" and value or (value == 1))
            end
        else
            -- Any other attribute change: re-evaluate the override page from
            -- Blizzard's vehicle/override/shapeshift APIs.
            local pg = 0
            if HasVehicleActionBar and HasVehicleActionBar() then
                pg = GetVehicleBarIndex and GetVehicleBarIndex() or 0
            elseif HasOverrideActionBar and HasOverrideActionBar() then
                pg = GetOverrideBarIndex and GetOverrideBarIndex() or 0
            elseif HasTempShapeshiftActionBar and HasTempShapeshiftActionBar() then
                pg = GetTempShapeshiftBarIndex() or 0
            end
            if self:GetAttribute("overridepage") ~= pg then
                self:SetAttribute("overridepage", pg)
            end
        end
    ]])

    -- Secure table of bar frames that receive state broadcasts
    OverrideController:Execute([[ _eabBarFrames = table.new() ]])

    -- overrideui driven by [overridebar][vehicleui] macro instead of parenting
    -- to OverrideActionBar (which would taint the protected frame).
    for attr, driver in pairs({
        form = "[form]1;0",
        overridebar = "[overridebar]1;0",
        overrideui = "[overridebar][vehicleui]1;0",
        possessbar = "[possessbar]1;0",
        sstemp = "[shapeshift]1;0",
        vehicle = "[@vehicle,exists]1;0",
        vehicleui = "[vehicleui]1;0",
        petbattleui = "[petbattle]1;0",
    }) do
        RegisterAttributeDriver(OverrideController, attr, driver)
    end
end

-- Add a bar frame to the watch list. Deduped in the snippet: the secure list
-- can never be pruned, so a re-registration would grow it and every sweep permanently.
local function RegisterBarWithOverrideController(frame)
    OverrideController:SetFrameRef("add", frame)
    OverrideController:Execute([[
        local f = self:GetFrameRef("add")
        for i = 1, #_eabBarFrames do
            if _eabBarFrames[i] == f then return end
        end
        table.insert(_eabBarFrames, f)
    ]])

    -- Initialize state on the frame
    frame:SetAttribute("state-overrideui", tonumber(OverrideController:GetAttribute("overrideui")) == 1)
    frame:SetAttribute("state-petbattleui", tonumber(OverrideController:GetAttribute("petbattleui")) == 1)
    frame:SetAttribute("state-overridepage", OverrideController:GetAttribute("overridepage") or 0)
end

-------------------------------------------------------------------------------
--  Secure Setup Handler: performs protected frame ops (SetParent, SetPoint,
--  SetSize, Show/Hide) from within a restricted secure snippet so they run
--  even during combat lockdown (normal Lua cannot call these on protected
--  frames in combat, but a SecureHandlerAttributeTemplate snippet can).
--  Usage: SecureSetupHandler_PrepareRefs() once after bar frames are
--  created -> SecureSetupHandler_EncodeLayout() to write layout as
--  attributes -> SecureSetupHandler_Execute() to trigger the snippet.
-------------------------------------------------------------------------------
-- Forward declaration (populated in Button Creation below); needed here
-- because SecureSetupHandler_PrepareRefs references it.
local barButtons = {}
ns.barButtons = barButtons

local _secureHandler = CreateFrame("Frame", "EABSecureSetupHandler", UIParent, "SecureHandlerAttributeTemplate")

-- Reads encoded button data and applies SetParent + layout. Attribute format
-- per slot: "btn-N" = "barref|x|y|w|h|show" (show="1"/"0"). Frame refs: bar
-- frames as "bar-{key}", hidden parent as "hiddenParent", UIParent as
-- "uiParent", Blizzard bars as "blizzbar-{name}". Trigger: set "do-setup" to
-- any value to run the full setup.
_secureHandler:SetAttribute("_onattributechanged", [=[
    if name == "do-setup" then
        -- (setup code follows below)
    elseif name == "clear-binds" then
        self:ClearBindings()
        return
    else
        return
    end

    -- Step 1: Reparent Blizzard buttons to UIParent (extract from Blizzard bars)
    local uiParent = self:GetFrameRef("uiParent")
    local btnCount = self:GetAttribute("btn-count") or 0
    for slot = 1, btnCount do
        local btnRef = self:GetFrameRef("btn-" .. slot)
        if btnRef then
            btnRef:SetParent(uiParent)
        end
    end

    -- Step 2: Hide Blizzard bar frames
    local hiddenParent = self:GetFrameRef("hiddenParent")
    local blizzCount = self:GetAttribute("blizzbar-count") or 0
    for i = 1, blizzCount do
        local barRef = self:GetFrameRef("blizzbar-" .. i)
        if barRef then
            barRef:SetParent(hiddenParent)
        end
    end

    -- Step 3: Reparent buttons to our bar frames and apply layout
    for slot = 1, btnCount do
        local data = self:GetAttribute("layout-" .. slot)
        if data then
            local barKey, x, y, w, h, show, actionSlot = strsplit("|", data)
            local btnRef = self:GetFrameRef("btn-" .. slot)
            local barRef = self:GetFrameRef("bar-" .. barKey)
            if btnRef and barRef then
                -- Clear statehidden so the button is under our control
                btnRef:SetAttribute("statehidden", nil)
                btnRef:SetParent(barRef)
                btnRef:ClearAllPoints()
                btnRef:SetPoint("TOPLEFT", barRef, "TOPLEFT", tonumber(x) or 0, tonumber(y) or 0)
                btnRef:SetWidth(tonumber(w) or 45)
                btnRef:SetHeight(tonumber(h) or 45)
                if barKey == "PetBar" then
                    local petIndex = tonumber(actionSlot) or 1
                    btnRef:SetID(petIndex)
                    btnRef:SetAttribute("action", nil)
                elseif barKey == "StanceBar" then
                    -- Stance buttons keep their native handling
                else
                    -- All action bar buttons use explicit action attributes.
                    btnRef:SetID(0)
                    if actionSlot and actionSlot ~= "" and actionSlot ~= "0" then
                        btnRef:SetAttribute("action", tonumber(actionSlot))
                    end
                end
                if show == "1" then
                    btnRef:Show()
                else
                    btnRef:Hide()
                end
            end
        end
    end

    -- Step 4: Size and position our bar frames (hide if always-hidden or disabled)
    local barFrameCount = self:GetAttribute("barframe-count") or 0
    for i = 1, barFrameCount do
        local frameData = self:GetAttribute("barframe-" .. i)
        if frameData then
            local barKey, w, h, point, relPoint, x, y, hidden = strsplit("|", frameData)
            local barRef = self:GetFrameRef("bar-" .. barKey)
            local uip = self:GetFrameRef("uiParent")
            if barRef and uip then
                barRef:SetWidth(tonumber(w) or 1)
                barRef:SetHeight(tonumber(h) or 1)
                barRef:ClearAllPoints()
                barRef:SetPoint(point or "CENTER", uip, relPoint or "CENTER", tonumber(x) or 0, tonumber(y) or 0)
                if hidden == "1" then
                    barRef:Hide()
                else
                    barRef:Show()
                end
            end
        end
    end

    -- Step 5: MainBar paging is driven by _onstate-page -> ChildUpdate("eab-page").
    -- Each button's _childupdate-eab-page recalculates the action attribute.

    -- Step 6: All keybind dispatch uses SetOverrideBindingClick (set by UpdateKeybinds).
]=])

-- Register all buttons and bar frames as refs on the secure handler.
-- Must be called AFTER SetupBar creates buttons (barButtons is populated).
local _secureRefsReady = false
-- One pass over every button that exists. Lazily built bars add buttons after
-- it has already run, so the reveal path in RefreshRuntimeVisibility clears
-- _secureRefsReady and calls this again; indices are reassigned consistently in
-- the same pass, and the only readers of btn._secureSlotIdx run after a full one.
local function SecureSetupHandler_PrepareRefs()
    if _secureRefsReady then return end
    _secureRefsReady = true

    _secureHandler:SetFrameRef("uiParent", UIParent)
    _secureHandler:SetFrameRef("hiddenParent", hiddenParent)

    -- Register all buttons (our EABButtons + Blizzard Stance/Pet)
    local btnIdx = 0
    for _, info in ipairs(BAR_CONFIG) do
        local btns = barButtons[info.key]
        if btns then
            for _, btn in ipairs(btns) do
                if btn then
                    btnIdx = btnIdx + 1
                    _secureHandler:SetFrameRef("btn-" .. btnIdx, btn)
                    btn._secureSlotIdx = btnIdx
                end
            end
        end
    end
    _secureHandler:SetAttribute("btn-count", btnIdx)

    -- Register stock bar frames to hide
    local blizzIdx = 0
    for _, entry in ipairs(STOCK_BAR_DISPOSAL) do
        local bar = _G[entry.name]
        if bar then
            blizzIdx = blizzIdx + 1
            _secureHandler:SetFrameRef("blizzbar-" .. blizzIdx, bar)
        end
    end
    if StatusTrackingBarManager and not (EAB.db and EAB.db.profile.useBlizzardDataBars) then
        blizzIdx = blizzIdx + 1
        _secureHandler:SetFrameRef("blizzbar-" .. blizzIdx, StatusTrackingBarManager)
    end
    _secureHandler:SetAttribute("blizzbar-count", blizzIdx)
end

-- Register our bar frames as refs. Called after CreateBarFrame.
local function SecureSetupHandler_RegisterBarFrame(key, frame)
    _secureHandler:SetFrameRef("bar-" .. key, frame)
end

-- Encode layout data for all buttons as attributes, then trigger the snippet.
-- layoutData: table of { slot = { barKey, x, y, w, h, show, actionSlot } }
-- barFrameData: table of { key, w, h, point, relPoint, x, y }
local function SecureSetupHandler_Execute(layoutData, barFrameData)
    for slot, d in pairs(layoutData) do
        local actionSlot = d.actionSlot or 0
        _secureHandler:SetAttribute("layout-" .. slot,
            d.barKey .. "|" .. d.x .. "|" .. d.y .. "|" .. d.w .. "|" .. d.h .. "|" .. (d.show and "1" or "0") .. "|" .. actionSlot)
    end
    -- Encode bar frame sizes/positions
    local barFrameCount = 0
    for _, d in ipairs(barFrameData) do
        barFrameCount = barFrameCount + 1
        _secureHandler:SetAttribute("barframe-" .. barFrameCount,
            d.key .. "|" .. d.w .. "|" .. d.h .. "|" .. d.point .. "|" .. d.relPoint .. "|" .. d.x .. "|" .. d.y .. "|" .. (d.hidden and "1" or "0"))
    end
    _secureHandler:SetAttribute("barframe-count", barFrameCount)
    -- Trigger the snippet
    _secureHandler:SetAttribute("do-setup", GetTime())
end

local function HideBlizzardBars()
    -- Fully hide all Blizzard action buttons (we create our own instead);
    -- Stance/Pet buttons are still reused, so only action buttons are hidden.
    for _, info in ipairs(BAR_CONFIG) do
        if info.blizzBtnPrefix and not info.isStance and not info.isPetBar then
            for i = 1, info.count do
                local btn = _G[info.blizzBtnPrefix .. i]
                if btn then
                    -- NOT reparented, and that is deliberate. The template sets
                    -- "useparent-actionpage" and then seeds self.action from
                    -- UpdateAction() in its OnLoad, so the button derives its
                    -- slot from whichever frame is its PARENT. Moving it to
                    -- hiddenParent breaks that inheritance and freezes
                    -- self.action at whatever it resolved to at load -- and
                    -- Blizzard's own ACTIONBAR_SLOT_CHANGED handler gates on
                    -- "arg1 == 0 or arg1 == tonumber(self.action)", so a button
                    -- with a stale cached slot can never match the slot that
                    -- actually changed and simply stops updating. That is what
                    -- left pressAndHoldAction unset on the natively-routed
                    -- twins and killed Hold and Release on empower KEYBINDS,
                    -- while mouse clicks (through our own buttons) were fine.
                    -- Leaving them under their real bar costs no visibility:
                    -- every stock bar is in STOCK_BAR_DISPOSAL, hidden with an
                    -- OnShow re-hide, so a child of one is never drawn.
                    ns.QuietlyHideBlizzButton(btn)
                end
            end
        end
    end
    -- MainMenuBar/StanceBar/PetActionBar need EAB.db ready, so handled here
    -- rather than at file load.
    local remainingBars = { "MainMenuBar", "StanceBar", "PetActionBar" }
    for _, name in ipairs(remainingBars) do
        local bar = _G[name]
        if bar then
            bar:UnregisterAllEvents()
            -- No Hide()/HideBase() call: SetParent(hiddenParent) below already
            -- makes the bar effectively invisible taint-free (see the note on
            -- ReassertHiddenOnShow above hiddenParent's creation).
            bar:SetParent(hiddenParent)
            -- Prevent Blizzard re-showing it (spell transforms like Ascendance
            -- can trigger ValidateActionBarTransition, creating invisible dead zones)
            ns.ReassertHiddenOnShow(bar)
            if bar.actionButtons and type(bar.actionButtons) == "table" then
                for _, child in pairs(bar.actionButtons) do
                    ns.QuietlyHideBlizzButton(child)
                end
            end
        end
    end
    -- ActionBarController retains all events so Blizzard's vehicle/override
    -- transition (ValidateActionBarTransition) works. MainMenuBarPageNumber is
    -- a legacy global absent on current clients; the live pager is
    -- MainActionBar's ActionBarPageNumber child, neutralised by KillPagerMouse.
    if MainMenuBarPageNumber then MainMenuBarPageNumber:Hide() end

    -- Replace ActionBar_PageUp/Down with versions that compute the target page
    -- and pass it to ChangeActionBarPage explicitly: stock versions derive it
    -- via GetActionBarPage(), and with MainMenuBar disabled the stock pipeline
    -- resets page to 1 after each change.
    --
    -- state-page is the RESOLVED page (7-14 in a form, vehicle, override or
    -- skyriding state), not the manual page, so cycling off it can walk out
    -- of the 1-6 range. Only trust it inside the manual range; otherwise ask
    -- Blizzard for the page the cycle actually moves, which is what
    -- ChangeActionBarPage writes.
    local function CurrentManualPage()
        local maxPages = NUM_ACTIONBAR_PAGES or 6
        local mainFrame = barFrames and barFrames["MainBar"]
        local curPage = mainFrame and tonumber(mainFrame:GetAttribute("state-page"))
        if not curPage or curPage < 1 or curPage > maxPages then
            curPage = EAB_VTABLE.GetActionBarPage() or 1
        end
        return curPage, maxPages
    end
    ActionBar_PageUp = function()
        local curPage, maxPages = CurrentManualPage()
        local newPage = curPage + 1
        if newPage > maxPages then newPage = 1 end
        ChangeActionBarPage(newPage)
    end
    ActionBar_PageDown = function()
        local curPage, maxPages = CurrentManualPage()
        local newPage = curPage - 1
        if newPage < 1 then newPage = maxPages end
        ChangeActionBarPage(newPage)
    end

    -- Hide status tracking bar manager (unless user wants Blizzard data bars)
    if not (EAB.db and EAB.db.profile.useBlizzardDataBars) then
        if StatusTrackingBarManager then
            StatusTrackingBarManager:UnregisterAllEvents()
            StatusTrackingBarManager:Hide()
        end
    end
    -- ActionBarParent is hidden at file load; OverrideActionBar visibility is fully
    -- owned by Blizzard's ValidateActionBarTransition(). No RegisterAttributeDriver on
    -- Blizzard-owned frames -- risks tainting protected state OverrideActionBar buttons
    -- inherit. Force all Blizzard action bars "enabled" via CVars so buttons work.
    EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_1", "1", "EllesmereUIActionBars")
    EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_2", "1", "EllesmereUIActionBars")
    EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_3", "1", "EllesmereUIActionBars")
    EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_4", "1", "EllesmereUIActionBars")

end

-------------------------------------------------------------------------------
--  Button Creation: all action bar buttons (slots 1-180) are our own
--  EABButton frames. Stance/Pet bars still reuse Blizzard buttons.
-------------------------------------------------------------------------------
local allButtons = {}   -- [actionSlot] = button
-- barButtons: forward-declared above (before SecureSetupHandler_PrepareRefs)
local buttonToBar = {}  -- [btn] = { barKey, index } for taint-safe slot resolution
local barFrames  = {}   -- [barKey] = secure header frame
local dataBarFrames = {} -- [barKey] = data bar frame (XP/Rep) populated later in SetupDataBars
local blizzMovableHolders = {} -- [barKey] = holder frame for Blizzard movable frames (ExtraAction, Encounter)
local extraBarHolders = {} -- [barKey] = holder frame for extra bars (MicroBar, BagBar)
local BLIZZ_MOVABLE_OVERLAY = { -- Fixed overlay sizes for unlock mode movers (not the actual Blizzard frames)
    ExtraActionButton = { w = 100, h = 100 },
    EncounterBar      = { w = 150, h = 40 },
}
local barBaseSize = {}  -- [barKey] = { w, h } original button size before any shape/scale

-- Action slot ranges per bar (see trailing comments). MUST match Blizzard's
-- internal slot assignments per button prefix (warcraft.wiki.gg/wiki/ActionSlot).
-- Slots 133-144 are reserved/unused. Stance bar uses StanceButton1-10 (not action slots).
local BAR_SLOT_OFFSETS = {
    MainBar = 0,    -- slots 1-12 (paged)
    Bar2 = 60,      -- slots 61-72  (MultiBarBottomLeft)
    Bar3 = 48,      -- slots 49-60  (MultiBarBottomRight)
    Bar4 = 24,      -- slots 25-36  (MultiBarRight)
    Bar5 = 36,      -- slots 37-48  (MultiBarLeft)
    Bar6 = 144,     -- slots 145-156 (MultiBar5)
    Bar7 = 156,     -- slots 157-168 (MultiBar6)
    Bar8 = 168,     -- slots 169-180 (MultiBar7)
    Bar9 = 12,      -- slots 13-24   (action page 2 -- custom bar)
    Bar10 = 108,    -- slots 109-120 (action page 10 -- custom bar, no native frame)
}

-- Binding name prefixes per bar: MULTIACTIONBAR<N>BUTTON, where N is Blizzard's
-- internal bar numbering (not our sequential bar IDs).
local BINDING_MAP = {
    MainBar = "ACTIONBUTTON",
    Bar2 = "MULTIACTIONBAR1BUTTON",
    Bar3 = "MULTIACTIONBAR2BUTTON",
    Bar4 = "MULTIACTIONBAR3BUTTON",
    Bar5 = "MULTIACTIONBAR4BUTTON",
    Bar6 = "MULTIACTIONBAR5BUTTON",
    Bar7 = "MULTIACTIONBAR6BUTTON",
    Bar8 = "MULTIACTIONBAR7BUTTON",
    -- Bar9/Bar10 have no native binding commands; custom commands defined in
    -- Bindings.xml route via SetOverrideBindingClick (keypress clicks our
    -- button, which reads the paged "action" attr).
    Bar9 = "EUI_BAR9_BUTTON",
    Bar10 = "EUI_BAR10_BUTTON",
    StanceBar = "SHAPESHIFTBUTTON",
    PetBar = "BONUSACTIONBUTTON",
}

-- Readable labels for the custom Bar9/Bar10 binding commands in Bindings.xml.
-- Global writes only (no file-scope locals); keybind UI reads
-- BINDING_HEADER_<header> for the section title, BINDING_NAME_<command> per row.
_G.BINDING_HEADER_EUI_BAR9  = "EllesmereUI Action Bar 9"
_G.BINDING_HEADER_EUI_BAR10 = "EllesmereUI Action Bar 10"
for i = 1, 12 do
    _G["BINDING_NAME_EUI_BAR9_BUTTON"  .. i] = "Action Bar 9 Button "  .. i
    _G["BINDING_NAME_EUI_BAR10_BUTTON" .. i] = "Action Bar 10 Button " .. i
end

-- Flyout system lives in EUI_ActionBars_Flyout.lua (loaded after this file).
-- All usage is event-driven, so we resolve the reference lazily.
local EABFlyout
local function GetEABFlyout()
    if not EABFlyout then EABFlyout = ns.EABFlyout end
    return EABFlyout
end

-------------------------------------------------------------------------------
--  Re-register events on action buttons that HideBlizzardBars unregistered.
--  These are what Blizzard's button mixins need for real-time icon, cooldown,
--  usability, and state updates.
-------------------------------------------------------------------------------
local BUTTON_EVENT_LISTS = {
    action = {
        "ACTIONBAR_UPDATE_STATE",
        "ACTIONBAR_UPDATE_USABLE",
        -- ACTIONBAR_UPDATE_COOLDOWN and ACTIONBAR_SLOT_CHANGED are deliberately NOT
        -- registered per button: assisted-combat dirties its slot ~11x/sec at total
        -- idle (dispatching to ~140 mixins ran the full cooldown path ~1500x/sec
        -- forever), and mouseover-conditional macros re-resolve on every mouseover flip
        -- (profiled ~7s CPU per 10s of cursor sweeps). The central dispatcher owns ALL
        -- cooldown painting, lazily creates btn.chargeCooldown, and runs UpdateAction +
        -- stale count clearing for slot changes instead.
        "PLAYER_ENTERING_WORLD",
        "UPDATE_SHAPESHIFT_FORM",
        "SPELL_UPDATE_CHARGES",
        "UPDATE_INVENTORY_ALERTS",
        "PLAYER_EQUIPMENT_CHANGED",
        "LOSS_OF_CONTROL_ADDED",
        "LOSS_OF_CONTROL_UPDATE",
        "PLAYER_TARGET_CHANGED", -- native per-button usability via Blizzard's C-side dispatcher
    },
    stance = {
        "UPDATE_SHAPESHIFT_FORMS",
        "UPDATE_SHAPESHIFT_FORM",
        "ACTIONBAR_PAGE_CHANGED",
        "PLAYER_ENTERING_WORLD",
        "UPDATE_SHAPESHIFT_COOLDOWN",
    },
    pet = {
        "PET_BAR_UPDATE",
        "PET_BAR_UPDATE_COOLDOWN",
        "PET_BAR_UPDATE_USABLE",
        "PLAYER_CONTROL_LOST",
        "PLAYER_CONTROL_GAINED",
        "PLAYER_FARSIGHT_FOCUS_CHANGED",
        "PLAYER_ENTERING_WORLD",
        "PET_BAR_SHOWGRID",
        "PET_BAR_HIDEGRID",
    },
}

local function ReRegisterButtonEvents(btn, listKey)
    for _, event in ipairs(BUTTON_EVENT_LISTS[listKey]) do
        EUI_SafeRegisterEvent(btn, event)
    end
    if listKey == "pet" then
        btn:RegisterUnitEvent("UNIT_PET", "player")
        btn:RegisterUnitEvent("UNIT_FLAGS", "pet")
    end
end

-- Bar dormancy strips this same list per button (see ns.ApplyBarDormancy;
-- the loop is inlined there -- this chunk is at the 200-local cap).

-- Get or create an action button for a slot. Action bars (1-8) always create
-- our own buttons, eliminating the taint surface: Blizzard's protected
-- buttons are never reused, so cross-addon taint can't propagate to
-- SetShown/Show/Hide. Stance bar still reuses Blizzard StanceButtons (own
-- secure handling); Pet bar is set up in SetupBar. skipProtected: skip
-- SetParent/Show (combat reload; the secure handler does those instead).
local function GetOrCreateButton(slot, parent, info, index, skipProtected)
    if allButtons[slot] then
        if not skipProtected then
            allButtons[slot]:SetParent(parent)
        end
        return allButtons[slot]
    end

    local btn
    if info.isStance then
        btn = _G["StanceButton" .. index] -- reuse Blizzard buttons (own secure stance handling)
        if btn and not skipProtected then
            btn:SetAttributeNoHandler("statehidden", nil)
            ReRegisterButtonEvents(btn, "stance")
            btn:SetParent(parent)
            btn:Show()
        end
    else
        -- Action bars: create our own button. ActionBarButtonTemplate
        -- inherits SecureActionButtonTemplate, so click dispatch, drag-and-
        -- drop, and the visual mixin (icon, cooldown, border) all work.
        -- Frames persist across /reload; reuse if already in _G.
        local name = "EABButton" .. slot
        btn = _G[name]
        if not btn then
            btn = CreateFrame("CheckButton", name, parent, "ActionBarButtonTemplate, SecureActionButtonTemplate")
            -- Neuter UpdateButtonArt: it resets NormalTexture/PushedTexture
            -- atlases on every call, causing mass GPU redraws across 96
            -- buttons. We handle art ourselves (MakeButtonSquare/ApplyPushedTextures).
            btn.UpdateButtonArt = function() end
        end
        -- Template OnLoad self-registers ACTIONBAR_SLOT_CHANGED and
        -- ACTIONBAR_UPDATE_COOLDOWN; the central dispatcher owns both (see
        -- BUTTON_EVENT_LISTS note) so the mixin's own handler is killed here
        -- -- it would run Update() under our execution taint (UpdateButtonArt
        -- neuter is a tainted field in that chain), erroring on secret
        -- cooldown args and blocking SetAttribute in combat.
        btn:UnregisterEvent("ACTIONBAR_SLOT_CHANGED")
        btn:UnregisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        -- Template OnLoad also registered this button with Blizzard's
        -- ActionBarButtonEventsFrame broadcaster; that tinsert ran under OUR
        -- execution, so the stored entry is a tainted value -- every dispatch
        -- (Blizzard's own untainted SLOT_CHANGED/PEW seeding, or the tick set
        -- while the vehicle/extra button shows) would read the entry, run the
        -- button's whole mixin OnEvent tainted and carry that taint through the
        -- rest of the loop (blocked SetAttribute, secret SetCooldown rejections
        -- in combat). UnregisterEvent can't stop this
        -- (broadcaster calls OnEvent directly) and wrapping btn.OnEvent would taint
        -- every per-button dispatch (template wires OnEvent by name, resolved at fire
        -- time). Instead nil our entry out of the list in place (never tremove --
        -- shifting would rewrite later Blizzard-owned entries as tainted). The button
        -- loses nothing: every event it needs is self-registered (BUTTON_EVENT_LISTS)
        -- or centrally dispatched.
        if ActionBarButtonEventsFrame and type(ActionBarButtonEventsFrame.frames) == "table" then
            -- The entry to remove is the one this button's template OnLoad
            -- just tinsert'd -- the array tail. Checking it directly keeps
            -- the 120-button build O(n) instead of O(n^2) over Blizzard's
            -- ~180-entry list (a real slice of the combat-reload watchdog
            -- budget); the full scan stays as the fallback for any exotic
            -- insertion order.
            local fr = ActionBarButtonEventsFrame.frames
            local tail = #fr
            if fr[tail] == btn then
                fr[tail] = nil
            else
                for k, f in pairs(fr) do
                    if f == btn then fr[k] = nil end
                end
            end
        end
        -- Desaturate-on-CD / on-CD alpha: re-evaluate the icon the moment the main
        -- cooldown display completes, since writes are static between events (a charge
        -- spell's recharge-end at 0 charges IS the main cooldown, exactly this edge) --
        -- without it the icon only recovers at the next cooldown event. Re-evaluates
        -- from live data so a GCD completing on a banked-charge spell is a no-op.
        -- HookScript, never SetScript (template's charge/LoC handling may own the
        -- slot); guarded because bar rebuilds reuse these frames and HookScript stacks.
        if btn.cooldown and not EFD(btn).cdDoneHooked then
            EFD(btn).cdDoneHooked = true
            btn.cooldown:HookScript("OnCooldownDone", function(cd)
                local b = cd:GetParent()
                if EAB._RefreshCooldownVisuals then
                    EAB._RefreshCooldownVisuals(b)
                end
                -- Recharge-numbers un-hide edge: a real main cooldown's END fires
                -- no bar event, so an occluded charge countdown had no owning edge
                -- to reappear on (it stranded hidden until the next unrelated
                -- pass). The display-complete edge is the exact moment occlusion
                -- lapses; nil-check cost for every non-charge button.
                if b and b.chargeCooldown and ns.UpdateChargeNumbersVisibility then
                    local action = b.GetAttribute and b:GetAttribute("action")
                    if action and HasAction(action) then
                        ns.UpdateChargeNumbersVisibility(b, b.chargeCooldown,
                            C_ActionBar.GetActionCooldown(action),
                            C_ActionBar.GetActionCharges(action))
                    end
                end
            end)
        end
        -- Hovering runs Blizzard's secure Update() (ForceButtonRefresh),
        -- resetting desaturation with no edge for the visuals memo to catch
        -- -- an on-CD icon flashed back to color until the next real cooldown
        -- event. Re-assert right after Blizzard's handler; RefreshCooldownVisuals
        -- early-outs when both features are off (two profile reads at hover
        -- rate). Guarded like the sibling above.
        if not EFD(btn).cdHoverHooked then
            EFD(btn).cdHoverHooked = true
            btn:HookScript("OnEnter", function(self)
                if EAB._RefreshCooldownVisuals then
                    EAB._RefreshCooldownVisuals(self)
                end
                -- Same Blizzard hover repaint also resets HotKey's text color
                -- to white (see ReapplyHotkeyColors above); OnEnter never fed
                -- the event-driven reassert, so a custom color reverted on
                -- every hover until the next unrelated ACTIONBAR_* event.
                -- Queue instead of reapplying inline: coalesces with any
                -- burst already pending and costs nothing when the bar is on
                -- the default white (see ReapplyHotkeyColors' early-out).
                EAB:QueueHotkeyColorReassert()
            end)
        end
        -- Physical-press GCD paint: keybinds arrive as clicks too
        -- (SetOverrideBindingClick), so PostClick fires at the actual press
        -- before any server round-trip; pushes the predicted cooldown and
        -- arms the press wave (ns._EABPressPush). Guarded as above.
        if not EFD(btn).cdClickHooked then
            EFD(btn).cdClickHooked = true
            -- Captured once: the command is a property of the BUTTON, not the
            -- slot it shows, so it survives page swaps (Bar 9 shares action
            -- page 2 with a paged MainBar, making slot-derived ambiguous).
            local pressBindCmd = BINDING_MAP[info.key]
            pressBindCmd = pressBindCmd and (pressBindCmd .. index) or nil
            btn:HookScript("PostClick", function(self, _, down)
                if ns._EABPressPush then ns._EABPressPush(self) end
                -- Publish for the CDM press mirror: click-routed keybinds never
                -- fire the native binding commands. Global rather than ns (the
                -- subscriber is a separate addon, like _EAB_UpdateKeybinds).
                local onPress = _G._EUI_OnActionButtonPress
                if onPress then onPress(self, down, pressBindCmd) end
            end)
        end
        -- When the pickup modifier is held (shift-click to move abilities),
        -- clear useOnKeyDown for the duration of that mouse click: the down
        -- edge never casts (a drag consumes the action instead), and a click
        -- without a drag casts on RELEASE -- matching Blizzard's buttons,
        -- which force useOnKeyDown off for hardware mouse clicks
        -- (SecureTemplates.lua) and so act on the up edge.
        -- MOUSE-ONLY via IsUnderMouse (rect test): keybinds ALSO arrive as
        -- OnClick (SetOverrideBindingClick dispatch for all bars), and a
        -- modified KEYBIND press must cast on its configured edge.
        -- The pre-body must return its message on the UP click and ONLY
        -- there: a wrap's post-body only executes when the pre returns a
        -- message (SecureHandlers.lua), so no message = the flip sticks
        -- (#1165's delayed presses / late GCD swipes), and a DOWN-edge
        -- message = the restore lands before the release and a shift-click
        -- casts on neither edge. Both shapes shipped and failed; keep the
        -- message on the up edge.
        -- eabPickupFlipped marks OUR flip: useOnKeyDown=false is also a
        -- legitimate user setting (press-and-hold casting), and the flag
        -- keeps the restore from ever forcing those users back to true.
        -- A drag consumes the up edge and strands the flip; the next down
        -- click (mouse or keybind) clears it BEFORE the native handler
        -- runs, so that press still acts on its configured edge.
        if not btn:GetAttribute("eabPickupWrap") and not InCombatLockdown() then
            btn:SetAttribute("eabPickupWrap", true)
            SecureHandlerWrapScript(btn, "OnClick", btn, [[
                local flipped = self:GetAttribute("eabPickupFlipped")
                if down then
                    if IsModifiedClick("PICKUPACTION") and self:IsUnderMouse() then
                        if self:GetAttribute("useOnKeyDown") ~= false then
                            self:SetAttribute("eabPickupFlipped", true)
                            self:SetAttribute("useOnKeyDown", false)
                        end
                    elseif flipped then
                        self:SetAttribute("eabPickupFlipped", false)
                        self:SetAttribute("useOnKeyDown", true)
                    end
                elseif flipped then
                    return nil, "restore"
                end
            ]], [[
                self:SetAttribute("eabPickupFlipped", false)
                self:SetAttribute("useOnKeyDown", true)
            ]])
        end
        if not skipProtected then
            btn:SetParent(parent)
            btn:SetID(0)
            btn:SetAttribute("action", slot)
        end
    end

    RegisterButtonWithController(btn)
    allButtons[slot] = btn
    return btn
end

local NUM_AB_PAGES = NUM_ACTIONBAR_PAGES or 6

-- Keybind routing: every standard-bar slot -- INCLUDING empowered spells --
-- binds to native commands, where the engine pairs press and release against
-- the physical key (hold-and-release, hold-to-cast repeat and queued empowers
-- are all engine-owned there). Only custom-paged bars and the custom bars
-- (no native command exists) route keys through the button via
-- SetOverrideBindingClick. pressAndHoldAction/typerelease stay maintained on
-- the buttons for MOUSE clicks on empowered slots.

-- Safe API wrappers (these globals may move to C_ActionBar); stored on
-- EAB_VTABLE to avoid the 200-local Lua 5.1 limit.
do
    local V = EAB_VTABLE
    V.GetOverrideBarIndex = GetOverrideBarIndex or (C_ActionBar and C_ActionBar.GetOverrideBarIndex) or function() return 14 end
    V.GetVehicleBarIndex = GetVehicleBarIndex or (C_ActionBar and C_ActionBar.GetVehicleBarIndex) or function() return 12 end
    V.GetActionBarPage = GetActionBarPage or (C_ActionBar and C_ActionBar.GetActionBarPage) or function() return 1 end
    V.HasVehicleActionBar = HasVehicleActionBar or (C_ActionBar and C_ActionBar.HasVehicleActionBar) or function() return false end
    V.HasOverrideActionBar = HasOverrideActionBar or (C_ActionBar and C_ActionBar.HasOverrideActionBar) or function() return false end
    V.HasTempShapeshiftActionBar = HasTempShapeshiftActionBar or (C_ActionBar and C_ActionBar.HasTempShapeshiftActionBar) or function() return false end
end

-------------------------------------------------------------------------------
--  Configurable Paging System: per-bar paging based on modifier keys and
--  class forms/stances. Empty paging config = bars behave exactly as before.
-------------------------------------------------------------------------------

-- Stored on EAB_VTABLE to avoid the 200-local Lua 5.1 limit.
EAB_VTABLE.BAR_KEY_TO_PAGE = {
    MainBar = 1,  Bar2 = 6,  Bar3 = 5,  Bar4 = 3,
    Bar5 = 4,     Bar6 = 13, Bar7 = 14, Bar8 = 15,
    Bar9 = 2,     Bar10 = 10,
}
EAB_VTABLE.PAGING_STATES = {
    modifier = {
        { id = "alt",   macro = "[mod:alt]",   label = "Alt" },
        { id = "shift", macro = "[mod:shift]", label = "Shift" },
        { id = "ctrl",  macro = "[mod:ctrl]",  label = "Ctrl" },
    },
    target = {
        { id = "help",  macro = "[help]",      label = "Friendly Target" },
        { id = "harm",  macro = "[harm]",      label = "Hostile Target" },
    },
    class = {
        DRUID = {
            { id = "prowl",   macro = "[bonusbar:1,stealth]", label = "Prowl" },
            { id = "cat",     macro = "[bonusbar:1]",         label = "Cat Form" },
            { id = "tree",    macro = "[bonusbar:2]",         label = "Tree of Life" },
            { id = "bear",    macro = "[bonusbar:3]",         label = "Bear Form" },
            { id = "moonkin", macro = "[bonusbar:4]",         label = "Moonkin Form" },
        },
        ROGUE = {
            { id = "stealth", macro = "[bonusbar:1]", label = "Stealth" },
        },
        WARRIOR = {
            { id = "battle",    macro = "[bonusbar:1]", label = "Battle Stance" },
            { id = "defensive", macro = "[bonusbar:2]", label = "Defensive Stance" },
        },
        EVOKER = {
            { id = "soar", macro = "[bonusbar:1]", label = "Soar" },
        },
    },
}

-- Auto-paging opt-outs for MainBar. Returns noForm, noSky: suppress implicit bonusbar
-- swaps for forms/stealth/stance (bonusbar 1-4) and skyriding (bonusbar 5). Does NOT
-- cover vehicle/override/possess -- those replace abilities outright, so suppressing
-- them would leave no way to use the vehicle. Only ever true for MainBar, the only bar
-- the engine drives off bonusbar and the only one with these toggles.
function EAB_VTABLE.GetAutoPagingOptOuts(barKey)
    if barKey ~= "MainBar" then return false, false end
    local bs = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars.MainBar
    if not bs then return false, false end
    return bs.disableFormPaging and true or false, bs.disableSkyridingPaging and true or false
end

function EAB_VTABLE.BuildPagingConditions(barKey, pagingConfig, defaultPage)
    if not pagingConfig or not next(pagingConfig) then return nil end
    local PG = EAB_VTABLE.PAGING_STATES
    local _, class = UnitClass("player")
    local noForm, noSky = EAB_VTABLE.GetAutoPagingOptOuts(barKey)
    local parts = {}
    if barKey == "MainBar" then
        if EAB_VTABLE.GetOverrideBarIndex then
            parts[#parts + 1] = "[overridebar] " .. EAB_VTABLE.GetOverrideBarIndex()
        end
        if EAB_VTABLE.GetVehicleBarIndex then
            parts[#parts + 1] = "[vehicleui][possessbar] " .. EAB_VTABLE.GetVehicleBarIndex()
        end
    end
    for _, state in ipairs(PG.modifier) do
        local page = pagingConfig[state.id]
        if page then
            parts[#parts + 1] = state.macro .. " " .. page
        end
    end
    -- MainBar falls back to hardcoded form pages for unconfigured (nil)
    -- states so setting a modifier doesn't break forms. false = user
    -- disabled ("None"), nil = unconfigured.
    local CLASS_DEFAULTS = {
        DRUID  = { prowl = 7, cat = 7, tree = 8, bear = 9, moonkin = 10 },
        ROGUE  = { stealth = 7 },
    }
    local classStates = PG.class[class]
    if classStates then
        -- noForm drops only the implicit fallback: a page the user picked for
        -- a specific form is explicit, not auto-paging, so it still applies.
        local defs = (barKey == "MainBar" and not noForm) and CLASS_DEFAULTS[class]
        for _, state in ipairs(classStates) do
            local page = pagingConfig[state.id]
            if page then
                parts[#parts + 1] = state.macro .. " " .. page
            elseif defs and defs[state.id] then
                -- nil and false both mean "no explicit page" (dropdown only
                -- offers Default or a bar; older saves stored false=Default).
                parts[#parts + 1] = state.macro .. " " .. defs[state.id]
            end
        end
    end
    -- WoW Forever and Classic Era: every class pages bar 1 by its stance/form offset
    -- (6 + offset), so the implicit fallback covers every offset after any explicit
    -- per-form pick.
    if barKey == "MainBar" and not noForm and (EllesmereUI.IS_FOREVER or EllesmereUI.IS_CLASSIC_ERA) then
        parts[#parts + 1] = "[bonusbar:1] 7; [bonusbar:2] 8; [bonusbar:3] 9; [bonusbar:4] 10"
    end
    -- Manual pages come before the skyriding clause: the engine only consults
    -- the bonus bar while Blizzard's page is 1 (ActionBarController_UpdateAll),
    -- so [bonusbar:5] listed first pinned the bar to the skyriding page and
    -- swallowed every manual page change until the player dismounted.
    -- The form clauses above deliberately keep their old precedence -- a page
    -- picked for a specific form in the dropdowns is an explicit request, and
    -- this path is click-routed, so the icon and the key agree either way.
    if barKey == "MainBar" then
        for i = 2, NUM_AB_PAGES do
            parts[#parts + 1] = "[bar:" .. i .. "] " .. i
        end
        if not noSky then
            parts[#parts + 1] = "[bonusbar:5] 11"
        end
    end
    -- Target conditions come after bonusbar/bar so dragonriding and manual
    -- page switches take priority over target-based switching.
    if PG.target then
        for _, state in ipairs(PG.target) do
            local page = pagingConfig[state.id]
            if page then
                parts[#parts + 1] = state.macro .. " " .. page
            end
        end
    end
    parts[#parts + 1] = tostring(defaultPage or 1)
    return table.concat(parts, "; ")
end

-------------------------------------------------------------------------------
--  Paging State Conditions (class-specific hardcoded fallback, used when no
--  custom paging is configured). Format: "[condition] pageNumber; ..."
-------------------------------------------------------------------------------
local function GetClassPagingConditions()
    local _, class = UnitClass("player")
    local noForm, noSky = EAB_VTABLE.GetAutoPagingOptOuts("MainBar")
    local conditions = ""

    -- Override bar (soft vehicle/quest abilities) and possess bar: remap bar
    -- 1 to those slots so our buttons stay visible and keybinds work.
    if EAB_VTABLE.GetOverrideBarIndex then
        conditions = conditions .. "[overridebar] " .. EAB_VTABLE.GetOverrideBarIndex() .. "; "
    end
    if EAB_VTABLE.GetVehicleBarIndex then
        conditions = conditions .. "[vehicleui][possessbar] " .. EAB_VTABLE.GetVehicleBarIndex() .. "; "
    end

    -- Manual page switching (pages 2-6): [bar:N] responds to the internal page set by
    -- ChangeActionBarPage() (built-in keybinds + our arrows). Listed BEFORE class form
    -- conditions to match the engine's native resolution order (manual page beats form
    -- bonusbar, which only applies on page 1). MainBar keybinds are native
    -- ACTIONBUTTONn commands, so the displayed page must resolve exactly like the
    -- engine's or a form + manual-page combo shows one ability and fires another.
    -- (Auto-paging opt-outs deliberately break from this -- why they force keys off
    -- ACTIONBUTTONn onto the click route; see UpdateKeybinds pass 1.)
    for i = 2, NUM_AB_PAGES do
        conditions = conditions .. "[bar:" .. i .. "] " .. i .. "; "
    end

    -- Class-specific form paging (page 1 only, per the ordering above)
    if not noForm then
        if EllesmereUI.IS_FOREVER or EllesmereUI.IS_CLASSIC_ERA then
            -- WoW Forever and Classic Era page bar 1 natively by the stance/form offset for
            -- EVERY class (vanilla warrior stances, druid forms, rogue stealth): page 6 + offset.
            -- Mirror it exactly so ACTIONBUTTONn and the icon agree in every stance.
            conditions = conditions .. "[bonusbar:1] 7; [bonusbar:2] 8; [bonusbar:3] 9; [bonusbar:4] 10; "
        elseif class == "DRUID" then
            conditions = conditions .. "[bonusbar:1,stealth] 7; [bonusbar:1] 7; [bonusbar:3] 9; [bonusbar:4] 10; "
        elseif class == "ROGUE" then
            conditions = conditions .. "[bonusbar:1] 7; "
        end
    end

    -- Dragonriding (all classes; page 1 only, same rule as the forms above)
    if not noSky then
        conditions = conditions .. "[bonusbar:5] 11; "
    end

    -- Default: page 1
    conditions = conditions .. "1"

    return conditions
end

-------------------------------------------------------------------------------
--  Action Bar 1 Paging Arrows + Page Number
-------------------------------------------------------------------------------
local _pagingFrame    -- forward ref
local LayoutPagingFrame  -- forward ref (used inside SetupPagingFrame closure)

-- The paging frame is parented to MainBar (see LayoutPagingFrame), so it
-- inherits the bar's mouseover-fade alpha AND secure show/hide automatically;
-- own alpha stays 1 so the parent governs solely (no double-fade).
local function SyncPagingAlpha()
    if _pagingFrame then _pagingFrame:SetAlpha(1) end
end

-- Paging arrows use SecureActionButtonTemplate type "macro"; [bar:N]
-- conditionals cycle pages statically, no dynamic attribute changes needed.
local _macroNext = "/changeactionbar [bar:6] 1"
local _macroPrev = "/changeactionbar [bar:1] 6"
for i = 1, NUM_AB_PAGES - 1 do
    _macroNext = _macroNext .. "; [bar:" .. i .. "] " .. (i + 1)
    _macroPrev = _macroPrev .. "; [bar:" .. (i + 1) .. "] " .. i
end

local function WireSecurePagingButton(btn, delta)
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", delta > 0 and _macroNext or _macroPrev)
end

local function InitPagingQuickKeybindButton(btn, atlas)
    if not btn then return end

    if not btn.QuickKeybindHighlightTexture then
        local tex = btn:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(btn)
        tex:SetAtlas(atlas)
        tex:SetAlpha(0.8)
        tex:Hide()
        btn.QuickKeybindHighlightTexture = tex
    end

    if EFD(btn).quickKeybindInit or not QuickKeybindButtonTemplateMixin then
        return
    end

    Mixin(btn, QuickKeybindButtonTemplateMixin)
    btn:HookScript("OnShow", btn.QuickKeybindButtonOnShow)
    btn:HookScript("OnHide", btn.QuickKeybindButtonOnHide)
    btn:HookScript("OnClick", btn.QuickKeybindButtonOnClick)
    btn:HookScript("OnEnter", btn.QuickKeybindButtonOnEnter)
    btn:HookScript("OnLeave", btn.QuickKeybindButtonOnLeave)
    EFD(btn).quickKeybindInit = true
    -- Do NOT call btn:QuickKeybindButtonOnShow() eagerly here. It registers
    -- persistent EventRegistry callbacks that fire UpdateMouseWheelHandler
    -- (and thus SetScript) on a SecureActionButtonTemplate frame on every
    -- QKB mode change. The HookScript("OnShow") handles runtime visibility.
end

local function SetupPagingFrame()
    if _pagingFrame then return _pagingFrame end

    local f = CreateFrame("Frame", "EABPagingFrame", UIParent)
    f:SetSize(20, 52)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(10)

    -- Page number text
    local pageText = f:CreateFontString(nil, "OVERLAY")
    pageText:SetFont(STANDARD_TEXT_FONT, 12, (EllesmereUI.SlugFlag("OUTLINE, SLUG")) or "OUTLINE, SLUG")
    pageText:SetTextColor(1, 1, 1, 0.9)
    pageText:SetText("1")
    f._pageText = pageText

    -- Own secure macrotext (WireSecurePagingButton), NOT Blizzard's
    -- ActionBarUpButton -- Blizzard's pager buttons are mouse-dead (KillPagerMouse).
    local upBtn = CreateFrame("Button", "EABPagingUp", f, "SecureActionButtonTemplate")
    upBtn:SetSize(18, 18)
    upBtn:RegisterForClicks("AnyUp", "AnyDown")
    upBtn:SetNormalAtlas("UI-HUD-ActionBar-PageUpArrow-Up")
    upBtn:SetPushedAtlas("UI-HUD-ActionBar-PageUpArrow-Down")
    upBtn:SetDisabledAtlas("UI-HUD-ActionBar-PageUpArrow-Disabled")
    upBtn:SetHighlightAtlas("UI-HUD-ActionBar-PageUpArrow-Mouseover")
    f._upBtn = upBtn
    InitPagingQuickKeybindButton(upBtn, "UI-HUD-ActionBar-PageUpArrow-Mouseover")

    -- same: own secure macrotext, not Blizzard's button
    local downBtn = CreateFrame("Button", "EABPagingDown", f, "SecureActionButtonTemplate")
    downBtn:SetSize(18, 18)
    downBtn:RegisterForClicks("AnyUp", "AnyDown")
    downBtn:SetNormalAtlas("UI-HUD-ActionBar-PageDownArrow-Up")
    downBtn:SetPushedAtlas("UI-HUD-ActionBar-PageDownArrow-Down")
    downBtn:SetDisabledAtlas("UI-HUD-ActionBar-PageDownArrow-Disabled")
    downBtn:SetHighlightAtlas("UI-HUD-ActionBar-PageDownArrow-Mouseover")
    f._downBtn = downBtn
    InitPagingQuickKeybindButton(downBtn, "UI-HUD-ActionBar-PageDownArrow-Mouseover")

    -- Update page text and handle combat visibility / vehicle state
    f:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
    f:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
    EUI_SafeRegisterEvent(f, "UPDATE_OVERRIDE_ACTIONBAR")
    EUI_SafeRegisterEvent(f, "UPDATE_VEHICLE_ACTIONBAR")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(_, event)
        if event == "UPDATE_OVERRIDE_ACTIONBAR" or event == "UPDATE_VEHICLE_ACTIONBAR" then
            LayoutPagingFrame()
            -- Trigger page sync; the Queue callback early-returns in combat,
            -- so the sync only runs out of combat.
            EAB_VTABLE.MainBarPageSync.Queue()
            return
        end
        if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            local s = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars and EAB.db.profile.bars["MainBar"]
            if s and not InCombatLockdown() then
                local inCombat = (event == "PLAYER_REGEN_DISABLED")
                if s.combatShowEnabled then
                    if inCombat then f:Show() else f:Hide() end
                elseif s.combatHideEnabled then
                    if inCombat then f:Hide() else f:Show() end
                end
            end
            return
        end
        local page = EAB_VTABLE.GetActionBarPage()
        pageText:SetText(tostring(page))
        -- Trigger page sync for manual page changes, form changes, etc.
        EAB_VTABLE.MainBarPageSync.Queue()
    end)

    local initPage = EAB_VTABLE.GetActionBarPage()
    pageText:SetText(tostring(initPage))

    WireSecurePagingButton(upBtn, 1)
    WireSecurePagingButton(downBtn, -1)
    upBtn.commandName = "NEXTACTIONPAGE"
    downBtn.commandName = "PREVIOUSACTIONPAGE"

    _pagingFrame = f
    ns._PagingFrameBind(f)
    return f
end

LayoutPagingFrame = function()
    local f = _pagingFrame
    if not f then return end
    if InCombatLockdown() then return end
    local mainFrame = barFrames and barFrames["MainBar"]
    if not mainFrame then f:Hide(); return end

    local s = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars and EAB.db.profile.bars["MainBar"]
    if not s then f:Hide(); return end

    -- Parenting to MainBar makes it inherit secure show/hide + mouseover-fade
    -- alpha automatically, including in combat. Reparenting secure children is
    -- blocked in combat, hence the InCombatLockdown gate above.
    if f:GetParent() ~= mainFrame then
        f:SetParent(mainFrame)
        f:SetFrameStrata("MEDIUM")
        f:SetAlpha(1)
    end
    -- Five levels over the bar, and one over its end caps while they can show
    -- (retail's page arrows sit over its caps).
    local caps = s.orientation ~= "vertical" and ns.AB_CAPS[ns.AB_CapsLook("MainBar") or "-"]
    local lvl = (mainFrame:GetFrameLevel() or 1) + 1 + (caps and caps.lvl or 4)
    if f:GetFrameLevel() ~= lvl then f:SetFrameLevel(lvl) end

    if s.alwaysHidden or s.enabled == false or not s.showPagingArrows then
        f:Hide()
        return
    end

    -- Hide during vehicle/override (paging doesn't apply)
    local overridePage = mainFrame:GetAttribute("state-overridepage") or 0
    if overridePage > 0 then
        f:Hide()
        return
    end

    local isVertical = (s.orientation == "vertical")
    local base = barBaseSize and barBaseSize["MainBar"]
    local btnH = (s.buttonHeight and s.buttonHeight > 0) and s.buttonHeight or (base and base.h or 45)
    local arrowSize = math.max(14, math.floor(btnH * 0.4))
    local textSize = math.max(10, math.floor(arrowSize * 0.7))
    local gap = 2

    f._upBtn:SetSize(arrowSize, arrowSize)
    f._downBtn:SetSize(arrowSize, arrowSize)
    f._pageText:SetFont(STANDARD_TEXT_FONT, textSize, (EllesmereUI.SlugFlag("OUTLINE, SLUG")) or "OUTLINE, SLUG")

    f._upBtn:ClearAllPoints()
    f._downBtn:ClearAllPoints()
    f._pageText:ClearAllPoints()

    local onRight = s.pagingArrowsRight

    if isVertical then
        local totalW = arrowSize + gap + textSize * 2 + gap + arrowSize
        f:SetSize(totalW, arrowSize)
        f:ClearAllPoints()
        if onRight then
            f:SetPoint("TOP", mainFrame, "BOTTOM", 0, -4)
        else
            f:SetPoint("BOTTOM", mainFrame, "TOP", 0, 4)
        end
        f._downBtn:SetPoint("LEFT", f, "LEFT", 0, 0)
        f._pageText:SetPoint("CENTER", f, "CENTER", 0, 0)
        f._upBtn:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    else
        local totalH = arrowSize + gap + textSize + gap + arrowSize
        f:SetSize(arrowSize, totalH)
        f:ClearAllPoints()
        if onRight then
            f:SetPoint("LEFT", mainFrame, "RIGHT", 4, 0)
        else
            f:SetPoint("RIGHT", mainFrame, "LEFT", -4, 0)
        end
        f._upBtn:SetPoint("TOP", f, "TOP", 0, 0)
        f._pageText:SetPoint("CENTER", f, "CENTER", 0, 0)
        f._downBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 0)
    end

    f:Show()
end
ns.LayoutPagingFrame = LayoutPagingFrame

-- Secure snippet appended to each button's _childupdate-eab-page handler (and
-- reused as the _childupdate-eab-empower handler): after the action attr
-- changes on a page swap, re-evaluate pressAndHoldAction for empowered /
-- hold-release spells. IsPressHoldReleaseSpell and GetActionInfo exist in the
-- restricted environment even though gone from _G (GetActionInfo as a
-- scrubbing wrapper, RestrictedEnvironment.lua). On ns: 200-local chunk cap.
--
-- Writes pressAndHoldAction ONLY (like Blizzard's UpdatePressAndHoldAction),
-- and only on a POSITIVE identity read: a slot whose identity is unreadable
-- at snippet time KEEPS its current value -- see the decision trailer inside.
-- It must NOT touch typerelease: Blizzard sets that to "actionrelease" once
-- in the mixin's OnLoad and never clears it, and SecureTemplates reads it on
-- EVERY key release when the ActionButtonUseKeyHeldSpell CVar is on, not just
-- for empowered spells (releasePressAndHoldAction = (not down) and
-- (pressAndHoldAction or CVar)). Clearing it on non-empower buttons would
-- leave those users' key-up path with no action type at all.
-- (2026-08-09: a [channeling]-gated typerelease disarm was field-tested on
-- live against the rank-1 queued-release latch and REVERTED -- it did not
-- stop the early release; the fix was routing empower KEYS native instead.
-- Do not re-attempt that shape without new field data.)
ns._eabEmpowerSnippet = [[
    local slot = self:GetAttribute('action')
    if slot and IsPressHoldReleaseSpell then
        local actionType, id, subType = GetActionInfo(slot)
        local spellID = nil
        if actionType == 'spell' then
            spellID = id
        elseif actionType == 'macro' and subType == 'spell' then
            spellID = id
        end
        if spellID then
            if IsPressHoldReleaseSpell(spellID) then
                self:SetAttribute('pressAndHoldAction', true)
            else
                self:SetAttribute('pressAndHoldAction', false)
            end
        elseif actionType and actionType ~= 'spell' and actionType ~= 'macro' then
            self:SetAttribute('pressAndHoldAction', false)
        end
    end
]]
-- Decision trailer for the snippet above: a readable spell identity decides
-- true/false exactly as before, and a positively non-spell action (item,
-- companion, ...) is never hold-release. EVERYTHING ELSE -- an empty slot, a
-- scrubbed in-combat read, or a macro not currently resolving to a spell
-- (mouseover macros flip constantly) -- KEEPS the current attribute. This
-- snippet runs SECURELY during combat page swaps (bonusbar/override flips in
-- encounters), where the restricted GetActionInfo read cannot be trusted to
-- see the spell: writing false there stripped hold-release from empowered
-- slots mid-fight, which presents as the Empowered Spell Input setting
-- flipping to Press-and-Tap. A stale TRUE on the other hand is inert: the
-- key-up actionrelease it allows is the same no-op every
-- Press-and-Hold-Casting key-up already fires on non-empower actions, and
-- native-routed keys never reach the button at all. The out-of-combat
-- re-checks (pass 3 of UpdateKeybinds, the combat-drop re-assert) correct
-- any kept value as soon as identity is readable again.

-- Un-park a slot that "Always Show Buttons" off left hidden. Parking writes
-- four things (alpha 0, mouse off, statehidden, Hide) and un-parking must undo
-- all four -- but EnableMouse on a protected button is combat-blocked, so
-- SafeEnableMouse silently returns and the insecure pass can only restore the
-- three unprotected ones. A form or page flip that fills the slot mid-combat
-- therefore left the button VISIBLE (alpha is unprotected) yet deaf to hover
-- and clicks, while keybinds -- which route through override bindings and need
-- no mouse -- kept working (reported: druid stance change in combat).
--
-- The restore cannot come from the OnShow -> UpdateShown wrapper: that snippet
-- gates on not IsShown(), and OnShow fires after the frame is already shown.
-- It has to happen here, before the Show. Gated on the hidden->shown edge so a
-- live on-cooldown alpha on an already-visible button is never stomped, and on
-- eab-click so a reveal never makes a click-through bar clickable.
ns._eabPageUnparkSnippet = [[
if not self:IsShown() then
    self:SetAlpha(1)
    if (self:GetAttribute('eab-click') or 1) ~= 0 then
        self:EnableMouse(true)
    end
end
]]

-- Build the _childupdate-eab-page snippet for a button at the given 1-based bar
-- index. On a page change: action = baseIndex + (page-1)*12, re-evaluate parked
-- visibility, then re-check hold-release. ALL install sites (SetupBar,
-- RebuildBarPaging) call this so the handler is byte-identical everywhere --
-- the page change rewrites the secure "action" attribute (our buttons are
-- ID=0, so actionpage is never consulted).
--
-- The visibility half is gated on eab-showempty EXISTING: it is stamped by
-- ApplyAlwaysShowButtons out of combat, and a button that has never seen a
-- stamp keeps the pre-existing behaviour (action only, visibility left to the
-- controller's deferred UpdateShown) rather than guessing at a default.
ns._eabPageVisSnippet = [[
local showEmpty = self:GetAttribute('eab-showempty')
if showEmpty then
    local withinCutoff = self:GetAttribute('eab-withincutoff') ~= 0
    local visible = withinCutoff
    if visible and showEmpty == 0 then
        visible = HasAction(slot)
    end
    -- A transient grid reveal outranks the empty-slot park, exactly as
    -- UpdateShown does: a page flip during a combat spell drag must not
    -- delete the drop targets under the cursor. Bits 2+ only -- bit 1 is
    -- Blizzard's CVAR reason and is not a transient reveal. statehidden is
    -- cleared only for a genuinely filled slot, so drag end still re-parks.
    local grid = self:GetAttribute('showgrid') or 0
    local transient = withinCutoff and (grid % 32) >= 2
    if visible or transient then
        if visible and self:GetAttribute('statehidden') then
            self:SetAttribute('statehidden', nil)
        end
]] .. ns._eabPageUnparkSnippet .. [[
        self:Show(true)
    else
        if not self:GetAttribute('statehidden') then
            self:SetAttribute('statehidden', true)
        end
        self:Hide(true)
    end
end
]]

function ns._eabBuildPageChildSnippet(baseIndex)
    return ("local page = tonumber(message) or 1; local slot = %d + (page - 1) * 12; self:SetAttribute('action', slot)\n"):format(baseIndex)
        .. ns._eabPageVisSnippet .. ns._eabEmpowerSnippet
end

-------------------------------------------------------------------------------
--  Secure Bar Frame Creation
--  Each bar gets a SecureHandlerStateTemplate frame. Our buttons are created
--  with SetID(0) + an explicit "action" attribute, so CalculateAction resolves
--  the slot from that attribute (path 2), NOT from actionpage. Paging works by
--  the bar's _onstate-page handler doing ChildUpdate("eab-page", page), and each
--  button's _childupdate-eab-page snippet rewriting its "action" attribute. The
--  frame "actionpage" attribute is kept only for insecure range-check reads.
-------------------------------------------------------------------------------
local function CreateBarFrame(info)
    local key = info.key
    local frame = CreateFrame("Frame", "EABBar_" .. key, UIParent, "SecureHandlerStateTemplate")
    frame:SetSize(1, 1)
    frame:SetPoint("CENTER")
    -- Render above any Blizzard bar art that might bleed through
    frame:SetFrameLevel(math.max(frame:GetFrameLevel(), 10))
    -- Bar frames never intercept clicks (only buttons do); motion is enabled
    -- later by the hover system for OnEnter/OnLeave.
    if frame.SetMouseClickEnabled then
        frame:SetMouseClickEnabled(false)
    end
    frame._barKey = key
    frame._barInfo = info

    if key == "MainBar" then
        -- MainBar paging: the state driver evaluates conditions (forms,
        -- vehicle, override, possess, bonus bars, modifiers); _onstate-page
        -- runs ChildUpdate("eab-page", page), and each button's
        -- _childupdate-eab-page rewrites action = baseIndex + (page-1)*12.
        local barSettings = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars[key]
        local customPaging = barSettings and barSettings.paging
        local pagingConditions
        if customPaging and next(customPaging) then
            pagingConditions = EAB_VTABLE.BuildPagingConditions("MainBar", customPaging, 1)
        else
            -- No custom paging: use hardcoded class defaults (zero impact)
            pagingConditions = GetClassPagingConditions()
        end

        -- Mark MainBar as the override bar target so the override controller
        -- propagates vehicle/override/petbattle state changes.
        frame:SetAttribute("state-overridebar", true)

        -- Propagate page state to actionpage in the restricted environment so
        -- it stays untainted. The same write goes to MainActionBar: the native
        -- ACTIONBUTTONn keys fire Blizzard's ActionButton1-12, which resolve
        -- their slot from that frame's actionpage at click time, and Blizzard's
        -- own writer (ActionBarController_UpdateAll) cannot be relied on once
        -- the stock bars are disposed, so without the mirror a key can fire a
        -- page the icon does not show. The secure ChildUpdate is
        -- the missing half of the paging contract: each button gets an
        -- attribute change so OnAttributeChanged -> UpdateAction re-evaluates
        -- the derived slot even in combat. NEVER CallMethod here: vehicle/
        -- override transitions evaluate all state drivers in one secure pass,
        -- and CallMethod exits to insecure Lua mid-pass, tainting the context
        -- -- Blizzard's ActionBarController drivers in the same pass inherit
        -- it and OverrideActionBar:Show() hits ADDON_ACTION_BLOCKED. Page
        -- sync instead rides ACTIONBAR_PAGE_CHANGED (paging frame OnEvent).
        frame:SetFrameRef("blizzmainbar", MainActionBar)
        frame:SetAttributeNoHandler("_onstate-page", [[
            local page = tonumber(newstate) or 1
            self:SetAttribute("actionpage", page)
            self:ChildUpdate("eab-page", page)
            self:GetFrameRef("blizzmainbar"):SetAttribute("actionpage", page)
        ]])

        RegisterStateDriver(frame, "page", pagingConditions)
    end

    -- Bars 2-8 (nativeActionPage) and 9-10 (customPage): buttons have static action
    -- attrs set in SetupBar pointing at the bar's default page. Custom paging installs
    -- a state driver + ChildUpdate to recalculate the action attr on page change --
    -- identical machinery either way, differing only in the default page source.
    local defaultPage = info.nativeActionPage or info.customPage
    if defaultPage then
        frame:Execute(("self:SetAttribute('actionpage', %d)"):format(defaultPage))

        -- Configurable paging: install a state driver on top of the default
        -- page; when no conditions match, fall back to the bar's default.
        local barSettings = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars[key]
        local customPaging = barSettings and barSettings.paging
        if customPaging and next(customPaging) then
            frame:SetAttributeNoHandler("_onstate-page", [[
                local page = tonumber(newstate) or 1
                self:SetAttribute("actionpage", page)
                self:ChildUpdate("eab-page", page)
            ]])
            frame._eabPagingInstalled = true
            local conditions = EAB_VTABLE.BuildPagingConditions(key, customPaging, defaultPage)
            if conditions then
                RegisterStateDriver(frame, "page", conditions)
            end
        end
    end

    barFrames[key] = frame

    -- Empower re-check: setting "state-eabempower" dispatches ChildUpdate to
    -- re-evaluate pressAndHoldAction on all children. MUST be an _onstate-
    -- handler on a state- attribute: these bars are SecureHandlerStateTemplate,
    -- whose dispatcher only matches "^state%-(.+)" -> "_onstate-<id>". No
    -- _onattributechanged path exists here (that's SecureHandlerAttributeTemplate,
    -- i.e. OverrideController); a plain-attribute trigger fires NOTHING.
    frame:SetAttributeNoHandler("_onstate-eabempower", [[
        self:ChildUpdate("eab-empower", "")
    ]])

    -- Secure visibility: show/hide even in combat by setting the state
    -- attribute directly. RegisterStateDriver installs the snippet at
    -- creation (out of combat); later SetAttribute("state-eabvis", "hide")
    -- triggers it from the secure environment.
    frame:SetAttribute("_onstate-eabvis", [[
        if newstate == "hide" then
            self:Hide()
        else
            self:Show()
        end
    ]])
    -- If always-hidden or disabled, start hidden so the secure snippet hides
    -- it immediately, before combat can return after a brief reload regen.
    local s = EAB.db and EAB.db.profile.bars[key]
    local startHidden = s and (s.alwaysHidden or s.enabled == false)
    RegisterStateDriver(frame, "eabvis", startHidden and "hide" or "show")

    -- Register with the override controller so vehicle/override/petbattle
    -- state changes propagate to this bar frame.
    RegisterBarWithOverrideController(frame)

    -- Register with secure handler so it can reparent buttons to this frame
    SecureSetupHandler_RegisterBarFrame(key, frame)
    -- Custom modifier paging rewrites button action attrs from a SECURE state
    -- driver, no dispatcher event exists. The driver's "state-page" write
    -- fires this frame's insecure OnAttributeChanged -- the one clean owning
    -- edge to retire the filled lists and slot->button map so the next
    -- cooldown pass rebuilds against the new mapping.
    frame:HookScript("OnAttributeChanged", function(_, name)
        if name == "state-page" then
            ns._cdFilledDirty = true
            ns._slotBtnMapDirty = true
            ns._cdDirtyUntil = GetTime() + 2
        end
    end)

    -- Bar dormancy edges. OnShow/OnHide fire on EFFECTIVE visibility, secure
    -- driver flips included, and the dormancy handler is all unprotected API,
    -- so both edges are combat-legal. Buttons don't exist yet at creation
    -- time (handler no-ops until they do); FinishSetup's initial sync covers
    -- bars that START hidden (their OnHide never fires).
    frame:HookScript("OnShow", function(f)
        if ns.ApplyBarDormancy then ns.ApplyBarDormancy(f._barKey, false) end
    end)
    frame:HookScript("OnHide", function(f)
        if ns.ApplyBarDormancy then ns.ApplyBarDormancy(f._barKey, true) end
    end)
    return frame
end

-- Rebuild the paging state driver for a bar after settings change. Called from the
-- options panel when the user modifies paging config. Must be called out of combat.
function ns.RebuildBarPaging(barKey)
    if InCombatLockdown() then return end
    local frame = barFrames[barKey]
    if not frame then return end
    local info = frame._barInfo
    if not info then return end
    local barSettings = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars[barKey]
    local customPaging = barSettings and barSettings.paging

    if barKey == "MainBar" then
        local pagingConditions
        if customPaging and next(customPaging) then
            pagingConditions = EAB_VTABLE.BuildPagingConditions("MainBar", customPaging, 1)
        else
            pagingConditions = GetClassPagingConditions()
        end
        -- Force re-evaluation by unregistering first
        UnregisterStateDriver(frame, "page")
        RegisterStateDriver(frame, "page", pagingConditions)
    elseif info.nativeActionPage or info.customPage then
        local defaultPage = info.nativeActionPage or info.customPage
        if customPaging and next(customPaging) then
            -- Install handler if not already present
            if not frame._eabPagingInstalled then
                frame:SetAttributeNoHandler("_onstate-page", [[
                    local page = tonumber(newstate) or 1
                    self:SetAttribute("actionpage", page)
                    self:ChildUpdate("eab-page", page)
                ]])
                frame._eabPagingInstalled = true
                -- Must set the secure "action" attr (buttons are ID=0, so
                -- CalculateAction never consults "actionpage"). Same builder
                -- as SetupBar so paging added live behaves identically -- no /reload needed.
                local btns = barButtons[barKey]
                if btns then
                    for idx, btn in ipairs(btns) do
                        if not btn:GetAttribute("_childupdate-eab-page") then
                            btn:SetAttributeNoHandler("_childupdate-eab-page", ns._eabBuildPageChildSnippet(idx))
                        end
                    end
                end
            end
            local conditions = EAB_VTABLE.BuildPagingConditions(barKey, customPaging, defaultPage)
            if conditions then
                UnregisterStateDriver(frame, "page")
                RegisterStateDriver(frame, "page", conditions)
            end
        else
            -- No paging configured: remove state driver, restore fixed page
            UnregisterStateDriver(frame, "page")
            frame:Execute(("self:SetAttribute('actionpage', %d)"):format(defaultPage))
        end
    end

    -- Keybind routing derives from paging config (UpdateKeybinds pass 1):
    -- custom paging and auto-paging opt-outs both force click-routed keys.
    -- Rebuild now since toggling a paging setting fires no binding event
    -- (waiting on UPDATE_BINDINGS could wait forever); the signature diff
    -- makes this a no-op when routing didn't change, and UpdateKeybinds
    -- re-arms itself out of combat, so calling it unconditionally is safe.
    if _G._EAB_UpdateKeybinds then _G._EAB_UpdateKeybinds() end
end


-------------------------------------------------------------------------------
--  Bar Setup creates frames and buttons for each bar
-------------------------------------------------------------------------------
-- Build a bar's buttons into an EXISTING bar frame and record its base size.
-- Split out of SetupBar so a bar whose buttons were skipped at load can have
-- them built later, at the reveal edge: CreateBarFrame always creates a frame,
-- so re-running SetupBar there would leave a second one behind.
-- On ns rather than a file local: this file is at Lua 5.1's 200-local cap for
-- the main chunk, and a second top-level local here overflows it.
ns.BuildBarButtons = function(info, frame, skipProtected)
    -- Shrink the clickable area to match a custom visual shape so a square
    -- hit rect can't steal clicks from diamond/circle/etc neighbours. Insets
    -- are a fraction of button size; "none" resets to full square.
    -- Out-of-combat only (SetHitRectInsets on a protected button is unsafe
    -- in combat), behind the same not-skipProtected guard as SetParent.
    local function ApplyShapeHitRects(btn, shape)
        if not btn then return end
        local w, h = btn:GetSize()
        if not w or w == 0 then w = 45 end
        if not h or h == 0 then h = 45 end
        local insetX, insetY = 0, 0
        if shape == "diamond" or shape == "circle" then
            insetX = math.floor(w * 0.146)
            insetY = math.floor(h * 0.146)
        elseif shape == "hexagon" then
            insetX = math.floor(w * 0.12)
            insetY = math.floor(h * 0.12)
        elseif shape == "shield" then
            insetX = math.floor(w * 0.10)
            insetY = math.floor(h * 0.15)
        end
        btn:SetHitRectInsets(insetX, insetX, insetY, insetY)
    end

    local key = info.key
    local buttons = {}
    -- The layout shape: stock styles draw no custom shape, so their hit rects stay full.
    local buttonShape = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars[key]
        and ns.AB_LayoutShape(EAB.db.profile.bars[key]) or "none"

    if info.isStance then
        -- Stance bar: reuse StanceButton1-N
        for i = 1, info.count do
            local btn = _G["StanceButton" .. i]
            if btn then
                if not skipProtected then
                    ApplyShapeHitRects(btn, buttonShape)
                    btn:SetAttributeNoHandler("statehidden", nil)
                    ReRegisterButtonEvents(btn, "stance")
                    btn:SetParent(frame)
                end
                buttons[i] = btn
            end
        end
    elseif info.isPetBar then
        -- Pet bar: reuse PetActionButton1-N
        for i = 1, info.count do
            local btn = _G["PetActionButton" .. i]
            if btn then
                if not skipProtected then
                    ApplyShapeHitRects(btn, buttonShape)
                    btn:SetAttributeNoHandler("statehidden", nil)
                    ReRegisterButtonEvents(btn, "pet")
                    btn:SetParent(frame)
                end
                buttons[i] = btn
                -- Hook drag handlers so spellbook drops work even though
                -- the original PetActionBar is hidden and unregistered.
                btn:HookScript("OnReceiveDrag", function(self)
                    if InCombatLockdown() then return end
                    -- Blizzard's mixin handler runs first; fall back to
                    -- PickupPetAction if it didn't fire. The resulting
                    -- PET_BAR_UPDATE triggers our full refresh automatically.
                    local cType = GetCursorInfo()
                    if cType == "petaction" then
                        PickupPetAction(self:GetID())
                    end
                end)
            end
        end
    else
        -- Action bars (never stance/pet in this branch): our own EABButtons.
        local slotOffset = BAR_SLOT_OFFSETS[key] or 0
        for i = 1, info.count do
            local slot = slotOffset + i
            local btn = GetOrCreateButton(slot, frame, info, i, skipProtected)
            if btn then
                local bindPrefix = BINDING_MAP[key]
                if not skipProtected then
                    ApplyShapeHitRects(btn, buttonShape)
                    -- Explicit action attr: CalculateAction sees it non-zero
                    -- and returns it directly (path 2).
                    btn:SetAttribute("action", slot)
                    if bindPrefix then
                        btn:SetAttributeNoHandler("binding", bindPrefix .. i)
                    end
                    -- Force visual refresh; events are centrally dispatched
                    -- (per-button registration on 96 buttons caused mass
                    -- OnEvent->UpdateAction calls per tick -- screen blink).
                    -- Taint-safe refresh; avoids passing secret cooldown values through a tainted call.
                    EAB_VTABLE.ForceButtonRefresh(btn, slot)
                    -- Two channels ForceButtonRefresh doesn't own (same pairing
                    -- as the bar-reveal path): checked state + equipped border.
                    btn:SetChecked((IsCurrentAction(slot) or IsAutoRepeatAction(slot)) and true or false)
                    if btn.Border then
                        btn.Border:SetShown(IsEquippedAction(slot) and true or false)
                    end
                end
                if bindPrefix then
                    btn.commandName = bindPrefix .. i
                end
                -- Always register both so empower spells (hold-and-release)
                -- receive the key-down event even when CVar is key-up mode.
                -- useOnKeyDown controls which event fires normal spells.
                btn:RegisterForClicks("AnyDown", "AnyUp")
                btn:SetAttribute("useOnKeyDown", GetCVarBool("ActionButtonUseKeyDown"))
                if btn.EnableMouseWheel then
                    btn:EnableMouseWheel(true)
                end
                if not skipProtected then
                    btn:SetAttribute("showgrid", 1)
                end
                GetEABFlyout():RegisterButton(btn)
                -- Page child-update: rewrites the secure "action" attr on a page
                -- change, then re-checks hold-release. Shared builder so SetupBar
                -- and RebuildBarPaging install byte-identical handlers.
                if (key == "MainBar" or frame._eabPagingInstalled)
                   and not btn:GetAttribute("_childupdate-eab-page") then
                    btn:SetAttributeNoHandler("_childupdate-eab-page", ns._eabBuildPageChildSnippet(i))
                end
                -- Empower re-check on slot change (spec swap, drag, etc.)
                -- The bar header's _onstate-eabempower dispatches ChildUpdate
                -- when addon code sets "state-eabempower".
                if not btn:GetAttribute("_childupdate-eab-empower") then
                    btn:SetAttributeNoHandler("_childupdate-eab-empower", ns._eabEmpowerSnippet)
                end
                buttons[i] = btn
                buttonToBar[btn] = { barKey = key, index = i }
            end
        end
    end

    barButtons[key] = buttons
    ns._eabBarNoButtons[key] = nil

    -- Store original button size before any shape/scale modifications.
    -- StanceButtons and PetActionButtons are 30x30; action buttons are 45x45.
    -- Round to nearest integer to eliminate floating-point noise from Blizzard's
    -- scaling the intended sizes are always whole numbers.
    local btn1 = buttons[1]
    barBaseSize[key] = {
        w = math.floor((btn1 and btn1:GetWidth() or 45) + 0.5),
        h = math.floor((btn1 and btn1:GetHeight() or 45) + 0.5),
    }

    return buttons
end

-- Keeps every bar frame on screen, the way Blizzard's own bars are: bar
-- positions are offsets from the screen centre, so a higher UI Scale, an
-- import made at another scale or a narrower screen would otherwise push a bar
-- near an edge past it. Display only: the saved position is never rewritten,
-- so the bar goes back to it once the screen has room. Protected on our secure
-- bar frames in combat, so the combat /reload build runs this at combat end.
-- On ns: file at the 200-local cap.
ns._eabClampAllBars = function()
    for _, f in pairs(barFrames) do
        f:SetClampedToScreen(true)
    end
end

local function SetupBar(info, skipProtected)
    local key = info.key
    local frame = CreateBarFrame(info)
    if skipProtected or InCombatLockdown() then
        -- One key: every bar of the combat build shares the single pass.
        ns.CombatQueue.Defer("EABClampBars", ns._eabClampAllBars)
    else
        frame:SetClampedToScreen(true)
    end
    -- A bar that can never become visible AND has no key bound gets no buttons
    -- at load: the button loop is 95 % of such a bar's setup cost, and most of
    -- that is Blizzard's CreateFrame on the action button template, which only
    -- a lower button count can reach. A hidden bar with keys keeps its buttons:
    -- its bindings stay live by contract and click-routed keys need a button to
    -- route to. The frame IS still built, so barFrames[key] stays non-nil for
    -- its 52 indexing sites and barButtons[key] is empty, not nil.
    -- ns._eabBuildSkippedBars builds them when the bar leaves the Never set or
    -- a key lands on it.
    if ns.IsNeverBar(info) and not ns.BarHasBoundKeys(info) then
        barButtons[key] = {}
        ns._eabBarNoButtons[key] = true
        -- Placeholder only, same fallback the button-derived value would take
        -- with no buttons. BuildBarButtons recomputes it from the real button.
        barBaseSize[key] = { w = 45, h = 45 }
        return frame, barButtons[key]
    end
    return frame, ns.BuildBarButtons(info, frame, skipProtected)
end

-------------------------------------------------------------------------------
--  First-Install Capture: no saved vars, so read Blizzard Edit Mode settings
--  for initial bar positions, icon counts, orientation and visibility.
-------------------------------------------------------------------------------
local function CaptureBlizzardDefaults()
    local captured = {}
    local uiW, uiH = UIParent:GetSize()
    local uiScale = UIParent:GetEffectiveScale()

    -- MainActionBar is the Edit Mode frame for Action Bar 1 (there is no MainMenuBar).
    -- Chain: ActionButton1 > MainActionBarButtonContainer1 > MainActionBar > UIParent
    local mainActionBar = _G["MainActionBar"]

    for _, info in ipairs(BAR_CONFIG) do
        local bar = _G[info.blizzFrame]
        if info.key == "MainBar" then
            -- MainBar reads Edit Mode settings + position from MainActionBar.
            -- Early disposal reparents it to the full-screen hiddenParent, so
            -- GetCenter still returns valid coordinates.
            local data = {}
            local mabPos = mainActionBar
            if mabPos then
                local cx, cy = mabPos:GetCenter()
                if cx and cy then
                    local bScale = mabPos:GetEffectiveScale()
                    cx = cx * bScale / uiScale
                    cy = cy * bScale / uiScale
                    data.point = "CENTER"
                    data.relPoint = "CENTER"
                    data.x = cx - (uiW / 2)
                    data.y = cy - (uiH / 2)
                end
            end

            local mab = mainActionBar
            if mab then
                if mab.numButtonsShowable and mab.numButtonsShowable > 0 then
                    data.numIcons = mab.numButtonsShowable
                end
                if mab.numRows and mab.numRows > 0 then
                    data.numRows = mab.numRows
                end
                if mab.GetSettingValue then
                    local ok, val = pcall(mab.GetSettingValue, mab, 0)
                    if ok and val ~= nil then data.orientation = (val == 0) and "horizontal" or "vertical" end
                    ok, val = pcall(mab.GetSettingValue, mab, 3)
                    if ok and val ~= nil and val > 0 then data.blizzIconScale = val / 100 end
                end
            end

            captured["MainBar"] = data

        elseif bar and bar:GetPoint(1) then
            local data = {}

            -- Position: convert to UIParent-relative CENTER coords.
            local cx, cy = bar:GetCenter()
            if cx and cy then
                local bScale = bar:GetEffectiveScale()
                cx = cx * bScale / uiScale
                cy = cy * bScale / uiScale
                data.point = "CENTER"
                data.relPoint = "CENTER"
                data.x = cx - (uiW / 2)
                data.y = cy - (uiH / 2)
            end

            -- Number of visible buttons try Edit Mode setting 2 first
            if bar.GetSettingValue then
                local ok, val = pcall(bar.GetSettingValue, bar, 2)
                if ok and val and val >= 6 and val <= 12 then
                    data.numIcons = val
                end
            end
            if not data.numIcons and bar.numButtonsShowable and bar.numButtonsShowable > 0 then
                data.numIcons = bar.numButtonsShowable
            end

            -- Number of rows try Edit Mode setting 1 first
            if bar.GetSettingValue then
                local ok, val = pcall(bar.GetSettingValue, bar, 1)
                if ok and val and val >= 1 and val <= 4 then
                    data.numRows = val
                end
            end
            if not data.numRows and bar.numRows and bar.numRows > 0 then
                data.numRows = bar.numRows
            end

            -- Orientation
            if bar.isHorizontal ~= nil then
                data.orientation = bar.isHorizontal and "horizontal" or "vertical"
            end
            if bar.GetSettingValue then
                local ok, val = pcall(bar.GetSettingValue, bar, 0)
                if ok and val ~= nil then
                    data.orientation = (val == 0) and "horizontal" or "vertical"
                end
            end

            -- Icon size (Edit Mode setting 3).
            if bar.GetSettingValue then
                local ok, val = pcall(bar.GetSettingValue, bar, 3)
                if ok and val ~= nil and val > 0 then
                    data.blizzIconScale = val / 100
                end
            end

            -- Always Show Buttons (setting 9): 0=off, 1=on
            if bar.GetSettingValue and info.key ~= "MainBar" and not info.isStance and not info.isPetBar then
                local ok, val = pcall(bar.GetSettingValue, bar, 9)
                if ok and val ~= nil then
                    data.alwaysShowButtons = (val == 1)
                end
            end

            -- An empty bar with alwaysShowButtons off would vanish entirely once we take over, so force it on.
            if data.alwaysShowButtons == false and info.blizzBtnPrefix then
                local numToCheck = data.numIcons or info.count or 12
                local hasAny = false
                for i = 1, numToCheck do
                    local btn = _G[info.blizzBtnPrefix .. i]
                    if btn and btn.action and HasAction(btn.action) then
                        hasAny = true
                        break
                    end
                end
                if not hasAny then
                    data.alwaysShowButtons = true
                end
            end

            -- Visibility (setting 5, bars 2-8 only): 0=Always, 1=InCombat,
            -- 2=OutOfCombat, 3=Hidden. A bar disabled via Gameplay > Action
            -- Bars (CVars) reports IsShown()=false while setting 5 still
            -- claims "Always Visible"; IsShown=false takes priority.
            if not bar:IsShown() then
                data.visibility = 3
            elseif bar.GetSettingValue and not info.isStance and not info.isPetBar then
                local ok, val = pcall(bar.GetSettingValue, bar, 5)
                if ok and val ~= nil then
                    data.visibility = val
                end
            end

            captured[info.key] = data
        end
    end
    return captured
end

-- First-install end cap span: the elements in one row directly beside
-- Blizzard's Action Bar 1 at capture time (horizontal bars 2-8 shown at all
-- times, the micro menu, the bag bar; stance and pet bars depend on the class,
-- so never), walked outward from bar 1 on each side. The last one each way
-- carries bar 1's cap for that side (ns.AB_CapsSides). Same row = vertical
-- overlap of at least half the shorter one; directly beside = facing edges
-- -8..12 apart (Blizzard's WoW Forever row leaves 4.5 and 7), the nearest
-- first. Returns the left and right bar keys, nil for none.
function ns.AB_CaptureCapSpan(captured)
    local main = _G.MainActionBar
    local mc = captured and captured.MainBar
    if not main or not mc or mc.orientation == "vertical" then return nil, nil end
    local uiS = UIParent:GetEffectiveScale()
    local function Rect(f)
        if not (f and f.GetLeft) then return nil end
        local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
        if not (l and r and t and b) or r - l < 1 or t - b < 1 then return nil end
        local k = f:GetEffectiveScale() / uiS
        return { l * k, r * k, t * k, b * k }
    end
    local home = Rect(main)
    if not home or home[2] - home[1] < 20 then return nil, nil end
    local cands = {}
    for _, info in ipairs(BAR_CONFIG) do
        local d = captured[info.key]
        if info.key ~= "MainBar" and d and info.blizzFrame and not info.isStance and not info.isPetBar
            and d.orientation == "horizontal" and (d.visibility == nil or d.visibility == 0) then
            local r = Rect(_G[info.blizzFrame])
            if r then cands[#cands + 1] = { key = info.key, r = r } end
        end
    end
    local mcf, mm = _G.MicroMenuContainer, _G.MicroMenu
    if mcf and mcf:IsShown() and mm and mm:GetParent() == mcf and mm:IsShown() and mm.isHorizontal ~= false then
        local r = Rect(mcf)
        if r then cands[#cands + 1] = { key = "MicroBar", r = r } end
    end
    local bags = _G.BagsBar
    if bags and bags:IsShown() and bags.isHorizontal ~= false then
        local r = Rect(bags)
        if r then cands[#cands + 1] = { key = "BagBar", r = r } end
    end
    local function Walk(dir)
        local cur, last, used = home, nil, {}
        while true do
            local best, bestGap
            for i = 1, #cands do
                local c = cands[i]
                if not used[c] then
                    local r = c.r
                    local ov = min(cur[3], r[3]) - max(cur[4], r[4])
                    if ov >= 0.5 * min(cur[3] - cur[4], r[3] - r[4]) then
                        local gap = (dir > 0) and (r[1] - cur[2]) or (cur[1] - r[2])
                        if gap >= -8 and gap <= 12 and (not bestGap or gap < bestGap) then
                            best, bestGap = c, gap
                        end
                    end
                end
            end
            if not best then return last end
            used[best] = true
            last, cur = best.key, best.r
        end
    end
    return Walk(-1), Walk(1)
end

-------------------------------------------------------------------------------
--  Layout Engine positions buttons in a grid
-------------------------------------------------------------------------------
-- Snap to a whole number of physical pixels at the bar's effective scale (same
-- round-trip as the border system), eliminating sub-pixel drift between siblings.
local function SnapForScale(x, barScale)
    if x == 0 then return 0 end
    local PP = EllesmereUI and EllesmereUI.PP
    if PP then return PP.Scale(x) end
    return math.floor(x + 0.5)
end

-- Grow direction for icon layout + fixed-edge resize. Lives on EAB, not a
-- file-scope local (main chunk is at Lua's 200-local cap). Caveat: in an unlock
-- anchor chain a mid-chain bar can inherit its parent's grow visually while its
-- own DB still holds the old value.
function EAB:ResolveGrowDirectionForLayout(key, s, depth)
    return (s.growDirection or "up"):upper()
end

-- Resolve a bar's icon order into abstract order parts. iconOrder supersedes the legacy
-- reverseIconOrder boolean; nil iconOrder falls back to the boolean, so old profiles
-- render unchanged with zero migration. Returns flowFlip (reverse button flow along the
-- fill axis) plus hAnchor ("LEFT"/"RIGHT") and vAnchor ("TOP"/"BOTTOM") for the corner
-- modes (both nil in the two legacy modes). do-end + ns so no file-scope local slots
-- are consumed (Lua 5.1 200-local cap).
do
    local function ResolveIconOrder(s)
        local order = s.iconOrder
        if order == nil then
            order = s.reverseIconOrder and "reversed" or "default"
        end
        if order == "reversed" then
            return true, nil, nil
        elseif order == "TOPLEFT" then
            return false, "LEFT", "TOP"
        elseif order == "TOPRIGHT" then
            return false, "RIGHT", "TOP"
        elseif order == "BOTTOMLEFT" then
            return false, "LEFT", "BOTTOM"
        elseif order == "BOTTOMRIGHT" then
            return false, "RIGHT", "BOTTOM"
        end
        return false, nil, nil
    end

    -- Resolved icon order -> concrete index flips for a bar's button grid.
    -- Corner modes place button 1 in that corner purely by permuting indexes:
    -- the frame, its size and the grid geometry never change. rowsUpward is meaningful
    -- only for horizontal bars. Third return (cornerFill): true in the four corner
    -- modes. On vertical bars those fill ACROSS the columns first and wrap down to the
    -- next row; Default/Reversed keep the legacy down-each-column fill. Horizontal bars
    -- already fill row-first, so callers ignore it there.
    function ns.GetOrderFlips(s, isVertical, rowsUpward)
        local flowFlip, hAnchor, vAnchor = ResolveIconOrder(s)
        local colFlip, rowFlip = false, false
        if isVertical then
            rowFlip = flowFlip or (vAnchor == "BOTTOM")
            colFlip = (hAnchor == "RIGHT")
        else
            colFlip = flowFlip or (hAnchor == "RIGHT")
            if vAnchor then
                rowFlip = ((vAnchor == "TOP") == rowsUpward)
            end
        end
        return colFlip, rowFlip, (hAnchor ~= nil)
    end
end

-- Compute layout for a bar and return a table of per-button data.
-- Returns: { [i] = { x, y, w, h, show } }, frameW, frameH
local function ComputeBarLayout(key)
    local info = BAR_LOOKUP[key]
    if not info then return {}, 1, 1 end
    local buttons = barButtons[key]
    if not buttons then return {}, 1, 1 end

    local s = EAB.db.profile.bars[key]
    local numIcons = s.overrideNumIcons or s.numIcons or info.count
    if numIcons < 1 then numIcons = info.count end
    if numIcons > info.count then numIcons = info.count end
    if info.isStance then numIcons = GetNumShapeshiftForms() or info.count end
    if numIcons < 1 then numIcons = 1 end

    local numRows = s.overrideNumRows or s.numRows or 1
    if numRows < 1 then numRows = 1 end
    local stride = ceil(numIcons / numRows)
    numRows = ceil(numIcons / stride)
    -- Raw coords -- do NOT pre-snap with SnapForScale: PP.Scale truncates and
    -- loses a pixel where PP.mult > 1. Pixel-lock happens below, post-shape.
    local padding = s.buttonPadding or 2
    local isVertical = (s.orientation == "vertical")
    local growDir = EAB:ResolveGrowDirectionForLayout(key, s)
    local shape = ns.AB_LayoutShape(s)

    local base = barBaseSize[key]
    local baseW = base and base.w or 45
    local baseH = base and base.h or 45
    local btnW = (s.buttonWidth and s.buttonWidth > 0) and s.buttonWidth or baseW
    local btnH = (s.buttonHeight and s.buttonHeight > 0) and s.buttonHeight or baseH
    if shape ~= "none" and shape ~= "cropped" then
        btnW = btnW + SHAPE_BTN_EXPAND
        btnH = btnH + SHAPE_BTN_EXPAND
    end
    if shape == "cropped" then btnH = btnH * 0.80 end
    local PPc = EllesmereUI and EllesmereUI.PP
    local onePxC = PPc and PPc.mult or 1
    -- Lock btnW/btnH/padding to exact physical pixel multiples so stepW/stepH
    -- and the frame-size math below share the pixel grid of the width-match
    -- extras (onePxC). Otherwise coords drift sub-pixel as col grows, shrinking
    -- spacing and making the last button undershoot the match target.
    local btnWPxC    = math.floor(btnW    / onePxC + 0.5)
    local btnHPxC    = math.floor(btnH    / onePxC + 0.5)
    local paddingPxC = math.floor(padding / onePxC + 0.5)
    btnW    = btnWPxC    * onePxC
    btnH    = btnHPxC    * onePxC
    padding = paddingPxC * onePxC
    local stepW = btnW + padding
    local stepH = btnH + padding
    local extraWC = s._matchExtraPixels or 0
    local extraHC = s._matchExtraPixelsH or 0

    local showEmpty = s.alwaysShowButtons
    if showEmpty == nil then showEmpty = true end
    if info.isStance then showEmpty = false end

    -- Icon order flips are constant for the whole grid.
    local rowsUpward = not isVertical and (growDir == "UP" or growDir == "CENTER")
    local colFlip, rowFlip, cornerFill = ns.GetOrderFlips(s, isVertical, rowsUpward)

    local result = {}
    for i = 1, info.count do
        local btn = buttons[i]
        if not btn then break end
        if i > numIcons then
            result[i] = { x = 0, y = 0, w = btnW, h = btnH, show = false }
        else
            local col, row
            if isVertical then
                if cornerFill then
                    -- Corner modes fill across columns first, then wrap down a
                    -- row (numRows = the column count on vertical bars).
                    col = (i - 1) % numRows
                    row = floor((i - 1) / numRows)
                else
                    col = floor((i - 1) / stride)
                    row = (i - 1) % stride
                end
            else
                col = (i - 1) % stride
                row = floor((i - 1) / stride)
            end
            -- Icon order flips first so the width/height-match extras
            -- below derive from the final visual position.
            if colFlip then col = (isVertical and numRows or stride) - 1 - col end
            if rowFlip then row = (isVertical and stride or numRows) - 1 - row end
            local thisBtnW = (extraWC > 0 and col < extraWC) and (btnW + onePxC) or btnW
            local thisBtnH = (extraHC > 0 and row < extraHC) and (btnH + onePxC) or btnH
            local extraBeforeW = math.min(col, extraWC) * onePxC
            local extraBeforeH = math.min(row, extraHC) * onePxC
            local xOff = col * stepW + extraBeforeW
            local yOff
            if rowsUpward then
                yOff = row * stepH + extraBeforeH
            else
                yOff = -(row * stepH + extraBeforeH)
            end
            local show = true
            if not showEmpty and not (_gridState.shown or ShouldQuickKeybindSurfaceBar(s)) and not ButtonHasAction(btn, info.blizzBtnPrefix) then
                show = false
            end
            result[i] = { x = xOff, y = yOff, w = thisBtnW, h = thisBtnH, show = show }
        end
    end

    -- Frame size in integer physical pixels, then back to coord. btnW/btnH/
    -- padding are already exact pixel multiples, so these multiplies produce
    -- exact pixel counts with no float dust or 1px truncation loss.
    local totalCols = isVertical and numRows or stride
    local totalRows = isVertical and stride or numRows
    local frameWPx = totalCols * btnWPxC + (totalCols - 1) * paddingPxC + extraWC
    local frameHPx = totalRows * btnHPxC + (totalRows - 1) * paddingPxC + extraHC
    local frameW = frameWPx * onePxC
    local frameH = frameHPx * onePxC
    return result, max(frameW, 1), max(frameH, 1)
end

local function HideSlotArt(btn)
    if not btn.SlotArt then return end
    if EllesmereUI and EllesmereUI._hiddenParent then
        btn.SlotArt:SetParent(EllesmereUI._hiddenParent)
    else
        btn.SlotArt:Hide()
        btn.SlotArt:SetAlpha(0)
    end
end

-------------------------------------------------------------------------------
--  Party Mode: spinning action bars, on the shared spin engine
--  (EllesmereUI.PartySpin_Create, EllesmereUI_PartyMode.lua). Each bar's
--  shown buttons orbit that bar's centre by re-anchoring, not rotating, so
--  buttons stay upright and clicking, cooldowns and keybinds are unaffected.
--  Frozen in combat, where moving a protected button is blocked; offsets are
--  measured in screen space, so Blizzard style's per-button SetScale holds;
--  every button goes back onto its exact layout anchor when it stops.
--
--  do/end scope: file is at Lua 5.1's 200-local cap, so none of this may take
--  a main-chunk slot; the refresh lives on ns for ApplyAll.
-------------------------------------------------------------------------------
do
local groups, groupOf = {}, {}
ns.PartySpin_Refresh = EllesmereUI.PartySpin_Create({
    target = "actionBars",
    collect = function()
        wipe(groups)
        for _, info in ipairs(BAR_CONFIG) do
            local buttons, frame = barButtons[info.key], barFrames[info.key]
            if buttons and frame then
                local grp = groupOf[info.key]
                if not grp then
                    grp = { frames = {} }
                    groupOf[info.key] = grp
                end
                grp.pivot = frame
                local list = grp.frames
                wipe(list)
                for i = 1, #buttons do
                    local btn = buttons[i]
                    if btn and btn:IsShown() then list[#list + 1] = btn end
                end
                groups[#groups + 1] = grp
            end
        end
        return groups
    end,
})
end

-- Upvalue for LayoutBar (must be declared before it). ApplyAll sets it during full
-- rebuilds so edge preservation cannot save stale positions into the new profile.
local _isApplyingAll = false

local function LayoutBar(key)
    if InCombatLockdown() then ns._eabApplyDeferred = true return end
    local info = BAR_LOOKUP[key]
    if not info then return end
    local frame = barFrames[key]
    local buttons = barButtons[key]
    if not frame or not buttons then return end

    local s = EAB.db.profile.bars[key]
    -- LAYOUT STAMP: skips a re-layout whose inputs are unchanged (the combat-exit
    -- ApplyAll re-ran this full layout for nothing). EVERY input the body reads
    -- folds into one string: raw settings, profile flags, barPositions, base sizes,
    -- PP.mult (resolution), derived helpers via their RESULTS (grow direction, order
    -- flips, quick keybind surface, unlock anchoring), the stance form count, the
    -- flyout screen-thirds bucket (live GetCenter, so anchor-chain moves invalidate
    -- too), and -- hide-empty bars only -- the per-slot filled bitmask driving
    -- empty-slot alpha. A matching stamp means byte-identical skip. Written only at
    -- the END of a completed pass and cleared on entry, so an interrupted pass can
    -- never leave a stale valid stamp.
    local _lbStamp
    do
        local p = EAB.db.profile
        local pos = p.barPositions and p.barPositions[key]
        local base0 = barBaseSize[key]
        local PPm = EllesmereUI and EllesmereUI.PP
        local growDirS = EAB:ResolveGrowDirectionForLayout(key, s)
        local isVertS = (s.orientation == "vertical")
        local rowsUpS = not isVertS and (growDirS == "UP" or growDirS == "CENTER")
        local cfS, rfS, cnS = ns.GetOrderFlips(s, isVertS, rowsUpS)
        local nIcoS = s.overrideNumIcons or s.numIcons or info.count
        if info.isStance then nIcoS = GetNumShapeshiftForms() or info.count end
        local fbS = -1
        do
            local cx, cy = frame:GetCenter()
            if cx and cy then
                local r = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
                local uw, uh = UIParent:GetSize()
                fbS = ((cx * r > uw * 2 / 3) and 2 or 0) + ((cy * r > uh * 2 / 3) and 1 or 0)
            end
        end
        local showES = s.alwaysShowButtons
        if showES == nil then showES = true end
        if info.isStance then showES = false end
        local fillS = ""
        if not showES then
            local tf = {}
            for i = 1, info.count do
                local b = buttons[i]
                tf[i] = (b and ButtonHasAction(b, info.blizzBtnPrefix)) and "1" or "0"
            end
            fillS = table.concat(tf)
        end
        _lbStamp = table.concat({
            -- #buttons, not just the configured count: a Never bar is built with
            -- none and gains them at the reveal edge, and every other stamp input
            -- can be identical across that edge (the base size falls back to the
            -- same 45x45 the real button reports).
            tostring(nIcoS), tostring(#buttons),
            tostring(s.overrideNumRows or s.numRows or 1),
            tostring(s.buttonPadding or 2), tostring(s.orientation), growDirS or "-",
            tostring(s.buttonShape), tostring(s.buttonWidth), tostring(s.buttonHeight),
            tostring(s._matchExtraPixels), tostring(s._matchExtraPixelsH),
            tostring(showES), tostring(s.mouseoverEnabled),
            ns.AB_Forever() and "forever" or ns.AB_Style(),
            ns.AB_ChromeStamp(key),
            tostring(p.procGlowEnabled),
            pos and tostring(pos.point) or "-", pos and tostring(pos.relPoint) or "-",
            pos and tostring(pos.x) or "-", pos and tostring(pos.y) or "-",
            base0 and tostring(base0.w) or "-", base0 and tostring(base0.h) or "-",
            tostring(PPm and PPm.mult or 1),
            tostring(cfS), tostring(rfS), tostring(cnS),
            tostring(_gridState.shown),
            ShouldQuickKeybindSurfaceBar(s) and "1" or "0",
            (EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(key)) and "1" or "0",
            tostring(fbS), fillS,
        }, "|")
        local st = ns._eabLayoutStamp
        if not st then st = {}; ns._eabLayoutStamp = st end
        if st[key] == _lbStamp then
            return
        end
        st[key] = nil
    end
    local numIcons = s.overrideNumIcons or s.numIcons or info.count
    if numIcons < 1 then numIcons = info.count end
    if numIcons > info.count then numIcons = info.count end
    if info.isStance then numIcons = GetNumShapeshiftForms() or info.count end
    if numIcons < 1 then numIcons = 1 end

    local numRows = s.overrideNumRows or s.numRows or 1
    if numRows < 1 then numRows = 1 end

    local stride = ceil(numIcons / numRows)
    if stride < 1 then stride = 1 end
    -- Recalculate actual rows needed (avoids empty trailing rows)
    numRows = ceil(numIcons / stride)
    -- Raw coords -- do NOT pre-snap with SnapForScale: PP.Scale truncates and
    -- loses a pixel where PP.mult > 1. Pixel-lock happens below, post-shape.
    local padding = s.buttonPadding or 2
    local isVertical = (s.orientation == "vertical")
    local growDir = EAB:ResolveGrowDirectionForLayout(key, s)
    local shape = ns.AB_LayoutShape(s)

    local base = barBaseSize[key]
    local baseW = base and base.w or 45
    local baseH = base and base.h or 45
    local btnW = (s.buttonWidth and s.buttonWidth > 0) and s.buttonWidth or baseW
    local btnH = (s.buttonHeight and s.buttonHeight > 0) and s.buttonHeight or baseH

    if shape ~= "none" and shape ~= "cropped" then
        btnW = btnW + SHAPE_BTN_EXPAND
        btnH = btnH + SHAPE_BTN_EXPAND
    end
    if shape == "cropped" then
        btnH = btnH * 0.80
    end

    -- Width/height match: distribute extra physical pixels across buttons
    local PP = EllesmereUI and EllesmereUI.PP
    local onePx = PP and PP.mult or 1
    -- Lock btnW/btnH/padding to exact physical pixel multiples so stepW and the
    -- width-match +1px extras share one pixel grid; prevents sub-pixel drift
    -- that shrinks visible spacing where PP.mult > 1.
    local btnWPx    = math.floor(btnW    / onePx + 0.5)
    local btnHPx    = math.floor(btnH    / onePx + 0.5)
    local paddingPx = math.floor(padding / onePx + 0.5)
    btnW    = btnWPx    * onePx
    btnH    = btnHPx    * onePx
    padding = paddingPx * onePx
    local stepW = btnW + padding
    local stepH = btnH + padding

    local extraW = s._matchExtraPixels or 0
    local extraH = s._matchExtraPixelsH or 0

    -- Show empty slots (stance bar always forces this off)
    local showEmpty = s.alwaysShowButtons
    if showEmpty == nil then showEmpty = true end
    if info.isStance then showEmpty = false end

    -- Growth direction fixes which edge stays put on resize. UP/CENTER on
    -- horizontal bars stack rows upward (2nd row above 1st); icon order flips
    -- permute indexes within that fixed grid.
    local rowsUpward = not isVertical and (growDir == "UP" or growDir == "CENTER")
    local colFlip, rowFlip, cornerFill = ns.GetOrderFlips(s, isVertical, rowsUpward)

    -- Fit Ring to Cropped Buttons sizes the assist ring from the button's own
    -- rectangle: a shown ring on this bar is refitted (or restored) after the
    -- re-layout. A hidden ring is fitted by AssistShow before it next shows.
    local assistFit = EAB.db.profile.assistGlowFitCropped
    local assistRefit = false

    for i = 1, info.count do
        local btn = buttons[i]
        if not btn then break end

        if i > numIcons then
            btn:Hide()
            btn:SetAlpha(0)
            ns._eabMarkParked(btn, info)
        else
            -- Buttons inside range stay Shown; visibility is alpha-only so
            -- combat page swaps never strand a button hidden.
            local lfd = EFD(btn)
            local demote = lfd.parkA0 == 2 and not btn:IsShown()
            btn:Show()
            if demote and btn:IsShown() then lfd.parkA0 = 1 end

            local col, row
            if isVertical then
                if cornerFill then
                    -- Corner modes fill across columns first, then wrap down a
                    -- row (numRows = the column count on vertical bars).
                    col = (i - 1) % numRows
                    row = floor((i - 1) / numRows)
                else
                    col = floor((i - 1) / stride)
                    row = (i - 1) % stride
                end
            else
                col = (i - 1) % stride
                row = floor((i - 1) / stride)
            end

            -- Icon order flips first so the width/height-match extras
            -- below derive from the final visual position.
            if colFlip then col = (isVertical and numRows or stride) - 1 - col end
            if rowFlip then row = (isVertical and stride or numRows) - 1 - row end

            -- Width/height match: first N columns/rows get +1 physical pixel.
            -- Only the matched axis expands, so a row stays uniform (no 1px jag).
            local thisBtnW = (extraW > 0 and col < extraW) and (btnW + onePx) or btnW
            local thisBtnH = (extraH > 0 and row < extraH) and (btnH + onePx) or btnH
            -- Cumulative offset from expanded buttons before this one
            local extraBeforeW = math.min(col, extraW) * onePx
            local extraBeforeH = math.min(row, extraH) * onePx

            btn:ClearAllPoints()
            local xOff = col * stepW + extraBeforeW
            local yOff, anchor
            if rowsUpward then
                yOff = row * stepH + extraBeforeH
                anchor = "BOTTOMLEFT"
            else
                yOff = -(row * stepH + extraBeforeH)
                anchor = "TOPLEFT"
            end
            EFD(btn).barKey = key
            -- Stock styles (Blizzard, Classic) keep the native-size button and
            -- scale it, so the stock art scales with it.
            local abStyle = ns.AB_Style()
            if abStyle ~= "eui" then
                local base = barBaseSize[key]
                local nativeW = base and base.w or 45
                local nativeH = base and base.h or 45
                local sc = thisBtnW / nativeW
                btn:SetScale(sc)
                btn:SetSize(nativeW, nativeH)
                btn:SetPoint(anchor, frame, anchor, xOff / sc, yOff / sc)
                -- Classic WoW UI: the vanilla ring on the native-size button,
                -- painted once per size (the scale carries it). Blizzard
                -- Style on the Forever client: the retail border, once.
                if abStyle == "classic" then
                    local cfd = EFD(btn)
                    if cfd.classicW ~= nativeW or cfd.classicH ~= nativeH then
                        cfd.classicW, cfd.classicH = nativeW, nativeH
                        ns.AB_PaintClassicButton(btn, nativeW, nativeH)
                    end
                elseif EllesmereUI.IS_FOREVER and not (info.isStance or info.isPetBar) then
                    ns.AB_StockNormal(btn)
                end
            else
                btn:SetPoint(anchor, frame, anchor, xOff, yOff)
                btn:SetSize(thisBtnW, thisBtnH)
            end
            HideSlotArt(btn)

            -- Stock styles: counter-scale SpellActivationAlert so the native
            -- proc glow renders at screen size despite the button's SetScale.
            if abStyle ~= "eui" and btn.SpellActivationAlert then
                local base = barBaseSize[key]
                local nativeW = base and base.w or 45
                local sc = thisBtnW / nativeW
                if sc > 0 then
                    btn.SpellActivationAlert:SetScale(1 / sc)
                end
            end

            -- Resize the autocast overlay to match the button size
            if btn.AutoCastOverlay then
                btn.AutoCastOverlay:SetAllPoints(btn)
            end

            -- TargetReticleAnimFrame is authored 128x128 for the default 45x45
            -- button, so btnW/45 keeps the visual proportions.
            if btn.TargetReticleAnimFrame then
                btn.TargetReticleAnimFrame:SetScale(btnW / 45)
            end

            -- AssistedCombat frames are created lazily at the default 45x45,
            -- anchored CENTER; scale them to our button size. A highlight ring
            -- fitted to a Cropped button (ns._AssistFit) runs at scale 1 and is
            -- refitted by the assist pass queued at the end of this layout.
            local ahf = btn.AssistedCombatHighlightFrame
            if ahf and not (ns._eabFD[ahf] and ns._eabFD[ahf].fitW) then
                ahf:SetScale(btnW / 45)
            end
            if assistFit and not assistRefit then
                local ohf = EFD(btn).assistHL
                assistRefit = (ohf and ohf:IsShown()) or (ahf and ahf:IsShown()) or false
            end
            if btn.AssistedCombatRotationFrame then
                btn.AssistedCombatRotationFrame:SetScale(btnW / 45)
            end

            -- Pin SpellActivationAlert to button bounds for custom proc glows;
            -- with custom glows off or a stock style on, leave it untouched.
            if btn.SpellActivationAlert and EAB.db.profile.procGlowEnabled and abStyle == "eui" then
                btn.SpellActivationAlert:SetAllPoints(btn)
                btn.SpellActivationAlert:SetScale(1)
            end

            -- Profession quality diamonds: EAB paints its own rank icon (the
            -- quality scan in OnEnable). Blizzard's overlay is created lazily
            -- inside the secure button Update, which our buttons get no
            -- events for, and forcing that update writes the new frame onto
            -- the secure button's table (taint). Keep it permanently hidden.
            if btn.ProfessionQualityOverlayFrame then
                btn.ProfessionQualityOverlayFrame:SetShown(false)
                if not EFD(btn).qualityHooked then
                    btn.ProfessionQualityOverlayFrame:HookScript("OnShow", function(self)
                        self:SetShown(false)
                    end)
                    EFD(btn).qualityHooked = true
                end
            end
            if EAB._QueueRankScan then EAB._QueueRankScan() end

            if not showEmpty and not (_gridState.shown or ShouldQuickKeybindSurfaceBar(s)) and not ButtonHasAction(btn, info.blizzBtnPrefix) then
                btn:SetAlpha(0)
                ns._eabMarkParked(btn, info)
            else
                if not s.mouseoverEnabled then
                    btn:SetAlpha(1)
                    lfd.parkA0 = nil
                end
            end
        end
    end

    -- Size the bar frame to encompass all visible buttons (including extra px)
    local totalCols = isVertical and numRows or stride
    local totalRows = isVertical and stride or numRows
    local frameW = totalCols * btnW + (totalCols - 1) * padding + extraW * onePx
    local frameH = totalRows * btnH + (totalRows - 1) * padding + extraH * onePx

    -- Sync frame anchor with barPositions before SetSize so the frame grows
    -- from the correct edge (or center). Skip anchored bars: their position
    -- is owned by the anchor chain, not barPositions.
    local isAnchored = EllesmereUI.IsUnlockAnchored
        and EllesmereUI.IsUnlockAnchored(key)
    if not isAnchored then
        local curPt = ({frame:GetPoint(1)})[1]
        local pos = EAB.db.profile.barPositions and EAB.db.profile.barPositions[key]
        if pos and pos.point and pos.relPoint == "CENTER" and curPt ~= pos.point then
            local PPa = EllesmereUI and EllesmereUI.PP
            local px, py = pos.x or 0, pos.y or 0
            if pos.point == "CENTER" and curPt and curPt ~= "CENTER" then
                -- Edge -> CENTER: read the live center (stored CENTER coords may
                -- be stale from a different width) so the bar does not jump.
                local fCx, fCy = frame:GetCenter()
                if fCx and fCy then
                    local uiS = UIParent:GetEffectiveScale()
                    local fS = frame:GetEffectiveScale()
                    local ratio = fS / uiS
                    local uiW, uiH = UIParent:GetSize()
                    px = fCx * ratio - uiW / 2
                    py = fCy * ratio - uiH / 2
                end
                if PPa and PPa.SnapCenterForDim then
                    local es = frame:GetEffectiveScale()
                    px = PPa.SnapCenterForDim(px, frame:GetWidth() or 0, es)
                    py = PPa.SnapCenterForDim(py, frame:GetHeight() or 0, es)
                end
            elseif PPa and PPa.SnapForES then
                local es = frame:GetEffectiveScale()
                px = PPa.SnapForES(px, es)
                py = PPa.SnapForES(py, es)
            end
            frame:ClearAllPoints()
            frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, px, py)
        end
    end
    -- Pre-resize center in UIParent space, captured BEFORE SetSize (an
    -- edge-pointed frame moves its center when resized); the anchor offset
    -- upkeep below validates against it.
    local preCX, preCY
    do
        local c1, c2 = frame:GetCenter()
        if c1 and c2 then
            local r = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
            preCX, preCY = c1 * r, c2 * r
        end
    end
    EllesmereUI._layoutBarResizing = key
    frame:SetSize(max(frameW, 1), max(frameH, 1))
    EllesmereUI._layoutBarResizing = nil
    -- Anchor offset upkeep: a growth-direction resize shifts the center by
    -- delta/2 while the fixed edge stays put, so the center-based anchor
    -- offset must follow. _eabPrevLayout* separates real resizes from init/reload sizing.
    do
        local newW = max(frameW, 1)
        local newH = max(frameH, 1)
        local prevW = frame._eabPrevLayoutW
        local prevH = frame._eabPrevLayoutH
        frame._eabPrevLayoutW = newW
        frame._eabPrevLayoutH = newH
        -- Self-validating gate: dw/2 compensation is correct only when the PRE-resize
        -- center sat at the anchor-derived position (target center + stored offset on
        -- the compensated axis). Mid-profile-apply the bar still holds the OUTGOING
        -- position while unlockAnchors already carries the INCOMING offsets;
        -- compensating that corrupts offsets cumulatively on every swap. Layout passes
        -- land before/inside/after the _abAnchorSuppressed window (extra bars build on
        -- a timer), so only the position check is ordering-proof.
        if (prevW or prevH)
           and not EllesmereUI._unlockActive
           and not EllesmereUI._abAnchorSuppressed
           and not _isApplyingAll then
            local s = EAB.db.profile.bars[key]
            local grow = s and s.growDirection
            if grow then
                grow = grow:upper()
                if grow ~= "CENTER" then
                    local adb = EllesmereUIDB and EllesmereUIDB.unlockAnchors
                    local ai = adb and adb[key]
                    if ai then
                        local side = ai.side
                        local PPo = EllesmereUI and EllesmereUI.PP
                        local uiES = PPo and UIParent:GetEffectiveScale()
                        local tCX, tCY
                        if EllesmereUI.GetAnchorTargetCenterUI then
                            tCX, tCY = EllesmereUI.GetAnchorTargetCenterUI(key)
                        end
                        local TOL = 2  -- UI px; pixel-snap noise stays well under 1
                        -- Width/height-matched bars: the match owns that axis, so
                        -- a resize there is the match asserting the target size
                        -- the saved offset already matches; compensating would
                        -- corrupt it (CDM has a twin of this block).
                        local wMatched = EllesmereUIDB and EllesmereUIDB.unlockWidthMatch and EllesmereUIDB.unlockWidthMatch[key]
                        local hMatched = EllesmereUIDB and EllesmereUIDB.unlockHeightMatch and EllesmereUIDB.unlockHeightMatch[key]
                        -- Horizontal growth (LEFT/RIGHT): adjust offsetX on TOP/BOTTOM anchors
                        if prevW and math.abs(newW - prevW) > 0.1
                           and (side == "TOP" or side == "BOTTOM")
                           and not wMatched
                           and preCX and tCX
                           and math.abs(preCX - (tCX + (ai.offsetX or 0))) <= TOL then
                            local dw = newW - prevW
                            if grow == "RIGHT" then
                                ai.offsetX = ai.offsetX + dw / 2
                            elseif grow == "LEFT" then
                                ai.offsetX = ai.offsetX - dw / 2
                            end
                            if PPo and uiES then ai.offsetX = PPo.SnapForES(ai.offsetX, uiES) end
                        end
                        -- Vertical growth (UP/DOWN): adjust offsetY on LEFT/RIGHT anchors
                        if prevH and math.abs(newH - prevH) > 0.1
                           and (side == "LEFT" or side == "RIGHT")
                           and not hMatched
                           and preCY and tCY
                           and math.abs(preCY - (tCY + (ai.offsetY or 0))) <= TOL then
                            local dh = newH - prevH
                            if grow == "DOWN" then
                                ai.offsetY = ai.offsetY - dh / 2
                            elseif grow == "UP" then
                                ai.offsetY = ai.offsetY + dh / 2
                            end
                            if PPo and uiES then ai.offsetY = PPo.SnapForES(ai.offsetY, uiES) end
                        end
                    end
                end
            end
        end
    end

    -- flyoutDirection per button from orientation + live screen position: split
    -- each axis into thirds and open away from the nearest screen edge.
    local flyDir
    do
        local cx, cy = frame:GetCenter()
        local uiW = UIParent:GetWidth()
        local uiH = UIParent:GetHeight()
        local uiScale = UIParent:GetEffectiveScale()
        local fScale  = frame:GetEffectiveScale()
        -- Convert to UIParent coordinate space
        if cx and cy then
            cx = cx * fScale / uiScale
            cy = cy * fScale / uiScale
        end
        if cx and cy then
            local thirdW = uiW / 3
            local thirdH = uiH / 3
            if isVertical then
                -- Vertical bar: flyout goes left if bar is in the right third, else right
                flyDir = (cx > thirdW * 2) and "LEFT" or "RIGHT"
            else
                -- Horizontal bar: flyout goes down if bar is in the top third, else up
                flyDir = (cy > thirdH * 2) and "DOWN" or "UP"
            end
        else
            -- Frame not yet on screen safe fallback
            flyDir = isVertical and "RIGHT" or "UP"
        end
    end
    for i = 1, #buttons do
        local btn = buttons[i]
        if btn then
            -- Ensure the button has GetPopupDirection for Blizzard's SpellFlyout system
            -- (must be available on all buttons, regardless of squareIcons setting)
            if not btn.GetPopupDirection then
                btn.GetPopupDirection = function(self)
                    return self:GetAttribute("flyoutDirection") or "UP"
                end
            end
            if not InCombatLockdown() then
                btn:SetAttribute("flyoutDirection", flyDir)
            end
        end
    end

    -- Notify the position system for width/height match propagation and
    -- anchor chains. Anchored bars with a growth direction skip it: the
    -- deferred ApplyAnchorPosition it queues would override edge
    -- positioning, and OnSizeChanged already propagates to dependents.
    local skipNotify = EllesmereUI.IsUnlockAnchored
        and EllesmereUI.IsUnlockAnchored(key)
        and growDir ~= "CENTER" and growDir ~= "UP"
    if not skipNotify then
        if EllesmereUI.NotifyElementResized then
            EllesmereUI.NotifyElementResized(key)
        end
        if EllesmereUI.PropagateAnchorChain then
            EllesmereUI.PropagateAnchorChain(key)
        end
    end

    -- Position paging arrows after MainBar layout
    if key == "MainBar" then
        if not _pagingFrame then SetupPagingFrame() end
        LayoutPagingFrame()
        -- Set up secure paging keybind overrides (once, out of combat).
        -- Redirects NEXTACTIONPAGE / PREVIOUSACTIONPAGE to hidden secure
        -- buttons so page cycling works in combat without taint.
        if _pagingFrame and not _pagingFrame._pageBindsSet and not InCombatLockdown() then
            _pagingFrame._pageBindsSet = true
            local nextBtn = CreateFrame("Button", "EABPageNext", UIParent, "SecureActionButtonTemplate")
            nextBtn:SetSize(1, 1)
            nextBtn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
            nextBtn:SetAlpha(0)
            nextBtn:RegisterForClicks("AnyUp", "AnyDown")
            WireSecurePagingButton(nextBtn, 1)

            local prevBtn = CreateFrame("Button", "EABPagePrev", UIParent, "SecureActionButtonTemplate")
            prevBtn:SetSize(1, 1)
            prevBtn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
            prevBtn:SetAlpha(0)
            prevBtn:RegisterForClicks("AnyUp", "AnyDown")
            WireSecurePagingButton(prevBtn, -1)

            local function ApplyPageBindings()
                if InCombatLockdown() then return end
                ClearOverrideBindings(_pagingFrame)
                local nextKeys = { GetBindingKey("NEXTACTIONPAGE") }
                local prevKeys = { GetBindingKey("PREVIOUSACTIONPAGE") }
                for _, k in ipairs(nextKeys) do
                    SetOverrideBindingClick(_pagingFrame, true, k, "EABPageNext")
                end
                for _, k in ipairs(prevKeys) do
                    SetOverrideBindingClick(_pagingFrame, true, k, "EABPagePrev")
                end
            end
            ApplyPageBindings()
            -- Re-apply if user changes keybinds
            _pagingFrame:RegisterEvent("UPDATE_BINDINGS")
            local origOnEvent = _pagingFrame:GetScript("OnEvent")
            _pagingFrame:SetScript("OnEvent", function(self, event, ...)
                if event == "UPDATE_BINDINGS" then
                    if not InCombatLockdown() then ApplyPageBindings() end
                    return
                end
                if origOnEvent then origOnEvent(self, event, ...) end
            end)
        end
    end

    -- The bar's chrome: WoW Forever's frame and dividers when shown (dividers
    -- only on a one-line bar at spacing 2 or less, as Blizzard draws them)
    -- and the bar's end caps. A bar that never showed either builds nothing.
    if (ns._abChrome and ns._abChrome[key]) or ns.AB_ForeverBg(key) or ns.AB_CapsLook(key) then
        local oneLine = (isVertical and totalCols or totalRows) == 1 and (s.buttonPadding or 2) <= 2
        ns.AB_ApplyBarChrome(key, frame, max(frameW, 1), max(frameH, 1), btnW, isVertical, totalRows > 1,
            oneLine and (isVertical and totalRows or totalCols) or 0,
            isVertical and stepH or stepW, isVertical and extraH or extraW, onePx)
    end
    -- The micro menu's and bag bar's caps size from Action Bar 1's buttons
    -- and may carry its caps (the span): repaint them after bar 1's pass.
    if key == "MainBar" then
        ns._abMainBtnW = btnW
        ns.AB_ExtraCapsAll()
    end

    -- Countdown size can be capped against button width (CooldownFonts .EffectiveSize,
    -- opt-in per bar), so any re-layout can change the cap. It sits here, not at the
    -- ~fourteen callers (icon size, padding, row/column overrides, width/height-match
    -- links, profile swaps, ...), because hooking one leaves the rest applying a stale
    -- size. Cheap when nothing changed: the per-frame stamp no-ops unless size differs.
    EAB:ApplyCooldownFontsForBar(key)
    -- A shown fitted-or-fittable assist ring on this bar: refit or restore it
    -- on the next assist pass (coalesced; never queued with the option off).
    if assistRefit then ns.QueueAssistRescan() end
    -- Publish the stamp only on a completed pass (cleared on entry above).
    ns._eabLayoutStamp[key] = _lbStamp
end

-------------------------------------------------------------------------------
--  Visual Customization Button Appearance
-------------------------------------------------------------------------------
local function HideSelfDeferred(self)
    -- Reuse a cached closure per frame to avoid allocation on every OnShow
    local fd = EFD(self)
    if not fd.hideFn then
        fd.hideFn = function()
            if self and not self:IsForbidden() then self:Hide() end
        end
    end
    C_Timer_After(0, fd.hideFn)
end

local function HideBorder(button)
    if button.NormalTexture then
        button.NormalTexture:Hide()
        button.NormalTexture:SetAlpha(0)
    end
    if button.Border then
        -- Show Equipped Border (Icon Effects) keeps Blizzard's equipped-item
        -- border, in our square art; its shown state stays with the updates.
        if EAB.db.profile.showEquippedBorder then
            ns.AB_EquippedBorderLook(button.Border)
        else
            button.Border:Hide()
            button.Border:SetAlpha(0)
        end
    end
    if button.icon and button.IconMask then
        button.icon:RemoveMaskTexture(button.IconMask)
        -- Neutralize IconMask: UpdateButtonArt re-applies it via
        -- icon:AddMaskTexture on combat transitions, page changes, etc.
        button.IconMask:Hide()
        button.IconMask:SetTexture(nil)
        button.IconMask:ClearAllPoints()
        button.IconMask:SetSize(0.001, 0.001)
    end
end

local function SetSquareTexture(texture, texPath)
    if not texture then return end
    texture:SetAtlas(nil)
    texture:SetTexture(texPath)
    texture:SetTexCoord(0, 1, 0, 1)
    texture:ClearAllPoints()
    texture:SetAllPoints(texture:GetParent())
end

-- Show Equipped Border (Icon Effects, profile.showEquippedBorder): Blizzard's
-- equipped-item border on a square button, in our square highlight art and
-- Blizzard's own green at half opacity. The art swap fires the Border's
-- SetAtlas hook (MakeButtonSquare) again, which `busy` turns away.
do
    local busy = false
    function ns.AB_EquippedBorderLook(bd)
        if busy then return end
        busy = true
        SetSquareTexture(bd, HIGHLIGHT_TEXTURES[1])
        busy = false
        bd:SetVertexColor(0, 1, 0, 0.5)
        bd:SetAlpha(1)
    end
end

-------------------------------------------------------------------------------
--  Classic WoW UI button art (ns.AB_Style() == "classic")
--  The vanilla 36-button ring on a button, scaled by the button's own size:
--  NormalTexture UI-Quickslot2 (66/36 of the button, CENTER 0,-1/36), or
--  UI-Quickslot on an empty slot; PushedTexture UI-Quickslot-Depress over the
--  button; HighlightTexture ButtonHilight-Square ADD; CheckedTexture
--  CheckButtonHilight ADD; equipped Border UI-ActionButton-Border ADD (62/36,
--  CENTER 0,1/36). Square icon with full art: the stock IconMask is
--  neutralised the way HideBorder does it, the stock slot background kept
--  transparent, the cooldown swipe spans the icon. Idempotent: a layout pass
--  re-runs it per native size (our buttons' UpdateButtonArt is a noop, so
--  nothing of Blizzard's repaints the ring behind it).
-------------------------------------------------------------------------------
ns.AB_CLASSIC = {
    slot     = "Interface\\Buttons\\UI-Quickslot2",
    empty    = "Interface\\Buttons\\UI-Quickslot",
    pushed   = "Interface\\Buttons\\UI-Quickslot-Depress",
    hilight  = "Interface\\Buttons\\ButtonHilight-Square",
    checked  = "Interface\\Buttons\\CheckButtonHilight",
    equipped = "Interface\\Buttons\\UI-ActionButton-Border",
}

-- Slot ring or empty-slot art on the NormalTexture. Memo per button: the
-- content edges (slot change, page flip) cost one comparison when unchanged.
function ns.AB_ClassicSlotRing(btn, filled)
    filled = filled and true or false
    local fd = EFD(btn)
    if fd.classicFilled == filled then return end
    fd.classicFilled = filled
    local nt = btn.NormalTexture
    if nt then
        nt:SetTexture(filled and ns.AB_CLASSIC.slot or ns.AB_CLASSIC.empty)
        nt:SetTexCoord(0, 1, 0, 1)
    end
end

-- Plain Blizzard Style on the Forever client: the border the template's
-- OnLoad left on our button's NormalTexture (IconFrame-AddRow, as our
-- buttons have no .bar; IconFrame on a bar-art button) is redrawn once from
-- its retail sheet, where the client's atlas would draw Forever art.
function ns.AB_StockNormal(btn)
    local fd = EFD(btn)
    if fd.stockNT then return end
    fd.stockNT = true
    if ns.AB_Forever() then return end
    local nt = btn.NormalTexture
    local a = nt and nt:GetAtlas()
    if not a then return end
    local l = strlower(a)
    if l == "ui-hud-actionbar-iconframe-addrow" or l == "ui-hud-actionbar-iconframe" then
        EllesmereUI.StockAtlas(nt, a)
    end
end

-- Paints the whole kit on `btn` for a `w` x `h` button (its own size when
-- omitted). Our bar buttons pass their native size; flyout buttons pass none.
function ns.AB_PaintClassicButton(btn, w, h)
    local fd = EFD(btn)
    local art = ns.AB_CLASSIC
    if not w then w, h = btn:GetSize() end
    if not w or w <= 0 then w = 45 end
    if not h or h <= 0 then h = w end
    local sw, sh = w / 36, h / 36
    local icon = btn.icon
    if icon then
        if btn.IconMask then
            icon:RemoveMaskTexture(btn.IconMask)
            btn.IconMask:Hide()
            btn.IconMask:SetTexture(nil)
            btn.IconMask:ClearAllPoints()
            btn.IconMask:SetSize(0.001, 0.001)
        end
        icon:SetTexCoord(0, 1, 0, 1)
    end
    -- The 12.1 rounded slot background stays transparent (the square ring
    -- below is the slot); alpha, so Blizzard's own art passes keep working.
    if btn.SlotBackground then btn.SlotBackground:SetAlpha(0) end
    if btn.cooldown then
        btn.cooldown:ClearAllPoints()
        btn.cooldown:SetAllPoints(btn)
    end
    -- Seeded from the same source the content edges use (the action
    -- attribute); buttons without one (flyout popups) ask the mixin.
    if fd.classicFilled == nil then
        local a = btn.GetAttribute and btn:GetAttribute("action")
        if a then
            fd.classicFilled = HasAction(a) and true or false
        else
            fd.classicFilled = ButtonHasAction(btn) and true or false
        end
    end
    local nt = btn.NormalTexture
    if nt then
        nt:SetAtlas(nil)
        nt:SetTexture(fd.classicFilled and art.slot or art.empty)
        nt:SetTexCoord(0, 1, 0, 1)
        nt:ClearAllPoints()
        nt:SetPoint("CENTER", btn, "CENTER", 0, -sh)
        nt:SetSize(66 * sw, 66 * sh)
    end
    local pt = btn.PushedTexture
    if pt then
        pt:SetAtlas(nil)
        pt:SetTexture(art.pushed)
        pt:SetTexCoord(0, 1, 0, 1)
        pt:SetDrawLayer("OVERLAY", 7)
        pt:ClearAllPoints()
        pt:SetAllPoints(btn)
        pt:SetVertexColor(1, 1, 1, 1)
        pt:SetAlpha(1)
    end
    local ht = btn.HighlightTexture
    if ht then
        ht:SetAtlas(nil)
        ht:SetTexture(art.hilight)
        ht:SetTexCoord(0, 1, 0, 1)
        ht:SetBlendMode("ADD")
        ht:ClearAllPoints()
        ht:SetAllPoints(btn)
    end
    local ct = btn.CheckedTexture
    if ct then
        ct:SetAtlas(nil)
        ct:SetTexture(art.checked)
        ct:SetTexCoord(0, 1, 0, 1)
        ct:SetBlendMode("ADD")
        ct:ClearAllPoints()
        ct:SetAllPoints(btn)
    end
    local bd = btn.Border
    if bd then
        bd:SetAtlas(nil)
        bd:SetTexture(art.equipped)
        bd:SetTexCoord(0, 1, 0, 1)
        bd:SetBlendMode("ADD")
        bd:ClearAllPoints()
        bd:SetPoint("CENTER", btn, "CENTER", 0, sh)
        bd:SetSize(62 * sw, 62 * sh)
    end
    fd.classicArt = true
end

_quickKeybindState.art.ApplyButtonHighlight = function(btn)
    local tex = btn and btn.QuickKeybindHighlightTexture
    if not tex then return end

    local p = EAB and EAB.db and EAB.db.profile
    local useCC = p and p.highlightUseClassColor
    local customC = (p and p.highlightCustomColor) or { r = 0.973, g = 0.839, b = 0.604, a = 1 }
    local cr, cg, cb = customC.r, customC.g, customC.b
    if useCC then
        local _, ct = UnitClass("player")
        if ct then
            local cc = RAID_CLASS_COLORS[ct]
            if cc then
                cr, cg, cb = cc.r, cc.g, cc.b
            end
        end
    end

    -- QuickKeybind manages hover/idle opacity itself. We only replace the
    -- Blizzard atlas with EUI's square highlight art and matching color.
    SetSquareTexture(tex, HIGHLIGHT_TEXTURES[1])
    tex:SetVertexColor(cr, cg, cb, 1)
end

_quickKeybindState.art.RefreshButton = function(btn, show)
    if not btn or btn:IsForbidden() then return end
    _quickKeybindState.art.ApplyButtonHighlight(btn)
    if show ~= nil then
        _quickKeybindState.art.ApplyButtonHighlightAlpha(btn, show)
    end
end

_quickKeybindState.art.InitializeButton = function(btn, show)
    _quickKeybindState.art.RefreshButton(btn, show)
    _quickKeybindState.art.HookButton(btn)
end

_quickKeybindState.art.HookButton = function(btn)
    if not btn or btn:IsForbidden() or EFD(btn).quickKeybindArtHooked then return end
    if btn.QuickKeybindHighlightTexture and btn.DoModeChange then
        hooksecurefunc(btn, "DoModeChange", function(self, isInQuickbindMode)
            _quickKeybindState.art.RefreshButton(self, isInQuickbindMode)
        end)
        EFD(btn).quickKeybindArtHooked = true
    end
end

_quickKeybindState.art.ApplyButtonHighlightAlpha = function(btn, show)
    local tex = btn and btn.QuickKeybindHighlightTexture
    if not tex then return end

    if show then
        local idleAlpha = 0.5
        if btn.IsMouseOver and btn:IsMouseOver() then
            tex:SetAlpha(1)
        else
            tex:SetAlpha(idleAlpha)
        end
    else
        tex:SetAlpha(1)
    end
end

_quickKeybindState.art.ForEachSpecialButton = function(fn)
    if not fn then return end
    if ExtraActionButton1 then
        fn(ExtraActionButton1)
    end
end

_quickKeybindState.ReassertButtonsAfterCombatChange = function()
    if not _quickKeybindState.open then return end
    C_Timer_After(0, function()
        if _quickKeybindState.open and ns.EAB_UpdateQuickKeybindButtons then
            ns.EAB_UpdateQuickKeybindButtons(true)
        end
    end)
end

local function HideTexture(texture)
    if not texture then return end
    texture:SetAlpha(0)
end

function EAB_VTABLE.HideRegionDeferred(region, resetAlpha)
    if not region then return end
    local fd = EFD(region)
    if not fd.hideFn then
        fd.hideFn = function()
            if region and not region:IsForbidden() then
                region:Hide()
                if resetAlpha then
                    region:SetAlpha(resetAlpha)
                end
            end
        end
    end
    C_Timer_After(0, fd.hideFn)
end

local function MakeButtonSquare(btn)
    if EFD(btn).squared then return end
    -- Always hide SlotBackground regardless of style (our own icon
    -- background toggle controls slot backgrounds for all bars).
    HideSlotArt(btn)
    -- Skip the rest of Blizzard texture stripping for the stock styles
    local _p = EAB.db and EAB.db.profile
    if ns.AB_Style() ~= "eui" then return end
    HideBorder(btn)
    -- Ensure the button has GetPopupDirection for Blizzard's SpellFlyout system.
    -- ActionBarButtonTemplate may not always inherit this from FlyoutButtonMixin.
    if not btn.GetPopupDirection then
        btn.GetPopupDirection = function(self)
            return self:GetAttribute("flyoutDirection") or "UP"
        end
    end
    local fd = EFD(btn)
    if btn.NormalTexture and not fd.ntHooked then
        btn.NormalTexture:HookScript("OnShow", HideSelfDeferred)
        fd.ntHooked = true
    end
    if not fd.showHooked then
        -- Cache the deferred closure per button to avoid allocation on every OnShow
        local hideBorderFn = function()
            if btn and not btn:IsForbidden() then HideBorder(btn) end
        end
        btn:HookScript("OnShow", function() C_Timer_After(0, hideBorderFn) end)
        fd.showHooked = true
    end
    -- Re-neutralize IconMask after Blizzard re-adds it (combat transitions,
    -- page changes, bonus bar swaps). Deferred via C_Timer to avoid tainting
    -- Blizzard's secure call chains.
    if not fd.artHooked and btn.UpdateButtonArt then
        hooksecurefunc(btn, "UpdateButtonArt", function(self)
            local sfd = EFD(self)
            -- Coalesce: UpdateAction storms (mouseover-conditional macros) call
            -- this many times per frame; one deferred HideBorder covers them all.
            if sfd.artPending then return end
            sfd.artPending = true
            if not sfd.artFn then
                sfd.artFn = function()
                    sfd.artPending = nil
                    if self and not self:IsForbidden() then
                        HideBorder(self)
                    end
                end
            end
            C_Timer_After(0, sfd.artFn)
        end)
        fd.artHooked = true
    end
    -- Hook UpdateAssistedCombatRotationFrame to scale the rotation frame
    -- when Blizzard creates it lazily (default 45x45, needs our button size).
    if not fd.rotHooked and btn.UpdateAssistedCombatRotationFrame then
        hooksecurefunc(btn, "UpdateAssistedCombatRotationFrame", function(self)
            -- Fires at Blizzard's combat cadence while a rotation action is on
            -- a bar: change-guard so steady-state fires cost only the reads.
            local rtf = self.AssistedCombatRotationFrame
            if rtf and EFD(self).squared then
                local s = (self:GetWidth() or 45) / 45
                if rtf:GetScale() ~= s then rtf:SetScale(s) end
            end
            -- Blizzard's swirl frame stays permanently hidden (its Lua OnUpdate polls
            -- every render frame while shown); our script-free spinner clone replaces
            -- it. UpdateState (the caller we hook behind) re-Shows it every call and
            -- this hook runs right after, synchronously, so it never renders.
            if rtf then
                if rtf:IsShown() then rtf:Hide() end
                local spin = ns.EnsureAssistSpinner(self, rtf)
                local p2 = EAB.db and EAB.db.profile
                local enabled = not p2 or p2.obaIconEnabled ~= false
                local action = self.GetAttribute and self:GetAttribute("action") or self.action
                local isAssist = action and C_ActionBar and C_ActionBar.IsAssistedCombatAction
                    and C_ActionBar.IsAssistedCombatAction(action) or false
                spin:SetShown(enabled and isAssist)
                -- Suggested-spell icon updates ride the assist ticker, armed
                -- here on the only signal that identifies an assist button (see
                -- ns._ArmAssistTicker for cost discipline). When the assist
                -- action leaves, stop the ticker if no assist button remains.
                if isAssist then
                    if ns._ArmAssistTicker then ns._ArmAssistTicker() end
                elseif ns._assistTicker and ns._assistTicker.IsPlaying() then
                    if ns.RepaintAssistIcons() == 0 then ns._assistTicker.Stop() end
                end
            end
        end)
        fd.rotHooked = true
    end
    SetSquareTexture(btn.HighlightTexture, HIGHLIGHT_TEXTURES[1])
    SetSquareTexture(btn.NewActionTexture, HIGHLIGHT_TEXTURES[1])
    SetSquareTexture(btn.PushedTexture, HIGHLIGHT_TEXTURES[2])
    SetSquareTexture(btn.Flash, HIGHLIGHT_TEXTURES[1])
    SetSquareTexture(btn.CheckedTexture, HIGHLIGHT_TEXTURES[1])
    SetSquareTexture(btn.Border, HIGHLIGHT_TEXTURES[1])
    _quickKeybindState.art.InitializeButton(btn)
    HideTexture(btn.FlyoutBorderShadow)
    if btn.BorderShadow then
        if EllesmereUI and EllesmereUI._hiddenParent then
            btn.BorderShadow:SetParent(EllesmereUI._hiddenParent)
        else
            HideTexture(btn.BorderShadow)
        end
    end
    if btn.cooldown then
        btn.cooldown:ClearAllPoints()
        btn.cooldown:SetAllPoints(btn)
    end
    -- Cast-anim suppression (SpellCastAnimFrame + InterruptDisplay): Hide the ANIMATED
    -- frame synchronously -- its animation group re-drives alpha on the next render
    -- tick, so SetAlpha(0) plus a deferred Hide leaks a one-frame blink of the cast
    -- sweep, while a hidden frame renders no animations. The deferred Hide stays as a
    -- fallback reset. Insecure UNIT_SPELLCAST/OnShow context, IsForbidden-guarded.
    if (btn.SpellCastAnimFrame and not fd.castHooked)
       or (btn.InterruptDisplay and not fd.intHooked) then
        local hideCastAnim = function(self)
            local prof = EAB.db and EAB.db.profile
            if not prof then return end
            local bfd = EFD(btn)
            if not prof.hideCastingAnimations and not bfd.shapeApplied and not bfd.cropped then return end
            self:SetAlpha(0)
            if not self:IsForbidden() then self:Hide() end
            EAB_VTABLE.HideRegionDeferred(self, 1)
        end
        if btn.SpellCastAnimFrame and not fd.castHooked then
            btn.SpellCastAnimFrame:HookScript("OnShow", hideCastAnim)
            fd.castHooked = true
        end
        if btn.InterruptDisplay and not fd.intHooked then
            btn.InterruptDisplay:HookScript("OnShow", hideCastAnim)
            fd.intHooked = true
        end
    end
    -- The cast-on-button anim's OnHide resets the swipe to opaque black on the
    -- button that hard-cast, clobbering the CD Swipe color/opacity setting there
    -- (cast-time spells only; instants never play the anim, and the suppression
    -- hook above trips the same OnHide at cast START). HookScript runs after the
    -- reset, so re-assert ours on the same edge -- fires only when a cast anim
    -- frame hides, nothing at idle.
    if btn.SpellCastAnimFrame and not fd.castSwipeHooked then
        fd.castSwipeHooked = true
        btn.SpellCastAnimFrame:HookScript("OnHide", function()
            local pdb = EAB.db and EAB.db.profile
            local cd = btn.cooldown
            if not pdb or not (cd and cd.SetSwipeColor) then return end
            local c = pdb.cdSwipeColor or { r = 0, g = 0, b = 0 }
            pcall(cd.SetSwipeColor, cd, c.r or 0, c.g or 0, c.b or 0, (pdb.cdSwipeAlpha or 80) / 100)
        end)
    end
    if btn.SlotBackground then
        btn.SlotBackground:SetAlpha(0)
        if not fd.slotBgHooked then
            fd.slotBgHooked = true
            hooksecurefunc(btn.SlotBackground, "SetAlpha", function(self, a)
                if (issecretvalue and issecretvalue(a)) or a ~= 0 then self:SetAlpha(0) end
            end)
        end
    end
    if not fd.slotBG then
        local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:SetAllPoints(btn)
        local sc = (_p and _p.slotBgColor) or { r = 0.15, g = 0.15, b = 0.15 }
        local so = _p and _p.slotBgOpacity
        if so == nil then so = 50 end
        bg:SetColorTexture(sc.r or 0.15, sc.g or 0.15, sc.b or 0.15, so / 100)
        fd.slotBG = bg
    end
    if btn.SlotArt then
        btn.SlotArt:SetAlpha(0)
        if not fd.slotArtHooked then
            fd.slotArtHooked = true
            hooksecurefunc(btn.SlotArt, "SetAlpha", function(self, a)
                if (issecretvalue and issecretvalue(a)) or a ~= 0 then self:SetAlpha(0) end
            end)
        end
    end
    -- Blizzard's equipped-item Border: it calls Border:SetAtlas()/Show() on
    -- refreshes and EAB owns the visible border, so it is suppressed, unless
    -- Show Equipped Border keeps it (in our square art).
    if btn.Border and not fd.borderHooked then
        local function BorderRefresh(self)
            if EAB.db.profile.showEquippedBorder then
                ns.AB_EquippedBorderLook(self)
            else
                self:SetAlpha(0)
                EAB_VTABLE.HideRegionDeferred(self)
            end
        end
        hooksecurefunc(btn.Border, "SetAtlas", BorderRefresh)
        hooksecurefunc(btn.Border, "Show", BorderRefresh)
        fd.borderHooked = true
    end
    fd.squared = true
end

local function EnsureBorders(btn)
    local fd = EFD(btn)
    if fd.borders then return fd.borders end
    local PP = EllesmereUI and EllesmereUI.PP
    if PP then
        PP.CreateBorder(btn, 0, 0, 0, 1, 1, "OVERLAY", 2)
        fd.borders = PP.GetBorders(btn)
        -- Reparent the flyout arrow INTO the border frame and lift it above the
        -- strips (OVERLAY sublevel 2, from PP.CreateBorder above): sharing the
        -- frame is not enough, without a higher sublevel the arrow draws under.
        if btn.Arrow then
            btn.Arrow:SetParent(fd.borders)
            if btn.Arrow.SetDrawLayer then
                btn.Arrow:SetDrawLayer("OVERLAY", 7)
            elseif btn.Arrow.SetFrameLevel then
                btn.Arrow:SetFrameLevel(fd.borders:GetFrameLevel() + 1)
            end
        end
    end
    return fd.borders
end

-- Frame level of a button's textured border backdrop (the bar border and its
-- Match Bar Border copy). "Show Behind": level-1 draws behind the icon.
-- "Border Above Effects": +20 clears the proc glow wrapper (+10), the assist
-- overlay (+14) and ring (+15), the cooldown swipe and the item-rank diamond
-- (+18). Otherwise the button's own level, in front of the icon. Show Behind
-- wins. On ns: the main chunk is at the 200-local cap.
ns._eabBorderLevel = function(btn, behind, above)
    local lvl = btn:GetFrameLevel()
    if behind then return max(0, lvl - 1) end
    if above then return lvl + 20 end
    return lvl
end

-- edgePx: the bar's exact size from ResolveBorderThickness (nil = legacy path).
-- above: the bar's "Border Above Effects" (textured borders only).
local function ApplyButtonBorders(btn, on, cr, cg, cb, ca, sz, zoom, textureKey, texOffset, texOffsetY, shiftX, shiftY, addonKey, sizeKey, behind, edgePx, above)
    MakeButtonSquare(btn)
    local PP = EllesmereUI and EllesmereUI.PP
    local fd = EFD(btn)
    if not on then
        if fd.borders then
            PP.HideBorder(btn)
        end
        -- Also hide textured border if present
        if EllesmereUI._bdBorderData then
            local bdFrame = EllesmereUI._bdBorderData[btn]
            if bdFrame then bdFrame:Hide() end
        end
        fd.borderKey = nil
    else
        local texKey = textureKey or "solid"
        if texKey ~= "solid" then
            -- Textured borders: always apply (cheap SetBackdropBorderColor call)
            fd.borderKey = nil
        else
            -- Solid borders: cache to avoid redundant PP updates (the exact size is
            -- a memo input of its own: a number or nil, compared as is)
            local es = btn:GetEffectiveScale()
            local stateKey = cr * 1000000 + cg * 10000 + cb * 100 + ca + sz * 0.001 + zoom * 10000000 + es * 0.0001
            if fd.borderKey == stateKey and fd.borderTexKey == texKey and fd.borderPxKey == edgePx then return end
            fd.borderKey = stateKey
        end
        fd.borderTexKey = texKey
        fd.borderPxKey = edgePx
        if texKey == "solid" then
            EnsureBorders(btn)
        elseif fd.borders then
            -- Switching from solid to textured: hide existing PP borders
            PP.HideBorder(btn)
            local ppC = PP.GetBorders(btn)
            if ppC then
                if ppC._top then ppC._top:SetAlpha(0) end
                if ppC._bottom then ppC._bottom:SetAlpha(0) end
                if ppC._left then ppC._left:SetAlpha(0) end
                if ppC._right then ppC._right:SetAlpha(0) end
            end
        end
        EllesmereUI.ApplyBorderStyle(btn, sz, cr, cg, cb, ca, textureKey, texOffset, texOffsetY, shiftX, shiftY, addonKey, sizeKey, nil, edgePx)
        -- "Show Behind": textured border frame is a child of btn; equal level draws
        -- in front of the icon, level-1 draws behind it. "Border Above Effects"
        -- raises it over the effects; turning it off lands back on the rule
        -- above on the next apply. Solid borders unaffected.
        if texKey ~= "solid" and EllesmereUI._bdBorderData then
            local bdFrame = EllesmereUI._bdBorderData[btn]
            if bdFrame then
                bdFrame:SetFrameLevel(ns._eabBorderLevel(btn, behind, above))
            end
        end
        if fd.borders and fd.shapeMask and fd.shapeMask:IsShown() then
            PP.HideBorder(btn)
            if EllesmereUI._bdBorderData then
                local bdFrame = EllesmereUI._bdBorderData[btn]
                if bdFrame then bdFrame:Hide() end
            end
        end
    end
    if zoom > 0 then
        local icon = btn.icon or btn.Icon
        if icon and icon.SetTexCoord and not (fd.shapeMask and fd.shapeMask:IsShown()) and not fd.cropped then
            icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        end
    end
end

-------------------------------------------------------------------------------
--  Shape Masking
-------------------------------------------------------------------------------
local function MaskFrameTextures(frame, mask)
    if not frame or not mask then return end
    for _, region in ipairs({frame:GetRegions()}) do
        if region.AddMaskTexture then
            pcall(region.AddMaskTexture, region, mask)
        end
    end
end

local function UnmaskFrameTextures(frame, mask)
    if not frame or not mask then return end
    for _, region in ipairs({frame:GetRegions()}) do
        if region.RemoveMaskTexture then
            pcall(region.RemoveMaskTexture, region, mask)
        end
    end
end

local function ApplyShapeToButton(btn, shape, brdOn, brdR, brdG, brdB, brdA, brdSize, zoom)
    _quickKeybindState.art.RefreshButton(btn)
    local fd = EFD(btn)

    if shape == "none" or shape == "cropped" then
        -- Remove shape mask if previously applied
        if fd.shapeMask then
            local mask = fd.shapeMask
            local icon = btn.icon or btn.Icon
            if icon then pcall(icon.RemoveMaskTexture, icon, mask) end
            -- Unmask slot BG and icon BG from main mask
            if fd.slotBG then pcall(fd.slotBG.RemoveMaskTexture, fd.slotBG, mask) end
            if fd.iconBg then pcall(fd.iconBg.RemoveMaskTexture, fd.iconBg, mask) end
            -- Unmask cooldown frames and restore default swipe
            if btn.cooldown and not btn.cooldown:IsForbidden() then
                pcall(btn.cooldown.RemoveMaskTexture, btn.cooldown, mask)
                pcall(btn.cooldown.SetSwipeTexture, btn.cooldown, "")
            end
            if btn.chargeCooldown and not btn.chargeCooldown:IsForbidden() then
                pcall(btn.chargeCooldown.RemoveMaskTexture, btn.chargeCooldown, mask)
                pcall(btn.chargeCooldown.SetSwipeTexture, btn.chargeCooldown, "")
            end
            -- Neutralize the mask so a stale reference cannot clip anything
            mask:SetTexture(nil)
            mask:ClearAllPoints()
            mask:SetSize(0.001, 0.001)
            mask:Hide()
        end
        -- Remove overlay mask if it existed
        if fd.overlayMask then
            local omask = fd.overlayMask
            if btn.HighlightTexture then pcall(btn.HighlightTexture.RemoveMaskTexture, btn.HighlightTexture, omask) end
            if btn.PushedTexture then pcall(btn.PushedTexture.RemoveMaskTexture, btn.PushedTexture, omask) end
            if btn.CheckedTexture then pcall(btn.CheckedTexture.RemoveMaskTexture, btn.CheckedTexture, omask) end
            if btn.NewActionTexture then pcall(btn.NewActionTexture.RemoveMaskTexture, btn.NewActionTexture, omask) end
            if btn.Flash then pcall(btn.Flash.RemoveMaskTexture, btn.Flash, omask) end
            if btn.QuickKeybindHighlightTexture then pcall(btn.QuickKeybindHighlightTexture.RemoveMaskTexture, btn.QuickKeybindHighlightTexture, omask) end
            if btn.Border then pcall(btn.Border.RemoveMaskTexture, btn.Border, omask) end
            local nt = btn.NormalTexture or btn:GetNormalTexture()
            if nt then pcall(nt.RemoveMaskTexture, nt, omask) end
            if btn.SpellActivationAlert then
                UnmaskFrameTextures(btn.SpellActivationAlert, omask)
                EFD(btn.SpellActivationAlert).shapeMasked = nil
            end
            omask:SetTexture(nil)
            omask:ClearAllPoints()
            omask:SetSize(0.001, 0.001)
            omask:Hide()
        elseif fd.shapeMask then
            -- Overlays were on the main mask (no border case) clean them off
            local mask = fd.shapeMask
            if btn.HighlightTexture then pcall(btn.HighlightTexture.RemoveMaskTexture, btn.HighlightTexture, mask) end
            if btn.PushedTexture then pcall(btn.PushedTexture.RemoveMaskTexture, btn.PushedTexture, mask) end
            if btn.CheckedTexture then pcall(btn.CheckedTexture.RemoveMaskTexture, btn.CheckedTexture, mask) end
            if btn.NewActionTexture then pcall(btn.NewActionTexture.RemoveMaskTexture, btn.NewActionTexture, mask) end
            if btn.Flash then pcall(btn.Flash.RemoveMaskTexture, btn.Flash, mask) end
            if btn.QuickKeybindHighlightTexture then pcall(btn.QuickKeybindHighlightTexture.RemoveMaskTexture, btn.QuickKeybindHighlightTexture, mask) end
            if btn.Border then pcall(btn.Border.RemoveMaskTexture, btn.Border, mask) end
            local nt = btn.NormalTexture or btn:GetNormalTexture()
            if nt then pcall(nt.RemoveMaskTexture, nt, mask) end
            if btn.SpellActivationAlert then
                UnmaskFrameTextures(btn.SpellActivationAlert, mask)
                EFD(btn.SpellActivationAlert).shapeMasked = nil
            end
        end
        -- Clean up glow wrapper mask
        if fd.glowWrapper then
            local mask = fd.shapeMask
            if mask then UnmaskFrameTextures(fd.glowWrapper, mask) end
            local wfd = EFD(fd.glowWrapper)
            if wfd.ownMask then
                UnmaskFrameTextures(fd.glowWrapper, wfd.ownMask)
                wfd.ownMask:Hide()
            end
        end
        if fd.shapeBorder then
            fd.shapeBorder:Hide()
            EFD(fd.shapeBorder).wantsShow = false
            fd.shapeBorder:SetTexture(nil)
        end
        -- Clear shape tracking flags
        fd.shapeApplied = nil
        fd.shapeName = nil
        fd.shapeMaskPath = nil
        -- Restore cooldown edge to default (non-circular, not forced on)
        if btn.cooldown and not btn.cooldown:IsForbidden() then
            if btn.cooldown.SetUseCircularEdge then pcall(btn.cooldown.SetUseCircularEdge, btn.cooldown, false) end
        end
        if btn.chargeCooldown and not btn.chargeCooldown:IsForbidden() then
            if btn.chargeCooldown.SetUseCircularEdge then pcall(btn.chargeCooldown.SetUseCircularEdge, btn.chargeCooldown, false) end
        end
        -- Restore icon
        local icon = btn.icon or btn.Icon
        if icon then
            icon:ClearAllPoints()
            icon:SetSize(0, 0)
            icon:SetAllPoints(btn)
            if shape == "cropped" then
                local z = (zoom or 0)
                icon:SetTexCoord(z, 1 - z, z + 0.10, 1 - z - 0.10)
                fd.cropped = true
            else
                fd.cropped = false
                if zoom and zoom > 0 then
                    icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
                else
                    icon:SetTexCoord(0, 1, 0, 1)
                end
            end
        end
        -- Show square borders only if border is enabled
        if fd.borders and brdOn then
            -- Re-apply border style to restore correct type (PP or textured)
            local barKey = fd.barKey
            local texKey = barKey and EAB.db and EAB.db.profile.bars[barKey] and EAB.db.profile.bars[barKey].borderTexture or "solid"
            if texKey ~= "solid" then
                local s = EAB.db.profile.bars[barKey]
                local c = s and s.borderColor or { r=0, g=0, b=0, a=1 }
                local sz, px = ResolveBorderThickness(s)
                local thKey = s.borderThickness or "thin"
                EllesmereUI.ApplyBorderStyle(btn, sz, c.r, c.g, c.b, c.a or 1, texKey, s.borderTextureOffset, s.borderTextureOffsetY, s.borderTextureShiftX, s.borderTextureShiftY, "actionbars", thKey, nil, px)
                if EllesmereUI._bdBorderData then
                    local bdFrame = EllesmereUI._bdBorderData[btn]
                    if bdFrame then
                        bdFrame:SetFrameLevel(ns._eabBorderLevel(btn, s.borderBehind, s.borderAboveEffects))
                    end
                end
            else
                PP.ShowBorder(btn)
            end
        elseif fd.borders then
            PP.HideBorder(btn)
            if EllesmereUI._bdBorderData then
                local bdFrame = EllesmereUI._bdBorderData[btn]
                if bdFrame then bdFrame:Hide() end
            end
        end
        -- Re-enable Blizzard's Border texture (was hidden for custom shapes)
        if btn.Border then
            SetSquareTexture(btn.Border, HIGHLIGHT_TEXTURES[1])
        end
        return
    end

    -- Custom shape
    local maskTex = SHAPE_MASKS[shape]
    if not maskTex then return end

    if not fd.shapeMask then
        fd.shapeMask = btn:CreateMaskTexture()
    end
    local mask = fd.shapeMask
    mask:SetTexture(maskTex, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:Show()

    local icon = btn.icon or btn.Icon

    -- Always remove existing mask references before re-adding
    -- (AddMaskTexture is additive; stale references cause shape-inside-shape)
    if icon then pcall(icon.RemoveMaskTexture, icon, mask) end
    if fd.slotBG then pcall(fd.slotBG.RemoveMaskTexture, fd.slotBG, mask) end
    if fd.iconBg then pcall(fd.iconBg.RemoveMaskTexture, fd.iconBg, mask) end
    if btn.cooldown and not btn.cooldown:IsForbidden() then
        pcall(btn.cooldown.RemoveMaskTexture, btn.cooldown, mask)
    end
    if btn.chargeCooldown and not btn.chargeCooldown:IsForbidden() then
        pcall(btn.chargeCooldown.RemoveMaskTexture, btn.chargeCooldown, mask)
    end
    do
        -- Remove overlay textures from whichever mask they were on
        local omask = fd.overlayMask or mask
        if btn.HighlightTexture then pcall(btn.HighlightTexture.RemoveMaskTexture, btn.HighlightTexture, omask) end
        if btn.PushedTexture then pcall(btn.PushedTexture.RemoveMaskTexture, btn.PushedTexture, omask) end
        if btn.CheckedTexture then pcall(btn.CheckedTexture.RemoveMaskTexture, btn.CheckedTexture, omask) end
        if btn.NewActionTexture then pcall(btn.NewActionTexture.RemoveMaskTexture, btn.NewActionTexture, omask) end
        if btn.Flash then pcall(btn.Flash.RemoveMaskTexture, btn.Flash, omask) end
        if btn.QuickKeybindHighlightTexture then pcall(btn.QuickKeybindHighlightTexture.RemoveMaskTexture, btn.QuickKeybindHighlightTexture, omask) end
        if btn.Border then pcall(btn.Border.RemoveMaskTexture, btn.Border, omask) end
        local nt2 = btn.NormalTexture or btn:GetNormalTexture()
        if nt2 then pcall(nt2.RemoveMaskTexture, nt2, omask) end
        if btn.SpellActivationAlert then
            UnmaskFrameTextures(btn.SpellActivationAlert, omask)
            EFD(btn.SpellActivationAlert).shapeMasked = nil
        end
        -- Also clean from main mask if overlay mask was separate
        if fd.overlayMask and fd.overlayMask ~= mask then
            if btn.HighlightTexture then pcall(btn.HighlightTexture.RemoveMaskTexture, btn.HighlightTexture, mask) end
            if btn.PushedTexture then pcall(btn.PushedTexture.RemoveMaskTexture, btn.PushedTexture, mask) end
            if btn.CheckedTexture then pcall(btn.CheckedTexture.RemoveMaskTexture, btn.CheckedTexture, mask) end
            if btn.NewActionTexture then pcall(btn.NewActionTexture.RemoveMaskTexture, btn.NewActionTexture, mask) end
            if btn.Flash then pcall(btn.Flash.RemoveMaskTexture, btn.Flash, mask) end
            if btn.QuickKeybindHighlightTexture then pcall(btn.QuickKeybindHighlightTexture.RemoveMaskTexture, btn.QuickKeybindHighlightTexture, mask) end
            if btn.Border then pcall(btn.Border.RemoveMaskTexture, btn.Border, mask) end
            if nt2 then pcall(nt2.RemoveMaskTexture, nt2, mask) end
        end
        if fd.glowWrapper then
            UnmaskFrameTextures(fd.glowWrapper, mask)
            local wfd = EFD(fd.glowWrapper)
            if wfd.ownMask then
                UnmaskFrameTextures(fd.glowWrapper, wfd.ownMask)
            end
        end
    end

    -- Apply mask to icon
    if icon then icon:AddMaskTexture(mask) end

    -- Overlay/animation mask: with a border (brdSize >= 1) use a separate inset
    -- mask so animations stop at the border edge instead of bleeding past it.
    local overlayMask
    if brdSize and brdSize >= 1 then
        if not fd.overlayMask then
            fd.overlayMask = btn:CreateMaskTexture()
        end
        overlayMask = fd.overlayMask
        overlayMask:SetTexture(maskTex, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        overlayMask:ClearAllPoints()
        local inset = 3
        PP.Point(overlayMask, "TOPLEFT", btn, "TOPLEFT", inset, -inset)
        PP.Point(overlayMask, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", -inset, inset)
        overlayMask:Show()
    else
        -- No border overlays share the main mask, hide overlay mask if it exists
        if fd.overlayMask then fd.overlayMask:Hide() end
        overlayMask = mask
    end

    -- Apply overlay mask to all button overlay textures
    if btn.HighlightTexture then pcall(btn.HighlightTexture.AddMaskTexture, btn.HighlightTexture, overlayMask) end
    if btn.PushedTexture then pcall(btn.PushedTexture.AddMaskTexture, btn.PushedTexture, overlayMask) end
    if btn.CheckedTexture then pcall(btn.CheckedTexture.AddMaskTexture, btn.CheckedTexture, overlayMask) end
    if btn.NewActionTexture then pcall(btn.NewActionTexture.AddMaskTexture, btn.NewActionTexture, overlayMask) end
    if btn.Flash then pcall(btn.Flash.AddMaskTexture, btn.Flash, overlayMask) end
    if btn.QuickKeybindHighlightTexture then pcall(btn.QuickKeybindHighlightTexture.AddMaskTexture, btn.QuickKeybindHighlightTexture, overlayMask) end
    -- Blizzard's item-quality Border uses a round atlas that does not match
    -- non-square shapes, so hide it whenever a custom shape is on.
    if btn.Border then
        btn.Border:Hide()
    end
    if fd.slotBG then pcall(fd.slotBG.AddMaskTexture, fd.slotBG, mask) end
    if fd.iconBg then pcall(fd.iconBg.AddMaskTexture, fd.iconBg, mask) end
    local nt = btn.NormalTexture or btn:GetNormalTexture()
    if nt then pcall(nt.AddMaskTexture, nt, overlayMask) end

    -- Expand icon beyond button frame
    local shapeOffset = SHAPE_ICON_EXPAND_OFFSETS[shape] or 0
    local shapeDefault = (SHAPE_ZOOM_DEFAULTS[shape] or 6.0) / 100
    local iconExp = SHAPE_ICON_EXPAND + shapeOffset + ((zoom or 0) - shapeDefault) * 200
    if iconExp < 0 then iconExp = 0 end
    local halfIE = iconExp / 2
    if icon then
        icon:ClearAllPoints()
        PP.Point(icon, "TOPLEFT", btn, "TOPLEFT", -halfIE, halfIE)
        PP.Point(icon, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", halfIE, -halfIE)
    end

    -- Mask inset for border
    mask:ClearAllPoints()
    if brdSize and brdSize >= 1 then
        PP.Point(mask, "TOPLEFT", btn, "TOPLEFT", 1, -1)
        PP.Point(mask, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    else
        mask:SetAllPoints(btn)
    end

    -- Expand texcoords
    local insetPx = SHAPE_INSETS[shape] or 17
    local visRatio = (128 - 2 * insetPx) / 128
    local expand = ((1 / visRatio) - 1) * 0.5
    if icon then icon:SetTexCoord(-expand, 1 + expand, -expand, 1 + expand) end

    -- Hide square borders (both PP and textured)
    if fd.borders then
        PP.HideBorder(btn)
        if EllesmereUI._bdBorderData then
            local bdFrame = EllesmereUI._bdBorderData[btn]
            if bdFrame then bdFrame:Hide() end
        end
    end

    -- Shape border texture
    if not fd.shapeBorder then
        fd.shapeBorder = btn:CreateTexture(nil, "OVERLAY", nil, 6)
    end
    local borderTex = fd.shapeBorder
    pcall(borderTex.RemoveMaskTexture, borderTex, mask)
    borderTex:ClearAllPoints()
    borderTex:SetAllPoints(btn)
    local btfd = EFD(borderTex)
    if brdOn and SHAPE_BORDERS[shape] then
        borderTex:SetTexture(SHAPE_BORDERS[shape])
        borderTex:SetVertexColor(brdR, brdG, brdB, brdA)
        borderTex:Show()
        btfd.wantsShow = true
    else
        borderTex:Hide()
        btfd.wantsShow = false
    end

    -- Apply mask to cooldown frames so swipe follows the shape
    if btn.cooldown and not btn.cooldown:IsForbidden() then
        pcall(btn.cooldown.AddMaskTexture, btn.cooldown, mask)
        if btn.cooldown.SetSwipeTexture then
            pcall(btn.cooldown.SetSwipeTexture, btn.cooldown, maskTex)
        end
    end
    if btn.chargeCooldown and not btn.chargeCooldown:IsForbidden() then
        pcall(btn.chargeCooldown.AddMaskTexture, btn.chargeCooldown, mask)
        if btn.chargeCooldown.SetSwipeTexture then
            pcall(btn.chargeCooldown.SetSwipeTexture, btn.chargeCooldown, maskTex)
        end
    end

    -- Mask proc glow animation frames
    if btn.SpellActivationAlert then
        MaskFrameTextures(btn.SpellActivationAlert, overlayMask)
        EFD(btn.SpellActivationAlert).shapeMasked = true
    end
    if fd.glowWrapper then
        local w = fd.glowWrapper
        local wfd = EFD(w)
        if not wfd.ownMask then
            wfd.ownMask = w:CreateMaskTexture()
        end
        wfd.ownMask:ClearAllPoints()
        PP.Point(wfd.ownMask, "TOPLEFT", btn, "TOPLEFT", 1, -1)
        PP.Point(wfd.ownMask, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        wfd.ownMask:SetTexture(maskTex, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        wfd.ownMask:Show()
        MaskFrameTextures(w, wfd.ownMask)
    end

    -- Store shape tracking flags for cooldown edge system
    fd.shapeApplied = true
    fd.shapeName = shape
    fd.shapeMaskPath = maskTex

    -- Apply shape-specific cooldown edge: circular edge for non-square shapes,
    -- per-shape scale, custom texture + current color.
    local shapeEdgeScale = SHAPE_EDGE_SCALES[shape] or 0.60
    local useCircular = (shape ~= "square" and shape ~= "csquare")
    do
        local edgeTex = "Interface\\AddOns\\EllesmereUIActionBars\\Media\\edge.png"
        local p = EAB.db and EAB.db.profile
        local cr, cg, cb, ca = 0.973, 0.839, 0.604, 1
        if p then
            if p.cooldownEdgeUseClassColor then
                local _, cls = UnitClass("player")
                local cc = RAID_CLASS_COLORS[cls]
                if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                ca = (p.cooldownEdgeColor and p.cooldownEdgeColor.a) or 1
            elseif p.cooldownEdgeColor then
                cr = p.cooldownEdgeColor.r or cr
                cg = p.cooldownEdgeColor.g or cg
                cb = p.cooldownEdgeColor.b or cb
                ca = p.cooldownEdgeColor.a or ca
            end
        end
        for _, cd in ipairs({btn.cooldown, btn.chargeCooldown}) do
            if cd and not cd:IsForbidden() then
                if cd.SetEdgeTexture then pcall(cd.SetEdgeTexture, cd, edgeTex) end
                if cd.SetEdgeColor then pcall(cd.SetEdgeColor, cd, cr, cg, cb, ca) end
                if cd.SetUseCircularEdge then pcall(cd.SetUseCircularEdge, cd, useCircular) end
                if cd.SetEdgeScale then pcall(cd.SetEdgeScale, cd, shapeEdgeScale) end
            end
        end
    end

    fd.cropped = false
end

-------------------------------------------------------------------------------
--  Out-of-Range Icon Coloring: ACTION_RANGE_CHECK_UPDATE tints action button
--  icons when the target is out of range. Each slot opts in via
--  C_ActionBar.EnableActionRangeCheck so the client fires the event only for
--  slots we care about.
-------------------------------------------------------------------------------
local _range = {
    slots = {},           -- [actionSlot] = refcount (bars currently holding range checking on the slot)
    barSlots = {},        -- [barKey] = { [actionSlot] = true } acquisition snapshot
    outOfRange = {},      -- [actionSlot] = true  (currently out of range)
    eventFrame = nil,     -- lazy-created event frame
    slotPending = false,  -- debounce for per-slot range re-enable
}

-- Resolve a button's action slot without reading btn.action: protected
-- (secret value in Midnight), reading it in combat taints. Uses a lookup
-- table built at setup; MainBar derives the page offset from the bar frame's
-- actionpage attribute (set by _onstate-page).
local function GetButtonActionSlot(btn)
    local info = buttonToBar[btn]
    if not info then return nil end
    local offset = BAR_SLOT_OFFSETS[info.barKey]
    if not offset then return nil end
    if info.barKey == "MainBar" then
        -- actionpage is set by the _onstate-page handler in the restricted env
        -- and reflects vehicle/override/form pages, unlike
        -- C_ActionBar.GetActionBarPage() which tracks only the manual page.
        local frame = barFrames["MainBar"]
        local page = frame and tonumber(frame:GetAttribute("actionpage")) or EAB_VTABLE.GetActionBarPage()
        offset = (page - 1) * NUM_ACTIONBAR_BUTTONS
    end
    return offset + info.index
end

-- Apply or remove the range tint on a single button
local function ApplyRangeTint(btn, outOfRange, barSettings)
    local ico = btn.icon or btn.Icon
    if not ico then return end
    local rfd = EFD(btn)
    if outOfRange and barSettings.outOfRangeColoring then
        local c = barSettings.outOfRangeColor or { r = 0.7, g = 0.2, b = 0.2 }
        ico:SetVertexColor(c.r, c.g, c.b)
        rfd.rangeTinted = true
    elseif rfd.rangeTinted then
        rfd.rangeTinted = nil
        -- Let Blizzard's UpdateUsable set the correct color (may be dimmed
        -- for insufficient resources) instead of forcing full white.
        if btn.UpdateUsable then
            btn:UpdateUsable()
        else
            ico:SetVertexColor(1, 1, 1)
        end
    end
end

-- Slot acquisition is REFCOUNTED: pages duplicate slots across bars, so a plain boolean
-- lets one bar's release kill another bar's live tracking, and resolving slots at
-- release time strands the old page's slots enabled forever when a page flip lands
-- between acquire and release. Each bar releases exactly the snapshot it acquired; the
-- engine call happens only on 0<->1 edges. Dormant bars release entirely so they stop
-- GENERATING ACTION_RANGE_CHECK_UPDATE traffic (otherwise every hidden bar's slots stay
-- range-enabled and each fire walks all bars).

-- Release whatever the bar snapshot holds (no slot resolution: the snapshot
-- IS what was acquired, immune to page drift). On ns: chunk at the 200-local cap.
ns._eabReleaseRangeSlots = function(barKey)
    local held = _range.barSlots[barKey]
    if not held then return end
    _range.barSlots[barKey] = nil
    for slot in pairs(held) do
        local n = _range.slots[slot]
        if n and n > 1 then
            _range.slots[slot] = n - 1
        else
            _range.slots[slot] = nil
            _range.outOfRange[slot] = nil
            if C_ActionBar and C_ActionBar.EnableActionRangeCheck then
                pcall(C_ActionBar.EnableActionRangeCheck, slot, false)
            end
        end
    end
end

-- Re-evaluate a bar's range state from the live API and repaint it.
-- Acquiring a slot yields NO initial state: EnableActionRangeCheck is silent
-- until the next transition, so a slot whose refcount just went 0->1 has
-- nothing to paint from and the release-wiped cache entry stays wiped. The
-- flip handler's "no change, return" gate then swallows the next report,
-- stranding the last painted tint. On ns: chunk at the 200-local cap.
ns._eabRangeSweepBar = function(barKey)
    local buttons = barButtons[barKey]
    local s = EAB.db.profile.bars[barKey]
    if not buttons or not s or not s.outOfRangeColoring then return end
    if ns._eabBarDormant[barKey] then return end
    for _, btn in ipairs(buttons) do
        local slot = GetButtonActionSlot(btn)
        if slot and HasAction(slot) then
            local isOut = (IsActionInRange(slot) == false)
            _range.outOfRange[slot] = isOut or nil
            ApplyRangeTint(btn, isOut, s)
        elseif slot then
            -- Slot lost its action (talent swap, drag): clear stale tint.
            _range.outOfRange[slot] = nil
            ApplyRangeTint(btn, false, s)
        end
    end
end

-- Enable range checking for all active button slots on a bar
local function EnableRangeCheckForBar(barKey)
    local buttons = barButtons[barKey]
    if not buttons then return end
    local s = EAB.db.profile.bars[barKey]
    if not s or not s.outOfRangeColoring then return end
    -- Dormant bars acquire nothing; the show edge re-runs this.
    if ns._eabBarDormant[barKey] then return end
    -- Re-acquire from scratch: releasing the old snapshot first makes this
    -- idempotent under page flips (debounced SLOT_CHANGED re-enable and the
    -- PAGE_CHANGED pass both land here).
    ns._eabReleaseRangeSlots(barKey)
    local held = {}
    _range.barSlots[barKey] = held
    for _, btn in ipairs(buttons) do
        local slot = GetButtonActionSlot(btn)
        if slot and not held[slot] then
            held[slot] = true
            local n = _range.slots[slot]
            if n then
                _range.slots[slot] = n + 1
            else
                _range.slots[slot] = 1
                if C_ActionBar and C_ActionBar.EnableActionRangeCheck then
                    pcall(C_ActionBar.EnableActionRangeCheck, slot, true)
                end
            end
        end
    end
    -- Every acquire path lands here, so post-acquire re-evaluation does too
    -- rather than in each caller. Unconditional: a bar sharing slots another
    -- bar already holds takes no 0->1 edge but still needs its buttons painted.
    ns._eabRangeSweepBar(barKey)
end

-- Disable range checking for all slots on a bar and clear tints
local function DisableRangeCheckForBar(barKey)
    ns._eabReleaseRangeSlots(barKey)
    local buttons = barButtons[barKey]
    if not buttons then return end
    for _, btn in ipairs(buttons) do
        local rfd = EFD(btn)
        if rfd.rangeTinted then
            rfd.rangeTinted = nil
            if btn.UpdateUsable then
                btn:UpdateUsable()
            else
                local ico = btn.icon or btn.Icon
                if ico then ico:SetVertexColor(1, 1, 1) end
            end
        end
    end
end

-- Dormancy edges for range (via ns: ApplyBarDormancy is defined earlier in
-- the chunk). Hide releases the bar's slots; show re-acquires and the sweep
-- repaints from the LIVE API -- repainting from cache would paint every
-- button in-range, since the hide-time release wiped the bar's entries.
ns._eabRangeBarDormancy = function(barKey, dormant)
    if dormant then
        ns._eabReleaseRangeSlots(barKey)
        return
    end
    EnableRangeCheckForBar(barKey)
end

-- Recompute a bar's flyout direction from its current screen position.
function EAB:RecalcFlyoutDirection(barKey)
    if InCombatLockdown() then return end
    local frame = barFrames[barKey]
    local btns = barButtons[barKey]
    local s = self.db.profile.bars[barKey]
    if not frame or not btns or not s then return end
    local isVert = (s.orientation == "vertical")
    local cx, cy = frame:GetCenter()
    if not cx or not cy then return end
    local uiW = UIParent:GetWidth()
    local uiH = UIParent:GetHeight()
    local uiScale = UIParent:GetEffectiveScale()
    local fScale  = frame:GetEffectiveScale()
    cx = cx * fScale / uiScale
    cy = cy * fScale / uiScale
    local thirdW = uiW / 3
    local thirdH = uiH / 3
    local dir
    if isVert then
        dir = (cx > thirdW * 2) and "LEFT" or "RIGHT"
    else
        dir = (cy > thirdH * 2) and "DOWN" or "UP"
    end
    for _, btn in ipairs(btns) do
        btn:SetAttribute("flyoutDirection", dir)
    end
end

function EAB:ApplyRangeColoring()
    -- Set up the event listener BEFORE enabling range checks so any
    -- immediate ACTION_RANGE_CHECK_UPDATE events are caught.
    if not _range.eventFrame then
        -- No offset snapshot needed: GetButtonActionSlot reads the bar
        -- frame's actionpage attribute dynamically for MainBar.
        _range.eventFrame = ns.TakeShell()
        EUI_SafeRegisterEvent(_range.eventFrame, "ACTION_RANGE_CHECK_UPDATE")
        _range.eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        _range.eventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        EUI_SafeRegisterEvent(_range.eventFrame, "ACTION_USABLE_CHANGED")
        _range.eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
        _range.eventFrame:SetScript("OnEvent", function(_, event, slot, inRange, checksRange)
            if event == "ACTION_RANGE_CHECK_UPDATE" then
                if not _range.slots[slot] then return end
                local wasOut = _range.outOfRange[slot]
                local isOut = checksRange and not inRange
                local changed = false
                if isOut and not wasOut then
                    _range.outOfRange[slot] = true
                    changed = true
                elseif not isOut and wasOut then
                    _range.outOfRange[slot] = nil
                    changed = true
                end
                if not changed then return end
                local bars = EAB.db.profile.bars
                -- Slot->buttons map fast path (dispatcher-maintained) avoids
                -- scanning all bars x all buttons per flip. Belt: re-verify
                -- the live slot per hit so a stale entry can only skip, never
                -- mis-tint; paging edges that stale the map also wipe and
                -- re-derive range state, healing anything skipped. Dormant
                -- bars skip (reveal repaints from the outOfRange cache).
                local smap = ns._slotBtnMap
                local mapClean = smap and not ns._slotBtnMapDirty
                local hosts = mapClean and smap[slot] or nil
                if hosts then
                    for i = 1, #hosts do
                        local btn = hosts[i]
                        if GetButtonActionSlot(btn) == slot then
                            local bInfo = buttonToBar[btn]
                            local s = bInfo and bars[bInfo.barKey]
                            if s and s.outOfRangeColoring
                                and not ns._eabBarDormant[bInfo.barKey] then
                                ApplyRangeTint(btn, isOut, s)
                            end
                        end
                    end
                else
                    -- Map absent/dirty, or CLEAN BUT MISSING a slot the engine
                    -- is live-flipping (a paging edge remapped hosting with no
                    -- rebuild edge this map sees; modifier paging fires no
                    -- event here). Dropping the flip strands the tint until
                    -- the slot's NEXT transition, accumulating into
                    -- permanently stale bars, so fail OPEN with the full scan
                    -- and retire the map for the next SLOT_CHANGED to rebuild.
                    if mapClean then
                        ns._slotBtnMapDirty = true
                    end
                    for _, info in ipairs(BAR_CONFIG) do
                        local btns = barButtons[info.key]
                        local s = bars[info.key]
                        if btns and s and s.outOfRangeColoring
                            and not ns._eabBarDormant[info.key] then
                            for _, btn in ipairs(btns) do
                                if GetButtonActionSlot(btn) == slot then
                                    ApplyRangeTint(btn, isOut, s)
                                end
                            end
                        end
                    end
                end
            elseif event == "ACTIONBAR_SLOT_CHANGED" then
                -- When a slot changes (paging, drag, etc.), re-enable range
                -- checking for the new action and clear stale tint
                if slot and _range.slots[slot] then
                    if _range.outOfRange[slot] then
                        _range.outOfRange[slot] = nil
                        local bars2 = EAB.db.profile.bars
                        -- Same map fast path + re-verify belt + clean-miss
                        -- fail-open as the flip walk above: an over-skip here
                        -- strands a RED tint on an in-range button.
                        local smap2 = ns._slotBtnMap
                        local mapClean2 = smap2 and not ns._slotBtnMapDirty
                        local hosts2 = mapClean2 and smap2[slot] or nil
                        if hosts2 then
                            for i = 1, #hosts2 do
                                local btn2 = hosts2[i]
                                if GetButtonActionSlot(btn2) == slot then
                                    local bInfo2 = buttonToBar[btn2]
                                    local s2 = bInfo2 and bars2[bInfo2.barKey]
                                    if s2 then
                                        ApplyRangeTint(btn2, false, s2)
                                    end
                                end
                            end
                        else
                            if mapClean2 then
                                ns._slotBtnMapDirty = true
                            end
                            for _, info2 in ipairs(BAR_CONFIG) do
                                local btns2 = barButtons[info2.key]
                                local s2 = bars2[info2.key]
                                if btns2 and s2 then
                                    for _, btn2 in ipairs(btns2) do
                                        if GetButtonActionSlot(btn2) == slot then
                                            ApplyRangeTint(btn2, false, s2)
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if C_ActionBar and C_ActionBar.EnableActionRangeCheck then
                        pcall(C_ActionBar.EnableActionRangeCheck, slot, true)
                    end
                end
                -- Debounce the full re-enable pass so 12+ per-slot fires
                -- during a bar page swap collapse into one deferred call.
                -- anyEnabled gate: feature fully off = no timer, no walk.
                if _range.anyEnabled and not _range.slotPending then
                    _range.slotPending = true
                    C_Timer_After(0, function()
                        _range.slotPending = false
                        for _, info in ipairs(BAR_CONFIG) do
                            local s = EAB.db.profile.bars[info.key]
                            if s and s.outOfRangeColoring then
                                EnableRangeCheckForBar(info.key)
                            end
                        end
                    end)
                end
            elseif event == "ACTIONBAR_PAGE_CHANGED" then
                -- No offset update needed: GetButtonActionSlot reads MainBar's
                -- actionpage attribute dynamically. A page flip remaps MainBar
                -- action ids with no per-slot SLOT_CHANGED, so the filled-slot
                -- fast lists must rebuild.
                ns._cdFilledDirty = true
                -- Clear all range state and re-enable for the new slots; skipped
                -- when the feature is off everywhere (the dirty flag above stays
                -- -- it belongs to the cooldown walker, not range).
                if not _range.anyEnabled then return end
                wipe(_range.outOfRange)
                for _, info in ipairs(BAR_CONFIG) do
                    local s = EAB.db.profile.bars[info.key]
                    if s and s.outOfRangeColoring then
                        local btns = barButtons[info.key]
                        if btns then
                            for _, btn in ipairs(btns) do
                                local rfd = EFD(btn)
                                if rfd.rangeTinted then
                                    local ico = btn.icon or btn.Icon
                                    if ico then ico:SetVertexColor(1, 1, 1) end
                                    rfd.rangeTinted = nil
                                end
                            end
                        end
                        EnableRangeCheckForBar(info.key)
                    end
                end
            elseif event == "ACTION_USABLE_CHANGED" then
                -- Blizzard resets icon vertex colors on usability changes;
                -- re-apply range tint on any out-of-range buttons.
                -- Bail fast when nothing is out of range (common case).
                if not next(_range.outOfRange) then return end
                for _, info in ipairs(BAR_CONFIG) do
                    local btns = barButtons[info.key]
                    local s = EAB.db.profile.bars[info.key]
                    if btns and s and s.outOfRangeColoring
                        and not ns._eabBarDormant[info.key] then
                        for _, btn in ipairs(btns) do
                            if EFD(btn).rangeTinted then
                                ApplyRangeTint(btn, true, s)
                            end
                        end
                    end
                end
            elseif event == "UPDATE_SHAPESHIFT_FORM" then
                -- Form shifts can fire ACTION_RANGE_CHECK_UPDATE with stale data
                -- before Blizzard settles, so defer a manual IsActionInRange
                -- poll. anyEnabled gate: feature fully off = no closure, no poll.
                if not _range.anyEnabled then return end
                C_Timer_After(0, function()
                    local bars = EAB.db.profile.bars
                    for _, info in ipairs(BAR_CONFIG) do
                        local s = bars[info.key]
                        if s and s.outOfRangeColoring
                            and not ns._eabBarDormant[info.key] then
                            local btns = barButtons[info.key]
                            if btns then
                                for _, btn in ipairs(btns) do
                                    local sl = GetButtonActionSlot(btn)
                                    if sl and HasAction(sl) then
                                        local inRange = IsActionInRange(sl)
                                        local isOut = (inRange == false)
                                        _range.outOfRange[sl] = isOut or nil
                                        ApplyRangeTint(btn, isOut, s)
                                    else
                                        if sl then _range.outOfRange[sl] = nil end
                                        ApplyRangeTint(btn, false, s)
                                    end
                                end
                            end
                        end
                    end
                end)
            end
        end)
    end

    local anyEnabled = nil
    for _, info in ipairs(BAR_CONFIG) do
        local key = info.key
        local s = self.db.profile.bars[key]
        if s and s.outOfRangeColoring then
            anyEnabled = true
            -- The acquire path sweeps: EnableActionRangeCheck fires no initial
            -- event, so slots already out of range need the live poll.
            EnableRangeCheckForBar(key)
        else
            DisableRangeCheckForBar(key)
        end
    end
    -- Standing flag for the event branches above: with the feature off on every
    -- bar the SLOT_CHANGED debounce and form-shift poll schedule NOTHING.
    -- Recomputed on every settings apply -- the single enable/disable funnel.
    _range.anyEnabled = anyEnabled

    -- Hook Blizzard's usability update so our range tint is re-applied
    -- after Blizzard resets the icon vertex color.
    for _, info in ipairs(BAR_CONFIG) do
        local btns = barButtons[info.key]
        if btns then
            for _, btn in ipairs(btns) do
                if not EFD(btn).rangeHooked and btn.UpdateUsable then
                    EFD(btn).rangeHooked = true
                    hooksecurefunc(btn, "UpdateUsable", function(self)
                        if not EFD(self).rangeTinted then return end
                        local slot = GetButtonActionSlot(self)
                        if slot and _range.outOfRange[slot] then
                            local bInfo = buttonToBar[self]
                            local s = bInfo and EAB.db.profile.bars[bInfo.barKey]
                            if s and s.outOfRangeColoring then
                                ApplyRangeTint(self, true, s)
                            end
                        end
                    end)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Mouseover Fade System
-------------------------------------------------------------------------------
local hoverStates = {}  -- shared by action bars, data bars, and extra bars

-- Every mouseover-enabled bar follows the same state machine: entering marks
-- it hovered and fades in, leaving schedules a guarded fade-out on the next
-- frame. Per-bar attach functions only provide edge-case policies that differ
-- between action bars, data bars, and Blizzard-owned extra bars.
function EAB_VTABLE.Hover.GetSettings(barKey)
    return EAB.db and EAB.db.profile and EAB.db.profile.bars and EAB.db.profile.bars[barKey]
end

function EAB_VTABLE.Hover.GetState(barKey, frame)
    local state = hoverStates[barKey]
    if not state then
        state = { frame = frame, isHovered = false, fadeDir = nil }
        hoverStates[barKey] = state
    else
        state.frame = frame or state.frame
    end
    return state
end

-- The alpha a bar RESTS at while the cursor is not on it, plus whether that resting state
-- is a hover gate. Single source of truth for every alpha writer here, so a fade-out
-- cannot land on a different verdict than the visibility refresh would. mouseoverEnabled
-- is STATIC (true whenever mouseover is selected at all, any Match Mode), so it can only
-- answer "is the hover mechanism wired"; VisWantsMouseover answers "is it gating now".
-- _savedBarAlpha is load-bearing: ApplyMode parks mouseoverAlpha at 0 and stashes the real
-- value there while a mouseover selection is stored, so the shown branch would paint 0.
-- On the vtable, not a chunk local (main chunk is at the 200-local cap).
function EAB_VTABLE.Hover.RestingAlpha(barKey, s)
    s = s or EAB_VTABLE.Hover.GetSettings(barKey)
    if not s then return 1, false end
    local wantsHover
    if s.mouseoverEnabled and EllesmereUI.VisWantsMouseover then
        wantsHover = EllesmereUI.VisWantsMouseover(s, "barVisibility", nil, EllesmereUI.VIS_CAPS_DEFAULT)
    else
        wantsHover = s.mouseoverEnabled
    end
    if wantsHover then return 0, true end
    return s._savedBarAlpha or s.mouseoverAlpha or 1, false
end

-- Fade ONE bar in, no broadcast. The fadeDir memo makes repeat calls while
-- already fading/faded O(1) table reads, so a sweep across a bar's 12 buttons
-- costs 12 memo hits and one real fade. On the vtable, not a chunk local
-- (main chunk is at the 200-local cap).
function EAB_VTABLE.Hover.FadeInOne(barKey, state)
    local s = EAB_VTABLE.Hover.GetSettings(barKey)
    if s and s.mouseoverEnabled and state and state.fadeDir ~= "in" then
        local targetAlpha = s._savedBarAlpha or 1
        state.fadeDir = "in"
        StopFade(state.frame)
        -- The shared per-frame fader starts a show-all edge on every bar in
        -- the same frame (lockstep, no ripple).
        FadeTo(state.frame, targetAlpha, s.mouseoverSpeed or 0.15)
        if barKey == "MainBar" then SyncPagingAlpha(targetAlpha) end
    end
end

function EAB_VTABLE.Hover.FadeIn(barKey, state)
    EAB_VTABLE.Hover.FadeInOne(barKey, state)
    -- "Show All on Mouseover": bring other bars along, all starting THIS
    -- frame in lockstep. Cheap because every fade rides the shared fader (a
    -- table write per bar). Iterative, not recursive: no reentrancy latch to get stuck.
    -- Gated on THIS bar being Mouseover itself -- AttachHoverHooks wires the
    -- same OnEnter onto every bar regardless of its own visibility mode, so
    -- without this check hovering an Always-visible bar broadcast the same
    -- as hovering a real Mouseover one (tooltip promises the latter only).
    local s = EAB_VTABLE.Hover.GetSettings(barKey)
    if s and s.mouseoverEnabled and EAB.db.profile.mouseoverShowAll then
        local FadeInOne = EAB_VTABLE.Hover.FadeInOne
        for otherKey, otherState in pairs(hoverStates) do
            if otherKey ~= barKey then
                FadeInOne(otherKey, otherState)
            end
        end
    end
end

function EAB_VTABLE.Hover.FadeOut(barKey, state)
    if _gridState.shown then return end  -- keep bars visible during spell drag
    local s = EAB_VTABLE.Hover.GetSettings(barKey)
    if s and s.mouseoverEnabled and state and state.fadeDir ~= "out" then
        -- Fade back to the bar's RESTING alpha, not a hardcoded 0: under Any a passing
        -- disjunct keeps the bar visible with no hover involved, and fading it away here
        -- would leave it wrong until the next visibility refresh.
        local resting = EAB_VTABLE.Hover.RestingAlpha(barKey, s)
        state.fadeDir = "out"
        StopFade(state.frame)
        FadeTo(state.frame, resting, s.mouseoverSpeed or 0.15)
        if barKey == "MainBar" then SyncPagingAlpha(resting) end
    end
end

-- Check if any mouseover-enabled bar is currently hovered.
function ns.AnyMouseoverBarHovered()
    for otherKey, otherState in pairs(hoverStates) do
        if otherState.isHovered then
            local os = EAB_VTABLE.Hover.GetSettings(otherKey)
            if os and os.mouseoverEnabled then return true end
        end
    end
    return false
end

function EAB_VTABLE.Hover.ScheduleFadeOut(barKey, state, opts)
    opts = opts or {}

    -- The bar frame and every button hook OnLeave, so one mouse sweep across a
    -- 12-button bar lands here 12+ times. Coalesced: one pending timer per bar covers
    -- the whole sweep (same pattern as _range.slotPending) instead of a timer+closure
    -- per OnLeave each running the O(bars) hovered scan. Callback built once per state
    -- and reused; opts is stable per bar (one BuildHandlers call).
    if state.foPending then return end
    state.foPending = true
    local cb = state.foCb
    if not cb then
        cb = function()
            state.foPending = false
            if opts.isStillHovered and opts.isStillHovered(state) then
                if opts.markHoveredWhileActive then
                    state.isHovered = true
                end
                return
            end
            if state.isHovered then return end
            -- Ground truth: Enter/Leave interleaves between a bar frame and
            -- its children can leave isHovered false while the cursor never
            -- left the bar (fade flicker per twitch). One C call settles it.
            if state.frame and state.frame:IsMouseOver() then
                state.isHovered = true
                return
            end
            if _quickKeybindState.open then return end
            if opts.blockFadeOut and opts.blockFadeOut(state) then return end
            -- When showing all bars together, keep visible while any bar is hovered
            if EAB.db.profile.mouseoverShowAll and ns.AnyMouseoverBarHovered() then return end
            EAB_VTABLE.Hover.FadeOut(barKey, state)
            -- Broadcast fade-out to all other mouseover bars, lockstep
            -- (cheap via the shared fader, same as the fade-in broadcast).
            if EAB.db.profile.mouseoverShowAll then
                for otherKey, otherState in pairs(hoverStates) do
                    if otherKey ~= barKey and not otherState.isHovered then
                        EAB_VTABLE.Hover.FadeOut(otherKey, otherState)
                    end
                end
            end
        end
        state.foCb = cb
    end
    C_Timer_After(0.1, cb)
end

function EAB_VTABLE.Hover.BuildHandlers(barKey, state, opts)
    opts = opts or {}

    local function OnEnter(self)
        if opts.canEnter and not opts.canEnter(self, state) then return end
        state.isHovered = true
        EAB_VTABLE.Hover.FadeIn(barKey, state)
    end

    local function OnLeave()
        state.isHovered = false
        EAB_VTABLE.Hover.ScheduleFadeOut(barKey, state, opts)
    end

    return OnEnter, OnLeave
end

local function AttachDataBarHoverHooks(barKey)
    if hoverStates[barKey] then return end

    local frame = dataBarFrames[barKey]
    if not frame then return end

    local state = EAB_VTABLE.Hover.GetState(barKey, frame)
    local OnEnter, OnLeave = EAB_VTABLE.Hover.BuildHandlers(barKey, state)

    frame:HookScript("OnEnter", OnEnter)
    frame:HookScript("OnLeave", OnLeave)
end

local function AttachHoverHooks(barKey)
    -- Idempotency (same guard as both sibling attach functions): HookScript
    -- stacks and can never be unhooked, so a second pass would permanently
    -- double every hover handler on the bar and its 12 buttons.
    if hoverStates[barKey] then return end

    local frame = barFrames[barKey]
    local buttons = barButtons[barKey]
    if not frame or not buttons then return end

    local state = EAB_VTABLE.Hover.GetState(barKey, frame)

    local function CanEnter(self)
        -- Skip hidden empty buttons (alwaysShowButtons off)
        local s = EAB.db.profile.bars[barKey]
        if s then
            local showEmpty = s.alwaysShowButtons
            if showEmpty == nil then showEmpty = true end
            if not showEmpty then
                if self ~= frame then
                    -- Individual button: skip a parked empty slot (our own
                    -- record, never GetAlpha: another addon may fade the button).
                    if ns._eabParked(self) then
                        return false
                    end
                else
                    -- Bar frame itself (gaps between buttons): allow only if the
                    -- cursor is within pad of a shown button that is not parked.
                    local cx, cy = GetCursorPosition()
                    local scale = frame:GetEffectiveScale()
                    cx, cy = cx / scale, cy / scale
                    local pad = (s.buttonPadding or 2) + 2
                    local nearVisible = false
                    for i = 1, #buttons do
                        local btn = buttons[i]
                        if btn and btn:IsShown() and not ns._eabParked(btn) then
                            local bl, bb, bw, bh = btn:GetRect()
                            if bl and cx >= bl - pad and cx <= bl + bw + pad and cy >= bb - pad and cy <= bb + bh + pad then
                                nearVisible = true
                                break
                            end
                        end
                    end
                    if not nearVisible then return false end
                end
            end
        end
        return true
    end

    local OnEnter, OnLeave = EAB_VTABLE.Hover.BuildHandlers(barKey, state, {
        canEnter = CanEnter,
        blockFadeOut = function()
            -- Keep bar visible while a spell flyout spawned from this bar is open.
            return GetEABFlyout():IsVisible() and GetEABFlyout():IsMouseOver()
        end,
    })

    frame:HookScript("OnEnter", OnEnter)
    frame:HookScript("OnLeave", OnLeave)
    for i = 1, #buttons do
        local btn = buttons[i]
        if btn then
            btn:HookScript("OnEnter", OnEnter)
            btn:HookScript("OnLeave", OnLeave)
        end
    end
end

-- onlyHoverGated: visit ONLY the bars whose hover gate can move on a state edge (Match
-- Any plus mouseover). The edge-driven caller passes it so a target change does not drag
-- every other bar through a StopFade/SetAlpha it cannot need.
function EAB:RefreshMouseover(onlyHoverGated)
    for _, info in ipairs(ALL_BARS) do
        local key = info.key
        local s = self.db.profile.bars[key]
        if s and (not onlyHoverGated or (s.mouseoverEnabled and s.visibilityMatch == "any")) then
            local frame = barFrames[key] or (info.isDataBar and dataBarFrames[key]) or (info.isBlizzardMovable and blizzMovableHolders[key]) or (extraBarHolders[key]) or (info.visibilityOnly and _G[info.frameName])
            if frame then
                -- For extra bars (MicroBar, BagBar), fade the Blizzard frame directly
                -- since that's what AttachExtraBarHoverHooks targets.
                if info.visibilityOnly and not info.isDataBar and not info.isBlizzardMovable then
                    local blizzFrame = _G[info.frameName]
                    if blizzFrame then frame = blizzFrame end
                end
                if info.noManagedVisibility then
                    -- Position-only Blizzard-owned eye (QueueStatus): EUI no longer
                    -- controls its visibility, so never fade or alpha-hide it --
                    -- force full opacity regardless of stale mouseover settings.
                    StopFade(frame, 1)
                elseif s.mouseoverEnabled then
                    if info.isDataBar then
                        AttachDataBarHoverHooks(key)
                    end
                    -- Ensure extra bars have hover hooks attached (may not have been
                    -- set up at load time if mouseover was disabled then)
                    if info.visibilityOnly and not info.isDataBar and not info.isBlizzardMovable then
                        ns.AttachExtraBarHoverHooks(info)
                    end
                    local state = hoverStates[key]
                    -- A bar the cursor is sitting on keeps what the hover gave it. This
                    -- used to be safe by accident (the function only ran on settings
                    -- changes); it now also runs on combat/group/mount edges, where
                    -- repainting would yank a hovered bar invisible mid-hover.
                    if not (state and state.isHovered) then
                        local resting = EAB_VTABLE.Hover.RestingAlpha(key, s)
                        StopFade(frame, resting)
                        if state then state.fadeDir = (resting == 0) and "out" or nil end
                        if key == "MainBar" then SyncPagingAlpha(resting) end
                    end
                else
                    StopFade(frame, s.mouseoverAlpha or 1)
                    local state = hoverStates[key]
                    if state then state.fadeDir = nil end
                    if key == "MainBar" then SyncPagingAlpha(s.mouseoverAlpha or 1) end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Visibility Condition Builder: macro condition string for RegisterStateDriver,
--  per bar type and user settings (combat show/hide).
--    MainBar (bar 1): visible during vehicle/override (paging shows the right
--                      actions); hides during pet battle.
--    Bars 2-8:         hide during vehicle UI, pet battle and override bar
--                      (only bar 1 pages to override/vehicle actions).
--    StanceBar:        hide during vehicle UI and pet battle.
--    PetBar:           hide during pet battle; shows only with a pet and no
--                      vehicle/override/possess state.
-------------------------------------------------------------------------------
-- Multi-select visibility compiler: thin delegate to the shared secure driver
-- compiler in EllesmereUI_Visibility.lua (one grammar for Action Bars and
-- Unit Frames). EAB table fields, not locals -- 200-local cap.
function EAB.BuildVisModeConjuncts(vm)
    return EllesmereUI.BuildVisModeConjuncts(vm)
end

function EAB.BuildVisibilityStringMulti(hidePrefix, vm)
    return EllesmereUI.BuildVisibilityDriverString(hidePrefix, vm)
end

-- Edges this addon watches, for the shared Any tail builder: the target/enemy axes may
-- compile to live macro tokens because the soft-target machinery (PLAYER_SOFT_* events
-- + the 0.1s poll) rebuilds the driver when they drift. EAB field: 200-local cap.
EAB.VIS_EDGES = { softTarget = true }

local function BuildVisibilityString(info, s, visOverride)
    -- Hide Bar When Using Gamepad compiles to the constant a Never bar gets, so
    -- every writer that builds a bar's driver here agrees (combat-gated sites,
    -- regen healers, housing/soft-target/pet rebuilds). An explicit override
    -- (toggle keybind, drag, spellbook) still wins, as it does over Never.
    if EAB._padHide and not visOverride and s.gamepadHideBar == true then return "hide" end
    local key = info.key
    local vis = visOverride or s.barVisibility or "always"
    -- An applied Visibility override replaces the whole setting, the shared option
    -- lanes included. The runtime toggle keybind still wins over it, the same way it
    -- wins over the saved mode.
    local visOv = (not visOverride) and EllesmereUI.VisOverrideValue(s) or nil

    if info.isStance and (GetNumShapeshiftForms() or 0) == 0 then
        return "hide" -- classes/specs with no forms have no stance bar to show
    end

    -- Visibility-option hide clauses expressed as macro conditionals; run
    -- inside the secure state driver so they work in combat without taint. Under Any the
    -- Any tail below compiles both halves itself: Show lanes as disjuncts, Hide lanes as
    -- its own leading gates, so this block would only duplicate them.
    local visOptHide = ""
    if s.visibilityMatch ~= "any" and not visOv then
        if s.visHideMounted then visOptHide = visOptHide .. "[mounted] hide; " end
        -- Inverse of the above. [nomounted] cannot see druid travel/flight forms
        -- (they are shapeshifts), so a druid in a mount-like form reads unmounted
        -- here and the bar hides -- accepted asymmetry: the secure clause is what
        -- keeps this working in combat, and Lua cannot un-hide past the driver.
        if s.visOnlyMounted then visOptHide = visOptHide .. "[nomounted] hide; " end
        if s.visHideNoTarget then visOptHide = visOptHide .. "[noexists] hide; " end
        if s.visHideWithTarget then visOptHide = visOptHide .. "[exists] hide; " end
        if s.visHideNoEnemy then visOptHide = visOptHide .. "[noharm] hide; " end
        if s.visHideWithEnemy then visOptHide = visOptHide .. "[harm] hide; " end
    end

    -- Authoritative multi-select set. Explicit overrides (toggle keybind,
    -- QuickKeybind, grid drag) substitute the whole mode term as for single
    -- modes, so they keep the legacy path.
    local vm
    if not visOverride and EllesmereUI.GetActiveVisibilityModes then
        vm = EllesmereUI.GetActiveVisibilityModes(s, "barVisibility")
    end

    -- Any match: the shared builder compiles the whole tail; Lua-only lanes (instances,
    -- housing, skyriding mount) are resolved at build time, so their verdict is only as
    -- fresh as the last driver rebuild. Explicit overrides keep the legacy path.
    if not visOverride and s.visibilityMatch == "any" and EllesmereUI.BuildAnyMatchTail then
        local anyPrefix, anyWrap
        if info.isPetBar then
            anyPrefix = "[petbattle] hide; "
            anyWrap = "novehicleui,pet,nooverridebar,nopossessbar"
        elseif key == "MainBar" then
            anyPrefix = "[petbattle] hide; "
        elseif info.isStance then
            anyPrefix = "[vehicleui][petbattle] hide; "
        else
            anyPrefix = "[vehicleui][petbattle][overridebar] hide; "
        end
        return anyPrefix .. EllesmereUI.BuildAnyMatchTail(s, "barVisibility", vm, anyWrap, EAB.VIS_EDGES)
    end

    -- Pet bar has unique logic: it only shows when a pet is active and
    -- the player is not in a vehicle/override/possess state.
    if info.isPetBar then
        -- Both paths fold the mode's AND terms INTO the pet wrapper bracket. Adjacent
        -- bracket groups are OR in macro grammar, so a mode clause beside the wrapper
        -- ("[...pet...] [combat] show") matches on the pet term alone and ignores the
        -- mode (inverting the two dragonriding modes). A negated axis has no AND token,
        -- becoming a leading hide gate instead (same technique as visOptHide).
        local conj, negGate
        if visOv then
            -- An override replaces the setting, so no mode terms at all: Never hides
            -- outright, the other two leave the pet wrapper as the only condition.
            if visOv == "never" then return "hide" end
            conj, negGate = "", ""
        elseif vm then
            -- Group modes are structurally unsupported here (locked in UI, stripped by sync copies).
            conj, negGate = EAB.BuildVisModeConjuncts(vm)
        else
            conj, negGate = "", ""
            if vis == "in_combat" then
                conj = "combat,"
            elseif vis == "out_of_combat" then
                conj = "nocombat,"
            elseif vis == "show_dragonriding" then
                conj = "advflyable,flying,"
            elseif vis == "show_not_dragonriding" then
                negGate = "[advflyable,flying] hide; "
            elseif s.combatShowEnabled then
                conj = "combat,"
            elseif s.combatHideEnabled then
                negGate = "[combat] hide; "
            end
        end
        local bracket = "[novehicleui,pet,nooverridebar,nopossessbar"
        if conj ~= "" then bracket = bracket .. "," .. conj:sub(1, -2) end
        bracket = bracket .. "]"
        return "[petbattle] hide; " .. visOptHide .. negGate .. bracket .. " show; hide"
    end

    -- Build the hide-prefix based on bar type
    local hidePrefix
    if key == "MainBar" then
        hidePrefix = "[petbattle] hide; "
    elseif info.isStance then
        hidePrefix = "[vehicleui][petbattle] hide; "
    else
        hidePrefix = "[vehicleui][petbattle][overridebar] hide; "
    end

    -- Inject visibility-option hide clauses after the standard hide-prefix
    hidePrefix = hidePrefix .. visOptHide

    -- One constant, with the standard pet battle / vehicle prefix still in front.
    if visOv then
        return hidePrefix .. ((visOv == "never") and "hide" or "show")
    end

    -- Multi-select set: compiled tail; the legacy single-mode chain below
    -- stays byte-identical for every scalar value.
    if vm then
        return EAB.BuildVisibilityStringMulti(hidePrefix, vm)
    end

    -- Append visibility mode conditions
    if vis == "never" then
        return hidePrefix .. "hide"
    elseif vis == "in_combat" then
        return hidePrefix .. "[combat] show; hide"
    elseif vis == "out_of_combat" then
        return hidePrefix .. "[nocombat] show; hide"
    elseif vis == "in_raid" then
        return hidePrefix .. "[group:raid] show; hide"
    elseif vis == "in_party" then
        -- [group:party] alone is TRUE inside a raid; nogroup:raid narrows it
        -- to a real party so unchecking In Raid Group actually hides in raids.
        return hidePrefix .. "[group:party,nogroup:raid] show; hide"
    elseif vis == "solo" then
        return hidePrefix .. "[nogroup] show; hide"
    elseif vis == "show_dragonriding" then
        -- No "mounted": Flight Form is a shapeshift, not a mount. advflyable
        -- covers skyriding mounts + Flight Form, excludes ordinary flying.
        return hidePrefix .. "[advflyable,flying] show; hide"
    elseif vis == "show_not_dragonriding" then
        -- Exact inverse: hide while dragonriding, show otherwise; hidePrefix
        -- still force-hides in pet battle/vehicle.
        return hidePrefix .. "[advflyable,flying] hide; show"
    end
    return hidePrefix .. "show"
end

-------------------------------------------------------------------------------
--  Managed Non-Secure Visibility: XP/Rep bars and extra bars such as
--  Micro/Bag/QueueStatus are not secure bar headers, so they need an
--  explicit runtime visibility pass whenever the player's
--  combat/group/target/mount state changes.
-------------------------------------------------------------------------------
function EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info)
    if not info then return false end
    if info.noManagedVisibility then return false end
    return info.isDataBar or (info.visibilityOnly and not info.isBlizzardMovable)
end

function EAB_VTABLE.ExtraBars.GetManagedNonSecureFrame(info)
    if not EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then return nil end
    if info.isDataBar then
        return dataBarFrames[info.key]
    end
    return info.frameName and _G[info.frameName] or nil
end

function EAB_VTABLE.ExtraBars.GetManagedNonSecureVisibilityState()
    local inCombat = EAB_VTABLE.ExtraBars._managedNonSecureInCombat
    if inCombat == nil then
        inCombat = InCombatLockdown()
    end
    local inRaid = IsInRaid and IsInRaid() or false
    local inGroup = IsInGroup and IsInGroup() or false
    return {
        inCombat = inCombat,
        inRaid = inRaid,
        inParty = inGroup and not inRaid,
    }
end

function EAB_VTABLE.ExtraBars.ShouldShowManagedNonSecureBar(s)
    if not s then return false end
    local vis = EAB.VisibilityCompat.Normalize(s)
    if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then
        return false
    end
    if s.enabled == false or s.alwaysHidden then return false end
    if EllesmereUI.CheckVisibilityOptions(s) then
        return false
    end
    local state = EAB_VTABLE.ExtraBars.GetManagedNonSecureVisibilityState()
    -- Multi-select path (nil = legacy single mode below; the dragonriding
    -- scalar also routes here, same predicate CheckVisibilityMode uses)
    if EllesmereUI and EllesmereUI.EvalVisibilityExtended then
        local ext = EllesmereUI.EvalVisibilityExtended(s, "barVisibility", state, EllesmereUI.VIS_CAPS_DEFAULT)
        if ext ~= nil then return ext end
    end
    if EllesmereUI and EllesmereUI.CheckVisibilityMode then
        return EllesmereUI.CheckVisibilityMode(vis, state)
    end
    return vis ~= "never"
end

-- Deferred completion for a petbattle unsuppress that lands during combat.
-- Wild pet battles hold combat lockdown for their whole duration and the
-- [petbattle] driver flips back to "show" at battle close, BEFORE
-- PLAYER_REGEN_ENABLED. The unsuppress below then defers on InCombatLockdown(), but the
-- driver never fires again (already "show") and every other caller uses reason
-- "visibility", a different key pair -- without this the micro menu/bag bar stays
-- hidden after every wild pet battle until a /reload.
--
-- One combat-queue entry; pending frames retry once combat drops. If a new
-- battle began before regen the pending set is dropped: suppression flags
-- are still set (re-suppressing keeps the ORIGINAL pre-battle shown state,
-- see `if not ffd[suppressKey]` below), so that battle's own close
-- transition completes or re-defers as usual.
-- do-block with block locals; helper exported on the vtable (200-local cap).
do
    local pending
    local function DrainPending()
        local p = pending
        pending = nil
        if not p then return end
        if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then
            return -- back in a battle; its close transition owns the rest
        end
        for f in pairs(p) do
            EAB_VTABLE.ExtraBars.SetManagedBlizzOwnedSuppressed(f, "petbattle", false)
        end
    end
    EAB_VTABLE.ExtraBars.QueuePetBattleUnsuppress = function(frame)
        pending = pending or {}
        pending[frame] = true
        ns.CombatQueue.Defer("PetBattleUnsuppress", DrainPending)
    end
end

function EAB_VTABLE.ExtraBars.SetManagedBlizzOwnedSuppressed(frame, reason, suppressed)
    if not frame then return end

    local ffd = EFD(frame)
    local suppressKey = (reason == "petbattle") and "suppressedByPetBattle" or "suppressedByVisibility"
    local shownKey = (reason == "petbattle") and "wasShownBeforePetBattle" or "wasShownBeforeVisibility"

    -- EditMode-managed frames (MicroMenuContainer, BagsBar): Hide()/Show()
    -- route through protected HideBase/ShowBase, blocked in combat. Issue the
    -- protected call only on a real state transition (a redundant re-Hide on
    -- an already-hidden frame still trips ADDON_ACTION_BLOCKED each refresh,
    -- and SPELLS_CHANGED fires often mid-rotation), never in combat --
    -- RefreshRuntimeVisibility re-runs from ApplyAll on PLAYER_REGEN_ENABLED
    -- and completes the deferred transition once lockdown clears.
    --
    -- InCombatLockdown() is the RIGHT gate here, not the protected-instance
    -- check: the restriction is "protected frame op blocked in combat", and
    -- the protected-instance check reports true for a whole keystone run (it
    -- exists for secret-value reads and Blizzard panel toggles), which would
    -- strand the micro menu/bag bar unsuppressed for the entire key.
    if suppressed then
        if not ffd[suppressKey] then
            ffd[shownKey] = frame:IsShown()
        end
        ffd[suppressKey] = true
        if frame:IsShown() then
            if not InCombatLockdown() then
                frame:Hide()
                ns.AB_ExtraCapsFor(frame)
            else
                ns._eabApplyDeferred = true
            end
        end
        return
    end

    if ffd[suppressKey] then
        if InCombatLockdown() then
            -- Keep bookkeeping and mark the combat-drop ApplyAll owed. That
            -- heals "visibility" (RefreshRuntimeVisibility re-issues it) but
            -- never "petbattle": ApplyAll only calls back with "visibility"
            -- and the driver already sits at "show", so that reason needs its
            -- own completion on the same event.
            ns._eabApplyDeferred = true
            if reason == "petbattle" then
                EAB_VTABLE.ExtraBars.QueuePetBattleUnsuppress(frame)
            end
            return
        end
        local wasShown = ffd[shownKey]
        ffd[suppressKey] = nil
        ffd[shownKey] = nil
        if wasShown and not frame:IsShown() then
            frame:Show()
            ns.AB_ExtraCapsFor(frame)
        end
    end
end

function EAB_VTABLE.ExtraBars.ApplyManagedNonSecureAlpha(info, frame, s)
    if not frame or not s or not frame:IsShown() then return end

    local hstate = hoverStates[info.key]
    local resting, hoverGated = EAB_VTABLE.Hover.RestingAlpha(info.key, s)
    if hoverGated then
        if hstate and hstate.isHovered then
            frame:SetAlpha(1)
            _fadeAlpha[frame] = 1
            hstate.fadeDir = "in"
        else
            frame:SetAlpha(resting)
            _fadeAlpha[frame] = resting
            if hstate then hstate.fadeDir = "out" end
        end
    else
        frame:SetAlpha(resting)
        _fadeAlpha[frame] = resting
        if hstate then hstate.fadeDir = nil end
    end
    ns.AB_FadeTwin(frame, _fadeAlpha[frame])
end

function EAB_VTABLE.ExtraBars.ApplyManagedMouse(frame, blizzOwnedVisibility, s, shouldShow)
    if not frame or not s then return end

    shouldShow = (shouldShow ~= false)
    -- Blizzard-owned frames (QueueStatusButton) manage their own mouse state;
    -- overriding it disables clicking/hovering after every visibility refresh.
    if blizzOwnedVisibility then
        return
    elseif s.mouseoverEnabled and s.clickThrough then
        SafeEnableMouseMotionOnly(frame, shouldShow)
    else
        SafeEnableMouse(frame, shouldShow and not s.clickThrough)
    end
end

function EAB_VTABLE.ExtraBars.ApplyManagedNonSecurePresentation(info, frame, s, shouldShow, allowShow)
    if not frame or not s then return end

    -- Show/hide the holder BEFORE the Blizzard frame so the parent has
    -- valid screen coordinates when the child's Show() triggers Blizzard
    -- Layout callbacks that call GetCenter().
    if not info.isDataBar then
        local holder = extraBarHolders[info.key]
        if holder then
            if shouldShow then holder:Show() else holder:Hide() end
        end
    end

    if info.blizzOwnedVisibility then
        EAB_VTABLE.ExtraBars.SetManagedBlizzOwnedSuppressed(frame, "visibility", not shouldShow)
    elseif shouldShow then
        if allowShow ~= false then
            frame:Show()
        end
    else
        frame:Hide()
    end

    if shouldShow then
        EAB_VTABLE.ExtraBars.ApplyManagedNonSecureAlpha(info, frame, s)
    end
    EAB_VTABLE.ExtraBars.ApplyManagedMouse(frame, info.blizzOwnedVisibility, s, shouldShow)
end

function EAB_VTABLE.ExtraBars.ApplyManagedNonSecureVisibility(info)
    if not EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then return false, nil, nil end

    local s = EAB.db and EAB.db.profile and EAB.db.profile.bars and EAB.db.profile.bars[info.key]
    local frame = EAB_VTABLE.ExtraBars.GetManagedNonSecureFrame(info)
    if not s or not frame then return false, frame, s end

    local shouldShow = EAB_VTABLE.ExtraBars.ShouldShowManagedNonSecureBar(s)

    -- Data bars always route through their update func: the hidden path ends
    -- in the same presentation call via BeginManagedDataBarUpdate, and bars
    -- with event arming (House Favor) need the call to disarm when hidden.
    if info.isDataBar and frame._updateFunc then
        frame._updateFunc()
    else
        EAB_VTABLE.ExtraBars.ApplyManagedNonSecurePresentation(info, frame, s, shouldShow, not info.isDataBar)
    end

    return shouldShow, frame, s
end

function EAB_VTABLE.ExtraBars.RefreshManagedNonSecureVisibility()
    for _, info in ipairs(EXTRA_BARS) do
        if EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then
            EAB_VTABLE.ExtraBars.ApplyManagedNonSecureVisibility(info)
        end
    end
end

-------------------------------------------------------------------------------
--  Extra Bar Visibility (Pet Battle / Vehicle Hiding): MicroBar, BagBar, data
--  bars and Blizzard movable frames are not SecureHandlerStateTemplate
--  frames, so one secure proxy frame monitors [petbattle]/[vehicleui] and
--  calls methods to show/hide them.
-------------------------------------------------------------------------------
local _extraBarVisProxy  -- created once, reused

function EAB:ApplyExtraBarVisibility()
    if not _extraBarVisProxy then
        _extraBarVisProxy = CreateFrame("Frame", nil, UIParent, "SecureHandlerStateTemplate")
        _extraBarVisProxy:SetAttribute("_onstate-extravis", [[
            self:CallMethod("OnExtraVisChanged", newstate)
        ]])
        _extraBarVisProxy.OnExtraVisChanged = function(_, state)
            -- state is "hide" during pet battle, "show" otherwise
            local shouldHide = (state == "hide")
            for _, info in ipairs(EXTRA_BARS) do
                if info.noManagedVisibility then
                    -- skip
                else
                local key = info.key
                local s = EAB.db and EAB.db.profile.bars[key]
                if s and not s.alwaysHidden then
                    local frame
                    if EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then
                        frame = EAB_VTABLE.ExtraBars.GetManagedNonSecureFrame(info)
                    elseif info.isBlizzardMovable then
                        frame = blizzMovableHolders[key]
                    else
                        frame = _G[info.frameName]
                    end
                    if frame then
                        if shouldHide then
                            if info.blizzOwnedVisibility then
                                EAB_VTABLE.ExtraBars.SetManagedBlizzOwnedSuppressed(frame, "petbattle", true)
                            else
                                frame:Hide()
                            end
                        else
                            if info.blizzOwnedVisibility then
                                EAB_VTABLE.ExtraBars.SetManagedBlizzOwnedSuppressed(frame, "petbattle", false)
                            end
                            if EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then
                                EAB_VTABLE.ExtraBars.ApplyManagedNonSecureVisibility(info)
                            else
                                frame:Show()
                            end
                        end
                    end
                end
            end -- if s
            end -- if not noManagedVisibility
        end
    end
    -- Register the state driver: hide during pet battle, show otherwise
    RegisterStateDriver(_extraBarVisProxy, "extravis", "[petbattle] hide; show")
end

--  Combat Show/Hide, Runtime Visibility, Click-Through, Housing
-------------------------------------------------------------------------------
function EAB:ApplyCombatVisibility()
    if InCombatLockdown() then ns._eabApplyDeferred = true return end
    for _, info in ipairs(ALL_BARS) do
        local key = info.key
        local s = self.db.profile.bars[key]
        if s then
            local frame = barFrames[key] or (info.isDataBar and dataBarFrames[key]) or (info.isBlizzardMovable and blizzMovableHolders[key]) or (extraBarHolders[key]) or (info.visibilityOnly and _G[info.frameName])
            if frame and not info.visibilityOnly then
                local newStr
                if s.alwaysHidden then
                    newStr = "hide"
                -- Under Any the compiled driver already carries both halves (Show lanes as
                -- disjuncts, Hide lanes as leading gates, the Lua-only ones resolved at
                -- build time with their own combat escape hatch), so a literal "hide" here
                -- would replace a self-updating string with a dead constant. Same guard
                -- ShouldHideNonMacro carries; with all of them skipping it, the "any"
                -- branch inside CheckVisibilityOptionsNonMacro has no live caller left and
                -- is kept only so the helper stays correct for a future non-driver one.
                elseif s.visibilityMatch ~= "any" and EllesmereUI.CheckVisibilityOptionsNonMacro(s) then
                    newStr = "hide"
                else
                    newStr = BuildVisibilityString(info, s)
                end
                -- Skip re-registration if driver string is unchanged (avoids blink from re-evaluation)
                if frame._eabLastVisStr ~= newStr then

                    frame._eabLastVisStr = newStr
                    RegisterAttributeDriver(frame, "state-visibility", newStr)
                end
            end
        end
    end
    -- Pet battle / vehicle hiding for extra bars (MicroBar, BagBar, data bars)
    -- via a dedicated secure proxy: they are not SecureHandlerStateTemplate.
    self:ApplyExtraBarVisibility()
end

-- Gates for the soft-target poll, so it costs nothing for users who do not use
-- the feature. Recomputed on every visibility refresh below and once at setup,
-- so it can never desync from the bar settings.
function EAB:_RefreshSoftTargetGate()
    -- Two gates from one walk (re-run on every config apply):
    --   _anyHideNoTarget -- any bar with "Hide when No Target" (soft-target
    --   override machinery: the 0.1s poll + ImmediateSoftTargetCheck).
    --   _anyNonMacroVis  -- any bar using ANY non-macro visibility option, or
    --   a managed non-secure bar; when false, UpdateHousingVisibility has
    --   nothing it could ever change and skips entirely.
    --   _anyHoverGated   -- any bar whose hover gate can OPEN and CLOSE on a state edge
    --   (Match Any plus mouseover). Only those need the resting alpha re-derived when
    --   combat/group/mount state moves; under All a mouseover bar is hover-gated for as
    --   long as the setting stands, so its alpha never changes off an edge.
    local anySoft, anyNonMacro, anyHoverGated = false, false, false
    for _, info in ipairs(ALL_BARS) do
        local s = self.db.profile.bars[info.key]
        if s then
            if s.mouseoverEnabled and s.visibilityMatch == "any" then
                anyHoverGated = true
            end
            -- Under Any the counter lane carries the soft-target correction too, so it
            -- arms the same machinery; under All it never did and still does not.
            if s.visHideNoTarget or (s.visHideWithTarget and s.visibilityMatch == "any") then
                anySoft = true
            end
            -- Driven off the shared key list rather than a hand-written subset: an
            -- option missing here silently skips the whole UpdateHousingVisibility pass
            -- for that bar. Deliberately over-inclusive (it also matches the
            -- macro-expressible lanes) -- a needless walk on a rare zone/mount edge is
            -- cheap, a missed one leaves the bar stale until the next settings change.
            if not anyNonMacro and EllesmereUI.VisHasAnyOption(s) then
                anyNonMacro = true
            end
        end
        if not anyNonMacro and EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then
            anyNonMacro = true
        end
    end
    self._anyHideNoTarget = anySoft
    self._anyNonMacroVis = anyNonMacro
    self._anyHoverGated = anyHoverGated
end

-- Re-derive the resting alpha of every hover-gated bar. Registered once with the shared
-- visibility dispatcher (below), which already watches the exact edge set this depends on
-- (combat, group, target, mount, zone, shapeshift, gliding) and fans out one frame later.
-- Alpha only: no Show/Hide, no driver registration, so this is safe inside combat lockdown
-- and carries no taint exposure. Fully gated -- users with no Any-plus-mouseover bar pay
-- one flag read per dispatcher event.
function EAB:RefreshHoverGatedAlpha()
    if not self._anyHoverGated then return end
    self:RefreshMouseover(true)
end

-- Build the buttons of bars skipped at load (see SetupBar) that need them now:
-- the bar left the Never set (reveal), or a key landed on one of its commands
-- (hidden bars keep live bindings, and a click-routed key needs a button to
-- route to). Deliberately state-based rather than edge-based: an options write
-- taken in combat flips the Never map but cannot create secure frames, and the
-- PLAYER_REGEN_ENABLED healer re-enters the callers with the map ALREADY
-- flipped, so a transition test would never fire again and the bar would stay
-- buttonless until the next reload. Returns true when anything was built. The
-- CALLER owns the binding rebuild: one caller is UpdateKeybinds itself. On ns:
-- file at the 200-local cap.
ns._eabBuildSkippedBars = function()
    if not next(ns._eabBarNoButtons) or InCombatLockdown() then return false end
    local built = false
    for _, info in ipairs(BAR_CONFIG) do
        local key = info.key
        local frame = barFrames[key]
        if frame and ns._eabBarNoButtons[key]
           and (not ns._eabBarNever[key] or ns.BarHasBoundKeys(info)) then
            ns.BuildBarButtons(info, frame, false)
            LayoutBar(key)
            -- Still hidden (keybind case, or a reveal whose driver has not
            -- shown the frame yet): the hide edge already passed with no
            -- buttons, so park the new mixin event lists the way it would
            -- have. The show edge lifts this as usual.
            if not frame:IsShown() then
                ns._eabBarDormant[key] = nil
                ns.ApplyBarDormancy(key, true)
            end
            built = true
        end
    end
    if built then
        -- The refs pass already ran without these buttons in it.
        _secureRefsReady = false
        SecureSetupHandler_PrepareRefs()
        -- Everything cosmetic (borders, shapes, fonts, backgrounds, button
        -- art, cooldown visuals, range colouring) converges through the
        -- full apply. Next frame, not inline: ApplyAll calls back into
        -- RefreshRuntimeVisibility, and the marker is already cleared by then
        -- so it finds nothing to build. On ns, not on EAB, so the
        -- EUI_UnlockMode hook on EAB.ApplyAll stays as it was.
        C_Timer.After(0, function()
            if ns._eabApplyAll then ns._eabApplyAll() end
        end)
    end
    return built
end

-------------------------------------------------------------------------------
--  Hide Bar When Using Gamepad (per bar, s.gamepadHideBar, default off; set
--  on the Global Settings Gamepad page).
--  "Using" means CONNECTED (EllesmereUI.PadConnected: gamepad support is on
--  and a controller is present), never the last-input device, so a touch of
--  the mouse cannot flicker a bar back. A hidden bar is hidden the way Never
--  hides it: its driver compiles to "hide" (BuildVisibilityString) and it
--  joins the Never set (ns.IsNeverBar). Two cached verdicts: EAB._padOn is the
--  device verdict, EAB._padHide the one every bar reader uses (_padOn, except
--  while Quick Keybind mode is open, which brings these bars back for binding).
--  Both only turn ON out of combat: the secure drivers cannot follow in
--  combat, and a still-visible bar in the Never set would skip its content
--  walks for the rest of the fight. EAB fields, not locals: 200-local cap.
-------------------------------------------------------------------------------
-- Device edges arrive through EllesmereUI.WatchPad, one call per burst; a
-- repaint only when the verdict flips.
function EAB._PadFlush(on)
    if on == EAB._padOn then return end
    if InCombatLockdown() then
        -- Keep the old verdict; the PLAYER_REGEN_ENABLED ApplyAll re-reads it.
        EAB._padStale = true
        ns._eabApplyDeferred = true
        return
    end
    EAB._padOn = on
    EAB:RefreshRuntimeVisibility()
end

-- Watches the device edges while any bar has the toggle on (unwatched they
-- cost nothing) and re-reads the devices on the watch edge and after an edge
-- that landed in combat. Runs ahead of the Never map and the drivers, so every
-- settings path (options, profile swap, spec override) re-arms here, and once
-- from FinishSetup before its pre-lockdown driver pass. Quick Keybind mode's
-- open and close edges re-run it through RefreshRuntimeVisibility.
function EAB._PadSync()
    local bars = EAB.db.profile.bars
    local any = false
    for i = 1, #BAR_CONFIG do
        local s = bars[BAR_CONFIG[i].key]
        if s and s.gamepadHideBar == true then any = true break end
    end
    if any ~= (EAB._padArmed == true) then
        EAB._padArmed = any
        if any then
            EllesmereUI.WatchPad(EAB, EAB._PadFlush)
        else
            EllesmereUI.UnwatchPad(EAB)
        end
        EAB._padStale = any or nil
    end
    if not any then
        EAB._padOn = false
    elseif EAB._padStale and not InCombatLockdown() then
        EAB._padStale = nil
        EAB._padOn = EllesmereUI.PadConnected()
    end
    -- A Quick Keybind close taken in combat keeps the bars up until its regen
    -- FinishClose re-runs this.
    local hide = (EAB._padOn and not _quickKeybindState.open) or false
    if hide and not EAB._padHide and InCombatLockdown() then return end
    EAB._padHide = hide
end

function EAB:RefreshRuntimeVisibility()
    -- Secure driver/mouse writes below are per-site combat-gated; a run
    -- during combat leaves those writes unapplied, and the REGEN_ENABLED
    -- ApplyAll (gated on this flag) is the healer.
    if InCombatLockdown() then ns._eabApplyDeferred = true end
    -- Controller verdict first: the Never map and every driver below read it.
    EAB._PadSync()
    -- Every settings path that can change a bar's Never/disabled status runs
    -- through here (this is where drivers re-derive), so this is the single
    -- recompute site for the hard-dormancy map the event walks gate on.
    ns.RecomputeNeverBars()
    -- Bars that left the Never set with their buttons skipped at load get them
    -- now (state-based; see ns._eabBuildSkippedBars). ~200 override bindings
    -- are built from BAR_CONFIG x barButtons, so a revealed bar has none until
    -- UpdateKeybinds runs; it defers itself in combat.
    if ns._eabBuildSkippedBars() and _G._EAB_UpdateKeybinds then
        _G._EAB_UpdateKeybinds()
    end
    self:_RefreshSoftTargetGate()
    for _, info in ipairs(ALL_BARS) do
        local key = info.key
        local s = self.db.profile.bars[key]
        if not s then -- skip bars without settings (not yet initialized)
        elseif EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then
            EAB_VTABLE.ExtraBars.ApplyManagedNonSecureVisibility(info)
        else
        local frame = barFrames[key] or (info.isDataBar and dataBarFrames[key]) or (info.isBlizzardMovable and blizzMovableHolders[key]) or (extraBarHolders[key]) or (info.visibilityOnly and _G[info.frameName])
        if frame then
            local vis = s.barVisibility or "always"
            local isHidden = (vis == "never") or s.alwaysHidden
            -- Runtime "Toggle Action Bar" override (keybind-driven, NOT persisted):
            -- flips a bar between always-shown and hidden without touching the saved
            -- barVisibility. Only ever set for bars whose saved mode is always/never.
            local _visToggleOv = EAB._visOverride and EAB._visOverride[key]
            if _visToggleOv then
                vis = _visToggleOv
                isHidden = (_visToggleOv == "never")
            end
            if ShouldQuickKeybindSurfaceBar(s) and barFrames[key] and frame == barFrames[key] then
                if not InCombatLockdown() then
                    RegisterAttributeDriver(frame, "state-visibility", "show")
                    -- Keep the cache in sync (see EAB_UpdateQuickKeybindVisibility):
                    -- a stale cache makes QKB exit skip restoring the real driver.
                    frame._eabLastVisStr = "show"
                    frame:Show()
                    SafeEnableMouseMotionOnly(frame, true)
                end
                -- QuickKeybind temporarily surfaces managed action bars when
                -- runtime conditions hide them, but not when the user chose
                -- an explicit "Never" visibility mode.
            elseif isHidden then
                if not info.visibilityOnly and not InCombatLockdown() then
                    if frame._eabLastVisStr ~= "hide" then

                        frame._eabLastVisStr = "hide"
                        RegisterAttributeDriver(frame, "state-visibility", "hide")
                    end
                elseif info.visibilityOnly then
                    frame:Hide()
                    if info.blizzOwnedVisibility then
                        local bf = _G[info.frameName]
                        if bf then bf:Hide() end
                    end
                end
                if not InCombatLockdown() then
                    SafeEnableMouse(frame, false)
                end
            else
                if not info.visibilityOnly and not InCombatLockdown() then
                    local newStr
                    if _visToggleOv == "always" then
                        -- Forced-show via the toggle keybind: ignore the saved mode
                        -- (which may be "never") and any non-macro hide options.
                        newStr = BuildVisibilityString(info, s, "always")
                    -- Any is driver-owned, same reason as in ApplyCombatVisibility.
                    elseif s.visibilityMatch ~= "any" and EllesmereUI.CheckVisibilityOptionsNonMacro(s) then
                        newStr = "hide"
                    else
                        newStr = BuildVisibilityString(info, s)
                    end
                    if frame._eabLastVisStr ~= newStr then

                        frame._eabLastVisStr = newStr
                        RegisterAttributeDriver(frame, "state-visibility", newStr)
                    end
                end
                if not InCombatLockdown() then
                    if vis ~= "in_combat" and vis ~= "out_of_combat" and not s.combatShowEnabled then
                        -- Only Show frames without a state-visibility driver.
                        -- Frames with a driver (any _eabLastVisStr) are managed by the driver.
                        -- Movable wrappers are ours: restore them when their hide
                        -- condition clears. Blizzard still owns child visibility.
                        if not info.blizzOwnedVisibility and not frame._eabLastVisStr
                           and (not info.isBlizzardMovable
                                or EAB_VTABLE.ExtraBars.ShouldShowManagedNonSecureBar(s)) then
                            frame:Show()
                        end
                    end
                    if barFrames[key] and frame == barFrames[key] then
                        SafeEnableMouseMotionOnly(frame, not s.clickThrough or s.mouseoverEnabled)
                    elseif info.noManagedVisibility then
                        -- skip: Blizzard owns mouse state (e.g. QueueStatusButton)
                    elseif info.isBlizzardMovable or info.blizzOwnedVisibility then
                        SafeEnableMouse(frame, false)
                    else
                        SafeEnableMouse(frame, not s.clickThrough)
                    end
                end
                if info.isDataBar and frame._updateFunc then
                    frame._updateFunc()
                end
            end
        end
        end
    end
end

-------------------------------------------------------------------------------
--  Slot-export addon compatibility: that addon exports settings by automating
--  a PickupAction + PlaceAction on every populated action slot (60+ in a
--  row). With bars that hide empty slots or use conditional visibility, each
--  pickup/place forces a costly secure show/hide pass; back-to-back that
--  stalls the client for many seconds.
--
--  The cure is the "Visibility: Always + Always Show Buttons" config, so
--  while its window is open we apply exactly that to every bar (the same
--  change the options toggles make). Each bar's real visibility settings are
--  backed up to saved variables BEFORE overwriting and restored on close. The
--  backup is persisted, so a /reload or logout with the window open can never
--  strand the user on "always": EAB:OnInitialize calls RestoreMyslotBackup
--  unconditionally on the next login, before any bar is built.
-------------------------------------------------------------------------------
-- Settings swapped to force a bar fully visible. Listed once so backup and
-- overwrite stay in sync. do/end keeps this a block upvalue, not a chunk
-- local (Lua 5.1 200-local-per-chunk cap).
do
local MYSLOT_VIS_FIELDS = {
    "barVisibility", "alwaysHidden", "mouseoverEnabled", "mouseoverAlpha",
    "_savedBarAlpha", "combatShowEnabled", "combatHideEnabled", "alwaysShowButtons",
    -- An applied Visibility override REPLACES the whole setting (a "never"
    -- would keep the bar hidden through the import); captured, force-cleared
    -- and restored like every other field here.
    "visibilityOverride",
    -- Multi-select set: backed up by reference (the shared setter assigns a
    -- fresh table on every write, so the captured table never mutates) and
    -- restored/cleared like any other field.
    "visibilityModes",
    -- The Match Mode scalar is its own store key outside visibilityModes; a
    -- surviving "any" makes the compiler build from the emptied set.
    "visibilityMatch",
    -- Hide Bar When Using Gamepad would keep the bar hidden like Never.
    "gamepadHideBar",
}
-- The option LANES (target/enemy/mounted macro lanes AND the Lua-only
-- instance/housing/skyriding/resting/VEHICLE lanes) are enumerated by the
-- live EllesmereUI.VIS_OPT_KEYS list and swapped dynamically below: ANY lane
-- left standing hides the bar past the forced "always" -- the Lua-only ones
-- through CheckVisibilityOptionsNonMacro's bare "hide" driver, which runs
-- before the mode string is even consulted. Iterating the live list means a
-- future lane can never reopen this hole.
local function MyslotEachVisField(fn)
    for _, f in ipairs(MYSLOT_VIS_FIELDS) do fn(f) end
    local optKeys = EllesmereUI and EllesmereUI.VIS_OPT_KEYS
    if optKeys then
        for _, f in ipairs(optKeys) do fn(f) end
    end
end

-- Restore real visibility settings from the persisted backup, then clear it.
-- Safe to call anytime (no-op if no backup). NOT gated on that addon being
-- enabled, so it self-heals even if it was disabled since the backup was written.
function EAB:RestoreMyslotBackup()
    local backup = self.db and self.db.profile and self.db.profile._myslotVisBackup
    if not backup then return false end
    for key, saved in pairs(backup) do
        local s = self.db.profile.bars[key]
        if s then
            MyslotEachVisField(function(f) s[f] = saved[f] end)
        end
    end
    self.db.profile._myslotVisBackup = nil
    return true
end

function EAB:SetMyslotForceShow(on)
    on = not not on
    -- The persisted backup's presence IS the "are we forcing" state, so this
    -- survives /reload without a separate flag.
    local forcing = self.db.profile._myslotVisBackup ~= nil
    if on == forcing then return end

    if on then
        -- Capture real values and PERSIST the backup BEFORE overwriting, so the
        -- backup always exists if any field was changed (crash/reload-safe).
        local backup = {}
        for _, info in ipairs(BAR_CONFIG) do
            local s = self.db.profile.bars[info.key]
            if s then
                local saved = {}
                MyslotEachVisField(function(f) saved[f] = s[f] end)
                backup[info.key] = saved
            end
        end
        self.db.profile._myslotVisBackup = backup
        -- Overwrite to "always" + "always show buttons" (mirrors the options'
        -- ApplyVisibilityKey("always"), incl. restoring a mouseover bar's real
        -- alpha so it doesn't stay faded).
        for _, info in ipairs(BAR_CONFIG) do
            local s = self.db.profile.bars[info.key]
            if s then
                s.barVisibility = "always"
                -- A lingering multi-select set would stay authoritative over
                -- the forced "always"; the backup above already captured it.
                s.visibilityModes = nil
                s.visibilityMatch = nil
                -- EVERY option lane off, macro and Lua-only alike (the live
                -- VIS_OPT_KEYS list): visOnlyVehicle and friends otherwise
                -- keep feeding CheckVisibilityOptionsNonMacro a hide verdict
                -- that overrides the forced "always" at the driver site.
                local optKeys = EllesmereUI and EllesmereUI.VIS_OPT_KEYS
                if optKeys then
                    for _, f in ipairs(optKeys) do s[f] = nil end
                end
                s.alwaysHidden = false
                s.gamepadHideBar = false
                s.mouseoverEnabled = false
                -- Force FULL opacity, never the bar's real resting value: a
                -- hidden-until-hover bar rests at mouseoverAlpha 0 (and the
                -- Any-engine parks it at 0 with the real value stashed), and
                -- RefreshMouseover's disable path paints mouseoverAlpha
                -- verbatim -- restoring the stash here re-hid the very bar
                -- this swap exists to show. The backup holds both real
                -- values; restore puts them back untouched.
                s.mouseoverAlpha = 1
                s._savedBarAlpha = nil
                s.combatShowEnabled = false
                s.combatHideEnabled = false
                s.alwaysShowButtons = true
            end
        end
    else
        self:RestoreMyslotBackup()
    end

    -- Re-apply -- the same calls the options "Visibility"/"Always Show Buttons"
    -- toggles make, now that the real settings reflect the desired state.
    if not InCombatLockdown() then
        self:RefreshRuntimeVisibility()
        self:RefreshMouseover()
        self:ApplyCombatVisibility()
        for _, info in ipairs(BAR_CONFIG) do
            self:ApplyAlwaysShowButtons(info.key)
        end
    end
    EllesmereUI:RefreshPage()
end
end -- do: MYSLOT_VIS_FIELDS scope

do
    -- Wire the integration only when that addon is enabled: otherwise the
    -- watcher is never created and SetMyslotForceShow never runs, so no
    -- settings are swapped. The OnInitialize restore runs regardless, so a
    -- leftover backup from when it was enabled always self-heals.
    local function MyslotEnabled()
        if C_AddOns and C_AddOns.GetAddOnEnableState then
            return C_AddOns.GetAddOnEnableState("Myslot") > 0
        end
        return true
    end
    if MyslotEnabled() then
        -- Its main window comes from its LibStub library's MainFrame; hook
        -- show/hide to toggle the force-show override. No-op if absent.
        local hooked = false
        local function TryHookMyslot()
            if hooked or not LibStub then return hooked end
            local lib = LibStub:GetLibrary("Myslot-5.0", true)
            local frame = lib and lib.MainFrame
            if not frame then return false end
            hooked = true
            frame:HookScript("OnShow", function() EAB:SetMyslotForceShow(true) end)
            frame:HookScript("OnHide", function() EAB:SetMyslotForceShow(false) end)
            if frame:IsShown() then EAB:SetMyslotForceShow(true) end
            return true
        end
        local watcher = ns.TakeShell()
        watcher:RegisterEvent("PLAYER_LOGIN")
        watcher:RegisterEvent("ADDON_LOADED")
        watcher:SetScript("OnEvent", function()
            if TryHookMyslot() then watcher:UnregisterAllEvents() end
        end)
    end
end

-------------------------------------------------------------------------------
--  "Toggle Action Bar" visibility keybind: per-bar keybind that flips bar UI
--  between active/shown and dormant/hidden at RUNTIME. Action bindings stay
--  live; barVisibility is never written, so the toggle does not persist
--  (/reload restores saved state).
--  Meaningful only when saved visibility is "always" or "never", and only
--  out of combat (changing a secure frame's state-visibility driver is
--  combat-blocked). The keybind itself IS saved per-bar (s.toggleVisKey) and
--  re-applied on login.
--
--  Bindings are keyed by the PRESSED KEY, not the bar, so one key on several
--  bars toggles them as a synced group: a press hides every bound bar that
--  is shown, the next press shows them all.
-------------------------------------------------------------------------------

-- Toggle every bar bound to `key` as a group. If any participant is currently
-- shown, hide them all; otherwise show them all. Only bars whose saved mode is
-- "always"/"never" participate. Runtime-only -- never writes barVisibility.
function EAB:ToggleVisKey(key)
    if InCombatLockdown() or not key then return end
    local participants, anyShown = {}, false
    for _, info in ipairs(ALL_BARS) do
        local s = self.db.profile.bars[info.key]
        if s and s.toggleVisKey == key then
            local saved = s.barVisibility or "always"
            if saved == "always" or saved == "never" then
                participants[#participants + 1] = info.key
                -- A controller-hidden bar counts as hidden (as Never does), so
                -- the first press shows it.
                local eff = (self._visOverride and self._visOverride[info.key])
                    or ((self._padHide and s.gamepadHideBar == true) and "never") or saved
                if eff == "always" then anyShown = true end
            end
        end
    end
    if #participants == 0 then return end
    local target = anyShown and "never" or "always"
    self._visOverride = self._visOverride or {}
    for _, bk in ipairs(participants) do
        self._visOverride[bk] = target
    end
    self:RefreshRuntimeVisibility()
end

-- Drop a bar's runtime toggle override so its saved visibility takes effect
-- again (called when the visibility dropdown changes in options).
function EAB:ClearVisToggleOverride(barKey)
    if self._visOverride then self._visOverride[barKey] = nil end
end

-- Rebuild override bindings from the saved per-bar keys: one pooled button
-- per UNIQUE key (a key shared by several bars drives all of them). A key is
-- only bound if at least one bar using it has a saved always/never mode, so
-- a shared key never dead-overrides the player's normal binding. Binding
-- APIs are combat-protected, so defer to PLAYER_REGEN_ENABLED in combat.
function EAB:RebuildVisToggleBindings()
    if InCombatLockdown() then
        ns.CombatQueue.Defer("RebuildVisToggleBindings", function()
            EAB:RebuildVisToggleBindings()
        end)
        return
    end
    -- Unique keys that have at least one participating (always/never) bar.
    local keys, seen = {}, {}
    for _, info in ipairs(ALL_BARS) do
        local s = self.db.profile.bars[info.key]
        local k = s and s.toggleVisKey
        if k and k ~= "" and not seen[k] then
            local saved = s.barVisibility or "always"
            if saved == "always" or saved == "never" then
                seen[k] = true
                keys[#keys + 1] = k
            end
        end
    end
    -- Clear every pooled button's binding, then (re)assign one per unique key.
    self._visToggleBtnPool = self._visToggleBtnPool or {}
    for _, btn in ipairs(self._visToggleBtnPool) do
        ClearOverrideBindings(btn)
    end
    for i, k in ipairs(keys) do
        local btn = self._visToggleBtnPool[i]
        if not btn then
            btn = CreateFrame("Button", "EUIVisToggleKeyBtn" .. i, UIParent)
            btn:Hide()
            self._visToggleBtnPool[i] = btn
        end
        local thisKey = k
        btn:SetScript("OnClick", function() EAB:ToggleVisKey(thisKey) end)
        SetOverrideBindingClick(btn, true, k, btn:GetName())
    end
end

function EAB:ApplyClickThroughForBar(barKey)
    local s = self.db.profile.bars[barKey]
    if not s then return end

    -- Data bars
    local dataFrame = dataBarFrames[barKey]
    if dataFrame then
        EAB_VTABLE.ExtraBars.ApplyManagedMouse(dataFrame, false, s, dataFrame:IsShown())
        return
    end

    -- Extra bars (MicroBar, BagBar, QueueStatus)
    for _, info in ipairs(EXTRA_BARS) do
        if info.key == barKey and not info.isDataBar and not info.isBlizzardMovable then
            if info.blizzOwnedVisibility then
                local holder = extraBarHolders[barKey]
                if holder then SafeEnableMouse(holder, false) end
                local bf = _G[info.frameName]
                if bf then SafeEnableMouse(bf, true) end
            else
                local frame = _G[info.frameName]
                if frame then SafeEnableMouse(frame, not s.clickThrough) end
            end
            return
        end
    end

    -- Action bars
    local frame = barFrames[barKey]
    if not frame then return end
    local buttons = barButtons[barKey]
    if not buttons then return end

    local enable = ShouldQuickKeybindSurfaceBar(s) or not s.clickThrough
    -- When click-through is on but mouseover is enabled, keep mouse motion
    -- so OnEnter/OnLeave still fire for hover fade.
    local motionOnly = not enable and s.mouseoverEnabled
    -- Bar frame only needs mouse motion (for hover detection); clicks pass through
    -- to the buttons or to frames behind the bar.
    SafeEnableMouseMotionOnly(frame, enable or motionOnly)
    local showEmpty = s.alwaysShowButtons
    if showEmpty == nil then showEmpty = true end
    local info = BAR_LOOKUP[barKey]
    if info and info.isStance then showEmpty = false end
    for i = 1, #buttons do
        local btn = buttons[i]
        if btn then
            -- Don't re-enable mouse on invisible (parked) empty slots
            local isInvisible = not showEmpty and ns._eabParked(btn)
            if not isInvisible then
                if enable then
                    SafeEnableMouse(btn, true)
                elseif motionOnly then
                    SafeEnableMouseMotionOnly(btn, true)
                else
                    SafeEnableMouse(btn, false)
                end
            end
        end
    end
end

function EAB:UpdateHousingVisibility()
    -- Fully gated: with no bar using a non-macro visibility option and no
    -- managed non-secure bar, this sync can change nothing -- yet it's
    -- invoked on every soft-target flip, which churns constantly near NPCs.
    -- Flag maintained by _RefreshSoftTargetGate.
    if not self._anyNonMacroVis then return end
    -- Coalesced: an event burst schedules ONE deferred sync, not one per event.
    if self._housingVisPending then return end
    self._housingVisPending = true
    -- Defer to next frame to avoid taint from secure execution paths
    -- (e.g. CameraOrSelectOrMoveStop triggering PLAYER_MOUNT_DISPLAY_CHANGED)
    C_Timer.After(0, function()
        self._housingVisPending = nil
        if InCombatLockdown() then return end
        if _quickKeybindState.open then return end
        -- Check non-macro visibility options here. Secure frames still use the
        -- state driver for target/enemy conditions, but mounted-like druid
        -- forms are also handled here to cover cases [mounted] does not match.
        local function ShouldHideNonMacro(s)
            if not s then return false end
            -- An applied Visibility override replaces the whole setting, the shared option
            -- lanes included, and BuildVisibilityString already compiles it into a
            -- constant. Checked before the two raw lane reads below, which would otherwise
            -- keep hiding the bar on a lane the override took over.
            if EllesmereUI.VisOverrideValue(s) then return false end
            -- Under Any the driver string already carries both halves (Show lanes as
            -- disjuncts, Hide lanes as leading gates, the Lua-only ones resolved at build
            -- time with their own combat escape hatch), and the rebuild below refreshes
            -- it on exactly these events. A literal "hide" here would add nothing and
            -- would veto the whole disjunction on a lane that is not even firing.
            if s.visibilityMatch == "any" then return false end
            if s.visHideNoTarget then
                -- [noexists] in the state driver covers the basic has-target
                -- check even in combat. Out of combat also hide when a soft
                -- target is the only "target": macro conditionals count
                -- softinteract/softenemy/softfriend as "target exists" while
                -- UnitExists("target") doesn't, so test those tokens directly.
                if not UnitExists("target") and (UnitExists("softinteract") or UnitExists("softenemy") or UnitExists("softfriend")) then return true end
            end
            if s.visHideMounted then
                -- Regular mounts are handled entirely by the secure "[mounted] hide"
                -- clause, which self-updates even in combat. Druid travel/flight forms
                -- don't match [mounted] and fall back to this non-secure clobber, and a
                -- bare "hide" is a dead constant once written (the shift-out edge lands
                -- in combat, where this handler bails), so the marker lets the write
                -- site bake a combat escape hatch into the string instead.
                if not (IsMounted and IsMounted())
                    and EllesmereUI.IsPlayerMountedLike() then
                    return "combathide"
                end
            end
            -- Every other Lua-only option (both instance lanes, both housing lanes, both
            -- skyriding-mount lanes) comes from the shared evaluator, so a lane added
            -- there is live here too instead of silently going stale on the next zone or
            -- mount edge. skipMountAxis keeps the driver's [mounted]/[nomounted] clauses
            -- authoritative, leaving the narrower shapeshift check above as the only
            -- mount handling on this path. The skyriding-mount lanes can flip into
            -- combat like the form case, so the evaluator flags them "mountaxis".
            if EllesmereUI and EllesmereUI.CheckVisibilityOptionsNonMacro then
                local nonMacro = EllesmereUI.CheckVisibilityOptionsNonMacro(s, true)
                if nonMacro == "mountaxis" then return "combathide" end
                if nonMacro then return true end
            end
            return false
        end

        for _, info in ipairs(ALL_BARS) do
            local key = info.key
            local s = self.db.profile.bars[key]
            if s then
                if EAB_VTABLE.ExtraBars.IsManagedNonSecureBar(info) then
                    EAB_VTABLE.ExtraBars.ApplyManagedNonSecureVisibility(info)
                else
                    local frame = barFrames[key] or (info.isDataBar and dataBarFrames[key]) or (info.isBlizzardMovable and blizzMovableHolders[key]) or (extraBarHolders[key]) or (info.visibilityOnly and _G[info.frameName])
                if frame then
                    -- Secure action bar frames use the state driver for
                    -- target/enemy options (mounted-like forms handled in
                    -- ShouldHideNonMacro). Non-secure frames (data bars,
                    -- extra bars, visibility-only) need the full check: no driver.
                    local isSecure = not info.visibilityOnly and not info.isDataBar and not info.isBlizzardMovable and barFrames[key]
                    local shouldHide = isSecure and ShouldHideNonMacro(s) or (not isSecure and EllesmereUI.CheckVisibilityOptions(s))
                    -- Runtime "Toggle Action Bar" override wins over the saved mode and
                    -- non-macro hide checks, as in RefreshRuntimeVisibility: otherwise
                    -- any event routed here (target/group/mount/housing) re-applies the
                    -- saved visibility and re-shows a bar the player toggled off.
                    -- Secure managed bars only.
                    local _visToggleOv = isSecure and self._visOverride and self._visOverride[key]
                    if _visToggleOv == "never" then
                        if frame._eabLastVisStr ~= "hide" then
                            frame._eabLastVisStr = "hide"
                            RegisterAttributeDriver(frame, "state-visibility", "hide")
                        end
                    elseif _visToggleOv == "always" then
                        local ovStr = BuildVisibilityString(info, s, "always")
                        if frame._eabLastVisStr ~= ovStr then
                            frame._eabLastVisStr = ovStr
                            RegisterAttributeDriver(frame, "state-visibility", ovStr)
                        end
                    elseif shouldHide then
                        if isSecure then
                            -- "combathide" (druid mount-like form, skyriding-mount lanes): a
                            -- lane that can flip INTO combat must not be a dead constant, so
                            -- hide out of combat and fall back to the real driver in combat
                            -- (mode, prefixes and any [mounted] clause keep working there).
                            -- Never / always-hidden bars keep the plain hide.
                            local hideStr = "hide"
                            if shouldHide == "combathide" and not s.alwaysHidden
                                and (s.barVisibility or "always") ~= "never" then
                                hideStr = "[nocombat] hide; " .. BuildVisibilityString(info, s)
                            end
                            if frame._eabLastVisStr ~= hideStr then

                                frame._eabLastVisStr = hideStr
                                RegisterAttributeDriver(frame, "state-visibility", hideStr)
                            end
                        elseif info.blizzOwnedVisibility then
                            local bf = _G[info.frameName]
                            if bf then
                                EFD(bf).visWasShown = bf:IsShown()
                                bf:Hide()
                            end
                        else
                            frame:Hide()
                        end
                    elseif not s.alwaysHidden and (s.barVisibility or "always") ~= "never" then
                        if isSecure then
                            local newStr = BuildVisibilityString(info, s)
                            if frame._eabLastVisStr ~= newStr then

                                frame._eabLastVisStr = newStr
                                RegisterAttributeDriver(frame, "state-visibility", newStr)
                            end
                        elseif info.blizzOwnedVisibility then
                            local bf = _G[info.frameName]
                            if bf and EFD(bf).visWasShown then
                                bf:Show()
                            end
                            if bf then EFD(bf).visWasShown = nil end
                        -- Restore our movable wrapper, respecting all remaining
                        -- visibility gates (including pet battles).
                        elseif not info.isBlizzardMovable
                           or EAB_VTABLE.ExtraBars.ShouldShowManagedNonSecureBar(s) then
                            frame:Show()
                        end
                        -- Data bars may need to re-hide (max level, max renown, etc.)
                        if info.isDataBar and frame._updateFunc then
                            frame._updateFunc()
                        end
                    end
                end
                end
            end
        end
    end)
end

-------------------------------------------------------------------------------
--  Pushed / Highlight / Cooldown Edge / Misc Textures / Proc Glows
--  These are global settings that apply to ALL action bar buttons.
-------------------------------------------------------------------------------
local PUSHED_TYPES = {
    [1] = "light",   -- Light overlay
    [2] = "medium",  -- Medium overlay
    [3] = "strong",  -- Strong overlay
    [4] = "solid",   -- Solid color fill
    [5] = "border",  -- Border only
    [6] = "none",    -- No pushed effect
}

do
local function _setupBorderEdges(btn, storeKey, driverTex)
    -- Edge state lives in EFD, never on the button table: StanceBar/PetBar
    -- flow through here with BLIZZARD-owned buttons (StanceButton/
    -- PetActionButton), which must never receive custom keys.
    local edges = EFD(btn)[storeKey]
    if not edges then
        edges = {}
        for j = 1, 4 do
            local t = btn:CreateTexture(nil, "OVERLAY", nil, 2)
            t:SetColorTexture(1, 1, 1, 1)
            t:Hide()
            edges[j] = t
        end
        EFD(btn)[storeKey] = edges
        if driverTex then
            hooksecurefunc(driverTex, "Show", function()
                if not edges._active then return end
                for j = 1, 4 do edges[j]:Show() end
            end)
            hooksecurefunc(driverTex, "Hide", function()
                for j = 1, 4 do edges[j]:Hide() end
            end)
        end
    end
    return edges
end

local function _applyBorderEdges(edges, btn, brdSize, cr, cg, cb)
    edges._active = true
    local anchor = btn.icon or btn.Icon or btn
    local PP = EllesmereUI.PP
    for j = 1, 4 do edges[j]:SetVertexColor(cr, cg, cb, 1) end
    edges[1]:ClearAllPoints(); edges[1]:SetPoint("TOPLEFT", anchor); edges[1]:SetPoint("TOPRIGHT", anchor)
    if PP then PP.Height(edges[1], brdSize) else edges[1]:SetHeight(brdSize) end
    edges[2]:ClearAllPoints(); edges[2]:SetPoint("BOTTOMLEFT", anchor); edges[2]:SetPoint("BOTTOMRIGHT", anchor)
    if PP then PP.Height(edges[2], brdSize) else edges[2]:SetHeight(brdSize) end
    edges[3]:ClearAllPoints(); edges[3]:SetPoint("TOPLEFT", edges[1], "BOTTOMLEFT"); edges[3]:SetPoint("BOTTOMLEFT", edges[2], "TOPLEFT")
    if PP then PP.Width(edges[3], brdSize) else edges[3]:SetWidth(brdSize) end
    edges[4]:ClearAllPoints(); edges[4]:SetPoint("TOPRIGHT", edges[1], "BOTTOMRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT", edges[2], "TOPRIGHT")
    if PP then PP.Width(edges[4], brdSize) else edges[4]:SetWidth(brdSize) end
end

local function _hideBorderEdges(btn, storeKey)
    local edges = EFD(btn)[storeKey]
    if not edges then return end
    edges._active = false
    for j = 1, 4 do edges[j]:Hide() end
end
ns._setupBorderEdges = _setupBorderEdges
ns._applyBorderEdges = _applyBorderEdges
ns._hideBorderEdges  = _hideBorderEdges
end

-------------------------------------------------------------------------------
--  Match Bar Border (the Pushed / Highlight Border Settings cogs and the Spell
--  Cast Highlight cog). On bars with a textured Border Style, a press, a hover
--  or the active spell lights up a tinted copy of the button's own border in
--  place of the flat edge lines (pushed / hover) or the checked fill (cast).
--  One copy per button, built the first time a role arms it on an eligible
--  bar, never for players who leave the options off: EFD(btn).ixBorder is a
--  wrapper frame and the only Show/Hide target, EFD(btn).ixHost inside it
--  carries the backdrop and stays shown, so neither a restyle nor the UI-scale
--  re-apply (EllesmereUI.ReapplyPxBorders) can flash or drop the copy. Roles
--  (EFD ixPush / ixHover / ixCast) are armed by the three Apply*Textures
--  passes; the live states (ixPressed / ixOver / ixChecked) come from hooks
--  whose bodies return at once unless their role is armed. ONE painter picks
--  pressed > spell cast > hover. While the copy shows, the bar border hides
--  through its own backdrop's alpha (our frame), never Hide(); the button's
--  own alpha is never read or written. All on ns: the main chunk is at the
--  200-local cap.
-------------------------------------------------------------------------------

-- Tint slots (r, g, b, a), refilled in place by the pushed and highlight passes
-- while their role is on, so a paint allocates nothing.
ns._ixPushC = { 1, 1, 1, 1 }
ns._ixHlC   = { 1, 1, 1, 1 }
-- [barKey] = the bar's last computed eligibility (GetCheckedAlpha reads it).
ns._ixElig  = {}

-- Which roles are on, from the profile alone: each needs its own opt-in plus
-- the setting it restyles (Border pushed / highlight type, cast highlight on).
ns._ixRolesOn = function(p)
    return (p.pushedBorderMatchBar and (p.pushedTextureType or 2) == 5) or false,
        (p.highlightBorderMatchBar and (p.highlightTextureType or 2) == 5) or false,
        (p.castHighlightBorder and p.showCastHighlight ~= false) or false
end

-- Bar eligibility: EllesmereUI style, square icons, a None or Cropped shape, a
-- textured Border Style that resolves to a file, Border Size above 0. Returns
-- it and whether it differs from the stored value (stored here).
ns._ixBarEligible = function(barKey)
    local p = EAB.db.profile
    local s = p.bars[barKey]
    local ok = false
    if s and p.squareIcons and ns.AB_Style() == "eui" then
        local shape = s.buttonShape or "none"
        local tex = s.borderTexture or "solid"
        if (shape == "none" or shape == "cropped") and tex ~= "" and tex ~= "solid"
           and EllesmereUI.ResolveBorderTexture(tex) then
            ok = ResolveBorderThickness(s) > 0
        end
    end
    local changed = ns._ixElig[barKey] ~= ok
    ns._ixElig[barKey] = ok
    return ok, changed
end

-- Styles the copy exactly like the bar border: texture, step, exact size,
-- offsets, shifts, and the bar border's frame level (Show Behind / Border
-- Above Effects; ApplyBorderStyle resets the backdrop to the host's level, so
-- it is set again after). Keeps the current tint. Unmemoized, like the bar
-- border's own textured path. Callers keep it out of combat.
ns._ixStyle = function(btn, fd, s)
    local host = fd.ixHost
    local sz, px = ResolveBorderThickness(s)
    EllesmereUI.ApplyBorderStyle(host, sz, fd.ixR or 1, fd.ixG or 1, fd.ixB or 1, fd.ixA or 1,
        s.borderTexture, s.borderTextureOffset, s.borderTextureOffsetY,
        s.borderTextureShiftX, s.borderTextureShiftY, "actionbars",
        s.borderThickness or "thin", nil, px)
    local bd = EllesmereUI._bdBorderData[host]
    if bd then bd:SetFrameLevel(ns._eabBorderLevel(btn, s.borderBehind, s.borderAboveEffects)) end
    fd.ixStyled = true
end

-- The one painter: pressed > spell cast > hover (cast and hover share the
-- highlight tint). Recolours only on a real change, shows and hides only on an
-- edge. Runs from hooks in and out of combat: our own frames only.
ns._ixPaint = function(btn, fd)
    local w = fd.ixBorder
    if not w then return end
    local bdData = EllesmereUI._bdBorderData
    local bd = bdData[fd.ixHost]
    local c
    if bd then
        if fd.ixPressed and fd.ixPush then
            c = ns._ixPushC
        elseif (fd.ixChecked and fd.ixCast) or (fd.ixOver and fd.ixHover) then
            c = ns._ixHlC
        end
    end
    if c then
        local r, g, b, a = c[1], c[2], c[3], c[4]
        if fd.ixR ~= r or fd.ixG ~= g or fd.ixB ~= b or fd.ixA ~= a then
            fd.ixR, fd.ixG, fd.ixB, fd.ixA = r, g, b, a
            bd:SetBackdropBorderColor(r, g, b, a)
        end
        if not fd.ixLit then
            fd.ixLit = true
            local base = bdData[btn]
            if base then
                fd.ixBaseA = base:GetAlpha()
                base:SetAlpha(0)
            end
            w:Show()
        end
    elseif fd.ixLit then
        fd.ixLit = nil
        w:Hide()
        local base = bdData[btn]
        if base then base:SetAlpha(fd.ixBaseA or 1) end
    end
end

-- Pressed-state drivers, one shared function each. Bodies return unless the
-- pushed role is armed (or, to release, a press is recorded).
ns._ixPressOn = function(btn)
    local fd = ns._eabFD[btn]
    if fd and fd.ixPush and not fd.ixPressed then
        fd.ixPressed = true
        ns._ixPaint(btn, fd)
    end
end
ns._ixPressOff = function(btn)
    local fd = ns._eabFD[btn]
    if fd and fd.ixPressed then
        fd.ixPressed = nil
        ns._ixPaint(btn, fd)
    end
end

-- Installed once per button, the first time the pushed role arms it. The
-- keybind flash path shows and hides PushedTexture from Lua; a mouse press is
-- drawn by the engine with no Lua call, so the button's own mouse scripts
-- drive that half, and OnHide drops a press a hidden bar would strand. A drag
-- off the button may never deliver OnMouseUp, so OnDragStart drops it too, on
-- our own action buttons only (the Stance and Pet bars reuse Blizzard's).
ns._ixHookPress = function(btn, fd)
    fd.ixPressHooked = true
    local pt = btn.PushedTexture
    if pt then
        hooksecurefunc(pt, "Show", function() ns._ixPressOn(btn) end)
        hooksecurefunc(pt, "Hide", function() ns._ixPressOff(btn) end)
    end
    btn:HookScript("OnMouseDown", ns._ixPressOn)
    btn:HookScript("OnMouseUp", ns._ixPressOff)
    btn:HookScript("OnHide", ns._ixPressOff)
    if _controllerButtons[btn] then btn:HookScript("OnDragStart", ns._ixPressOff) end
end

-- Reads the checked state and paints only when it really changed. A secret
-- value is skipped without a retry; the next SetChecked samples again.
ns._ixSampleChecked = function(btn, fd)
    local c = btn:GetChecked()
    if issecretvalue and issecretvalue(c) then return end
    c = c and true or nil
    if fd.ixChecked ~= c then
        fd.ixChecked = c
        ns._ixPaint(btn, fd)
    end
end

-- Installed once per button, the first time the cast role arms it. Blizzard's
-- UpdateState and our own dispatcher both set the checked state through
-- SetChecked. The hooked argument is never read (it can be secret).
ns._ixHookChecked = function(btn, fd)
    fd.ixCheckHooked = true
    hooksecurefunc(btn, "SetChecked", function()
        local d = ns._eabFD[btn]
        if d and d.ixCast then ns._ixSampleChecked(btn, d) end
    end)
end

-- Arms (on) or disarms one role ("ixPush" / "ixHover" / "ixCast") on one
-- button; returns whether it is armed. The first arm builds and styles the
-- copy and installs the role's driver, out of combat only: a combat arm defers
-- to the regen ApplyAll and returns false, so the caller keeps its own look.
-- Dropping the last role hides the copy, restores the bar border's alpha and
-- takes the host out of the px re-apply registry (HideBorderStyle).
ns._ixRole = function(btn, s, role, on)
    local fd = EFD(btn)
    if on then
        local needHook = (role == "ixPush" and not fd.ixPressHooked)
            or (role == "ixCast" and not fd.ixCheckHooked)
        if not fd.ixStyled or needHook then
            if InCombatLockdown() then
                ns._eabApplyDeferred = true
                return false
            end
            if not fd.ixBorder then
                local w = CreateFrame("Frame", nil, btn)
                w:SetAllPoints(btn)
                w:Hide()
                local host = CreateFrame("Frame", nil, w)
                host:SetAllPoints(w)
                fd.ixBorder, fd.ixHost = w, host
                ns._ixEver = true
            end
            if not fd.ixStyled then ns._ixStyle(btn, fd, s) end
            if role == "ixPush" and not fd.ixPressHooked then ns._ixHookPress(btn, fd) end
            if role == "ixCast" and not fd.ixCheckHooked then ns._ixHookChecked(btn, fd) end
        end
        fd[role] = true
        -- A (re)armed cast role starts from the button's real state.
        if role == "ixCast" then ns._ixSampleChecked(btn, fd) end
        ns._ixPaint(btn, fd)
        return true
    elseif fd[role] then
        fd[role] = nil
        if role == "ixPush" then
            fd.ixPressed = nil
        elseif role == "ixHover" then
            fd.ixOver = nil
        else
            fd.ixChecked = nil
        end
        ns._ixPaint(btn, fd)
        if fd.ixStyled and not (fd.ixPush or fd.ixHover or fd.ixCast) then
            EllesmereUI.HideBorderStyle(fd.ixHost)
            fd.ixStyled = nil
        end
    end
    return false
end

-- Tail of ApplyBordersForBar / ApplyShapesForBar. Armed copies restyle with the
-- bar border (out of combat; a combat pass defers to the regen ApplyAll);
-- eligOnly (the shape tail) skips that restyle. A bar that moved in or out of
-- eligibility re-runs the three role passes, which own the edges-or-copy
-- choice; ApplyAll runs them itself right after its bar loop.
ns._ixBarSync = function(barKey, eligOnly)
    local p = EAB.db and EAB.db.profile
    if not p then return end
    local push, hover, cast = ns._ixRolesOn(p)
    if not (push or hover or cast) then return end
    local elig, changed = ns._ixBarEligible(barKey)
    if elig and not eligOnly then
        local buttons = barButtons[barKey]
        local s = p.bars[barKey]
        if buttons and s then
            if InCombatLockdown() then
                ns._eabApplyDeferred = true
            else
                for i = 1, #buttons do
                    local btn = buttons[i]
                    local fd = btn and ns._eabFD[btn]
                    if fd and fd.ixStyled then ns._ixStyle(btn, fd, s) end
                end
            end
        end
    end
    if changed and not _isApplyingAll then
        EAB:ApplyPushedTextures()
        EAB:ApplyHighlightTextures()
        EAB:ApplyCheckedTextures()
    end
end

function EAB:ApplyPushedTextures()
    local p = self.db.profile
    local abStyle = ns.AB_Style()
    local pType = p.pushedTextureType or 2
    local useCC = p.pushedUseClassColor
    local customC = p.pushedCustomColor or { r=0.973, g=0.839, b=0.604, a=1 }
    local brdSize = p.pushedBorderSize or 4

    local cr, cg, cb = customC.r, customC.g, customC.b
    if useCC then
        local _, ct = UnitClass("player")
        if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then cr, cg, cb = cc.r, cc.g, cc.b end end
    end

    -- Match Bar Border (pushed): eligible bars trade the flat edges for the
    -- button's own border copy, tinted with this colour and its alpha. Once a
    -- copy exists (ixEver), every path that does not arm the role disarms it.
    local ixOn = abStyle == "eui" and (ns._ixRolesOn(p))
    if ixOn then
        local t = ns._ixPushC
        t[1], t[2], t[3], t[4] = cr, cg, cb, customC.a or 1
    end
    local ixEver = ns._ixEver

    for _, info in ipairs(BAR_CONFIG) do
        local buttons = barButtons[info.key]
        if buttons then
            local s = p.bars[info.key]
            local ixBar = ixOn and ns._ixBarEligible(info.key)
            for i = 1, #buttons do
                local btn = buttons[i]
                if btn and btn.PushedTexture then
                    if abStyle ~= "eui" then
                        if abStyle == "classic" then
                            -- Classic WoW UI: the vanilla depress art over the button.
                            btn.PushedTexture:SetAtlas(nil)
                            btn.PushedTexture:SetTexture(ns.AB_CLASSIC.pushed)
                            btn.PushedTexture:SetTexCoord(0, 1, 0, 1)
                        elseif info.isStance or info.isPetBar then
                            -- Blizzard's buttons: its own art pass re-atlases them.
                            btn.PushedTexture:SetAtlas("UI-HUD-ActionBar-IconFrame-Down", true)
                        else
                            ns.AB_StockAtlas(btn.PushedTexture, "UI-HUD-ActionBar-IconFrame-Down", true)
                        end
                        btn.PushedTexture:SetDrawLayer("OVERLAY", 7)
                        btn.PushedTexture:ClearAllPoints()
                        btn.PushedTexture:SetAllPoints(btn)
                        btn.PushedTexture:SetVertexColor(1, 1, 1, 1)
                        btn.PushedTexture:SetAlpha(1)
                        ns._hideBorderEdges(btn, "_pushedBorder")
                    elseif pType == 6 then
                        btn.PushedTexture:SetAlpha(0)
                        ns._hideBorderEdges(btn, "_pushedBorder")
                    elseif pType == 5 then
                        btn.PushedTexture:SetAlpha(0)
                        if ixBar and ns._ixRole(btn, s, "ixPush", true) then
                            ns._hideBorderEdges(btn, "_pushedBorder")
                        else
                            local edges = ns._setupBorderEdges(btn, "_pushedBorder", btn.PushedTexture)
                            ns._applyBorderEdges(edges, btn, brdSize, cr, cg, cb)
                        end
                    else
                        btn.PushedTexture:SetAlpha(1)
                        ns._hideBorderEdges(btn, "_pushedBorder")
                        if pType <= 3 then
                            SetSquareTexture(btn.PushedTexture, HIGHLIGHT_TEXTURES[pType] or HIGHLIGHT_TEXTURES[2])
                            btn.PushedTexture:SetVertexColor(cr, cg, cb, 1)
                        elseif pType == 4 then
                            btn.PushedTexture:SetColorTexture(cr, cg, cb, 0.35)
                        end
                    end
                    -- Stock styles, other pushed types, the option off and
                    -- bars that left eligibility all land here.
                    if ixEver and not ixBar then ns._ixRole(btn, s, "ixPush", false) end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Pushed-State Flash: SetOverrideBinding routes keybinds to native engine
--  commands (ACTIONBUTTON1 etc.) so the engine fires the action directly
--  without clicking our buttons, so they never enter PUSHED state from
--  keyboard. Fix: hook UseAction to show PushedTexture, global keyup watcher
--  to hide all active textures.
-------------------------------------------------------------------------------
do
    local _pushedHooked = false
    local _activePushed = {}  -- btn -> true
    local _activePushedN = 0
    local _btnKeys = {}       -- btn -> { k1, k2 } (reused, no alloc per press)
    local _pollFrame
    function EAB:HookPushedFlash()
        if _pushedHooked then return end
        _pushedHooked = true
        _pollFrame = ns.TakeShell()
        _pollFrame:SetScript("OnUpdate", function()
            if _activePushedN == 0 then
                _pollFrame:Hide()
                return
            end
            for btn in pairs(_activePushed) do
                local keys = _btnKeys[btn]
                local held = false
                if keys then
                    for i = 1, #keys do
                        if IsKeyDown(keys[i]) then held = true; break end
                    end
                end
                if not held then
                    if btn.PushedTexture then btn.PushedTexture:Hide() end
                    _activePushed[btn] = nil
                    _activePushedN = _activePushedN - 1
                end
            end
            if _activePushedN == 0 then _pollFrame:Hide() end
        end)
        _pollFrame:Hide()
        -- Extract the base key from a compound binding ("SHIFT-1" -> "1",
        -- "CTRL-Q" -> "Q"): IsKeyDown only accepts raw key names.
        local function BaseKey(binding)
            if not binding then return nil end
            -- The minus key's name is the literal "-", so "-" and modifier
            -- combos like "SHIFT--" END in "-": the trailing char IS the key,
            -- and the pattern below would find no non-hyphen run (nil).
            if binding:sub(-1) == "-" then return "-" end
            return binding:match("[^%-]+$")
        end
        local function ShowPushedForSlot(slot)
            local prof = EAB.db and EAB.db.profile
            if not prof then return end
            if ns.AB_Style() == "eui" and (prof.pushedTextureType or 2) == 6 then return end
            local btn = allButtons[slot]
            if not btn or not btn.PushedTexture then return end
            local cmd = btn.commandName
            if not cmd then return end
            local k1, k2 = GetBindingKey(cmd)
            if not k1 then return end
            local keys = _btnKeys[btn]
            if not keys then keys = {}; _btnKeys[btn] = keys end
            keys[1] = BaseKey(k1); keys[2] = BaseKey(k2); keys[3] = nil
            btn.PushedTexture:Show()
            if not _activePushed[btn] then
                _activePushed[btn] = true
                _activePushedN = _activePushedN + 1
            end
            _pollFrame:Show()
        end
        -- ActionButtonDown/MultiActionButtonDown fire on key press regardless
        -- of "cast on key down" CVar. This ensures pushed texture shows while
        -- the key is held for both key-down and key-up casting modes.
        hooksecurefunc("ActionButtonDown", function(id) ShowPushedForSlot(id) end)
        if MultiActionButtonDown then
            local multiBarPage = {
                MultiBarBottomLeft  = 6,
                MultiBarBottomRight = 5,
                MultiBarRight       = 3,
                MultiBarLeft        = 4,
                MultiBar5           = 13,
                MultiBar6           = 14,
                MultiBar7           = 15,
            }
            hooksecurefunc("MultiActionButtonDown", function(barName, id)
                local page = multiBarPage[barName]
                if not page then return end
                local slot = (page - 1) * 12 + id
                ShowPushedForSlot(slot)
            end)
        end
    end
end

function EAB:ApplyHighlightTextures()
    local p = self.db.profile
    local abStock = ns.AB_Style() ~= "eui"
    local hType = p.highlightTextureType or 2
    local useCC = p.highlightUseClassColor
    local customC = p.highlightCustomColor or { r=0.973, g=0.839, b=0.604, a=1 }
    local brdSize = p.highlightBorderSize or 4

    local cr, cg, cb = customC.r, customC.g, customC.b
    if useCC then
        local _, ct = UnitClass("player")
        if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then cr, cg, cb = cc.r, cc.g, cc.b end end
    end

    -- Match Bar Border (hover), plus the tint the spell-cast copy shares with
    -- it (this colour and its alpha). Once a copy exists (ixEver), every path
    -- that does not arm the hover role disarms it, and a lit cast copy picks
    -- up a colour change here. The tint is refreshed on every pass, options
    -- off included: the Spell Cast Highlight toggles arm the cast role through
    -- ApplyCheckedTextures alone, which paints with this slot as it stands.
    local _, ixOn, ixCast = ns._ixRolesOn(p)
    ixOn = ixOn and not abStock
    do
        local t = ns._ixHlC
        t[1], t[2], t[3], t[4] = cr, cg, cb, customC.a or 1
    end
    local ixEver = ns._ixEver

    for _, info in ipairs(BAR_CONFIG) do
        if abStock then
            -- skip -- the stock kit owns the highlight (classic paints its
            -- own in ns.AB_PaintClassicButton)
            local buttons = ixEver and barButtons[info.key]
            if buttons then
                for i = 1, #buttons do
                    local btn = buttons[i]
                    if btn then ns._ixRole(btn, nil, "ixHover", false) end
                end
            end
        else
        local buttons = barButtons[info.key]
        if buttons then
            local s = p.bars[info.key]
            local ixBar = ixOn and ns._ixBarEligible(info.key)
            for i = 1, #buttons do
                local btn = buttons[i]
                if btn and btn.HighlightTexture then
                    if hType == 6 then
                        btn.HighlightTexture:SetAlpha(0)
                        ns._hideBorderEdges(btn, "_highlightBorder")
                    elseif hType == 5 then
                        btn.HighlightTexture:SetAlpha(0)
                        if ixBar and ns._ixRole(btn, s, "ixHover", true) then
                            ns._hideBorderEdges(btn, "_highlightBorder")
                        else
                            local edges = ns._setupBorderEdges(btn, "_highlightBorder")
                            ns._applyBorderEdges(edges, btn, brdSize, cr, cg, cb)
                        end
                        if not EFD(btn).hlBorderHooked then
                            EFD(btn).hlBorderHooked = true
                            -- Hover driver for both looks: the armed copy, else
                            -- today's edges.
                            btn:HookScript("OnEnter", function(self)
                                local fd = EFD(self)
                                if fd.ixHover then
                                    fd.ixOver = true
                                    ns._ixPaint(self, fd)
                                    return
                                end
                                local be = fd._highlightBorder
                                if be and be._active then for j = 1, 4 do be[j]:Show() end end
                            end)
                            btn:HookScript("OnLeave", function(self)
                                local fd = EFD(self)
                                if fd.ixOver then
                                    fd.ixOver = nil
                                    ns._ixPaint(self, fd)
                                end
                                local be = fd._highlightBorder
                                if be then for j = 1, 4 do be[j]:Hide() end end
                            end)
                        end
                    else
                        btn.HighlightTexture:SetAlpha(1)
                        ns._hideBorderEdges(btn, "_highlightBorder")
                        if hType <= 3 then
                            SetSquareTexture(btn.HighlightTexture, HIGHLIGHT_TEXTURES[hType] or HIGHLIGHT_TEXTURES[1])
                            btn.HighlightTexture:SetVertexColor(cr, cg, cb, 1)
                        elseif hType == 4 then
                            btn.HighlightTexture:SetColorTexture(cr, cg, cb, 0.35)
                        end
                    end
                    if ixEver and not ixBar then ns._ixRole(btn, s, "ixHover", false) end
                end
                if ixCast and ixEver and btn then
                    local fd = ns._eabFD[btn]
                    if fd and fd.ixCast then ns._ixPaint(btn, fd) end
                end
                _quickKeybindState.art.RefreshButton(btn)
            end
        end
        end -- abStock
    end

    -- Blizzard-owned special buttons do not flow through the standard bar
    -- button setup, but QuickKeybind still resets their overlay atlas.
    -- Keep their QuickKeybind highlight aligned with the EUI button art too.
    _quickKeybindState.art.ForEachSpecialButton(_quickKeybindState.art.InitializeButton)
end

-------------------------------------------------------------------------------
--  Keybind System: ALL standard-bar slots (empowered spells included) bind to
--  native commands (ACTIONBUTTON1 etc.) -- the engine pairs press/release
--  against the physical key, which is the only queue-safe empower path. A
--  click-routed key delivers stateless up/down clicks, and an up landing
--  while an empower is still QUEUED files a release the engine honors the
--  instant the cast starts (the rank-1 latch; typerelease-disarm gating was
--  field-tested against it and failed -- the up is consumed as a second
--  UseAction, not as a release attribute read). Click routing remains ONLY
--  where native commands cannot express the slot: custom-paged bars and
--  Bar9/Bar10.
-------------------------------------------------------------------------------
local _bindState = { housingCleared = false }

-- Binding owner: one frame owns all override bindings so they clear/reapply as
-- a unit. Native-command routing (ACTIONBUTTON1, etc.) lets the engine's
-- hold-to-cast and empowered-spell systems work without our own attrs.
local _eabBindOwner = CreateFrame("Frame", "EAB_BindOwner", UIParent)

-- Returns true when the override bindings were (re)applied, false when the
-- routing signature was unchanged and the rebuild was skipped.
--
-- The signature cache exists because rebuilding is expensive: up to two override
-- bindings cleared and re-registered per button (engine binding-table rebuilds) plus
-- GetActionInfo/IsPressHoldReleaseSpell per slot, and the empower reroute calls this on
-- ACTIONBAR_SLOT_CHANGED, which storms dozens of times/sec with mouseover-conditional
-- macros (each flip re-resolves them). Slot contents do NOT change the bindings
-- themselves (keys map to native commands or button names, not actions), so a rebuild
-- is only needed when a routing decision, bound key, or empower state changes.
local function UpdateKeybinds()
    -- Combat bail, self-re-arming. Everything below is protected
    -- (ClearOverrideBindings/SetOverrideBindingClick) so it cannot run here,
    -- and returning false with nothing to retry drops the whole build: the
    -- load-time apply has no deferral of its own, so logging in or reloading
    -- during combat leaves EVERY override binding unapplied for the session
    -- -- custom-bound keys dead and custom-paged routing wrong. (A previous
    -- version of this comment blamed native bindings for press-and-tap
    -- empower behaviour; superseded 2026-08-09 -- empowers route native BY
    -- DESIGN now, with hold-and-release engine-owned.)
    -- Re-arming here covers every caller at once; sibling paths that already defer share
    -- the "UpdateKeybinds" queue key, so the rebuild runs once after combat.
    if InCombatLockdown() then
        ns.CombatQueue.Defer("UpdateKeybinds", UpdateKeybinds)
        return false
    end
    -- With the house editor active our overrides are cleared so Blizzard's
    -- housing hotkeys work (see Housing Editor Keybind Clearing). The editor
    -- then registers its OWN overrides, firing UPDATE_BINDINGS straight back
    -- here; without this guard the rebuild re-applies ~200 of ours on top and
    -- stomps the housing hotkeys until the editor's next mode change. Rebuild
    -- resumes on editor close (housingCleared reset -> UpdateKeybinds;
    -- sigValid stays false while cleared, so that rebuild is never skipped).
    if _bindState.housingCleared then return false end
    -- A hidden bar skipped at load must exist the moment a key lands on one of
    -- its commands (UPDATE_BINDINGS lands here): hidden bars keep live
    -- bindings, and a click-routed key has no button to route to otherwise.
    -- Combat already bailed above, so the build is legal here; the passes
    -- below then bind the new buttons like any other.
    ns._eabBuildSkippedBars()
    -- Empower detection for one action slot, shared by the current-page
    -- and base-slot checks in pass 1.
    local function SlotIsPH(slot)
        if not (slot and HasAction(slot)) then return false end
        local actionType, id, subType = GetActionInfo(slot)
        if actionType == "flyout" then return true end
        if C_Spell and C_Spell.IsPressHoldReleaseSpell then
            local spellID
            if actionType == "spell" then
                spellID = id
            elseif actionType == "macro" and subType == "spell" then
                spellID = id
            end
            if spellID and not (issecretvalue and issecretvalue(spellID))
               and C_Spell.IsPressHoldReleaseSpell(spellID) then
                return true
            end
        end
        return false
    end
    -- Flyout detection, split out from SlotIsPH. A flyout MUST click-route to
    -- our visible EABButton: SpellFlyout:Toggle anchors to self, and native
    -- command routing (ACTIONBUTTONn) fires on Blizzard's original button,
    -- which we hide/reparent off-screen (see stock-bar hiding above) --
    -- opening the popup there produces no visible menu even though the key
    -- was received. Empowers have no popup to anchor, so they're unaffected
    -- and must stay on the native command (see routing comment below).
    local function SlotIsFlyout(slot)
        if not (slot and HasAction(slot)) then return false end
        return GetActionInfo(slot) == "flyout"
    end
    -- Pass 1: compute per-button routing signature (k1, k2, useClick, isPH)
    -- and compare against the last applied build.
    local sig = _bindState.sig
    if not sig then sig = {}; _bindState.sig = sig end
    local n = 0
    local changed = not _bindState.sigValid
    local anyPH = false
    for _, info in ipairs(BAR_CONFIG) do
        local prefix = BINDING_MAP[info.key]
        local btns = barButtons[info.key]
        if prefix and btns then
            -- Custom modifier/form paging lives only in our private secure
            -- state driver, which never moves Blizzard's GetActionBarPage().
            -- Native engine commands (ACTIONBUTTONn / MULTIACTIONBARxBUTTONn)
            -- resolve against Blizzard's page, so on a custom-paged bar the
            -- keybind would fire the un-paged slot while the icon (our
            -- explicit "action" attr) repages. Route those bars' keybinds
            -- through the button (SetOverrideBindingClick) so the keypress
            -- reads our paged "action" attr, exactly as empower/flyout already do.
            --
            -- Class-default form paging (Druid/Rogue; every class's stance or
            -- form on WoW Forever) is NOT custom paging:
            -- it rides on bonusbar, a native engine concept ACTIONBUTTONn
            -- resolves on its own, so icon and native keybind already agree
            -- in every form. Click-routing those bars would only cost
            -- press-and-hold repeat casting (a synthetic click never reaches
            -- UseAction with isKeyPress=true), so they must stay on the
            -- native command -- only genuine user-configured paging (bs.paging) needs the click route.
            local bs = EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars[info.key]
            local barHasCustomPaging = (bs and bs.paging and next(bs.paging) ~= nil) and true or false
            -- Auto-paging opt-outs need the click route for the mirror-image
            -- reason: bonusbar stays a native engine concept whether or not
            -- we page off it, so ACTIONBUTTONn still resolves to the
            -- form/skyriding slot after we deliberately STOP the icon from
            -- following it. Left native, a stealthed keypress casts the
            -- page-7 ability the button no longer shows (the show-one/
            -- fire-another split GetClassPagingConditions warns about). Cost:
            -- press-and-hold repeat on MainBar while the opt-out is on.
            if info.key == "MainBar" and bs
               and (bs.disableFormPaging or bs.disableSkyridingPaging) then
                barHasCustomPaging = true
            end
            for i, btn in ipairs(btns) do
                if btn then
                    local cmd = prefix .. i
                    local k1, k2 = GetBindingKey(cmd)
                    -- Routing is native for everything on standard bars,
                    -- empowers included (flyouts are the exception -- see
                    -- isFlyout below): the engine's keystate-paired
                    -- hold-and-release is the only queue-safe empower path
                    -- (stateless click routes latch queued releases at
                    -- rank 1). Click routing exists ONLY where a native
                    -- command cannot express the slot: custom-paged bars
                    -- (above) and the custom bars.
                    local slot = btn:GetAttribute("action")
                    -- Custom bars (Bar9/Bar10) have no native binding command, so
                    -- their keys MUST click-route; SetOverrideBinding to a
                    -- non-existent command does nothing. isPH tracks empower
                    -- state separately from useClick: on a custom-paged bar
                    -- useClick is always true, but the secure empower snippet
                    -- still needs a re-trigger when press-and-hold state flips.
                    local isPH = SlotIsPH(slot)
                    -- Base-slot check: isPH no longer decides ROUTING on its
                    -- own (empowers stay native either way); it stays in the
                    -- signature so
                    -- pass 3 re-fires the attr re-check when a slot's
                    -- press-and-hold state genuinely changes (mouse-click
                    -- correctness), and it feeds the combat-drop re-assert
                    -- gate. Consulting the BASE slot keeps the signature
                    -- stable across page swaps -- deriving it from the
                    -- CURRENT page only would rebuild ~200 bindings on every
                    -- mount and dismount (skyriding page flips). Guarded on
                    -- the offsets table so Pet/Stance buttons (action attr
                    -- nil) never alias into MainBar slots.
                    local isFlyout = SlotIsFlyout(slot)
                    if not isPH then
                        local off = BAR_SLOT_OFFSETS[info.key]
                        if off then
                            local base = off + i
                            if base ~= slot then
                                isPH = SlotIsPH(base)
                            end
                        end
                    end
                    if isPH then anyPH = true end
                    -- isPH (empower) deliberately NOT part of the routing
                    -- decision: empower keys must ride the native command.
                    -- isFlyout IS part of it: flyouts need self to be the
                    -- visible button so SpellFlyout anchors somewhere the
                    -- player can actually see.
                    local useClick = barHasCustomPaging or (info.customPage ~= nil) or isFlyout
                    k1 = k1 or false
                    k2 = k2 or false
                    if sig[n + 1] ~= k1 or sig[n + 2] ~= k2
                       or sig[n + 3] ~= useClick or sig[n + 4] ~= isPH then
                        changed = true
                    end
                    sig[n + 1], sig[n + 2], sig[n + 3], sig[n + 4] = k1, k2, useClick, isPH
                    n = n + 4
                end
            end
        end
    end
    if _bindState.sigN ~= n then changed = true; _bindState.sigN = n end
    -- Tracked on every full pass (even signature-unchanged ones) so the
    -- combat-drop attr re-assert knows whether any press-and-hold slot
    -- exists at all -- non-empower classes never pay for it.
    _bindState.hasPH = anyPH
    -- Blizzard's twin buttons are what a natively-routed empower key actually
    -- drives; their pressAndHoldAction is kept current by Blizzard's own
    -- SLOT_CHANGED and PLAYER_ENTERING_WORLD registrations, which the
    -- broadcaster quieting at the top of the file leaves untouched.
    if not changed then return false end
    _bindState.sigValid = true
    -- Pass 2: apply. Reads the routing decisions computed above.
    ClearOverrideBindings(_eabBindOwner)
    local j = 0
    for _, info in ipairs(BAR_CONFIG) do
        local prefix = BINDING_MAP[info.key]
        local btns = barButtons[info.key]
        if prefix and btns then
            for i, btn in ipairs(btns) do
                if btn then
                    local k1, k2, useClick = sig[j + 1], sig[j + 2], sig[j + 3]
                    j = j + 4
                    if useClick then
                        local btnName = btn:GetName()
                        if k1 and btnName then
                            SetOverrideBindingClick(_eabBindOwner, false, k1, btnName)
                        end
                        if k2 and btnName then
                            SetOverrideBindingClick(_eabBindOwner, false, k2, btnName)
                        end
                    else
                        local cmd = prefix .. i
                        if k1 then
                            SetOverrideBinding(_eabBindOwner, false, k1, cmd)
                        end
                        if k2 then
                            SetOverrideBinding(_eabBindOwner, false, k2, cmd)
                        end
                    end
                end
            end
        end
    end
    -- Pass 3: re-evaluate pressAndHoldAction on every button. Routing the key is only
    -- HALF of hold-and-release -- a CLICK-routed key still behaves as Press-and-Tap
    -- unless the button also carries that attr. The only writers are this re-check and
    -- _childupdate-eab-page (installed on MainBar and custom-paged bars alone).
    --
    -- Blizzard writes the attribute too and gets the last word on every
    -- loading screen: BUTTON_EVENT_LISTS.action registers
    -- PLAYER_ENTERING_WORLD per button and the mixin's PEW branch calls
    -- Update() -> UpdatePressAndHoldAction(). Zoning leaves the page state
    -- unchanged (page 1 -> page 1), so nothing re-runs our snippet and an
    -- empowered spell sits on pressAndHoldAction=false for the rest of the session.
    --
    -- Firing it HERE covers every caller at once (load time, UPDATE_BINDINGS,
    -- the combat re-arm above, the housing restore, the post-loading-screen
    -- restore). SetAttribute on a secure header is protected, but the combat
    -- bail at the top guarantees we only reach here out of combat.
    for _, info in ipairs(BAR_CONFIG) do
        local frame = barFrames[info.key]
        if frame then
            frame:SetAttribute("state-eabempower", GetTime())
        end
    end
    return true
end
_G._EAB_UpdateKeybinds = UpdateKeybinds

-- Re-assert pressAndHoldAction across all bars once combat drops. Combat is
-- the ONE window where the attribute can be rewritten without pass 3 above
-- running: the page-swap snippet fires SECURELY mid-fight (bonusbar/override
-- flips during encounters), and even with its unreadable-read guard the
-- out-of-combat truth must win afterwards -- while the signature cache
-- correctly reports "nothing changed", because the ROUTING didn't change,
-- only the attribute did. One ChildUpdate per bar per combat drop, and only
-- when a press-and-hold slot exists at all, so non-empower classes and idle
-- play pay nothing. Touches pressAndHoldAction only -- never typerelease,
-- never bindings -- so the native hold-to-cast path is untouched by
-- construction.
ns._EABReassertEmpowerAttrs = function()
    if InCombatLockdown() then return end
    if not _bindState.hasPH then return end
    for _, info in ipairs(BAR_CONFIG) do
        local frame = barFrames[info.key]
        if frame then
            frame:SetAttribute("state-eabempower", GetTime())
        end
    end
end





-- Update useOnKeyDown on all action buttons to match the CVar.
-- RegisterForClicks is always ("AnyDown", "AnyUp") so empower spells
-- receive key-down even in key-up mode. Only the attribute changes.
-- Must be called out of combat (SetAttribute on secure buttons).
local function ApplyClickRegistration()
    local keyDown = GetCVarBool("ActionButtonUseKeyDown")
    for _, info in ipairs(BAR_CONFIG) do
        if not info.isStance and not info.isPetBar then
            local btns = barButtons[info.key]
            if btns then
                for _, btn in ipairs(btns) do
                    if btn then
                        btn:SetAttribute("useOnKeyDown", keyDown)
                    end
                end
            end
        end
    end
end

-- Called when ActionButtonUseKeyDown CVar changes. Defers to out-of-combat.
local function ApplyKeyDownCVar()
    if InCombatLockdown() then
        ns.CombatQueue.Defer("ApplyKeyDownCVar", ApplyKeyDownCVar)
        return
    end
    ApplyClickRegistration()
    UpdateKeybinds()
end


-------------------------------------------------------------------------------
--  Vehicle Exit Button: reparent to UIParent so it stays visible when
--  ActionBarParent is hidden. Position and visibility are fully
--  Blizzard-owned (no unlock mode, no SetPoint hook). ActionBarController is
--  disabled above, so Blizzard's transition system won't reposition it.
-------------------------------------------------------------------------------
do
    local btn = MainMenuBarVehicleLeaveButton
    if btn then
        btn:SetParent(UIParent)
        local vehVis = ns.TakeShell()
        EUI_SafeRegisterEvent(vehVis, "UNIT_ENTERED_VEHICLE")
        EUI_SafeRegisterEvent(vehVis, "UNIT_EXITED_VEHICLE")
        vehVis:RegisterEvent("PLAYER_ENTERING_WORLD")
        vehVis:RegisterEvent("PLAYER_REGEN_ENABLED")
        vehVis:SetScript("OnEvent", function(self, event, unit)
            -- Only the UNIT_ events carry a unit; PLAYER_ENTERING_WORLD's first
            -- arg is isInitialLogin, so testing it as a unit skipped the whole
            -- pass on a fresh login.
            if (event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE")
                and unit ~= "player" then
                return
            end
            if event ~= "PLAYER_REGEN_ENABLED" then
                -- MainMenuBarVehicleLeaveButton is EditMode-managed, so SetShown
                -- routes through protected HideBase/ShowBase and is blocked in ANY
                -- combat, not only inside a live keystone. Do NOT AND this with a
                -- protected-instance check: that is false in every normal dungeon and
                -- goes false the instant a key COMPLETES (requires
                -- IsChallengeModeActive), so combat vehicle events call straight
                -- through and trip ADDON_ACTION_BLOCKED. Same rule as the micro
                -- menu/bag bar site above -- InCombatLockdown is the whole gate.
                -- Nothing lost by deferring: the protected call couldn't have
                -- succeeded in combat either way, and PLAYER_REGEN_ENABLED re-applies
                -- the state on lockdown end.
                if InCombatLockdown() then return end
            end
            local show = (CanExitVehicle and CanExitVehicle()) or false
            -- A redundant SetShown on a frame already in that state still trips
            -- the block, so only issue the protected op on a real transition.
            if btn:IsShown() ~= show then
                btn:SetShown(show)
            end
        end)
    end
end

-------------------------------------------------------------------------------
--  Hide Blizzard's Vehicle / Override Bar  (opt-in)
--
--  Bar 1 already pages to [vehicleui][possessbar] and the leave button is
--  reparented to UIParent above, so nothing is lost while hidden.
--
--  Suppression is alpha + mouse on the TOP-LEVEL bar only, never SetParent,
--  never Hide, never recursion into descendants: OverrideActionBar is a
--  protected, EditMode-managed frame (reparenting taints the transition
--  code), while SetAlpha is unprotected and combat-legal. Only mouse state
--  we disabled ourselves is ever restored.
--
--  Blizzard docks the micro menu INTO this bar, where it would inherit
--  alpha 0; it is moved out instead (ReclaimMicroMenu), not disabled in
--  place.
-------------------------------------------------------------------------------

-- Snapshot where MicroMenu lives while it is still home, so the reclaim has a
-- real anchor to restore instead of guessing one.
function EAB:CacheMicroMenuHome()
    if self._eabMicroHome then return end
    if not (MicroMenu and MicroMenu.GetPoint) then return end
    -- Never snapshot while docked: a /reload inside a vehicle or pet battle
    -- would record the DOCKED anchor as "home" in the write-once cache.
    if self:MicroMenuDockedIn(OverrideActionBar) or self:MicroMenuDockedIn(PetBattleFrame) then return end
    local p, rel, relP, x, y = MicroMenu:GetPoint(1)
    if p then
        self._eabMicroHome = { p, rel, relP, x or 0, y or 0 }
    end
end

-- Blizzard docks MicroMenu several levels deep, so a one-level parent test
-- misses it. Walk the chain.
function EAB:MicroMenuDockedIn(root)
    if not (MicroMenu and root) then return false end
    local p = MicroMenu.GetParent and MicroMenu:GetParent()
    local guard = 0
    while p and guard < 8 do
        if p == root then return true end
        p = p.GetParent and p:GetParent()
        guard = guard + 1
    end
    return false
end

-- Hand MicroMenu back to its own container: left docked it inherits alpha 0
-- and sits invisible over the vehicle exit button (or, for pet battles,
-- stays parented under PetBattleFrame and never comes back at all -- MicroMenuContainer
-- stays shown and draggable in Edit Mode, but empty), still taking clicks.
-- ResetMicroMenuPosition() is NOT the right call: it re-derives the dock from
-- current game state, which mid-vehicle/mid-battle resolves back into the
-- docked frame (no-op).
function EAB:ReclaimMicroMenu()
    if InCombatLockdown() then return end
    if not (MicroMenu and MicroMenuContainer) then return end
    self:CacheMicroMenuHome()
    if not (self:MicroMenuDockedIn(OverrideActionBar) or self:MicroMenuDockedIn(PetBattleFrame)) then return end
    MicroMenu:SetParent(MicroMenuContainer)
    local h = self._eabMicroHome
    if h then
        MicroMenu:ClearAllPoints()
        MicroMenu:SetPoint(h[1], h[2] or MicroMenuContainer, h[3], h[4], h[5])
    end
    MicroMenu:SetAlpha(1)
    ns.AB_ExtraCapsShown("MicroBar")
end

-- Blizzard docks MicroMenu into PetBattleFrame for the duration of a pet
-- battle, the same multi-level docking behavior as OverrideActionBar for
-- vehicles -- confirmed via a live capture: MicroMenu's parent chain still
-- ran through PetBattleFrame two full seconds after PET_BATTLE_CLOSE, with
-- MicroMenuContainer sitting empty (but shown/draggable) the whole time.
-- Wild battles hold combat lockdown through their own close event, so the
-- reclaim (which no-ops in combat, see above) is retried once on the next
-- PLAYER_REGEN_ENABLED, same pattern as QueuePetBattleUnsuppress uses for
-- the sibling suppression bug this branch was originally about.
do
    -- One keyed combat-queue entry (idempotent), the QueuePetBattleUnsuppress
    -- shape above.
    local function ReclaimMicroMenu()
        EAB:ReclaimMicroMenu()
    end
    local function TryReclaimAfterPetBattle()
        if InCombatLockdown() then
            ns.CombatQueue.Defer("ReclaimMicroMenu", ReclaimMicroMenu)
            return
        end
        EAB:ReclaimMicroMenu()
    end
    local petBattleReclaimFrame = CreateFrame("Frame")
    EUI_SafeRegisterEvent(petBattleReclaimFrame, "PET_BATTLE_CLOSE")
    petBattleReclaimFrame:SetScript("OnEvent", TryReclaimAfterPetBattle)
end

function EAB:ApplyVehicleBarVisibility()
    local bar = OverrideActionBar
    if not bar then return end
    local hide = self.db and self.db.profile and self.db.profile.hideBlizzardVehicleBar
    if hide then
        self:ReclaimMicroMenu()
        bar:SetAlpha(0)
        -- Guarded: the restore below may only undo OUR disable, never switch
        -- on mouse Blizzard had off for its own reasons.
        if not self._eabVehMouseOff then
            self._eabVehMouseOff = true
            SafeEnableMouse(bar, false)
        end
    else
        bar:SetAlpha(1)
        if self._eabVehMouseOff then
            self._eabVehMouseOff = nil
            SafeEnableMouse(bar, true)
        end
    end
end

-- Arm or disarm the watch. Everything is created on first enable: never
-- enabled = no event frame, no registrations, no hook. HookScript cannot be
-- undone, so the hook installs at most once and gates on the setting inside;
-- disabling unregisters the events.
function EAB:UpdateVehicleBarWatch()
    local on = self.db and self.db.profile and self.db.profile.hideBlizzardVehicleBar
    local f = self._eabVehWatch
    if not on then
        if f then f:UnregisterAllEvents() end
        self:ApplyVehicleBarVisibility()
        return
    end
    if not f then
        f = ns.TakeShell()
        f:SetScript("OnEvent", function()
            EAB:CacheMicroMenuHome()
            EAB:ApplyVehicleBarVisibility()
        end)
        self._eabVehWatch = f
    end
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- The bar's own OnShow is the deterministic edge; one deferred re-assert
    -- follows because the micro menu dock can land later in the same frame.
    if not self._eabVehShowHooked and OverrideActionBar then
        self._eabVehShowHooked = true
        OverrideActionBar:HookScript("OnShow", function()
            if not (EAB.db and EAB.db.profile
                    and EAB.db.profile.hideBlizzardVehicleBar) then return end
            EAB:ApplyVehicleBarVisibility()
            C_Timer_After(0, function() EAB:ApplyVehicleBarVisibility() end)
        end)
    end
    self:ApplyVehicleBarVisibility()
end

-------------------------------------------------------------------------------
--  Vehicle Highlight Fix: during vehicle/override paging, empty MainBar
--  buttons can retain a stale "checked" state from the normal bar.
--  CheckedTexture uses the same texture as HighlightTexture, so it looks
--  like a permanent highlight. The inverted mouseover behavior (hides on
--  enter, returns on leave) is WoW's native CheckButton behavior when checked.
--  Fix: after a page change, clear the checked state and hide CheckedTexture
--  on MainBar buttons with no action on the new page.
-------------------------------------------------------------------------------
do
    local _vehHighlightPending = false

    local function FixVehicleHighlights()
        _vehHighlightPending = false
        local mainFrame = barFrames and barFrames["MainBar"]
        if not mainFrame then return end
        local page = tonumber(mainFrame:GetAttribute("actionpage")) or 1
        local buttons = barButtons and barButtons["MainBar"]
        if not buttons then return end

        -- Only apply the alpha-0 fallback on vehicle/override/bonus pages
        -- (page > 6). On normal pages (1-6), just restore alpha to 1 so
        -- Blizzard's SetChecked/UpdateState manages checked visuals normally.
        local isSpecialPage = (page > 6)

        for i, btn in ipairs(buttons) do
            if btn then
                local ct = btn.CheckedTexture
                if isSpecialPage then
                    local slot = i + (page - 1) * NUM_ACTIONBAR_BUTTONS
                    if not HasAction(slot) then
                        -- SetChecked might be protected during combat; pcall.
                        -- Also hide CheckedTexture as a visual fallback.
                        pcall(btn.SetChecked, btn, false)
                        if ct then ct:SetAlpha(0) end
                    else
                        -- Slot has an action; restore alpha so Blizzard's
                        -- UpdateState manages checked visuals (honors the
                        -- Show Highlight on Spell Cast setting).
                        if ct then ct:SetAlpha(EAB:GetCheckedAlpha("MainBar")) end
                    end
                else
                    -- Normal page: restore alpha on all buttons so checked
                    -- state renders correctly when spells are dragged in
                    -- (honors the Show Highlight on Spell Cast setting).
                    if ct then ct:SetAlpha(EAB:GetCheckedAlpha("MainBar")) end
                end
            end
        end
    end

    local function QueueVehicleHighlightFix()
        if _vehHighlightPending then return end
        _vehHighlightPending = true
        C_Timer_After(0, FixVehicleHighlights)
    end

    local vehHighlightFrame = ns.TakeShell()
    EUI_SafeRegisterEvent(vehHighlightFrame, "UPDATE_VEHICLE_ACTIONBAR")
    EUI_SafeRegisterEvent(vehHighlightFrame, "UPDATE_OVERRIDE_ACTIONBAR")
    vehHighlightFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
    vehHighlightFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
    vehHighlightFrame:SetScript("OnEvent", QueueVehicleHighlightFix)
end


-------------------------------------------------------------------------------
--  Housing Editor Keybind Clearing: when the house editor is active, clear
--  our override bindings so Blizzard's housing hotkeys work. Restore them
--  when the editor closes.
-------------------------------------------------------------------------------
local _housingEventFrame = CreateFrame("Frame")
local IsHouseEditorActive = C_HouseEditor and C_HouseEditor.IsHouseEditorActive
if IsHouseEditorActive then
    EUI_SafeRegisterEvent(_housingEventFrame, "HOUSE_EDITOR_MODE_CHANGED")
    _housingEventFrame:SetScript("OnEvent", function()
        if IsHouseEditorActive() then
            -- House editor opened: clear ALL override bindings so housing hotkeys work
            if _bindState.housingCleared then return end
            _bindState.housingCleared = true
            if not InCombatLockdown() then
                ClearOverrideBindings(_eabBindOwner)
                -- Bindings no longer match the cached signature; force the
                -- next UpdateKeybinds to rebuild even if routing is identical.
                _bindState.sigValid = false
            end
        else
            -- House editor closed: restore our override bindings. Call
            -- unconditionally -- UpdateKeybinds defers itself in combat, and a
            -- combat guard here would drop the restore with nothing to re-arm
            -- it, leaving every override binding cleared until reload.
            if not _bindState.housingCleared then return end
            _bindState.housingCleared = false
            UpdateKeybinds()
        end
    end)
end

-------------------------------------------------------------------------------
--  Grid Show/Hide (show empty slots during spell drag)
-------------------------------------------------------------------------------

-- Reached only on a real off -> on edge: ns.EABQueueGrid settles the event
-- storm a bag sort produces (its old 0.1s throttle here could not, because
-- every HIDEGRID in the storm reset _gridState.shown and re-armed it).
local function OnGridChange()
    if InCombatLockdown() then return end
    _gridState.shown = true

    -- Propagate showgrid to the controller so the secure environment
    -- knows buttons should be visible (handles combat transitions).
    for _, info in ipairs(BAR_CONFIG) do
        if not info.isStance and not info.isPetBar then
            local buttons = barButtons[info.key]
            if buttons then
                for _, btn in ipairs(buttons) do
                    if btn then
                        SetShowGridInsecure(btn, true, SHOWGRID.GAME_EVENT)
                    end
                end
            end
        end
    end

    -- When the player starts dragging a spell, show all button slots
    -- so they can see where to drop it (even empty ones).
    -- Respect the icon cutoff so hidden overflow buttons stay hidden.
    for _, info in ipairs(BAR_CONFIG) do
        local buttons = barButtons[info.key]
        if buttons then
            local s = EAB.db.profile.bars[info.key]
            local numIcons = s and (s.overrideNumIcons or s.numIcons) or info.count
            if not numIcons or numIcons < 1 then numIcons = info.count end
            if numIcons > info.count then numIcons = info.count end
            if info.isStance then numIcons = GetNumShapeshiftForms() or info.count end
            if numIcons < 1 then numIcons = 1 end
            for i = 1, numIcons do
                local btn = buttons[i]
                if btn then
                    -- Clear statehidden so the secure UpdateShown snippet
                    -- allows the button to stay visible during drag.
                    if btn:GetAttribute("statehidden") then
                        btn:SetAttributeNoHandler("statehidden", nil)
                    end
                    local gfd = EFD(btn)
                    if gfd.slotBG then gfd.slotBG:Show() end
                    -- Show borders during drag
                    if gfd.borders and not (gfd.shapeMask and gfd.shapeMask:IsShown()) then
                        gfd.borders:Show()
                    end
                    if gfd.shapeBorder and EFD(gfd.shapeBorder).wantsShow then
                        gfd.shapeBorder:Show()
                    end
                    -- Make hidden empty buttons visible during drag. The park
                    -- verdict is taken before the Show: our own Show keeps
                    -- alpha, so it must not read as a secure reveal.
                    local parked = ns._eabParked(btn)
                    btn:Show()
                    if parked then
                        btn:SetAlpha(1)
                    end
                    gfd.parkA0 = nil
                    -- Re-enable mouse so empty slots accept drops
                    SafeEnableMouse(btn, true)
                end
            end
        end
    end

    -- Mouseover bar forcing moved to CURSOR_CHANGED handler, which only
    -- fires for real cursor drags. ACTIONBAR_SHOWGRID also fires for
    -- equipment changes, bag sorts, etc. which should not affect mouseover.
end

-- Show All During Drag: restore bars saved as Never that were surfaced for a
-- cursor drag (CURSOR_CHANGED handler). Idempotent, safe from every drag-end
-- path. Clears only the overrides the drag itself planted, so a
-- toggle-keybind override the user set stays intact. If the drag ends in
-- combat the driver swap is deferred: RefreshRuntimeVisibility skips secure
-- writes there, and PLAYER_REGEN_ENABLED's ApplyAll re-runs it clean.
function EAB._RestoreDragNeverBars()
    local forced = _gridState._dragNeverForced
    if not forced then return end
    _gridState._dragNeverForced = nil
    if EAB._visOverride then
        for key in pairs(forced) do
            if EAB._visOverride[key] == "always" then
                EAB._visOverride[key] = nil
            end
        end
    end
    EAB:RefreshRuntimeVisibility()
    -- A bar opted into BOTH drag and spellbook surfacing skips the spellbook
    -- plant while the drag override holds it; re-evaluate so it stays up when
    -- the drag ends with the spellbook still open.
    if EAB._UpdateSpellbookNeverBars then EAB._UpdateSpellbookNeverBars() end
end

-- Show When Spellbook Is Open (per-bar opt-in, s.spellbookShow, ANY
-- visibility mode): while the spellbook (PlayerSpellsFrame) or macro panel
-- (MacroFrame) is open, opted-in bars force-show the same way a cursor drag
-- surfaces them by default:
--   * non-always modes (Never, conditional drivers) plant the runtime
--     _visOverride slot (never persisted) -- own forced-set so the drag
--     trigger and this one restore independently; same combat guard
--     (secure driver swaps are combat-blocked; a panel opened mid-combat
--     surfaces at the regen re-check).
--   * mouseover bars force alpha 1 (StopFade), re-asserted on every call
--     because a drag's grid-hide fade can land while the panel stays open;
--     released to the normal fade-out on close unless hovered.
-- resync = drop everything planted first and re-evaluate (options toggle
-- flips while the panel is already open).
function EAB._UpdateSpellbookNeverBars(resync)
    local open = (PlayerSpellsFrame and PlayerSpellsFrame:IsShown())
        or (MacroFrame and MacroFrame:IsShown())
    if resync == true or not open then
        local forced = _gridState._sbNeverForced
        if forced then
            _gridState._sbNeverForced = nil
            if EAB._visOverride then
                for key in pairs(forced) do
                    if EAB._visOverride[key] == "always" then
                        EAB._visOverride[key] = nil
                    end
                end
            end
            EAB:RefreshRuntimeVisibility()
        end
        local mo = _gridState._sbMoForced
        if mo then
            _gridState._sbMoForced = nil
            for key in pairs(mo) do
                local s = EAB.db.profile.bars[key]
                local state = hoverStates[key]
                if s and s.mouseoverEnabled and state and not state.isHovered then
                    EAB_VTABLE.Hover.FadeOut(key, state)
                end
            end
        end
        if not open then return end
    end
    if not InCombatLockdown() and not _gridState._sbNeverForced then
        local forced
        for _, info in ipairs(BAR_CONFIG) do
            local s = EAB.db.profile.bars[info.key]
            if s and s.spellbookShow and s.enabled ~= false
               and ((s.barVisibility or "always") ~= "always" or s.alwaysHidden
                    or (EAB._padHide and s.gamepadHideBar == true))
               and not (EAB._visOverride and EAB._visOverride[info.key]) then
                EAB._visOverride = EAB._visOverride or {}
                EAB._visOverride[info.key] = "always"
                forced = forced or {}
                forced[info.key] = true
            end
        end
        if forced then
            _gridState._sbNeverForced = forced
            EAB:RefreshRuntimeVisibility()
        end
    end
    local mo
    for _, info in ipairs(BAR_CONFIG) do
        local s = EAB.db.profile.bars[info.key]
        if s and s.spellbookShow and s.enabled ~= false and s.mouseoverEnabled then
            local frame = barFrames[info.key]
            if frame then
                -- Through the hover system's OWN fade-in, never a raw
                -- SetAlpha: FadeInOne targets the bar's true shown alpha
                -- (_savedBarAlpha) and keeps state.fadeDir truthful --
                -- a raw SetAlpha leaves the resting "out" memo in place,
                -- so the close-path FadeOut treats the bar as already
                -- faded and skips it (bar stuck visible until a hover).
                EAB_VTABLE.Hover.FadeInOne(info.key,
                    EAB_VTABLE.Hover.GetState(info.key, frame))
                mo = mo or {}
                mo[info.key] = true
            end
        end
    end
    _gridState._sbMoForced = mo
end

-- Trigger wiring: OnShow/OnHide HookScripts on the two panels (both are
-- LoadOnDemand -- ADDON_LOADED installs late hooks, unregistering once both
-- are in). PLAYER_REGEN_ENABLED re-evaluates panels opened or closed during
-- combat; the handler is one IsShown probe when nothing is planted.
do
    local hooked = {}
    local function OnPanelToggle()
        EAB._UpdateSpellbookNeverBars()
    end
    local function TryHook(name)
        if hooked[name] then return true end
        local f = _G[name]
        if not f then return false end
        hooked[name] = true
        f:HookScript("OnShow", OnPanelToggle)
        f:HookScript("OnHide", OnPanelToggle)
        return true
    end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("ADDON_LOADED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function(self, event, addon)
        if event == "ADDON_LOADED" then
            if addon == "Blizzard_PlayerSpells" then TryHook("PlayerSpellsFrame")
            elseif addon == "Blizzard_MacroUI" then TryHook("MacroFrame") end
            if hooked.PlayerSpellsFrame and hooked.MacroFrame then
                self:UnregisterEvent("ADDON_LOADED")
            end
        else
            EAB._UpdateSpellbookNeverBars()
        end
    end)
    TryHook("PlayerSpellsFrame")
    TryHook("MacroFrame")
end

-------------------------------------------------------------------------------
--  Apply All orchestrates full visual application
-------------------------------------------------------------------------------
local function ApplyAll()
    _isApplyingAll = true
    -- Full applies can create/enable bars and reassign slots without any
    -- dispatcher content event: retire the filled-slot fast lists, and the
    -- curated memo with them (profile swaps can land mid-session).
    ns._cdFilledDirty = true
    ns._cdCuratedDirty = true

    -- Restore any strata raised during a drag that wasn't cleaned up
    if _dragState.visible then
        _dragState.visible = false
        for frame, orig in pairs(_dragState.strataCache) do
            frame:SetFrameStrata(orig)
        end
        wipe(_dragState.strataCache)
    end

    local inCombat = InCombatLockdown()

    if not inCombat then
        EAB_VTABLE.MainBarPageSync.InstallAll()
    end

    for _, info in ipairs(BAR_CONFIG) do
        local key = info.key
        local s = EAB.db.profile.bars[key]
        local frame = barFrames[key]

        -- Bar enabled/disabled toggle (protected frames can't be shown/hidden in combat)
        if frame and s and not inCombat then
            if s.enabled == false then
                frame:Hide()
            elseif not s.alwaysHidden then
                -- Skip Show if a state-visibility driver is managing this frame
                -- (the driver handles show/hide; calling Show() causes a one-frame blink)
                if not frame._eabLastVisStr then
                    frame:Show()
                end
            end
        end

        if not inCombat then
            LayoutBar(key)
        end
        if not inCombat then EAB:ApplyBordersForBar(key) end
        if not inCombat then EAB:ApplyShapesForBar(key) end
        EAB:ApplyFontsForBar(key)
        EAB:ApplyBackgroundForBar(key)
        EAB:ApplyIconBackgroundForBar(key)
        if not inCombat then EAB:ApplyAlwaysShowButtons(key) end
        if not inCombat then EAB:ApplyClickThroughForBar(key) end
    end
    -- The micro menu's and bag bar's caps (a profile or spec switch changes
    -- their keys without bar 1's layout stamp moving).
    ns.AB_ExtraCapsAll()

    EAB:ApplyPushedTextures()
    EAB:HookPushedFlash()
    EAB:ApplyHighlightTextures()
    EAB:ApplyCooldownFonts()
    EAB:ApplyCooldownSwipeColor()
    EAB:ApplySlotBackgroundColor()
    -- Gated so it's zero-touch at the default (100); the live handler + setValue
    -- own the rest.
    if EAB.db and EAB.db.profile and EAB.db.profile.alphaWhenOnCD ~= 100 then
        EAB:ApplyCDAlphaAll()
    end
    EAB:ApplyCooldownEdge()
    EAB:ApplyMiscTextures()
    EAB:ApplyCheckedTextures()
    if not inCombat then EAB:ApplyCombatVisibility() end
    if not inCombat then EAB:RefreshRuntimeVisibility() end
    EAB:RefreshMouseover()
    EAB:RefreshProcGlows()
    EAB:ApplyRangeColoring()

    -- A full apply that ran DURING combat skipped every `not inCombat` step
    -- above; the REGEN_ENABLED re-run (gated on this flag) converges them.
    if inCombat then ns._eabApplyDeferred = true end

    -- Dormancy re-sync: a profile swap or options change can re-register
    -- visibility drivers without firing the per-bar OnShow/OnHide edges the
    -- dormancy map saw. Per-key memoized, so unchanged bars cost one table read.
    for _, info in ipairs(BAR_CONFIG) do
        local f = barFrames[info.key]
        if f then ns.ApplyBarDormancy(info.key, not f:IsVisible()) end
    end

    -- Party Mode orbit: claims the buttons this rebuild built or showed (Party
    -- Mode may have started -- login, keybind, Bloodlust -- before they
    -- existed); a button the rebuild re-anchored re-measures its rest through
    -- the engine's SetPoint hook.
    ns.PartySpin_Refresh()

    _isApplyingAll = false
end

-- Handle for the lazy bar build in RefreshRuntimeVisibility, which sits above
-- this definition and cannot see the local. On ns and not on EAB deliberately:
-- the EUI_UnlockMode hook watches EAB.ApplyAll, and putting it there would
-- start firing that hook for the first time.
ns._eabApplyAll = ApplyAll

-------------------------------------------------------------------------------
--  Position Save/Restore
-------------------------------------------------------------------------------
-- Convert CENTER position to edge for non-CENTER-grow bars (same pattern as CDM).
-- Stored on EAB to avoid consuming local slots (200-local Lua 5.1 cap).
function EAB:ConvertCenterToEdge(barKey, point, x, y)
    if point ~= "CENTER" then return point, x, y end
    local cfg = self.db and self.db.profile and self.db.profile.bars and self.db.profile.bars[barKey]
    local grow = cfg and cfg.growDirection
    if not grow then return point, x, y end
    grow = grow:upper()
    if grow == "CENTER" then return point, x, y end
    local frame = barFrames[barKey]
    if not frame then return point, x, y end
    local fw = frame:GetWidth() or 0
    local fh = frame:GetHeight() or 0
    if grow == "RIGHT" and fw > 0 then return "LEFT", x - fw / 2, y
    elseif grow == "LEFT" and fw > 0 then return "RIGHT", x + fw / 2, y
    elseif grow == "DOWN" and fh > 0 then return "TOP", x, y + fh / 2
    elseif grow == "UP" and fh > 0 then return "BOTTOM", x, y - fh / 2
    end
    return point, x, y
end

function EAB:ConvertEdgeToCenter(barKey, pos)
    if not pos or not pos.point then return pos end
    local pt = pos.point
    if pt == "CENTER" then return pos end
    if pt ~= "LEFT" and pt ~= "RIGHT" and pt ~= "TOP" and pt ~= "BOTTOM" then return pos end
    local frame = barFrames[barKey]
    if not frame then return pos end
    local fw = frame:GetWidth() or 0
    local fh = frame:GetHeight() or 0
    local cx, cy = pos.x or 0, pos.y or 0
    if pt == "LEFT" then cx = cx + fw / 2
    elseif pt == "RIGHT" then cx = cx - fw / 2
    elseif pt == "TOP" then cy = cy - fh / 2
    elseif pt == "BOTTOM" then cy = cy + fh / 2
    end
    return { point = "CENTER", relPoint = pos.relPoint, x = cx, y = cy }
end

local function SaveBarPosition(barKey)
    local frame = barFrames[barKey]
    if not frame then return end
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if point then
        -- Pixel-perfect snapping can leave sub-pixel offsets (0.5) on
        -- CENTER-anchored bars, and re-snapping on restore drifts 1px at some
        -- UI scales. Clamp near-zero CENTER offsets to exactly 0 so the
        -- restore-skip at RestoreBarPositions fires correctly.
        if point == "CENTER" and relPoint == "CENTER" then
            local es = frame:GetEffectiveScale() or 1
            local PPa = EllesmereUI and EllesmereUI.PP
            local onePx = PPa and PPa.perfect and (PPa.perfect / es) or 1
            if math.abs(x) < onePx then x = 0 end
            if math.abs(y) < onePx then y = 0 end
        end
        EAB.db.profile.barPositions[barKey] = {
            point = point, relPoint = relPoint, x = x, y = y,
        }
    end
end

local function RestoreBarPositions()
    local positions = EAB.db.profile.barPositions
    if not positions then return end
    local PPa = EllesmereUI and EllesmereUI.PP
    for _, info in ipairs(BAR_CONFIG) do
        local key = info.key
        local pos = positions[key]
        local frame = barFrames[key]
        if pos and frame then
            -- Skip bars owned by the unlock anchor system: position is computed
            -- from the anchor chain, not saved barPositions.
            local anchored = EllesmereUI and EllesmereUI.IsUnlockAnchored
                             and EllesmereUI.IsUnlockAnchored(key)
            if anchored then
                -- skip: anchor system owns this bar's position
            else
            local pt = pos.point or "CENTER"
            local rpt = pos.relPoint or pt
            local px = pos.x or 0
            local py = pos.y or 0
            -- Skip CENTER 0,0: this is never an intentional position.
            -- Anchored bars save 0,0 as a placeholder; their real position
            -- comes from the anchor chain which resolves later.
            if pt == "CENTER" and rpt == "CENTER" and px == 0 and py == 0 then
                -- skip
            else
                -- Snap to physical pixel grid. For CENTER-anchored bars use
                -- SnapCenterForDim with the frame's actual size so odd-pixel
                -- dimensions get the +0.5 center offset they need (plain
                -- SnapForES drifts by 1px on save & exit for odd dimensions).
                if PPa then
                    local es = frame:GetEffectiveScale()
                    local isCenterAnchor = (pt == "CENTER" and rpt == "CENTER")
                    if isCenterAnchor and PPa.SnapCenterForDim then
                        px = PPa.SnapCenterForDim(px, frame:GetWidth() or 0, es)
                        py = PPa.SnapCenterForDim(py, frame:GetHeight() or 0, es)
                    elseif PPa.SnapForES then
                        px = PPa.SnapForES(px, es)
                        py = PPa.SnapForES(py, es)
                    end
                end
                frame:ClearAllPoints()
                frame:SetPoint(pt, UIParent, rpt, px, py)
            end
            end -- anchored else
        end
    end
    -- Note: anchored bars are handled later in RegisterWithUnlockMode
    -- (0.5s deferred) via ReapplyOwnAnchor, after elements are registered.
end



-------------------------------------------------------------------------------
--  Unlock Mode Integration
--  Register bars with EUI_UnlockMode for positioning.
-------------------------------------------------------------------------------
local function RegisterWithUnlockMode()
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements then return end
    local MK = EllesmereUI.MakeUnlockElement

    local elements = {}
    local orderBase = 200

    for idx, info in ipairs(BAR_CONFIG) do
        local key = info.key
        elements[#elements + 1] = MK({
            key   = key,
            label = info.label,
            group = "Action Bars",
            order = orderBase + idx,
            isHidden = function()
                local s = EAB.db.profile.bars[info.key]
                if not s then return false end
                -- Honor the runtime "Toggle Action Bar" override the same way
                -- RefreshRuntimeVisibility does: a bar saved as Never but
                -- surfaced by the keybind is on screen, so it needs a mover;
                -- a saved-Always bar toggled off does not.
                local ov = EAB._visOverride and EAB._visOverride[info.key]
                if ov then return ov == "never" end
                return s.alwaysHidden or (EAB._padHide and s.gamepadHideBar == true)
            end,
            getFrame = function() return barFrames[info.key] end,
            getSize = function()
                local frame = barFrames[info.key]
                if not frame then return 1, 1 end
                return frame:GetWidth(), frame:GetHeight()
            end,
            linkedDimensions = true,
            -- Size matching works in every style: stock styles size their buttons
            -- from Icon Size too (LayoutBar scales the native-size button to it),
            -- and the math below uses the same layout shape as LayoutBar.
            -- A textured square border's reach past the bar's edges, so size
            -- matching lines up with what is on screen. The outer buttons sit
            -- flush on the bar frame's edges (LayoutBar: no outer inset), so
            -- the per-button reach is the bar's. Same arguments ApplyBordersForBar
            -- paints with; nil for custom shapes (their ring sits inside the
            -- button), stock looks and non-square icons.
            getMatchPad = function()
                local p = EAB.db and EAB.db.profile
                if not (p and p.squareIcons) or ns.AB_Style() ~= "eui" then return nil end
                local s = p.bars[info.key]
                if not s then return nil end
                local shape = s.buttonShape or "none"
                if shape ~= "none" and shape ~= "cropped" then return nil end
                local sz, px = ns.ResolveBorderThickness(s)
                local c = s.borderColor
                return EllesmereUI.BorderMatchPad(sz, s.borderTexture or "solid",
                    s.borderTextureOffset, s.borderTextureOffsetY, s.borderTextureShiftX, s.borderTextureShiftY,
                    "actionbars", s.borderThickness or "thin", px, nil, c and c.a or 1)
            end,
            setWidth = function(_, w)
                local s = EAB.db.profile.bars[info.key]
                if not s then return end
                -- Reverse-engineer square button size from total bar width
                -- using physical pixel math to distribute remainder pixels.
                local numIcons = s.overrideNumIcons or s.numIcons or info.count
                local numRows  = s.overrideNumRows  or s.numRows  or 1
                if numRows < 1 then numRows = 1 end
                local stride   = math.ceil(numIcons / numRows)
                if stride < 1 then stride = 1 end
                local isVert   = (s.orientation == "vertical")
                local pad      = s.buttonPadding or 2
                local shape    = ns.AB_LayoutShape(s)
                local cols     = isVert and numRows or stride
                local PP = EllesmereUI and EllesmereUI.PP
                local onePx = PP and PP.mult or 1
                local physTarget = math.floor(w / onePx + 0.5)
                local physPad = math.floor(pad / onePx + 0.5)
                local rawPhysBtn = (physTarget - (cols - 1) * physPad) / cols
                if shape ~= "none" and shape ~= "cropped" then
                    rawPhysBtn = rawPhysBtn - math.floor((SHAPE_BTN_EXPAND or 10) / onePx + 0.5)
                end
                if rawPhysBtn < 8 then rawPhysBtn = 8 end
                local basePhysBtn = math.floor(rawPhysBtn)
                s.buttonWidth  = basePhysBtn * onePx
                s.buttonHeight = s.buttonWidth
                -- Compute remainder pixels to distribute across columns
                local shapePhys = 0
                if shape ~= "none" and shape ~= "cropped" then
                    shapePhys = math.floor((SHAPE_BTN_EXPAND or 10) / onePx + 0.5)
                end
                local idealPhys = cols * (basePhysBtn + shapePhys) + (cols - 1) * physPad
                local extra = physTarget - idealPhys
                if extra > 0 and extra <= cols then
                    s._matchExtraPixels = extra
                else
                    s._matchExtraPixels = nil
                end
                LayoutBar(info.key)
            end,
            setHeight = function(_, h)
                local s = EAB.db.profile.bars[info.key]
                if not s then return end
                -- Reverse-engineer square button size from total bar height
                -- using physical pixel math to distribute remainder pixels.
                local numIcons = s.overrideNumIcons or s.numIcons or info.count
                local numRows  = s.overrideNumRows  or s.numRows  or 1
                if numRows < 1 then numRows = 1 end
                local stride   = math.ceil(numIcons / numRows)
                if stride < 1 then stride = 1 end
                local isVert   = (s.orientation == "vertical")
                local pad      = s.buttonPadding or 2
                local shape    = ns.AB_LayoutShape(s)
                local rows     = isVert and stride or numRows
                local PP = EllesmereUI and EllesmereUI.PP
                local onePx = PP and PP.mult or 1
                local physTarget = math.floor(h / onePx + 0.5)
                local physPad = math.floor(pad / onePx + 0.5)
                local rawPhysBtn = (physTarget - (rows - 1) * physPad) / rows
                if shape ~= "none" and shape ~= "cropped" then
                    rawPhysBtn = rawPhysBtn - math.floor((SHAPE_BTN_EXPAND or 10) / onePx + 0.5)
                elseif shape == "cropped" then
                    rawPhysBtn = rawPhysBtn / 0.80
                end
                if rawPhysBtn < 8 then rawPhysBtn = 8 end
                local basePhysBtn = math.floor(rawPhysBtn)
                s.buttonWidth  = basePhysBtn * onePx
                s.buttonHeight = s.buttonWidth
                -- Compute remainder pixels to distribute across rows
                local shapePhys = 0
                if shape ~= "none" and shape ~= "cropped" then
                    shapePhys = math.floor((SHAPE_BTN_EXPAND or 10) / onePx + 0.5)
                end
                local croppedH = basePhysBtn + shapePhys
                if shape == "cropped" then
                    croppedH = math.floor(basePhysBtn * 0.80)
                end
                local idealPhys = rows * croppedH + (rows - 1) * physPad
                local extra = physTarget - idealPhys
                if extra > 0 and extra <= rows then
                    s._matchExtraPixelsH = extra
                else
                    s._matchExtraPixelsH = nil
                end
                LayoutBar(info.key)
            end,
            savePos = function(_, point, relPoint, x, y)
                if point and x and y then
                    local sp, sx, sy = EAB:ConvertCenterToEdge(info.key, point, x, y)
                    EAB.db.profile.barPositions[info.key] = {
                        point = sp, relPoint = relPoint or point, x = sx, y = sy,
                    }
                else
                    SaveBarPosition(info.key)
                end
                -- Follow baseline: capture the anchor target's geometry at save time so
                -- ApplyAnchorPosition can shift the absolute saved growth edge by the
                -- target's displacement when it moves/resizes at runtime. Applies to
                -- every growth-direction bar so a perpendicular corner anchor to a
                -- resizing chain target can follow; nil for unanchored/CENTER-grow
                -- bars, leaving the follow off and the pure pin unchanged.
                do
                    local entry = EAB.db.profile.barPositions[info.key]
                    local s = EAB.db.profile.bars[info.key]
                    local gd = s and (s.growDirection or "up"):upper()
                    if entry and gd and gd ~= "CENTER"
                       and EllesmereUI.GetAnchorTargetCenterUI then
                        entry.tgtx, entry.tgty = EllesmereUI.GetAnchorTargetCenterUI(info.key)
                        if EllesmereUI.GetAnchorTargetEdgesUI then
                            entry.tgtL, entry.tgtR, entry.tgtT, entry.tgtB =
                                EllesmereUI.GetAnchorTargetEdgesUI(info.key)
                        end
                    end
                end
            end,
            loadPos = function()
                return EAB:ConvertEdgeToCenter(info.key, EAB.db.profile.barPositions[info.key])
            end,
            clearPos = function()
                EAB.db.profile.barPositions[info.key] = nil
            end,
            applyPos = function()
                EAB:RecalcFlyoutDirection(info.key)
                -- Anchored bars: position owned by anchor system. But bars
                -- with growth direction need edge bounds applied first so the
                -- live-edge reading in ApplyAnchorPosition has correct data.
                if EllesmereUI and EllesmereUI.IsUnlockAnchored
                   and EllesmereUI.IsUnlockAnchored(info.key) then
                    local s = EAB.db.profile.bars[info.key]
                    local gd = s and (s.growDirection or "up"):upper()
                    if gd and gd ~= "CENTER" and gd ~= "UP" then
                        local pos = EAB.db.profile.barPositions[info.key]
                        local frame = barFrames[info.key]
                        if pos and frame then
                            local pt = pos.point or "CENTER"
                            local px, py = pos.x or 0, pos.y or 0
                            -- Convert CENTER to edge (like CDM's ApplyBarPositionCentered)
                            if pt == "CENTER" then
                                local fw = frame:GetWidth() or 0
                                local fh = frame:GetHeight() or 0
                                if gd == "RIGHT" and fw > 0 then
                                    pt = "LEFT"; px = px - fw / 2
                                elseif gd == "LEFT" and fw > 0 then
                                    pt = "RIGHT"; px = px + fw / 2
                                elseif gd == "DOWN" and fh > 0 then
                                    pt = "TOP"; py = py + fh / 2
                                end
                            end
                            if pt ~= "CENTER" then
                                local PPa = EllesmereUI and EllesmereUI.PP
                                if PPa and PPa.SnapForES then
                                    local es = frame:GetEffectiveScale()
                                    px = PPa.SnapForES(px, es)
                                    py = PPa.SnapForES(py, es)
                                end
                                frame:ClearAllPoints()
                                frame:SetPoint(pt, UIParent, pos.relPoint or "CENTER", px, py)
                            end
                        end
                    end
                    return
                end
                local pos = EAB.db.profile.barPositions[info.key]
                local frame = barFrames[info.key]
                if pos and frame then
                    local pt = pos.point
                    local px, py = pos.x, pos.y
                    local PPa = EllesmereUI and EllesmereUI.PP
                    if PPa and px and py then
                        local es = frame:GetEffectiveScale()
                        local isCenterAnchor = (pt == "CENTER")
                            and (pos.relPoint == "CENTER" or pos.relPoint == nil)
                        if isCenterAnchor and PPa.SnapCenterForDim then
                            px = PPa.SnapCenterForDim(px, frame:GetWidth() or 0, es)
                            py = PPa.SnapCenterForDim(py, frame:GetHeight() or 0, es)
                        elseif PPa.SnapForES then
                            px = PPa.SnapForES(px, es)
                            py = PPa.SnapForES(py, es)
                        end
                    end
                    frame:ClearAllPoints()
                    frame:SetPoint(pt, UIParent, pos.relPoint or pt, px, py)
                end
            end,
        })
    end

    -- Blizzard movable frames (Extra Action Button, Encounter Bar)
    local blizzOrder = orderBase + #BAR_CONFIG
    for _, info in ipairs(EXTRA_BARS) do
        if info.isBlizzardMovable then
            blizzOrder = blizzOrder + 1
            local bk = info.key
            elements[#elements + 1] = MK({
                key   = bk,
                label = info.label,
                group = "Action Bars",
                order = blizzOrder,
                noResize = true,
                getFrame = function() return blizzMovableHolders[bk] end,
                getSize = function()
                    local ov = BLIZZ_MOVABLE_OVERLAY[bk]
                    if ov then return ov.w, ov.h end
                    return 50, 50
                end,
                savePos = function(_, point, relPoint, x, y)
                    if point and x and y then
                        EAB.db.profile.barPositions[bk] = {
                            point = point, relPoint = relPoint or point, x = x, y = y,
                        }
                    end
                    if not EllesmereUI._unlockActive then
                        local holder = blizzMovableHolders[bk]
                        if holder and point and x and y and not InCombatLockdown() then
                            holder:ClearAllPoints()
                            holder:SetPoint(point, UIParent, relPoint or point, x, y)
                        end
                    end
                end,
                loadPos = function()
                    local pos = EAB.db.profile.barPositions[bk]
                    if not pos then return nil end
                    local pt = pos.point
                    return { point = pt, relPoint = pos.relPoint or pt, x = pos.x, y = pos.y }
                end,
                clearPos = function()
                    EAB.db.profile.barPositions[bk] = nil
                end,
                applyPos = function()
                    local pos = EAB.db.profile.barPositions[bk]
                    local holder = blizzMovableHolders[bk]
                    if not holder or InCombatLockdown() then return end
                    holder:ClearAllPoints()
                    if pos then
                        local pt = pos.point
                        local px, py = pos.x, pos.y
                        local PPa = EllesmereUI and EllesmereUI.PP
                        if PPa and px and py then
                            local es = holder:GetEffectiveScale()
                            local isCenterAnchor = (pt == "CENTER")
                                and (pos.relPoint == "CENTER" or pos.relPoint == nil)
                            if isCenterAnchor and PPa.SnapCenterForDim then
                                px = PPa.SnapCenterForDim(px, holder:GetWidth() or 0, es)
                                py = PPa.SnapCenterForDim(py, holder:GetHeight() or 0, es)
                            elseif PPa.SnapForES then
                                px = PPa.SnapForES(px, es)
                                py = PPa.SnapForES(py, es)
                            end
                        end
                        holder:SetPoint(pt, UIParent, pos.relPoint or pt, px, py)
                    else
                        holder:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
                    end
                end,
            })
        end
    end


    EllesmereUI:RegisterUnlockElements(elements, "EllesmereUIActionBars")

    -- Reapply anchors now that elements are registered: RestoreBarPositions
    -- ran before registration (too early for ReapplyOwnAnchor to resolve
    -- frames), so anchored bars sit unresolved. Skip growth-direction bars:
    -- applyPos already pre-positioned them at the edge and the authoritative
    -- pass preserves that via live-edge reading.
    if EllesmereUI.ReapplyOwnAnchor then
        for _, info in ipairs(BAR_CONFIG) do
            if EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(info.key) then
                local s = EAB.db.profile.bars[info.key]
                local gd = s and (s.growDirection or "up"):upper()
                if not gd or gd == "CENTER" or gd == "UP" then
                    EllesmereUI.ReapplyOwnAnchor(info.key)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Initialization
-------------------------------------------------------------------------------
function EAB:OnInitialize()
    -- Detect first install BEFORE AceDB creates the saved variable.
    -- We use a dedicated flag so "Reset to Defaults" also re-captures.
    local rawDB = EllesmereUIActionBarsDB
    local isFirstInstall = not rawDB or not rawDB.profiles
        or (rawDB.profiles and not next(rawDB.profiles))

    self.db = EllesmereUI.Lite.NewDB("EllesmereUIActionBarsDB", defaults, true)
    -- Expose for ApplyAnchorPosition's growth-direction edge read.
    EllesmereUI._abBarPositions = self.db.profile.barPositions

    -- Slot-export safety net: a session that ended with that addon's window
    -- open (e.g. /reload) left the real bar visibility settings swapped to
    -- "always". Restore before any bar is built so the swap can never
    -- persist. Unconditional (see EAB:SetMyslotForceShow).
    self:RestoreMyslotBackup()

    -- Mark whether we need to capture Blizzard layout on first install; the capture
    -- itself is deferred to PLAYER_ENTERING_WORLD, when Edit Mode has fully applied bar
    -- positions/sizes. Per-install flag on the SV root, not per-profile.
    local sv = self.db.sv
    self._needsCapture = not sv._capturedOnce_EAB

    -- Expose apply hook for PP scale change re-apply
    _G._EAB_RecalcFlyouts = function()
        for _, info in ipairs(BAR_CONFIG) do
            EAB:RecalcFlyoutDirection(info.key)
        end
    end

    -- MicroBar position is fully Blizzard-owned (Edit Mode). No anchor
    -- flipping needed. Stubs kept so callers don't error.
    _G._EAB_UnlockModeOpen = function() end
    _G._EAB_UnlockModeClose = function() end

    _G._EAB_ApplyKeyDown = function() ApplyKeyDownCVar() end
    _G._EAB_Apply = function()
        -- Re-point the exposed barPositions view at the active profile's table.
        -- Profile swaps replace db.profile wholesale and the unlock system reads
        -- saved growth edges / follow baselines through this reference; a stale
        -- pointer would read and write another profile's saved positions.
        if EAB.db and EAB.db.profile and EAB.db.profile.barPositions then
            EllesmereUI._abBarPositions = EAB.db.profile.barPositions
        end
        ApplyAll()
        -- Data bars: ApplyAll never lays them out, so a profile swap, an import
        -- or a spec override repaints their size, texture, text and Custom
        -- Border here (our own plain frames: safe in combat). Not in ApplyAll,
        -- which also runs at login, where creation already laid them out.
        for _, info in ipairs(ns.EXTRA_BARS) do
            if info.isDataBar then ns.ApplyDataBarLayout(info.key) end
        end
        if not InCombatLockdown() then
            RestoreBarPositions()
            -- Recalculate flyout directions now that bars are at their final
            -- positions: LayoutBar (inside ApplyAll) runs before
            -- RestoreBarPositions, so it used the default position.
            C_Timer_After(0, function()
                for _, info in ipairs(BAR_CONFIG) do
                    EAB:RecalcFlyoutDirection(info.key)
                end
            end)
        end
    end


    -- Rank (crafted quality) icons: EAB paints its own overlay per button. Blizzard's
    -- ProfessionQualityOverlayFrame is created lazily inside the secure button Update
    -- and our buttons no longer receive ACTIONBAR_SLOT_CHANGED (central dispatcher owns
    -- it), so it only ever appeared after a mouseover -- and forcing
    -- UpdateProfessionQuality() from addon code writes the lazily-created frame onto
    -- the secure button's table (tainted field on a protected frame). Self-painting
    -- from EFD avoids both: no button-table writes, no reliance on Blizzard's update
    -- timing. Their overlay stays hidden everywhere (apply pass + scan +
    -- OnShow hook) so the two renderers never double-draw. Coalesced:
    -- SLOT_CHANGED storms collapse into one deferred scan per frame.
    do
        local qf = ns.TakeShell()
        local _qPending = false
        local _rankAtlas = {}       -- quality -> atlas name (false = none found)
        local QueueQualityScan

        local function RankAtlasFor(q)
            local hit = _rankAtlas[q]
            if hit ~= nil then return hit or nil end
            local probe = C_Texture and C_Texture.GetAtlasInfo
            local names = {
                "Professions-Icon-Quality-Tier" .. q .. "-Inv-Small",
                "Professions-Icon-Quality-Tier" .. q .. "-Small",
                "Professions-Icon-Quality-Tier" .. q,
            }
            for i = 1, #names do
                if probe and probe(names[i]) then
                    _rankAtlas[q] = names[i]
                    return names[i]
                end
            end
            _rankAtlas[q] = false
            return nil
        end

        local function SetRankShown(btn, atlas)
            local fd = EFD(btn)
            if not atlas then
                if fd.rankIconTex then fd.rankIconTex:Hide() end
                return
            end
            local tex = fd.rankIconTex
            if not tex then
                -- First paint creates the holder. A new cosmetic child frame
                -- writes nothing onto the secure button's table; skip only
                -- in combat lockdown (next out-of-combat scan paints it).
                if InCombatLockdown() then return end
                local holder = CreateFrame("Frame", nil, btn)
                holder:SetAllPoints(btn)
                holder:SetFrameLevel((btn:GetFrameLevel() or 1) + 18)
                holder:EnableMouse(false)
                tex = holder:CreateTexture(nil, "OVERLAY", nil, 7)
                fd.rankIconHolder = holder
                fd.rankIconTex = tex
            end
            if fd.rankIconAtlas ~= atlas then
                fd.rankIconAtlas = atlas
                -- The atlas name comes straight from Blizzard's quality info
                -- (or the probe-verified fallback), but guard anyway: an
                -- unknown atlas must read as no-rank, not an error.
                if not pcall(tex.SetAtlas, tex, atlas, true) then
                    fd.rankIconAtlas = nil
                    tex:Hide()
                    return
                end
                if EllesmereUI._RANKDEBUG then
                    print("|cff33ff99[Rank]|r atlas", atlas)
                end
            end
            -- Mirror Blizzard's overlay anchor: its template centers an
            -- atlas-sized texture 14,-14 from the button's TOPLEFT (designed for
            -- the default 45px button, so scale with the button).
            local sc = (btn:GetWidth() or 45) / 45
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", btn, "TOPLEFT", 14 * sc, -14 * sc)
            tex:SetScale(sc)
            tex:Show()
            fd.rankIconHolder:Show()
        end

        local function QualityScan()
            _qPending = false
            local bars = EAB.db and EAB.db.profile and EAB.db.profile.bars
            if not bars then return end
            for _, info in ipairs(BAR_CONFIG) do
                local btns = barButtons[info.key]
                local s = bars[info.key]
                if btns and s then
                    local featureOn = s.showRankIcon and true or false
                    for _, btn in ipairs(btns) do
                        local rankAtlas
                        if featureOn then
                            local action = btn:GetAttribute("action") or 0
                            if action > 0 then
                                -- Blizzard's own source, from live ActionButton.lua
                                -- UpdateProfessionQuality: a dedicated action API that
                                -- returns the overlay atlas directly. Every other
                                -- surface is dead from an action slot on live
                                -- (verified via in-game debug 2026-07-19):
                                -- C_TradeSkillUI reads off the bare itemID are nil (the
                                -- reagent one returns a flat 2 for every ranked item),
                                -- GetActionLink returns nil, and the tooltip's name
                                -- line carries no quality markup.
                                local ab = C_ActionBar
                                if ab and ab.GetProfessionQualityInfo
                                   and (not ab.IsItemAction or ab.IsItemAction(action)) then
                                    local qi = ab.GetProfessionQualityInfo(action)
                                    rankAtlas = qi and qi.iconInventory
                                end
                                -- Older-client fallback: crafted quality by
                                -- itemID, mapped through the atlas probe.
                                if not rankAtlas and GetActionInfo then
                                    local aType, aID = GetActionInfo(action)
                                    if aType == "item" and aID then
                                        local ts = C_TradeSkillUI
                                        local q = ts and ts.GetItemCraftedQualityByItemInfo
                                            and ts.GetItemCraftedQualityByItemInfo(aID)
                                        if type(q) == "number" and q >= 1 and q <= 5 then
                                            rankAtlas = RankAtlasFor(q)
                                        end
                                    end
                                end
                                if EllesmereUI._RANKDEBUG and rankAtlas ~= nil then
                                    pcall(function()
                                        print("|cff33ff99[Rank]|r action", action,
                                            "atlas", tostring(rankAtlas))
                                    end)
                                end
                            end
                        end
                        SetRankShown(btn, rankAtlas)
                        -- Blizzard's overlay must never draw over ours: it can
                        -- pre-exist this fix or get shown by a hover-driven
                        -- lazy creation. Hide + install the permanent OnShow
                        -- hide for overlays born after the apply pass ran.
                        local ov = btn.ProfessionQualityOverlayFrame
                        if ov then
                            if ov:IsShown() then ov:SetShown(false) end
                            if not EFD(btn).qualityHooked then
                                ov:HookScript("OnShow", function(self2)
                                    self2:SetShown(false)
                                end)
                                EFD(btn).qualityHooked = true
                            end
                        end
                    end
                end
            end
        end

        QueueQualityScan = function()
            if not _qPending then
                _qPending = true
                C_Timer_After(0, QualityScan)
            end
        end
        EAB._QueueRankScan = QueueQualityScan

        qf:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        -- Loadout/spec swap changes slot CONTENTS but does not reliably fire
        -- ACTIONBAR_SLOT_CHANGED for our EABButtons (same reason the spell
        -- refresh sweep exists), so a rank icon from the old spec's item can
        -- persist on a slot the new spec leaves empty or fills with a spell.
        -- SPELLS_CHANGED covers that swap; the macro name is handled by the
        -- ForceButtonRefresh sweep on the same event.
        qf:RegisterEvent("SPELLS_CHANGED")
        qf:SetScript("OnEvent", QueueQualityScan)
        -- A hover is what makes Blizzard lazily CREATE its overlay (and shows it in the
        -- same breath) -- and no slot event fires from hovering, so the suppression +
        -- our repaint would otherwise lag until the next slot change. Re-scan off the
        -- tooltip hook (coalesced, deferred to a clean context; same GameTooltip hook
        -- pattern as tooltip suppression). Also converges anything the hover's
        -- item-data load just made resolvable.
        if GameTooltip then
            hooksecurefunc(GameTooltip, "SetAction", QueueQualityScan)
        end
        -- Initial paint (login / reload): bars applied before this block ran.
        QueueQualityScan()
    end

    SLASH_ELLESMEREACTIONBARS1 = "/eab"
    SlashCmdList["ELLESMEREACTIONBARS"] = function(msg)
        EllesmereUI:ShowModule("EllesmereUIActionBars")
    end

    SLASH_EABQUICKKEYBIND1 = "/kb"
    -- Unambiguous alias: other UI suites (ElvUI) register /kb for their own
    -- bind mode, and whichever loads last owns it.
    SLASH_EABQUICKKEYBIND2 = "/euikb"
    SlashCmdList["EABQUICKKEYBIND"] = function(msg)
        if InCombatLockdown() then return end
        if not C_AddOns.IsAddOnLoaded("Blizzard_QuickKeybind") then
            C_AddOns.LoadAddOn("Blizzard_QuickKeybind")
        end
        if QuickKeybindFrame then
            QuickKeybindFrame:Show()
        end
    end

end

function EAB:OnEnable()
    -- If this is a first install (or reset), we need to capture Blizzard's
    -- Edit Mode layout BEFORE hiding bars. The capture must run once Edit
    -- Mode has applied bar positions/sizes, i.e. at/after PLAYER_ENTERING_WORLD.
    --
    -- OnEnable itself is dispatched from the Lite enable-flush, gated on IsLoggedIn()
    -- and deferred one tick past PLAYER_LOGIN (the Edit Mode secret-taint fix). So on a
    -- fresh install the login PLAYER_ENTERING_WORLD has ALREADY fired by the time we
    -- run here -- a plain RegisterEvent would then wait for the next zone change, so
    -- OnFirstLogin (and the FinishSetup it calls) would never run this session and the
    -- bars stay built-but-invisible.
    --
    -- Since the flush guarantees we're logged in and past the login PEW (Edit Mode has
    -- applied its layout), capture now. Keep the event as a backstop for the rare case
    -- we somehow enable before login; the _needsCapture guard keeps the two paths
    -- idempotent (OnFirstLogin clears it + unregisters PEW).
    if self._needsCapture then
        self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnFirstLogin")
        if IsLoggedIn() then
            C_Timer_After(0, function()
                if self._needsCapture then self:OnFirstLogin() end
            end)
        end
    else
        self:FinishSetup()
    end
end

-- Called on PLAYER_ENTERING_WORLD for first-install only.
-- At this point Edit Mode has applied bar positions/sizes/rows.
function EAB:OnFirstLogin()
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")

    -- A profile import can stamp the capture flag mid-session (imported data
    -- is a chosen layout). Honor the stamp here so a still-pending capture
    -- never overwrites the imported profile; just run the normal setup.
    if self.db.sv._capturedOnce_EAB then
        self._needsCapture = false
        self:FinishSetup()
        return
    end

    -- Capture Blizzard layout while bars are still visible
    local captured = CaptureBlizzardDefaults()
    for barKey, data in pairs(captured) do
        local s = self.db.profile.bars[barKey]
        if s and data then
            if data.numIcons then s.overrideNumIcons = data.numIcons end
            if data.numRows then s.overrideNumRows = data.numRows end
            if data.orientation then s.orientation = data.orientation end
            if data.blizzIconScale then
                -- Convert Blizzard's icon scale to explicit button dimensions.
                -- barBaseSize isn't populated yet (SetupBar runs later), so
                -- read the base size directly from the first Blizzard button.
                local info = BAR_LOOKUP[barKey]
                local baseW, baseH = 45, 45
                if info and info.blizzBtnPrefix then
                    local btn1 = _G[info.blizzBtnPrefix .. "1"]
                    if btn1 then
                        baseW = math.floor((btn1:GetWidth() or 45) + 0.5)
                        baseH = math.floor((btn1:GetHeight() or 45) + 0.5)
                    end
                end
                s.buttonWidth = math.floor(baseW * data.blizzIconScale + 0.5)
                s.buttonHeight = math.floor(baseH * data.blizzIconScale + 0.5)
            end
            if data.alwaysShowButtons ~= nil then
                s.alwaysShowButtons = data.alwaysShowButtons
            end
            -- Visibility: 3=Hidden, 1=InCombat, 2=OutOfCombat, 0=Always
            -- Keep barVisibility and boolean flags in sync so the
            -- options dropdown reflects the actual state.
            if data.visibility then
                if data.visibility == 3 then
                    EAB.VisibilityCompat.ApplyMode(s, "never")
                elseif data.visibility == 1 then
                    EAB.VisibilityCompat.ApplyMode(s, "in_combat")
                elseif data.visibility == 2 then
                    EAB.VisibilityCompat.ApplyMode(s, "out_of_combat")
                else
                    EAB.VisibilityCompat.ApplyMode(s, "always")
                end
            end
            if data.point then
                self.db.profile.barPositions[barKey] = {
                    point = data.point, relPoint = data.relPoint,
                    x = data.x, y = data.y,
                }
            end
        end
    end

    -- Action Bar 1's end caps go to the outer ends of a row of bars Blizzard
    -- placed directly beside it (WoW Forever: the micro menu and bags).
    do
        local p = self.db.profile
        p.endCapSpanLeft, p.endCapSpanRight = ns.AB_CaptureCapSpan(captured)
    end

    -- WoW Forever keeps Blizzard's XP / reputation bars (useBlizzardDataBars),
    -- which Edit Mode stacks right above action bar 1 and restacks as they come
    -- and go (a watched reputation, max level). The bars it stacks above them
    -- (2, 3, stance, pet) were captured over the stack as it stood, so they are
    -- lifted by the steps its hidden containers would add (Edit Mode's
    -- UpdateBottomActionBarPositions: the secondary container height - 1, the
    -- main one height + 4), and a status bar that shows later never covers
    -- them. Only while the containers and the bar sit where Edit Mode puts them.
    if EllesmereUI.IS_FOREVER and self.db.profile.useBlizzardDataBars then
        local mainC, secC = _G.MainStatusTrackingBarContainer, _G.SecondaryStatusTrackingBarContainer
        local function AtDefault(f)
            if not f.IsInDefaultPosition then return true end
            local ok, v = pcall(f.IsInDefaultPosition, f)
            return not ok or v ~= false
        end
        if mainC and secC and AtDefault(mainC) and AtDefault(secC) then
            local lift = 0
            if not secC:IsShown() then lift = lift + (secC:GetHeight() or 0) - 1 end
            if not mainC:IsShown() then lift = lift + (mainC:GetHeight() or 0) + 4 end
            if lift > 0 then
                local STACKED = { MultiBarBottomLeft = true, MultiBarBottomRight = true,
                                  StanceBar = true, PetActionBar = true }
                local uiS = UIParent:GetEffectiveScale()
                for _, info in ipairs(BAR_CONFIG) do
                    local pos = self.db.profile.barPositions[info.key]
                    local bf = STACKED[info.blizzFrame] and _G[info.blizzFrame]
                    if pos and pos.y and bf and bf:IsShown() and AtDefault(bf) then
                        pos.y = pos.y + lift * bf:GetEffectiveScale() / uiS
                    end
                end
            end
        end
    end

    -- Mark capture as done so we never read Edit Mode again (per-install flag)
    self.db.sv._capturedOnce_EAB = true
    self._needsCapture = false

    -- Stance bar visibility must always be "Always" it manages its own
    -- show/hide based on shapeshift form availability.
    local sb = self.db.profile.bars["StanceBar"]
    if sb then
        sb.alwaysHidden       = false
        sb.combatShowEnabled  = false
        sb.combatHideEnabled  = false
    end

    -- Now proceed with normal setup
    self:FinishSetup()
end

-------------------------------------------------------------------------------
--  Edit Mode Icon Count Sync: when EUI's configured icon count for a bar
--  exceeds Edit Mode's setting, update the Edit Mode layout data via
--  C_EditMode.SaveLayouts so Blizzard's own code applies the higher count
--  (untainted). Avoids writing numButtonsShowable directly, which taints.
-------------------------------------------------------------------------------
local function SyncEditModeIconCounts()
    if InCombatLockdown() then return end
    -- Classic Era has no Edit Mode at all: C_EditMode is a neutral stub (its
    -- GetLayouts/SaveLayouts keys resolve to callable-but-empty functions,
    -- which would otherwise pass the plain truthiness check below several
    -- calls before the real no-op happens). Early-return explicitly instead
    -- of relying on that to resolve safely.
    if EllesmereUI.IS_CLASSIC_ERA then return end
    if not C_EditMode or not C_EditMode.GetLayouts or not C_EditMode.SaveLayouts then return end

    -- Never write while Blizzard's Edit Mode is open. The manager keeps its OWN copy of
    -- layoutInfo for the whole session and pushes that copy whole on Save, so a write from here
    -- is either discarded by the next Save or discards the edit in progress. This runs again on
    -- the next options close, so skipping costs nothing.
    if EllesmereUI.EditModeOpen() then return end

    -- SaveLayouts replaces the character's ENTIRE layout set (the client holds it and writes it
    -- at logout), so the payload has to have the shape Blizzard always passes: the presets
    -- first, then the saved layouts, with activeLayout an index into that merged list. When
    -- the presets cannot be resolved, skip the write entirely rather than send the short list.
    local layoutInfo, numPresets = EllesmereUI.EditModeLayoutsForSave()
    if not layoutInfo then return end

    -- Build desired icon counts keyed by systemIndex (all bars are system 0).
    -- MainMenuBar has no system; MainActionBar is system=0 systemIndex=1.
    local desired = {}
    for _, info in ipairs(BAR_CONFIG) do
        if not info.isStance and not info.isPetBar then
            local s = EAB.db and EAB.db.profile and EAB.db.profile.bars[info.key]
            local euiCount = s and (s.overrideNumIcons or s.numIcons) or info.count
            if not euiCount or euiCount < 1 then euiCount = info.count end
            local blizzBar = _G[info.blizzFrame]
            if blizzBar and blizzBar.system == 0 and blizzBar.systemIndex then
                desired[blizzBar.systemIndex] = euiCount
            end
            if info.nativeMainBar and _G.MainActionBar then
                local mab = _G.MainActionBar
                if mab.system == 0 and mab.systemIndex then
                    desired[mab.systemIndex] = euiCount
                end
            end
        end
    end

    -- Setting 2 = NumIcons. GetSettingValue(bar, 2) returns the actual count
    -- (6-12), so the raw layout value appears to be the actual count too.
    local ICON_COUNT_SETTING = 2
    local changed = false

    -- HideBarArt setting: force to 1 (hidden) on all action bar layouts
    local HIDE_BAR_ART_SETTING = Enum and Enum.EditModeActionBarSetting
        and Enum.EditModeActionBarSetting.HideBarArt

    -- Check ALL saved layouts so switching never reverts to fewer icons. The merged-in presets
    -- are read-only (SaveLayouts drops edits to them), so they are carried through untouched.
    -- Each row is noted for Uninstall EUI: a raised count is put back when its earlier value is
    -- known, and bar art is noted every time (shown is Blizzard's default, the fallback for an
    -- account older than the record).
    for layoutIndex, layout in ipairs(layoutInfo.layouts) do
        if layoutIndex > numPresets and type(layout.systems) == "table" then
            for _, sysInfo in ipairs(layout.systems) do
                if sysInfo.system == 0 and sysInfo.systemIndex and type(sysInfo.settings) == "table" then
                    local want = desired[sysInfo.systemIndex]
                    for _, s in ipairs(sysInfo.settings) do
                        if want and s.setting == ICON_COUNT_SETTING and s.value < want then
                            EllesmereUI.NoteEditModeSetting(layout, sysInfo, s.setting, s.value, want)
                            s.value = want
                            changed = true
                        end
                        if HIDE_BAR_ART_SETTING and s.setting == HIDE_BAR_ART_SETTING then
                            EllesmereUI.NoteEditModeSetting(layout, sysInfo, s.setting, s.value, 1, 0)
                            if s.value ~= 1 then
                                s.value = 1
                                changed = true
                            end
                        end
                    end
                end
            end
        end
    end

    if changed then
        C_EditMode.SaveLayouts(layoutInfo)
    end
end

function EAB:SyncEditModeIcons()
    if InCombatLockdown() then
        -- Keyed: repeated calls in one combat collapse into one idempotent sync.
        ns.CombatQueue.Defer("SyncEditModeIcons", SyncEditModeIconCounts)
        return
    end
    SyncEditModeIconCounts()
end

-- The actual bar creation, positioning, and event registration.
function EAB:FinishSetup()
    -- Run-once: reachable from OnEnable AND OnFirstLogin, and a module
    -- disable/re-enable dispatches OnEnable again. Everything here using
    -- HookScript (hover hooks on ~140 buttons, flyout OnHide, stock-bar
    -- OnShow) stacks a second permanent handler on re-entry -- HookScript
    -- can't be unhooked -- and the pet/stance event frames would duplicate.
    if ns._eabFinishSetupDone then return end
    ns._eabFinishSetupDone = true
    local function DoSetupSecure()
        -- Non-protected setup: create bar frames, compute layout, register events.
        -- Protected operations (SetParent, SetPoint on Blizzard buttons) are
        -- dispatched through the secure handler so they work even in combat.

        local inCombat = InCombatLockdown()

        if not inCombat then
            -- Normal load: use the direct path (all protected ops are fine)
            HideBlizzardBars()
            for _, info in ipairs(BAR_CONFIG) do
                SetupBar(info, false)
                LayoutBar(info.key)
            end
            -- Register secure handler refs now that buttons exist
            SecureSetupHandler_PrepareRefs()
            -- Apply the current page to MainBar buttons. The state driver
            -- evaluated during CreateBarFrame (before buttons existed), so
            -- buttons still have their initial action=slot from
            -- GetOrCreateButton; recalculate using the actual current page.
            local mbFrame = barFrames["MainBar"]
            if mbFrame then
                local curPage = tonumber(mbFrame:GetAttribute("state-page")) or 1
                local mbBtns = barButtons["MainBar"]
                if mbBtns then
                    for i, btn in ipairs(mbBtns) do
                        btn:SetAttribute("action", i + (curPage - 1) * 12)
                    end
                end
            end
            RestoreBarPositions()
            local vBtn = MainMenuBarVehicleLeaveButton
            if vBtn and barFrames["MainBar"] then
                vBtn:ClearAllPoints()
                vBtn:SetPoint("BOTTOM", barFrames["MainBar"], "TOPRIGHT", -15, 2)
            end
        else
            -- Combat reload: non-protected setup only; secure handler does the rest.
            -- Stock bar disposal (including ActionBarParent) already happened at
            -- file load time. OverrideActionBar is fully Blizzard-owned.
            EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_1", "1", "EllesmereUIActionBars")
            EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_2", "1", "EllesmereUIActionBars")
            EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_3", "1", "EllesmereUIActionBars")
            EllesmereUI.SetCVar("SHOW_MULTI_ACTIONBAR_4", "1", "EllesmereUIActionBars")

            -- Create bar frames and buttons (no protected ops)
            for _, info in ipairs(BAR_CONFIG) do
                SetupBar(info, true)
            end
            -- Register secure handler refs now that buttons exist
            SecureSetupHandler_PrepareRefs()

            -- Compute layout and encode for secure handler
            local layoutData = {}
            local barFrameData = {}
            local positions = EAB.db.profile.barPositions or {}

            for _, info in ipairs(BAR_CONFIG) do
                local key = info.key
                local buttons = barButtons[key]
                local s = EAB.db.profile.bars[key]
                local slotOffset = BAR_SLOT_OFFSETS[key] or 0
                if buttons then
                    local btnLayout, frameW, frameH = ComputeBarLayout(key)
                    local pos = positions[key]
                    local point = pos and pos.point or "CENTER"
                    local relPoint = pos and pos.relPoint or "CENTER"
                    local px = pos and pos.x or 0
                    local py = pos and pos.y or 0
                    tinsert(barFrameData, { key = key, w = frameW, h = frameH,
                        point = point, relPoint = relPoint, x = px, y = py,
                        hidden = (s and (s.alwaysHidden or s.enabled == false)) and true or false })

                    for i, btnData in pairs(btnLayout) do
                        local btn = buttons[i]
                        if btn and btn._secureSlotIdx then
                            local actionSlot = 0
                            if key == "MainBar" then
                                -- For MainBar, actionSlot encodes the button index (1-12)
                                actionSlot = i
                            elseif info.isPetBar then
                                -- PetActionButtons use their index (1-10) as their slot ID
                                actionSlot = i
                            elseif not info.isStance then
                                actionSlot = slotOffset + i
                            end
                            layoutData[btn._secureSlotIdx] = {
                                barKey = key,
                                x = btnData.x, y = btnData.y,
                                w = btnData.w, h = btnData.h,
                                show = btnData.show,
                                actionSlot = actionSlot,
                            }
                        end
                    end
                end
            end

            -- Dispatch all protected operations through the secure handler
            SecureSetupHandler_Execute(layoutData, barFrameData)
        end

        -- Both broadcasters are killed at file-load time (top of file), and
        -- the per-button ACTIONBAR_UPDATE_COOLDOWN registration is stripped at
        -- button creation, so this dispatcher is the ONLY owner of the cooldown
        -- pipeline -- swipes, desaturation and on-CD alpha all ride it. It used
        -- to be set up inside the out-of-combat branch above, which left a
        -- /reload taken in combat with no cooldown events at all for the rest
        -- of the session. It registers events and builds closures, nothing
        -- protected, so both paths get it here, after their buttons exist.
        -- DEFERRED one tick: ~1,600 lines of closure construction + ~25 event
        -- registrations, pure insecure and self-guarded (_dispatcherSetup).
        -- C_Timer callbacks fire on the first frame AFTER the loading screen,
        -- so this leaves the shared login watchdog budget (one combat-sized
        -- budget for the whole suite's OnEnable chain) without losing the
        -- combat-legal window: nothing here is combat-blocked. One tick with
        -- no cooldown events is invisible during the loading screen.
        C_Timer_After(0, function() EAB:SetupEventDispatcher() end)

        -- Visual styling: defer visuals to out-of-combat if needed.
        local function DoVisuals()
            ApplyAll()
            -- Reapply unlock-mode positions + anchor chains now that bars exist.
            -- (The EUI_UnlockMode hook on EAB.ApplyAll doesn't fire because
            -- ApplyAll is a local function, not on the addon table.)
            if EllesmereUI._applySavedPositions then
                -- NOTE: C_Timer callbacks do not run during the loading screen, so on a
                -- combat reload this fires after lockdown has re-engaged. The in-window
                -- pass lives in EUI_UnlockMode's synchronous PLAYER_LOGIN handler; this
                -- delayed pass is the settle correction once element sizes stabilize.
                C_Timer_After(1.5, EllesmereUI._applySavedPositions)
            end
            ApplyKeyDownCVar()
            self:SyncEditModeIcons()
            self:HookProcGlow()
            self:ScanExistingProcs()
            -- Re-scan after a delay to catch procs that Blizzard populates late
            C_Timer_After(2, function() self:ScanExistingProcs() end)
            -- Clear stale count text when a slot becomes empty. The central
            -- dispatcher's ACTIONBAR_SLOT_CHANGED branch handles this for our
            -- fresh EABButton frames; the UpdateCount hook covers Blizzard
            -- buttons that receive events natively.
            for _, info in ipairs(BAR_CONFIG) do
                if not info.isStance and not info.isPetBar then
                    local btns = barButtons[info.key]
                    if btns then
                        for _, b in ipairs(btns) do
                            if not b._eabCountFixed then
                                b._eabCountFixed = true
                                if b.UpdateCount then
                                    hooksecurefunc(b, "UpdateCount", function(self)
                                        if not self:HasAction() then
                                            self.Count:SetText("")
                                        end
                                    end)
                                end
                            end
                        end
                    end
                end
            end
        end

        if InCombatLockdown() then
            ns.CombatQueue.Defer("FinishSetupVisuals", function()
                C_Timer_After(0.1, DoVisuals)
            end)
        else
            C_Timer_After(0.1, DoVisuals)
        end
    end

    DoSetupSecure()

    -- Override keybinds (custom-paged/flyout click routes) + saved "Toggle
    -- Action Bar" keys: engine binding-table rebuilds, protected. On a combat
    -- /reload InCombatLockdown() is already true here and this loading-screen
    -- execution is the ONLY place the rebuild is legal, so it stays in-window.
    -- Out of combat there is no window to protect, and the whole suite's
    -- OnEnable chain shares this one watchdog budget (AB is first in it):
    -- move the rebuild to its own execution so it neither dies at the tail
    -- of the bar build nor starves the modules behind it. If a pull starts
    -- in the one-frame gap, both callees bail and re-arm on regen -- the
    -- same contract the combat path already lives on.
    if InCombatLockdown() then
        UpdateKeybinds()
        EAB:RebuildVisToggleBindings()
    else
        C_Timer_After(0, function()
            UpdateKeybinds()
            EAB:RebuildVisToggleBindings()
        end)
    end

    -- Initialize the showgrid monitor on ActionButton1 so that when
    -- Blizzard changes its showgrid attribute (e.g. during combat spell
    -- drag), the change propagates to all our managed buttons.
    InitShowGridMonitor()

    -- Register ACTIONBAR_SHOWGRID/HIDEGRID on the controller itself
    -- so the secure showgrid state stays in sync with game events.
    -- Note: RunAttribute cannot be called from Lua; use SetAttribute to
    -- trigger the secure _onattributechanged snippet instead.
    local _gridSurfacedBars = {}
    local _gridRestorePending = false
    local function RestoreGridSurfacedBars()
        _gridRestorePending = false
        if InCombatLockdown() then
            -- Restore swallowed by combat (drag ended after combat began):
            -- flag the regen ApplyAll so the stomped drivers still re-derive.
            ns._eabApplyDeferred = true
            return
        end
        -- If something is still on the cursor (spell swap), don't restore yet
        if GetCursorInfo() then return end
        for key in pairs(_gridSurfacedBars) do
            local info = BAR_LOOKUP[key]
            local s = EAB.db.profile.bars[key]
            local frame = barFrames[key]
            if info and s and frame then
                if s.mouseoverEnabled then
                    -- The drag has fully ended (cursor cleared, checked above). If
                    -- the cursor is still over this bar, the spell was dropped here
                    -- (or you're just hovering it), so keep it shown and let the
                    -- normal OnLeave fade it on real exit. Otherwise hide as before.
                    local state = hoverStates[key]
                    if frame:IsMouseOver() then
                        if state then state.isHovered = true; state.fadeDir = "in" end
                        StopFade(frame, s._savedBarAlpha or 1)
                        if key == "MainBar" then SyncPagingAlpha(s._savedBarAlpha or 1) end
                    else
                        if state then state.isHovered = false; state.fadeDir = "out" end
                        StopFade(frame, 0)
                        if key == "MainBar" then SyncPagingAlpha(0) end
                    end
                end
            end
        end
        wipe(_gridSurfacedBars)
        -- Re-derive every driver through the single recompute site instead of
        -- a local predicate: the surface condition above admits option-driven
        -- bars (visHideMounted etc.) whose barVisibility is "always", and a
        -- restore predicate maintained separately drifted and left exactly
        -- those bars stuck on "show" until a settings toggle or /reload. The
        -- surface stomp syncs _eabLastVisStr, so this compare-and-register
        -- pass re-registers precisely the stomped bars.
        EAB:RefreshRuntimeVisibility()
    end
    -- Registering events on a frame stamps it with the EventRegistrations forbidden
    -- aspect, and the restricted environment refuses frames carrying any aspect. The
    -- controller wraps buttons and executes snippets, so its events must live on a
    -- plain sidecar listener, never on the controller.
    -- Mirror Blizzard's lockActionBars setting onto the controller so the
    -- secure OnDragStart wrapper can tell a real pickup from a dead gesture
    -- (see the wrapper in RegisterButtonWithController). Attribute, not a
    -- chunk local: this file is at Lua 5.1's 200-local cap, and the snippet
    -- can only read attributes anyway.
    ns.EABSyncBarsLocked = function()
        -- No _eabApplyDeferred here, unlike the widget-writing guards: nothing
        -- else needs re-applying, and PLAYER_REGEN_ENABLED re-syncs this.
        if InCombatLockdown() then return end
        local locked
        if Settings and Settings.GetValue then
            local ok, v = pcall(Settings.GetValue, "lockActionBars")
            -- v ~= nil, not just ok: this seeds during FinishSetup, which can
            -- run before the setting is registered. Accepting nil as "false"
            -- would skip the CVar fallback and seed a LOCKED bar as unlocked.
            if ok and v ~= nil then locked = v and true or false end
        end
        if locked == nil and C_CVar and C_CVar.GetCVarBool then
            locked = C_CVar.GetCVarBool("lockActionBars") and true or false
        end
        local v = locked and 1 or 0
        -- Guarded: SetAttribute re-runs the controller's _onattributechanged
        -- snippet, and CVAR_UPDATE is a firehose at login.
        if ActionButtonController:GetAttribute("eab-barslocked") ~= v then
            ActionButtonController:SetAttribute("eab-barslocked", v)
        end
    end

    EAB._abcEvents = ns.TakeShell()

    -- Controller-side grid appliers, run from the settle in ns.EABQueueGrid.
    _gridState.showFns[#_gridState.showFns + 1] = function()
        -- Cancel any pending restore (swap case: drop + immediate pickup)
        _gridRestorePending = false
        if not InCombatLockdown() then
            for btn in pairs(_controllerButtons) do
                SetShowGridInsecure(btn, true, SHOWGRID.GAME_EVENT)
            end
            -- Temporarily surface bars hidden by conditional visibility
            -- (combat-only, target-only, etc.) so the user can place spells.
            for _, info in ipairs(BAR_CONFIG) do
                if not info.isStance and not info.isPetBar then
                    local s = EAB.db.profile.bars[info.key]
                    local frame = barFrames[info.key]
                    if s and frame and not s.alwaysHidden
                       and not (EAB._padHide and s.gamepadHideBar == true) then
                        local vis = s.barVisibility or "always"
                        -- Any visibility option at all counts: a bar the player cannot
                        -- see is a bar they cannot drop a spell onto, so surfacing one
                        -- that did not strictly need it is the harmless direction.
                        local hasCondition = vis ~= "always" and vis ~= "never"
                        if not hasCondition and EllesmereUI.VisHasAnyOption then
                            hasCondition = EllesmereUI.VisHasAnyOption(s)
                        end
                        if hasCondition then
                            _gridSurfacedBars[info.key] = true
                            RegisterAttributeDriver(frame, "state-visibility", "show")
                            -- Keep the cache in sync with the stomp (same
                            -- class as the QuickKeybind surface fix): a
                            -- stale cache holding the real string makes
                            -- every later refresh compare equal and skip
                            -- re-registering, leaving the bar stuck on
                            -- "show" until a settings toggle or /reload.
                            frame._eabLastVisStr = "show"
                            frame:Show()
                        end
                        -- Mouseover bars: force alpha to 1 during drag
                        if s.mouseoverEnabled then
                            _gridSurfacedBars[info.key] = true
                            StopFade(frame, 1)
                        end
                    end
                end
            end
        end
    end

    _gridState.hideFns[#_gridState.hideFns + 1] = function()
        if not InCombatLockdown() then
            for btn in pairs(_controllerButtons) do
                SetShowGridInsecure(btn, false, SHOWGRID.GAME_EVENT)
            end
            -- Defer restore: spell swaps fire HIDEGRID then SHOWGRID
            -- in rapid succession. Deferring lets the next SHOWGRID
            -- cancel the restore so bars stay visible.
            if next(_gridSurfacedBars) then
                _gridRestorePending = true
                C_Timer_After(0, RestoreGridSurfacedBars)
            end
        end
    end

    EAB._abcEvents:SetScript("OnEvent", function(_, event, arg1)
        if event == "ACTIONBAR_SHOWGRID" then
            ns.EABQueueGrid(true)
        elseif event == "ACTIONBAR_HIDEGRID" or event == "PET_BAR_HIDEGRID" then
            ns.EABQueueGrid(false)
        elseif event == "CVAR_UPDATE" then
            -- Name-filtered: CVAR_UPDATE fires for every cvar, dozens of times
            -- at login. The lock matters to the drag wrapper; Cast Actions on
            -- Key Down re-applies useOnKeyDown (combat-deferred).
            if arg1 == "lockActionBars" then ns.EABSyncBarsLocked()
            elseif arg1 == "ActionButtonUseKeyDown" then ApplyKeyDownCVar() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- A lock toggled during combat deferred; pick it up on regen.
            ns.EABSyncBarsLocked()
        elseif event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" then
            if event == "PLAYER_ENTERING_WORLD" then ns.EABSyncBarsLocked() end
            -- Spec/talent swaps refill slots: retire the filled-slot fast
            -- lists (see the dispatcher's repaint walks) AND the curated-set
            -- memo (talents change what the viewer curates).
            ns._cdFilledDirty = true
            ns._cdCuratedDirty = true
            -- Force visibility update on all managed buttons
            if not InCombatLockdown() then
                for btn in pairs(_controllerButtons) do
                    local showgrid = btn:GetAttribute("showgrid") or 0
                    local hasAction = btn.HasAction and btn:HasAction()
                    local hidden = btn:GetAttribute("statehidden")
                    if not hidden and (showgrid > 0 or hasAction) then
                        if not btn:IsShown() then
                            btn:Show()
                            -- Our Show keeps alpha: a surfaced 2-park sits at 0.
                            local pfd = ns._eabFD[btn]
                            if pfd and pfd.parkA0 == 2 and btn:IsShown() then pfd.parkA0 = 1 end
                        end
                    end
                end
            end
        end
    end)
    EAB._abcEvents:RegisterEvent("ACTIONBAR_SHOWGRID")
    EAB._abcEvents:RegisterEvent("ACTIONBAR_HIDEGRID")
    EAB._abcEvents:RegisterEvent("PET_BAR_HIDEGRID")
    EAB._abcEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
    EAB._abcEvents:RegisterEvent("SPELLS_CHANGED")
    EAB._abcEvents:RegisterEvent("CVAR_UPDATE")
    EAB._abcEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- Seed before the first drag: PLAYER_ENTERING_WORLD may already be past.
    ns.EABSyncBarsLocked()

    -- Reset showgrid state at login (covers waiting for the game to apply
    -- the always-show-buttons state to the main bar).
    if ActionButton1 then
        ActionButton1:SetAttribute("showgrid", 0)
    end

    -- Suppress action bar tooltips per-bar when the setting is enabled.
    -- Hooks GameTooltip:SetAction/SetPetAction which Blizzard action
    -- buttons call on hover. Zero per-frame cost.
    if GameTooltip then
        local function ShouldHideTooltip(tip)
            local owner = tip:GetOwner()
            if not owner then return false end
            local info = buttonToBar[owner]
            if not info then return false end
            local s = EAB.db and EAB.db.profile.bars[info.barKey]
            return s and s.disableTooltips
        end
        hooksecurefunc(GameTooltip, "SetAction", function(self)
            if ShouldHideTooltip(self) then self:Hide() end
        end)
        hooksecurefunc(GameTooltip, "SetPetAction", function(self)
            if ShouldHideTooltip(self) then self:Hide() end
        end)
    end

    -- Attach hover hooks for mouseover -- DEFERRED one tick: ~290 HookScript
    -- calls + ~60 closures, the heaviest pure-insecure chunk in the login
    -- window. HookScript is combat-legal; every hoverStates consumer nil-
    -- guards, so one unpopulated tick is a silent no-op; and After(0) fires
    -- before DoVisuals' +0.1s RefreshMouseover walk.
    C_Timer_After(0, function()
        for _, info in ipairs(BAR_CONFIG) do
            AttachHoverHooks(info.key)
        end
    end)

    -- When a spell flyout closes, fade out any bars that were kept visible by it
    do
        local flyFrame = GetEABFlyout():GetFrame()
        if flyFrame then
            flyFrame:HookScript("OnHide", function()
                if _quickKeybindState.open then return end
                for key, state in pairs(hoverStates) do
                    if not state.isHovered then
                        EAB_VTABLE.Hover.FadeOut(key, state)
                    end
                end
            end)
        end
    end

    -- When the screen's coordinate space changes (UI Scale, resolution, window
    -- size), put every bar back on its SAVED position. The bars are clamped to
    -- the screen (SetupBar), and the engine can rewrite a clamped frame's
    -- anchor to the spot it clamped it to; re-applying the saved record returns
    -- a bar to its real spot once the screen has room again. Display only:
    -- nothing here reads a live anchor or writes a saved position (the saved
    -- record changes only when the player moves the bar). Gated on UIParent's
    -- size, so a scale event that changes nothing costs one compare. Skipped
    -- while an unlock session is open or suspended for combat: its movers own
    -- the bars until Save & Exit or Cancel.
    do
        local scaleFrame = ns.TakeShell()
        scaleFrame._eabW, scaleFrame._eabH = UIParent:GetSize()
        local function ReapplySavedBarPositions()
            if EllesmereUI._unlockActive or EllesmereUI._unlockModeSessionActive then return end
            RestoreBarPositions()
            -- Anchored bars take their spot from the anchor, not the record.
            -- The helper lives in the unlock core, built at PLAYER_LOGIN.
            local reapply = EllesmereUI.ReapplyUnlockAnchor
            local adb = EllesmereUIDB and EllesmereUIDB.unlockAnchors
            if reapply and adb then
                local bars = EAB.db.profile.bars
                for _, info in ipairs(BAR_CONFIG) do
                    local key = info.key
                    local ai = adb[key]
                    if ai and ai.target then
                        -- A growth bar with no captured pin keeps its LIVE
                        -- edge on a re-apply (the settle pass skips it for the
                        -- same reason), which would fix a clamped spot in place.
                        local s = bars[key]
                        local gd = (s and s.growDirection or "up"):upper()
                        if key == "StanceBar" or gd == "CENTER" or ai.refFor == gd then
                            reapply(key)
                        end
                    end
                end
            end
        end
        scaleFrame:RegisterEvent("UI_SCALE_CHANGED")
        scaleFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
        scaleFrame:SetScript("OnEvent", function(sf)
            local w, h = UIParent:GetSize()
            if w == sf._eabW and h == sf._eabH then return end
            if EllesmereUI._unlockActive or EllesmereUI._unlockModeSessionActive then return end
            sf._eabW, sf._eabH = w, h
            if InCombatLockdown() then
                ns.CombatQueue.Defer("EABReapplyBarPositions", ReapplySavedBarPositions)
            else
                ReapplySavedBarPositions()
            end
        end)
    end

    -- Register events
    self:RegisterEvent("UPDATE_BINDINGS", function()
        if InCombatLockdown() then
            ns.CombatQueue.Defer("UpdateKeybinds", UpdateKeybinds)
        else
            UpdateKeybinds()
        end
        self:ApplyFonts()
    end)

    _gridState.showFns[#_gridState.showFns + 1] = OnGridChange
    self:RegisterEvent("ACTIONBAR_SHOWGRID", function() ns.EABQueueGrid(true) end)
    -- Pet actions fire their own grid events when dragging pet spells
    self:RegisterEvent("PET_BAR_SHOWGRID", function() ns.EABQueueGrid(true) end)

    -- Detect bar-to-bar drags (CURSOR_CHANGED) and clear grid state on drop.
    -- Also show mouseover-faded bars while dragging so the player can drop
    -- spells/items onto them.  Purely visual -- no secure frame access.
    local DRAG_TYPES = {
        spell = true, macro = true,
        petaction = true, mount = true, companion = true,
    }
    _dragState.visible = false
    _dragState.strataCache = {}  -- [frame] = originalStrata
    local function ResetDragState()
        -- Stale drag-forced Never bars (drag ended across a loading screen /
        -- combat edge) go back to hidden with the rest of the drag state.
        EAB._RestoreDragNeverBars()
        -- Force-restore all strata and clear drag visibility without the
        -- guard check, so stale state from spec changes etc. is always cleaned.
        _dragState.visible = false
        -- Skip the restore if in combat; the strata cache entries survive
        -- and will be restored on the next PLAYER_REGEN_ENABLED call.
        if InCombatLockdown() then return end
        for frame, orig in pairs(_dragState.strataCache) do
            frame:SetFrameStrata(orig)
        end
        wipe(_dragState.strataCache)
    end
    local function SetDragVisible(show)
        if _dragState.visible == show then return end
        _dragState.visible = show
        for _, info in ipairs(ALL_BARS) do
            local key = info.key
            local s = self.db.profile.bars[key]
            if not s then -- skip bars without settings
            else
            local frame = barFrames[key]
                or (info.isDataBar and dataBarFrames[key])
                or (info.isBlizzardMovable and blizzMovableHolders[key])
                or extraBarHolders[key]
                or (info.visibilityOnly and _G[info.frameName])
            -- For extra bars, alpha is managed on the Blizzard frame directly
            if info.visibilityOnly and not info.isDataBar and not info.isBlizzardMovable then
                local bf = _G[info.frameName]
                if bf then frame = bf end
            end
            if frame then
                local state = hoverStates[key]
                if show then
                    -- Raise strata so bars render above the spellbook.
                    -- SetFrameStrata is protected on secure frames in combat,
                    -- so only do this out of combat.
                    if not InCombatLockdown() then
                        if not _dragState.strataCache[frame] then
                            _dragState.strataCache[frame] = frame:GetFrameStrata()
                        end
                        frame:SetFrameStrata("FULLSCREEN_DIALOG")
                    end
                    -- Show mouseover-faded bars at full opacity
                    if s.mouseoverEnabled then
                        local fullAlpha = s._savedBarAlpha or 1
                        StopFade(frame, fullAlpha)
                        if state then state.fadeDir = "in" end
                        if key == "MainBar" then SyncPagingAlpha(fullAlpha) end
                    end
                else
                    -- Restore original strata (only if we changed it)
                    if not InCombatLockdown() then
                        local orig = _dragState.strataCache[frame]
                        if orig then
                            frame:SetFrameStrata(orig)
                            _dragState.strataCache[frame] = nil
                        end
                    end
                    -- Fade back out if mouseover-enabled and not hovered. Skip
                    -- position-only Blizzard-owned bars (the QueueStatus eye): EUI
                    -- controls only their position, never fades them out.
                    if s.mouseoverEnabled and not info.noManagedVisibility then
                        if not (state and state.isHovered) then
                            StopFade(frame)
                            FadeTo(frame, 0, s.mouseoverSpeed or 0.15)
                            if state then state.fadeDir = "out" end
                            if key == "MainBar" then SyncPagingAlpha(0) end
                        end
                    end
                end
            end
        end
        end
    end

    EUI_SafeRegisterEvent(self, "CURSOR_CHANGED", function()
        local cursorType = GetCursorInfo()
        if cursorType then
            if DRAG_TYPES[cursorType] then
                SetDragVisible(true)
                -- Through the queue, never straight into OnGridChange: a
                -- direct call flips _gridState.shown, and this drag's own
                -- ACTIONBAR_SHOWGRID would then settle as a no-op and skip
                -- the controller-side applier.
                ns.EABQueueGrid(true)
                -- Force mouseover bars visible during real cursor drags
                _gridState._mouseoverForced = true
                for _, info in ipairs(BAR_CONFIG) do
                    local s = EAB.db.profile.bars[info.key]
                    if s and s.mouseoverEnabled then
                        local frame = barFrames[info.key]
                        if frame then
                            StopFade(frame, 1)
                            if info.key == "MainBar" then SyncPagingAlpha(1) end
                        end
                    end
                end
                -- Show During Drag (per-bar opt-in, s.dragShow): surface bars saved as
                -- Never so the drag can be dropped onto them. Surgical -- every other
                -- visibility mode already shows during a drag (mouseover forcing
                -- above, conditional drivers). Reuses the runtime _visOverride slot
                -- (never persisted) and skips bars the toggle keybind already
                -- overrides. Secure driver swaps are combat-blocked, so combat drags
                -- leave Never bars hidden.
                if not InCombatLockdown() and not _gridState._dragNeverForced then
                    local forced
                    for _, info in ipairs(BAR_CONFIG) do
                        local s = EAB.db.profile.bars[info.key]
                        if s and s.dragShow and s.enabled ~= false
                           and (s.barVisibility == "never" or s.alwaysHidden)
                           and not (EAB._visOverride and EAB._visOverride[info.key]) then
                            EAB._visOverride = EAB._visOverride or {}
                            EAB._visOverride[info.key] = "always"
                            forced = forced or {}
                            forced[info.key] = true
                        end
                    end
                    if forced then
                        _gridState._dragNeverForced = forced
                        EAB:RefreshRuntimeVisibility()
                    end
                end
            end
        else
            SetDragVisible(false)
            EAB._RestoreDragNeverBars()
            -- Fallback for a cursor cleared without a HIDEGRID; the queue
            -- dedupes when both arrive. OnGridHide owns the state flip and
            -- the re-assert, so this must not clear _gridState.shown itself
            -- (that would make the settle skip the hide appliers).
            if _gridState.shown then ns.EABQueueGrid(false) end
        end
    end)

    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        -- Re-apply anything deferred during combat -- but ONLY if something actually
        -- deferred. ns._eabApplyDeferred is set by every combat-gated apply site whose
        -- skipped work this ApplyAll heals (LayoutBar, shapes, grid, page sync,
        -- suppress/unsuppress, the visibility appliers, and ApplyAll itself when run
        -- mid-combat). The unconditional version ran the full ~30ms bar reskin on EVERY
        -- combat drop -- a visible hitch between every dungeon pack, paid even when
        -- combat deferred nothing.
        if ns._eabApplyDeferred then
            ns._eabApplyDeferred = nil
            ApplyAll()
        end
        -- Restore any strata changes that couldn't be done in combat
        ResetDragState()
        -- Quick Keybind buttons may need reassertion after combat transitions
        _quickKeybindState.ReassertButtonsAfterCombatChange()
        -- Combat page flips can leave empower hold-release attrs stale while
        -- the routing signature is unchanged; repair once per combat drop.
        if ns._EABReassertEmpowerAttrs then ns._EABReassertEmpowerAttrs() end
    end)

    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        _quickKeybindState.ReassertButtonsAfterCombatChange()
    end)

    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        -- After any loading screen, reset vehicle/housing keybind flags and re-apply
        -- bindings. WoW can briefly report vehicleui/overridebar during zone
        -- transitions, which clears our override bindings. If the restore races with
        -- InCombatLockdown() the bindings stay cleared forever. This catches that.
        ResetDragState()
        C_Timer_After(0.2, function()
            -- Reset stale flags -- if we're not actually in housing the flag
            -- should be false. Plain Lua state, safe in combat.
            local inHousing = IsHouseEditorActive and IsHouseEditorActive()
            if not inHousing and _bindState.housingCleared then
                _bindState.housingCleared = false
            end
            -- This is the restore point for the transient-clear race above, so it
            -- must never be skipped: bindings can be cleared or wrongly routed while
            -- the cached signature claims they are applied. Force the rebuild past
            -- the signature short-circuit, and call unconditionally --
            -- UpdateKeybinds defers itself to PLAYER_REGEN_ENABLED in combat. Zoning
            -- INTO combat (die, release, run back in while the raid still fights)
            -- needs this or empower slots sit on native bindings (Press-and-Tap
            -- behaviour) until the next reload.
            _bindState.sigValid = false
            UpdateKeybinds()
        end)
        -- Re-evaluate visibility options (visOnlyInstances, visHideHousing,
        -- etc.) after every loading screen. ZONE_CHANGED_NEW_AREA alone is
        -- insufficient: it can fire before GetInstanceInfo() updates, and
        -- doesn't fire at all on /reload inside an instance.
        self:UpdateHousingVisibility()
    end)

    local function QueueAlwaysShowButtonsRefresh()
        -- During drag, skip. OnGridChange already shows everything, and
        -- HIDEGRID / CURSOR_CHANGED will restore afterwards.
        if _gridState.shown then return end
        if _gridState.visPending then return end
        _gridState.visPending = true
        C_Timer_After(0, function()
            _gridState.visPending = false
            if _gridState.shown then return end
            for _, info in ipairs(BAR_CONFIG) do
                self:ApplyAlwaysShowButtons(info.key)
            end
        end)
    end

    -- Slot changes alone are not sufficient for all paging transitions
    -- (dragonriding, druid forms, mount state). Include page/bonus events
    -- so empty-slot visibility refreshes immediately on those swaps.
    self:RegisterEvent("ACTIONBAR_PAGE_CHANGED", QueueAlwaysShowButtonsRefresh)
    self:RegisterEvent("UPDATE_BONUS_ACTIONBAR", QueueAlwaysShowButtonsRefresh)

    -- Spec swap: Blizzard may re-show SlotArt/SlotBackground or change button
    -- regions after our hooks ran. Deferred re-apply ensures our cosmetic
    -- overrides (squaring, borders, slot art hiding) are re-enforced after
    -- Blizzard finishes processing the spec change.
    EUI_SafeRegisterEvent(self, "PLAYER_SPECIALIZATION_CHANGED", function()
        C_Timer.After(0.5, function()
            if not InCombatLockdown() then
                ApplyAll()
                RestoreBarPositions()
            end
        end)
    end)

    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        self:UpdateHousingVisibility()
    end)

    -- Visibility option events: mounted, target, group changes
    EUI_SafeRegisterEvent(self, "PLAYER_MOUNT_DISPLAY_CHANGED", function()
        self:UpdateHousingVisibility()
    end)
    -- Resting: IsResting() has no dedicated poll, so without this the Resting axis only
    -- re-evaluated when some unrelated event above happened to fire afterward.
    self:RegisterEvent("PLAYER_UPDATE_RESTING", function()
        self:UpdateHousingVisibility()
    end)
    -- Party Mode axis: no game event, so the core fires its own edge
    -- (EllesmereUI.FireVisEdge, re-fired after combat for secure bars).
    if EllesmereUI.RegisterVisEdge and not self._partyVisEdge then
        self._partyVisEdge = true
        EllesmereUI.RegisterVisEdge(function() self:UpdateHousingVisibility() end)
    end
    -- Vehicle edges for the In Vehicle axis (same reasoning as Resting; the
    -- sync is gated + coalesced, so the rare fire costs a flag check).
    EUI_SafeRegisterEvent(self, "UNIT_ENTERED_VEHICLE", function()
        self:UpdateHousingVisibility()
    end)
    EUI_SafeRegisterEvent(self, "UNIT_EXITED_VEHICLE", function()
        self:UpdateHousingVisibility()
    end)
    self:RegisterEvent("UPDATE_SHAPESHIFT_FORM", function()
        self:UpdateHousingVisibility()
    end)
    -- Dragonriding visibility modes on the managed non-secure bars:
    -- capability edge plus the airborne edge (probed at load in
    -- EllesmereUI_Visibility.lua; the secure bars need neither -- their
    -- state driver re-evaluates [advflyable,flying] natively).
    EUI_SafeRegisterEvent(self, "PLAYER_CAN_GLIDE_CHANGED", function()
        self:UpdateHousingVisibility()
    end)
    if EllesmereUI._hasGlidingEvent then
        EUI_SafeRegisterEvent(self, "PLAYER_IS_GLIDING_CHANGED", function()
            self:UpdateHousingVisibility()
        end)
    end
    -- Immediate soft-target override: when the only "target" is a soft-interact NPC
    -- (dialogue in view cone), the [noexists] state driver instantly shows the bar.
    -- Override to "hide" in the same frame so the bar never visibly flashes. The
    -- deferred UpdateHousingVisibility that follows handles the general case and
    -- restores the normal driver string when the soft target clears.
    local function ImmediateSoftTargetCheck()
        -- Fully gated (same flag the 0.1s poll already uses): without a
        -- "Hide when No Target" bar, the four UnitExists calls and the
        -- all-bars walk below are dead weight on every soft-target flip --
        -- and soft-interact churns constantly near NPCs.
        if not self._anyHideNoTarget then return end
        if InCombatLockdown() then return end
        -- [noexists] in macro conditionals considers soft-interact/
        -- softenemy/softfriend as "target exists", but UnitExists("target")
        -- does NOT. Check the soft-target unit tokens directly.
        local hasSoftInteract = UnitExists("softinteract")
        local hasSoftEnemy = UnitExists("softenemy")
        local hasSoftFriend = UnitExists("softfriend")
        local hasHardTarget = UnitExists("target")
        local softOnly = (hasSoftInteract or hasSoftEnemy or hasSoftFriend) and not hasHardTarget
        for _, info in ipairs(ALL_BARS) do
            local s = self.db.profile.bars[info.key]
            if s and (s.visHideNoTarget or (s.visHideWithTarget and s.visibilityMatch == "any"))
                    and not (self._visOverride and self._visOverride[info.key]) then
                local frame = barFrames[info.key]
                if frame then
                    -- Under Any a literal "hide" would veto the whole disjunction on this
                    -- one lane; the rebuild below lets the shared builder drop just it.
                    if softOnly and s.visHideNoTarget and s.visibilityMatch ~= "any" then
                        if frame._eabLastVisStr ~= "hide" then
                            frame._eabLastVisStr = "hide"
                            RegisterAttributeDriver(frame, "state-visibility", "hide")
                        end
                    else
                        local newStr = BuildVisibilityString(info, s)
                        if frame._eabLastVisStr ~= newStr then
                            frame._eabLastVisStr = newStr
                            RegisterAttributeDriver(frame, "state-visibility", newStr)
                        end
                    end
                end
            end
        end
    end
    self:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        -- Defer: UnitExists("target") is not always updated at the exact
        -- moment PLAYER_TARGET_CHANGED fires, so an immediate check can
        -- wrongly see no hard target and keep the bar hidden. Run next frame.
        C_Timer.After(0, function()
            ImmediateSoftTargetCheck()
            self:UpdateHousingVisibility()
        end)
    end)
    EUI_SafeRegisterEvent(self, "PLAYER_SOFT_INTERACT_CHANGED", function()
        ImmediateSoftTargetCheck()
        self:UpdateHousingVisibility()
    end)
    local function RegisterIfValid(event, fn)
        if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid(event) then
            EUI_SafeRegisterEvent(self, event, fn)
        end
    end
    RegisterIfValid("PLAYER_SOFT_ENEMY_CHANGED", function()
        ImmediateSoftTargetCheck()
        self:UpdateHousingVisibility()
    end)
    RegisterIfValid("PLAYER_SOFT_FRIEND_CHANGED", function()
        ImmediateSoftTargetCheck()
        self:UpdateHousingVisibility()
    end)
    self:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        self:UpdateHousingVisibility()
    end)
    -- Polling fallback: some soft-target transitions (notably Action Targeting walking
    -- into range) do not reliably fire the dedicated soft-target events on every
    -- client/patch. Check the soft-target unit tokens every 0.1s and sync visibility
    -- only when the state changes. Gated on _anyHideNoTarget: for users with no "Hide
    -- when No Target" bar this is a single flag check that then returns, so the
    -- machinery costs nothing. The state token is four cached booleans (no per-tick
    -- allocation); refresh only runs when a token actually flips.
    self:_RefreshSoftTargetGate()
    -- Hover-gated bars (Match Any plus mouseover) need their resting alpha re-derived
    -- whenever the state their other disjuncts read moves. Rather than hand-wiring the
    -- five relevant events here, ride the shared visibility dispatcher: it already watches
    -- exactly that set, pcall-wraps each updater and defers one frame (imperceptible for
    -- alpha). Same registration Friends, Quest Tracker and Damage Meters use.
    EllesmereUI.RegisterVisibilityUpdater(function()
        EAB:RefreshHoverGatedAlpha()
    end)
    local lastI, lastE, lastF, lastT
    local function PollSoftTargetState()
        if InCombatLockdown() then return end
        if not self._anyHideNoTarget then return end
        local i  = UnitExists("softinteract") and true or false
        local e  = UnitExists("softenemy") and true or false
        local fr = UnitExists("softfriend") and true or false
        local t  = UnitExists("target") and true or false
        if i ~= lastI or e ~= lastE or fr ~= lastF or t ~= lastT then
            lastI, lastE, lastF, lastT = i, e, fr, t
            ImmediateSoftTargetCheck()
            self:UpdateHousingVisibility()
        end
    end
    C_Timer.NewTicker(0.1, PollSoftTargetState)
    -- Combat exit: synchronously restore all visHideNoTarget bar state drivers. During
    -- combat, ImmediateSoftTargetCheck and UpdateHousingVisibility are blocked by
    -- InCombatLockdown. If a bar's driver was overridden to "hide" (soft-target
    -- override) before combat started, it stays stuck the entire fight. The shared
    -- visibility dispatcher uses a double-deferred path that can miss rapid combat
    -- re-entry; this handler runs at the exact frame lockdown lifts, with no deferral,
    -- guaranteeing restoration.
    do
        local regenFrame = ns.TakeShell()
        regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        regenFrame:SetScript("OnEvent", function()
            for _, info in ipairs(ALL_BARS) do
                local s = self.db.profile.bars[info.key]
                if s and (s.visHideNoTarget or (s.visHideWithTarget and s.visibilityMatch == "any"))
                    and not (self._visOverride and self._visOverride[info.key]) then
                    local frame = barFrames[info.key]
                    if frame then
                        local newStr = BuildVisibilityString(info, s)
                        if frame._eabLastVisStr ~= newStr then
                            frame._eabLastVisStr = newStr
                            RegisterAttributeDriver(frame, "state-visibility", newStr)
                        end
                    end
                end
            end
        end)
    end

    -- Grid hide: restore empty slot visibility
    local function OnGridHide()
        _gridState.shown = false

        -- Clear the game event showgrid flag on all managed buttons
        if not InCombatLockdown() then
            for _, info in ipairs(BAR_CONFIG) do
                if not info.isStance and not info.isPetBar then
                    local btns = barButtons[info.key]
                    if btns then
                        for _, btn in ipairs(btns) do
                            if btn then
                                SetShowGridInsecure(btn, false, SHOWGRID.GAME_EVENT)
                            end
                        end
                    end
                end
            end
        end

        -- Defer visibility update by one frame so ACTIONBAR_SLOT_CHANGED
        -- processes first. Without this, a spell dropped onto a previously
        -- empty slot is not yet registered when ApplyAlwaysShowButtons runs,
        -- causing the button to be hidden as empty.
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            -- The grid show force-showed buttons, so the stamps no longer
            -- reflect button state and every bar must re-assert.
            if ns._asbStamp then wipe(ns._asbStamp) end
            for _, info2 in ipairs(BAR_CONFIG) do
                self:ApplyAlwaysShowButtons(info2.key)
            end
        end)

        -- Restore mouseover fade on bars that were forced visible during drag.
        -- Only needed if a real cursor drag happened (CURSOR_CHANGED forced them).
        -- _gridState tracks whether forcing occurred via the CURSOR_CHANGED path.
        if _gridState._mouseoverForced then
            _gridState._mouseoverForced = false
            for _, info in ipairs(BAR_CONFIG) do
                local s = EAB.db.profile.bars[info.key]
                if s and s.mouseoverEnabled then
                    local state = hoverStates[info.key]
                    if state and not state.isHovered then
                        EAB_VTABLE.Hover.FadeOut(info.key, state)
                    end
                end
            end
        end
        -- Re-hide Never bars surfaced by Show All During Drag.
        EAB._RestoreDragNeverBars()
    end
    _gridState.hideFns[#_gridState.hideFns + 1] = OnGridHide
    self:RegisterEvent("ACTIONBAR_HIDEGRID", function() ns.EABQueueGrid(false) end)
    self:RegisterEvent("PET_BAR_HIDEGRID", function() ns.EABQueueGrid(false) end)

    -- Spell updates: refresh button icons and visibility
    -- Also re-layout the stance bar since GetNumShapeshiftForms() may have changed
    self:RegisterEvent("SPELLS_CHANGED", function()
        if _gridState.spellsPending then return end
        _gridState.spellsPending = true
        C_Timer_After(0, function()
            _gridState.spellsPending = false
            LayoutBar("StanceBar")
            self:RefreshRuntimeVisibility() -- form count may have changed; re-eval stance bar show/hide
            -- Content-signature gate: SPELLS_CHANGED also fires mid-combat on
            -- spell-override flips (proc morphs), where slot CONTENTS are identical and
            -- the full AlwaysShow + ForceButtonRefresh sweep below (~140 buttons;
            -- measured 4.6ms + 1.7ms in one storm frame) repaints nothing new -- the
            -- icon/override branches already own morph visuals. A cheap GetActionInfo
            -- sweep proves whether contents actually changed; only a real change (spec
            -- swap, learn/unlearn) pays the heal this pass exists for. Secret ids
            -- (instanced combat) stamp as "?" -- stable -- and genuine combat content
            -- swaps still repaint via SLOT_CHANGED's own targeted path. PER-BUTTON
            -- DELTA: the aggregate signature could only say "something changed" -- and
            -- a single spell TRANSFORM legitimately changes it (GetActionInfo reports
            -- the override), so every mid-combat transform paid the full ~140-button
            -- ForceButtonRefresh + per-bar AlwaysShow response (measured
            -- 1.68ms + 0.53ms in one frame) to heal 1-2 slots. The same walk
            -- that builds the signature now also diffs a per-button token, so
            -- the heal touches exactly the changed buttons. The full sweep
            -- survives only for the cold start (nil signature: reload/profile
            -- flip/Never-set change), where "everything changed" is true.
            local sig = {}
            local isSecQ = issecretvalue
            local coldStart = ns._eabSpellsSig == nil
            local changed, changedBars
            for _, info in ipairs(BAR_CONFIG) do
                if not info.isStance and not info.isPetBar
                    and not ns._eabBarNever[info.key] then
                    local btns = barButtons[info.key]
                    if btns then
                        for _, btn in ipairs(btns) do
                            if btn then
                                local a = btn:GetAttribute("action")
                                local t2, id, st
                                if a then t2, id, st = GetActionInfo(a) end
                                local tok
                                if isSecQ and (isSecQ(t2) or isSecQ(id) or isSecQ(st)) then
                                    tok = "?"
                                else
                                    tok = (t2 or "-") .. (id or 0) .. (st or "")
                                end
                                sig[#sig + 1] = tok
                                local fd = EFD(btn)
                                if fd.spellsTok ~= tok then
                                    fd.spellsTok = tok
                                    if not coldStart then
                                        if not changed then
                                            changed = {}
                                            changedBars = {}
                                        end
                                        changed[#changed + 1] = btn
                                        changedBars[info.key] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
            sig = table.concat(sig, ",")
            if sig == ns._eabSpellsSig then return end
            ns._eabSpellsSig = sig
            if not coldStart then
                -- Targeted heal: only the buttons whose content token
                -- changed, and only their bars' AlwaysShow passes.
                if changed then
                    for key in pairs(changedBars) do
                        self:ApplyAlwaysShowButtons(key)
                    end
                    for i = 1, #changed do
                        local btn = changed[i]
                        EAB_VTABLE.ForceButtonRefresh(btn, btn:GetAttribute("action"))
                    end
                end
                return
            end
            for _, info in ipairs(BAR_CONFIG) do
                self:ApplyAlwaysShowButtons(info.key)
            end
            -- Force visual refresh on all action buttons. Spec swap changes which
            -- spells occupy each slot; the C-side ACTIONBAR_SLOT_CHANGED handler may
            -- not fire UpdateAction on our EABButton frames. Without this, cooldown
            -- swipes (including GCD) can disappear after swap. A spec swap changes slot
            -- CONTENTS while slot numbers stay identical, so this needs the forced
            -- refresh path (ForceButtonRefresh; also handles the secret-safe variant).
            for _, info in ipairs(BAR_CONFIG) do
                if not info.isStance and not info.isPetBar
                    and not ns._eabBarNever[info.key] then
                    local btns = barButtons[info.key]
                    if btns then
                        for _, btn in ipairs(btns) do
                            if btn then
                                EAB_VTABLE.ForceButtonRefresh(btn, btn:GetAttribute("action"))
                            end
                        end
                    end
                end
            end
        end)
    end)

    -- Slot changed: update visibility when a spell is placed/removed from a slot.
    -- This can fire per-slot (12+ times during a bar page swap), so use the
    -- shared debounced visibility queue.
    self:RegisterEvent("ACTIONBAR_SLOT_CHANGED", QueueAlwaysShowButtonsRefresh)

    -- Pet bar: re-layout and refresh visibility when the pet's action bar changes.
    -- PET_BAR_UPDATE covers ability changes; PET_UI_UPDATE covers summoning/dismissal;
    -- UNIT_PET covers pet swaps. PLAYER_ENTERING_WORLD ensures button state is
    -- populated on login (PetActionBar was unregistered from all events, so Blizzard's
    -- own update never fires). PET_BAR_UPDATE_USABLE fires when action usability
    -- changes so icon dimming stays current; UNIT_AURA "pet" can also affect usability.
    -- Coalesced: any event burst schedules ONE deferred pass per frame through a cached
    -- closure. "full" absorbs "cd": every full path repaints cooldowns too. A hidden
    -- pet bar skips all of it -- the secure
    -- [pet] driver keeps visibility correct engine-side -- and the show edge
    -- reconciles with one full pass (ns._eabPetReconcile).
    local _petPendingKind = nil  -- nil | "cd" | "full"
    local PetBarDeferred
    PetBarDeferred = function()
        local kind = _petPendingKind
        _petPendingKind = nil
        if not kind then return end
        do
            if kind == "cd" then
                -- Cooldown-only path: safe during combat, no taint risk.
                -- Update each button's cooldown frame directly.
                for i = 1, NUM_PET_ACTION_SLOTS do
                    local btn = _G["PetActionButton" .. i]
                    if btn and btn.cooldown then
                        local start, duration, enable = GetPetActionCooldown(i)
                        CooldownFrame_Set(btn.cooldown, start, duration, enable)
                    end
                end
                return
            end
            if InCombatLockdown() then
                -- Combat-safe path: update textures and visual state per-button
                -- without touching protected frame operations (Show/Hide/SetParent).
                -- This allows pet abilities to appear when summoning a pet mid-combat.
                local hasPetBar = PetHasActionBar()
                for i = 1, NUM_PET_ACTION_SLOTS do
                    local btn = _G["PetActionButton" .. i]
                    if btn then
                        local name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled = GetPetActionInfo(i)
                        if hasPetBar and texture then
                            if isToken then btn.icon:SetTexture(_G[texture])
                            else btn.icon:SetTexture(texture) end
                            -- Dim icon when the ability is not currently usable.
                            local usable = GetPetActionSlotUsable(i)
                            local shade = usable and 1 or 0.4
                            btn.icon:SetVertexColor(shade, shade, shade)
                            btn.icon:Show()
                            -- AutoCastOverlay (AutoCastOverlayMixin) replaced the old
                            -- AutoCastShine API in modern WoW. SetShown controls the
                            -- corner-ring frame; ShowAutoCastEnabled starts/stops the
                            -- rotating shine animation.
                            if btn.AutoCastOverlay then
                                btn.AutoCastOverlay:SetShown(autoCastAllowed)
                                btn.AutoCastOverlay:ShowAutoCastEnabled(autoCastEnabled)
                            end
                        else
                            btn.icon:Hide()
                            if btn.AutoCastOverlay then btn.AutoCastOverlay:Hide() end
                        end
                        -- Reflect the active state so pet mode buttons (Passive /
                        -- Assist / Defend) highlight the currently selected mode.
                        -- Attack actions flash instead of showing the full highlight.
                        -- SetChecked / StartFlash / StopFlash are visual-only and safe
                        -- to call during combat lockdown.
                        local ct = btn:GetCheckedTexture()
                        local ctA = EAB:GetCheckedAlpha("PetBar")
                        if isActive then
                            if IsPetAttackAction(i) then
                                btn:StartFlash()
                                if ct then ct:SetAlpha(0.5 * ctA) end
                            else
                                btn:StopFlash()
                                if ct then ct:SetAlpha(1.0 * ctA) end
                            end
                            btn:SetChecked(true)
                        else
                            btn:StopFlash()
                            btn:SetChecked(false)
                        end
                        -- Update cooldown
                        if btn.cooldown then
                            local start, duration, enable = GetPetActionCooldown(i)
                            CooldownFrame_Set(btn.cooldown, start, duration, enable)
                        end
                    end
                end
                return
            end
            -- Full update path: only safe out of combat.
            if _gridState.shown then
                -- During a spell drag, skip PetActionBar:Update() which
                -- hides empty slots. Just refresh textures per-button so
                -- the vacated slot clears its icon while the grid stays.
                for i = 1, NUM_PET_ACTION_SLOTS do
                    local btn = _G["PetActionButton" .. i]
                    if btn then
                        local name, texture, isToken = GetPetActionInfo(i)
                        if texture then
                            if isToken then btn.icon:SetTexture(_G[texture])
                            else btn.icon:SetTexture(texture) end
                            btn.icon:Show()
                        else
                            btn.icon:Hide()
                        end
                    end
                end
                return
            end
            if PetActionBar and PetActionBar.Update then
                PetActionBar:Update()
            end
            -- Layout only when the populated-slot SHAPE changed (summon,
            -- dismiss, swap): re-laying the whole bar per aura/usable event
            -- was the pet handler's dominant cost. Every shape-changing
            -- input fires one of the registered pet events, so the memo
            -- cannot strand; settings changes lay out via ApplyAll directly.
            local sig = PetHasActionBar() and "p" or "n"
            for i = 1, NUM_PET_ACTION_SLOTS do
                sig = sig .. (GetPetActionInfo(i) and "1" or "0")
            end
            if sig ~= ns._eabPetLayoutSig then
                ns._eabPetLayoutSig = sig
                LayoutBar("PetBar")
                self:ApplyAlwaysShowButtons("PetBar")
            end
            -- Re-register the state driver so the [pet] condition is always
            -- current after a pet summon, swap, or dismissal.
            local petInfo = BAR_LOOKUP["PetBar"]
            local petFrame = barFrames["PetBar"]
            local petS = self.db.profile.bars["PetBar"]
            -- Not while a runtime rule owns the driver (a surfacing override from
            -- the toggle keybind or the spellbook, or Hide Bar When Using
            -- Gamepad): RefreshRuntimeVisibility registered that string (an
            -- override keeps the [pet] term), and a plain rebuild here would
            -- stomp it on the reveal's own reconcile pass.
            if petInfo and petFrame and petS and not petS.alwaysHidden
               and not (self._visOverride and self._visOverride.PetBar)
               and not (self._padHide and petS.gamepadHideBar == true) then
                RegisterAttributeDriver(petFrame, "state-visibility", BuildVisibilityString(petInfo, petS))
            end
        end
    end
    local function UpdatePetBar(_, event)
        -- Hidden pet bar: skip entirely. The [pet] visibility driver
        -- evaluates engine-side regardless, and the show edge runs a full
        -- reconcile pass, so nothing here can be missed.
        local pf = barFrames["PetBar"]
        if pf and not pf:IsVisible() then return end
        local kind = (event == "PET_BAR_UPDATE_COOLDOWN") and "cd" or "full"
        local prev = _petPendingKind
        _petPendingKind = (kind == "full" or prev == "full") and "full" or "cd"
        if not prev then C_Timer_After(0, PetBarDeferred) end
    end
    -- Bar-reveal reconcile (ApplyBarDormancy show edge): one full pass
    -- covers everything the hidden-skip above dropped.
    ns._eabPetReconcile = function()
        local prev = _petPendingKind
        _petPendingKind = "full"
        if not prev then C_Timer_After(0, PetBarDeferred) end
    end
    local _petEventFrame = ns.TakeShell()
    _petEventFrame:RegisterEvent("PET_BAR_UPDATE")
    _petEventFrame:RegisterEvent("PET_BAR_UPDATE_COOLDOWN")
    EUI_SafeRegisterEvent(_petEventFrame, "PET_BAR_UPDATE_USABLE")
    _petEventFrame:RegisterEvent("PET_UI_UPDATE")
    _petEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    _petEventFrame:RegisterUnitEvent("UNIT_PET", "player")
    _petEventFrame:RegisterUnitEvent("UNIT_AURA", "pet")
    _petEventFrame:SetScript("OnEvent", UpdatePetBar)

    -- StanceBarMixin:UpdateState owns Blizzard's active highlight and cooldown
    -- swipe, but HideBlizzardBars unregisters that bar's events. Reconcile both
    -- visuals on the reused buttons without invoking the hidden bar's layout
    -- or visibility updates. SetChecked and CooldownFrame_Set are visual-only,
    -- matching the pet bar painter above.
    -- Per-form memo of the last (start, duration, enable) triple pushed. The
    -- cooldown event refires on every GCD for form classes and the swipe is a
    -- pure function of those three values, so an identical triple is skipped.
    -- Invalidation inputs, each named: the triple itself (compared per
    -- form); the form list and the world enter (their events wipe the memo);
    -- the show-edge reconcile (the hidden bar may have been repainted by
    -- anything meanwhile -- its no-event call wipes too). Secret values
    -- (instanced combat) cannot be compared: that form pushes unconditionally
    -- and drops its memo.
    local stanceLast = {}
    local function UpdateStanceState(_, event)
        if event ~= "UPDATE_SHAPESHIFT_COOLDOWN" then wipe(stanceLast) end
        -- Hidden stance bar: skip. The show edge reruns this painter
        -- (ns._eabStanceReconcile), and the event refires every GCD for
        -- form classes, so nothing can stay stale while visible.
        local sf = barFrames["StanceBar"]
        if sf and not sf:IsVisible() then return end
        local numForms = GetNumShapeshiftForms()
        for i = 1, numForms do
            local btn = _G["StanceButton" .. i]
            if btn then
                -- Clicks toggle the checked state optimistically; reconcile it
                -- from the actual form even when the cooldown has not changed.
                local _, isActive = GetShapeshiftFormInfo(i)
                btn:SetChecked(isActive)
            end
            if btn and btn.cooldown then
                local start, duration, enable = GetShapeshiftFormCooldown(i)
                if issecretvalue and (issecretvalue(start) or issecretvalue(duration)
                                      or issecretvalue(enable)) then
                    stanceLast[i] = nil
                    CooldownFrame_Set(btn.cooldown, start, duration, enable)
                else
                    local m = stanceLast[i]
                    if not m or m[1] ~= start or m[2] ~= duration or m[3] ~= enable then
                        if not m then m = {}; stanceLast[i] = m end
                        m[1], m[2], m[3] = start, duration, enable
                        CooldownFrame_Set(btn.cooldown, start, duration, enable)
                    end
                end
            end
        end
    end
    ns._eabStanceReconcile = UpdateStanceState
    local _stanceEventFrame = ns.TakeShell()
    _stanceEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_COOLDOWN")
    _stanceEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    _stanceEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
    _stanceEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    _stanceEventFrame:SetScript("OnEvent", UpdateStanceState)


    -- Talent changes can cause Blizzard to re-show hidden bars.
    -- Re-run the hider and re-unregister events on the affected frames.
    -- The OnShow hooks below also catch this, but this is a safety net.
    EUI_SafeRegisterEvent(self, "PLAYER_TALENT_UPDATE", function()
        if InCombatLockdown() then return end
        for _, entry in ipairs(STOCK_BAR_DISPOSAL) do
            local bar = _G[entry.name]
            if bar then
                if not entry.retainEvents then
                    bar:UnregisterAllEvents()
                end
                -- No Hide(): see ReassertHiddenOnShow's note above
                -- hiddenParent's creation. Reparenting alone is enough.
                bar:SetParent(hiddenParent)
            end
        end
        -- Both event broadcasters are quieted at file-load time (top of file).
        -- Redundant quieting here as a safety net in case Blizzard re-creates
        -- them; the same helper, so Blizzard's two seeding registrations stay.
        if ns.QuietBroadcasters then ns.QuietBroadcasters() end
        -- ...then hand control back to the mode machine: this safety net can
        -- run after "full" has registered, so without the resync it silently
        -- drops that tick set while the mode check believes it is still active.
        if ns.ResyncBroadcaster then ns.ResyncBroadcaster() end
    end)

    -- Hook Show on stock bars so they can never re-appear regardless
    -- of what fires them (talent changes, spec swaps, zone transitions, etc.).
    -- ReassertHiddenOnShow reparents rather than Hide()s -- see its note above
    -- hiddenParent's creation.
    for _, entry in ipairs(STOCK_BAR_DISPOSAL) do
        local bar = _G[entry.name]
        if bar then
            ns.ReassertHiddenOnShow(bar)
        end
    end

    -- Register with unlock mode immediately. FinishSetup runs at
    -- PLAYER_LOGIN, inside the pre-lockdown window on a combat reload, so
    -- registering now (instead of on a timer) lets the position pass in
    -- DoVisuals resolve anchored elements before lockdown re-engages.
    -- (EllesmereUI is a hard dependency, so it is always loaded here.)
    RegisterWithUnlockMode()

    -- Apply visibility drivers now, for the same reason: the real conditional driver
    -- strings (e.g. PetBar's [pet]-gated visibility) must register before combat
    -- lockdown re-engages -- the secure state engine then evaluates them correctly
    -- even IN combat. ApplyAll's visibility pass is skipped while in combat, so
    -- without this call a combat reload left bars on their placeholder "show" driver
    -- (petless PetBar visible) until combat dropped. Idempotent out of combat: the
    -- _eabLastVisStr cache skips unchanged re-registrations, so the later ApplyAll
    -- pass is a no-op for these. Extra bars (built on a later timer) are nil-skipped
    -- here, exactly as on a normal login.
    -- Controller verdict first (Hide Bar When Using Gamepad): on a combat
    -- reload this is the last out-of-combat moment, and the first
    -- RefreshRuntimeVisibility only lands after lockdown is back.
    self._PadSync()
    self:ApplyCombatVisibility()
    self:UpdateVehicleBarWatch()

    -- Dormancy initial sync: bars that START hidden never fire an OnHide
    -- edge, and the creation-time OnHide fired before buttons existed. Runs
    -- after the visibility drivers above have settled each frame's state.
    -- The per-key memo makes this a no-op for anything the edges already handled.
    for _, info in ipairs(BAR_CONFIG) do
        local f = barFrames[info.key]
        if f then ns.ApplyBarDormancy(info.key, not f:IsVisible()) end
    end
end

-- Main-chunk locals the other EUI_ActionBars_*.lua files re-import by name
-- (EUI_ActionBars_DataBars.lua adds SetupDataBars for the extra bars file).
ns._internals = {
    BAR_CONFIG = BAR_CONFIG, BINDING_MAP = BINDING_MAP, BUTTON_EVENT_LISTS = BUTTON_EVENT_LISTS,
    ReRegisterButtonEvents = ReRegisterButtonEvents, barFrames = barFrames,
    _fadeAlpha = _fadeAlpha, extraBarHolders = extraBarHolders,
    dataBarFrames = dataBarFrames, blizzMovableHolders = blizzMovableHolders,
    BLIZZ_MOVABLE_OVERLAY = BLIZZ_MOVABLE_OVERLAY, hoverStates = hoverStates,
    AttachDataBarHoverHooks = AttachDataBarHoverHooks, _quickKeybindState = _quickKeybindState,
    FormatHotkeyText = FormatHotkeyText, StopFade = StopFade,
    SafeEnableMouse = SafeEnableMouse, SafeEnableMouseMotionOnly = SafeEnableMouseMotionOnly,
    ShouldQuickKeybindSurfaceBar = ShouldQuickKeybindSurfaceBar,
    SHOWGRID = SHOWGRID, SetShowGridInsecure = SetShowGridInsecure,
    SyncPagingAlpha = SyncPagingAlpha, InitPagingQuickKeybindButton = InitPagingQuickKeybindButton,
    FONT_PATH = FONT_PATH, LayoutBar = LayoutBar, buttonToBar = buttonToBar, _gridState = _gridState,
    ApplyButtonBorders = ApplyButtonBorders, ApplyShapeToButton = ApplyShapeToButton,
    NUM_ACTIONBAR_BUTTONS = NUM_ACTIONBAR_BUTTONS,
    barBaseSize = barBaseSize, SHAPE_EDGE_SCALES = SHAPE_EDGE_SCALES,
    GetButtonActionSlot = GetButtonActionSlot, MaskFrameTextures = MaskFrameTextures,
}
-- A re-import of a name this table lacks fails where the part file loads,
-- not later as a nil upvalue inside one of its functions.
setmetatable(ns._internals, { __index = function(_, k)
    error("ns._internals has no entry " .. tostring(k), 2)
end })
