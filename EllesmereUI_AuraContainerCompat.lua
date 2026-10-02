if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EUI_ClassicEnv then setfenv(1, EUI_ClassicEnv) end -- Classic Era port: suite-private API stand-ins (EllesmereUI_ClassicCompat.lua)
-------------------------------------------------------------------------------
--  EllesmereUI_AuraContainerCompat.lua
--
--  WoW Classic Era port: a Lua stand-in for the 12.1 engine aura container
--  (CreateFrame("AuraContainer", ..., "CustomAuraContainerTemplate")), which
--  that client does not have. Every aura display in the suite (nameplate,
--  unit frame, raid frame and Player Aura Bars icons) is built through
--  EllesmereUI_AuraKit.lua on top of that engine object, so this file
--  re-implements the slice of its API the suite uses, with the same method
--  names and call shapes:
--
--    container: SetFlowLayout{AnchorPoint,GrowthDirection,Padding,
--               MaximumLineSize,Axis}, SetAuraProcessingPolicy, AddAuraGroup,
--               SetAuraGroup{MaxFrameCount,CandidateFilters,Layout,
--               SortMethod,FilterString}, AddAuraSlot, SetAuraSlot{
--               FilterString,CandidateFilters}, SetUnit, GetUnit,
--               UpdateAllAuras
--    button:    SetIcon, SetDurationCooldown, SetApplicationCount,
--               SetDurationText, SetDurationBar, SetApplicationBar,
--               SetCancelAuraButtons
--
--  Aura data comes from C_UnitAuras.GetAuraDataByIndex. Classic Era has no
--  secret values, so everything is plain Lua. Filter tokens the client
--  cannot evaluate are approximated, honestly:
--    PLAYER, RAID, CANCELABLE, NOT_CANCELABLE  real (client filter strings)
--    RAID_PLAYER_DISPELLABLE                   read as RAID (what you can dispel)
--    INCLUDE_NAME_PLATE_ONLY, RAID_IN_COMBAT   no restriction
--    CROWD_CONTROL, BIG_DEFENSIVE, ...         no such flag: a group asking
--                                              for one shows only its
--                                              includeSpellIDs, else nothing;
--                                              "!TOKEN" excludes nothing
--  Sorting: Default = the client's own aura order, Expiration(Only) =
--  shortest remaining first (permanent last), Name(Only) = by name; every
--  other method falls back to Default. Reverse flips the order.
-------------------------------------------------------------------------------
local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end
-- Classic Era only: every other client has the engine container (and no
-- EUI_ClassicStubs, which this file writes its enum stand-ins into).
if not (EllesmereUI.IS_CLASSIC_ERA and EUI_ClassicStubs) then return end

local CreateFrame, GetTime, pairs, ipairs, type, tostring, math_floor, math_ceil, math_max =
      CreateFrame, GetTime, pairs, ipairs, type, tostring, math.floor, math.ceil, math.max
local GetAuraDataByIndex = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex

-------------------------------------------------------------------------------
--  Enum globals the consumers read (only filled when the client lacks them)
-------------------------------------------------------------------------------
if not AuraContainerSortMethod then
    EUI_ClassicStubs.AuraContainerSortMethod = { Default = 0, BigDefensive = 1, UnitFrameDebuff = 2, ImportantOnly = 3,
        Expiration = 4, ExpirationOnly = 5, Name = 6, NameOnly = 7, AuraInstanceIDOnly = 8 }
end
if not AuraContainerSortDirection then
    EUI_ClassicStubs.AuraContainerSortDirection = { Normal = 0, Reverse = 1 }
end
if not CustomAuraContainerAuraProcessingPolicy then
    EUI_ClassicStubs.CustomAuraContainerAuraProcessingPolicy = { ProcessAura = 1 }
end
if not AnchorUtil.FlowDirection then
    AnchorUtil.FlowDirection = { Right = 1, Left = 2, Up = 3, Down = 4 }
end
local FD = AnchorUtil.FlowDirection
local SORT, SORT_DIR = AuraContainerSortMethod, AuraContainerSortDirection

-------------------------------------------------------------------------------
--  Filter parsing (cached per filter string)
-------------------------------------------------------------------------------
local REAL = { PLAYER = "PLAYER", RAID = "RAID", CANCELABLE = "CANCELABLE",
    NOT_CANCELABLE = "NOT_CANCELABLE", RAID_PLAYER_DISPELLABLE = "RAID" }
