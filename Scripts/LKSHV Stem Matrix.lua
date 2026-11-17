-- @description LKSHV Stem Matrix — one-click mute / solo for _STM tracks
-- @version 1.7
-- @author Ilia Lukashev
-- @changelog
--   Donate button opens taplink.cc/lukashevmixing
--   A plain click on a soloed stem takes the solo off instead of muting it
--   Donate button (heart after the last stem, and in the right-click menu)
--   Shift+click: select the stem and scroll the track list so it sits at the top
--   Drag across buttons with the left button held to mute / unmute (Cmd: solo) several stems in one gesture
--   Renamed LG -> LKSHV (saved stem-name rules are carried over)
--   Which tracks count as stems is configurable per project (e.g. "bus") with a global default ("_stm")
-- @about
--   A compact button matrix of every stem track. By default a stem is a track whose name ends in "_STM"
--   (any case); right-click > Match track names sets other rules per project, e.g. "bus" or "_stm, bus".
--   Click: mute / unmute the stem. Cmd+click (Ctrl on Windows): solo / unsolo.
--   Shift+click: select the stem and scroll the track list so it is the top track.
--   Right-click: unmute all, unsolo all, dock / undock. Made to live in a REAPER docker.
--   Requires ReaImGui (ReaPack: ReaTeam Extensions).

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script needs ReaImGui.\nInstall it via Extensions → ReaPack → Browse packages → ReaImGui.", "LKSHV Stem Matrix", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'

local NAME = "LKSHV Stem Matrix"
local DONATE_URL = "https://taplink.cc/lukashevmixing"   -- where the heart button leads
local OLD_NAME = "LG Stem Matrix"   -- pre-rename: saved rules are still read from it
local ctx = ImGui.CreateContext(NAME)
local font = ImGui.CreateFont('sans-serif', 13)
ImGui.Attach(ctx, font)

-- palette (Lukashev Graphite)
local C = {
  bg     = 0x1E1E20FF, btn  = 0x2E2E32FF, btnHi = 0x3A3A3FFF, btnMute = 0x232325FF,
  edge   = 0x141416FF, text = 0xF0F0F2FF, textMute = 0x77777CFF,
  solo   = 0xFFD60AFF, mute = 0xFF453AFF, accent = 0x0A84FFFF,
}

local BTN_MIN_W, BTN_H, GAP = 92, 30, 4
local dockWanted = nil   -- set from the menu; ReaImGui remembers docking between runs itself

-- ---------------------------------------------------------------- tracks
-- rules: comma separated; "_xxx" = suffix (e.g. _stm matches "DRUMS_STM", "Vox_Stm 2"),
-- anything else = a word in the name (e.g. bus matches "MUSIC BUS", "Drum Buss")
local DEFAULT_RULES = "_stm"
local rulesText, rules

local function loadRules()
  local _, proj = reaper.GetProjExtState(0, NAME, "match")
  if proj == "" then _, proj = reaper.GetProjExtState(0, OLD_NAME, "match") end
  local glob = reaper.GetExtState(NAME, "match")
  if glob == "" then glob = reaper.GetExtState(OLD_NAME, "match") end
  rulesText = (proj ~= "" and proj) or (glob ~= "" and glob) or DEFAULT_RULES
  rules = {}
  for w in rulesText:gmatch("[^,]+") do
    w = w:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if w ~= "" then rules[#rules + 1] = w end
  end
end

local function escape(p) return (p:gsub("%p", "%%%0")) end

local function isStem(name)
  local l = name:lower()
  for _, r in ipairs(rules) do
    if r:sub(1, 1) == "_" then
      if l:find(escape(r) .. "%f[^%a]") then return true end
    else
      for w in l:gmatch("%w+") do
        if w == r or w == r .. "s" then return true end     -- bus / buss, stem / stems
      end
    end
  end
  return false
end

local function shortName(name)
  local s = name
  for _, r in ipairs(rules) do
    if r:sub(1, 1) == "_" then
      local pat = "[_%s]*" .. escape(r:sub(2)):gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end) .. "%f[^%a]"
      s = s:gsub(pat, "", 1)
    end
  end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s ~= "" and s or name
end

local function editRules(scope)
  local ok, v = reaper.GetUserInputs(NAME .. (scope == "project" and " - this project" or " - default"), 1,
    "Stem names (comma separated):,extrawidth=220", rulesText)
  if not ok then return end
  v = v:gsub("^%s+", ""):gsub("%s+$", "")
  if scope == "project" then
    reaper.SetProjExtState(0, NAME, "match", v)
    reaper.MarkProjectDirty(0)
  else
    reaper.SetExtState(NAME, "match", v, true)
  end
  loadRules()
end

local function stems()
  local t = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm and isStem(nm) then
      local col = reaper.GetTrackColor(tr)
      local rgba = nil
      if col and col ~= 0 then
        local r, g, b = reaper.ColorFromNative(col)
        rgba = (r << 24) | (g << 16) | (b << 8) | 0xFF
      end
      t[#t + 1] = {
        tr = tr, label = shortName(nm), color = rgba,
        mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0.5,
        solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0,
      }
    end
  end
  return t
