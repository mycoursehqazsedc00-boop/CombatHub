--[[
    CombatHub
    Shared combat event dispatcher and cache coordinator for Vanilla WoW 1.12 / Turtle WoW.
    Strict Lua 5.0 (Vanilla-Safe Mode).
]]

CombatHub = CombatHub or {}
local CH = CombatHub

CH.VERSION = "1.1.0"

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
-- Shared GUID, Roster & Spell Caches
-------------------------------------------------------------------------
local playerGUID = nil
local petGUID    = nil

local guidNameCache = {}
local guidNameCount = 0
local MAX_GUID_CACHE = 800

local guidUnitCache = {}
local petOwnerCache = {}
local rosterCacheCount = 0

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

local function StoreGuidName(guid, name)
    if not guid or guid == "" or not name or name == "" or name == "Unknown" then return end
    if not guidNameCache[guid] then
        if guidNameCount >= MAX_GUID_CACHE then
            guidNameCache = {}
            guidNameCount = 0
        end
        guidNameCount = guidNameCount + 1
    end
    guidNameCache[guid] = name
end

local function CacheRosterUnit(unit, ownerGuid)
    local g = ReadUnitGUID(unit)
    if not g then return nil end
    if not guidUnitCache[g] then
        rosterCacheCount = rosterCacheCount + 1
    end
    guidUnitCache[g] = unit
    if ownerGuid then
        petOwnerCache[g] = ownerGuid
    end
    local name = UnitName(unit)
    StoreGuidName(g, name)
    return g
end

function CH:RefreshSelfGUIDs()
    local oldPet = petGUID
    playerGUID = ReadUnitGUID("player")
    petGUID    = ReadUnitGUID("pet")
    if oldPet and oldPet ~= petGUID then
        if guidUnitCache[oldPet] then
            guidUnitCache[oldPet] = nil
            if rosterCacheCount > 0 then
                rosterCacheCount = rosterCacheCount - 1
            end
        end
        petOwnerCache[oldPet] = nil
    end
    if playerGUID then
        if not guidUnitCache[playerGUID] then
            rosterCacheCount = rosterCacheCount + 1
        end
        guidUnitCache[playerGUID] = "player"
        StoreGuidName(playerGUID, UnitName("player"))
    end
    if petGUID then
        if not guidUnitCache[petGUID] then
            rosterCacheCount = rosterCacheCount + 1
        end
        guidUnitCache[petGUID] = "pet"
        if playerGUID then
            petOwnerCache[petGUID] = playerGUID
        end
        StoreGuidName(petGUID, UnitName("pet"))
    end
end

function CH:RefreshRosterCache()
    guidUnitCache = {}
    petOwnerCache = {}
    rosterCacheCount = 0

    self:RefreshSelfGUIDs()

    local numRaid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if numRaid > 0 then
        local i
        for i = 1, numRaid do
            local unit = "raid" .. i
            local ownerG = CacheRosterUnit(unit, nil)
            if ownerG then
                CacheRosterUnit("raidpet" .. i, ownerG)
            end
        end
    else
        local numParty = GetNumPartyMembers and GetNumPartyMembers() or 0
        if numParty > 0 then
            local i
            for i = 1, numParty do
                local unit = "party" .. i
                local ownerG = CacheRosterUnit(unit, nil)
                if ownerG then
                    CacheRosterUnit("partypet" .. i, ownerG)
                end
            end
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

function CH:GetUnitToken(guid)
    if not guid or guid == "" then return nil end
    return guidUnitCache[guid]
end

function CH:GetOwnerGUID(petGuid)
    if not petGuid or petGuid == "" then return nil end
    return petOwnerCache[petGuid]
end

function CH:ResolveUnitName(guid)
    if not guid or guid == "" then return nil end
    local cached = guidNameCache[guid]
    if cached then return cached end
    if not CH.mods.superwow and not CH.mods.nampower then return nil end

    local ok, name = pcall(UnitName, guid)
    if ok and name and name ~= "" and name ~= "Unknown" then
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
    guidUnitCache = {}
    petOwnerCache = {}
    rosterCacheCount = 0
    spellCache = {}
    spellCacheCount = 0
    self:RefreshRosterCache()
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
    errors = 0,
}
CH.debugTrace = false

local function Trace(msg)
    if CH.debugTrace and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCombatHub|r: " .. tostring(msg))
    end
end

local CORE_EVENTS = {
    PLAYER_LOGIN          = true,
    PLAYER_ENTERING_WORLD = true,
    PARTY_MEMBERS_CHANGED = true,
    RAID_ROSTER_UPDATE    = true,
    UNIT_PET              = true,
    UNIT_PET_GUID         = true,
}

local function SyncEventRegistration(ev)
    local list = eventListeners[ev]
    if list and table.getn(list) > 0 then
        hubFrame:RegisterEvent(ev)
    else
        if not CORE_EVENTS[ev] then
            hubFrame:UnregisterEvent(ev)
        end
        eventListeners[ev] = nil
    end

    local count = 0
    for _ in pairs(eventListeners) do
        count = count + 1
    end
    CH.stats.registeredEvents = count
end

