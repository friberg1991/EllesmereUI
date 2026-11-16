if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBlizzardSkin_LootRollWindow.lua
--  The Loot Roll Popups card's Roll Window (opt-in, EllesmereUIDB.lootRollWindow):
--  every group loot roll as one row in a window of its own, with its Need,
--  Greed or Transmog and Pass buttons, in place of the popups. With Show Who
--  Rolled (lootRollWhoRolled) the buttons count the group's picks and list them
--  on hover, and a closed row shows the winner until it fades.
--
--  Blizzard's roll frames keep running, unseen: the game hears START_LOOT_ROLL
--  on a frame of its own, and a roll frame removed from addon code runs the
--  bottom managed container's Layout tainted. So only their alpha and mouse
--  are set, and any Lua error here hands the rolls back to them until a
--  reload, so a fault never costs a roll. A blocked RollOnLoot does the same.
--
--  Event-driven only: the countdown bar is a Scale animation over the roll's
--  time left, the seconds are a Cooldown's own countdown text, and a finished
--  row leaves by a delayed fade.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local WSkin = ns.WSkin
local PP = EllesmereUI.PP

local RW = {}
ns.LootRollWindow = RW
EllesmereUI._LootRollWindow = RW

local ROW_W, ROW_H, ROW_GAP, BTN = 320, 32, 2, 24
local RESULT_HOLD = 6   -- seconds a decided row stays
local RESULT_WAIT = 10  -- seconds a closed row waits for its result
local ROLL_TYPE = { need = 1, greed = 2, transmog = 4, pass = 0 }
local BUTTON_KEYS = { "pass", "greed", "need" }
local BLIZZARD_BUTTONS = { "NeedButton", "GreedButton", "TransmogButton", "PassButton" }
local EVENTS = {
    "START_LOOT_ROLL", "CANCEL_LOOT_ROLL", "CANCEL_ALL_LOOT_ROLLS", "MAIN_SPEC_NEED_ROLL",
    "PLAYER_ENTERING_WORLD", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
}
local SAMPLE_ICONS = {
    "Interface\\Icons\\INV_Sword_04", "Interface\\Icons\\INV_Chest_Cloth_17", "Interface\\Icons\\INV_Jewelry_Ring_03",
}

local anchor, ev, samples
local rows, rolls, active = {}, {}, {}
local on, hiding, registered = false, false, false
local failed, blocked, previewing = false, false, false
local Refresh, Fail

local function Enabled()
    return EllesmereUIDB and EllesmereUIDB.lootRollWindow == true and not (failed or blocked) or false
end

local function WhoRolled()
    return EllesmereUIDB and EllesmereUIDB.lootRollWhoRolled == true
end

local function Guard(fn)
    return function(...) return xpcall(fn, Fail, ...) end
end

-- Every alpha first, so a restore from Fail never stops halfway.
local function HideBlizzardFrames(hide)
    if hide == hiding then return end
    hiding = hide
    for i = 1, 4 do
        local f = _G["GroupLootFrame" .. i]
        if f then f:SetAlpha(hide and 0 or 1) end
    end
    for i = 1, 4 do
        local f = _G["GroupLootFrame" .. i]
        if f then
            local host = f.LootButtonContainer or f
            if f.IconFrame then f.IconFrame:EnableMouse(not hide) end
            for _, name in ipairs(BLIZZARD_BUTTONS) do
                if host[name] then host[name]:EnableMouse(not hide) end
            end
        end
    end
end

function Fail(err)
    if not failed then
        failed = true
        HideBlizzardFrames(false)
        if ev then ev:UnregisterAllEvents() end
        if anchor then anchor:Hide() end
        EllesmereUI.Print(EllesmereUI.L("The loot roll window hit an error, so Blizzard's roll popups are back until you reload."))
    end
    return geterrorhandler()(err)
end

-------------------------------------------------------------------------------
--  Rolls
-------------------------------------------------------------------------------
local function FreeSlot()
    local used = {}
    for _, roll in ipairs(active) do used[roll.slot] = true end
    local slot = 1
    while used[slot] do slot = slot + 1 end
    return slot
end

