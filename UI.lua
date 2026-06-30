-- UI.lua — Gloom's Build Barn window (DS 2.0 skin)
--
-- Single-column, progressive-disclosure panel matching the hodguild.com design:
--   • content/difficulty switches (M+/Raids, Heroic/Mythic) with accent labels
--   • a bordered boss/dungeon icon strip (tooltips on hover)
--   • pick a boss/dungeon → its title + your class's top DPS/HPS line + spec list
--   • pick a spec's Best/Popular build → details (+ similarity to your current
--     build) + Apply + a conditional "Changes If Applied" breakdown
-- Docked (rides the in-game Talents window) or standalone — see the docking
-- section. Colours/fonts come from GBB.COLOR / GBB.FONT (Core.lua).

local GBB = _G.GloomsBuildBarn
local UI = {}
GBB.UI = UI

-- section "raid"|"mythicplus"; diff 4|5; encId; selected spec + build key.
-- encId nil = landing view (strip + logo). selSpec nil = boss picked, choosing spec.
local state = { section = "raid", diff = 5, encId = nil, selSpec = nil, selBuild = nil, docked = false, heatmap = false }

local frame
local encButtons, specRows = {}, {}

local PANEL_W, PANEL_H, INSET = 380, 800, 20 -- PANEL_H = undocked height; docked matches the Talents window
local CONTENT_W = PANEL_W - INSET * 2          -- 340
local ICON, PITCH, COLS = 32, 42, 8            -- strip grid

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local ROLE_LABEL = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
local DEFAULT_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function shortNum(n)
  if not n then return "?" end
  if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
  return tostring(math.floor(n + 0.5))
end

local function comma(n)
  if not n then return "?" end
  local s = tostring(math.floor(n + 0.5))
  while true do
    local s2, k = s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
    s = s2
    if k == 0 then break end
  end
  return s
end

local function classColor()
  local classToken = GBB:PlayerClass()
  local c = classToken and (RAID_CLASS_COLORS or {})[classToken]
  return c or { r = 1, g = 0.82, b = 0 }
end

local function hex(cc) return cc.hex or ("%02x%02x%02x"):format(
  math.floor(cc.r * 255 + 0.5), math.floor(cc.g * 255 + 0.5), math.floor(cc.b * 255 + 0.5)) end

local function className() return (UnitClass("player")) or "your class" end
local function metricUnit(metric) return metric == "hps" and "hps" or "dps" end
-- Unit for a spec: healers = HPS, everyone else = DPS (role is the reliable tell).
local function specUnit(spec)
  if spec and (spec.role == "HEALER" or spec.metric == "hps") then return "hps" end
  return "dps"
end

-- Apply a bundled font with a graceful fallback to the default game font.
local function setFont(fs, path, size, flags)
  if not fs:SetFont(path, size, flags or "") then fs:SetFont(DEFAULT_FONT, size, flags or "") end
end

local function newText(parent, font, size, r, g, b, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  setFont(fs, font, size)
  if r then fs:SetTextColor(r, g, b) end
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Four 1px edge textures forming a squared border on `f` (a frame/texture host).
local function addEdges(f, r, g, b, a, thick)
  thick = thick or 1
  local e = {}
  local function edge(p1, p2, w, h)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(r, g, b, a)
    t:SetPoint(p1); t:SetPoint(p2)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
    return t
  end
  e.top = edge("TOPLEFT", "TOPRIGHT", nil, thick)
  e.bottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, thick)
  e.left = edge("TOPLEFT", "BOTTOMLEFT", thick, nil)
  e.right = edge("TOPRIGHT", "BOTTOMRIGHT", thick, nil)
  e.SetColor = function(_, nr, ng, nb, na)
    for _, t in pairs({ e.top, e.bottom, e.left, e.right }) do t:SetColorTexture(nr, ng, nb, na or 1) end
  end
  return e
end

