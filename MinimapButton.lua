-- MinimapButton.lua — minimap button via LibDBIcon (a LibDataBroker launcher),
-- so minimap-button collectors (MBB, ChocolateBar, etc.) treat it as a
-- first-class citizen instead of stamping the "use LibDBIcon" warning on it.
--
-- The libs are fetched by the packager into Libs/ at release time only, so in
-- local dev they are absent — in that case we fall back to the original
-- self-contained button (no LibStub/Ace dependency). Both paths share the same
-- icon, click actions, tooltip, and SavedVars-driven show/hide.

local GBB = _G.GloomsBuildBarn
local ADDON = "GloomsBuildBarn"

local LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

-- Shared behavior ----------------------------------------------------------

local function onClick(_, mouseButton)
  if mouseButton == "RightButton" then
    if GBB.UI and GBB.UI.SetDocked then GBB.UI:SetDocked(not (GBB.db and GBB.db.docked)) end
  elseif GBB.UI and GBB.UI.Toggle then
    GBB.UI:Toggle()
  end
end

-- LibDBIcon manages its own drag, so the tooltip only advertises the clicks.
local function fillTooltip(tt)
  tt:SetText("Gloom's Build Barn", 1, 1, 1)
  tt:AddLine("Left-click: open", 0.8, 0.8, 0.8)
  tt:AddLine("Right-click: dock / undock", 0.8, 0.8, 0.8)
end

-- SavedVars: LibDBIcon writes hide + minimapPos into GBB.db.minimap. The
-- fallback reuses the same table (minimapPos as its angle) so position and
-- hidden state carry over if a release later swaps in the lib path.
local function ensureDB()
  if not GBB.db then return false end
  GBB.db.minimap = GBB.db.minimap or {}
  -- Migrate the pre-LibDBIcon flags (Session ≤209) into the shared table.
  if GBB.db.minimapHide ~= nil then
    GBB.db.minimap.hide = GBB.db.minimapHide
    GBB.db.minimapHide = nil
  end
  if GBB.db.minimapAngle ~= nil and GBB.db.minimap.minimapPos == nil then
    GBB.db.minimap.minimapPos = GBB.db.minimapAngle
    GBB.db.minimapAngle = nil
  end
  return true
end

-- LibDBIcon path -----------------------------------------------------------

local dataObject

local function registerBroker()
  dataObject = LDB:NewDataObject(ADDON, {
    type = "launcher",
    label = "Gloom's Build Barn",
    icon = GBB.MEDIA .. "minimap.png",
    OnClick = onClick,
    OnTooltipShow = fillTooltip,
  })
  LDBIcon:Register(ADDON, dataObject, GBB.db.minimap)
end

-- Self-contained fallback (the original button) ----------------------------

local btn

local function position(angle)
  local rad = math.rad(angle)
  local r = (Minimap:GetWidth() / 2) + 5
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

local function onDragUpdate()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local px, py = GetCursorPosition()
  px, py = px / scale, py / scale
  local angle = math.deg(math.atan2(py - my, px - mx))
  position(angle)
  GBB.db.minimap.minimapPos = angle
end

local function buildFallback()
  btn = CreateFrame("Button", "GloomsBuildBarnMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetSize(31, 31)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(GBB.MEDIA .. "minimap.png")
  icon:SetSize(22, 22) -- crest already has a transparent (badge-shaped) background
  icon:SetPoint("CENTER", 0, 1)

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  btn:SetScript("OnClick", onClick)
  btn:SetScript("OnDragStart", function() btn:SetScript("OnUpdate", onDragUpdate) end)
  btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    fillTooltip(GameTooltip)
    GameTooltip:AddLine("Drag: move around the minimap", 0.55, 0.55, 0.55)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  position(GBB.db.minimap.minimapPos or 200)
end

-- Public API ---------------------------------------------------------------

local function useLib()
  return LDB and LDBIcon
end

-- Create the button at login unless the user has hidden it.
function GBB:InitMinimapButton()
  if not ensureDB() then return end
  if useLib() then
    if not dataObject then registerBroker() end
    if GBB.db.minimap.hide then LDBIcon:Hide(ADDON) else LDBIcon:Show(ADDON) end
  else
    if btn then return end
    if not GBB.db.minimap.hide then buildFallback() end
  end
end

-- /gbb minimap — toggle the button on/off (persisted). Returns shown state.
function GBB:ToggleMinimapButton()
  if not ensureDB() then return end
  GBB.db.minimap.hide = not GBB.db.minimap.hide
  if useLib() then
    if not dataObject then registerBroker() end
    if GBB.db.minimap.hide then LDBIcon:Hide(ADDON) else LDBIcon:Show(ADDON) end
  else
    if GBB.db.minimap.hide then
      if btn then btn:Hide() end
    elseif btn then
      btn:Show()
    else
      buildFallback()
    end
  end
  return not GBB.db.minimap.hide
end