local function AddRoll(rollID, rollTime)
    if rolls[rollID] then return end
    local texture, name, count, quality, _, canNeed, canGreed, _, reasonNeed, reasonGreed, _, _, canTransmog =
        GetLootRollItemInfo(rollID)
    if not name then return end
    if not (rollTime and rollTime > 0) then rollTime = GetLootRollTimeLeft(rollID) end
    if not (type(rollTime) == "number" and rollTime > 0) then rollTime = 60000 end
    local link = GetLootRollItemLink(rollID)
    local roll = {
        id = rollID, open = true, slot = FreeSlot(),
        texture = texture, name = name, count = count, quality = quality, link = link,
        itemID = link and C_Item.GetItemInfoInstant(link),
        canNeed = canNeed, canGreed = canGreed, canTransmog = canTransmog,
        reasonNeed = reasonNeed, reasonGreed = reasonGreed,
        total = rollTime / 1000, ends = GetTime() + rollTime / 1000,
    }
    rolls[rollID] = roll
    active[#active + 1] = roll
end

local function RemoveRoll(roll)
    rolls[roll.id] = nil
    for i, other in ipairs(active) do
        if other == roll then
            table.remove(active, i)
            break
        end
    end
end

local function Decided(info)
    return info and (info.winner ~= nil or info.allPassed) or false
end

-- A closed row waits for its result with Show Who Rolled, then holds it.
local function CloseRoll(roll)
    roll.open = false
    roll.decided = WhoRolled() and Decided(roll.info)
    roll.wait = roll.decided and RESULT_HOLD or WhoRolled() and RESULT_WAIT or 0
end

-- A drop carries no rollID, so it goes to the roll for the same item; never a
-- decided drop to a roll that is still open (an earlier copy of the item).
local function OnDrop(encounterID, lootListID)
    local info = C_LootHistory.GetSortedInfoForDrop(encounterID, lootListID)
    local link = info and info.itemHyperlink
    if not link then return end
    local key = encounterID .. ":" .. lootListID
    local itemID = C_Item.GetItemInfoInstant(link)
    local decided = Decided(info)
    local found
    for _, roll in ipairs(active) do
        if roll.drop == key then
            found = roll
            break
        end
        if not found and not roll.drop and itemID and roll.itemID == itemID and not (roll.open and decided) then
            found = roll
        end
    end
    if not found then return end
    found.drop, found.info = key, info
    if decided and not found.open and not found.decided then
        found.decided, found.wait = true, RESULT_HOLD
    end
end

local function OnEvent(_, event, a, b, c)
    if event == "START_LOOT_ROLL" then
        AddRoll(a, b)
    elseif event == "CANCEL_LOOT_ROLL" then
        if rolls[a] then CloseRoll(rolls[a]) end
    elseif event == "MAIN_SPEC_NEED_ROLL" then
        local roll = rolls[a]
        if roll then
            roll.myRoll, roll.winning = b, c
            CloseRoll(roll)
        end
    elseif event == "CANCEL_ALL_LOOT_ROLLS" then
        wipe(rolls)
        wipe(active)
    elseif event == "LOOT_HISTORY_UPDATE_DROP" then
        OnDrop(a, b)
    elseif event == "PLAYER_ENTERING_WORLD" then
        for _, rollID in ipairs(GetActiveLootRollIDs()) do
            AddRoll(rollID, C_Loot.GetLootRollDuration(rollID))
        end
    else
        if a == ADDON_NAME and type(b) == "string" and b:find("RollOnLoot", 1, true) then
            blocked = true
            RW.Apply()
            EllesmereUI.Print(EllesmereUI.L("The game blocked a roll from the loot roll window, so Blizzard's roll popups are back until you reload."))
        end
        return
    end
    Refresh()
end

-------------------------------------------------------------------------------
--  Rows
-------------------------------------------------------------------------------
-- Roll kind, tooltip label, whether it can be rolled and the ineligible reason.
local function ButtonRoll(roll, key)
    if key == "need" then return "need", NEED, roll.canNeed, roll.reasonNeed end
    if key == "pass" then return "pass", PASS, true end
    if roll.canTransmog then return "transmog", TRANSMOGRIFICATION, true end
    return "greed", GREED, roll.canGreed, roll.reasonGreed
end

local function PlayerText(entry)
    local c = EllesmereUI.GetClassColor(entry.playerClass)
    local color = c and EllesmereUI.HexColor(c.r, c.g, c.b) or "|cffffffff"
    return color .. entry.playerName .. "|r" .. (entry.roll and ("  " .. entry.roll) or "")
end

local function ResultText(roll)
    local info = WhoRolled() and roll.info
    if info then
        if info.allPassed then return LOOT_HISTORY_ALL_PASSED end
        if info.winner then return PlayerText(info.winner) end
        if info.currentLeader then return PlayerText(info.currentLeader) end
    end
    if roll.myRoll then return EllesmereUI.L("You") .. ": " .. roll.myRoll end
    return ""
end

local function OnButtonClick(self)
    local roll = self.row.roll
    if not (roll and roll.open) or roll.sample then return end
    RollOnLoot(roll.id, ROLL_TYPE[ButtonRoll(roll, self.key)])
end

local function OnButtonEnter(self)
    local roll = self.row.roll
    if not roll then return end
    local _, label, can, reason = ButtonRoll(roll, self.key)
    local lines = { label }
    local why = not can and reason and _G["LOOT_ROLL_INELIGIBLE_REASON" .. reason]
    if why then lines[#lines + 1] = "|cffff4040" .. why .. "|r" end
    if roll.info and WhoRolled() then
        for _, entry in ipairs(roll.info.rollInfos) do
            if ns.LootRollPick(entry.state) == self.key then lines[#lines + 1] = PlayerText(entry) end
        end
    end
    EllesmereUI.ShowWidgetTooltip(self, table.concat(lines, "\n"))
end

local function OnButtonLeave()
    EllesmereUI.HideWidgetTooltip()
end

local function OnIconEnter(self)
    local roll = self:GetParent().roll
    if not roll or roll.sample then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetLootRollItem(roll.id)
    GameTooltip:Show()
end

local function OnFadeDone(group)
    local r = group:GetParent()
    if r.roll and not r.roll.sample then RemoveRoll(r.roll) end
    r.roll = nil
    Refresh()
end

local function CreateRow(i)
    local r = CreateFrame("Frame", nil, anchor)
    r:SetSize(ROW_W, ROW_H)
    r:SetPoint("BOTTOM", anchor, "BOTTOM", 0, (i - 1) * (ROW_H + ROW_GAP))
    r.bg = EllesmereUI.SolidTex(r, "BACKGROUND", 0, 0, 0, 0.75)
    r.bg:SetAllPoints()
    PP.CreateBorder(r, 0, 0, 0, 1, 1, "OVERLAY", 7)

    r.icon = CreateFrame("Button", nil, r)
    r.icon:SetSize(ROW_H, ROW_H)
    r.icon:SetPoint("LEFT")
    r.icon.tex = r.icon:CreateTexture(nil, "ARTWORK")
    r.icon.tex:SetAllPoints()
    r.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.icon:SetScript("OnEnter", Guard(OnIconEnter))
    r.icon:SetScript("OnLeave", GameTooltip_Hide)
    r.cd = CreateFrame("Cooldown", nil, r.icon, "CooldownFrameTemplate")
    r.cd:SetAllPoints()
    r.cd:SetDrawSwipe(false)
    r.cd:SetDrawEdge(false)
    r.cd:SetHideCountdownNumbers(false)

    r.buttons = {}
    for n, key in ipairs(BUTTON_KEYS) do
        local b = CreateFrame("Button", nil, r)
        b:SetSize(BTN, BTN)
        b:SetPoint("RIGHT", r, "RIGHT", -4 - (n - 1) * (BTN + 2), 0)
        b:SetMotionScriptsWhileDisabled(true)
        b.row, b.key = r, key
        b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        b.count:SetPoint("TOPRIGHT", 4, 2)
        b:SetScript("OnClick", Guard(OnButtonClick))
        b:SetScript("OnEnter", Guard(OnButtonEnter))
        b:SetScript("OnLeave", OnButtonLeave)
        r.buttons[n] = b
    end

    r.name = r:CreateFontString(nil, "OVERLAY")
    WSkin.Font(r.name, nil, nil, nil, 12)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r.buttons[#r.buttons], "LEFT", -6, 0)
    r.result = r:CreateFontString(nil, "OVERLAY")
    WSkin.Font(r.result, nil, nil, nil, 11)
    r.result:SetJustifyH("RIGHT")
    r.result:SetPoint("RIGHT", -6, 0)

    local eg = EllesmereUI.ELLESMERE_GREEN
    r.bar = EllesmereUI.SolidTex(r, "ARTWORK", eg.r, eg.g, eg.b, 0.9)
    r.bar:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 0, 0)
    r.bar:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
    r.bar:SetHeight(2)
    r.barAnim = r.bar:CreateAnimationGroup()
    r.barScale = r.barAnim:CreateAnimation("Scale")
    r.barScale:SetOrigin("LEFT", 0, 0)

    r.fade = r:CreateAnimationGroup()
    r.fade:SetToFinalAlpha(true)
    r.fadeAlpha = r.fade:CreateAnimation("Alpha")
    r.fadeAlpha:SetFromAlpha(1)
    r.fadeAlpha:SetToAlpha(0)
    r.fadeAlpha:SetDuration(0.4)
    r.fade:SetScript("OnFinished", Guard(OnFadeDone))

    rows[i] = r
    return r
end

-- The countdown runs on the game's clock from here; nothing redraws it.
local function StartCountdown(r, roll)
    local now = GetTime()
    local left = roll.sample and roll.total * 0.6 or math.max(0, roll.ends - now)
    r.cd:SetCooldown(now - (roll.total - left), roll.total)
    r.barAnim:Stop()
    r.barScale:SetScaleFrom(math.max(left / roll.total, 0.001), 1)
    r.barScale:SetScaleTo(0.001, 1)
    r.barScale:SetDuration(math.max(left, 0.01))
    r.bar:Show()
    r.barAnim:Play()
    if roll.sample then
        r.cd:Pause()
        r.barAnim:Pause()
    end
end

local function ApplyRoll(r, roll)
    if r.roll ~= roll then
        r.roll, r.fadeWait = roll, nil
        r.fade:Stop()
        r:SetAlpha(1)
        r.icon.tex:SetTexture(roll.texture)
        local qr, qg, qb = C_Item.GetItemQualityColor(roll.quality or 1)
        r.name:SetText(roll.name)
        r.name:SetTextColor(qr, qg, qb)
        PP.SetBorderColor(r, qr, qg, qb, 1)
        for _, b in ipairs(r.buttons) do
            local art = "lootroll-toast-icon-" .. ButtonRoll(roll, b.key)
            b:SetNormalAtlas(art .. "-up")
            b:SetPushedAtlas(art .. "-down")
            b:SetHighlightAtlas(art .. "-highlight", "ADD")
        end
        StartCountdown(r, roll)
    end
    local open = roll.open
    local who = WhoRolled() and roll.info
    for _, b in ipairs(r.buttons) do
        local _, _, can = ButtonRoll(roll, b.key)
        b:SetShown(open)
        b:SetEnabled(can and true or false)
        b:SetAlpha(can and 1 or 0.35)
        local n = 0
        if who then
            for _, entry in ipairs(who.rollInfos) do
                if ns.LootRollPick(entry.state) == b.key then n = n + 1 end
            end
        end
        b.count:SetText(n > 0 and n or "")
    end
    r.result:SetText(open and "" or ResultText(roll))
    if not open then
        r.cd:Clear()
        r.barAnim:Stop()
        r.bar:Hide()
        if r.fadeWait ~= roll.wait then
            r.fadeWait = roll.wait
            r.fade:Stop()
            r:SetAlpha(1)
            r.fadeAlpha:SetStartDelay(roll.wait)
            r.fade:Play()
        end
    end
end

-------------------------------------------------------------------------------
--  Window
-------------------------------------------------------------------------------
function RW.ApplyPosition()
    if not anchor then return end
    local pos = EllesmereUIDB and EllesmereUIDB.lootRollWindowPos
    anchor:ClearAllPoints()
    if pos then
        anchor:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
    else
        anchor:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 300)
    end
end

local function GetAnchor()
    if not anchor then
        anchor = CreateFrame("Frame", "EllesmereUILootRollWindow", UIParent)
        anchor:SetSize(ROW_W, ROW_H)
        anchor:SetFrameStrata("DIALOG")
        anchor:SetClampedToScreen(true)
        anchor:Hide()
        RW.ApplyPosition()
    end
    return anchor
end

-- Still sample rows for the preview: their timers are paused.
local function Samples()
    if not samples then
        local Q = Enum.ItemQuality
        samples = {}
        for i, quality in ipairs({ Q.Epic, Q.Rare, Q.Uncommon }) do
            samples[i] = {
                sample = true, open = true, slot = i, total = 60,
                texture = SAMPLE_ICONS[i], name = EllesmereUI.L("Sample Item"), quality = quality,
                canNeed = i ~= 3, canGreed = true, canTransmog = i == 2,
                reasonNeed = 1, info = ns.LootRollSample,
            }
        end
    end
    return samples
end

local function Draw()
    local list = active[1] and active or previewing and Samples() or nil
    if not (list and Enabled()) then
        if anchor then anchor:Hide() end
        return
    end
    GetAnchor():Show()
    local used = {}
    for _, roll in ipairs(list) do
        local r = rows[roll.slot] or CreateRow(roll.slot)
        used[r] = true
        r:Show()
        ApplyRoll(r, roll)
    end
    for _, r in pairs(rows) do
        if not used[r] then
            r.roll = nil
            r.fade:Stop()
            r:Hide()
        end
    end
end

function Refresh()
    xpcall(Draw, Fail)
end

local function RegisterUnlock()
    if registered or not (EllesmereUI.RegisterUnlockElements and EllesmereUI.MakeUnlockElement) then return end
    registered = true
    EllesmereUI:RegisterUnlockElements({
        EllesmereUI.MakeUnlockElement({
            key      = "EUI_LootRollWindow",
            label    = "Loot Roll Window",
            group    = "Blizzard Windows",
            order    = 651,
            noResize          = true,
            noAnchorTarget    = true,
            noAnchorTo        = true,
            noSizeMatchTarget = true,
            isHidden = function() return not Enabled() end,
            getFrame = GetAnchor,
            getSize  = function() return ROW_W, ROW_H end,
            savePos = function(_, _point, _relPoint, x, y)
                if not (x and y) then return end
                EllesmereUIDB.lootRollWindowPos = { x = x, y = y }
            end,
            loadPos = function()
                local pos = EllesmereUIDB and EllesmereUIDB.lootRollWindowPos
                if not pos then return nil end
                return { point = "CENTER", relPoint = "CENTER", x = pos.x, y = pos.y }
            end,
            clearPos = function()
                EllesmereUIDB.lootRollWindowPos = nil
                RW.ApplyPosition()
            end,
            applyPos = RW.ApplyPosition,
        })
    })
end

-- Options entry point and login: switches the window, and the loot history
-- event with Show Who Rolled, on or off.
local function Configure()
    local want = Enabled()
    if want ~= on then
        on = want
        if on then
            if not ev then
                ev = CreateFrame("Frame")
                ev:SetScript("OnEvent", Guard(OnEvent))
            end
            for _, event in ipairs(EVENTS) do ev:RegisterEvent(event) end
            RegisterUnlock()
            OnEvent(nil, "PLAYER_ENTERING_WORLD")
        else
            if ev then ev:UnregisterAllEvents() end
            wipe(rolls)
            wipe(active)
            previewing = false
        end
        HideBlizzardFrames(on)
    end
    if ev and on then
        if WhoRolled() then ev:RegisterEvent("LOOT_HISTORY_UPDATE_DROP") else ev:UnregisterEvent("LOOT_HISTORY_UPDATE_DROP") end
    end
    Refresh()
end

function RW.Apply()
    xpcall(Configure, Fail)
end

function RW.Enabled()
    return Enabled()
end

-- No argument: whether the preview shows.
function RW.Preview(show)
    if show == nil then return previewing end
    previewing = show and true or false
    Refresh()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if Enabled() then RW.Apply() end
end)
