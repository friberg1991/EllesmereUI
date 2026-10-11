if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EllesmereUI and EllesmereUI.IS_FOREVER then return end -- retail vendor window only: the options row is not built on WoW Forever
-------------------------------------------------------------------------------
--  EllesmereUIQoL_BulkBuy.lua
--  Buy in Bulk: a Shift-click on a vendor's item opens a small amount
--  window in place of Blizzard's stack split box, for any amount that can be
--  paid for and fits in the bags. The server sells one stack per call, so a
--  larger amount is sent a stack at a time, each once the one before is paid;
--  an error message or the vendor window closing ends it.
--  Off by default: nothing is built or hooked until it is turned on.
-------------------------------------------------------------------------------
local EUI = EllesmereUI
local PP  = EUI.PP

local EDGE = 6  -- inset kept from the vendor window's edges
-- What can change the offer, or says a purchase was paid.
local WATCHED = { "MERCHANT_CLOSED", "MERCHANT_UPDATE", "PLAYER_MONEY", "CURRENCY_DISPLAY_UPDATE", "BAG_UPDATE_DELAYED" }

local active, hooked = false, false
local win, offer, amount
local order  -- the offer being bought when it takes more than one call

local function Enabled()
    return EllesmereUIDB and EllesmereUIDB.bulkBuy == true
end

-- nil for a currency the client has no info for.
local function Held(cost)
    if cost.kind == "gold" then return GetMoney() end
    if cost.kind == "item" then return C_Item.GetItemCount(cost.link, false, false, true) end
    local info = C_CurrencyInfo.GetCurrencyInfoFromLink(cost.link)
    return info and info.quantity
end