-- Flat solid-fill button (no border, per the Figma). Opacity is the ONLY state:
-- _base (default 50%) vs active (100%). The colour is fully opaque and the level
-- is driven purely by SetAlpha — never bake alpha into the colour too, or the two
-- multiply and the button darkens on hover instead of brightening.
local function makeOutlineButton(parent, w, h, cc, label, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  b._base, b._active = 0.5, false
  b.fill = b:CreateTexture(nil, "BACKGROUND")
  b.fill:SetAllPoints()
  b.fill:SetColorTexture(cc.r, cc.g, cc.b, 1)
  b.fill:SetAlpha(b._base)
  b.text = newText(b, GBB.FONT.label, size or 11, 1, 1, 1, "CENTER")
  b.text:SetPoint("CENTER")
  b:SetFontString(b.text) -- wire the fontstring so b:SetText() actually updates it
  if label then b.text:SetText(label) end
  local function level() return b._active and 1 or b._base end
  b:SetScript("OnEnter", function(self) if not self._active then self.fill:SetAlpha(math.min(1, self._base + 0.22)) end end)
  b:SetScript("OnLeave", function(self) self.fill:SetAlpha(level()) end)
  function b:SetActive(a) self._active = a and true or false; self.fill:SetAlpha(level()) end
  function b:SetBase(a) self._base = a; self.fill:SetAlpha(level()) end
  return b
end

-- A binary switch: [leftLabel] [track+knob] [rightLabel]. value=false→left, true→right.
-- colorFor(value) returns the accent colour for the SELECTED label.
local function makeSwitch(parent, leftText, rightText, colorFor, onChange)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(150, 22)
  s.value = false

  s.left = CreateFrame("Button", nil, s)
  s.left.text = newText(s.left, GBB.FONT.label, 12, 1, 1, 1, "RIGHT")
  s.left.text:SetText(leftText); s.left.text:SetAllPoints()
  s.left:SetSize(s.left.text:GetStringWidth() + 2, 16)
  s.left:SetPoint("LEFT", 0, 0)

  s.track = CreateFrame("Button", nil, s)
  s.track:SetSize(50, 24)
  s.track:SetPoint("LEFT", s.left, "RIGHT", 10, 0)
  s.track.fill = s.track:CreateTexture(nil, "BACKGROUND")
  s.track.fill:SetAllPoints(); s.track.fill:SetColorTexture(1, 1, 1, 0.2)
  s.track.knob = s.track:CreateTexture(nil, "ARTWORK")
  s.track.knob:SetSize(18, 14)
  s.track.knob:SetColorTexture(1, 1, 1, 1) -- white knob

  s.right = CreateFrame("Button", nil, s)
  s.right.text = newText(s.right, GBB.FONT.label, 12, 1, 1, 1, "LEFT")
  s.right.text:SetText(rightText); s.right.text:SetAllPoints()
  s.right:SetSize(s.right.text:GetStringWidth() + 2, 16)
  s.right:SetPoint("LEFT", s.track, "RIGHT", 10, 0)

  local function refresh()
    local k = s.track.knob
    k:ClearAllPoints()
    if s.value then k:SetPoint("RIGHT", -3, 0) else k:SetPoint("LEFT", 3, 0) end
    s.left.text:SetTextColor(s.value and 0.6 or colorFor(false).r, s.value and 0.6 or colorFor(false).g, s.value and 0.6 or colorFor(false).b)
    s.right.text:SetTextColor(s.value and colorFor(true).r or 0.6, s.value and colorFor(true).g or 0.6, s.value and colorFor(true).b or 0.6)
  end
  local function set(v)
    if s.value == v then return end
    s.value = v; refresh(); if onChange then onChange(v) end
  end
  s.track:SetScript("OnClick", function() set(not s.value) end)
  s.left:SetScript("OnClick", function() set(false) end)
  s.right:SetScript("OnClick", function() set(true) end)
  function s:Set(v) s.value = v and true or false; refresh() end
  function s:Refresh() refresh() end
  refresh()
  return s
end

-- The bundled custom spec icon for (classToken, specName), or nil to fall back
-- to the game's built-in spec icon. Suffix differs per class (resto vs restoration).
local SPEC_FILE = {
  WARLOCK = { class = "warlock", Affliction = "affliction", Demonology = "demo", Destruction = "destro" },
  DEATHKNIGHT = { class = "dk", Blood = "blood", Frost = "frost", Unholy = "unholy" },
  DEMONHUNTER = { class = "dh", Havoc = "havoc", Vengeance = "vengeance", Devourer = "devourer" },
  DRUID = { class = "druid", Balance = "balance", Feral = "feral", Guardian = "guardian", Restoration = "restoration" },
  EVOKER = { class = "evoker", Devastation = "devastation", Preservation = "preservation", Augmentation = "augmentation" },
  HUNTER = { class = "hunter", ["Beast Mastery"] = "bm", Marksmanship = "mm", Survival = "survival" },
  MAGE = { class = "mage", Arcane = "arcane", Fire = "fire", Frost = "frost" },
  MONK = { class = "monk", Brewmaster = "brewmaster", Mistweaver = "mistweaver", Windwalker = "windwalker" },
  PALADIN = { class = "paladin", Holy = "holy", Protection = "prot", Retribution = "ret" },
  PRIEST = { class = "priest", Discipline = "disc", Holy = "holy", Shadow = "shadow" },
  ROGUE = { class = "rogue", Assassination = "assassination", Outlaw = "outlaw", Subtlety = "subtlety" },
  SHAMAN = { class = "shaman", Elemental = "elemental", Enhancement = "enhance", Restoration = "resto" },
  WARRIOR = { class = "warrior", Arms = "arms", Fury = "fury", Protection = "prot" },
}
local function specIconPath(classToken, specName)
  local m = classToken and SPEC_FILE[classToken]
  local suffix = m and m[specName]
  if not (m and suffix) then return nil end
  return GBB.MEDIA .. "icons\\specs\\hod_" .. m.class .. "_" .. suffix .. ".png"
end

local function encIconPath(encId) return GBB.MEDIA .. "icons\\encounters\\" .. tostring(encId) .. ".png" end

local function diffColor() return GBB.DIFF_COLOR[state.diff] or GBB.COLOR.mythic end
local function stripAccent() return state.section == "raid" and diffColor() or GBB.COLOR.purple end

-- ---------------------------------------------------------------------------
-- frame construction
-- ---------------------------------------------------------------------------
local function buildFrame()
  frame = CreateFrame("Frame", "GloomsBuildBarnFrame", UIParent)
  frame:SetSize(PANEL_W, PANEL_H)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "GloomsBuildBarnFrame")

  -- background: the DS2 flame plate, on a near-black base, with a 1px rim.
  frame.bgBase = frame:CreateTexture(nil, "BACKGROUND")
  frame.bgBase:SetAllPoints(); frame.bgBase:SetColorTexture(0.04, 0.055, 0.10, 0.96)
  frame.bg = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  frame.bg:SetAllPoints(); frame.bg:SetTexture(GBB.MEDIA .. "bg_flame.png")
  frame.bg:SetAlpha(0.55)
  frame.rim = addEdges(frame, 1, 1, 1, 0.10)

  -- top-right controls: dock toggle + close.
  frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  frame.closeBtn:SetSize(28, 28)
  frame.closeBtn:SetPoint("TOPRIGHT", 2, 2)
  frame.closeBtn:SetScript("OnClick", function() UI:Hide() end)

  frame.dockBtn = makeOutlineButton(frame, 64, 18, GBB.COLOR.purple, "Dock", 10)
  frame.dockBtn:SetBase(0.9)
  frame.dockBtn:SetPoint("TOPRIGHT", -30, -6)
  frame.dockBtn:SetScript("OnClick", function() UI:SetDocked(not state.docked) end)

  -- header label
  frame.header = newText(frame, GBB.FONT.label, 12, 1, 1, 1)
  frame.header:SetPoint("TOPLEFT", INSET, -20)
  frame.header:SetText("CHOOSE CONTENT TYPE/DIFFICULTY:")

  -- content + difficulty switches (one row)
  frame.contentSwitch = makeSwitch(frame, "M+", "RAIDS",
    function(_) return GBB.COLOR.green end,
    function(toRaids) UI:SetSection(toRaids and "raid" or "mythicplus") end)
  frame.contentSwitch:SetPoint("TOPLEFT", INSET, -42)

  frame.diffSwitch = makeSwitch(frame, "Heroic", "Mythic",
    function(isMythic) return isMythic and GBB.COLOR.mythic or GBB.COLOR.heroic end,
    function(isMythic) UI:SetDiff(isMythic and 5 or 4) end)
  frame.diffSwitch:SetPoint("TOPRIGHT", -INSET, -42)

  -- strip header + "go back" link share the same slot.
  frame.stripHeader = newText(frame, GBB.FONT.label, 12, 1, 1, 1)
  frame.stripHeader:SetPoint("TOPLEFT", INSET, -98)
  frame.backBoss = CreateFrame("Button", nil, frame)
  frame.backBoss:SetPoint("TOPLEFT", INSET, -104)
  frame.backBoss.text = newText(frame.backBoss, GBB.FONT.body, 10, 0.82, 0.84, 0.9)
  frame.backBoss.text:SetText("Select a Different Boss")
  frame.backBoss.text:SetPoint("TOPLEFT")
  frame.backBoss:SetSize(160, 14)
  frame.backBoss:SetScript("OnClick", function() UI:SelectEncounter(nil) end)
  frame.backBoss:SetScript("OnEnter", function(s) s.text:SetTextColor(1, 1, 1) end)
  frame.backBoss:SetScript("OnLeave", function(s) s.text:SetTextColor(0.82, 0.84, 0.9) end)

  -- strip container (icon grid)
  frame.strip = CreateFrame("Frame", nil, frame)
  frame.strip:SetPoint("TOPLEFT", INSET, -122)
  frame.strip:SetSize(CONTENT_W, 90)

  -- boss/dungeon title + top line (shown once an encounter is picked)
  frame.encTitle = newText(frame, GBB.FONT.titleMed, 22, 1, 1, 1)
  frame.encTitle:SetPoint("TOPLEFT", INSET, -124)
  -- (no fixed width — the title auto-sizes so the back icon can sit at its end)

  -- clickable "back" icon right after the boss name (clears the selection).
  -- Uses a built-in texture; swap for a custom PNG by changing the SetTexture line.
  frame.backIcon = CreateFrame("Button", nil, frame)
  frame.backIcon:SetSize(18, 18)
  frame.backIcon:SetPoint("LEFT", frame.encTitle, "RIGHT", 8, 0)
  frame.backIcon.tex = frame.backIcon:CreateTexture(nil, "ARTWORK")
  frame.backIcon.tex:SetAllPoints()
  frame.backIcon.tex:SetAtlas("common-icon-undo")
  if not (frame.backIcon.tex.GetAtlas and frame.backIcon.tex:GetAtlas()) then
    frame.backIcon.tex:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
  end
  frame.backIcon:SetScript("OnClick", function() UI:SelectEncounter(nil) end)
  frame.backIcon:SetScript("OnEnter", function(self)
    self.tex:SetVertexColor(1, 0.85, 0.4)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(state.section == "mythicplus" and "Choose a different dungeon" or "Choose a different boss", 1, 1, 1)
    GameTooltip:Show()
  end)
  frame.backIcon:SetScript("OnLeave", function(self) self.tex:SetVertexColor(1, 1, 1); GameTooltip:Hide() end)

  frame.topLine = newText(frame, GBB.FONT.bodyMed, 12, 1, 1, 1)
  frame.topLine:SetPoint("TOPLEFT", INSET, -151)
  frame.topLine:SetWidth(CONTENT_W)

  -- talent heatmap toggle — bottom-pinned: label + subtitle + OFF/ON switch.
  frame.heatSub = newText(frame, GBB.FONT.body, 10, 0.78, 0.80, 0.86)
  frame.heatSub:SetPoint("BOTTOMLEFT", INSET, 18)
  frame.heatTitle = newText(frame, GBB.FONT.label, 12, 1, 1, 1)
  frame.heatTitle:SetText("TALENT HEATMAP")
  frame.heatTitle:SetPoint("BOTTOMLEFT", frame.heatSub, "TOPLEFT", 0, 3)
  frame.heatSwitch = makeSwitch(frame, "OFF", "ON",
    function(isOn) return isOn and GBB.COLOR.green or { r = 1, g = 1, b = 1 } end,
    function(isOn) UI:SetHeatmap(isOn) end)
  local hs = frame.heatSwitch
  hs:SetWidth(hs.left:GetWidth() + hs.track:GetWidth() + hs.right:GetWidth() + 20) -- fit, so ON sits at the edge
  hs:SetPoint("BOTTOMRIGHT", -INSET, 20)
  -- cap the subtitle so it wraps to a 2nd line instead of colliding with the switch
  frame.heatSub:SetWidth(PANEL_W - INSET * 2 - hs:GetWidth() - 14)
  frame.heatSub:SetWordWrap(true)

  -- spec list container
  frame.specList = CreateFrame("Frame", nil, frame)
  frame.specList:SetPoint("TOPLEFT", INSET, -197)
  frame.specList:SetSize(CONTENT_W, 200)

  -- When the heatmap is ON the spec/build area is inactive — this eats clicks over
  -- it (so the dimmed buttons are truly disabled), shown only while heatmapping.
  frame.heatBlocker = CreateFrame("Frame", nil, frame)
  frame.heatBlocker:SetFrameStrata("HIGH")
  frame.heatBlocker:SetFrameLevel(frame:GetFrameLevel() + 100)
  frame.heatBlocker:SetPoint("TOPLEFT", frame.specList, "TOPLEFT", -INSET, 8)
  frame.heatBlocker:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 60)
  frame.heatBlocker:EnableMouse(true)
  frame.heatBlocker:Hide()

  -- build detail (anchored under the spec list at render time)
  local d = CreateFrame("Frame", nil, frame)
  d:SetSize(CONTENT_W, 360)
  frame.detail = d

  -- The spec list stays visible above; the build buttons themselves are the
  -- persistent selector, so no "back to spec" affordance is needed here.
  d.title = newText(d, GBB.FONT.title, 22, 1, 1, 1)
  d.title:SetPoint("TOPLEFT", 0, 0)

  -- four detail lines, each label (regular) + value (semibold/white).
  d.lines = {}
  for i = 1, 4 do
    local row = {}
    row.label = newText(d, GBB.FONT.body, 12, 0.78, 0.80, 0.86)
    row.value = newText(d, GBB.FONT.label, 12, 1, 1, 1)
    d.lines[i] = row
  end

  d.apply = makeOutlineButton(d, CONTENT_W, 30, GBB.COLOR.purple, "Apply This Build Now", 13)
  d.apply:SetBase(0.9)
  d.apply:SetScript("OnClick", function() UI:ApplySelected() end)

  d.changesLabel = newText(d, GBB.FONT.label, 12, 1, 1, 1)
  d.changesLabel:SetText("CHANGES IF APPLIED:")

  -- shown instead of the changes blocks when the selected build is already active
  d.appliedNote = newText(d, GBB.FONT.bodyMed, 12, GBB.COLOR.green.r, GBB.COLOR.green.g, GBB.COLOR.green.b)
  d.appliedNote:SetText("This build is currently applied.")

  -- three change blocks (added/changed/removed): tinted panel + wrapped text.
  local function changeBlock(tagColor, glowTex)
    local blk = CreateFrame("Frame", nil, d)
    blk:SetSize(CONTENT_W, 40)
    blk.bg = blk:CreateTexture(nil, "BACKGROUND"); blk.bg:SetAllPoints()
    blk.bg:SetColorTexture(tagColor.r, tagColor.g, tagColor.b, 0.10)
    blk.text = newText(blk, GBB.FONT.body, 11, 0.92, 0.92, 0.95)
    blk.text:SetPoint("TOPLEFT", 10, -8); blk.text:SetPoint("TOPRIGHT", -10, -8)
    blk.text:SetJustifyV("TOP"); blk.text:SetSpacing(2)
    blk._tag = tagColor
    blk._glowTex = glowTex
    -- hover → pulse this category's nodes in the live Talents tree
    blk:EnableMouse(true)
    blk:SetScript("OnEnter", function(self)
      if self._nodes and #self._nodes > 0 then
        GBB:HighlightNodes(self._nodes, self._glowTex)
      end
    end)
    blk:SetScript("OnLeave", function() GBB:ClearNodeHighlights() end)
    return blk
  end
  d.added = changeBlock(GBB.COLOR.green, GBB.MEDIA .. "glow_add.png")
  d.changed = changeBlock(GBB.COLOR.mythic, GBB.MEDIA .. "glow_change.png")
  d.removed = changeBlock({ r = 1, g = 0.27, b = 0.27 }, GBB.MEDIA .. "glow_remove.png")

  -- landing (logo + footer) — only when no encounter is selected.
  frame.logo = frame:CreateTexture(nil, "ARTWORK")
  frame.logo:SetTexture(GBB.MEDIA .. "hod_gbb_lockup.png")
  frame.logo:SetSize(260, 139)            -- 460x246 lockup, scaled to width 260
  frame.logo:SetPoint("CENTER", frame, "TOP", 0, -430)
  frame.footer = newText(frame, GBB.FONT.body, 11, 0.55, 0.58, 0.66, "CENTER")
  frame.footer:SetPoint("BOTTOM", 0, 18); frame.footer:SetWidth(CONTENT_W)