end

local function setAll(list, parm, val, undo)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for _, s in ipairs(list) do reaper.SetMediaTrackInfo_Value(s.tr, parm, val) end
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(undo, -1)
end

-- one gesture: press on a stem flips it, dragging on applies the SAME new state to every stem passed over
local drag   -- { parm = "B_MUTE"|"I_SOLO", val = number, done = {[track]=true}, n = count, label = first stem }

local function paint(s)
  if drag.done[s.tr] then return end
  drag.done[s.tr] = true
  drag.n = drag.n + 1
  reaper.SetMediaTrackInfo_Value(s.tr, drag.parm, drag.val)
end

local function beginDrag(s, solo)
  if s.solo and not solo then drag = { parm = "I_SOLO", val = 0 }       -- plain click on a soloed stem: unsolo
  elseif solo then drag = { parm = "I_SOLO", val = s.solo and 0 or 2 }  -- 2 = solo in place
  else drag = { parm = "B_MUTE", val = s.mute and 0 or 1 } end
  drag.done, drag.n, drag.label = {}, 0, s.label
  paint(s)
end

local function openURL(url)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url)
  elseif reaper.GetOS():match("OSX") or reaper.GetOS():match("mac") then os.execute("open '" .. url .. "'")
  else os.execute('start "" "' .. url .. '"') end
end

-- small heart pill, same height as the stem buttons
local function donateButton()
  local w = BTN_H + 4
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, "##donate", w, BTN_H)
  local hov = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + BTN_H, hov and C.accent or C.btnMute, 6)
  ImGui.DrawList_AddRect(dl, x, y, x + w, y + BTN_H, C.edge, 6, 0, 1)
  local col = hov and 0xFFFFFFFF or 0xFF5A7AFF
  local cx, cy = x + w / 2, y + BTN_H / 2 - 1
  ImGui.DrawList_AddCircleFilled(dl, cx - 2.7, cy - 1.8, 3.4, col)
  ImGui.DrawList_AddCircleFilled(dl, cx + 2.7, cy - 1.8, 3.4, col)
  ImGui.DrawList_AddTriangleFilled(dl, cx - 5.95, cy - 0.7, cx + 5.95, cy - 0.7, cx, cy + 5.6, col)
  if hov and not drag then ImGui.SetTooltip(ctx, "Donate - support the development\n" .. DONATE_URL) end
  if clicked then openURL(DONATE_URL) end
end

-- scroll the arrange / TCP so this track is the first one visible
local function scrollToTop(tr)
  reaper.SetOnlyTrackSelected(tr)
  reaper.SetMixerScroll(tr)
  local y = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY")
  if reaper.JS_Window_FindChildByID then                          -- exact, when js_ReaScriptAPI is installed
    local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
    local ok, pos = reaper.JS_Window_GetScrollInfo(arrange, "v")
    if arrange and ok then
      reaper.JS_Window_SetScrollPos(arrange, "v", math.max(0, math.floor(pos + y)))
      reaper.UpdateArrange()
      return
    end
  end
  -- fallback: step the scroll until the track's top edge reaches the top of the view
  local dir = y > 0 and 1 or -1
  for _ = 1, 2000 do
    if y == 0 then break end
    reaper.CSurf_OnScroll(0, dir)
    local now = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY")
    if now == y then break end                                   -- reached the end of the list
    if (now > 0) ~= (y > 0) then                                 -- stepped past the top: keep the closer position
      if math.abs(now) > math.abs(y) then reaper.CSurf_OnScroll(0, -dir) end
      break
    end
    y = now
  end
  reaper.UpdateArrange()
end

local function endDrag()
  local what = drag.parm == "I_SOLO" and (drag.val > 0 and "Solo" or "Unsolo") or (drag.val > 0 and "Mute" or "Unmute")
  reaper.Undo_OnStateChange(drag.n == 1 and (what .. " stem " .. drag.label) or (what .. " " .. drag.n .. " stems"))
  drag = nil
end

-- ---------------------------------------------------------------- drawing
local function ellipsize(text, maxW)
  if ImGui.CalcTextSize(ctx, text) <= maxW then return text end
  local s = text
  while #s > 1 and ImGui.CalcTextSize(ctx, s .. "…") > maxW do s = s:sub(1, -2) end
  return s .. "…"
end

