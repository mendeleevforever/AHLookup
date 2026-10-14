-- AHLookup.lua
-- Search Auctionator's saved price data from anywhere — no auction house needed.
-- WoW Forever (Classic-era, Interface 16001).
--
-- Price lookup modelled on WaylaidCrateAdvisor / DEValueTooltip:
--   1) Auctionator.API.v1.GetAuctionPriceByItemID
--   2) raw AUCTIONATOR_PRICE_DATABASE[realm .. " " .. faction][itemID].m
--
-- Auctionator only stores item IDs + prices, not names, so this addon resolves
-- names with C_Item.GetItemInfo (throttled) and caches them in AHLookupDB so
-- later sessions are instant.

local ADDON_NAME = "AHLookup"
local VERSION    = "1.1.0"
local AHL = {}
_G[ADDON_NAME] = AHL

local GetInfo    = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local PREFIX        = "|cff00ff96AH Lookup:|r "

-- Layout
local FRAME_W, FRAME_H = 460, 530
local ROW_H    = 20
local NUM_ROWS = 18
local LIST_TOP = -112

-- Name loading throttle (per 0.05s tick)
local MAX_PROCESSED_PER_TICK = 300   -- GetItemInfo calls (cached ones are cheap)
local MAX_REQUESTS_PER_TICK  = 12    -- calls that had to ask the server
local MAX_TRIES              = 2     -- retry passes for items the server is slow on

-- State
AHL.index     = {}   -- array of entries { id, key, name, lname, quality }
AHL.byID      = {}   -- itemID -> entry
AHL.results   = {}   -- current search results (entries)
AHL.queue     = {}   -- itemIDs waiting for GetItemInfo
AHL.queuePos  = 1
AHL.waiting   = {}   -- itemID -> true (asked server, waiting on GET_ITEM_INFO_RECEIVED)
AHL.tries     = {}
AHL.unnamed   = 0
AHL.loading   = false
AHL.offset    = 0
AHL.query     = ""

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local QUALITY_FALLBACK = {
    [0] = {0.62, 0.62, 0.62}, [1] = {1, 1, 1},       [2] = {0.12, 1, 0},
    [3] = {0, 0.44, 0.87},    [4] = {0.64, 0.21, 0.93}, [5] = {1, 0.5, 0},
    [6] = {0.9, 0.8, 0.5},    [7] = {0, 0.8, 1},
}
local function QualityRGB(q)
    if q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] then
        local c = ITEM_QUALITY_COLORS[q]
        return c.r, c.g, c.b
    end
    local c = QUALITY_FALLBACK[q or 1] or QUALITY_FALLBACK[1]
    return c[1], c[2], c[3]
end

local function Num(n)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

local function Trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- Money formatting — same as WaylaidCrateAdvisor / DEValueTooltip
function AHL:Coins(copper)
    if not copper then return "|cffaaaaaa—|r" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts+1] = ("|cffffd700%dg|r"):format(g) end
    if s > 0 then parts[#parts+1] = ("|cffc0c0c0%ds|r"):format(s) end
    if c > 0 or #parts == 0 then parts[#parts+1] = ("|cffb87333%dc|r"):format(c) end
    return table.concat(parts, " ")
end

-------------------------------------------------------------------------------
-- Auctionator database discovery
-------------------------------------------------------------------------------
-- A realm price table maps keys ("12345") to entries like { m = 1234, h = {...}, l = {...} }.
local function IsPriceTable(t)
    if type(t) ~= "table" then return false end
    local checked = 0
    for _, v in pairs(t) do
        if type(v) == "table" and (v.m or v.h or v.l) then return true end
        checked = checked + 1
        if checked >= 25 then break end
    end
    return false
end

local function CountKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Returns realmTable, sourceLabel
function AHL:FindPriceDB()
    -- 1) Auctionator's own live database object for this character (most accurate)
    if Auctionator and type(Auctionator.Database) == "table" and IsPriceTable(Auctionator.Database.db) then
        return Auctionator.Database.db, "Auctionator live data"
    end

    local root = AUCTIONATOR_PRICE_DATABASE
    if type(root) ~= "table" then return nil end

    -- 2) Known key formats ("Realm Faction" is what the other addons use)
    local realm   = GetRealmName() or ""
    local nrealm  = (GetNormalizedRealmName and GetNormalizedRealmName()) or (realm:gsub("[%s%-]", ""))
    local faction = UnitFactionGroup("player") or ""
    local candidates = {
        realm .. " " .. faction,
        nrealm .. " " .. faction,
        realm,
        nrealm,
        realm .. "-" .. faction,
    }
    if Auctionator and Auctionator.Variables and Auctionator.Variables.GetConnectedRealmRoot then
        local ok, r = pcall(Auctionator.Variables.GetConnectedRealmRoot)
        if ok and type(r) == "string" then table.insert(candidates, 1, r) end
    end
    for _, key in ipairs(candidates) do
        if IsPriceTable(root[key]) then return root[key], key end
    end

    -- 3) Any key that mentions this realm (largest wins)
    local best, bestKey, bestN
    local lrealm = realm:lower()
    for key, t in pairs(root) do
        if type(key) == "string" and lrealm ~= "" and key:lower():find(lrealm, 1, true) and IsPriceTable(t) then
            local n = CountKeys(t)
            if not bestN or n > bestN then best, bestKey, bestN = t, key, n end
        end
    end
    if best then return best, bestKey end

    -- 4) Last resort: the largest price table of any realm
    for key, t in pairs(root) do
        if IsPriceTable(t) then
            local n = CountKeys(t)
            if not bestN or n > bestN then best, bestKey, bestN = t, key, n end
        end
    end
    if best then return best, tostring(bestKey) .. " (other realm)" end
    return nil