end

-- ---------------------------------------------------------------------------
-- encounter strip
-- ---------------------------------------------------------------------------
local function acquireEncButton(i)
  if encButtons[i] then return encButtons[i] end
  local b = CreateFrame("Button", nil, frame.strip)
  b:SetSize(ICON, ICON)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints(); b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.edges = addEdges(b, 1, 1, 1, 1)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self._name or "", 1, 1, 1)
    if self._sub then GameTooltip:AddLine(self._sub, 0.7, 0.7, 0.7) end
    GameTooltip:Show()
    self.icon:SetVertexColor(1.15, 1.15, 1.15)
  end)
  b:SetScript("OnLeave", function(self) GameTooltip:Hide(); self.icon:SetVertexColor(1, 1, 1) end)
  encButtons[i] = b
  return b
end

local function renderStrip()
  local list = GBB:EncounterList(state.section)
  local acc = stripAccent()
  for i, e in ipairs(list) do
    local b = acquireEncButton(i)
    local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", col * PITCH, -row * PITCH)
    b.icon:SetTexture(encIconPath(e.id))
    b.edges:SetColor(acc.r, acc.g, acc.b, 1)
    b._name = e.name
    b._sub = (state.section == "mythicplus" and e.keyMin)
      and ("Mythic+ " .. e.keyMin .. (e.keyMax and ("-" .. e.keyMax) or "")) or nil
    b:SetScript("OnClick", function() UI:SelectEncounter(e.id) end)
    b:Show()
  end
  for i = #list + 1, #encButtons do encButtons[i]:Hide() end