local function stemButton(i, s, w)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##stem" .. i, w, BTN_H)
  -- own hit-test: while the button is held, ImGui reports hover only for the pressed item
  local mx, my = ImGui.GetMousePos(ctx)
  local hov = mx and mx >= x and mx < x + w and my >= y and my < y + BTN_H and ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_AllowWhenBlockedByActiveItem)
  local dl = ImGui.GetWindowDrawList(ctx)
  local bg = s.mute and C.btnMute or (hov and C.btnHi or C.btn)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + BTN_H, bg, 6)
  ImGui.DrawList_AddRect(dl, x, y, x + w, y + BTN_H, s.solo and C.solo or C.edge, 6, 0, s.solo and 2 or 1)
  -- track colour bar on the left (faded when muted)
  if s.color then
    local c = s.mute and ((s.color & 0xFFFFFF00) | 0x55) or s.color
    ImGui.DrawList_AddRectFilled(dl, x + 4, y + 6, x + 7, y + BTN_H - 6, c, 1.5)
  end
  -- state chip on the right
  local chipW = 0
  if s.mute or s.solo then
    chipW = 16
    local cx, cy = x + w - chipW - 6, y + (BTN_H - 14) / 2
    ImGui.DrawList_AddRectFilled(dl, cx, cy, cx + chipW, cy + 14, s.solo and C.solo or C.mute, 3)
    local ch = s.solo and "S" or "M"
    local tw = ImGui.CalcTextSize(ctx, ch)
    ImGui.DrawList_AddText(dl, cx + (chipW - tw) / 2, cy, 0x111111FF, ch)
  end
  local tx = x + 13
  local label = ellipsize(s.label, w - 13 - 8 - (chipW > 0 and chipW + 6 or 0))
  local _, th = ImGui.CalcTextSize(ctx, label)
  ImGui.DrawList_AddText(dl, tx, y + (BTN_H - th) / 2, s.mute and C.textMute or C.text, label)
  if hov and not drag then
    ImGui.SetTooltip(ctx, s.label .. "\nClick: " .. (s.solo and "unsolo" or (s.mute and "unmute" or "mute")) ..
      "   Cmd+click: " .. (s.solo and "unsolo" or "solo") .. "\nDrag across buttons: several at once\nShift+click: go to track")
  end
  return hov
end

-- ---------------------------------------------------------------- loop
local lastProj
local pendingEdit
local function frame()
  local proj = reaper.EnumProjects(-1)
  if proj ~= lastProj then lastProj = proj; loadRules() end
  if pendingEdit then local sc = pendingEdit; pendingEdit = nil; editRules(sc) end
  local list = stems()
  if dockWanted ~= nil then ImGui.SetNextWindowDockID(ctx, dockWanted); dockWanted = nil end
  ImGui.SetNextWindowSize(ctx, 320, 140, ImGui.Cond_FirstUseEver)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, C.bg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 6, 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, GAP, GAP)
  ImGui.PushFont(ctx, font)
  local visible, open = ImGui.Begin(ctx, NAME, true, ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoCollapse)
  if visible then
    local availW = ImGui.GetContentRegionAvail(ctx)
    if #list == 0 then
      ImGui.TextColored(ctx, C.textMute, "No stem tracks (" .. rulesText .. ")")
      ImGui.TextColored(ctx, C.textMute, "Right-click > Match track names")
    else
      local cols = math.max(1, math.floor((availW + GAP) / (BTN_MIN_W + GAP)))
      local w = math.floor((availW - GAP * (cols - 1)) / cols)
      local mods = ImGui.GetKeyMods(ctx)
      local cmd = (mods & ImGui.Mod_Ctrl) ~= 0 or (mods & ImGui.Mod_Super) ~= 0
      for i, s in ipairs(list) do
        if (i - 1) % cols ~= 0 then ImGui.SameLine(ctx) end
        if stemButton(i, s, w) then
          if not drag and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Left) then
            if (mods & ImGui.Mod_Shift) ~= 0 then scrollToTop(s.tr) else beginDrag(s, cmd) end
          elseif drag and ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then paint(s) end
        end
      end
      if #list % cols ~= 0 then ImGui.SameLine(ctx) end
      donateButton()
      if drag and not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then endDrag() end
    end
    local docked = ImGui.IsWindowDocked(ctx)
    -- right-click anywhere in the window
    if ImGui.IsWindowHovered(ctx) and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then
      ImGui.OpenPopup(ctx, "menu")
    end
    if ImGui.BeginPopup(ctx, "menu") then
      if ImGui.MenuItem(ctx, "Unmute all stems") then setAll(list, "B_MUTE", 0, "Unmute all stems") end
      if ImGui.MenuItem(ctx, "Unsolo all stems") then setAll(list, "I_SOLO", 0, "Unsolo all stems") end
      ImGui.Separator(ctx)
      ImGui.TextDisabled(ctx, "Stems: " .. rulesText)
      if ImGui.MenuItem(ctx, "Match track names (this project)...") then pendingEdit = "project" end
      if ImGui.MenuItem(ctx, "Match track names (default)...") then pendingEdit = "default" end
      ImGui.Separator(ctx)
      if ImGui.MenuItem(ctx, docked and "Undock" or "Dock in REAPER docker") then
        dockWanted = docked and 0 or -1
      end
      if ImGui.MenuItem(ctx, "Donate...") then openURL(DONATE_URL) end
      if ImGui.MenuItem(ctx, "Close") then open = false end
      ImGui.EndPopup(ctx)
    end
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx)
  if open then reaper.defer(frame) end
end

reaper.defer(frame)