end

-- DB keys: "12345" for most items; "g:12345:..." style for gear variants; "p:..." = pets (skip).
local function KeyToItemID(k)
    if type(k) == "number" then return k end
    if type(k) ~= "string" then return nil end
    local n = tonumber(k)
    if n then return n end
    local prefix, id = k:match("^(%a+):(%d+)")
    if prefix and prefix ~= "p" then return tonumber(id) end
    return nil
end

-------------------------------------------------------------------------------
-- Price / age / link
-------------------------------------------------------------------------------
function AHL:GetPrice(e)
    if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID then
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, ADDON_NAME, e.id)
        if ok and type(price) == "number" and price > 0 then return price end
    end
    local db = self.priceDB
    if db and e.key ~= nil then
        local v = db[e.key]
        if type(v) == "table" and type(v.m) == "number" and v.m > 0 then return v.m end
    end
    return nil
end

function AHL:GetAge(e)
    if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionAgeByItemID then
        local ok, age = pcall(Auctionator.API.v1.GetAuctionAgeByItemID, ADDON_NAME, e.id)
        if ok and type(age) == "number" then return age end
    end
    return nil
end

function AHL:GetLink(e)
    local name, link, quality = GetInfo(e.id)
    if name then self:SetName(e, name, quality) end
    if not link then
        self.waiting[e.id] = true
        print(PREFIX .. "Item data is still loading from the server — try again in a moment.")
    end
    return link
end

-------------------------------------------------------------------------------
-- Name index
-------------------------------------------------------------------------------
function AHL:SetName(e, name, quality)
    if not e.name then self.unnamed = math.max(0, self.unnamed - 1) end
    e.name  = name
    e.lname = name:lower()
    if quality then e.quality = quality end
    if self.db then
        self.db.names[e.id] = name
        if quality then self.db.quality[e.id] = quality end
    end
end