end

-- ---------------------------------------------------------------------------
-- spec rows
-- ---------------------------------------------------------------------------
local function acquireSpecRow(i)
  if specRows[i] then return specRows[i] end
  local r = CreateFrame("Frame", nil, frame.specList)
  r:SetSize(CONTENT_W, 26)
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", 0, 0) -- full-bleed custom art, no edge crop
  r.name = newText(r, GBB.FONT.label, 14, 1, 1, 1) -- Semibold (Medium read too weak)
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 7, 0)
  -- underline (current spec only) — fontstrings can't underline, so it's a texture
  r.underline = r:CreateTexture(nil, "ARTWORK")
  r.underline:SetHeight(1)
  r.underline:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -1)
  r.underline:Hide()
  r.best = makeOutlineButton(r, 90, 26, GBB.COLOR.heroic, "HIGHEST DPS", 10)
  r.pop = makeOutlineButton(r, 87, 26, GBB.COLOR.heroic, "POPULARITY", 10)
  r.pop:SetPoint("RIGHT", 0, 0)
  r.best:SetPoint("RIGHT", r.pop, "LEFT", -10, 0)
  specRows[i] = r
  return r
end

-- ---------------------------------------------------------------------------
-- build detail
-- ---------------------------------------------------------------------------
local function layoutDetailLine(d, i, anchorTo, labelText, valueText)
  local row = d.lines[i]
  row.label:ClearAllPoints(); row.value:ClearAllPoints()
  row.label:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -6)
  row.label:SetText(labelText)
  row.value:SetPoint("LEFT", row.label, "RIGHT", 4, 0)
  row.value:SetText(valueText)
  row.label:Show(); row.value:Show()
  return row.label