-- nil where the click stays Blizzard's: a currency for sale, not purchasable,
-- sold out, or nothing to pay with.
local function Offer(index)
    local info = C_MerchantFrame.GetItemInfo(index)
    local link = GetMerchantItemLink(index)
    if not (info and link and info.isPurchasable) or info.currencyID or info.numAvailable == 0 then return end
    local lot, size = info.stackCount, GetMerchantItemMaxStack(index)
    local stack = math.max(size - size % lot, lot)  -- the most one call buys

    local costs = {}
    if info.price and info.price > 0 then costs[1] = { kind = "gold", per = info.price } end
    if info.hasExtendedCost then
        for i = 1, MAX_ITEM_COST do
            local texture, per, costLink, currency = GetMerchantItemCostItem(index, i)
            if costLink and per > 0 then
                costs[#costs + 1] = { kind = currency and "currency" or "item", per = per, link = costLink, texture = texture }
            end
        end
    end

    -- A free item has no payment to wait for, so it stays at one call.
    local most = costs[1] and math.huge or stack
    for _, cost in ipairs(costs) do
        local held = Held(cost)
        if not held then return end
        most = math.min(most, math.floor(held / cost.per) * lot)
    end
    if info.numAvailable > 0 then most = math.min(most, info.numAvailable) end
    if most < lot then return end
    return {
        index = index, itemID = GetMerchantItemID(index), link = link,
        lot = lot, stack = stack, size = size, most = most, costs = costs,
    }
end

-- What can be paid for and fits: the free slots of the plain bags plus the
-- rest of a stack already begun, in whole lots.
local function Fits()
    local slots = 0
    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        local free, family = C_Container.GetContainerNumFreeSlots(bag)
        if family == 0 then slots = slots + free end
    end
    local size = offer.size
    local n = math.min(offer.most, slots * size + (size - C_Item.GetItemCount(offer.link) % size) % size)
    return n - n % offer.lot
end

local function Snap(n)
    return math.max(offer.lot, math.min(n - n % offer.lot, Fits()))
end

-------------------------------------------------------------------------------
--  Buying
-------------------------------------------------------------------------------
local function Stop()
    order = nil
    win:UnregisterAllEvents()
end

local function BuyNext()
    local o = order
    if GetMerchantItemID(o.index) ~= o.itemID then return Stop() end
    o.sent, o.held = math.min(o.left, o.stack), Held(o.costs[1])
    BuyMerchantItem(o.index, o.sent)
end

local function Buy()
    if GetMerchantItemID(offer.index) ~= offer.itemID then return end
    if amount <= offer.stack then return BuyMerchantItem(offer.index, amount) end
    order, offer.left = offer, amount
    for _, event in ipairs(WATCHED) do win:RegisterEvent(event) end
    win:RegisterEvent("UI_ERROR_MESSAGE")
    BuyNext()
end

-------------------------------------------------------------------------------
--  Window
-------------------------------------------------------------------------------
local function SetStep(b, on)
    b:SetEnabled(on)
    b:SetAlpha(on and 0.8 or 0.25)
end

local function Paint()
    local lots, parts = amount / offer.lot, {}
    for i, cost in ipairs(offer.costs) do
        local total = lots * cost.per
        parts[i] = cost.kind == "gold" and GetMoneyString(total, true)
            or ("%s |T%s:0|t"):format(BreakUpLargeNumbers(total), cost.texture)
    end
    win.total:SetText(parts[1] and table.concat(parts, "  ") or GetMoneyString(0))
    win.amount:SetText(BreakUpLargeNumbers(amount))
    SetStep(win.less, amount > offer.lot)
    SetStep(win.more, amount < Fits())
end

local function SetAmount(n)
    amount = Snap(n)
    Paint()
end

local function OnEvent(self, event)
    if order then
        local held = Held(order.costs[1])
        if event == "UI_ERROR_MESSAGE" or event == "MERCHANT_CLOSED" then
            Stop()
        elseif held and order.held and held < order.held then
            order.left = order.left - order.sent
            if order.left > 0 then BuyNext() else Stop() end
        end
    else
        local now = event ~= "MERCHANT_CLOSED" and Offer(offer.index)
        if not now or now.itemID ~= offer.itemID then return self:Hide() end
        offer = now
        SetAmount(amount)
    end
end

-- The window wears the Blizzard skin's stack split look: its font, fills and
-- borders, and the window-frame atlas its shells use.
local function MakeLabel(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local flags = EUI.GetFontOutlineFlag("blizzardSkin") or ""
    EUI.PrimeFontShadow(fs, flags == "")
    fs:SetFont(EUI.GetFontPath("blizzardSkin") or "Fonts\\FRIZQT__.TTF", size, flags)
    fs:SetTextColor(1, 1, 1, 1)
    return fs
end

local function Button(w, h, label, onClick)
    local b = CreateFrame("Button", nil, win)
    b:SetSize(w, h)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.92)
    PP.CreateBorder(b, 0.2, 0.2, 0.2, 1, 1, "OVERLAY", 7)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.1)
    local fs = MakeLabel(b, 11)
    fs:SetPoint("CENTER")
    fs:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function Arrow(side, onClick)
    local b = CreateFrame("Button", nil, win)
    b:SetSize(14, 14)
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-" .. side .. ".png")
    b:SetScript("OnClick", onClick)
    return b
end