-- Adds any item IDs from Auctionator's data that aren't indexed yet.
function AHL:SyncIndex()
    local db, src = self:FindPriceDB()
    self.priceDB, self.dbSource = db, src
    if not db then
        self:UpdateStatus()
        return
    end

    local names, quals = self.db.names, self.db.quality
    local needName, needQual = {}, {}

    for k in pairs(db) do
        local id = KeyToItemID(k)
        if id then
            local e = self.byID[id]
            if not e then
                e = { id = id }
                self.byID[id] = e
                self.index[#self.index + 1] = e
                local cached = names[id]
                if cached then
                    e.name, e.lname, e.quality = cached, cached:lower(), quals[id]
                else
                    self.unnamed = self.unnamed + 1
                end
                if not e.name then
                    needName[#needName + 1] = id
                elseif not e.quality then
                    needQual[#needQual + 1] = id
                end
            end
            -- prefer the plain "12345" key for price lookups
            if e.key == nil or tonumber(k) then e.key = k end
        end
    end

    for _, id in ipairs(needName) do self.queue[#self.queue + 1] = id end
    for _, id in ipairs(needQual) do self.queue[#self.queue + 1] = id end
    self:StartLoader()
    self:UpdateStatus()
end

-- Throttled name loader
local loader = CreateFrame("Frame")
loader:Hide()
local loaderElapsed = 0

function AHL:StartLoader()
    if self.queuePos <= #self.queue then
        self.loading = true
        loader:Show()
    elseif not next(self.waiting) then
        self.loading = false
    end
end

function AHL:FinishQueue()
    wipe(self.queue)
    self.queuePos = 1
    local stragglers = {}
    for id in pairs(self.waiting) do
        local t = (self.tries[id] or 0) + 1
        self.tries[id] = t
        if t <= MAX_TRIES then stragglers[#stragglers + 1] = id end
    end
    if #stragglers > 0 then
        self.loading = true
        C_Timer.After(4, function()
            for _, id in ipairs(stragglers) do
                if self.waiting[id] then self.queue[#self.queue + 1] = id end
            end
            self:StartLoader()
            if not loader:IsShown() then self.loading = false end
            self:UpdateStatus()
        end)
    else
        self.loading = false
    end
    self:UpdateStatus()
end

loader:SetScript("OnUpdate", function(self, elapsed)
    loaderElapsed = loaderElapsed + elapsed
    if loaderElapsed < 0.05 then return end
    loaderElapsed = 0

    local q = AHL.queue
    local processed, requests, changed = 0, 0, false
    while AHL.queuePos <= #q and processed < MAX_PROCESSED_PER_TICK and requests < MAX_REQUESTS_PER_TICK do
        local id = q[AHL.queuePos]
        AHL.queuePos = AHL.queuePos + 1
        processed = processed + 1
        local e = AHL.byID[id]
        if e and (not e.name or not e.quality) then
            local name, _, quality = GetInfo(id)
            if name then
                AHL:SetName(e, name, quality)
                AHL.waiting[id] = nil
                changed = true
            else
                AHL.waiting[id] = true
                requests = requests + 1
            end
        end
    end

    if AHL.queuePos > #q then
        self:Hide()
        AHL:FinishQueue()
    end
    AHL:UpdateStatus()
    if changed then AHL:RequestRefresh() end
end)

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------
-- Matching rules (lower score = better match, sorted to the top):
--
-- The query is split into words. EVERY word must match somewhere in the item
-- name, in any order. Each word can match in one of three ways:
--
--   0 pts  starts a word in the name        "bra"  -> "[Bra]cers"
--   1 pt   appears inside a word            "weave"-> "Green[weave]"
--   3+ pts letters appear in order (fuzzy)   "iro"  -> "F[i][r]e Pr[o]tection"
--          (+0.5 per skipped letter; must fit inside a reasonable window so
--           stray letters scattered across a long name don't count)
--
-- Bonuses for the whole query: exact name -100, name starts with it -50,
-- name contains it -20. Ties sort alphabetically.

local MIN_FUZZY_SLACK = 6     -- a fuzzy word may skip at least this many letters
local FUZZY_SLACK_MULT = 2    -- ...or 2x its own length, whichever is larger

local function EscapePattern(c)
    return (c:gsub("%W", "%%%0"))
end

-- Pre-process the query words once per search
local function BuildTokens(q)
    local tokens = {}
    for word in q:gmatch("%S+") do
        local len = #word
        local parts = {}
        for i = 1, len do parts[i] = EscapePattern(word:sub(i, i)) end
        tokens[#tokens + 1] = {
            text     = word,
            len      = len,
            fuzzy    = table.concat(parts, ".-"),   -- "i.-r.-o"
            maxSpan  = len + math.max(MIN_FUZZY_SLACK, len * FUZZY_SLACK_MULT),
        }
    end
    return tokens
end

local function IsWordStart(name, pos)
    return pos == 1 or not name:sub(pos - 1, pos - 1):find("%w")
end

-- Returns a score for one word against one name, or nil if it doesn't match.
local function ScoreToken(name, tok)
    -- Plain fragment match (fast, done in C)
    local pos = name:find(tok.text, 1, true)
    if pos then
        local best = 1
        while pos do
            if IsWordStart(name, pos) then best = 0; break end
            pos = name:find(tok.text, pos + 1, true)
        end
        return best
    end

    -- Fuzzy: letters in order. Find the tightest window that contains them.
    if tok.len < 2 then return nil end
    local s, e = name:find(tok.fuzzy)
    if not s then return nil end
    local bestSpan = e - s + 1
    local tries = 0
    while s and tries < 12 and bestSpan > tok.len do
        s, e = name:find(tok.fuzzy, s + 1)
        if s and (e - s + 1) < bestSpan then bestSpan = e - s + 1 end
        tries = tries + 1
    end
    if bestSpan > tok.maxSpan then return nil end
    return 3 + (bestSpan - tok.len) * 0.5
end

local function ScoreName(name, q, tokens)
    local total = 0
    for i = 1, #tokens do
        local sc = ScoreToken(name, tokens[i])
        if not sc then return nil end
        total = total + sc
    end
    if name == q then
        total = total - 100
    else
        local pos = name:find(q, 1, true)
        if pos == 1 then total = total - 50
        elseif pos then total = total - 20 end
    end
    return total
end

local function SortResults(a, b)
    if a.score ~= b.score then return a.score < b.score end
    local an, bn = a.lname or "\255", b.lname or "\255"
    if an ~= bn then return an < bn end
    return a.id < b.id
end

function AHL:DoSearch(keepOffset)
    local f = self.frame
    local q = (Trim(f and f.searchBox:GetText() or ""):lower():gsub("%s+", " "))
    self.query = q

    local res = self.results
    wipe(res)
    if q ~= "" then
        local qid = tonumber(q)
        local tokens = BuildTokens(q)
        for _, e in ipairs(self.index) do
            local score = e.lname and ScoreName(e.lname, q, tokens)
            if score then
                e.score = score
                res[#res + 1] = e
            elseif qid and e.id == qid then
                e.score = -1000
                res[#res + 1] = e
            end
        end
        table.sort(res, SortResults)
    end

    if not keepOffset then self.offset = 0 end
    self:UpdateList()
end

-- Debounced search for typing
function AHL:ScheduleSearch(delay)
    if not (self.frame and self.frame:IsShown()) then return end
    self.searchToken = (self.searchToken or 0) + 1
    local token = self.searchToken
    C_Timer.After(delay, function()
        if token == self.searchToken then self:DoSearch(false) end
    end)
end

-- Throttled refresh while names stream in (keeps scroll position)
function AHL:RequestRefresh()
    if self.refreshPending or not (self.frame and self.frame:IsShown()) then return end
    self.refreshPending = true
    C_Timer.After(0.5, function()
        self.refreshPending = false
        if self.frame and self.frame:IsShown() then
            if self.query ~= "" then self:DoSearch(true) else self:UpdateList() end
        end
    end)
end

-------------------------------------------------------------------------------
-- Chat linking
-------------------------------------------------------------------------------
function AHL:LinkToChat(e)
    local link = self:GetLink(e)
    if not link then return end
    local ok, inserted = pcall(ChatEdit_InsertLink, link)
    if not (ok and inserted) and ChatFrame_OpenChat then
        -- No chat box open: open one with the link already in it
        ChatFrame_OpenChat(link)
    end
end

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------
local function Row_OnEnter(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local _, link = GetInfo(e.id)
    GameTooltip:SetHyperlink(link or ("item:" .. e.id))
    local age = AHL:GetAge(e)
    if age then
        local when = (age == 0) and "today" or (age == 1 and "1 day ago" or (age .. " days ago"))
        GameTooltip:AddLine("|cff888888Auctionator price last seen " .. when .. "|r")
    end
    GameTooltip:Show()
end

local function Row_OnLeave(self)
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end

local function Row_OnClick(self, button)
    local e = self.entry
    if not e or button ~= "LeftButton" then return end
    if IsModifiedClick("CHATLINK") or IsShiftKeyDown() then
        AHL:LinkToChat(e)
    elseif IsModifiedClick("DRESSUP") and DressUpItemLink then
        local link = AHL:GetLink(e)
        if link then DressUpItemLink(link) end
    end
end

local function List_OnMouseWheel(_, delta)
    AHL.offset = AHL.offset - delta * 3
    AHL:UpdateList()
end

local function SavePosition(f)
    local point, _, relPoint, x, y = f:GetPoint()
    if point and AHL.db then AHL.db.pos = { point, relPoint, x, y } end
end

function AHL:CreateUI()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "AHLookupFrame", UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    local pos = self.db and self.db.pos
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)
    f:Hide()
    tinsert(UISpecialFrames, "AHLookupFrame")   -- Escape closes it

    -- Background: same parchment look as Waylaid Crate Advisor
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
    bg:SetPoint("TOPLEFT", 12, -12)
    bg:SetPoint("BOTTOMRIGHT", -12, 12)
    bg:SetVertexColor(1, 0.88, 0.65, 1)

    -- Thin gold edge
    local function Edge(p1, p2, w, h)
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.55, 0.40, 0.12, 0.9)
        t:SetPoint(p1, bg, p1)
        t:SetPoint(p2, bg, p2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)

    local titleBg = f:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetPoint("TOP", 0, 12)
    titleBg:SetSize(320, 64)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -2)
    title:SetText("|cffffd100AH Lookup|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Search box
    local sb = CreateFrame("EditBox", "AHLookupSearchBox", f, "InputBoxTemplate")
    sb:SetSize(FRAME_W - 140, 20)
    sb:SetPoint("TOPLEFT", 28, -44)
    sb:SetAutoFocus(false)
    sb:SetMaxLetters(80)

    local placeholder = sb:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search item name or ID...")
    local function UpdatePlaceholder()
        if sb:GetText() == "" and not sb:HasFocus() then placeholder:Show() else placeholder:Hide() end
    end

    sb:SetScript("OnTextChanged", function()
        UpdatePlaceholder()
        AHL:ScheduleSearch(0.15)
    end)
    sb:SetScript("OnEditFocusGained", UpdatePlaceholder)
    sb:SetScript("OnEditFocusLost", UpdatePlaceholder)
    sb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        AHL.searchToken = (AHL.searchToken or 0) + 1
        AHL:DoSearch(false)
    end)
    f.searchBox = sb

    local clearBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    clearBtn:SetSize(80, 22)
    clearBtn:SetPoint("LEFT", sb, "RIGHT", 10, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        sb:SetText("")
        sb:SetFocus()
    end)

    -- Status line
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", 24, -72)
    status:SetPoint("TOPRIGHT", -24, -72)
    status:SetJustifyH("LEFT")
    f.status = status

    -- Column headers
    local hItem = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hItem:SetPoint("TOPLEFT", 20, -94)
    hItem:SetText("|cffd4a017Item|r")
    local hPrice = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hPrice:SetPoint("TOPRIGHT", -42, -94)
    hPrice:SetText("|cffd4a017AH Price|r")

    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(0.5, 0.38, 0.15, 0.6)
    div:SetPoint("TOPLEFT", 16, -108)
    div:SetPoint("TOPRIGHT", -16, -108)
    div:SetHeight(1)

    -- List area
    local listW = FRAME_W - 32 - 20
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", 16, LIST_TOP)
    list:SetSize(listW, ROW_H * NUM_ROWS)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", List_OnMouseWheel)
    f.list = list

    f.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(listW, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp")

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        if i % 2 == 0 then stripe:SetColorTexture(0.2, 0.15, 0.05, 0.18) else stripe:SetColorTexture(0, 0, 0, 0) end

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAllPoints()

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 2, ROW_H - 2)
        row.icon:SetPoint("LEFT", 2, 0)

        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("RIGHT", -4, 0)
        row.price:SetWidth(120)
        row.price:SetJustifyH("RIGHT")

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.price, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        if row.name.SetWordWrap then row.name:SetWordWrap(false) end

        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)
        row:SetScript("OnClick", Row_OnClick)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", List_OnMouseWheel)
        row:Hide()
        f.rows[i] = row
    end

    -- Scrollbar (plain Slider so it doesn't depend on any template)
    local sl = CreateFrame("Slider", nil, f)
    sl:SetOrientation("VERTICAL")
    sl:SetPoint("TOPLEFT", list, "TOPRIGHT", 4, 0)
    sl:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 4, 0)
    sl:SetWidth(16)
    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(0, 0, 0, 0.25)
    sl:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local thumb = sl:GetThumbTexture()
    if thumb then thumb:SetSize(18, 24) end
    sl:SetMinMaxValues(0, 0)
    sl:SetValueStep(1)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl:SetValue(0)
    sl:EnableMouse(true)
    sl:EnableMouseWheel(true)
    sl:SetScript("OnMouseWheel", List_OnMouseWheel)
    sl:SetScript("OnValueChanged", function(_, value)
        if AHL.updatingSlider then return end
        local v = math.floor(value + 0.5)
        if v ~= AHL.offset then
            AHL.offset = v
            AHL:UpdateList()
        end
    end)
    sl:Hide()
    f.slider = sl

    -- Message shown when the list is empty
    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    empty:SetPoint("TOPLEFT", 20, -60)
    empty:SetPoint("TOPRIGHT", -20, -60)
    empty:SetJustifyH("CENTER")
    if empty.SetSpacing then empty:SetSpacing(4) end
    f.empty = empty

    -- Footer
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer:SetPoint("BOTTOMLEFT", 22, 20)
    footer:SetJustifyH("LEFT")
    f.footer = footer

    local refreshBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    refreshBtn:SetSize(90, 22)
    refreshBtn:SetPoint("BOTTOMRIGHT", -16, 14)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function()
        AHL:SyncIndex()
        AHL:DoSearch(true)
    end)

    f:SetScript("OnShow", function()
        AHL:SyncIndex()
        AHL:DoSearch(true)
        UpdatePlaceholder()
    end)
    f:SetScript("OnHide", function()
        sb:ClearFocus()
        for _, row in ipairs(f.rows) do
            if GameTooltip:IsOwned(row) then GameTooltip:Hide() end
        end
    end)

    self.frame = f
    return f
end

function AHL:UpdateList()
    local f = self.frame
    if not f then return end

    local res   = self.results
    local total = #res
    local maxOff = math.max(0, total - NUM_ROWS)
    if self.offset > maxOff then self.offset = maxOff end
    if self.offset < 0 then self.offset = 0 end

    self.updatingSlider = true
    f.slider:SetMinMaxValues(0, maxOff)
    f.slider:SetValue(self.offset)
    self.updatingSlider = false
    if maxOff > 0 then f.slider:Show() else f.slider:Hide() end

    for i, row in ipairs(f.rows) do
        local e = res[self.offset + i]
        row.entry = e
        if e then
            local icon = GetInstant and select(5, GetInstant(e.id))
            row.icon:SetTexture(icon or QUESTION_ICON)
            row.name:SetText(e.name or ("Item #" .. e.id .. " |cff888888(loading...)|r"))
            row.name:SetTextColor(QualityRGB(e.quality))
            local price = self:GetPrice(e)
            row.price:SetText(price and self:Coins(price) or "|cff888888no price|r")
            row:Show()
            if GameTooltip:IsOwned(row) then Row_OnEnter(row) end   -- keep tooltip in sync while scrolling
        else
            row:Hide()
            if GameTooltip:IsOwned(row) then GameTooltip:Hide() end
        end
    end

    -- Empty-state message
    if total > 0 then
        f.empty:SetText("")
    elseif not self.priceDB then
        f.empty:SetText("|cffff6060No Auctionator price data found.|r\n\n|cffd0c0a0Make sure Auctionator is enabled and has\ncompleted at least one auction house scan.|r")
    elseif self.query == "" then
        f.empty:SetText(("|cffd0c0a0Type above to search %s items\nfrom Auctionator's price data.|r"):format(Num(#self.index)))
    else
        local msg = ("|cffd0c0a0No items match \"%s\".|r"):format(self.query)
        if self.loading and self.unnamed > 0 then
            msg = msg .. "\n\n|cffffcc00Still loading item names — results will fill in shortly.|r"
        end
        f.empty:SetText(msg)
    end

    if total > 0 then
        f.footer:SetText(("|cffd4a017%s|r |cff888888match%s  •  Shift-click to link  •  Ctrl-click to preview|r")
            :format(Num(total), total == 1 and "" or "es"))
    else
        f.footer:SetText("|cff888888Shift-click to link  •  Ctrl-click to preview|r")
    end
end

function AHL:UpdateStatus()
    local f = self.frame
    if not f then return end
    if not self.priceDB then
        f.status:SetText("|cffff6060No Auctionator data found|r")
        return
    end
    local s = ("|cffd4a017%s|r |cff888888items  •  %s|r"):format(Num(#self.index), self.dbSource or "?")
    if self.loading and self.unnamed > 0 then
        s = s .. ("  |cffffcc00•  loading names (%s left)|r"):format(Num(self.unnamed))
    end
    f.status:SetText(s)
end

function AHL:Toggle(searchText)
    local f = self:CreateUI()
    if searchText and searchText ~= "" then
        f:Show()
        f.searchBox:SetText(searchText)
        self.searchToken = (self.searchToken or 0) + 1
        self:DoSearch(false)
        return
    end
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        f.searchBox:SetFocus()
    end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_AHLOOKUP1 = "/ahl"
SLASH_AHLOOKUP2 = "/ahlookup"
SlashCmdList["AHLOOKUP"] = function(msg)
    msg = Trim(msg)
    local lower = msg:lower()

    if lower == "help" then
        print(PREFIX .. "commands:")
        print("  /ahl              Toggle the search window")
        print("  /ahl <text>       Open the window and search for <text>")
        print("  /ahl debug        Show where the Auctionator data is coming from")
        print("  /ahl resetcache   Forget cached item names and reload them")
        return
    end

    if lower == "debug" then
        local db, src = AHL:FindPriceDB()
        print(PREFIX .. "debug")
        print("  Auctionator loaded: " .. tostring(Auctionator ~= nil))
        print("  Auctionator API v1: " .. tostring((Auctionator and Auctionator.API and Auctionator.API.v1) ~= nil))
        print("  AUCTIONATOR_PRICE_DATABASE: " .. type(AUCTIONATOR_PRICE_DATABASE))
        if type(AUCTIONATOR_PRICE_DATABASE) == "table" then
            for k, v in pairs(AUCTIONATOR_PRICE_DATABASE) do
                if type(v) == "table" then print(("    [%s]  %s entries"):format(tostring(k), Num(CountKeys(v)))) end
            end
        end
        print("  Using: " .. (db and (src .. "  (" .. Num(CountKeys(db)) .. " entries)") or "nothing found"))
        print(("  Indexed: %s  •  unnamed: %s  •  loading: %s"):format(Num(#AHL.index), Num(AHL.unnamed), tostring(AHL.loading)))
        return
    end

    if lower == "resetcache" then
        wipe(AHL.db.names)
        wipe(AHL.db.quality)
        wipe(AHL.index)
        wipe(AHL.byID)
        wipe(AHL.queue)
        wipe(AHL.waiting)
        wipe(AHL.tries)
        wipe(AHL.results)
        AHL.queuePos, AHL.unnamed = 1, 0
        print(PREFIX .. "Name cache cleared — names will reload next time the window opens.")
        if AHL.frame and AHL.frame:IsShown() then
            AHL:SyncIndex()
            AHL:DoSearch(false)
        end
        return
    end

    AHL:Toggle(msg)
end

-------------------------------------------------------------------------------
-- Init / events
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        AHLookupDB = AHLookupDB or {}
        local db = AHLookupDB
        local locale = GetLocale()
        if db.locale ~= locale then       -- names are localized; start fresh on a locale change
            db.names, db.quality, db.locale = {}, {}, locale
        end
        db.names   = db.names or {}
        db.quality = db.quality or {}
        AHL.db = db
        print(("|cff00ff96AH Lookup %s|r loaded  —  /ahl to search Auctionator data"):format(VERSION))

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local id, success = arg1, arg2
        if not id or not AHL.waiting[id] then return end
        AHL.waiting[id] = nil
        local e = AHL.byID[id]
        if e and success ~= false then
            local name, _, quality = GetInfo(id)
            if name then
                AHL:SetName(e, name, quality)
                AHL:UpdateStatus()
                AHL:RequestRefresh()
            end
        end

    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- A scan may have added new items; pick them up if the window is open
        if AHL.frame and AHL.frame:IsShown() then
            AHL:SyncIndex()
            AHL:RequestRefresh()
        end
    end
end)