-- Helper: check if playerGUID (or optionally petGUID) matches any GUID field of the event.
-- In Nampower events, arg1 and arg2 are almost always target/caster or attacker/target GUIDs;
-- AURA_CAST_ON_* passes (spellId, casterGuid, targetGuid);
-- SPELL_START_* and SPELL_GO_* pass (itemId, spellId, casterGuid, targetGuid, ...).
local function MatchesSelfFilter(filter, ev, a1, a2, a3, a4)
    if not filter then return true end
    local me = playerGUID
    if not me then return true end

    local g1, g2
    if ev == "AURA_CAST_ON_SELF" or ev == "AURA_CAST_ON_OTHER" then
        g1, g2 = a2, a3
    elseif ev == "SPELL_START_SELF" or ev == "SPELL_START_OTHER"
        or ev == "SPELL_GO_SELF" or ev == "SPELL_GO_OTHER" then
        g1, g2 = a3, a4
    else
        g1, g2 = a1, a2
    end

    if filter == "self" then
        return (g1 == me or g2 == me)
    elseif filter == "self_or_pet" then
        if g1 == me or g2 == me then return true end
        local pet = petGUID
        if pet and (g1 == pet or g2 == pet) then return true end
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
        id            = id,
        name          = displayName or id,
        events        = events,
        callback      = callback,
        filter        = filter,
        active        = true,
        errorCount    = 0,
        lastErrorTime = 0,
    }
    subscribers[id] = sub
    table.insert(subscriberOrder, id)

    local i
    for i = 1, table.getn(events) do
        local ev = events[i]
        local oldList = eventListeners[ev]
        local newList = {}
        if oldList then
            local j
            for j = 1, table.getn(oldList) do
                newList[j] = oldList[j]
            end
        end
        table.insert(newList, sub)
        eventListeners[ev] = newList
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
            local newList = {}
            local j
            for j = 1, table.getn(list) do
                if list[j] ~= sub then
                    table.insert(newList, list[j])
                end
            end
            eventListeners[ev] = newList
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
    CH:RefreshRosterCache()
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
hubFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
hubFrame:RegisterEvent("RAID_ROSTER_UPDATE")
hubFrame:RegisterEvent("UNIT_PET")
if type(GetNampowerVersion) == "function" then
    hubFrame:RegisterEvent("UNIT_PET_GUID")
end

hubFrame:SetScript("OnEvent", function()
    local ev = event
    if ev == "PLAYER_LOGIN" then
        DetectMods()
        CH:RefreshRosterCache()
        if CH.mods.nampower then
            this:RegisterEvent("UNIT_PET_GUID")
        end
        deferFrame:Show()
        return
    end

    if ev == "PLAYER_ENTERING_WORLD" or ev == "PARTY_MEMBERS_CHANGED" or ev == "RAID_ROSTER_UPDATE" then
        CH:RefreshRosterCache()
    elseif ev == "UNIT_PET_GUID" then
        if arg2 == 1 or arg5 == 1 or not arg1 then
            CH:RefreshSelfGUIDs()
        end
        if type(arg7) == "number" and arg7 > 0 then
            local ownerG = ReadUnitGUID("raid" .. arg7)
            if ownerG then
                CacheRosterUnit("raidpet" .. arg7, ownerG)
            end
        elseif type(arg6) == "number" and arg6 > 0 then
            local ownerG = ReadUnitGUID("party" .. arg6)
            if ownerG then
                CacheRosterUnit("partypet" .. arg6, ownerG)
            end
        end
    elseif ev == "UNIT_PET" then
        if arg1 == "player" then
            CH:RefreshSelfGUIDs()
        elseif type(arg1) == "string" then
            local petUnit
            if string.find(arg1, "^raid%d+$") then
                petUnit = string.gsub(arg1, "^raid", "raidpet")
            elseif string.find(arg1, "^party%d+$") then
                petUnit = string.gsub(arg1, "^party", "partypet")
            end
            if petUnit then
                local ownerG = ReadUnitGUID(arg1)
                if ownerG then
                    CacheRosterUnit(petUnit, ownerG)
                end
            end
        end
    end

    local list = eventListeners[ev]
    if not list then return end

    local a1, a2, a3, a4, a5, a6, a7, a8, a9 = arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9
    local n = table.getn(list)
    local i
    for i = 1, n do
        local sub = list[i]
        if sub and sub.active then
            if MatchesSelfFilter(sub.filter, ev, a1, a2, a3, a4) then
                CH.stats.dispatched = CH.stats.dispatched + 1
                local ok, err = pcall(sub.callback, ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
                if not ok then
                    CH.stats.errors = CH.stats.errors + 1
                    sub.errorCount = (sub.errorCount or 0) + 1
                    local now = GetTime and GetTime() or 0
                    if DEFAULT_CHAT_FRAME and (sub.errorCount == 1 or (now - (sub.lastErrorTime or 0)) >= 10) then
                        sub.lastErrorTime = now
                        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444CombatHub|r [" .. tostring(sub.name) .. "] error #" .. tostring(sub.errorCount) .. ": " .. tostring(err))
                    end
                end
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

    local ok, err = pcall(handler, targetFrame, ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)

    this  = prevThis
    event = prevEvent
    arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9 = p1, p2, p3, p4, p5, p6, p7, p8, p9

    if not ok then
        error(err, 0)
    end
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
        .. "|r | Filtered out: |cff99ccff" .. tostring(CH.stats.filteredOut)
        .. "|r | Errors: |cffff6666" .. tostring(CH.stats.errors) .. "|r")
    p:AddMessage("  Caches: GUID=" .. tostring(guidNameCount)
        .. ", Roster=" .. tostring(rosterCacheCount)
        .. ", Spell=" .. tostring(spellCacheCount))

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
    local cmd = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))
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