local function Build()
    win = CreateFrame("Frame", nil, UIParent)
    win:SetSize(172, 110)
    win:SetFrameStrata("DIALOG")
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:EnableMouseWheel(true)
    win:Hide()

    local bg = win:CreateTexture(nil, "BACKGROUND", nil, 0)
    bg:SetAllPoints()
    bg:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png")
    bg:SetTexCoord(0.25, 1, 0, 0.75)
    local overlay = win:CreateTexture(nil, "BACKGROUND", nil, 1)
    overlay:SetAllPoints()
    overlay:SetColorTexture(0, 0, 0, 0.62)
    local edge = win:CreateTexture(nil, "OVERLAY", nil, 7)
    edge:SetAllPoints()
    edge:SetAtlas("AdventureMap_TopBorder")

    local field = CreateFrame("Frame", nil, win)
    field:SetSize(113, 22)
    field:SetPoint("TOP", 0, -10)
    local fieldBg = field:CreateTexture(nil, "BACKGROUND")
    fieldBg:SetAllPoints()
    fieldBg:SetColorTexture(0.04, 0.04, 0.04, 0.85)
    PP.CreateBorder(field, 0.2, 0.2, 0.2, 1, 1, "OVERLAY", 7)
    win.amount = MakeLabel(field, 12)
    win.amount:SetPoint("CENTER")
    win.total = MakeLabel(win, 11)
    win.total:SetPoint("TOP", field, "BOTTOM", 0, -5)
    win.less = Arrow("left", function() SetAmount(amount - offer.lot) end)
    win.less:SetPoint("RIGHT", field, "LEFT", -6, 0)
    win.more = Arrow("right", function() SetAmount(amount + offer.lot) end)
    win.more:SetPoint("LEFT", field, "RIGHT", 6, 0)

    local buy = Button(64, 24, EllesmereUI.L("Buy"), function() win:Hide(); Buy() end)
    buy:SetPoint("BOTTOMRIGHT", win, "BOTTOM", -4, 10)
    local cancel = Button(64, 24, EllesmereUI.L("Cancel"), function() win:Hide() end)
    cancel:SetPoint("BOTTOMLEFT", win, "BOTTOM", 4, 10)
    -- Stack: up to the next full stack.
    local stack = Button(64, 20, EllesmereUI.L("Stack"), function() SetAmount(amount - amount % offer.stack + offer.stack) end)
    stack:SetPoint("BOTTOM", buy, "TOP", 0, 4)
    local max = Button(64, 20, EllesmereUI.L("Max"), function() SetAmount(offer.most) end)
    max:SetPoint("BOTTOM", cancel, "TOP", 0, 4)

    win:SetScript("OnMouseWheel", function(_, delta) SetAmount(amount + delta * offer.lot) end)
    win:SetScript("OnEvent", OnEvent)
    win:SetScript("OnHide", function(self) self:UnregisterAllEvents() end)
end

local function Open(o, button)
    if not win then Build() end
    -- Where Blizzard opens its stack split box, kept inside the vendor window.
    local s = MerchantFrame:GetEffectiveScale() / win:GetEffectiveScale()
    local x = (button:GetLeft() - MerchantFrame:GetLeft()) * s
    local y = (button:GetTop() - MerchantFrame:GetBottom()) * s
    x = math.max(EDGE, math.min(x, MerchantFrame:GetWidth() * s - win:GetWidth() - EDGE))
    y = math.max(EDGE, math.min(y, MerchantFrame:GetHeight() * s - win:GetHeight() - EDGE))
    win:ClearAllPoints()
    win:SetPoint("BOTTOMLEFT", MerchantFrame, "BOTTOMLEFT", x, y)
    offer = o
    SetAmount(o.lot)
    for _, event in ipairs(WATCHED) do win:RegisterEvent(event) end
    win:Show()
end

-- Blizzard's stack split box just opened on the item marks an amount click.
-- A non-stacking item gets no box, so there an open chat edit box (a link
-- click) rules it out.
local function OnModifiedClick(button)
    if not active or order then return end
    if MerchantFrame.selectedTab ~= 1 or not IsModifiedClick("SPLITSTACK") then return end
    local index = button:GetID()
    local box = StackSplitFrame:IsShown() and StackSplitFrame.owner == button
    if not box and (GetMerchantItemMaxStack(index) > 1 or ChatFrameUtil.GetActiveWindow()) then return end
    local o = Offer(index)
    if not o then return end
    Open(o, button)
    if box then StackSplitFrame:Hide() end
end

local function Apply()
    active = Enabled()
    if active and not hooked then
        hooked = true
        hooksecurefunc("MerchantItemButton_OnModifiedClick", OnModifiedClick)
    end
    if win and not active then win:Hide() end
end
EllesmereUI._applyBulkBuy = Apply
Apply()
