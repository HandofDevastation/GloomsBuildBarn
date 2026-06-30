-- Core.lua — Gloom's Build Barn
--
-- Loads the baked build data (BuildData.lua) and exposes spec lookups, the
-- cross-spec ranking the UI shows, and the talent-apply path.
--   • Data access + current/class spec detection
--   • ApplyBuild — managed "Gloom's Build Barn" loadout, with switch-and-apply
--     when the target spec isn't the active one
--   • /gbb — opens the window; /gbb status — the text smoke test
-- UI lives in UI.lua (GBB.UI), loaded after this file.

local ADDON_NAME = ...

local GBB = {}
_G.GloomsBuildBarn = GBB

local PREFIX = "|cffff7729Gloom's Build Barn|r"
GBB.PREFIX = PREFIX
GBB.LOADOUT_NAME = "Gloom's Build Barn"

-- Raid difficulty keys as they appear in BuildData (WCL difficulty IDs).
GBB.DIFFICULTY = { [4] = "Heroic", [5] = "Mythic" }
GBB.DIFFICULTY_ORDER = { 4, 5 }

-- ---------------------------------------------------------------------------
-- DS 2.0 design tokens (mirrors hodguild.com globals.css). Each color carries
-- {r,g,b} 0-1 floats (for textures/SetTextColor) and a hex string (for inline
-- |cffRRGGBB color codes in fontstrings).
-- ---------------------------------------------------------------------------
local function color(hex)
  local r = tonumber(hex:sub(1, 2), 16) / 255
  local g = tonumber(hex:sub(3, 4), 16) / 255
  local b = tonumber(hex:sub(5, 6), 16) / 255
  return { r = r, g = g, b = b, hex = hex }
end
GBB.COLOR = {
  green       = color("20ba56"), -- Veteran Green — selected content-type label
  heroic      = color("8031ff"), -- Heroic purple — difficulty label + icon border
  mythic      = color("ff7729"), -- Mythic orange — difficulty label + icon border
  purple      = color("936bff"), -- Bright purple — buttons + Apply
}
-- Difficulty key (4/5) → its accent color.
GBB.DIFF_COLOR = { [4] = GBB.COLOR.heroic, [5] = GBB.COLOR.mythic }

