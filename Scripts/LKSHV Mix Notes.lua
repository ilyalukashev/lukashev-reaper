-- @description LKSHV Mix Notes — paste client revisions, get a checklist with timecodes
-- @version 1.0
-- @author Ilia Lukashev
-- @changelog
--   First release
-- @about
--   Paste (or type) revision notes from an email or a chat. The text is split into separate notes:
--   by song / section headers, bullets and sentences, and every timecode (1:23, 01:02:03, 1:20-1:35)
--   becomes its own note. Click a timecode to jump there, tick a note when it is done, flag notes
--   red / yellow / green. Notes are saved inside the project.
--   Requires ReaImGui (ReaPack: ReaTeam Extensions).

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script needs ReaImGui.\nInstall it via Extensions > ReaPack > Browse packages > ReaImGui.", "LKSHV Mix Notes", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'

local NAME = "LKSHV Mix Notes"
local DONATE_URL = "https://taplink.cc/lukashevmixing"
local ctx = ImGui.CreateContext(NAME)
local font = ImGui.CreateFont('sans-serif', 14)
local fontSmall = ImGui.CreateFont('sans-serif', 12)
local fontHead = ImGui.CreateFont('sans-serif', 15, ImGui.FontFlags_Bold or 0)
ImGui.Attach(ctx, font); ImGui.Attach(ctx, fontSmall); ImGui.Attach(ctx, fontHead)

-- palette (Lukashev Graphite)
local C = {
  bg = 0x1E1E20FF, panel = 0x26262AFF, field = 0x2E2E32FF, fieldHi = 0x3A3A3FFF, edge = 0x141416FF,
  text = 0xF0F0F2FF, text2 = 0xA8A8AEFF, text3 = 0x77777CFF, accent = 0x0A84FFFF,
  red = 0xFF453AFF, yellow = 0xFFD60AFF, green = 0x30D158FF, none = 0x55555AFF,
}
local FLAG = { [0] = C.none, C.red, C.yellow, C.green }
local FLAG_NAME = { [0] = "No colour", "Red", "Yellow", "Green" }

-- state: S.items is a flat list; kind "g" = header (song / section), kind "i" = note
local S = { items = {}, hideDone = false, show = 0, paste = "", pasteOpen = false, quick = "", edit = nil,
            editBuf = "", editFocus = false, undo = nil, status = "", statusT = 0 }

------------------------------------------------------------------ helpers
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function say(msg) S.status, S.statusT = msg, reaper.time_precise() end
local function fmtTime(t)
  t = math.floor(t + 0.5)
  local h, m, s = t // 3600, (t % 3600) // 60, t % 60
  if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
  return ("%d:%02d"):format(m, s)
end
local function openURL(url)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url)
  elseif reaper.GetOS():match("OSX") or reaper.GetOS():match("mac") then os.execute("open '" .. url .. "'")
  else os.execute('start "" "' .. url .. '"') end
end