end

local function renderDetail(rows)
  local d = frame.detail
  GBB:ClearNodeHighlights() -- drop any glows from a previous build/hover
  local sel
  for _, row in ipairs(rows) do if row.spec.name == state.selSpec then sel = row break end end
  if not sel then d:Hide() return end
  local entry = (state.selBuild == "pop" and sel.pop) or sel.perf or sel.pop
  if not entry then d:Hide() return end
  d:Show()

  local cc = classColor()
  local sameBuild = sel.perf and sel.pop and sel.perf.import == sel.pop.import
  local kind = sameBuild and "Recommended" or (entry == sel.pop and "Most Popular" or "Highest DPS")
  -- Title, e.g. "Highest Affliction DPS Build" with the spec name class-coloured.
  local unit = specUnit(sel.spec)
  local kindWord = (entry == sel.pop and not sameBuild) and "Most Popular" or
    (unit == "hps" and "Highest HPS" or "Highest DPS")
  if sameBuild then kindWord = "Recommended" end
  d.title:SetText(("%s |cff%s%s|r %s Build"):format(
    (entry == sel.pop and not sameBuild) and "Most Popular" or "Highest",
    hex(cc), sel.spec.name, unit:upper()))

  local diffWord = (state.section == "raid") and ((GBB.DIFFICULTY[state.diff] or ""):lower() .. " ") or "mythic+ "
  local hero = entry.hero or GBB:HeroTreeName(entry.import)
  local sim = GBB:BuildSimilarity(entry.import)

  -- detail lines (label + bold value)
  local anchor = d.title
  anchor = layoutDetailLine(d, 1, anchor,
    ("Mean %s from %d top %sparses:"):format(unit:upper(), entry.samples or 0, diffWord),
    comma(entry.median) .. " " .. unit:upper())
  anchor = layoutDetailLine(d, 2, anchor, "Hero Tree:", hero or "—")
  anchor = layoutDetailLine(d, 3, anchor, "Build agreement:",
    math.floor((entry.agreement or 0) * 100 + 0.5) .. "%")
  if sim ~= nil then
    anchor = layoutDetailLine(d, 4, anchor, "Similarity to your current build:", sim .. "%")
  else
    d.lines[4].label:Hide(); d.lines[4].value:Hide()
  end

  -- apply
  d.apply:ClearAllPoints()
  d.apply:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
  d.apply.text:SetText("Apply This Build Now")
  d.apply._import = entry.import
  d.apply._specIndex = sel.spec.index
  d.apply._specName = sel.spec.name
  d.apply._label = kindWord

  -- changes (current spec only)
  local diff = (sim ~= nil) and GBB:BuildDiff(entry.import) or nil
  local hasChanges = diff and not diff.otherSpec and
    (#diff.added > 0 or #diff.removed > 0 or #diff.changed > 0 or diff.heroChange ~= nil)
  local below = d.apply
  if not diff or diff.otherSpec or not hasChanges then
    d.changesLabel:Hide(); d.added:Hide(); d.changed:Hide(); d.removed:Hide()
    -- Same spec, no differences → this build is already applied; say so.
    if diff and not diff.otherSpec then
      d.appliedNote:ClearAllPoints()
      d.appliedNote:SetPoint("TOPLEFT", d.apply, "BOTTOMLEFT", 0, -16)
      d.appliedNote:Show()
    else
      d.appliedNote:Hide()
    end
  else
    d.appliedNote:Hide()
    d.changesLabel:ClearAllPoints()
    d.changesLabel:SetPoint("TOPLEFT", d.apply, "BOTTOMLEFT", 0, -16)
    d.changesLabel:Show()
    below = d.changesLabel

    local function fill(blk, prefix, names, nodes, isHero, heroChange)
      blk._nodes = nodes -- for the hover glow
      local parts = {}
      if isHero and heroChange then
        parts[#parts + 1] = "Hero tree: " .. heroChange.from .. " -> " .. heroChange.to
      end
      for _, n in ipairs(names or {}) do parts[#parts + 1] = n end
      if #parts == 0 then blk._nodes = nil; blk:Hide(); return below end
      blk.text:SetText("|cff" .. hex(blk._tag) .. prefix .. "|r " .. table.concat(parts, ", "))
      blk.text:SetWidth(CONTENT_W - 20)
      blk:ClearAllPoints()
      blk:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -8)
      blk:SetHeight(blk.text:GetStringHeight() + 16)
      blk:Show()
      return blk
    end
    -- "added" carries a hero-tree swap line if present. Order mirrors the mock.
    below = fill(d.added, "ADDED:", diff.added, diff.addedNodes, true, diff.heroChange)
    below = fill(d.removed, "REMOVED:", diff.removed, diff.removedNodes)
    below = fill(d.changed, "CHANGED:", diff.changed, diff.changedNodes)
  end
end

-- ---------------------------------------------------------------------------
-- render orchestration
-- ---------------------------------------------------------------------------
local function renderHeader()
  local _, specName = GBB:CurrentSpec()
  local meta = (GBB:Data() and GBB:Data().meta) or {}
  local gen = meta.generatedAt and tostring(meta.generatedAt):sub(1, 10) or "?"
  frame.footer:SetText(("Data refreshed %s  •  Visit hodguild.com for info"):format(gen))
end

function UI:Render()
  if not frame then return end
  renderHeader()

  local isRaid = state.section == "raid"
  frame.contentSwitch:Set(isRaid)       -- false=M+, true=Raids
  frame.diffSwitch:Set(state.diff == 5) -- false=Heroic, true=Mythic
  frame.diffSwitch:SetShown(isRaid)

  local hasEnc = state.encId ~= nil

  -- Landing vs picked: strip+logo+footer  OR  encounter detail.
  frame.stripHeader:SetShown(not hasEnc)
  frame.strip:SetShown(not hasEnc)
  frame.logo:SetShown(not hasEnc)
  frame.footer:SetShown(not hasEnc)
  frame.backBoss:SetShown(hasEnc)
  frame.encTitle:SetShown(hasEnc)
  frame.backIcon:SetShown(hasEnc)
  frame.topLine:SetShown(hasEnc)
  frame.heatTitle:SetShown(hasEnc)
  frame.heatSub:SetShown(hasEnc)
  frame.heatSwitch:SetShown(hasEnc)
  frame.specList:SetShown(hasEnc)

  if not hasEnc then
    local what = isRaid and ("CHOOSE RAID BOSS  |cff" .. hex(diffColor()) ..
      "(" .. (GBB.DIFFICULTY[state.diff] or "") .. " Difficulty)|r") or "CHOOSE A DUNGEON"
    frame.stripHeader:SetText(what)
    renderStrip()
    frame.detail:Hide()
    GBB:ClearHeatmap()
    for _, r in ipairs(specRows) do r:Hide() end
    return
  end

  -- encounter picked → title + top line + spec list (+ detail if a build chosen)
  local list = GBB:EncounterList(state.section)
  local enc
  for _, e in ipairs(list) do if e.id == state.encId then enc = e break end end
  if not enc then UI:SelectEncounter(nil); return end

  frame.backBoss.text:SetText(isRaid and "Select a Different Boss" or "Select a Different Dungeon")
  local cc = classColor()
  if isRaid then
    local dc = diffColor()
    frame.encTitle:SetText(("|cff%s%s|r %s"):format(hex(dc), GBB.DIFFICULTY[state.diff] or "", enc.name))
  else
    frame.encTitle:SetText(enc.name)
  end

  -- talent heatmap (current spec, when toggled on — paints the open live tree).
  -- Subtitle states the live spec/class + the selected encounter.
  local hsSpec = select(2, GBB:CurrentSpec()) or "?"
  local hsWhere = isRaid and ((GBB.DIFFICULTY[state.diff] or "") .. " " .. enc.name) or enc.name
  frame.heatSub:SetText(("%s %s  /  %s"):format(hsSpec, className(), hsWhere))
  frame.heatSwitch:Set(state.heatmap)
  -- Heatmap ON → the spec/build area is irrelevant; dim it to 30% + block clicks.
  frame.specList:SetAlpha(state.heatmap and 0.3 or 1)
  frame.detail:SetAlpha(state.heatmap and 0.3 or 1)
  frame.heatBlocker:SetShown(state.heatmap)
  if state.heatmap then
    GBB:ShowHeatmap(GBB:HeatFor(state.section, state.encId, state.diff))
  else
    GBB:ClearHeatmap()
  end

  local rows, topDps = GBB:SpecRowsForEncounter(state.section, state.encId, state.diff)
  if #rows == 0 then
    frame.topLine:SetText("No builds for this " .. (isRaid and "boss" or "dungeon") .. " yet.")
    frame.detail:Hide()
    for _, r in ipairs(specRows) do r:Hide() end
    return
  end

  if topDps then
    local e = topDps.perf or topDps.pop
    local u = metricUnit(topDps.spec.metric)
    frame.topLine:SetText(("Top %s for %s: |cff%s%s|r  |cffff7729•|r  %s %s"):format(
      u:upper(), className(), hex(cc), topDps.spec.name, shortNum(e.median), u:upper()))
  else
    frame.topLine:SetText("")
  end

  -- valid selection?
  local hasSel = false
  for _, row in ipairs(rows) do if row.spec.name == state.selSpec then hasSel = true break end end
  if state.selSpec and not hasSel then state.selSpec = nil end

  local _, _, _, curIdx = GBB:CurrentSpec()

  -- Display order: YOUR current spec first, then the rest alphabetically.
  -- (The data layer returns them by DPS; that order only feeds the top banner.)
  table.sort(rows, function(a, b)
    local ac, bc = a.spec.index == curIdx, b.spec.index == curIdx
    if ac ~= bc then return ac end
    return a.spec.name < b.spec.name
  end)

  -- All specs stay visible; picking a build just reveals the detail below the
  -- full list and highlights that build's button to 100%.
  for i, row in ipairs(rows) do
    local r = acquireSpecRow(i)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 46)
    local spec = row.spec
    local path = specIconPath(GBB:PlayerClass(), spec.name)
    if path then r.icon:SetTexture(path) elseif spec.icon then r.icon:SetTexture(spec.icon) end

    local isCurrent = curIdx and spec.index == curIdx
    r.name:SetText(spec.name)
    if isCurrent then
      local g = GBB.COLOR.green; r.name:SetTextColor(g.r, g.g, g.b)
      r.underline:SetColorTexture(g.r, g.g, g.b, 1)
      r.underline:SetWidth(math.max(1, r.name:GetStringWidth()))
      r.underline:Show()
    else
      r.name:SetTextColor(1, 1, 1)
      r.underline:Hide()
    end

    local sameBuild = row.perf and row.pop and row.perf.import == row.pop.import
    local selHere = state.selSpec == spec.name
    if sameBuild or not (row.perf and row.pop) then
      local key = row.perf and "perf" or "pop"
      r.best:SetText("VIEW"); r.best:Show()
      r.best:SetScript("OnClick", function() UI:Select(spec.name, key) end)
      r.best:SetActive(selHere)
      r.pop:Hide()
    else
      r.best:SetText(specUnit(spec) == "hps" and "HIGHEST HPS" or "HIGHEST DPS"); r.best:Show()
      r.best:SetScript("OnClick", function() UI:Select(spec.name, "perf") end)
      r.best:SetActive(selHere and state.selBuild == "perf")
      r.pop:SetText("POPULARITY"); r.pop:Show()
      r.pop:SetScript("OnClick", function() UI:Select(spec.name, "pop") end)
      r.pop:SetActive(selHere and state.selBuild == "pop")
    end
    r:Show()
  end
  for i = #rows + 1, #specRows do specRows[i]:Hide() end

  if state.selSpec then
    frame.detail:ClearAllPoints()
    frame.detail:SetPoint("TOPLEFT", frame.specList, "TOPLEFT", 0, -(#rows * 46) - 14)
    renderDetail(rows)
  else
    frame.detail:Hide()
  end
end

-- ---------------------------------------------------------------------------
-- docking — attach to the in-game Talents window, or float standalone
-- ---------------------------------------------------------------------------
local function ensureFrame()
  if not frame then buildFrame(); UI:ApplyDockLayout() end
  return frame
end

function UI:ApplyDockLayout()
  if not frame then return end
  if state.docked then
    frame:SetParent(PlayerSpellsFrame or UIParent)
    frame:ClearAllPoints()
    if PlayerSpellsFrame then
      frame:SetPoint("TOPLEFT", PlayerSpellsFrame, "TOPRIGHT", 0, 0)
      frame:SetHeight(PlayerSpellsFrame:GetHeight()) -- align top + bottom with the Talents window
    else
      frame:SetPoint("CENTER")
      frame:SetHeight(PANEL_H)
    end
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(false)
    frame.closeBtn:Hide()
    frame.dockBtn.text:SetText("Undock")
  else
    frame:SetParent(UIParent)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    frame:SetHeight(PANEL_H)
    frame:SetMovable(true)
    frame.closeBtn:Show()
    frame.dockBtn.text:SetText("Dock")
  end
end

function UI:UpdateDockVisibility()
  if not state.docked then return end
  local psf = PlayerSpellsFrame
  local tf = psf and psf.TalentsFrame
  local show = psf and psf:IsShown() and tf and tf:IsShown()
  if show and tf.ApplyButton and not tf.ApplyButton:IsShown() then show = false end
  if show then
    ensureFrame(); self:ApplyDockLayout(); frame:Show(); self:Render()
  elseif frame then
    frame:Hide()
  end
end

local dockHooksInstalled = false
local dockWaiter
local function installDockHooks()
  if dockHooksInstalled then return true end
  local psf = PlayerSpellsFrame
  if not psf then return false end
  psf:HookScript("OnShow", function() UI:UpdateDockVisibility() end)
  psf:HookScript("OnHide", function() if frame and state.docked then frame:Hide() end end)
  if psf.TalentsFrame then
    hooksecurefunc(psf.TalentsFrame, "SetShown", function() UI:UpdateDockVisibility() end)
  end
  if EventRegistry then
    EventRegistry:RegisterCallback("PlayerSpellsFrame.TabSet", function() UI:UpdateDockVisibility() end)
  end
  -- We deliberately do NOT reposition the Talents window; the dock anchor is
  -- relative, so it follows wherever a frame-mover (MoveAny/BlizzMove) puts it.
  dockHooksInstalled = true
  return true
end

function UI:EnsureDockHooks()
  if dockHooksInstalled then return end
  if installDockHooks() then return end
  if not dockWaiter then
    dockWaiter = CreateFrame("Frame")
    dockWaiter:RegisterEvent("ADDON_LOADED")
    dockWaiter:SetScript("OnEvent", function(_, _, name)
      if name == "Blizzard_PlayerSpells" then
        installDockHooks(); dockWaiter:UnregisterAllEvents(); UI:UpdateDockVisibility()
      end
    end)
  end
end

function UI:SetDocked(docked)
  docked = not not docked
  state.docked = docked
  if GBB.db then GBB.db.docked = docked end
  self:EnsureDockHooks()
  ensureFrame()
  self:ApplyDockLayout()
  if docked then
    if frame then frame:Hide() end
    self:UpdateDockVisibility()
    if not (PlayerSpellsFrame and PlayerSpellsFrame:IsShown()) then
      GBB.msg("docked to your Talents window — open Talents (or /gbb) to see it.")
    end
  else
    if frame then frame:Show(); self:Render() end
  end
end

function UI:OnLogin()
  state.docked = (GBB.db and GBB.db.docked) and true or false
  if state.docked then self:EnsureDockHooks(); self:UpdateDockVisibility() end
end

-- ---------------------------------------------------------------------------
-- public
-- ---------------------------------------------------------------------------
function UI:SelectEncounter(encId)
  state.encId = encId
  state.selSpec = nil
  state.selBuild = nil
  self:Render()
end

function UI:Select(specName, buildKey)
  state.selSpec = specName
  state.selBuild = buildKey
  self:Render()
end

function UI:ApplySelected()
  local b = frame and frame.detail and frame.detail.apply
  if not b or not b._import then return end
  GBB:ApplyForSpec(b._specIndex, b._specName, b._import, b._label)
end

function UI:SetSection(section)
  if state.section == section then return end
  state.section = section
  state.encId = nil; state.selSpec = nil; state.selBuild = nil
  self:Render()
end

function UI:SetDiff(diff)
  if state.diff == diff then return end
  state.diff = diff
  state.selSpec = nil; state.selBuild = nil
  self:Render()
end

function UI:SetHeatmap(on)
  state.heatmap = on and true or false
  self:Render()
end

function UI:OnSpecChanged()
  if frame and frame:IsShown() then self:Render() end
end

-- After a build commits, re-render so "Changes If Applied" recomputes (now empty).
function UI:OnBuildApplied()
  if frame and frame:IsShown() then self:Render() end
end

function UI:Show()
  if state.docked then
    self:EnsureDockHooks()
    if PlayerSpellsUtil and PlayerSpellsUtil.OpenToClassTalentsTab then PlayerSpellsUtil.OpenToClassTalentsTab()
    elseif ToggleTalentFrame then ToggleTalentFrame() end
    return
  end
  ensureFrame(); frame:Show(); self:Render()
end

function UI:Hide() GBB:ClearHeatmap(); if frame then frame:Hide() end end

function UI:Toggle()
  if state.docked then
    self:EnsureDockHooks()
    if PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentFrame then PlayerSpellsUtil.ToggleClassTalentFrame()
    elseif ToggleTalentFrame then ToggleTalentFrame() end
    return
  end
  if frame and frame:IsShown() then self:Hide() else self:Show() end
end
