--[[
    CombatHub
    Shared combat event dispatcher and cache coordinator for Vanilla WoW 1.12 / Turtle WoW.
    Strict Lua 5.0 (Vanilla-Safe Mode).
]]

CombatHub = CombatHub or {}
local CH = CombatHub

CH.VERSION = "1.0.0"

-------------------------------------------------------------------------
-- Mod Detection (refreshed on PLAYER_LOGIN)
-------------------------------------------------------------------------
CH.mods = {
    nampower   = false,
    superwow   = false,
    classicapi = false,
    dpslog     = false,
}

local function DetectMods()
    CH.mods.nampower   = (type(GetNampowerVersion) == "function")
    CH.mods.superwow   = (SUPERWOW_VERSION ~= nil)
    CH.mods.classicapi = (CLASSIC_API_VERSION ~= nil)
    CH.mods.dpslog     = (type(GetWeirdUtilsVersion) == "function" and GetWeirdUtilsVersion("dpslog") ~= nil)
end

-------------------------------------------------------------------------
-- Shared GUID & Spell Caches
-------------------------------------------------------------------------
local playerGUID = nil
local petGUID    = nil

local guidNameCache = {}
local guidNameCount = 0
local MAX_GUID_CACHE = 800

local spellCache = {}
local spellCacheCount = 0
local MAX_SPELL_CACHE = 600

local function ReadUnitGUID(unit)
    if CH.mods.nampower and type(GetUnitGUID) == "function" then
        local g = GetUnitGUID(unit)
        if g and g ~= "" then return g end
    end
    if CH.mods.superwow and type(UnitExists) == "function" then
        local exists, g = UnitExists(unit)
        if exists and g and g ~= "" then return g end
    end
    if type(UnitGUID) == "function" then
        local g = UnitGUID(unit)
        if g and g ~= "" then return g end
    end
    return nil
end

function CH:RefreshSelfGUIDs()
    playerGUID = ReadUnitGUID("player")
    petGUID    = ReadUnitGUID("pet")
    if playerGUID then
        local pname = UnitName("player")
        if pname and pname ~= "" then
            guidNameCache[playerGUID] = pname
        end
    end
    if petGUID then
        local petname = UnitName("pet")
        if petname and petname ~= "" then
            guidNameCache[petGUID] = petname
        end
    end
end

function CH:GetPlayerGUID()
    if not playerGUID then
        self:RefreshSelfGUIDs()
    end
    return playerGUID
end

function CH:GetPetGUID()
    return petGUID
end

function CH:ResolveUnitName(guid)
    if not guid or guid == "" then return nil end
    local cached = guidNameCache[guid]
    if cached then return cached end

    local name = UnitName(guid)
    if name and name ~= "" and name ~= "Unknown" then
        if guidNameCount >= MAX_GUID_CACHE then
            guidNameCache = {}
            guidNameCount = 0
        end
        guidNameCache[guid] = name
        guidNameCount = guidNameCount + 1
        return name
    end
    return nil
end

function CH:ResolveSpell(spellId)
    if not spellId or spellId == 0 then return nil end
    local entry = spellCache[spellId]
    if entry then return entry end

    local name, rank, icon
    if CH.mods.superwow and type(SpellInfo) == "function" then
        name, rank, icon = SpellInfo(spellId)
    end
    if (not name or name == "") and CH.mods.nampower and type(GetSpellNameAndRankForId) == "function" then
        local n, r = GetSpellNameAndRankForId(spellId)
        name = n
        rank = r
    end
    if (not icon or icon == "") and CH.mods.nampower and type(GetSpellRecField) == "function" and type(GetSpellIconTexture) == "function" then
        local iconId = GetSpellRecField(spellId, "spellIconID")
        if iconId then
            icon = GetSpellIconTexture(iconId)
        end
    end
    if (not name or name == "") and type(GetSpellInfo) == "function" then
        local n, r, ic = GetSpellInfo(spellId)
        name = name or n
        rank = rank or r
        icon = icon or ic
    end

    if name and name ~= "" then
        if spellCacheCount >= MAX_SPELL_CACHE then
            spellCache = {}
            spellCacheCount = 0
        end
        entry = { name = name, rank = rank or "", icon = icon }
        spellCache[spellId] = entry
        spellCacheCount = spellCacheCount + 1
        return entry
    end
    return nil
end

function CH:ClearCaches()
    guidNameCache = {}
    guidNameCount = 0
    spellCache = {}
    spellCacheCount = 0
    self:RefreshSelfGUIDs()
end