-- Bundled fonts (TTF — WoW's renderer is unreliable with OTF). Paths resolve
-- once the files land in Media/fonts/; a helper falls back to the default game
-- font if a file is missing so the UI never hard-breaks.
local FONT_DIR = "Interface\\AddOns\\GloomsBuildBarn\\Media\\fonts\\"
GBB.FONT = {
  title       = FONT_DIR .. "Khand-SemiBold.ttf",   -- boss/build titles
  titleMed    = FONT_DIR .. "Khand-Medium.ttf",
  body        = FONT_DIR .. "GeneralSans-Regular.ttf",
  bodyMed     = FONT_DIR .. "GeneralSans-Medium.ttf",
  label       = FONT_DIR .. "GeneralSans-Semibold.ttf", -- uppercase labels/buttons
}
GBB.MEDIA = "Interface\\AddOns\\GloomsBuildBarn\\Media\\"

local function addonVersion()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "dev"
  end
  return "dev"
end
GBB.version = addonVersion()

local function msg(text)
  print(PREFIX..": "..text)
end
GBB.msg = msg

-- ---------------------------------------------------------------------------
-- Data access
-- ---------------------------------------------------------------------------
-- BuildData.lua sets the global GloomsBuildBarnData (loaded before this file).

function GBB:Data()
  return _G.GloomsBuildBarnData
end

-- classToken, classID for the player.
function GBB:PlayerClass()
  local _, classToken, classID = UnitClass("player")
  return classToken, classID
end

-- classToken, specName, specId, specIndex for the player's CURRENT spec.
function GBB:CurrentSpec()
  local classToken = self:PlayerClass()
  local idx = GetSpecialization()
  if not idx then return classToken, nil, nil, nil end
  local specId, specName = GetSpecializationInfo(idx)
  return classToken, specName, specId, idx
end

-- The build table for the player's current spec (or nil), plus classToken/specName.
function GBB:CurrentSpecBuilds()
  local data = self:Data()
  local classToken, specName = self:CurrentSpec()
  if not data or not data.specs or not classToken or not specName then
    return nil, classToken, specName
  end
  local byClass = data.specs[classToken]
  return (byClass and byClass[specName]) or nil, classToken, specName
end

-- Every spec of the player's CLASS, in canonical (game) order, each enriched
-- with the baked build table when one exists. Class-locked: only this class.
-- Returns { {index, specId, name, icon, role, metric, builds}, ... }, classToken
function GBB:ClassSpecList()
  local classToken, classID = self:PlayerClass()
  local out = {}
  local data = self:Data()
  local byClass = (data and data.specs and data.specs[classToken]) or {}
  if not classID or not GetNumSpecializationsForClassID then return out, classToken end

  local n = GetNumSpecializationsForClassID(classID)
  for i = 1, n do
    local specId, name, _, icon, role = GetSpecializationInfoForClassID(classID, i)
    local builds = byClass[name]
    out[#out + 1] = {
      index = i,
      specId = specId,
      name = name,
      icon = icon,
      role = role,                       -- "TANK" / "HEALER" / "DAMAGER"
      metric = builds and builds.metric, -- "dps" / "hps"
      builds = builds,                   -- { raid = {...}, mythicplus = {...} } or nil
    }
  end
  return out, classToken
end

-- Union of encounters across all of the class's specs for a section
-- ("raid" | "mythicplus"). Each: {id, name, keyMin, keyMax, order}.
-- Raid sorts by baked order when present (emitter may bake displayOrder),
-- else encounterId; M+ sorts alphabetically.
function GBB:EncounterList(section)
  local specs = self:ClassSpecList()
  local seen, order = {}, {}
  for _, s in ipairs(specs) do
    local sec = s.builds and s.builds[section]
    if sec then
      for encId, e in pairs(sec) do
        if not seen[encId] then
          local rec = {
            id = encId,
            name = e.name or ("Encounter "..tostring(encId)),
            keyMin = e.keyMin,
            keyMax = e.keyMax,
            order = e.order or e.displayOrder,
          }
          seen[encId] = rec
          order[#order + 1] = rec
        end
      end
    end
  end

  if section == "mythicplus" then
    table.sort(order, function(a, b) return a.name < b.name end)
  else
    table.sort(order, function(a, b)
      if a.order and b.order and a.order ~= b.order then return a.order < b.order end
      if a.order and not b.order then return true end
      if b.order and not a.order then return false end
      return a.id < b.id
    end)
  end
  return order
end

-- For one encounter, the per-spec rows the UI shows, sorted by performance
-- median (desc), highest first. Each row carries the spec meta plus the
-- encounter's perf/pop entries for the requested difficulty.
-- section "raid" uses diffKey (4|5); "mythicplus" ignores it.
-- Returns rows, topDpsRow (highest-median dps-metric row or nil).
function GBB:SpecRowsForEncounter(section, encId, diffKey)
  local specs = self:ClassSpecList()
  local rows = {}
  for _, s in ipairs(specs) do
    local sec = s.builds and s.builds[section]
    local enc = sec and sec[encId]
    if enc then
      local node = (section == "raid") and enc[diffKey] or enc
      if node and (node.perf or node.pop) then
        rows[#rows + 1] = {
          spec = s,
          perf = node.perf,
          pop = node.pop,
          sortMedian = (node.perf and node.perf.median) or (node.pop and node.pop.median) or 0,
        }
      end
    end
  end
  table.sort(rows, function(a, b) return a.sortMedian > b.sortMedian end)

  local topDps
  for _, r in ipairs(rows) do
    if r.spec.metric == "dps" then topDps = r; break end
  end
  return rows, topDps
end

-- ---------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------
-- Builds a single managed loadout named GBB.LOADOUT_NAME for the target spec
-- and activates it. When the target spec isn't the active one, we switch first
-- (SetSpecialization) and finish on PLAYER_SPECIALIZATION_CHANGED.
--
-- NOTE: the import call itself (C_ClassTalents.ImportLoadout + the surrounding
-- delete-by-name housekeeping) is the one path that can only be verified live
-- in-game. It mirrors the proven community pattern; if the client reports a
-- different failure we adjust here. Everything prints a clear diagnostic.

local pendingApply -- { importString, specIndex, buildLabel }

GBB.debug = false -- off for release; toggle with /gbb debug to bring back the [gbb] diagnostics

local function dbg(...)
  if GBB.debug then print("|cff7f7f7f[gbb]|r "..table.concat({ ... }, " ")) end
end
GBB.dbg = dbg

-- This client's C_ClassTalents.ImportLoadout wants PARSED entries as arg #2,
-- not the export string. So we decode the string ourselves (mirroring Blizzard's
-- ReadLoadoutHeader/ReadLoadoutContent bit layout) into the entry list the API
-- expects: { {nodeID, ranksPurchased, selectionEntryID}, ... }.
local BIT_VERSION, BIT_SPEC, BIT_RANKS = 8, 16, 6

-- Returns entries, errKind, headerSpecID. errKind is nil on success, else a
-- short tag ("spec-mismatch" / "too-short" / "no-tree" / "no-exportutil").
local function parseImportString(importString, configID)
  if not (ExportUtil and ExportUtil.MakeImportDataStream and C_Traits) then
    return nil, "no-exportutil"
  end
  local ok, stream = pcall(ExportUtil.MakeImportDataStream, importString)
  if not ok or not stream then return nil, "stream-init" end

  if stream:GetNumberOfBits() < BIT_VERSION + BIT_SPEC + 128 then
    return nil, "too-short"
  end

  local version = stream:ExtractValue(BIT_VERSION)
  local headerSpecID = stream:ExtractValue(BIT_SPEC)
  local strHash = {}
  for i = 1, 16 do strHash[i] = stream:ExtractValue(8) end -- 128-bit tree hash

  local curSpecID = select(3, GBB:CurrentSpec())
  if curSpecID and headerSpecID ~= curSpecID then
    return nil, "spec-mismatch", headerSpecID
  end

  local cfg = C_Traits.GetConfigInfo(configID)
  local treeID = cfg and cfg.treeIDs and cfg.treeIDs[1]
  if not treeID then return nil, "no-tree", headerSpecID end

  -- Compare the string's tree hash to the live tree. A mismatch means the build
  -- was exported against a DIFFERENT talent-tree version, so the bit stream
  -- won't line up (this is what overran). An all-zero hash skips the check.
  local hashEmpty = true
  for i = 1, 16 do if strHash[i] ~= 0 then hashEmpty = false break end end
  local curHash = C_Traits.GetTreeHash and C_Traits.GetTreeHash(treeID)
  local hashMatch = "skip"
  if not hashEmpty and type(curHash) == "table" then
    hashMatch = "yes"
    for i = 1, 16 do if strHash[i] ~= curHash[i] then hashMatch = "no" break end end
  end
  GBB.dbg(("parse: treeID=%s treeHash=%s"):format(tostring(treeID), hashMatch))
  if hashMatch == "no" then return nil, "tree-version", headerSpecID end

  local treeNodes = C_Traits.GetTreeNodes(treeID)
  if type(treeNodes) ~= "table" then return nil, "no-treenodes", headerSpecID end
  GBB.dbg(("parse: treeNodes=%d"):format(#treeNodes))

  -- Per-node bit layout (DF 10.1+ / Midnight): selected → purchased →
  -- partiallyRanked → [ranks] → choiceNode → [choice]. Only PURCHASED nodes
  -- become import entries; selected-but-granted nodes are auto-granted in-game.
  local entries = {}
  for _, nodeID in ipairs(treeNodes) do
    local selected = stream:ExtractValue(1) == 1
    if selected then
      local purchased = stream:ExtractValue(1) == 1
      if purchased then
        local partial = stream:ExtractValue(1) == 1
        local partialRanks = partial and stream:ExtractValue(BIT_RANKS) or 0
        local isChoice = stream:ExtractValue(1) == 1
        local choiceSel = isChoice and stream:ExtractValue(2) or 0

        local node = C_Traits.GetNodeInfo(configID, nodeID)
        local entryID = node and node.entryIDs and node.entryIDs[isChoice and (choiceSel + 1) or 1]
        local maxRanks = (node and node.maxRanks) or 1
        entries[#entries + 1] = {
          nodeID = nodeID,
          entryID = entryID,
          selectionEntryID = entryID, -- alias for older field name; harmless if ignored
          ranksPurchased = partial and partialRanks or maxRanks,
          ranksGranted = 0,
        }
      end
    end
  end
  local totalRanks = 0
  for _, e in ipairs(entries) do totalRanks = totalRanks + (e.ranksPurchased or 0) end
  GBB.dbg(("parsed entries=%d totalRanks=%d (ver=%s headerSpec=%s)"):format(
    #entries, totalRanks, tostring(version), tostring(headerSpecID)))
  return entries, nil, headerSpecID
end

-- Switch active spec — the old global SetSpecialization is gone in this client.
local function switchSpec(index)
  if C_SpecializationInfo and C_SpecializationInfo.SetSpecialization then
    C_SpecializationInfo.SetSpecialization(index)
    return true
  elseif type(SetSpecialization) == "function" then
    SetSpecialization(index)
    return true
  end
  return false
end

local function importTalentUILoaded()
  -- ImportLoadout needs the talent UI's code available. Load it (hidden) once.
  if not (C_AddOns and C_AddOns.LoadAddOn) then return end
  for _, name in ipairs({ "Blizzard_PlayerSpells", "Blizzard_ClassTalentUI" }) do
    if C_AddOns.IsAddOnLoadable and C_AddOns.IsAddOnLoadable(name) then
      pcall(C_AddOns.LoadAddOn, name)
    end
  end
end

-- Build import entries using BLIZZARD'S OWN loadout parser/converter, which is
-- always format-correct (handles granted ranks, choice nodes, apex/capstones
-- exactly). Returns entries, or nil + reason if the talent UI isn't reachable
-- (then we fall back to our hand parser).
local function blizzardEntries(importString, configID)
  if not (ExportUtil and ExportUtil.MakeImportDataStream and C_Traits) then return nil, "no-exportutil" end
  importTalentUILoaded()
  local tab = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
  if not (tab and tab.ReadLoadoutHeader and tab.ReadLoadoutContent and tab.ConvertToImportLoadoutEntryInfo) then
    return nil, "no-blizzard-tab"
  end
  -- treeID for the current spec (the way TalentLoadoutsEx does it).
  local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
  local treeID = specID and C_ClassTalents.GetTraitTreeForSpec and C_ClassTalents.GetTraitTreeForSpec(specID)
  if not treeID then
    local cfg = C_Traits.GetConfigInfo(configID)
    treeID = cfg and cfg.treeIDs and cfg.treeIDs[1]
  end
  if not treeID then return nil, "no-tree" end

  local ok, stream = pcall(ExportUtil.MakeImportDataStream, importString)
  if not ok or not stream then return nil, "stream" end
  -- Consume the header to advance the stream, then read the node content.
  pcall(tab.ReadLoadoutHeader, tab, stream)
  local okC, content = pcall(tab.ReadLoadoutContent, tab, stream, treeID)
  if not okC or type(content) ~= "table" then return nil, "content" end
  -- Signature (per TalentLoadoutsEx): ConvertToImportLoadoutEntryInfo(self, configID, treeID, content)
  local okE, entries = pcall(tab.ConvertToImportLoadoutEntryInfo, tab, configID, treeID, content)
  if not okE then GBB.dbg("convert err: "..tostring(entries)) end
  if not okE or type(entries) ~= "table" then return nil, "convert" end
  return entries
end

-- The spec id baked into an export string's header (8-bit version, 16-bit spec).
local function headerSpecID(importString)
  if not (ExportUtil and ExportUtil.MakeImportDataStream) then return nil end
  local ok, stream = pcall(ExportUtil.MakeImportDataStream, importString)
  if not ok or not stream then return nil end
  pcall(stream.ExtractValue, stream, 8)
  local oks, spec = pcall(stream.ExtractValue, stream, 16)
  return oks and spec or nil
end

-- The hero talent tree NAME a build uses (e.g. "Sentinel", "Dark Ranger"), or
-- nil. Only resolvable for the CURRENT spec (decoding needs the live tree/config),
-- so off-spec builds return nil. Cached per import string.
local heroNameCache = {}
function GBB:HeroTreeName(importString)
  if type(importString) ~= "string" or importString == "" then return nil end
  local cached = heroNameCache[importString]
  if cached ~= nil then return cached or nil end -- false = computed, none

  local _, _, curSpecID = self:CurrentSpec()
  if not curSpecID or headerSpecID(importString) ~= curSpecID then return nil end

  local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local entries = blizzardEntries(importString, configID)
  if not entries then return nil end

  local ok, subTreeIDs = pcall(C_ClassTalents.GetHeroTalentSpecsForClassSpec)
  if not ok or type(subTreeIDs) ~= "table" then return nil end
  local selNodes = {}
  for _, stID in ipairs(subTreeIDs) do
    local info = C_Traits.GetSubTreeInfo(configID, stID)
    for _, nID in ipairs((info and info.subTreeSelectionNodeIDs) or {}) do
      selNodes[nID] = true
    end
  end

  local name = false
  for _, e in ipairs(entries) do
    if selNodes[e.nodeID] and e.selectionEntryID then
      local ei = C_Traits.GetEntryInfo(configID, e.selectionEntryID)
      local stID = ei and ei.subTreeID
      local info = stID and C_Traits.GetSubTreeInfo(configID, stID)
      if info and info.name then name = info.name; break end
    end
  end
  heroNameCache[importString] = name
  return name or nil
end

-- Resolve a trait entry's display name (talent name) via its spell.
local function entryName(configID, entryID)
  if not (entryID and C_Traits and C_Traits.GetEntryInfo) then return nil end
  local ei = C_Traits.GetEntryInfo(configID, entryID)
  local def = ei and ei.definitionID and C_Traits.GetDefinitionInfo and C_Traits.GetDefinitionInfo(ei.definitionID)
  if not def then return nil end
  if def.overrideName and def.overrideName ~= "" then return def.overrideName end
  if def.spellID and C_Spell and C_Spell.GetSpellInfo then
    local si = C_Spell.GetSpellInfo(def.spellID)
    if si and si.name then return si.name end
  end
  return nil
end

-- Name for a node: prefer a given entry, else its active/first entry.
local function nodeName(configID, node, preferEntryID)
  local eid = preferEntryID
  if not eid and node then
    eid = (node.activeEntry and node.activeEntry.entryID) or (node.entryIDs and node.entryIDs[1])
  end
  return entryName(configID, eid)
end

-- The hero TREE name a subtree-selection entry points at (e.g. "Sentinel").
local function subtreeNameFromEntry(configID, entryID)
  if not (entryID and C_Traits and C_Traits.GetEntryInfo) then return nil end
  local ei = C_Traits.GetEntryInfo(configID, entryID)
  local stID = ei and ei.subTreeID
  local info = stID and C_Traits.GetSubTreeInfo and C_Traits.GetSubTreeInfo(configID, stID)
  return info and info.name
end

-- Diff the CURRENT (committed) talents against a target build string. Returns
-- { added, removed, changed, heroChange }, or { otherSpec=true } if the build is
-- for a different spec, or nil if it can't be computed. Compares PURCHASED
-- selections only (auto-granted nodes don't create phantom changes), and when the
-- HERO TREE itself changes, collapses all that node churn into a single heroChange
-- instead of listing every hero node.
function GBB:BuildDiff(importString)
  local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end

  local _, _, curSpecID = self:CurrentSpec()
  if curSpecID and headerSpecID(importString) ~= curSpecID then return { otherSpec = true } end

  local entries = blizzardEntries(importString, configID)
  if not entries then return nil end

  local treeID = curSpecID and C_ClassTalents.GetTraitTreeForSpec and C_ClassTalents.GetTraitTreeForSpec(curSpecID)
  if not treeID then return nil end

  -- Accumulate ranks per node — tiered nodes (e.g. the apex) come back as
  -- MULTIPLE entries that must SUM, not overwrite (else a 4/4 apex reads as 1).
  local target = {}
  for _, e in ipairs(entries) do
    local t = target[e.nodeID]
    if not t then t = { entryID = nil, ranks = 0 }; target[e.nodeID] = t end
    t.ranks = t.ranks + (e.ranksPurchased or 0)
    if e.selectionEntryID and e.selectionEntryID ~= 0 then t.entryID = e.selectionEntryID end
  end

  -- Hero sub-tree: which one is active now vs. which the build wants.
  local subSel = {}
  if C_ClassTalents.GetHeroTalentSpecsForClassSpec and C_Traits.GetSubTreeInfo then
    local okST, sts = pcall(C_ClassTalents.GetHeroTalentSpecsForClassSpec)
    if okST and type(sts) == "table" then
      for _, stID in ipairs(sts) do
        local info = C_Traits.GetSubTreeInfo(configID, stID)
        for _, nID in ipairs((info and info.subTreeSelectionNodeIDs) or {}) do subSel[nID] = true end
      end
    end
  end
  local curHero, tgtHero
  for nID in pairs(subSel) do
    local node = C_Traits.GetNodeInfo(configID, nID)
    local curE = node and node.activeEntry and node.activeEntry.entryID
    curHero = (curE and subtreeNameFromEntry(configID, curE)) or curHero
    local tgtE = target[nID] and target[nID].entryID
    tgtHero = (tgtE and subtreeNameFromEntry(configID, tgtE)) or tgtHero
  end
  local heroChanged = curHero and tgtHero and curHero ~= tgtHero

  -- Name lists (for display) + parallel nodeID lists (for the live-tree glow).
  local added, removed, changed = {}, {}, {}
  local addedNodes, removedNodes, changedNodes = {}, {}, {}
  for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID)) do
    local node = C_Traits.GetNodeInfo(configID, nodeID)
    -- When the hero tree itself changes, skip all hero-related nodes — they're
    -- collapsed into heroChange below.
    local heroRelated = subSel[nodeID] or (node and node.subTreeID ~= nil)
    if node and not (heroChanged and heroRelated) then
      local curRanks = node.ranksPurchased or 0
      local curEntry = node.activeEntry and node.activeEntry.entryID
      local tgt = target[nodeID]
      local tgtRanks = tgt and tgt.ranks or 0
      local tgtEntry = tgt and tgt.entryID

      if tgtRanks > 0 and curRanks == 0 then
        added[#added + 1] = nodeName(configID, node, tgtEntry) or ("Node " .. nodeID)
        addedNodes[#addedNodes + 1] = nodeID
      elseif curRanks > 0 and tgtRanks == 0 then
        removed[#removed + 1] = nodeName(configID, node, curEntry) or ("Node " .. nodeID)
        removedNodes[#removedNodes + 1] = nodeID
      elseif curRanks > 0 and tgtRanks > 0 then
        if tgtEntry and curEntry and tgtEntry ~= curEntry then
          changed[#changed + 1] = (entryName(configID, tgtEntry) or "?") .. " (was " .. (entryName(configID, curEntry) or "?") .. ")"
          changedNodes[#changedNodes + 1] = nodeID
        elseif tgtRanks ~= curRanks then
          changed[#changed + 1] = (nodeName(configID, node, curEntry or tgtEntry) or ("Node " .. nodeID)) .. " (" .. curRanks .. " to " .. tgtRanks .. ")"
          changedNodes[#changedNodes + 1] = nodeID
        end
      end
    end
  end

  return {
    added = added, removed = removed, changed = changed,
    addedNodes = addedNodes, removedNodes = removedNodes, changedNodes = changedNodes,
    heroChange = heroChanged and { from = curHero, to = tgtHero } or nil,
  }
end

-- ---------------------------------------------------------------------------
-- Live talent-tree node glow (powers the "Changes If Applied" hover preview).
-- Maps nodeIDs → their buttons in the open Talents window via Blizzard's
-- TalentFrameBaseMixin:GetTalentButtonByNodeID, and pulses a coloured ring on
-- each. Only works while the Talents window is open (the buttons must exist).
-- ---------------------------------------------------------------------------
local glowPool, activeGlows = {}, {}

local function acquireGlow()
  local g = table.remove(glowPool)
  if g then return g end
  g = CreateFrame("Frame")
  -- Bold solid wash over the whole node (normal blend = strong tint on any art),
  -- white base tinted per-category via SetVertexColor; opacity pulses via the anim.
  -- Custom per-category glow PNG (soft feathered edge + a +/×/↻ symbol baked in).
  -- Texture is set per use; used as-is (no tint, no mask).
  g.tex = g:CreateTexture(nil, "OVERLAY", nil, 7)
  g.tex:SetAllPoints(g)
  g.ag = g:CreateAnimationGroup()
  local a = g.ag:CreateAnimation("Alpha")
  a:SetFromAlpha(1.0); a:SetToAlpha(0.5); a:SetDuration(0.6); a:SetSmoothing("IN_OUT")
  g.ag:SetLooping("BOUNCE")
  return g
end

function GBB:ClearNodeHighlights()
  for _, g in ipairs(activeGlows) do
    g.ag:Stop(); g:Hide(); g:SetParent(UIParent); g:ClearAllPoints()
    glowPool[#glowPool + 1] = g
  end
  wipe(activeGlows)
end

-- Pulse the given glow texture (a per-category PNG) on each node's button.
function GBB:HighlightNodes(nodeIDs, texPath)
  self:ClearNodeHighlights()
  local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
  if not (tf and tf.GetTalentButtonByNodeID and nodeIDs and texPath) then return end
  for _, nodeID in ipairs(nodeIDs) do
    local btn = tf:GetTalentButtonByNodeID(nodeID)
    if btn and btn:IsVisible() then
      local glow = acquireGlow()
      glow:SetParent(btn)
      glow:SetFrameStrata("HIGH")
      glow:SetFrameLevel((btn:GetFrameLevel() or 1) + 5)
      glow:ClearAllPoints()
      glow:SetPoint("CENTER", btn, "CENTER", 0, 0)
      local w, h = btn:GetSize()
      -- 1.9× to account for the PNG's internal padding (symbol ~node-sized, glow beyond).
      glow:SetSize((w and w > 0 and w or 32) * 1.9, (h and h > 0 and h or 32) * 1.9)
      glow.tex:SetTexture(texPath)
      glow:Show(); glow.ag:Play()
      activeGlows[#activeGlows + 1] = glow
    end
  end
end

-- ---------------------------------------------------------------------------
-- Talent heatmap — paint each live node by how often top players took it.
-- Mirrors the website's heat scale (hue 214→38 blue→gold, sat/light/alpha by
-- pick-rate). Pick-rate per talentID comes from BuildData's `heat` table;
-- talentID == TraitNodeEntry.ID, mapped to live nodes via the tree's entryIDs.
-- ---------------------------------------------------------------------------

-- entryID -> nodeID for the current spec's live tree (cached per spec).
local entryToNodeCache = {}
local function entryToNodeMap()
  local _, _, specID = GBB:CurrentSpec()
  local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if not (specID and configID) then return nil end
  if entryToNodeCache[specID] then return entryToNodeCache[specID] end
  local treeID = C_ClassTalents.GetTraitTreeForSpec and C_ClassTalents.GetTraitTreeForSpec(specID)
  if not treeID then return nil end
  local map = {}
  for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID)) do
    local info = C_Traits.GetNodeInfo(configID, nodeID)
    for _, eid in ipairs((info and info.entryIDs) or {}) do map[eid] = nodeID end
  end
  entryToNodeCache[specID] = map
  return map
end

local function hue2rgb(p, q, t)
  if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end
local function hslToRgb(h, s, l)
  if s == 0 then return l, l, l end
  h = h / 360
  local q = (l < 0.5) and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  return hue2rgb(p, q, h + 1 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1 / 3)
end
-- pick (0..1) -> r,g,b,alpha matching the site's heat() function.
local function heatColor(pick)
  local hue = 214 - 176 * pick
  local r, g, b = hslToRgb(hue, (35 + 55 * pick) / 100, (48 + 12 * pick) / 100)
  return r, g, b, 0.16 + 0.84 * pick
end

local heatPool, heatActive = {}, {}
local heatBorders = {} -- node StateBorder textures we hid while the heatmap is on
local function acquireHeat()
  local h = table.remove(heatPool)
  if h then return h end
  h = CreateFrame("Frame")
  -- shaded white orb, tinted per node by the heat colour (grayscale × multiply).
  h.tex = h:CreateTexture(nil, "ARTWORK")
  h.tex:SetTexture(GBB.MEDIA .. "heat_orb.png")
  h.tex:SetAllPoints(h)
  -- percentage on top of the orb, outlined so it reads on any colour.
  h.pct = h:CreateFontString(nil, "OVERLAY")
  if not h.pct:SetFont(GBB.FONT and GBB.FONT.label or "Fonts\\FRIZQT__.TTF", 11, "OUTLINE") then
    h.pct:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  end
  h.pct:SetTextColor(1, 1, 1)
  h.pct:SetPoint("CENTER", h, "CENTER", 0, 0)
  return h
end

function GBB:ClearHeatmap()
  for _, h in ipairs(heatActive) do
    h:Hide(); h:SetParent(UIParent); h:ClearAllPoints()
    heatPool[#heatPool + 1] = h
  end
  wipe(heatActive)
  for _, tex in ipairs(heatBorders) do tex:Show() end -- restore the gold node borders
  wipe(heatBorders)
end

-- Paint the heat table { [talentID]=pickRate } onto the live (current-spec) tree.
function GBB:ShowHeatmap(heat)
  self:ClearHeatmap()
  local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
  if not (tf and tf.GetTalentButtonByNodeID and heat) then return end
  local map = entryToNodeMap()
  if not map then return end

  -- Aggregate entry pick-rates up to their node (choice nodes have many entries).
  local nodePick = {}
  for entryID, pick in pairs(heat) do
    local nodeID = map[entryID]
    if nodeID then nodePick[nodeID] = math.min(1, (nodePick[nodeID] or 0) + pick) end
  end

  for nodeID, pick in pairs(nodePick) do
    local btn = tf:GetTalentButtonByNodeID(nodeID)
    if btn and btn:IsVisible() then
      -- Hide the node's SQUARE art (icon + borders + shadow) so the only thing
      -- left is the round orb on the dark tree — no square edges showing through.
      for _, key in ipairs({ "Icon", "Border", "Shadow", "StateBorder", "StateBorderHover" }) do
        local tex = btn[key]
        if tex and tex:IsShown() then tex:Hide(); heatBorders[#heatBorders + 1] = tex end
      end
      local h = acquireHeat()
      h:SetParent(btn); h:SetFrameStrata("HIGH"); h:SetFrameLevel((btn:GetFrameLevel() or 1) + 10)
      h:ClearAllPoints(); h:SetPoint("CENTER", btn, "CENTER", 0, 0)
      local w, ht = btn:GetSize()
      h:SetSize((w and w > 0 and w or 32) * 1.2, (ht and ht > 0 and ht or 32) * 1.2)
      local r, g, b = heatColor(pick)
      h.tex:SetVertexColor(r, g, b); h.tex:SetAlpha(1)
      h.pct:SetText(math.floor(pick * 100 + 0.5) .. "%")
      h:Show()
      heatActive[#heatActive + 1] = h
    end
  end
end

-- The heat table for the CURRENT spec at a given encounter (raid diff / M+), or nil.
function GBB:HeatFor(section, encId, diffKey)
  local builds = self:CurrentSpecBuilds()
  local sec = builds and builds[section]
  local enc = sec and sec[encId]
  if not enc then return nil end
  if section == "raid" then
    local node = enc[diffKey]
    return node and node.heat
  end
  return enc.heat
end

-- Similarity of a target build to your CURRENTLY-COMMITTED talents, as a 0-100
-- percentage: the share of the target build's talent POINTS you already have in
-- the right place (a node's points count as shared only when its choice matches).
-- Current-spec only — returns nil for an off-spec build (caller hides the line).
function GBB:BuildSimilarity(importString)
  local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local _, _, curSpecID = self:CurrentSpec()
  if curSpecID and headerSpecID(importString) ~= curSpecID then return nil end -- off-spec

  local entries = blizzardEntries(importString, configID)
  if not entries then return nil end

  -- Target ranks/selection per node (tiered nodes sum, like BuildDiff).
  local tgtRank, tgtSel, totalTgt = {}, {}, 0
  for _, e in ipairs(entries) do
    local r = e.ranksPurchased or 0
    tgtRank[e.nodeID] = (tgtRank[e.nodeID] or 0) + r
    totalTgt = totalTgt + r
    if e.selectionEntryID and e.selectionEntryID ~= 0 then tgtSel[e.nodeID] = e.selectionEntryID end
  end
  if totalTgt == 0 then return nil end

  local shared = 0
  for nodeID, tr in pairs(tgtRank) do
    local node = C_Traits.GetNodeInfo(configID, nodeID)
    if node then
      local cr = node.ranksPurchased or 0
      local curEntry = node.activeEntry and node.activeEntry.entryID
      local ts = tgtSel[nodeID]
      -- Different choice picked on a choice node ⇒ none of its points are shared.
      if not (ts and curEntry and ts ~= curEntry) then
        shared = shared + math.min(cr, tr)
      end
    end
  end
  return math.floor((shared / totalTgt) * 100 + 0.5)
end

-- The configID of our managed loadout for this spec, if it exists.
local function findManagedLoadout(specId)
  if not (C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID) then return nil end
  local ids = C_ClassTalents.GetConfigIDsBySpecID(specId)
  if type(ids) ~= "table" then return nil end
  for _, cid in ipairs(ids) do
    local info = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(cid)
    if info and info.name == GBB.LOADOUT_NAME then return cid end
  end
  return nil
end

-- Remove any prior managed loadout with our name for this spec, so we keep
-- exactly one. Never touches the active base config or non-managed loadouts.
local function deleteManagedLoadout(specId)
  local cid = findManagedLoadout(specId)
  local activeId = C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if cid and cid ~= activeId then
    pcall(C_ClassTalents.DeleteConfig, cid)
  end
end

-- ===========================================================================
-- Manual talent application (ported from TalentLoadoutsEx).
-- LoadConfig/ImportLoadout don't cleanly switch hero sub-trees — they leave the
-- old tree's granted gate node behind (Dark Ranger's Black Arrow lingered into a
-- Sentinel build). So we apply builds the way TalentLoadoutsEx does: fully reset
-- the tree, then purchase/select each node directly, then commit.
-- ===========================================================================

local HERO_TYPE = 0 -- our marker for hero-section nodes (TraitCurrencyFlag-style)

-- Per-spec node metadata, built lazily from the live tree.
local nodeMetaCache = {}
local function buildNodeMeta(specID, configID, treeID)
  if nodeMetaCache[specID] then return nodeMetaCache[specID] end

  -- visible nodes sorted top→bottom, left→right (purchase / gating order)
  local nodes = {}
  for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID)) do
    local info = C_Traits.GetNodeInfo(configID, nodeID)
    if info and info.isVisible then
      nodes[#nodes + 1] = { y = info.posY or 0, x = info.posX or 0, id = nodeID }
    end
  end
  table.sort(nodes, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)

  local order, nodeType, currencies = {}, {}, {}
  for idx, n in ipairs(nodes) do
    order[n.id] = idx
    local costs = C_Traits.GetNodeCost(configID, n.id)
    local curID = costs and costs[1] and costs[1].ID
    if curID then
      currencies[curID] = true
      nodeType[n.id] = C_Traits.GetTraitCurrencyInfo(curID) -- TraitCurrencyFlag: 4 class / 8 spec
    end
  end

  -- hero sub-trees: selection nodes are "hero" type; collect their currencies
  local subtreeIDs = {}
  local okST, st = pcall(C_ClassTalents.GetHeroTalentSpecsForClassSpec)
  if okST and type(st) == "table" then subtreeIDs = st end
  for _, stID in ipairs(subtreeIDs) do
    local info = C_Traits.GetSubTreeInfo(configID, stID)
    if info then
      if info.traitCurrencyID then currencies[info.traitCurrencyID] = true end
      for _, nID in ipairs(info.subTreeSelectionNodeIDs or {}) do
        nodeType[nID] = HERO_TYPE
      end
    end
  end

  local meta = { order = order, nodeType = nodeType, currencies = currencies, subtreeIDs = subtreeIDs }
  nodeMetaCache[specID] = meta
  return meta
end

-- Apply import entries to the active config by direct purchase, then commit.
local function applyEntries(configID, treeID, specID, entries)
  if not (C_Traits and C_Traits.PurchaseRank and C_Traits.SetSelection
    and C_Traits.ResetTreeByCurrency) then return false end
  local meta = buildNodeMeta(specID, configID, treeID)

  -- 1. Full reset → empty tree (also clears the old hero sub-tree's gate node).
  for _, stID in ipairs(meta.subtreeIDs) do
    local info = C_Traits.GetSubTreeInfo(configID, stID)
    for _, nID in ipairs((info and info.subTreeSelectionNodeIDs) or {}) do
      pcall(C_Traits.RefundRank, configID, nID)
    end
  end
  for curID in pairs(meta.currencies) do
    pcall(C_Traits.ResetTreeByCurrency, configID, treeID, curID)
  end

  -- 2. Target ranks / selections per node.
  local targetRank, targetSel = {}, {}
  for _, e in ipairs(entries) do
    targetRank[e.nodeID] = (targetRank[e.nodeID] or 0) + (e.ranksPurchased or 0)
    if e.selectionEntryID and e.selectionEntryID ~= 0 then targetSel[e.nodeID] = e.selectionEntryID end
  end

  -- 3. Select the hero sub-tree FIRST so its nodes become purchasable.
  for _, stID in ipairs(meta.subtreeIDs) do
    local info = C_Traits.GetSubTreeInfo(configID, stID)
    for _, nID in ipairs((info and info.subTreeSelectionNodeIDs) or {}) do
      if targetSel[nID] then pcall(C_Traits.SetSelection, configID, nID, targetSel[nID], false) end
    end
  end

  -- 4. Apply Class(4) → Spec(8) → Hero(0), each in node order (gates above first).
  local RANK = {}
  if Enum and Enum.TraitNodeType then
    if Enum.TraitNodeType.Single then RANK[Enum.TraitNodeType.Single] = true end
    if Enum.TraitNodeType.Tiered then RANK[Enum.TraitNodeType.Tiered] = true end
  end
  local nodeIDs = {}
  for nodeID in pairs(targetRank) do nodeIDs[#nodeIDs + 1] = nodeID end
  table.sort(nodeIDs, function(a, b) return (meta.order[a] or 1e9) < (meta.order[b] or 1e9) end)

  local function applyNode(nodeID)
    local node = C_Traits.GetNodeInfo(configID, nodeID)
    if not node then return end
    if RANK[node.type] then
      for _ = 1, (targetRank[nodeID] or 0) do pcall(C_Traits.PurchaseRank, configID, nodeID) end
    elseif targetSel[nodeID] then
      pcall(C_Traits.SetSelection, configID, nodeID, targetSel[nodeID], false)
    end
  end
  local passes = { 4, 8, HERO_TYPE }
  local done = {}
  for _, want in ipairs(passes) do
    for _, nodeID in ipairs(nodeIDs) do
      if not done[nodeID] and meta.nodeType[nodeID] == want then done[nodeID] = true; applyNode(nodeID) end
    end
  end
  for _, nodeID in ipairs(nodeIDs) do -- anything unclassified, last
    if not done[nodeID] then applyNode(nodeID) end
  end

  -- 5. Commit (C_Traits.CommitConfig — the taint-safe one per TalentLoadoutsEx).
  local cok, cret = true, true
  if C_Traits.CommitConfig then cok, cret = pcall(C_Traits.CommitConfig, configID) end
  GBB.dbg(("manual apply: nodes=%d commit ok=%s ret=%s"):format(#nodeIDs, tostring(cok), tostring(cret)))
  return cok and cret ~= false
end

-- Async loadout-creation watcher — mirrors Blizzard's ClassTalentsFrame exactly.
-- C_ClassTalents.ImportLoadout is ASYNCHRONOUS: it fires TRAIT_CONFIG_CREATED,
-- and a ranked build then needs a follow-up TRAIT_CONFIG_UPDATED once its ranks
-- populate. Only after that do we load + select the new config — which is what
-- makes it a real, persisting loadout (the step I was racing before).
local createWatcher = CreateFrame("Frame")
local pendingCreate -- { specID, buildLabel, gen, awaitPopulate = configID|nil }
local applyGen = 0   -- bumped per apply; a newer apply makes older async callbacks bail

-- Briefly mute the red UI error spam ("You can't do that right now") that the
-- GAME's own talent commit throws as it starts up. Scoped to the apply window
-- only, always paired with a safety timeout so errors are never left muted.
-- REVERSIBLE: delete this helper + its 3 call sites and nothing else changes.
local errorsMuted = false
local function muteUIErrors(on)
  if on == errorsMuted or not UIErrorsFrame then return end
  errorsMuted = on
  if on then
    UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")
  else
    UIErrorsFrame:RegisterEvent("UI_ERROR_MESSAGE")
  end
end

-- Make our loadout the selected one for this spec — in BOTH the persistent pref
-- AND the live Talents dropdown. Re-asserted on a delay because Blizzard's
-- commit-complete handler resets the selection to the base config a beat later.
local function selectLoadout(configID, specID)
  local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
  if specID and C_ClassTalents.UpdateLastSelectedSavedConfigID then
    pcall(C_ClassTalents.UpdateLastSelectedSavedConfigID, specID, configID)
  end
  if tf and tf.SetSelectedSavedConfigID then
    pcall(tf.SetSelectedSavedConfigID, tf, configID, false, true) -- select only, no re-apply
  end
  -- Re-sync the "Apply Changes" button. The glow = (isConfigReadyToApply OR
  -- HasAnyConfigChanges). We commit via C_ClassTalents.LoadConfig directly, bypassing
  -- the frame's LoadConfigInternal that would reset isConfigReadyToApply — so it
  -- stays stale-true and the button glows (and is disabled → dead glowing button).
  -- After our commit nothing is staged-ready, so clear it, then refresh the visuals.
  if tf then
    tf.isConfigReadyToApply = false
    if tf.UpdateConfigButtonsState then pcall(tf.UpdateConfigButtonsState, tf) end
  end
end

-- Just the button re-sync (no re-select), for late stale-glow cleanup.
local function syncApplyButton()
  local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
  if tf then
    tf.isConfigReadyToApply = false
    if tf.UpdateConfigButtonsState then pcall(tf.UpdateConfigButtonsState, tf) end
  end
end

-- GUARANTEE the build commits. LoadConfig's return value does NOT reliably tell
-- us whether the talents actually saved (autoApply is async; a tree-reset popup
-- or rate-limit can silently drop it — the "Apply Changes" button then glows). So
-- we verify the REAL state with HasAnyConfigChanges() (== is Apply Changes lit?)
-- and CommitConfig until it's clean, then tell the truth.
-- Drive the loadout to a committed state, verified by HasAnyConfigChanges (== is
-- "Apply Changes" lit?). When LoadConfig returned LoadInProgress, autoApply is
-- ALREADY committing — it just takes ~5s — so we ONLY WAIT; calling CommitConfig
-- then throws "You can't do that right now" and interferes. We commit ourselves
-- only when autoApply isn't handling it (and only once; or as a late last resort).
local function ensureCommitted(configID, label, specID, gen, autoCommit, committed, tries)
  -- A newer apply has superseded this one — stop touching the config/selection.
  if gen ~= applyGen then GBB.dbg("ensureCommitted superseded gen="..tostring(gen)); return end

  local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
  local pending = tf and tf.HasAnyConfigChanges and tf:HasAnyConfigChanges()
  local committing = tf and tf.IsCommitInProgress and tf:IsCommitInProgress()
  GBB.dbg(("ensureCommitted try=%d pending=%s committing=%s auto=%s"):format(
    tries, tostring(pending), tostring(committing), tostring(autoCommit)))

  if not pending then
    muteUIErrors(false)
    selectLoadout(configID, specID)
    C_Timer.After(1.5, function() if gen == applyGen then selectLoadout(configID, specID) end end)
    -- Late re-syncs: the import's async events can light the glow AFTER the above,
    -- so clear it again once everything has settled (cancelled if a newer apply starts).
    C_Timer.After(4.0, function() if gen == applyGen then syncApplyButton() end end)
    C_Timer.After(7.0, function() if gen == applyGen then syncApplyButton() end end)
    GBB.msg("applied the "..(label or "").." build to your \""..GBB.LOADOUT_NAME.."\" loadout.")
    if GBB.UI and GBB.UI.OnBuildApplied then GBB.UI:OnBuildApplied() end -- refresh the panel's diff
    return
  end

  -- Generous window — the commit itself takes ~5s.
  if tries >= 18 then
    muteUIErrors(false)
    selectLoadout(configID, specID)
    GBB.msg("saved the "..(label or "").." build to your \""..GBB.LOADOUT_NAME
      .."\" loadout, but the game wouldn't auto-apply it — open Talents and click \"Apply Changes\".")
    return
  end

  -- Commit ourselves only when autoApply isn't doing it (and only once). For the
  -- autoApply case, leave it alone unless it's clearly stuck well past the ~5s.
  if not committed and not committing and C_ClassTalents.CommitConfig
     and ((not autoCommit) or tries >= 14) then
    pcall(C_ClassTalents.CommitConfig, configID)
    committed = true
  end
  C_Timer.After(0.5, function() ensureCommitted(configID, label, specID, gen, autoCommit, committed, tries + 1) end)
end

-- Load the freshly-created loadout, then verify-commit it. LoadConfig itself can
-- fail (Error) when the active config isn't ready yet — common right after
-- ImportLoadout or a spec switch — so retry that; the commit is handled by
-- ensureCommitted, which trusts the live state, not LoadConfig's return.
local function loadAndApply(configID, label, specID, gen, attempt)
  attempt = attempt or 1
  if gen ~= applyGen then GBB.dbg("loadAndApply superseded gen="..tostring(gen)); return end
  -- Mute the game's commit-startup error spam for the apply window (safety timeout
  -- guarantees it's restored even if something below never resolves).
  if attempt == 1 then
    muteUIErrors(true)
    C_Timer.After(12, function() muteUIErrors(false) end)
  end
  local R = (Enum and Enum.LoadConfigResult) or {}
  local lok, result, changeErr = pcall(C_ClassTalents.LoadConfig, configID, true)
  GBB.dbg(("loadAndApply attempt=%d ok=%s result=%s err=%s id=%s"):format(
    attempt, tostring(lok), tostring(result), tostring(changeErr), tostring(configID)))

  if (not lok) or result == R.Error then
    if attempt < 4 then
      C_Timer.After(0.6, function() loadAndApply(configID, label, specID, gen, attempt + 1) end)
    else
      muteUIErrors(false)
      GBB.msg("saved the "..(label or "").." build to your \""..GBB.LOADOUT_NAME
        .."\" loadout, but the game wouldn't apply it automatically — open Talents and click \"Apply Changes\".")
    end
    return
  end

  -- Load accepted. autoApply commits on its own when LoadConfig returned
  -- LoadInProgress; ensureCommitted waits for that and only steps in otherwise.
  local autoCommit = (result == R.LoadInProgress)
  C_Timer.After(0.8, function() ensureCommitted(configID, label, specID, gen, autoCommit, false, 1) end)
end

local function finishLoadout(configID)
  local p = pendingCreate
  pendingCreate = nil
  createWatcher:UnregisterAllEvents()
  if not p then return end
  loadAndApply(configID, p.buildLabel, p.specID, p.gen)
end

createWatcher:SetScript("OnEvent", function(_, event, arg1)
  if not pendingCreate then return end
  if event == "TRAIT_CONFIG_CREATED" then
    local combat = Enum.TraitConfigType and Enum.TraitConfigType.Combat
    if type(arg1) == "table" and (not combat or arg1.type == combat) then
      local configID = arg1.ID
      if C_ClassTalents.IsConfigPopulated and not C_ClassTalents.IsConfigPopulated(configID) then
        pendingCreate.awaitPopulate = configID -- ranks not in yet; wait for the update
        GBB.dbg("config created, awaiting populate id="..tostring(configID))
      else
        finishLoadout(configID)
      end
    end
  elseif event == "TRAIT_CONFIG_UPDATED" then
    if pendingCreate.awaitPopulate and arg1 == pendingCreate.awaitPopulate then
      finishLoadout(arg1)
    end
  end
end)

-- The real import, run when we know the active spec matches the target.
function GBB:DoImport(importString, buildLabel)
  if not (C_Traits and C_Traits.PurchaseRank) then
    msg("this game version has no talent API.")
    return false
  end
  local configID = C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
  if not configID then
    msg("no active talent config — open your talents once, then retry.")
    return false
  end

  importTalentUILoaded()

  local _, specName, specId = self:CurrentSpec()
  dbg(("DoImport configID=%s curSpec=%s(id %s) len %d"):format(
    tostring(configID), tostring(specName), tostring(specId), #importString))

  -- WoW refuses to commit talent edits while the Blizzard Starter Build is
  -- active. Deactivate it, then retry once it settles (TalentLoadoutsEx does this).
  if C_ClassTalents.GetStarterBuildActive and C_ClassTalents.GetStarterBuildActive() then
    if self._starterTried then
      self._starterTried = nil
      msg("couldn't leave the Starter Build automatically — switch off it in the loadout dropdown, then apply again.")
      return false
    end
    self._starterTried = true
    dbg("starter build active — deactivating, retrying shortly")
    pcall(C_ClassTalents.SetStarterBuildActive, false)
    C_Timer.After(0.6, function() GBB:DoImport(importString, buildLabel) end)
    return true
  end
  self._starterTried = nil

  -- Prefer Blizzard's own converter (correct ranks/grants/choices). Fall back
  -- to our hand parser only if the talent UI isn't reachable.
  local entries, breason = blizzardEntries(importString, configID)
  if entries then
    local tr = 0
    for _, e in ipairs(entries) do tr = tr + (e.ranksPurchased or 0) end
    dbg(("Blizzard converter: entries=%d totalRanks=%d"):format(#entries, tr))
  else
    dbg("Blizzard converter n/a ("..tostring(breason)..") — using fallback parser")
    local pok, e2, errKind, headerSpec = pcall(parseImportString, importString, configID)
    if not pok then
      dbg("parse threw: "..tostring(e2))
      msg("couldn't read this build string (error: "..tostring(e2).."). (Please report.)")
      return false
    end
    if not e2 then
      if errKind == "spec-mismatch" then
        msg(("this build is for a different spec (build spec %s, you are %s) — switch to the matching spec first."):format(
          tostring(headerSpec), tostring(specId)))
      elseif errKind == "tree-version" then
        msg("this build was exported for a different talent-tree version than your client — it can't be applied. The website data likely needs a fresh harvest.")
      else
        msg("couldn't read this build string ("..tostring(errKind).."). (Please report.)")
      end
      return false
    end
    entries = e2
  end

  -- Resolve the live tree id for the current spec, then apply by direct purchase.
  local treeID
  local specForTree = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
  if specForTree and C_ClassTalents.GetTraitTreeForSpec then
    treeID = C_ClassTalents.GetTraitTreeForSpec(specForTree)
  end
  if not treeID then
    local cfg = C_Traits.GetConfigInfo(configID)
    treeID = cfg and cfg.treeIDs and cfg.treeIDs[1]
  end
  if not treeID then
    msg("couldn't find your talent tree — open Talents once, then retry.")
    return false
  end

  -- Create the addon's loadout via Blizzard's exact async import flow (the same
  -- calls the in-game Import dialog makes). ImportLoadout takes the import STRING
  -- as a 4th arg and is asynchronous — the watcher above loads + selects the new
  -- config once TRAIT_CONFIG_CREATED (and its populate update) fire. The result
  -- is a real, persisting "Gloom's Build Barn" loadout; your others are untouched.
  if not C_ClassTalents.ImportLoadout then
    msg("this game version can't create talent loadouts. (Please report.)")
    return false
  end
  if specId then deleteManagedLoadout(specId) end

  applyGen = applyGen + 1 -- supersede any in-flight apply's async callbacks
  pendingCreate = { specID = specId, buildLabel = buildLabel, gen = applyGen }
  createWatcher:RegisterEvent("TRAIT_CONFIG_CREATED")
  createWatcher:RegisterEvent("TRAIT_CONFIG_UPDATED")

  local pOK, success, errStr = pcall(C_ClassTalents.ImportLoadout, configID, entries, GBB.LOADOUT_NAME, importString)
  dbg(("ImportLoadout: pcall=%s success=%s err=%s entries=%d"):format(
    tostring(pOK), tostring(success), tostring(errStr), #entries))
  if not pOK or not success then
    pendingCreate = nil
    createWatcher:UnregisterAllEvents()
    msg("the import was rejected"..(type(errStr) == "string" and (": "..errStr) or "")..". (Please report.)")
    return false
  end

  -- Safety net: if the create event never arrives, don't leave a stuck pending.
  C_Timer.After(6, function()
    if pendingCreate and pendingCreate.specID == specId then
      pendingCreate = nil
      createWatcher:UnregisterAllEvents()
      dbg("loadout create timed out (no TRAIT_CONFIG_CREATED)")
    end
  end)
  return true
end

-- Public entry the UI calls. specIndex/specName identify the target spec;
-- importString is the baked build; buildLabel is e.g. "Best Performing".
function GBB:ApplyForSpec(specIndex, specName, importString, buildLabel)
  if InCombatLockdown() then
    msg("can't change talents in combat.")
    return false
  end
  if type(importString) ~= "string" or importString == "" then
    msg("no build string to apply.")
    return false
  end
  if pendingApply then
    msg("still switching specs — hang on a few seconds, then it'll apply automatically.")
    return false
  end

  local current = GetSpecialization()
  dbg(("ApplyForSpec target=%s(idx %s) current idx=%s"):format(
    tostring(specName), tostring(specIndex), tostring(current)))

  if specIndex and current ~= specIndex then
    -- Switch specs first; finish on PLAYER_SPECIALIZATION_CHANGED.
    pendingApply = { importString = importString, specIndex = specIndex, buildLabel = buildLabel }
    msg("switching to "..tostring(specName)..", then applying the "..(buildLabel or "").." build…")
    if not switchSpec(specIndex) then
      msg("couldn't switch spec from an addon in this client — change to "..tostring(specName)
        .." manually, then Apply.")
      pendingApply = nil
      return false
    end
    -- Spec change is a ~5s cast in this client; the apply runs when
    -- PLAYER_SPECIALIZATION_CHANGED fires. This is only a long safety net for a
    -- switch that never lands — by the time it fires, a real switch has already
    -- consumed pendingApply, so no spurious message appears mid-cast.
    C_Timer.After(12, function()
      if pendingApply and pendingApply.specIndex == specIndex then
        pendingApply = nil
        local _, curName = GBB:CurrentSpec()
        msg("spec change didn't complete (still "..tostring(curName)..") — try again once you're "..tostring(specName)..".")
      end
    end)
    return true
  end

  return self:DoImport(importString, buildLabel)
end

-- Back-compat: apply for the current spec.
function GBB:ApplyBuild(importString, buildLabel)
  local _, _, _, idx = self:CurrentSpec()
  return self:ApplyForSpec(idx, nil, importString, buildLabel)
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------
local function printStatus()
  print(PREFIX.." v"..tostring(GBB.version))
  local data = GBB:Data()
  if not data then
    print("  build data: |cffff4444not loaded|r")
    return
  end
  local meta = data.meta or {}
  print("  data generated: "..tostring(meta.generatedAt))

  local builds, classToken, specName = GBB:CurrentSpecBuilds()
  if not builds then
    print("  current spec: "..tostring(classToken).." / "..tostring(specName).." — |cffff4444no builds|r")
    return
  end
  local raidN, mplusN = 0, 0
  for _ in pairs(builds.raid or {}) do raidN = raidN + 1 end
  for _ in pairs(builds.mythicplus or {}) do mplusN = mplusN + 1 end
  print("  current spec: "..classToken.." / "..specName
    .." ("..raidN.." raid bosses, "..mplusN.." M+ dungeons)")
end

SLASH_GLOOMSBUILDBARN1 = "/gbb"
SLASH_GLOOMSBUILDBARN2 = "/glooms"
SlashCmdList["GLOOMSBUILDBARN"] = function(arg)
  arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "status" then
    printStatus()
  elseif arg == "debug" then
    GBB.debug = not GBB.debug
    print(PREFIX.." debug "..(GBB.debug and "|cff40ff40on|r" or "|cffff4444off|r"))
  elseif arg == "minimap" then
    local shown = GBB.ToggleMinimapButton and GBB:ToggleMinimapButton()
    print(PREFIX.." minimap button "..(shown and "|cff40ff40shown|r" or "|cffff4444hidden|r"))
  elseif arg == "dock" then
    if GBB.UI and GBB.UI.SetDocked then
      local docked = not (GBB.db and GBB.db.docked)
      GBB.UI:SetDocked(docked)
      print(PREFIX.." "..(docked and "docked to the Talents window" or "undocked (standalone window)"))
    end
  elseif arg == "probe" then
    local tab = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    print(PREFIX.." probe: PlayerSpellsFrame="..tostring(PlayerSpellsFrame ~= nil)
      .." TalentsFrame="..tostring(tab ~= nil))
    if not tab then
      print("  open your Talents tab first, then run /gbb probe again.")
      return
    end
    local seen, hits = {}, {}
    local t = tab
    while type(t) == "table" do
      for k, v in pairs(t) do
        if type(v) == "function" and not seen[k] then
          local lk = k:lower()
          if lk:find("import") or lk:find("loadout") or lk:find("config") or lk:find("tree") then
            seen[k] = true
            hits[#hits + 1] = k
          end
        end
      end
      local mt = getmetatable(t)
      t = mt and mt.__index
      if type(t) ~= "table" then break end
    end
    table.sort(hits)
    print("  methods: "..(next(hits) and table.concat(hits, ", ") or "(none found)"))
  elseif arg == "help" then
    print(PREFIX.." — |cffffd200/gbb|r opens the window · |cffffd200/gbb dock|r dock to/undock from the Talents window · |cffffd200/gbb minimap|r show/hide the minimap button · |cffffd200/gbb status|r data status · |cffffd200/gbb debug|r toggle diagnostics · |cffffd200/gbb probe|r list talent methods.")
  else
    if GBB.UI and GBB.UI.Toggle then
      GBB.UI:Toggle()
    else
      printStatus()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Boot / events
-- ---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:SetScript("OnEvent", function(_, event, unit)
  if event == "PLAYER_LOGIN" then
    GloomsBuildBarnDB = GloomsBuildBarnDB or {}
    GBB.db = GloomsBuildBarnDB
    print(PREFIX.." loaded. Type |cffffd200/gbb|r to open.")
    if GBB.UI and GBB.UI.OnLogin then GBB.UI:OnLogin() end
    if GBB.InitMinimapButton then GBB:InitMinimapButton() end
  elseif event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player" then
    local _, curName = GBB:CurrentSpec()
    dbg("PLAYER_SPECIALIZATION_CHANGED -> "..tostring(curName))
    if pendingApply then
      local p = pendingApply
      pendingApply = nil
      -- Let the new spec's config settle before importing. A freshly-switched
      -- spec keeps learning/initialising for a beat, so give it ~1.5s (the
      -- loadAndApply retry covers any remaining race).
      C_Timer.After(1.5, function()
        if GetSpecialization() == p.specIndex then
          GBB:DoImport(p.importString, p.buildLabel)
        else
          msg("spec didn't switch as expected — apply cancelled.")
        end
      end)
    end
    if GBB.UI and GBB.UI.OnSpecChanged then GBB.UI:OnSpecChanged() end
  end
end)