local IGNORED = { INCLUDE_NAME_PLATE_ONLY = true, RAID_IN_COMBAT = true }

local parsedFilters = {}
local function ParseFilter(str)
    str = str or "HELPFUL"
    local p = parsedFilters[str]
    if p then return p end
    p = { base = "HELPFUL", real = {}, neg = {}, unknown = false }
    for token in string.gmatch(str, "[^|]+") do
        if token == "HELPFUL" or token == "HARMFUL" then
            p.base = token
        elseif token:sub(1, 1) == "!" then
            local t = REAL[token:sub(2)]
            if t then p.neg[#p.neg + 1] = t end
        elseif REAL[token] then
            p.real[#p.real + 1] = REAL[token]
        elseif not IGNORED[token] then
            p.unknown = true
        end
    end
    parsedFilters[str] = p
    return p
end

-- Candidate filter lookups accept both { [id] = true } sets and { id, id } arrays.
local function NormalizeIDs(t)
    if type(t) ~= "table" then return nil end
    local out, any = {}, false
    for k, v in pairs(t) do
        if v == true then out[k] = true; any = true
        elseif type(v) == "number" then out[v] = true; any = true
        elseif type(k) == "number" and v then out[k] = true; any = true end
    end
    return any and out or nil
end

local function NormalizeCand(c)
    if type(c) ~= "table" then return nil end
    return {
        include = NormalizeIDs(c.includeSpellIDs),
        exclude = NormalizeIDs(c.excludeSpellIDs),
        incDispel = c.includeDispelTypes,
        excDispel = c.excludeDispelTypes,
        maxDuration = c.maxDuration,
        fromPlayer = c.isFromPlayerOrPlayerPet,
    }
end

-------------------------------------------------------------------------------
--  Per-update aura scan cache (one pass per container update)
-------------------------------------------------------------------------------
local function ScanBase(unit, base)
    local list = {}
    if not GetAuraDataByIndex then return list end
    for i = 1, 40 do
        local a = GetAuraDataByIndex(unit, i, base)
        if not a then break end
        a._euiIndex = i
        a._euiFilter = base
        list[#list + 1] = a
    end
    return list
end

local function ScanSet(unit, filter)
    local set = {}
    if not GetAuraDataByIndex then return set end
    for i = 1, 40 do
        local a = GetAuraDataByIndex(unit, i, filter)
        if not a then break end
        if a.auraInstanceID then set[a.auraInstanceID] = true end
        if a.spellId then set["s" .. a.spellId .. ":" .. (a.expirationTime or 0)] = true end
    end
    return set
end

local function SetKey(a)
    return a.auraInstanceID or ("s" .. tostring(a.spellId) .. ":" .. (a.expirationTime or 0))
end

local function Matches(a, p, cand, scan)
    local sid = a.spellId
    if p.unknown and not (cand and cand.include) then return false end
    for i = 1, #p.real do
        local tok = p.real[i]
        if tok == "PLAYER" then
            if not a.isFromPlayerOrPlayerPet and a.sourceUnit ~= "player" and a.sourceUnit ~= "pet" then return false end
        elseif not scan.set(p.base .. "|" .. tok)[SetKey(a)] then
            return false
        end
    end
    for i = 1, #p.neg do
        local tok = p.neg[i]
        if tok == "PLAYER" then
            if a.isFromPlayerOrPlayerPet or a.sourceUnit == "player" or a.sourceUnit == "pet" then return false end
        elseif scan.set(p.base .. "|" .. tok)[SetKey(a)] then
            return false
        end
    end
    if cand then
        if cand.include and not cand.include[sid] then return false end
        if cand.exclude and cand.exclude[sid] then return false end
        local dt = a.dispelName
        if cand.incDispel and not (dt and cand.incDispel[dt]) then return false end
        if cand.excDispel and dt and cand.excDispel[dt] then return false end
        if cand.maxDuration then
            local d = a.duration or 0
            if d == 0 or d > cand.maxDuration then return false end
        end
        if cand.fromPlayer ~= nil then
            local mine = a.isFromPlayerOrPlayerPet and true or false
            if mine ~= cand.fromPlayer then return false end
        end
    end
    return true
end

local function Remaining(a, now)
    local e = a.expirationTime or 0
    if e <= 0 then return math.huge end
    return e - now
end

local function SortList(list, method, direction)
    local now = GetTime()
    local cmp
    if method == SORT.Expiration or method == SORT.ExpirationOnly then
        cmp = function(x, y)
            local rx, ry = Remaining(x, now), Remaining(y, now)
            if rx ~= ry then return rx < ry end
            return x._euiIndex < y._euiIndex
        end
    elseif method == SORT.Name or method == SORT.NameOnly then
        cmp = function(x, y)
            local nx, ny = x.name or "", y.name or ""
            if nx ~= ny then return nx < ny end
            return x._euiIndex < y._euiIndex
        end
    else
        cmp = function(x, y) return x._euiIndex < y._euiIndex end
    end
    if direction == SORT_DIR.Reverse then
        local base = cmp
        cmp = function(x, y) return base(y, x) end
    end
    table.sort(list, cmp)
end

-------------------------------------------------------------------------------
--  Duration text formatting
-------------------------------------------------------------------------------
local function FallbackFormat(sec)
    if sec < 60 then return tostring(math_ceil(sec)) end
    if sec < 3600 then return math_floor(sec / 60 + 0.5) .. "m" end
    if sec < 86400 then return math_floor(sec / 3600 + 0.5) .. "h" end
    return math_floor(sec / 86400 + 0.5) .. "d"
end

local function FormatWith(formatter, sec)
    if type(formatter) == "table" or type(formatter) == "userdata" then
        for _, m in ipairs({ "Format", "FormatValue", "FormatNumber" }) do
            local fn = formatter[m]
            if type(fn) == "function" then
                local ok, s = pcall(fn, formatter, sec)
                if ok and type(s) == "string" then return s end
            end
        end
    end
    return FallbackFormat(sec)
end

-------------------------------------------------------------------------------
--  Aura buttons
-------------------------------------------------------------------------------
local ButtonMethods = {}

function ButtonMethods:SetIcon(tex) self._euiIcon = tex end
function ButtonMethods:SetDurationCooldown(cd) self._euiCD = cd end
function ButtonMethods:SetApplicationCount(fs, opts) self._euiCount = fs; self._euiCountOpts = opts end
function ButtonMethods:SetDurationText(fs, opts)
    self._euiDurText = fs
    local o = opts or {}
    self._euiFormatter = o.textFormatter or (o.binding and o.binding._formatter) or nil
end
function ButtonMethods:SetDurationBar(bar, opts) self._euiDurBar = bar; self._euiDurBarOpts = opts end
function ButtonMethods:SetApplicationBar(bar, opts)
    self._euiAppBar = bar
    self._euiAppMax = (opts and opts.maxApplications) or 1
    if bar and bar.SetMinMaxValues then bar:SetMinMaxValues(0, self._euiAppMax) end
end
function ButtonMethods:SetCancelAuraButtons(token) self._euiCancel = token end

local function UpdateTimers(b, now)
    local a = b._euiAura
    if not a then return end
    local dur, exp = a.duration or 0, a.expirationTime or 0
    local rem = (exp > 0) and (exp - now) or 0
    if b._euiDurText then
        if dur > 0 and rem > 0 then
            b._euiDurText:SetText(FormatWith(b._euiFormatter, rem))
        else
            b._euiDurText:SetText("")
        end
    end
    local bar = b._euiDurBar
    if bar and bar.SetValue then
        bar:SetMinMaxValues(0, 1)
        bar:SetValue((dur > 0 and rem > 0) and (rem / dur) or (dur == 0 and 1 or 0))
    end
end

local function ButtonOnUpdate(b, elapsed)
    b._euiElapsed = (b._euiElapsed or 0) + elapsed
    if b._euiElapsed < 0.1 then return end
    b._euiElapsed = 0
    UpdateTimers(b, GetTime())
end

local function ButtonOnEnter(b)
    local a, c = b._euiAura, b._euiContainer
    if not (a and c and c._euiUnit) then return end
    GameTooltip:SetOwner(b, "ANCHOR_BOTTOMRIGHT")
    if GameTooltip.SetUnitAura then
        GameTooltip:SetUnitAura(c._euiUnit, a._euiIndex, a._euiFilter)
    elseif a.spellId then
        GameTooltip:SetSpellByID(a.spellId)
    end
    GameTooltip:Show()
end

local function ButtonOnLeave() GameTooltip:Hide() end

local function ButtonOnClick(b, mouseButton)
    if mouseButton ~= "RightButton" or not b._euiCancel then return end
    local a, c = b._euiAura, b._euiContainer
    if not (a and c and c._euiUnit) or InCombatLockdown() then return end
    if a._euiFilter == "HELPFUL" and CancelUnitBuff then
        CancelUnitBuff(c._euiUnit, a._euiIndex, a._euiFilter)
    end
end

local function NewButton(container, initializeFrame)
    local b = CreateFrame("Button", nil, container)
    for k, fn in pairs(ButtonMethods) do b[k] = fn end
    b._euiContainer = container
    b:SetSize(20, 20)
    b:RegisterForClicks("RightButtonUp")
    b:SetScript("OnEnter", ButtonOnEnter)
    b:SetScript("OnLeave", ButtonOnLeave)
    b:SetScript("OnClick", ButtonOnClick)
    b:SetScript("OnUpdate", ButtonOnUpdate)
    b:Hide()
    if initializeFrame then
        local ok, err = pcall(initializeFrame, b)
        if not ok then geterrorhandler()(err) end
    end
    return b
end

local function ShowAura(b, a)
    b._euiAura = a
    if b._euiIcon then b._euiIcon:SetTexture(a.icon) end
    local cd = b._euiCD
    if cd then
        local dur, exp = a.duration or 0, a.expirationTime or 0
        if dur > 0 and exp > 0 then
            cd:SetCooldown(exp - dur, dur)
            cd:Show()
        elseif cd.Clear then
            cd:Clear()
        end
    end
    local n = a.applications or 0
    if b._euiCount then b._euiCount:SetText(n > 1 and n or "") end
    if b._euiAppBar and b._euiAppBar.SetValue then b._euiAppBar:SetValue(math.min(n, b._euiAppMax or n)) end
    UpdateTimers(b, GetTime())
    b:Show()
end

local function HideButton(b)
    b._euiAura = nil
    b:Hide()
end

-------------------------------------------------------------------------------
--  Container
-------------------------------------------------------------------------------
local unitContainers = {}   -- [unit] = { [container] = true }
local dirty = {}
local pump = CreateFrame("Frame")
pump:Hide()

local function MarkDirty(c)
    dirty[c] = true
    pump:Show()
end

local function MarkUnit(unit)
    local set = unit and unitContainers[unit]
    if not set then return end
    for c in pairs(set) do MarkDirty(c) end
end

local function LayoutContainer(c)
    local horizontal = not c._euiVertical
    local maxLine = c._euiMaxLine
    local padL, padR, padT, padB = c._euiPadL, c._euiPadR, c._euiPadT, c._euiPadB
    local u, v, thick, maxU = 0, 0, 0, 0
    local lineHasContent = false
    local placed = {}
    for gi = 1, #c._euiOrder do
        local g = c._euiOrder[gi]
        local shown = g.shownCount or 0
        if shown > 0 then
            local L = g.layout or {}
            local es = L.elementSpacing or 2
            local ls = L.lineSpacing or 2
            if lineHasContent then
                if L.forceNewLine then
                    v = v + thick + (L.groupLineSpacing or ls); u = 0; thick = 0
                    lineHasContent = false
                else
                    u = u + (L.groupSpacing or es)
                end
            end
            for i = 1, shown do
                local b = g.frames[i]
                local w = L.elementWidth or b:GetWidth()
                local h = L.elementHeight or b:GetHeight()
                local along, across = w, h
                if not horizontal then along, across = h, w end
                if maxLine and lineHasContent and u + along > maxLine then
                    v = v + thick + ls; u = 0; thick = 0
                end
                placed[#placed + 1] = { b, u, v }
                u = u + along
                if u > maxU then maxU = u end
                u = u + es
                if across > thick then thick = across end
                lineHasContent = true
            end
        end
    end
    local totalU, totalV = maxU, v + thick
    local sx = (c._euiGrowthH == FD.Left) and -1 or 1
    local sy = (c._euiGrowthV == FD.Up) and 1 or -1
    local anchor = c._euiAnchor or "TOPLEFT"
    for i = 1, #placed do
        local p = placed[i]
        local x, y = p[2], p[3]
        if not horizontal then x, y = p[3], p[2] end
        p[1]:ClearAllPoints()
        p[1]:SetPoint(anchor, c, anchor, sx * (padL + x), sy * (padT + y))
    end
    local W, H = totalU, totalV
    if not horizontal then W, H = totalV, totalU end
    c:SetSize(math_max(1, W + padL + padR), math_max(1, H + padT + padB))
end

local function UpdateContainer(c)
    local unit = c._euiUnit
    local exists = unit and UnitExists(unit)
    local baseCache, setCache = {}, {}
    local scan = {
        base = function(base)
            local l = baseCache[base]
            if not l then l = exists and ScanBase(unit, base) or {}; baseCache[base] = l end
            return l
        end,
        set = function(filter)
            local s = setCache[filter]
            if not s then s = exists and ScanSet(unit, filter) or {}; setCache[filter] = s end
            return s
        end,
    }
    local function Collect(p, cand, method, direction, max)
        local out = {}
        if not exists or max <= 0 then return out end
        for _, a in ipairs(scan.base(p.base)) do
            if Matches(a, p, cand, scan) then out[#out + 1] = a end
        end
        SortList(out, method, direction)
        return out
    end
    for gi = 1, #c._euiOrder do
        local g = c._euiOrder[gi]
        local max = g.maxFrameCount or 0
        local list = Collect(g.parsed, g.cand, g.sortMethod, g.sortDirection, max)
        local n = math.min(#list, max)
        for i = 1, n do
            local b = g.frames[i]
            if not b then b = NewButton(c, g.init); g.frames[i] = b end
            ShowAura(b, list[i])
        end
        for i = n + 1, #g.frames do HideButton(g.frames[i]) end
        g.shownCount = n
    end
    for _, s in pairs(c._euiSlots) do
        local list = Collect(s.parsed, s.cand, s.sortMethod, s.sortDirection, 1)
        if list[1] then ShowAura(s.frame, list[1]) else HideButton(s.frame) end
    end
    LayoutContainer(c)
end

pump:SetScript("OnUpdate", function(self)
    self:Hide()
    local work = dirty
    dirty = {}
    for c in pairs(work) do
        local ok, err = pcall(UpdateContainer, c)
        if not ok then geterrorhandler()(err) end
    end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("UNIT_PET")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
EUI_SafeRegisterEvent(events, "PLAYER_FOCUS_CHANGED")
events:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" or event == "NAME_PLATE_UNIT_ADDED" then
        MarkUnit(unit)
    elseif event == "PLAYER_TARGET_CHANGED" then
        MarkUnit("target"); MarkUnit("targettarget")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        MarkUnit("focus"); MarkUnit("focustarget")
    elseif event == "UNIT_PET" then
        MarkUnit("pet")
        if unit then MarkUnit(unit .. "pet") end
    else
        for _, set in pairs(unitContainers) do
            for c in pairs(set) do MarkDirty(c) end
        end
    end
end)

local ContainerMethods = {}

-- Flow layout setters (both API generations' names).
function ContainerMethods:SetFlowLayoutAnchorPoint(point) self._euiAnchor = point; MarkDirty(self) end
function ContainerMethods:SetFlowLayoutGrowthDirection(h, v)
    self._euiGrowthH, self._euiGrowthV = h, v; MarkDirty(self)
end
function ContainerMethods:SetFlowLayoutPadding(l, r, t, b)
    self._euiPadL, self._euiPadR, self._euiPadT, self._euiPadB = l or 0, r or 0, t or 0, b or 0
    MarkDirty(self)
end
function ContainerMethods:SetFlowLayoutMaximumLineSize(n) self._euiMaxLine = n; MarkDirty(self) end
function ContainerMethods:SetFlowLayoutAxis(axis)
    local axes = AnchorUtil.FlowLayoutAxis
    self._euiVertical = axes and axis == axes.Vertical or false
    MarkDirty(self)
end
ContainerMethods.SetAuraLayoutAnchorPoint = ContainerMethods.SetFlowLayoutAnchorPoint
ContainerMethods.SetAuraLayoutGrowthDirection = ContainerMethods.SetFlowLayoutGrowthDirection
ContainerMethods.SetAuraLayoutPadding = ContainerMethods.SetFlowLayoutPadding
ContainerMethods.SetAuraLayoutRowWidth = ContainerMethods.SetFlowLayoutMaximumLineSize

function ContainerMethods:SetAuraProcessingPolicy() end

local function ReorderGroups(c)
    local order = {}
    for i = 1, #c._euiGroupList do order[i] = c._euiGroupList[i] end
    table.sort(order, function(x, y)
        local lx = (x.layout and x.layout.layoutIndex) or x.addIndex
        local ly = (y.layout and y.layout.layoutIndex) or y.addIndex
        if lx ~= ly then return lx < ly end
        return x.addIndex < y.addIndex
    end)
    c._euiOrder = order
end

function ContainerMethods:AddAuraGroup(key, filter, opts)
    opts = opts or {}
    local g = self._euiGroups[key]
    if not g then
        g = { key = key, frames = {}, addIndex = #self._euiGroupList + 1 }
        self._euiGroups[key] = g
        self._euiGroupList[#self._euiGroupList + 1] = g
    end
    g.parsed = ParseFilter(filter)
    g.maxFrameCount = opts.maxFrameCount or 10
    g.sortMethod, g.sortDirection = opts.sortMethod, opts.sortDirection
    g.cand = NormalizeCand(opts.candidateFilters)
    g.init = opts.initializeFrame
    g.layout = opts.layout
    ReorderGroups(self)
    MarkDirty(self)
end

local function Group(c, key) return c._euiGroups[key] end

function ContainerMethods:SetAuraGroupMaxFrameCount(key, n)
    local g = Group(self, key); if not g then return end
    g.maxFrameCount = n or 0; MarkDirty(self)
end
function ContainerMethods:SetAuraGroupCandidateFilters(key, cand)
    local g = Group(self, key); if not g then return end
    g.cand = NormalizeCand(cand); MarkDirty(self)
end
function ContainerMethods:SetAuraGroupLayout(key, layout)
    local g = Group(self, key); if not g then return end
    g.layout = layout; ReorderGroups(self); MarkDirty(self)
end
function ContainerMethods:SetAuraGroupSortMethod(key, method, direction)
    local g = Group(self, key); if not g then return end
    g.sortMethod, g.sortDirection = method, direction; MarkDirty(self)
end
function ContainerMethods:SetAuraGroupFilterString(key, filter)
    local g = Group(self, key); if not g then return end
    g.parsed = ParseFilter(filter); MarkDirty(self)
end

function ContainerMethods:AddAuraSlot(key, filter, opts)
    opts = opts or {}
    local s = self._euiSlots[key]
    if not s then
        s = { key = key }
        self._euiSlots[key] = s
        s.frame = NewButton(self, opts.initializeFrame)
    end
    s.parsed = ParseFilter(filter)
    s.cand = NormalizeCand(opts.candidateFilters)
    s.sortMethod, s.sortDirection = opts.sortMethod, opts.sortDirection
    MarkDirty(self)
    return s.frame
end
function ContainerMethods:SetAuraSlotFilterString(key, filter)
    local s = self._euiSlots[key]; if not s then return end
    s.parsed = ParseFilter(filter); MarkDirty(self)
end
function ContainerMethods:SetAuraSlotCandidateFilters(key, cand)
    local s = self._euiSlots[key]; if not s then return end
    s.cand = NormalizeCand(cand); MarkDirty(self)
end

function ContainerMethods:SetUnit(unit)
    local old = self._euiUnit
    if old and unitContainers[old] then unitContainers[old][self] = nil end
    self._euiUnit = unit
    if unit then
        unitContainers[unit] = unitContainers[unit] or {}
        unitContainers[unit][self] = true
    end
    MarkDirty(self)
end
function ContainerMethods:GetUnit() return self._euiUnit end
function ContainerMethods:UpdateAllAuras() MarkDirty(self) end

-- Returns a container frame carrying the engine API above.
function EllesmereUI._CreateCompatAuraContainer(parent)
    local c = CreateFrame("Frame", nil, parent)
    for k, fn in pairs(ContainerMethods) do c[k] = fn end
    c._euiGroups, c._euiGroupList, c._euiOrder, c._euiSlots = {}, {}, {}, {}
    c._euiPadL, c._euiPadR, c._euiPadT, c._euiPadB = 0, 0, 0, 0
    c._euiAnchor, c._euiGrowthH, c._euiGrowthV = "TOPLEFT", FD.Right, FD.Down
    c:SetScript("OnShow", MarkDirty)
    return c
end