-------------------------------------------------------------------------
-- Event Registry & Reference-Counted Subscription
-------------------------------------------------------------------------
local hubFrame = CreateFrame("Frame", "CombatHubFrame")

-- subscribers[id] = { id=id, name=displayName, events={...}, callback=fn, filter=nil|"self"|"self_or_pet", active=true }
local subscribers = {}
local subscriberOrder = {}
-- eventListeners[eventName] = { sub1, sub2, ... }
local eventListeners = {}

-- Stats
CH.stats = {
    dispatched = 0,
    filteredOut = 0,
    registeredEvents = 0,
}
CH.debugTrace = false

local function Trace(msg)
    if CH.debugTrace and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCombatHub|r: " .. tostring(msg))
    end
end

local function SyncEventRegistration(ev)
    local list = eventListeners[ev]
    if list and table.getn(list) > 0 then
        hubFrame:RegisterEvent(ev)
    else
        hubFrame:UnregisterEvent(ev)
        eventListeners[ev] = nil
    end

    local count = 0
    for _ in pairs(eventListeners) do
        count = count + 1
    end
    CH.stats.registeredEvents = count
end

-- Helper: check if playerGUID (or optionally petGUID) matches any GUID field of the event.
-- In Nampower events, arg1 and arg2 are almost always target/caster or attacker/target GUIDs.
local function MatchesSelfFilter(filter, ev, a1, a2)
    if not filter then return true end
    local me = playerGUID
    if not me then return true end

    if filter == "self" then
        if a1 == me or a2 == me then return true end
        return false
    elseif filter == "self_or_pet" then
        local pet = petGUID
        if a1 == me or a2 == me then return true end
        if pet and (a1 == pet or a2 == pet) then return true end
        return false
    end
    return true
end