------------------------------------------------------------------ parsing
-- every timecode in a string: { s = first byte, e = byte after the last, t = seconds }
local function findTimecodes(str)
  local out, pos = {}, 1
  while true do
    local s, e, a, b = str:find("(%d+):(%d%d)", pos)
    if not s then break end
    local t = tonumber(a) * 60 + tonumber(b)
    local ok = tonumber(b) < 60
    local c = str:match("^:(%d%d)", e + 1)                      -- h:mm:ss
    if c and not str:match("^:%d%d%d", e + 1) then
      ok = ok and tonumber(c) < 60
      t = tonumber(a) * 3600 + tonumber(b) * 60 + tonumber(c); e = e + 3
    end
    local frac = str:match("^%.(%d+)", e + 1)                   -- 1:23.5
    if frac and #frac <= 3 then t = t + tonumber("0." .. frac); e = e + 1 + #frac end
    local prev = s > 1 and str:sub(s - 1, s - 1) or ""
    if prev:match("[%d:%.]") or str:match("^[%d:]", e + 1) then ok = false end
    if str:match("^%s*[AaPp]%.?[Mm]%f[^%a]", e + 1) then ok = false end      -- "3:45 PM" is a clock, not a timecode
    if ok then out[#out + 1] = { s = s, e = e + 1, t = t } end
    pos = e + 1
  end
  return out
end

local RANGE_WORDS = { ["-"] = true, ["\226\128\147"] = true, ["\226\128\148"] = true, ["to"] = true,
                      ["till"] = true, ["until"] = true, ["\208\180\208\190"] = true, ["\208\191\208\190"] = true }
-- merge "1:20 - 1:35" into one entry with t2
local function joinRanges(str, tcs)
  local out, i = {}, 1
  while i <= #tcs do
    local a, b = tcs[i], tcs[i + 1]
    if b and RANGE_WORDS[trim(str:sub(a.e, b.s - 1)):lower()] and b.t > a.t then
      out[#out + 1] = { s = a.s, e = b.e, t = a.t, t2 = b.t }; i = i + 2
    else out[#out + 1] = a; i = i + 1 end
  end
  return out
end

-- chat exports: drop "Name, [27.11.2026 15:40]" lines, strip "[27.11.26, 15:40:12] Name: " prefixes
local function cleanChatLine(line)
  if line:match("^[^%[]-,%s*%[[^%]]*%d[^%]]*%]%s*$") then return nil end
  line = line:gsub("^%[[^%]]*%d[^%]]*%]%s*[^:]-:%s+", "")
  line = line:gsub("^%d%d?[%./]%d%d?[%./]%d%d%d?%d?,?%s+%d%d?:%d%d%s*[AaPp]?[Mm]?%s*%-%s*[^:]-:%s+", "")
  return line
end
local function stripBullet(line)
  local l = line:gsub("^[%-%*%+]+%s+", "")
  l = l:gsub("^\226\128\162%s*", ""):gsub("^\226\128[\147\148]%s*", ""):gsub("^\194\183%s*", "")
  l = l:gsub("^%d+[%.%)]%s+", "")
  l = l:gsub("^%[[ xX]?%]%s*", "")
  return l
end
local function isBullet(line)
  return line:match("^[%-%*%+]+%s+") or line:match("^\226\128\162") or line:match("^%d+[%.%)]%s+") or false
end

local function regionList()
  local t, i = {}, 0
  while true do
    local rv, isrgn, pos, _, name = reaper.EnumProjectMarkers(i)
    if not rv or rv == 0 then break end
    if isrgn and name ~= "" then t[#t + 1] = { name = name, pos = pos } end
    i = i + 1
  end
  return t
end
local function looseKey(s) return (s:lower():gsub("^%d+[%.%)%s%-_]+", ""):gsub("[%s%p]+", "")) end
local function regionFor(name, regions)
  local k = looseKey(name)
  if k == "" then return nil end
  for _, r in ipairs(regions) do if looseKey(r.name) == k then return r end end
end

local HEAD_WORDS = { "track ", "song ", "mix ", "\209\130\209\128\208\181\208\186 ", "\208\162\209\128\208\181\208\186 ",
                     "\208\191\208\181\209\129\208\189\209\143 ", "\208\159\208\181\209\129\208\189\209\143 " }
local function isHeader(line, nextLine, prevBlank, regions)
  if #findTimecodes(line) > 0 or isBullet(line) then return false end
  local l = trim(line)
  if #l == 0 or #l > 80 then return false end
  if regionFor(l, regions) then return true end
  local words = select(2, l:gsub("%S+", ""))
  local plain = not l:find("[%.!%?,;]%s") and not l:match("[%.!%?,;]$")
  if l:sub(-1) == ":" then return plain and words <= 6 end
  if plain and words <= 6 then
    local low = l:lower()
    for _, w in ipairs(HEAD_WORDS) do if low:sub(1, #w) == w:lower() or l:sub(1, #w) == w then return true end end
    if prevBlank and nextLine and nextLine ~= "" and (isBullet(nextLine) or #findTimecodes(nextLine) > 0) then
      return true
    end
  end
  return false
end

-- long lines without timecodes: one note per sentence
local function splitSentences(text)
  if #text < 90 then return { text } end
  local parts, buf = {}, ""
  local rest = text
  while true do
    local s, e = rest:find("[%.!%?]+%s+")
    if not s then break end
    buf = buf .. rest:sub(1, e)
    rest = rest:sub(e + 1)
    if #trim(buf) >= 18 and #trim(rest) >= 18 then parts[#parts + 1] = trim(buf); buf = "" end
  end
  buf = trim(buf .. rest)
  if buf ~= "" then parts[#parts + 1] = buf end
  return parts
end

local function trackNames()
  local t = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local _, nm = reaper.GetTrackName(reaper.GetTrack(0, i))
    local base = nm:gsub("_[sS][tT][mM]$", "")
    if #base >= 3 and not nm:match("^Track %d+$") then t[#t + 1] = { name = nm, key = base:lower() } end
  end
  table.sort(t, function(a, b) return #a.key > #b.key end)
  return t
end
local function isWordByte(c) return c ~= "" and (c:match("[%w_]") ~= nil or c:byte() >= 128) end
local function trackFor(text, tracks)
  local low = text:lower()
  for _, tr in ipairs(tracks) do
    local s, e = low:find(tr.key, 1, true)
    if s and not isWordByte(low:sub(s - 1, s - 1)) and not isWordByte(low:sub(e + 1, e + 1)) then return tr.name end
  end
end

local function cleanNoteText(t)
  t = trim(t)
  t = t:gsub("^[%-:,%.%)%]]+%s*", ""):gsub("^\226\128[\147\148]%s*", "")
  t = t:gsub("[,;]+$", "")
  return trim(t)
end

-- text -> list of { kind, text, t, t2, track, base }
local function parseNotes(text)
  local regions, tracks = regionList(), trackNames()
  local lines = {}
  for raw in (text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
    local l = cleanChatLine(trim(raw))
    if l then lines[#lines + 1] = trim(l) end
  end
  local out, prevBlank = {}, true
  local function add(txt, t, t2)
    txt = cleanNoteText(txt)
    if txt == "" and not t then return end
    out[#out + 1] = { kind = "i", text = txt, t = t, t2 = t2, track = trackFor(txt, tracks), done = false, color = 0 }
  end
  for i, line in ipairs(lines) do
    if line == "" then prevBlank = true
    elseif isHeader(line, lines[i + 1], prevBlank, regions) then
      local nm = trim((line:gsub(":$", "")))
      local r = regionFor(nm, regions)
      out[#out + 1] = { kind = "g", text = nm, base = r and r.pos or nil }
      prevBlank = false
    else
      local body = stripBullet(line)
      local tcs = joinRanges(body, findTimecodes(body))
      if #tcs == 0 then
        for _, part in ipairs(splitSentences(body)) do add(part) end
      elseif trim(body:sub(1, tcs[1].s - 1)):gsub("[%(%[@~]", "") == "" or #tcs == 1 then
        if #tcs == 1 then
          local tc = tcs[1]
          local txt = trim(body:sub(1, tc.s - 1)) == "" and body:sub(tc.e) or body
          add(txt, tc.t, tc.t2)
        else                                               -- "0:15 kick up, 1:20 vox down": cut at each timecode
          for k, tc in ipairs(tcs) do
            local stop = tcs[k + 1] and tcs[k + 1].s - 1 or #body
            add(body:sub(tc.e, stop), tc.t, tc.t2)
          end
        end
      else                                                 -- "vox louder at 1:20 and 2:35": same note for each time
        for _, tc in ipairs(tcs) do add(body, tc.t, tc.t2) end
      end
      prevBlank = false
    end
  end
  return out
end

------------------------------------------------------------------ storage (inside the project)
local function esc(s) return (s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t")) end
local function unesc(s)
  return (s:gsub("\\(.)", function(c) return c == "n" and "\n" or c == "t" and "\t" or c end))
end
local function serialize()
  local out = {}
  for _, it in ipairs(S.items) do
    if it.kind == "g" then
      out[#out + 1] = table.concat({ "g", it.base and tostring(it.base) or "", esc(it.text) }, "\t")
    else
      out[#out + 1] = table.concat({ "i", it.done and "1" or "0", tostring(it.color or 0),
        it.t and tostring(it.t) or "", it.t2 and tostring(it.t2) or "", esc(it.track or ""), esc(it.text) }, "\t")
    end
  end
  return table.concat(out, "\n")
end
local function deserialize(str)
  local items = {}
  for line in (str .. "\n"):gmatch("(.-)\n") do
    local f = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = field end
    if f[1] == "g" then
      items[#items + 1] = { kind = "g", base = tonumber(f[2]), text = unesc(f[3] or "") }
    elseif f[1] == "i" then
      local tr = unesc(f[6] or "")
      items[#items + 1] = { kind = "i", done = f[2] == "1", color = tonumber(f[3]) or 0, t = tonumber(f[4]),
                            t2 = tonumber(f[5]), track = tr ~= "" and tr or nil, text = unesc(f[7] or "") }
    end
  end
  return items
end
local function load()
  local _, str = reaper.GetProjExtState(0, NAME, "items")
  S.items = deserialize(str or "")
  S.edit, S.undo = nil, nil
end
local function save()
  reaper.SetProjExtState(0, NAME, "items", serialize())
  reaper.MarkProjectDirty(0)
end
local function snapshot() S.undo = serialize() end       -- call before any change that loses something

------------------------------------------------------------------ actions
local function groupOf(idx)
  for i = idx, 1, -1 do if S.items[i].kind == "g" then return S.items[i] end end
end
local function itemPos(idx)
  local it = S.items[idx]
  local g = groupOf(idx)
  return (g and g.base or 0) + (it.t or 0)
end
local function selectTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == name then
      reaper.SetOnlyTrackSelected(tr)
      reaper.Main_OnCommand(40913, 0)                    -- vertical scroll selected tracks into view
      return true
    end
  end
end
local function jump(idx)
  local it = S.items[idx]
  if it.t then
    local pos = itemPos(idx)
    reaper.SetEditCurPos(pos, true, true)
    if it.t2 then reaper.GetSet_LoopTimeRange(true, false, pos, pos + (it.t2 - it.t), false) end
  end
  if it.track then selectTrack(it.track) end
end
local function addParsed(text, at)
  local new = parseNotes(text)
  if #new == 0 then say("Nothing to add"); return end
  snapshot()
  local notes = 0
  for k, it in ipairs(new) do
    if it.kind == "i" then notes = notes + 1 end
    if at then table.insert(S.items, at + k - 1, it) else S.items[#S.items + 1] = it end
  end
  save()
  say(("Added %d note%s"):format(notes, notes == 1 and "" or "s"))
end
local function markerFor(idx)
  local it = S.items[idx]
  if not it.t then return end
  local col = it.color == 1 and reaper.ColorToNative(255, 69, 58) | 0x1000000
           or it.color == 2 and reaper.ColorToNative(255, 214, 10) | 0x1000000
           or it.color == 3 and reaper.ColorToNative(48, 209, 88) | 0x1000000 or 0
  local nm = it.text:gsub("%s+", " ")
  if #nm > 60 then nm = nm:sub(1, 57):gsub("[\128-\191]*$", "") .. "..." end
  local pos = itemPos(idx)
  if it.t2 then reaper.AddProjectMarker2(0, true, pos, pos + (it.t2 - it.t), nm, -1, col)
  else reaper.AddProjectMarker2(0, false, pos, 0, nm, -1, col) end
end
local function exportText()
  local out = {}
  for _, it in ipairs(S.items) do
    if it.kind == "g" then out[#out + 1] = (#out > 0 and "\n" or "") .. it.text .. ":"
    else
      local tc = it.t and (fmtTime(it.t) .. (it.t2 and ("-" .. fmtTime(it.t2)) or "") .. " ") or ""
      out[#out + 1] = (it.done and "[x] " or "[ ] ") .. tc .. it.text
    end
  end
  return table.concat(out, "\n")
end
local function visible(it)
  if it.kind == "g" then return true end
  if S.hideDone and it.done then return false end
  if S.show ~= 0 and (it.color or 0) ~= S.show then return false end
  return true
end

------------------------------------------------------------------ UI
local later = {}
local function queue(fn) later[#later + 1] = fn end

local function flagDot(idx, it)
  local sz = ImGui.GetTextLineHeight(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  if ImGui.InvisibleButton(ctx, "##flag" .. idx, sz, sz) then
    queue(function() it.color = ((it.color or 0) + 1) % 4; save() end)
  end
  local hov = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local col = FLAG[it.color or 0]
  if (it.color or 0) == 0 then ImGui.DrawList_AddCircle(dl, x + sz / 2, y + sz / 2, sz * 0.30, hov and C.text2 or col, 0, 1.4)
  else ImGui.DrawList_AddCircleFilled(dl, x + sz / 2, y + sz / 2, sz * (hov and 0.36 or 0.32), col) end
  if hov then ImGui.SetTooltip(ctx, "Click: red > yellow > green > none") end
end

local function itemMenu(idx, it)
  if ImGui.BeginPopupContextItem(ctx, "##ctx" .. idx) then
    if ImGui.MenuItem(ctx, "Edit...") then
      queue(function() S.edit, S.editBuf, S.editFocus = idx, it.text, true end)
    end
    ImGui.Separator(ctx)
    for c = 1, 3 do
      if ImGui.MenuItem(ctx, FLAG_NAME[c], nil, it.color == c) then queue(function() it.color = c; save() end) end
    end
    if ImGui.MenuItem(ctx, FLAG_NAME[0], nil, (it.color or 0) == 0) then queue(function() it.color = 0; save() end) end
    ImGui.Separator(ctx)
    if it.t and ImGui.MenuItem(ctx, it.t2 and "Create region here" or "Create marker here") then
      queue(function()
        reaper.Undo_BeginBlock(); markerFor(idx); reaper.Undo_EndBlock("Mix Notes: create marker", -1)
        reaper.UpdateArrange()
      end)
    end
    if it.t and ImGui.MenuItem(ctx, "Remove timecode") then
      queue(function() snapshot(); it.t, it.t2 = nil, nil; save() end)
    end
    if it.track and ImGui.MenuItem(ctx, "Unlink track \"" .. it.track .. "\"") then
      queue(function() it.track = nil; save() end)
    end
    if ImGui.MenuItem(ctx, "Make it a header") then
      queue(function() snapshot(); S.items[idx] = { kind = "g", text = it.text }; save() end)
    end
    if ImGui.MenuItem(ctx, "Delete") then queue(function() snapshot(); table.remove(S.items, idx); save() end) end
    ImGui.EndPopup(ctx)
  end
end

local function drawEdit(idx, it, w)
  ImGui.SetNextItemWidth(ctx, w)
  if S.editFocus then ImGui.SetKeyboardFocusHere(ctx); S.editFocus = false end
  local rv, buf = ImGui.InputText(ctx, "##edit", S.editBuf, ImGui.InputTextFlags_EnterReturnsTrue)
  S.editBuf = buf
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then S.edit = nil
  elseif rv or ImGui.IsItemDeactivatedAfterEdit(ctx) then
    local txt = trim(S.editBuf)
    queue(function()
      if txt ~= "" and txt ~= it.text then
        snapshot(); it.text = txt
        if it.kind == "i" and not it.t then                 -- a timecode typed into the text is picked up
          local tcs = joinRanges(txt, findTimecodes(txt))
          if tcs[1] then it.t, it.t2 = tcs[1].t, tcs[1].t2 end
        end
        save()
      end
      S.edit = nil
    end)
  elseif ImGui.IsItemDeactivated(ctx) then S.edit = nil end
end

local function drawNote(idx, it)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  ImGui.Dummy(ctx, 4, 0); ImGui.SameLine(ctx, 0, 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 2, 2)
  local rv, v = ImGui.Checkbox(ctx, "##done" .. idx, it.done)
  ImGui.PopStyleVar(ctx)
  if rv then queue(function() it.done = v; save() end) end
  ImGui.SameLine(ctx, 0, 6)
  flagDot(idx, it)
  if it.t then
    ImGui.SameLine(ctx, 0, 6)
    local label = fmtTime(it.t) .. (it.t2 and ("-" .. fmtTime(it.t2)) or "")
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, it.done and C.field or 0x0A84FF40)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x0A84FF80)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, it.done and C.text3 or C.text)
    if ImGui.SmallButton(ctx, label .. "##tc" .. idx) then queue(function() jump(idx) end) end
    ImGui.PopStyleColor(ctx, 3)
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, it.t2 and "Go there and set the time selection" or "Go to this time")
    end
  end
  ImGui.SameLine(ctx, 0, 8)
  local availW = ImGui.GetContentRegionAvail(ctx)
  if S.edit == idx then
    drawEdit(idx, it, math.max(60, availW - 4))
  else
    local chipW = 0
    if it.track then chipW = ImGui.CalcTextSize(ctx, it.track) + 22 end
    local tx = ImGui.GetCursorPosX(ctx)
    ImGui.PushTextWrapPos(ctx, tx + math.max(80, availW - chipW - 4))
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, it.done and C.text3 or C.text)
    ImGui.Text(ctx, it.text ~= "" and it.text or "(no text)")
    ImGui.PopStyleColor(ctx)
    ImGui.PopTextWrapPos(ctx)
    if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
      queue(function() S.edit, S.editBuf, S.editFocus = idx, it.text, true end)
    end
    itemMenu(idx, it)
    if it.track then
      local _, y1 = ImGui.GetCursorScreenPos(ctx)
      ImGui.SameLine(ctx, 0, 8)
      ImGui.PushFont(ctx, fontSmall)
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.field)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.fieldHi)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text2)
      if ImGui.SmallButton(ctx, it.track .. "##trk" .. idx) then
        local nm = it.track
        queue(function() if not selectTrack(nm) then say("No track named " .. nm) end end)
      end
      ImGui.PopStyleColor(ctx, 3)
      ImGui.PopFont(ctx)
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Select this track") end
      local _, y2 = ImGui.GetCursorScreenPos(ctx)
      if y1 > y2 then ImGui.Dummy(ctx, 0, y1 - y2 - 4) end   -- wrapped text is taller than the chip
    end
  end
  local _, yEnd = ImGui.GetCursorScreenPos(ctx)
  if (it.color or 0) ~= 0 then
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x0, y0 + 1, x0 + 3, yEnd - 5, FLAG[it.color], 1.5)
  end
end

local function drawHeader(idx, it, first)
  if not first then ImGui.Dummy(ctx, 0, 6) end
  local total, done = 0, 0
  for i = idx + 1, #S.items do
    local n = S.items[i]
    if n.kind == "g" then break end
    total = total + 1; if n.done then done = done + 1 end
  end
  if S.edit == idx then
    drawEdit(idx, it, math.max(80, (ImGui.GetContentRegionAvail(ctx)) - 4))
  else
    ImGui.PushFont(ctx, fontHead)
    ImGui.TextColored(ctx, (total > 0 and done == total) and C.text3 or C.text, it.text)
    ImGui.PopFont(ctx)
    if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
      queue(function() S.edit, S.editBuf, S.editFocus = idx, it.text, true end)
    end
    if ImGui.BeginPopupContextItem(ctx, "##hctx" .. idx) then
      if ImGui.MenuItem(ctx, "Rename...") then queue(function() S.edit, S.editBuf, S.editFocus = idx, it.text, true end) end
      ImGui.Separator(ctx)
      ImGui.TextDisabled(ctx, "Timecodes below count from:")
      if ImGui.MenuItem(ctx, "Project start", nil, it.base == nil) then queue(function() it.base = nil; save() end) end
      if ImGui.MenuItem(ctx, "Edit cursor (" .. fmtTime(reaper.GetCursorPosition()) .. ")") then
        local p = reaper.GetCursorPosition()
        queue(function() it.base = p; save() end)
      end
      if ImGui.BeginMenu(ctx, "Region") then
        local regs = regionList()
        if #regs == 0 then ImGui.TextDisabled(ctx, "No regions in the project") end
        for k, r in ipairs(regs) do
          if ImGui.MenuItem(ctx, r.name .. "##rg" .. k, nil, it.base == r.pos) then
            queue(function() it.base = r.pos; save() end)
          end
        end
        ImGui.EndMenu(ctx)
      end
      ImGui.Separator(ctx)
      if ImGui.MenuItem(ctx, "Make it a note") then
        queue(function() snapshot(); S.items[idx] = { kind = "i", text = it.text, done = false, color = 0 }; save() end)
      end
      if ImGui.MenuItem(ctx, "Delete header") then queue(function() snapshot(); table.remove(S.items, idx); save() end) end
      if ImGui.MenuItem(ctx, "Delete header and its notes") then
        queue(function()
          snapshot()
          table.remove(S.items, idx)
          while S.items[idx] and S.items[idx].kind ~= "g" do table.remove(S.items, idx) end
          save()
        end)
      end
      ImGui.EndPopup(ctx)
    end
    ImGui.SameLine(ctx, 0, 10)
    ImGui.PushFont(ctx, fontSmall)
    ImGui.TextColored(ctx, C.text3, ("%d/%d%s"):format(done, total, it.base and ("   from " .. fmtTime(it.base)) or ""))
    ImGui.PopFont(ctx)
  end
  ImGui.Dummy(ctx, 0, 1)
end

local function mainMenu(docked)
  if ImGui.MenuItem(ctx, "Undo last change", nil, false, S.undo ~= nil) then
    queue(function() local u = S.undo; S.undo = serialize(); S.items = deserialize(u); S.edit = nil; save() end)
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, "Copy all as text") then ImGui.SetClipboardText(ctx, exportText()); say("Copied") end
  if ImGui.MenuItem(ctx, "Create markers for all timecodes") then
    queue(function()
      reaper.Undo_BeginBlock()
      local n = 0
      for i, it in ipairs(S.items) do if it.kind == "i" and it.t and not it.done then markerFor(i); n = n + 1 end end
      reaper.Undo_EndBlock("Mix Notes: create markers", -1)
      reaper.UpdateArrange()
      say(n .. " marker(s) created")
    end)
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, "Untick all") then
    queue(function() snapshot(); for _, it in ipairs(S.items) do it.done = false end; save() end)
  end
  if ImGui.MenuItem(ctx, "Delete done notes") then
    queue(function()
      snapshot()
      for i = #S.items, 1, -1 do if S.items[i].kind == "i" and S.items[i].done then table.remove(S.items, i) end end
      save()
    end)
  end
  if ImGui.MenuItem(ctx, "Delete everything") then queue(function() snapshot(); S.items = {}; S.edit = nil; save() end) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, docked and "Undock" or "Dock in REAPER docker") then S.dockWanted = docked and 0 or -1 end
  if ImGui.MenuItem(ctx, "Donate...") then openURL(DONATE_URL) end
end

local SHOW_NAME = { [0] = "All colours", "Red", "Yellow", "Green" }
local function toolbar()
  local total, done = 0, 0
  for _, it in ipairs(S.items) do if it.kind == "i" then total = total + 1; if it.done then done = done + 1 end end end
  if ImGui.Button(ctx, S.pasteOpen and "Close" or "Paste notes...") then S.pasteOpen = not S.pasteOpen; S.pasteFocus = S.pasteOpen end
  ImGui.SameLine(ctx)
  local rv, v = ImGui.Checkbox(ctx, "Hide done", S.hideDone)
  if rv then S.hideDone = v end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 104)
  if ImGui.BeginCombo(ctx, "##show", SHOW_NAME[S.show]) then
    for c = 0, 3 do if ImGui.Selectable(ctx, SHOW_NAME[c], S.show == c) then S.show = c end end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx)
  ImGui.TextColored(ctx, (total > 0 and done == total) and C.green or C.text2, ("%d / %d"):format(done, total))
  ImGui.SameLine(ctx)
  local availW = ImGui.GetContentRegionAvail(ctx)
  if availW > 34 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + availW - 30) end
  if ImGui.Button(ctx, "...##menu", 30, 0) then ImGui.OpenPopup(ctx, "mainmenu") end
  if ImGui.BeginPopup(ctx, "mainmenu") then mainMenu(ImGui.IsWindowDocked(ctx)); ImGui.EndPopup(ctx) end
end

local function pastePanel()
  local availW = ImGui.GetContentRegionAvail(ctx)
  if S.pasteFocus then ImGui.SetKeyboardFocusHere(ctx); S.pasteFocus = false end
  local _, buf = ImGui.InputTextMultiline(ctx, "##paste", S.paste, availW, 150)
  S.paste = buf
  if ImGui.Button(ctx, "Split into notes") and trim(S.paste) ~= "" then
    local txt = S.paste
    queue(function() addParsed(txt); S.paste = ""; S.pasteOpen = false end)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Paste clipboard") then
    local clip = ImGui.GetClipboardText(ctx) or ""
    if trim(clip) ~= "" then S.paste = (S.paste ~= "" and (S.paste .. "\n") or "") .. clip else say("Clipboard is empty") end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Clear") then S.paste = "" end
  ImGui.Dummy(ctx, 0, 2)
end

local lastProj
local function frame()
  local proj = reaper.EnumProjects(-1)
  if proj ~= lastProj then lastProj = proj; load() end
  if S.dockWanted ~= nil then ImGui.SetNextWindowDockID(ctx, S.dockWanted); S.dockWanted = nil end
  ImGui.SetNextWindowSize(ctx, 460, 560, ImGui.Cond_FirstUseEver)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, C.bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, C.field)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, C.fieldHi)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.field)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.fieldHi)
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, C.accent)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 10, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 5)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 6, 5)
  ImGui.PushFont(ctx, font)
  local vis, open = ImGui.Begin(ctx, NAME, true, ImGui.WindowFlags_NoCollapse)
  if vis then
    toolbar()
    if S.pasteOpen then pastePanel() end
    ImGui.Separator(ctx)
    local _, availH = ImGui.GetContentRegionAvail(ctx)
    local footH = ImGui.GetFrameHeightWithSpacing(ctx) + 4
    if ImGui.BeginChild(ctx, "list", 0, math.max(40, availH - footH), 0, 0) then
      if #S.items == 0 then
        ImGui.Dummy(ctx, 0, 14)
        ImGui.PushTextWrapPos(ctx, 0)
        ImGui.TextColored(ctx, C.text2, "No notes yet.")
        ImGui.TextColored(ctx, C.text3, "Press \"Paste notes...\" and drop the client's message in, or type a note below. "
          .. "Timecodes like 1:23 or 1:20-1:35 turn into buttons that jump to that place.")
        ImGui.PopTextWrapPos(ctx)
      end
      local first = true
      for idx, it in ipairs(S.items) do
        if visible(it) then
          if it.kind == "g" then drawHeader(idx, it, first) else drawNote(idx, it) end
          first = false
        end
      end
      ImGui.EndChild(ctx)
    end
    -- quick add
    local availW = ImGui.GetContentRegionAvail(ctx)
    ImGui.SetNextItemWidth(ctx, math.max(60, availW))
    local rv, buf = ImGui.InputTextWithHint(ctx, "##quick", "Add a note, e.g. \"1:20 vocal up\"  -  Enter", S.quick,
      ImGui.InputTextFlags_EnterReturnsTrue)
    S.quick = buf
    if rv and trim(S.quick) ~= "" then
      local txt = S.quick
      queue(function() addParsed(txt); S.quick = ""; S.quickFocus = true end)
    end
    if S.quickFocus then ImGui.SetKeyboardFocusHere(ctx, -1); S.quickFocus = false end
    if S.status ~= "" and reaper.time_precise() - S.statusT < 2.5 then
      ImGui.SetTooltip(ctx, S.status)
    end
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 7)
  local ops = later; later = {}
  for _, fn in ipairs(ops) do fn() end
  if open then reaper.defer(frame) end
end

-- exposed for tests
LKSHV_MIX_NOTES = { parse = parseNotes, findTimecodes = findTimecodes, S = S, serialize = serialize, deserialize = deserialize }

reaper.defer(frame)