--[[
    Subscribe(id, displayName, events, callback, filter)
      id: unique string key (e.g. "KLHThreatMeter", "GreedMeter", "EavesDrop", "Vampify_Damage")
      displayName: human-readable label for /chub status
      events: array of event names
      callback: function(ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
      filter: nil (all), "self", or "self_or_pet"
]]
function CH:Subscribe(id, displayName, events, callback, filter)
    if not id or type(events) ~= "table" or type(callback) ~= "function" then return false end

    -- Clean previous subscription if re-subscribing
    if subscribers[id] then
        self:Unsubscribe(id)
    end

    local sub = {
        id       = id,
        name     = displayName or id,
        events   = events,
        callback = callback,
        filter   = filter,
        active   = true,
    }
    subscribers[id] = sub
    table.insert(subscriberOrder, id)

    local i
    for i = 1, table.getn(events) do
        local ev = events[i]
        if not eventListeners[ev] then
            eventListeners[ev] = {}
        end
        table.insert(eventListeners[ev], sub)
        SyncEventRegistration(ev)
    end

    Trace("Subscribed: " .. tostring(sub.name) .. " (" .. table.getn(events) .. " events, filter=" .. tostring(filter or "none") .. ")")
    return true
end

function CH:Unsubscribe(id)
    local sub = subscribers[id]
    if not sub then return false end
    sub.active = false

    local i
    for i = 1, table.getn(sub.events) do
        local ev = sub.events[i]
        local list = eventListeners[ev]
        if list then
            local j
            for j = table.getn(list), 1, -1 do
                if list[j] == sub then
                    table.remove(list, j)
                end
            end
            SyncEventRegistration(ev)
        end
    end

    subscribers[id] = nil
    for i = table.getn(subscriberOrder), 1, -1 do
        if subscriberOrder[i] == id then
            table.remove(subscriberOrder, i)
        end
    end
    Trace("Unsubscribed: " .. tostring(id))
    return true
end

function CH:IsSubscribed(id)
    return subscribers[id] ~= nil
end

-------------------------------------------------------------------------
-- Deferred Post-Login Hook Queue
-- Runs 1 frame after PLAYER_LOGIN so all addons finish their own init first.
-------------------------------------------------------------------------
local postLoginQueue = {}
local postLoginRan = false
local deferFrame = CreateFrame("Frame", "CombatHubDeferFrame")
deferFrame:Hide()

function CH:OnPostLogin(fn)
    if type(fn) ~= "function" then return end
    if postLoginRan then
        fn()
        return
    end
    table.insert(postLoginQueue, fn)
end

deferFrame:SetScript("OnUpdate", function()
    this:Hide()
    postLoginRan = true
    CH:RefreshSelfGUIDs()
    local i
    for i = 1, table.getn(postLoginQueue) do
        local ok, err = pcall(postLoginQueue[i])
        if not ok and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444CombatHub adapter error|r: " .. tostring(err))
        end
    end
    postLoginQueue = {}
end)

-------------------------------------------------------------------------
-- Core Event Dispatcher
-------------------------------------------------------------------------
hubFrame:RegisterEvent("PLAYER_LOGIN")
hubFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
hubFrame:RegisterEvent("UNIT_PET")
if type(GetNampowerVersion) == "function" then
    hubFrame:RegisterEvent("UNIT_PET_GUID")
end

hubFrame:SetScript("OnEvent", function()
    local ev = event
    if ev == "PLAYER_LOGIN" then
        DetectMods()
        CH:RefreshSelfGUIDs()
        if CH.mods.nampower then
            this:RegisterEvent("UNIT_PET_GUID")
        end
        deferFrame:Show()
        return
    end

    if ev == "PLAYER_ENTERING_WORLD" or ev == "UNIT_PET_GUID" then
        CH:RefreshSelfGUIDs()
    elseif ev == "UNIT_PET" and arg1 == "player" then
        CH:RefreshSelfGUIDs()
    end

    local list = eventListeners[ev]
    if not list then return end

    local a1, a2, a3, a4, a5, a6, a7, a8, a9 = arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9
    local n = table.getn(list)
    local i
    for i = 1, n do
        local sub = list[i]
        if sub and sub.active then
            if MatchesSelfFilter(sub.filter, ev, a1, a2) then
                CH.stats.dispatched = CH.stats.dispatched + 1
                sub.callback(ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
            else
                CH.stats.filteredOut = CH.stats.filteredOut + 1
            end
        end
    end
end)

-------------------------------------------------------------------------
-- Helper to invoke a legacy OnEvent frame handler cleanly
-------------------------------------------------------------------------
function CH:InvokeFrameOnEvent(targetFrame, handler, ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
    if not targetFrame or not handler then return end
    local prevThis  = this
    local prevEvent = event
    local p1, p2, p3, p4, p5, p6, p7, p8, p9 = arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9

    this  = targetFrame
    event = ev
    arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9 = a1, a2, a3, a4, a5, a6, a7, a8, a9

    handler()

    this  = prevThis
    event = prevEvent
    arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9 = p1, p2, p3, p4, p5, p6, p7, p8, p9
end

-------------------------------------------------------------------------
-- Slash Command: /combathub, /chub
-------------------------------------------------------------------------
function CH:PrintStatus()
    if not DEFAULT_CHAT_FRAME then return end
    local p = DEFAULT_CHAT_FRAME
    p:AddMessage("|cff66ccffCombatHub v" .. CH.VERSION .. "|r Status:")
    p:AddMessage("  Mods: Nampower=" .. tostring(CH.mods.nampower)
        .. ", SuperWoW=" .. tostring(CH.mods.superwow)
        .. ", ClassicAPI=" .. tostring(CH.mods.classicapi)
        .. ", DPSLog=" .. tostring(CH.mods.dpslog))
    p:AddMessage("  Active hub events: |cffffff00" .. tostring(CH.stats.registeredEvents)
        .. "|r | Dispatched: |cff33ff33" .. tostring(CH.stats.dispatched)
        .. "|r | Filtered out: |cff99ccff" .. tostring(CH.stats.filteredOut) .. "|r")
    p:AddMessage("  Caches: GUID=" .. tostring(guidNameCount) .. ", Spell=" .. tostring(spellCacheCount))

    local n = table.getn(subscriberOrder)
    if n == 0 then
        p:AddMessage("  Subscribers: |cffff8800none|r")
    else
        p:AddMessage("  Subscribers (" .. tostring(n) .. "):")
        local i
        for i = 1, n do
            local sub = subscribers[subscriberOrder[i]]
            if sub then
                p:AddMessage("    - |cff33ff33" .. sub.name .. "|r ("
                    .. tostring(table.getn(sub.events)) .. " events, filter="
                    .. tostring(sub.filter or "all") .. ")")
            end
        end
    end
end

SLASH_COMBATHUB1 = "/combathub"
SLASH_COMBATHUB2 = "/chub"
SlashCmdList["COMBATHUB"] = function(msg)
    local cmd = string.lower(msg or "")
    if cmd == "trace" then
        CH.debugTrace = not CH.debugTrace
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCombatHub|r trace: " .. (CH.debugTrace and "|cff33ff33ON|r" or "|cffff3333OFF|r"))
        end
    elseif cmd == "clear" then
        CH:ClearCaches()
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCombatHub|r: GUID and Spell caches cleared.")
        end
    else
        CH:PrintStatus()
    end
end
