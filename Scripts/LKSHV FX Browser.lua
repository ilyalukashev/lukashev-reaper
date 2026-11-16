-- @description LKSHV FX Browser — fast FX browser with plugin images (Lukashev Graphite style)
-- @version 1.6
-- @author Ilia Lukashev
-- @changelog
--   Merge brands: select several (Cmd/Shift-click), right-click > Merge brands...
--   Rename brands (right-click a brand > Rename brand...); names, hidden plugins and tags live in the Data folder
--     and survive rescans, script updates and reinstalls
--   Fixes: "(8 out)" / "(mono)" suffixes no longer become brands; list view could not scroll to its last rows;
--     grid rows left a blank strip while scrolling; Settings button pushed off the top bar; hidden formats and
--     favourites of a non-preferred format missing from Hidden / Favourites; empty undo points on failed inserts;
--     arrow keys moved the selection while typing; non-Latin names cut mid-character
--   Hide plugin formats per brand (right-click a brand > Formats)
--   Sort the plugin list by name, brand or type
--   Renamed LG -> LKSHV (settings, tags and images are carried over automatically)
--   Tags with track-name matching (follow selected track, Recent for unknown tracks)
--   _stm suffix opens Buss/Group tags
--   Dock-style magnify in the brand list
--   Donate button
-- @about
--   Requires ReaImGui (ReaPack: ReaTeam Extensions). REAPER 6.37+.
--   Enter: insert on selected tracks · Cmd+Enter: on selected items · Shift+Enter: input FX
--   Images live in <REAPER resource>/Data/LKSHV FX Browser/images (one PNG/JPG per plugin).

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("This script needs ReaImGui.\nInstall it via Extensions → ReaPack → Browse packages → ReaImGui.", "LKSHV FX Browser", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'

local SCRIPT = "LKSHV FX Browser"
local DONATE_URL = "https://lukashev.studio/donate"   -- where the footer heart button leads
local EXT = "LKSHV_FXBrowser"
local OLD_EXT = "LG_FXBrowser"                         -- pre-rename name: settings are read from it once
local IS_MAC = reaper.GetOS():match("OSX") or reaper.GetOS():match("mac")
local SEP = package.config:sub(1, 1)
local DATA_ROOT = reaper.GetResourcePath() .. SEP .. "Data" .. SEP
do  -- one-time move of the data folder (tags, lists, images) from the old "LG" name
  local old, new = DATA_ROOT .. "LG FX Browser", DATA_ROOT .. "LKSHV FX Browser"
  local function exists(p) local ok, _, code = os.rename(p, p); return ok or code == 13 end
  if exists(old) and not exists(new) then os.rename(old, new) end
end
local IMG_DIR = DATA_ROOT .. "LKSHV FX Browser" .. SEP .. "images"
reaper.RecursiveCreateDirectory(IMG_DIR, 0)

------------------------------------------------------------------ palette (same look as the Look Mom A Plugin app)
local C = {
  bg      = 0x111111FF, panel  = 0x181818FF, field  = 0x242424FF, card   = 0x1C1C1CFF,
  cardHi  = 0x242424FF, line   = 0x2A2A2AFF, text   = 0xF2F2F2FF, text2  = 0xB4B4B4FF,
  text3   = 0x8A8A8AFF, accent = 0x2F5DDBFF, accentA= 0x2F5DDB66, accentB= 0x2F5DDB30,
  star    = 0xFFD60AFF, ph     = 0x202020FF, topo   = 0xFFFFFF1E, edge   = 0xFFFFFF14,
}

------------------------------------------------------------------ settings
local function getS(k, d)
  local v = reaper.GetExtState(EXT, k)
  if v == "" then v = reaper.GetExtState(OLD_EXT, k) end
  if v == "" then return d end
  return v
end
local function setS(k, v) reaper.SetExtState(EXT, k, tostring(v), true) end

local S = {
  images    = getS("images", "1") == "1",
  thumb     = tonumber(getS("thumb", "180")) or 180,
  hideDupes = getS("hideDupes", "1") == "1",
  openUI    = getS("openUI", "1") == "1",
  closeAfter= getS("closeAfter", "0") == "1",
  prefer    = getS("prefer", "VST3"),
  brandSort = getS("brandSort", "name"),
  sort      = getS("sort", "name"),             -- plugin list order: name | brand | type
  sideW     = tonumber(getS("sideW", "196")) or 196,
  follow    = getS("follow", "1") == "1",
}
local function saveSettings()
  setS("images", S.images and 1 or 0); setS("thumb", S.thumb); setS("hideDupes", S.hideDupes and 1 or 0)
  setS("openUI", S.openUI and 1 or 0); setS("closeAfter", S.closeAfter and 1 or 0); setS("prefer", S.prefer)
  setS("brandSort", S.brandSort); setS("sideW", math.floor(S.sideW)); setS("follow", S.follow and 1 or 0)
  setS("sort", S.sort)
end

local DATA_DIR = DATA_ROOT .. "LKSHV FX Browser"
local function listPath(k) return DATA_DIR .. SEP .. k .. ".txt" end

-- lists live in plain text files, one entry per line (ExtState cannot persist multi-line values)
local function loadList(k)
  local t, set = {}, {}
  local f = io.open(listPath(k), "r")
  local src
  if f then src = f:read("*a"); f:close() else src = reaper.GetExtState(EXT, k) end   -- one-time migration
  for line in (src .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" and not set[line] then t[#t + 1] = line; set[line] = true end
  end
  return t, set
end
local function writeList(k, arr)
  local f = io.open(listPath(k), "w")
  if f then f:write(table.concat(arr, "\n")); f:close() end
end
local favList, favSet = loadList("favorites")
local recentList = loadList("recent")
local _, hidPlug = loadList("hiddenPlugins")     -- plugin keys (all formats of a plugin)
local _, hidDev = loadList("hiddenDevs")
local _, hidFmt = loadList("hiddenFormats")     -- "Brand|FMT": that format is not shown for that brand
local devAlias = {}                              -- original developer name -> the user's name for it
do
  local lines = loadList("brandNames")
  for _, l in ipairs(lines) do
    local o, n = l:match("^(.-)\t(.+)$")
    if o and o ~= "" then devAlias[o] = n end
  end
end
local function saveDevAlias()
  local t = {}
  for o, n in pairs(devAlias) do t[#t + 1] = o .. "\t" .. n end
  table.sort(t)
  writeList("brandNames", t)
end
local folders = {}          -- { {name=, set={}, n=} } in user order
-- default track-name keywords for folders named like common instrument groups
local KW_PRESETS = {
  { "drum",   "kick, kik, bd, snare, snr, sn, tom, oh, overhead, hh, hat, hihat, ride, crash, cymb, room, drum, drm, kit, perc, clap, shaker, tamb, cowbell" },
  { "perc",   "perc, shaker, tamb, conga, bongo, cowbell, clap, perc" },
  { "bass",   "bass, bs, sub, 808, dibass, bassdi" },
  { "voc",    "voc, vox, vocal, lead, ld, bv, bvs, bgv, backing, choir, adlib, harm, dbl, double, chorus" },
  { "gtr",    "gtr, guitar, gt, eg, egtr, agtr, ac, acoustic, riff, gut" },
  { "guitar", "gtr, guitar, gt, eg, egtr, agtr, ac, acoustic, riff, gut" },
  { "key",    "keys, key, piano, pno, rhodes, wurli, organ, hammond, clav, synth, pad, prophet, juno, moog" },
  { "synth",  "synth, pad, lead, arp, pluck, prophet, juno, moog, hammond" },
  { "string", "str, strings, violin, vln, viola, cello, vc, orch" },
  { "brass",  "brass, horn, trumpet, tpt, trombone, tbn, sax" },
  { "fx",     "fx, sfx, riser, impact, sweep, verb, reverb, delay, dly, echo" },
  { "bus",    "_stm, _stem, _bus, bus, buss, stem, stm, grp, group, sub, all" },
  { "group",  "_stm, _stem, _bus, _grp, grp, group, bus, buss, stem, stm, sub, all" },
  { "grp",    "_stm, _stem, _bus, _grp, grp, group, bus, buss, stem, stm, sub, all" },
  { "mix",    "mix, master, mst, bus, buss, stem, stm, all" },
  { "master", "master, mst, mix, print" },
}
local function parseKw(str)
  local t = {}
  for w in (str or ""):gmatch("[^,%s]+") do t[#t + 1] = w:lower() end
  return t
end
local function defaultKw(name)
  local n = name:lower()
  for _, pr in ipairs(KW_PRESETS) do if n:find(pr[1], 1, true) then return parseKw(pr[2]) end end
  return {}
end

local function loadFolders()

  folders = {}
  local f = io.open(listPath("folders"), "r")
  if not f then return end
  local cur
  for line in f:lines() do
    line = line:gsub("\r$", "")
    local hdr = line:match("^#%s*(.+)$")
    local kw = line:match("^@%s*(.*)$")
    if hdr then cur = { name = hdr, set = {}, n = 0 }; folders[#folders + 1] = cur
    elseif kw and cur then cur.kw = parseKw(kw)
    elseif cur and line ~= "" and not cur.set[line] then cur.set[line] = true; cur.n = cur.n + 1 end
  end
  f:close()
  for _, fo in ipairs(folders) do
    if not fo.kw then fo.kw = defaultKw(fo.name) end
    local n = fo.name:lower()                         -- bus/group tags always claim the _stm suffix
    if n:find("bus", 1, true) or n:find("group", 1, true) or n:find("grp", 1, true) then
      local has = false
      for _, k in ipairs(fo.kw) do if k == "_stm" then has = true end end
      if not has then table.insert(fo.kw, 1, "_stm") end
    end
  end
end
local function saveFolders()
  local out = {}
  for _, fo in ipairs(folders) do
    out[#out + 1] = "# " .. fo.name
    out[#out + 1] = "@ " .. table.concat(fo.kw or {}, ", ")
    local t = {}
    for nm in pairs(fo.set) do t[#t + 1] = nm end
    table.sort(t)
    for _, nm in ipairs(t) do out[#out + 1] = nm end
  end
  writeList("folders", out)
end
local function findFolder(name) for i, fo in ipairs(folders) do if fo.name == name then return fo, i end end end
loadFolders()

-- smart context: pick the folder whose keywords match the selected track (or its parent folder tracks)
local function nameTokens(name)
  local t = {}
  local n = name:lower():gsub("(%a)(%d)", "%1 %2"):gsub("(%d)(%a)", "%1 %2")
  for w in n:gmatch("[%w]+") do t[#t + 1] = w end
  return t
end
local function matchFolderForName(name)
  local best, bestScore = nil, 0
  local toks = nameTokens(name)
  local lname = name:lower()
  for _, fo in ipairs(folders) do                    -- suffix words ("_stm") win over everything else
    for _, kw in ipairs(fo.kw or {}) do
      if kw:sub(1, 1) == "_" and #kw > 1 then
        local pat = kw:gsub("%p", "%%%0") .. "%f[^%a]"
        if lname:find(pat) and 100 + #kw > bestScore then best, bestScore = fo, 100 + #kw end
      end
    end
  end
  if best then return best end
  for _, fo in ipairs(folders) do
    local words = { table.unpack(fo.kw or {}) }
    for _, w in ipairs(nameTokens(fo.name)) do words[#words + 1] = w end   -- the tag name itself always counts
    for _, kw in ipairs(words) do
      if kw:sub(1, 1) ~= "_" then for _, tk in ipairs(toks) do
        local hit = (tk == kw) or (#kw >= 3 and tk:sub(1, #kw) == kw)
        if hit then
          local sc = #kw + (tk == kw and 1 or 0)
          if sc > bestScore then best, bestScore = fo, sc end
        end
      end end
    end
  end
  return best
end
local function matchFolderForTrack(tr)
  local depth = 0
  while tr and depth < 8 do
    local _, nm = reaper.GetTrackName(tr)
    local fo = matchFolderForName(nm or "")
    if fo then return fo, nm end
    tr = reaper.GetParentTrack(tr)
    depth = depth + 1
  end
end
local ctxTrackKey, ctxTrackName, ctxFolder, autoPicked = nil, nil, nil, false
local ctxCheckT = -1e9
local function tagsOf(name)
  local t = {}
  for _, fo in ipairs(folders) do if fo.set[name] then t[#t + 1] = fo.name end end
  return t
end

local function saveSet(k, set)
  local t = {}
  for v in pairs(set) do t[#t + 1] = v end
  table.sort(t)
  writeList(k, t)
end
local function saveFav()
  favList = {}
  for k in pairs(favSet) do favList[#favList + 1] = k end
  table.sort(favList)
  writeList("favorites", favList)
end
local function pushRecent(name)
  for i = #recentList, 1, -1 do if recentList[i] == name then table.remove(recentList, i) end end
  table.insert(recentList, 1, name)
  while #recentList > 40 do table.remove(recentList) end
  writeList("recent", recentList)
end

------------------------------------------------------------------ plugin list
local FORMAT_RANK = { VST3 = 1, AU = 2, CLAP = 3, VST = 4, LV2 = 5, JS = 6, DX = 7 }

local function splitDev(rest)
  if rest:sub(-1) ~= ")" then return rest, "" end
  local depth = 0
  for i = #rest, 1, -1 do
    local ch = rest:sub(i, i)
    if ch == ")" then depth = depth + 1
    elseif ch == "(" then
      depth = depth - 1
      if depth == 0 then
        return (rest:sub(1, i - 1):gsub("%s+$", "")), rest:sub(i + 1, -2)
      end
    end
  end
  return rest, ""
end

-- REAPER appends channel variants after the developer: "Kontakt 7 (Native Instruments) (16 out)", "... (mono)"
local function isVariant(g)
  g = g:lower()
  return g:match("^%d+ out$") or g:match("^%d+ch$") or g:match("^%d+%->%d+ch$") or g == "mono" or g == "stereo"
      or g == "x64" or g == "x86" or g:match("^%d+ in$") or g:match("^%d+ in %d+ out$")
end
-- returns: plugin name, developer, variant ("" when none)
local function splitName(rest)
  local variant = ""
  while true do
    local base, group = splitDev(rest)
    if group ~= "" and isVariant(group) then
      variant = variant == "" and group or (group .. ", " .. variant)
      rest = base
    else
      return base, group, variant
    end
  end
end

local function sanitize(s) return (s:gsub('[/\\:%*%?"<>|]', "_"):gsub("%s+", " ")) end

local all, byName = {}, {}
local devCounts, devList = {}, {}
local devFormats = {}                -- brand -> { FMT = number of plugins }
local devOrigs = {}                  -- brand as shown -> { original developer names }
local formatsPresent = {}

local function scan()
  all, byName, devCounts, devList, formatsPresent, devFormats, devOrigs = {}, {}, {}, {}, {}, {}, {}
  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    i = i + 1
    local typ, rest = name:match("^([%w]+):%s*(.+)$")
    if not typ then typ, rest = "FX", name end
    local inst = typ:sub(-1) == "i" and typ ~= "JS"
    local fmt = inst and typ:sub(1, -2) or typ
    local base0, dev, variant = splitName(rest)
    local base = variant ~= "" and (base0 .. " (" .. variant .. ")") or base0
    if fmt == "JS" and dev == "" then dev = "JSFX" end
    local odev = dev                                      -- the name REAPER reports: keys and image names stay on it
    dev = devAlias[odev] or odev
    if dev ~= "" then devOrigs[dev] = devOrigs[dev] or {}; devOrigs[dev][odev] = true end
    local p = {
      name = name, ident = ident, fmt = fmt, inst = inst, base = base, dev = dev,
      lbase = base:lower(), ldev = dev:lower(),
      key = base:lower() .. "|" .. odev:lower(),
      img = sanitize((odev ~= "" and (odev .. " - ") or "") .. base0),   -- variants share one image
    }
    p.search = (p.lbase .. " " .. p.ldev .. " " .. odev:lower() .. " " .. fmt:lower() .. (inst and " instrument" or ""))
    all[#all + 1] = p
    byName[name] = p
    formatsPresent[fmt] = true
    p.fmtHidden = hidFmt[dev .. "|" .. fmt] == true
    if dev ~= "" then
      devFormats[dev] = devFormats[dev] or {}
      devFormats[dev][fmt] = (devFormats[dev][fmt] or 0) + 1
    end
  end
  table.sort(all, function(a, b)
    if a.lbase ~= b.lbase then return a.lbase < b.lbase end
    if a.ldev ~= b.ldev then return a.ldev < b.ldev end
    local ra, rb = FORMAT_RANK[a.fmt] or 9, FORMAT_RANK[b.fmt] or 9
    if ra ~= rb then return ra < rb end
    return a.name < b.name
  end)
  -- preferred-format winner for each plugin (for de-duplication)
  local best = {}
  for _, p in ipairs(all) do
    local cur = best[p.key]
    local rank = (p.fmt == S.prefer) and 0 or (FORMAT_RANK[p.fmt] or 9)
    if p.fmtHidden then rank = rank + 100 end             -- a hidden format only wins when every format is hidden
    if not cur or rank < cur.rank then best[p.key] = { p = p, rank = rank } end
  end
  for _, p in ipairs(all) do p.primary = (best[p.key].p == p) end
  for _, p in ipairs(all) do
    if p.primary and not p.fmtHidden and p.dev ~= "" then devCounts[p.dev] = (devCounts[p.dev] or 0) + 1 end
  end
  for d in pairs(devCounts) do devList[#devList + 1] = d end
  table.sort(devList, function(a, b) return a:lower() < b:lower() end)
end

------------------------------------------------------------------ images
local imgFiles = {}       -- img key -> path
local imgNorm, imgNormBase, imgOrphans = {}, {}, {}
local imgBad = {}       -- path -> true for broken captures (thin strips, tiny, unreadable)
local function pngSize(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local h = f:read(24); f:close()
  if not h or #h < 24 or h:sub(2, 4) ~= "PNG" then return nil end
  local function u32(i) local a, b, c, d = h:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
  return u32(17), u32(21)
end
local function isBadCapture(path)
  if not path:lower():match("%.png$") then return false end
  local w, h = pngSize(path)
  if not w then return true end
  return h < 80 or w < 80 or w / h > 6 or h / w > 6
end
-- loose key: lower-case letters and digits only (ignores spaces, punctuation, unicode accents form, "(x64)")
local function norm(s) return (s:lower():gsub("%(x64%)", ""):gsub("[^%w]", "")) end
local function addImageFile(f)
  local stem, ext = f:match("^(.+)%.(%w+)$")
  if stem and stem:sub(1, 1) ~= "." then
    ext = ext:lower()
    if ext == "png" or ext == "jpg" or ext == "jpeg" then
      local path = IMG_DIR .. SEP .. f
      if isBadCapture(path) then imgBad[path] = true; return end
      imgFiles[stem] = path
      imgNorm[norm(stem)] = path
      local base = stem:match("^.- %- (.+)$")              -- "Developer - Plugin" -> "Plugin"
      if base then imgNormBase[norm(base)] = imgNormBase[norm(base)] or path end
      imgNormBase[norm(stem)] = imgNormBase[norm(stem)] or path   -- files named after the plugin only
    end
  end
end
local function imagePath(p)
  return imgFiles[p.img] or imgNorm[norm(p.img)] or imgNormBase[norm(p.base)]
end
local function scanImages()
  imgFiles, imgNorm, imgNormBase, imgBad = {}, {}, {}, {}
  -- read the folder straight from disk: REAPER's EnumerateFiles may serve a cached listing
  local pipe
  if not reaper.GetOS():match("Win") and io.popen then
    local ok, h = pcall(io.popen, "ls -1 '" .. IMG_DIR:gsub("'", "'\\''") .. "' 2>/dev/null")
    if ok then pipe = h end
  end
  if pipe then
    for f in pipe:lines() do addImageFile(f) end
    pipe:close()
  else
    reaper.EnumerateFiles(IMG_DIR, -1)
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(IMG_DIR, i)
      if not f then break end
      addImageFile(f); i = i + 1
    end
  end
  imgOrphans = {}
  local used = {}
  for _, q in ipairs(all) do local pth = imagePath(q); if pth then used[pth] = true end end
  for stem, pth in pairs(imgFiles) do if not used[pth] then imgOrphans[#imgOrphans + 1] = stem end end
  table.sort(imgOrphans)
end

local ctx = ImGui.CreateContext(SCRIPT)
local imgCache, imgUsed, imgCount = {}, {}, 0   -- key -> image / last frame used
local frame, loadsThisFrame = 0, 0
local MAX_IMG, LOADS_PER_FRAME = 160, 4
local imgStat = { loaded = 0, failed = 0, err = "" }

local graveyard = {}   -- images waiting to be released a few frames later
local function dropImage(key)
  local img = imgCache[key]
  if img and img ~= false then
    graveyard[#graveyard + 1] = { img = img, at = frame + 3 }
    imgCount = imgCount - 1
  end
  imgCache[key], imgUsed[key] = nil, nil
end
local function releaseGraveyard()
  for i = #graveyard, 1, -1 do
    local g = graveyard[i]
    if frame >= g.at then
      if ImGui.ValidatePtr(g.img, "ImGui_Image*") then ImGui.Detach(ctx, g.img) end
      table.remove(graveyard, i)
    end
  end
end

local function getImage(p)
  local key = p.img
  local path = imagePath(p)
  if not path then return nil end
  local img = imgCache[key]
  if img == false then
    if frame - (imgUsed[key] or 0) < 120 then return nil end   -- failed recently: retry in ~4 s
    imgCache[key] = nil
  elseif img then
    imgUsed[key] = frame; return img
  end
  if loadsThisFrame >= LOADS_PER_FRAME then return nil end   -- spread loading over frames: UI never stalls
  loadsThisFrame = loadsThisFrame + 1
  local ok, im = pcall(ImGui.CreateImage, path)
  if not ok or not im then
    imgCache[key] = false; imgUsed[key] = frame
    imgStat.failed = imgStat.failed + 1
    if imgStat.err == "" then
      imgStat.err = tostring(im)
      reaper.ShowConsoleMsg("LKSHV FX Browser: cannot load image\n" .. path .. "\n" .. tostring(im) .. "\n")
    end
    return nil
  end
  imgStat.loaded = imgStat.loaded + 1
  ImGui.Attach(ctx, im)
  imgCache[key], imgUsed[key] = im, frame
  imgCount = imgCount + 1
  if imgCount > MAX_IMG then                                  -- evict least recently used
    local oldK, oldF = nil, math.huge
    for k, f in pairs(imgUsed) do if f < oldF and k ~= key then oldK, oldF = k, f end end
    if oldK and oldF < frame - 1 then dropImage(oldK) end
  end
  return im
end

local function shellQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local status, statusT = "", 0
local pending          -- insert requested while drawing; executed after the frame ends
local drag             -- plugin being dragged out of the browser
local hoverSelf = false
local later = {}                     -- actions to run after the frame
local function queue(fn) later[#later + 1] = fn end
local dropFolder                     -- folder under the mouse while dragging
local devSel, devAnchor = {}, nil   -- selected developers (Cmd / Shift click in the sidebar)
local msel, nsel = {}, 0            -- multi-selection by plugin name
local function say(msg) status, statusT = msg, reaper.time_precise() end

local function captureImage(p)
  if not IS_MAC then say('Capture works on macOS; use "Load image..." instead'); return end
  local dst = IMG_DIR .. SEP .. p.img .. ".png"
  local tmp = "/tmp/lkshv_fxbrowser_manual.png"
  os.remove(tmp)
  say("Click the plugin window to capture (Esc to cancel)")
  os.execute("screencapture -iWo -x " .. shellQuote(tmp))
  local f = io.open(tmp, "rb")
  if not f then say("Capture cancelled"); return end
  f:close()
  os.execute("sips -Z 640 " .. shellQuote(tmp) .. " >/dev/null 2>&1")
  os.remove(dst)
  os.execute("mv -f " .. shellQuote(tmp) .. " " .. shellQuote(dst))
  dropImage(p.img); scanImages(); say("Image saved for " .. p.base)
end

local function loadImageFile(p)
  local ok, file = reaper.GetUserFileNameForRead("", "Image for " .. p.base, "png")
  if not ok or file == "" then return end
  local ext = (file:match("%.(%w+)$") or "png"):lower()
  local inF = io.open(file, "rb"); if not inF then return end
  local data = inF:read("*a"); inF:close()
  for _, e in ipairs({ "png", "jpg", "jpeg" }) do os.remove(IMG_DIR .. SEP .. p.img .. "." .. e) end
  local outF = io.open(IMG_DIR .. SEP .. p.img .. "." .. ext, "wb")
  if not outF then say("Cannot write to the images folder"); return end
  outF:write(data); outF:close()
  dropImage(p.img); scanImages(); say("Image set for " .. p.base)
end

local function removeImage(p)
  local pth = imagePath(p)
  if pth then os.remove(pth) end
  for _, e in ipairs({ "png", "jpg", "jpeg" }) do os.remove(IMG_DIR .. SEP .. p.img .. "." .. e) end
  dropImage(p.img); scanImages()
end

local batch                                         -- auto-capture state machine
local _, skipCap = loadList("skipCapture")       -- plugins that took REAPER down during a capture
local LOG = DATA_DIR .. SEP .. "capture.log"
local function logln(msg)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S  ") .. msg .. "\n"); f:close() end
end
local function sh(cmd)                                  -- run a shell command, log it and its exit status
  local ok, why, code = os.execute(cmd)
  logln(("  $ %s  -> %s %s"):format(cmd, tostring(why), tostring(code)))
  return ok
end
local function fileSize(path)
  local f = io.open(path, "rb"); if not f then return 0 end
  local n = f:seek("end"); f:close(); return n or 0
end

-- macOS helper: find the CGWindowID of a REAPER window by (part of) its title
local WINID_JS = DATA_DIR .. SEP .. "winid.js"
local function ensureWinIdHelper()
  local f = io.open(WINID_JS, "r")
  if f then f:close(); return end
  f = io.open(WINID_JS, "w"); if not f then return end
  f:write([[
ObjC.import('CoreGraphics');
function run(argv) {
  var want = argv[0];
  var info = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
  var best = 0, bestArea = 0;
  for (var i = 0; i < info.length; i++) {
    var w = info[i];
    var name = w.kCGWindowName || '';
    if (name.indexOf(want) >= 0) {
      var a = w.kCGWindowBounds.Width * w.kCGWindowBounds.Height;
      if (a > bestArea) { best = w.kCGWindowNumber; bestArea = a; }
    }
  }
  return String(best);
}
]])
  f:close()
end
local function windowIdByTitle(title)
  if not io.popen then return nil end
  ensureWinIdHelper()
  local ok, pipe = pcall(io.popen, "osascript -l JavaScript " .. shellQuote(WINID_JS) .. " " .. shellQuote(title) .. " 2>&1")
  if not ok or not pipe then return nil end
  local out = pipe:read("*a") or ""; pipe:close()
  logln("  window id lookup '" .. title .. "' -> " .. out:gsub("%s+$", ""))
  local id = tonumber(out:match("^%s*(%d+)%s*$"))
  if id and id > 0 then return id end
end

local function finishCapture(tmp, dst)
  for _ = 1, 4 do                                         -- screencapture can hand the file over a moment later
    if fileSize(tmp) > 0 then break end
    os.execute("sleep 0.25")
  end
  if fileSize(tmp) == 0 then
    sh("ls -la " .. shellQuote(tmp) .. " >> " .. shellQuote(LOG) .. " 2>&1")
    logln("  no file written"); return false
  end
  sh("sips -Z 640 " .. shellQuote(tmp) .. " >/dev/null 2>&1")
  sh("mv -f " .. shellQuote(tmp) .. " " .. shellQuote(dst))
  logln(("  saved %s (%d bytes)"):format(dst, fileSize(dst)))
  return fileSize(dst) > 0
end

-- capture a plugin window: by window id first (exact, works for GPU UIs), screen rect as fallback
local function captureWindow(hwnd, dst)
  -- plain, non-hidden temp file in /tmp (a dot-file inside Library is silently not written by screencapture)
  local tmp = "/tmp/lkshv_fxbrowser_capture.png"
  os.remove(tmp)
  local title = reaper.JS_Window_GetTitle and reaper.JS_Window_GetTitle(hwnd) or ""
  logln("capture -> " .. dst .. "   window title: " .. title)
  if title ~= "" then
    local id = windowIdByTitle(title)
    if id then
      sh(("screencapture -x -o -l%d %s 2>> %s"):format(id, shellQuote(tmp), shellQuote(LOG)))
      if finishCapture(tmp, dst) then return true end
    end
  end
  -- fallback: screen rectangle (JS coords on macOS are bottom-left based)
  local ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
  if not ok then logln("  no client rect"); return false end
  local x, y, w, h = l, t, r - l, b - t
  if t > b then
    local _, mt, _, mb = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, false)
    x, y, w, h = l, math.abs(mb - mt) - t, r - l, t - b
  end
  logln(("  rect %d,%d %dx%d"):format(x, y, w, h))
  if w < 20 or h < 20 then return false end
  os.remove(tmp)
  sh(("screencapture -x -o -R%d,%d,%d,%d %s 2>> %s"):format(math.floor(x), math.floor(y), math.floor(w), math.floor(h), shellQuote(tmp), shellQuote(LOG)))
  return finishCapture(tmp, dst)
end

local function startBatch(list, force)
  if not IS_MAC then say("Auto-capture works on macOS"); return end
  if not reaper.JS_Window_GetClientRect then
    reaper.MB("Auto-capture needs the js_ReaScriptAPI extension.\nInstall it via Extensions > ReaPack > Browse packages > js_ReaScriptAPI, then restart REAPER.", SCRIPT, 0)
    return
  end
  local todo, skipped = {}, 0
  for _, p in ipairs(list) do
    if skipCap[p.key] then skipped = skipped + 1
    elseif force or not imagePath(p) then todo[#todo + 1] = p end
  end
  if skipped > 0 then say(("%d plugin(s) skipped: they crashed REAPER before"):format(skipped)) end
  if #todo == 0 then say("All listed plugins already have images"); return end
  if reaper.MB(("Capture %d plugin windows?\nEach plugin opens on a temporary track for about a second. Keep the screen awake.\n(First run: allow REAPER in System Settings > Privacy > Screen Recording.)"):format(#todo), SCRIPT, 1) ~= 1 then return end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
  local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "LKSHV FX Browser capture", true)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
  batch = { list = todo, i = 0, tr = tr, state = "next", ok = 0, noWin = 0, small = 0 }
  logln(("==== batch start: %d plugins, js=%s"):format(#todo, tostring(reaper.JS_Window_GetTitle ~= nil)))
end

local function stopBatch()
  if not batch then return end
  setS("batchCurrent", "")
  if reaper.ValidatePtr(batch.tr, "MediaTrack*") then
    for i = reaper.TrackFX_GetCount(batch.tr) - 1, 0, -1 do reaper.TrackFX_Delete(batch.tr, i) end
    reaper.DeleteTrack(batch.tr)
  end
  say(("Captured %d of %d   (no window: %d, window too small: %d)  - details: capture.log"):format(batch.ok, #batch.list, batch.noWin, batch.small))
  logln(("==== batch end: captured %d of %d"):format(batch.ok, #batch.list))
  batch = nil
  scanImages()
end

local function stepBatch()
  local b = batch
  if not b then return end
  if not reaper.ValidatePtr(b.tr, "MediaTrack*") then batch = nil; setS("batchCurrent", ""); return end
  local now = reaper.time_precise()
  if b.waitUntil and now < b.waitUntil then return end
  b.waitUntil = nil
  if b.state == "next" then
    b.i = b.i + 1
    if b.i > #b.list then setS("batchCurrent", ""); stopBatch(); return end
    b.p = b.list[b.i]
    setS("batchCurrent", b.p.key)                     -- journal: if REAPER dies now, we know who did it
    b.idx = reaper.TrackFX_AddByName(b.tr, b.p.name, false, -1)
    if b.idx < 0 then return end                      -- failed to load: skip
    b.state = "open"; b.waitUntil = now + 0.4         -- let the plugin initialise before opening its UI
  elseif b.state == "open" then
    reaper.TrackFX_Show(b.tr, b.idx, 3)
    b.t0 = now; b.state = "wait"; b.lastRect = nil; b.stableSince = now
  elseif b.state == "wait" then
    local hwnd = reaper.TrackFX_GetFloatingWindow(b.tr, b.idx)
    local ok, l, t, r, bt
    if hwnd then ok, l, t, r, bt = reaper.JS_Window_GetClientRect(hwnd) end
    local w, h = 0, 0
    if ok then w, h = math.abs(r - l), math.abs(bt - t) end
    local key = ("%d,%d,%d,%d"):format(l or 0, t or 0, r or 0, bt or 0)
    if key ~= b.lastRect then b.lastRect = key; b.stableSince = now end
    -- capture once the plugin UI has grown to a real size and stopped resizing
    if ok and w >= 120 and h >= 100 and now - b.t0 > 1.0 and now - b.stableSince >= 0.6 then
      local dst = IMG_DIR .. SEP .. b.p.img .. ".png"
      if captureWindow(hwnd, dst) then
        local size = 0
        local f = io.open(dst, "rb"); if f then size = f:seek("end"); f:close() end
        if size > 0 and not isBadCapture(dst) then
          b.ok = b.ok + 1
          dropImage(b.p.img)
          imgFiles[b.p.img] = dst                      -- visible right away, no folder rescan needed
        else
          logln("  rejected as broken (" .. table.concat({ pngSize(dst) }, "x") .. ")")
          os.remove(dst); b.small = b.small + 1
        end
      end
      b.state = "hide"
    elseif now - b.t0 > 15 then
      logln(("%s: gave up, window=%s size=%dx%d"):format(b.p.name, tostring(hwnd ~= nil), w, h))
      if hwnd then b.small = b.small + 1 else b.noWin = b.noWin + 1 end
      b.state = "hide"                                -- gave up on this one
    end
  elseif b.state == "hide" then
    reaper.TrackFX_Show(b.tr, b.idx, 2)               -- close the UI first...
    b.state = "delete"; b.waitUntil = now + 0.7       -- ...and give it time to tear down
  elseif b.state == "delete" then
    if b.idx < reaper.TrackFX_GetCount(b.tr) then reaper.TrackFX_Delete(b.tr, b.idx) end
    setS("batchCurrent", "")
    b.state = "next"; b.waitUntil = now + 0.3
    if b.i % 10 == 0 then scanImages() end
  end
end

local function openURL(url)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url)
  elseif IS_MAC then os.execute("open " .. shellQuote(url))
  else os.execute('start "" "' .. url .. '"') end
end

local function openFolder(dir)
  if IS_MAC then os.execute("open " .. shellQuote(dir))
  else os.execute('start "" "' .. dir .. '"') end
end

------------------------------------------------------------------ insert
local function insertTo(p, track, take)
  local idx
  if take then
    idx = reaper.TakeFX_AddByName(take, p.name, -1)
    if idx >= 0 and S.openUI then reaper.TakeFX_Show(take, idx, 3) end
  else
    idx = reaper.TrackFX_AddByName(track, p.name, false, -1)
    if idx >= 0 and S.openUI then reaper.TrackFX_Show(track, idx, 3) end
  end
  if idx and idx >= 0 then
    reaper.Undo_OnStateChangeEx("Insert " .. p.base, -1, -1)
    pushRecent(p.name)
    local _, tn = reaper.GetTrackName(track or reaper.GetMediaItemTake_Track(take))
    say(p.base .. " -> " .. (take and "item on " or "") .. tn)
    return true
  end
  return false
end

local function insert(p, mode)
  if not p then return end
  reaper.PreventUIRefresh(1)
  local n = 0
  if mode == "items" then
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
      local take = reaper.GetActiveTake(reaper.GetSelectedMediaItem(0, i))
      if take then
        local idx = reaper.TakeFX_AddByName(take, p.name, -1)
        if idx >= 0 then n = n + 1; if S.openUI and n == 1 then reaper.TakeFX_Show(take, idx, 3) end end
      end
    end
  else
    local tracks = {}
    for i = 0, reaper.CountSelectedTracks2(0, true) - 1 do tracks[#tracks + 1] = reaper.GetSelectedTrack2(0, i, true) end
    if #tracks == 0 then local t = reaper.GetLastTouchedTrack(); if t then tracks[1] = t end end
    for _, tr in ipairs(tracks) do
      local idx = reaper.TrackFX_AddByName(tr, p.name, mode == "input", -1)
      if idx >= 0 then
        n = n + 1
        if S.openUI and n == 1 then reaper.TrackFX_Show(tr, mode == "input" and (0x1000000 + idx) or idx, 3) end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  if n > 0 then reaper.Undo_OnStateChangeEx("Insert " .. p.base, -1, -1) end   -- no undo point when nothing was added
  if n == 0 then
    say(mode == "items" and "Select items first" or "Select a track first")
    return false
  end
  pushRecent(p.name)
  say(("%s -> %d %s"):format(p.base, n, mode == "items" and "item(s)" or (mode == "input" and "input FX" or "track(s)")))
  return true
end

------------------------------------------------------------------ filtering
local query, category = "", "all"     -- category: all/fav/recent/inst/fx/fmt:X/dev:X
local results, sel = {}, 1
local dirty = true

local function rebuild()
  dirty = false
  results = {}
  local tokens = {}
  for t in query:lower():gmatch("%S+") do tokens[#tokens + 1] = t end
  local source = all
  if category == "recent" then
    source = {}
    for _, n in ipairs(recentList) do if byName[n] then source[#source + 1] = byName[n] end end
  end
  for _, p in ipairs(source) do
    local ok = true
    local hidden = hidPlug[p.key] or hidDev[p.dev]
    local fmtOff = p.fmtHidden and not category:match("^folder:")     -- tagged entries stay visible in their tag
    if category == "hidden" then ok = (hidden and p.primary) or p.fmtHidden
    elseif hidden or fmtOff then ok = false end
    -- one entry per plugin - except where the entry itself was picked by the user (favourites, tags, recent, a format)
    if S.hideDupes and not p.primary and category ~= "recent" and category ~= "fav" and category ~= "hidden"
       and not category:match("^fmt:") and not category:match("^folder:") then ok = false end
    if ok and category ~= "hidden" then
      if category == "fav" then ok = favSet[p.name] == true
      elseif category == "inst" then ok = p.inst
      elseif category == "fx" then ok = not p.inst
      elseif category:match("^fmt:") then ok = p.fmt == category:sub(5)
      elseif category:match("^dev:") then ok = p.dev == category:sub(5)
      elseif category == "devs" then ok = devSel[p.dev] == true
      elseif category:match("^folder:") then
        local fo = findFolder(category:sub(8))
        ok = fo ~= nil and fo.set[p.name] == true
      end
    end
    if ok then
      for _, t in ipairs(tokens) do if not p.search:find(t, 1, true) then ok = false; break end end
    end
    if ok then results[#results + 1] = p end
  end
  if category ~= "recent" and S.sort ~= "name" then            -- "name" is the scan order already
    for i, p in ipairs(results) do p._i = i end
    if S.sort == "brand" then
      table.sort(results, function(a, b) if a.ldev ~= b.ldev then return a.ldev < b.ldev end return a._i < b._i end)
    else                                                       -- type: instruments last, then format, then name
      local function tr(p) return (p.inst and 100 or 0) + (FORMAT_RANK[p.fmt] or 9) end
      table.sort(results, function(a, b)
        local ta, tb = tr(a), tr(b)
        if ta ~= tb then return ta < tb end
        return a._i < b._i
      end)
    end
  end
  if #tokens > 0 and category ~= "recent" then   -- name-prefix matches and favourites float up
    local t1 = tokens[1]
    local function score(p)
      local s = 0
      if p.lbase:sub(1, #t1) == t1 then s = s - 4 elseif p.lbase:find(t1, 1, true) then s = s - 2 end
      if favSet[p.name] then s = s - 1 end
      return s
    end
    for i, p in ipairs(results) do p._s, p._i = score(p), i end
    table.sort(results, function(a, b) if a._s ~= b._s then return a._s < b._s end return a._i < b._i end)
  end
  sel = math.min(math.max(sel, 1), math.max(#results, 1))
end

------------------------------------------------------------------ embedded assets (heading font: Archivo Expanded ExtraBold, SIL OFL)
local HEAD_FONT_B64 = [[
AAEAAAAQAQAABAAAR0RFRgBoAI4AACr4AAAAHEdQT1M35DPYAAArFAAAD8xHU1VCuPq49AAAOuAAAAAqT1MvMmHf/lcAAAGIAAAAYFNUQVRe90IcAAA7DAAA
AFpjbWFwKYgocQAAA3QAAAC+Z2FzcAAAABAAACrwAAAACGdseWaqFm3yAAAFBAAAH0RoZWFkJshrrQAAAQwAAAA2aGhlYQgQBG8AAAFEAAAAJGhtdHgUEBKK
AAAB6AAAAYxsb2NhjHSTIwAABDwAAADIbWF4cABpAGgAAAFoAAAAIG5hbWXOMOK8AAAkSAAABoZwb3N0/28ALAAAKtAAAAAgcHJlcGgGjIUAAAQ0AAAABwAB
AAAAAgBCji18n18PPPUAAwPoAAAAANv9HLEAAAAA5xQLv/+9/zME4gLlAAAABgACAAAAAAAAAAEAAANu/y4AAATl/73/+ATiAAEAAAAAAAAAAAAAAAAAAABj
AAEAAABjAGcABQAAAAAAAQAAAAAAAAAAAAAAAAAAAAAABALoAyAABwAAArwCigAAAIwCvAKKAAAB3QAyAPoAAAAAAAAAAAAAAACAAAADAAAAAAAAAAAAAAAA
T01OSQDAACAgJgNu/y4AAARMAZoAAAABAAAAAAIOAq4AAAAgAAMCnQBVA6UADwOSAFUDrgA3A6UAVQNfAFUDHwBVA/QANwPdAFUBdQBVAt4AHAO3AFUC8gBV
BHwAVQPcAFUD9QA3A10AVQP1ADcDpABVA2MAMgNQABgDyABSA4gADQS9AAgDrAAXA5YAEQNZACIDCAAmAv0AQQMDAC0C/QAqAwwAKgHiAAsC/gAHAvMAQQE7
AEEBOf+9At0AQQE7AEEEjgBBAvMAQQMNACoC/QBBAv0AKgHgAEECxgAkAfUAGQLzAD8CwgACBDYAAgL8AAgCwgACApQAHAMSAC4CvwBIAw8AMwMVACwDDQAX
AxUALAMXAC4C1gAUAyMAKwMXACkBXQBCAV0APgFYAEIBXQA+BBIAQgFmAEMCywAjAaIAZAGvAB0C9QAQATQAAAE0AAABcwA7AXMAHAFrAB8BawAhAWgATgFo
ACABoAAyBOIAAAKPAAACCgA2ARYANgEwAAACxgAkAuAAVALgAFQC4ABgAuAATALgABcC4ABjBGwAOATlADcD6QA+ASUAVQE/AAAAAAACAAAAAwAAABQAAwAB
AAAAFAAEAKoAAAAWABAAAwAGAC8AOQBAAFoAYAB6AH4AtyAUICb//wAAACAAMAA6AEEAWwBhAHsAtyAUICb//wAAAAUAAP/AAAD/ugAA/4/gPuAdAAEAFgAA
ADIAAAA8AAAARAAAAAAAAAAAAFYARABUAEgAVwBeAGAAVQBLAEwARwBYAEAAUQA/AEkAQQBCAFsAWQBaAEUAXwBPAEoAUABdAFMAYgBNAGEATgBcAAC4Af+F
sASNAAAAAAAAJgBjAJUAvADSAOYBIgE5AUUBZQGAAY8BzQH2Ai4CVAKTArwDEQMjA0QDZAOnA8UD3QPzBEoEhgS7BPgFMwVWBckF8QYEBiYGPQZJBooGsgbm
ByIHXwd+B9gH+wgiCD8IfAiXCMcI3QkVCS0Jawm2CeAKGwpkCoAKzAsVCyALNwtJC2YLewuOC9EL3Qv/DC4MOwxIDGQMgQy8DPcNCA0aDSYNMg0+DVUNZA1k
DcUN2Q3sDf4OEQ47Dk4Orw83D4cPlA+iAAIADwAAA5YCsAAHABQAAHMBMwEjJyEHEzMnLgMnIw4CBw8BUuMBUt00/pA0eOg+BA4QDAQHBxQRBwKw/VBubgED
jAkjJyEIEjAsDgADAFUAAANiArAAEwAdACcAAHMRITIWFhUUBgYHFR4CFRQGBiMlITI2NTQmJiMhNSEyNjY1NCYjIVUCNThaNSA3ISc+JDlgPP6TASkgKBEi
GP7aARgXIBIoHv7lArArTDMtQCgKBAgpRjI7UyyRIyQTHhGGER4VHSMAAAEAN//0A3gCvAAhAABFIiYmNTQ2MzIWFhUjNCYmIyIGBhUVFBYWMzI2NjUzFAYG
AeeQwGDd1Ha0ZcYzXD1IYjMzYUZCXzPCYrMMUZ51q7lHgVgrPSExVjkZOVcxHzwqVYBHAAACAFUAAANuArAACgAYAABzESEyFhYVFAYGIyczMj4CNTU0LgIj
I1UBgH+4YmK4f7WpME04Hx84TTCpArBQmm5vmVCXGS5EKxcrQy4ZAAABAFUAAAMpArAACwAAcxEhFSEVIRUhFSEVVQLM/gABwP5AAggCsJd0knyXAAEAVQAA
AvkCsAAJAABzESEVIRUhFSEVVQKk/icBpf5bArCXi5f3AAABADf/9AOnArwAKgAARSImNTQ2NjMyHgIVIzQuAiMiDgIVFRQWFjMyNjY1NSM1IREjJw4CAdnR
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
LFyQY0RlRSoTEyEQFR8RDB40JzxGIAkPHSMPBxUUCAIIAytBJiBGO8UZEyZZS2Z+OkuadqOjCA4JXQgOCAEXChUhFyEPHxoTFQgAAQA+//QD4gK8ADoAAEUi
JiY1NDY3NSYmNTQ2NjMyFhYVFSM1NCYmIyIOAhUUFhYzMxUjIgYGFRQWFjMyNjY1NSEVIxUUBgYB0om0V0xAMURYqnx6rl25LlQ7MUw1HCA0HY6iHzYgLmFK
TFgmAUOKUqsMMVs/PlgQBA5PMjtYMS9UORYLFh8RCxcgFxogDnYQJB0fKhUYLBzFdktHZzcAAAEAVf82ANEC1gADAABXETMRVXzKA6D8YAAAAQAAAlABPwLV
AAQAAEEjJzUzAT+WqcwCUIAFAAAAGAEmAAMAAQQJAAAAqAAAAAMAAQQJAAEAIACoAAMAAQQJAAIADgDIAAMAAQQJAAMANgDWAAMAAQQJAAQAIACoAAMAAQQJ
AAUAGgEMAAMAAQQJAAYAIAEmAAMAAQQJAAcATgFGAAMAAQQJAAgAGAGUAAMAAQQJAAkAGAGsAAMAAQQJAAoBjgHEAAMAAQQJAAsANgNSAAMAAQQJAAwANgNS
AAMAAQQJAA0BIAOIAAMAAQQJAA4ANASoAAMAAQQJABAADgTcAAMAAQQJABEAEATqAAMAAQQJABkAGAT6AAMAAQQJAQAADAUSAAMAAQQJAQEACgUeAAMAAQQJ
AQkAEgUoAAMAAQQJARkAEAU6AAMAAQQJARoADAVKAAMAAQQJARsACgVWAEMAbwBwAHkAcgBpAGcAaAB0ACAAMgAwADIAMAAgAFQAaABlACAAQQByAGMAaABp
AHYAbwAgAFAAcgBvAGoAZQBjAHQAIABBAHUAdABoAG8AcgBzACAAKABoAHQAdABwAHMAOgAvAC8AZwBpAHQAaAB1AGIALgBjAG8AbQAvAE8AbQBuAGkAYgB1
AHMALQBUAHkAcABlAC8AQQByAGMAaABpAHYAbwApAEEAcgBjAGgAaQB2AG8AIABTAGUAbQBpAEIAbwBsAGQAUgBlAGcAdQBsAGEAcgAyAC4AMAAwADEAOwBP
AE0ATgBJADsAQQByAGMAaABpAHYAbwAtAFMAZQBtAGkAQgBvAGwAZABWAGUAcgBzAGkAbwBuACAAMgAuADAAMAAxAEEAcgBjAGgAaQB2AG8ALQBTAGUAbQBp
AEIAbwBsAGQAQQByAGMAaABpAHYAbwAgAGkAcwAgAGEAIAB0AHIAYQBkAGUAbQBhAHIAawAgAG8AZgAgAE8AbQBuAGkAYgB1AHMALQBUAHkAcABlAC4ATwBt
AG4AaQBiAHUAcwAtAFQAeQBwAGUASABlAGMAdABvAHIAIABHAGEAdAB0AGkAQQByAGMAaABpAHYAbwAgAGkAcwAgAGEAIABnAHIAbwB0AGUAcwBxAHUAZQAg
AHMAYQBuAHMAIABzAGUAcgBpAGYAIAB0AHkAcABlAGYAYQBjAGUAIABmAGEAbQBpAGwAeQAgAGYAcgBvAG0AIABPAG0AbgBpAGIAdQBzAC0AVAB5AHAAZQAu
ACAASQB0ACAAdwBhAHMAIABvAHIAaQBnAGkAbgBhAGwAbAB5ACAAZABlAHMAaQBnAG4AZQBkACAAZgBvAHIAIABoAGkAZwBoAGwAaQBnAGgAdABzACAAYQBu
AGQAIABoAGUAYQBkAGwAaQBuAGUAcwAuACAAVABoAGkAcwAgAGYAYQBtAGkAbAB5ACAAaQBzACAAcgBlAG0AaQBuAGkAcwBjAGUAbgB0ACAAbwBmACAAbABh
AHQAZQAgAG4AaQBuAGUAdABlAGUAbgB0AGgAIABjAGUAbgB0AHUAcgB5ACAAQQBtAGUAcgBpAGMAYQBuACAAdAB5AHAAZQBmAGEAYwBlAHMALgBoAHQAdABw
ADoALwAvAHcAdwB3AC4AbwBtAG4AaQBiAHUAcwAtAHQAeQBwAGUALgBjAG8AbQBUAGgAaQBzACAARgBvAG4AdAAgAFMAbwBmAHQAdwBhAHIAZQAgAGkAcwAg
AGwAaQBjAGUAbgBzAGUAZAAgAHUAbgBkAGUAcgAgAHQAaABlACAAUwBJAEwAIABPAHAAZQBuACAARgBvAG4AdAAgAEwAaQBjAGUAbgBzAGUALAAgAFYAZQBy
AHMAaQBvAG4AIAAxAC4AMQAuACAAVABoAGkAcwAgAGwAaQBjAGUAbgBzAGUAIABpAHMAIABhAHYAYQBpAGwAYQBiAGwAZQAgAHcAaQB0AGgAIABhACAARgBB
AFEAIABhAHQAOgAgAGgAdAB0AHAAOgAvAC8AcwBjAHIAaQBwAHQAcwAuAHMAaQBsAC4AbwByAGcALwBPAEYATABoAHQAdABwADoALwAvAHMAYwByAGkAcAB0
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
AAAAAAAAAAAAAAAAAAAAAAAA/+4AAAAAAAD/3QAAAAD/uv/dAAAAAAAAAAD/4v/dAAAAAAAAAAAAAAAAAAD/0wAAAAAAAAAA/8T/pgAA//sAAAAAAAAAAAAA
AAAAAAAAAAD/0wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/84AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP/O
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACgAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/90AAAAAAAAAAAAAAAAAAP/sAAAAAP9vAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAD/xP+cAAAAAAAAAAD/9gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/9v90AAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/xP+6
/9j/3f/dAAAAAAAA/8T/tf/iAAD/7AAA/87/4gAA/6H/7P/iAAAAAAAAAAAAAP/OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP/E/8QAAP/IAAAAAAAA/+QAAAAA
AAAAAP/uAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAwAAQAHAAAACwAMAAcADwAaAAkAHAAc
ABUAHwAgABYAJQAlABgAKQAqABkALAAuABsAMAA+AB4ARgBGAC0AUQBSAC4AVABVADAAAQABAFUAAgAaAAgAAAAEABsACgAAAAAAAAAXAA8AAAAAAAAAFQAA
ABAACwARAAMADAAMACcACQASAAAAAQAAAAAABQAYAAAAAAAAAAAAGQAAAAAAAAABAAEAAAATAA0AFAAAAAYABgAoAAYADgAWACEAJgAlAB8AHgAkACMAHQAg
AAAAAAAAAAAAAAAAAAAAHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcABwAAACIAIgABAAEAVQAEAAAAAgAAAAAAAAACAAAAAAAZAAAAAAAAAAAAAgAAAAIAAAAM
ABAABgANAA0AJQALABMABQAIAAEAAQABAA4AEQAIAAAAAAAIAAgABwAHAAEABwABAAcADwASAAMACQAJACYAJwAUABYAIAAkACMAHgAdACIAFwAcAB8AGAAY
ABsAGwAYAAAAAAAaABUAAAAAAAAAAAAAAAAAAAAAABcACgAKAAAAIQAhAAEAAAAKACYAKAACREZMVAAObGF0bgAYAAQAAAAA//8AAAAAAAAAAAAAAAAAAQAB
AAgAAwAAABQAAwAAACwAAndkdGgBAQAAd2dodAEAAAFpdGFsARoAAgAGABIAHgABAAAAAAEZAH0AAAABAAEAAAEJAyAAAAADAAIAAgEbAAAAAAABAAAAAA==
]]

local TOPO_DATA = [[
3CTn3pS84SRx4xQZ5BPH5AOJ4vNM4SMj3pMN3AMR2XM119N110Oz1yRD1+S+2JTg2XTw2kT03CTn 2AW13AV64EUJ5JRk5rPc5wN15cMj4zLl33K/3AK52GLQ1ZMO1DNg0oUl0pV301Wg1FW11gW+2AW1 I0tBJbsjJ3rvJ8qxJkpzIypMH7pFHEpcGeqIGQqxGOraGasDGpsbHEs1HttII0tB 1uYw2XYS3AXj4SVS5kR+6RPH6XOJ6UNM58L55JKz33KB2kJ51gKX0xLQ0fL50RM30CRXzXV3zWXKzmYH0IYw03ZA1uYw JJt/KEtVKgssKxsDK6rRK5qcKupzKZpKJboVIIoEHaoMGtohFwpfFWqcFRraFfsYF2tBGhtqHSuDIIuMJJt/ 1GaX17Z92kZZ3bYS4EXI47VK5ySx6ZQu6wPH64NM6uMO6gLl6JK85kKQ4EJR2kJA1uJJ1FJd0dJ+z/KnzsLQzdMOzPRXy+S+yPWMyJXzyfZFzJZ80AaZ1GaX Iyu8JouqKRuPK6tjLZssLsrvLxqxLopzLQo1KxoMKEnqIknQHtnUG2nlF/oGFWovEwpzEgqxEjsDE5tBFpt/GluoHtu+Iyu8 0ybq1ubS2kam3bZi4EYc47Wf5yUF6uRD7ROz7ZNg7XMj7ILl62K85yJm4EIi3AIP2JIN1SIW0bIvzsJVzKJ+yrK8ybL5yVM3yaPwyVRDyDSqw9Wgw0Xzw4YwxYaDyQbBzlbp0ybq JPvmKEvRK+uoLwtqMOssMfrvMkqcMWpKL6oMLWnhKam6JbmmIWmiHSmtGNnJFWnvEpohEApzDwrFD2sYEZtqFWusGpvbH7vtJPvm soc8tAcntzbduObQvgbeyucv0Ac71gck2Xb/3AbV4EZt47X06AUs7ePw7zOJ75M37uLl7VKn6pJo5kIr4SH72yHf1gHd0bHvzSIXyPJVxZKnw1MOwvNgw9QZw3RXwoSVvPV3tzabtlawshbksFcQsCcnsLc8soc8 JfwPKtvtLsu8Mdt/NEssNYraNbpzNJohMqnjL/m1K6mNJol5IIl5G2mLFkmxEmnjD2ohDRpzDAraDEsYDPtBD3uME9vRGbwDH7wYJfwP 4mtV5Ws56BsD6XrF6gpz6Uoh5ynU5Jmr4Smd3bm32yn12apK2Uqx2jsD3As73ptX4mtV tAgKvTeewKeDxOd70AeM1Sd92kdG3pbw4gaL5WX/8HOz8WNg8XMO8FK87mJ+6NId4SHR2XGu0pGzy8HcxQIsvyKSt8M3s0OzsLQZr2SArsU6rhWMrAXzptaspabqpScnpVdlpheYp5fMqYfyrBgPrqgbsTgZtAgK 44u86NuD7Iss7irF7ipK7GnP6pmR6Nlq5Jk04gkn33ko3Nk62wlT2Tl813m61hoM1Vpf1RrF1VsY1st/17ud2Xu73bvQ44u8 Jqw4LIwSMavUNbt/OBssOdqxOepKOLn4NfmrMol8LWlZJolKH7lSGNlwE7mcD3nYDEohCbqICNrvCTssCetVDLuoEgv0GNwrH7xCJqw4 pV+tps+Ep29ap28Ipp7fpT69o46qoc6qoB7Fnz7vnw8dn29aoB+Eoc+xo4+9pV+t n+AAocAdo4AkpTAcpzAA s8hxuBhQv8f/xAflyFfg0pfx1gfq2XfI3bdw4gbs5WZd8rOJ84M380Ll8jKn77Je7QIs6NHx4EGh17F+0AGGx3G8v5IXt/KSsJM3q7PHqQRDp/SVpjV3pPXKoIaXn5bqn4cnoCd6oUe3owf1phg2qYhhrPh3sFh7s8hx 3cw45yv+7Suz73t/8StB8isD8pqx8kpf8Tn475ml7SlT6bkJ5kja4gi33pit3Ai02XjO1ukK1SlM06ml0ooM0VsY0bvH0lv603wk1Sw91uxF3cw4 J2xhLlw4NRvtOduTPTssP7qxQEpKP0njPamlO/l7N6lCMakkKEkbHtktF/lMEgl9DNnECOohBkqIBXrFBSsDBXtBBitqCRu8DwwPF/xTH7xsJ2xh WZyfXVyFYMxUZQv6Z7uoadtBanrvaiqwaGpzZrphZCpeXZqIVmraVEsDUwsrUhtqUduoUjv6Uww3VAxhVayIV1ybWZyf qC//qf/Bqz9vq48dqx7fqd6hp85upT5Loc46nz5HnZ5jnH6Nm87Km88dnF9vnY/Bnx// nGAAnzBdoPB4o4CGpeB7p8BkqaA+q5AA 0e0G2yyt6pxC78wP86vR9iuT98tV+JsD+Bqx9mo19JnP8hlo7Sji4ygz4cgK4Vfh4jd65yZu7IUl9IOJ9ZMj9ULQ9BKS8WJJ7fIL6bHR5JGb33Fy2kFX1SFM0AFQyuFjwPGwt4Isr0LQp3Oeo4QuohSAnzVrmyZFmjbBmncTm0dlnmf0orhcqKiorcjEsujDuBiowXhcxphLy8hdzlh5z8ia0LjY0JkqzXtVyvx2yqzIywzxzJ0Vzy0Y0e0G AAt0AauoA6vRClwjFWx0HtyWJbyTLIx4New4QDvWQsvKRIvQRevmRxwLSwzxTe1YUV2XUw2mVa2rWQ2RXH1aYZzkZ5w+asvRbPtqblsDbsqcbnpdbYoha+nuainUaHnKZenOWDoyU+pBT6o+TRosSooDQ6lEQDkCO/jcNfjTKfjmHtkFFykoESlUC+mRB1njAspfAArO rB//rZ+trp9Grq7zrc6hrA5jqK4ipT39oP3qnm3ym/4Rmp46mZ54mT7KmZ8xmo+Ym/// mhAAm9BfnmCyoPDbo4DopvDaqYC2rJBnrvAA //n5/koA/In4+fnK8hjs6Qge56f15oe35ld65tcn66W178S+9lOJ98MO94LQ9vKn8/JH7xHu6AGU3bE81FEayuEnwKFmtzHLsFI6nvPcl4SllPTak0TokmTlkLTMjSSAidRpiCRyhmSLhCTTg4UlhLVkh0WHjhWokBXKkYYHlecnmMe3nHgzociep8jlrckGtKkEwzjBx3jRyikBy2k+y+mRy9ohywrFyVt/xFzIw30vw/2Bxc2xyS3IzJ3A0O2a3A0I4Sza5yy38yyO+7xT//xI AAxIBuxeF/yxHtzDJ2y8NtyGPMyNP1ynQezcSM3ITR45UV57Uw6FVa6EWe5aXj4FYZ2eaixpbZvjcCtfcYrvchpzcZoMcCmqbZlUawknaVkaZrkgXwmDWsmpV1m1U+muUJmRThloR+jDRViMQshtP1heOIhsE7kSCylbAAnx r1//sR+Ese8Isc62sH5jrh4mqY3ipG20oB2lnK2wmh3RmI39l346lw6Nl07zmF+Emc// mCAAmpClnYERnzE1ocFXphFoqlFQrPEar4CxsmAA //lw/Wlk+tlC8Dhc66fh6lej6bdl6jbB7RW18RS++QNg+fMO+aK892Jc80IC7SGn5JFI3pEV2XD31FDmzlDjySDtwzEItDFysFGWrcG6o4LOoBMUnKNJmUNplqNzjhNtirN0hZOigvPSgUQAfdSVfDUQe8Vje/WgfRXef5YRiPZtjUazkJcTl9gemxhxnkiupGkCqzk5sulLvgkxwXkzxOlQxpl7x7m6yDoMx8rFxXuTv7zcvZ1tvR3Tvc39vr4RwK4oxA48yg440A4K3A1n4g0u5k0b6b0Z8y0+9o1D+f0x//zr AAziBEzDCJy7Htz1JNzyMozVOIzkO/0JP11TSa6tTe8iUV9RVM9SWD8uXV7TYZ5rZN39cfuTdCrvdOpKdHnPczloa+f5aTejZ5eNZQeAYNeOXie3XWfhXXhxXMiuWsjoWDj/Vnj+VMjwUljDUChxTRe8S1efSaeaQ6e5KuhxEgjwA3lfAAlv sr//tl62tm5jtb46sm39ql2mo41ynm1kmv1xmG2Slp2/lT4RlN5jlT7Kl+// TzAAUjARVWAA lmAAmZEMniHunnIsneJVm9KMmUKvldLJiCMGg9MygDN1fiOzfDQFePTTdnXKdkYcdqZFdxZaeLZ4g9a5h0baidcAjYdRlBgelzhxm9jLockhp8lcrPl8shmMvFmRwKmswlnMw3n4xEo1xHpzw4sYwJvmu3znuY0vtz1ptK2GsT2Koq0ynY0lmv0rmG0/lp1YlM2Bkw3Tkq5Pk17Klj// //kK/Wj4+fjL8kgv72fh7cej7Ldl7Ecn7DbV7OZa7+VO81SV+kOJ/CMj/HLl/CK8+nJp9iIC7tGS5JEc3ADU1SCxzlCjx3CpvFDKuBC+tsClthB7tnAA Vw//Ws+2Yi8IZ75jae39bkzcc8u8disUd3pfdymldik4csgzcQc8b6b+bjbqa+beXjbTWQasVnaDU9ZFTEUlSMTKRVSWQfR3PaRkOjRmN6SENwSqN0TTOTUlQCYHQiaDQjbBQdbqQHcnPsdROxeNNtfALSgeJohUBgkDAAkN AA2IBg0yCJ0eDA0THt0uL/0XNf0tOj1kPa25Qe5PSa+SS1/KTb// tq//uB+Luc8xu375vT7Zv87ByF6izX5/332e472E6A2C8y3J923U+73E//2V RvAASaBOTDB/T6CnUwC1VaCtWGCQWsBjXmAA lMAAlyFylvHFlgIClJIskhJVgvLRf5MAfQM3ezN1eZPGdHUwciW1cCYDbZY7aiZgZQZ3YMZ1XHZcWQYwVnX6U+WvTeTaS1SZSMRqQ6QvPaQEN6PsM2PxMUQFL/QhLxRULzSAMUTnOTXKPCZFPLaDPHbBOzb+ObcnNkdlL9e3KBgKIWhBGUhxCXi3BEjEAAi9 //i5/Iia+Rhp8sfh74dl7rcn7lbV7nZu71Xz8kUQ9bRw/RN1/rMj/xLl/tK8/SJp+RIF8/Gu6pEx4SDK2XCL0bBhwIA+vmApvSAA Xx//ai7QbI54bf4mcVzxd7tVeaqIegmldygzdwfhd1ejeGdlegc8fCcjf5cYg9cqiKdli4eilRiamUjmndkqpGl3qlmpu3n5vhohv1pKv/pzwDqxv/sDvdu8ucyMt2zctX0Gsh0srq0yoPzvmvzqmGz3ld0Qkk1YkT2BkF2/kC4mlJ// AA4gA/39Cy2ZDq2BHf14K61bMo1qNR2AN62nO74RP16hRn// vP//vT/Hvg+YwK9awz86zl7X2y4n4E3z473j5y3k8e4m9o42+742//4m QXAARQB7SaDaT6EiVaE+WeEwXVEBX+C5ZNAA kzAAlBCllCEgk6FykmG7kJHujUIif5KTfEK8ejLleLMVd0Ngc7SVcSU6bnWlawXwZ5YWZCYlYMYiXVYMWsXrWAW1TwSVTGRXSaQoQ6PnOWOaNDODL/OKLWOfKtPLKVQFKRRDKcSAK6TTNEXKNvYwN5ZuN4aXNtbKNTb+MNdRKsejJNfnHpgeFkhPCyh7BSiGAAh4 //Jl/eIs+tHs8IFQ4gCc0gAA AANOANMjAULlAAKF //hz/IhS+Rgf9hfh89ej8Rcn8FbV8CaD8VW19GTn+ERO//Nu ZW//bn7wcO6Ncl46dQzcehtVfBpzfNmRe8hxfBgKfMfhfde/f5engUefg9enh0fOktjDl+kVnYlip8nRt4pKudpzu4rFu4tBuZvmtlx0suzBsFzbrPzkoByvmhytlqy+lBzYkY0Aj60vjo1YjY2WjV39kw// AA6RBS6gCJ68EG9GFJ99F/+RG2+MHf9uHy8xHt7zHJ5jHJ46Ha4RIH3oJg2/K62uL/24NH3oOI5NO97fQQ// 0E//zc/WzT/BzS+Yzj9v0P8x1u7G2y6F335W4t5D5k5B8/5+//6Q OwAAPUBSQCClRCD3SBE1TRF0UwGtWDHLXHHSYnG6ZCGmZZGHZrFKaLB7awAA kZAAkhCQkcEMkLFfjkGwi4HfiCIDd9JkdeJ+dHKnc3L5cjQZcKSqbZVGa+V6aVWtZrXKY1XZX+XRXVW7WQVuUHRdTeQfSyPwRjO4NtMyMoMfLkMpKfNQJlOJJDPHI6PwI6QZJFRXJhSqL1XKMXYcMjZaMiaDMJbVLNcnJ5d6IWfHG2f8EtgtCkhJBEhMAAg6 //IS92GA24AA AAOqA5NMBML5BKLQA6KSAAIl //gz/IgP+ffo9Wd68tb+8eZu8sW19AVO9bTw+fRR//O9 a4//dA7Kdk5jd44ReF2qeSyzfjqcgQjDgih+gvhrhLhfiCh3lGkqnzmyshp8tCqctcrFtxsYtvt/tZvms4w4sFx4rcyOqzyTnmxsl4x2lByNkMyzjhzhi90aid2Bie3ojz8xkX// JG//J8/WKc+YKj9GKR7JKP6NKc5jKt5QLW5DMN5cM26WNT7fOo// 2k//2E/W1y+t1v+E139a2K8x237z3j7K4S6u5J6f6A6g//7l AA7pBS8WD+/BFf// DyAAE7AxGbBVIWBpLkB5MoCMNfCwQLFJU+IuWQJWZCKFaHKma+LfbiM3b0OzbuRDbLTiawUjaVVOZ5VsZQWGYMWJXVVpWrU6WDT0UVQLTsPQTDOoNRK6MNKxLILKJnMOIKNgHrOJHXPHHcQFH3RXKXWgK+YHLJZFLJZuLBaXKmbVJrcnIZd6HSeuF/faESgACkgVBEgUAAf/ j+AAkDBnj+DOjuEgjUFgirGXh0G/gvHZfrHhemHZdwHCdCGccaFeb8EMbwC5bxBncEAA //HN6+Cl4nAA AAPsB9NgCRM3CYMOCQLQBxJ+BAIsAAHc //f4+tez9udR9GbV85ZF9HWg9vT8+tRx//P8 gi1HgU1GgG02frzmfgx2flv6gHrFgtnPhLlhhck+h0kkidkbjUksmUmprGqcr7rasXsYsitqsVu8r7v6rVwjqKw5mvwqlBxGj9xqi6yfgi1H cK//c99vem5/fr32gU3Hgv3XhL3+ir64jf9aj8// 4Z//3y+t3y9v4V8x5J8O6N7/8I8E+f8U//8x AA83BS9yDb// CYAADpBPEtB9FyCaIyDTKaEMLVFJL3GHMBHFL4HuKyJVI/K/HEMIFkMcE7MQESLtB6IXAAGW jhAAjkBSjfCljTDii8EgidFPh0FzhLGGgUGPfdGHe0FzeLFPdqEgdRDidDClc/BSdIAA //GK8WC56+BS6MAA ZQUuY1U4YMU1XuUlXHT9WQSaU+PBUVNuTsNARVL4QFK8PjKSPBJVO3IsPBICPaHwP1HsQ6H7SMIvUwLKVnLfYZL+ZQMXZ5M5aVNgawOla8Pwa6RDatSVaVTaZ5UIZQUu AAQnBSPkCkO5D3OpEtO9FWPmGNQzIaUlJhXKJxYHJ2ZFJnaXI+bqHtdLGWeOEtfACyffBSfgAAfF //e9+7eA+Ecn9fas9UYw9fWg+CUQ+5SV//Q1 idw7hmw/hEwjgvvmgptqg4qxhVohh0nPiPmqirmYjUmSkYmlllnPm7oMoZpfpnqxqTrvqtssqztVqvt/qbuop8vBpKvRlqvwidw7 dN//d69ve072fr6qgi6Mg96QhZ6hiV7zjE9vjf// 6D//53/B6A+Y6b957E9j8W9S929S+79f//97 AA+DA3+uCF// BDAACyCAD3C7E7DgHrEgIpFJJMFyJeGcJlHFJhHuI/I3IIJtG2KQFyKKEgJZB/GwAAFK jAAAi+B7ixC5idDriCEThmEqgiE+fdEne/EMejDieRC5eDB7eAA+eFAA //FA+LDi88CQ8HA+7zAA ZCTAYnTLX+S/XjSiXGRsWuQZWqPcWyOzXHOUXwOCYnONZQOvZpPcZ2QZZ0RXZiSVZCTA AARfBEQsCXQRDpQbEtRDGNSsHkU6IXW1IlXzIpYwIcaDH1bVGzcnFmdlEEeUCkerBSeqAAeL //eB+9c8+Tbq94aD9wYc95Wg+WUl/ES+//Rt k0urjhu7iru1iEuTh0tqhrsDh8qIibo1jGoGjvn6kYn+l4ounYqIoCrFoUrvoYssoPtEnztim9uAk0ur eI//em+YfQ9Ef58Rgv74hZ8IiK9Gir+Zi+// 7z//7//W8R/B9N+m+t+n///M iWAAiVBSiCCchdDOgvDgf9DOfbClfCBSfEAA //DT+oCQ+KBn98A++EAY+fAH/IAL//As AAA5A9CQBODOBEDgA3DlAADZ AASZBERoCJRXDNRiESSJFkTcGtVOHUW1HiYcHVZuGvbBF/b+Ezc8DcdlCJd1BEduAAdN //dC/VcT+rbB+WZu+NYH+VWg+tU8/STn//Sn kmssjvshjhsSjUrvjcqxj9qKk0qJlRqclurFlyrvlpsDlPsckmss fH//fZ/Bft+YgR9vgv9jhZ9yh0+WiG/BiU// AATYA3SsB7SaDASnD3TIE7UNFxVjGQW1GbYHGPZaF1aXFIbVEEcODAcuB7c5A3csAAcJ //b8/XbB/AaD+yZF+tXz+1Wg/DVj/aUl//To AAUkApT6BSTlCJTiDAT2D5UlEmVjFIW1FRXzFLYwE2ZuEMasDbbWCXbyBgbzApbeAAa3 //aj/gZa/TXz/fWM//U5 AAWnASV3A3VJBgU2CJU5CyVQDbV+D0W1D+XzD0YwDbZjCyaLCJadBgaeA3aKAbZtAAYu
]]

local function b64decode(data)
  local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  data = data:gsub("[^" .. b .. "=]", "")
  return (data:gsub(".", function(x)
    if x == "=" then return "" end
    local r, f = "", (b:find(x, 1, true) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
    if #x ~= 8 then return "" end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
    return string.char(c)
  end))
end

local HEAD_FONT_PATH = DATA_DIR .. SEP .. "LGHead.ttf"
do
  local f = io.open(HEAD_FONT_PATH, "rb")
  local have = f and f:seek("end") or 0
  if f then f:close() end
  if have < 1000 then
    local w = io.open(HEAD_FONT_PATH, "wb")
    if w then w:write(b64decode(HEAD_FONT_B64)); w:close() end
  end
end
local function headFont(size)
  local ok, f = pcall(ImGui.CreateFont, HEAD_FONT_PATH, size)
  if ok and f then return f end
  return ImGui.CreateFont("sans-serif", size, ImGui.FontFlags_Bold or 0)
end

------------------------------------------------------------------ fonts & style
local font = ImGui.CreateFont("sans-serif", 14)
local fontNav = ImGui.CreateFont("sans-serif", 15)
local fontSmall = ImGui.CreateFont("sans-serif", 12)
local fontBig = ImGui.CreateFont("sans-serif", 22)
local fontHead = headFont(30)
local fontHeadXL = headFont(48)
for _, f in ipairs({ font, fontNav, fontSmall, fontBig, fontHead, fontHeadXL }) do ImGui.Attach(ctx, f) end

-- topographic background: polylines decoded once, rebuilt as native arrays only when the area changes
local topoNorm = {}
do
  local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local val = {}
  for i = 1, 64 do val[B:sub(i, i)] = i - 1 end
  for path in TOPO_DATA:gmatch("%S+") do
    local pts = {}
    for i = 1, #path - 3, 4 do
      local a, b, c, d = path:sub(i, i), path:sub(i + 1, i + 1), path:sub(i + 2, i + 2), path:sub(i + 3, i + 3)
      pts[#pts + 1] = (val[a] * 64 + val[b]) / 4095
      pts[#pts + 1] = (val[c] * 64 + val[d]) / 4095
    end
    topoNorm[#topoNorm + 1] = pts
  end
end
local topoKey, topoArrays = nil, {}
local function drawTopo(dl, ox, oy, w, h)
  local key = ("%d,%d,%d,%d"):format(math.floor(ox), math.floor(oy), math.floor(w), math.floor(h))
  if key ~= topoKey then
    topoKey, topoArrays = key, {}
    local k = math.max(w / 1500, h / 1000)
    local dx, dy = ox + (w - 1500 * k) / 2, oy + (h - 1000 * k) / 2
    for _, pts in ipairs(topoNorm) do
      local t = {}
      for i = 1, #pts, 2 do t[i] = dx + pts[i] * 1500 * k; t[i + 1] = dy + pts[i + 1] * 1000 * k end
      topoArrays[#topoArrays + 1] = reaper.new_array(t)
    end
  end
  for _, arr in ipairs(topoArrays) do ImGui.DrawList_AddPolyline(dl, arr, C.topo, 0, 1.0) end
end

-- smooth hover animation (0..1) per id
local anim = {}
local function animate(id, target)
  local v = anim[id] or 0
  local dt = ImGui.GetDeltaTime and ImGui.GetDeltaTime(ctx) or 0.016
  v = v + (target - v) * math.min(1, dt * 14)
  if math.abs(v - target) < 0.002 then v = target end
  anim[id] = v
  return v
end

-- line icons, drawn (no font glyphs needed)
local function icon(dl, kind, x, y, col)
  local s = 16
  if kind == "grid" then
    for i = 0, 1 do for j = 0, 1 do
      ImGui.DrawList_AddRect(dl, x + 1 + i * 8, y + 1 + j * 8, x + 7 + i * 8, y + 7 + j * 8, col, 1.5, 0, 1.4)
    end end
  elseif kind == "star" then
    local cx, cy = x + s / 2, y + s / 2 + 0.5
    local pts = {}
    for k = 0, 10 do
      local a = -math.pi / 2 + k * math.pi / 5
      local r = (k % 2 == 0) and 7.5 or 3.2
      pts[#pts + 1] = cx + r * math.cos(a); pts[#pts + 1] = cy + r * math.sin(a)
    end
    ImGui.DrawList_AddPolyline(dl, reaper.new_array(pts), col, 0, 1.4)
  elseif kind == "heart" then
    ImGui.DrawList_AddCircleFilled(dl, x + 5.3, y + 6.2, 3.4, col)
    ImGui.DrawList_AddCircleFilled(dl, x + 10.7, y + 6.2, 3.4, col)
    ImGui.DrawList_AddTriangleFilled(dl, x + 2.05, y + 7.3, x + 13.95, y + 7.3, x + 8, y + 13.6, col)
  elseif kind == "clock" then
    ImGui.DrawList_AddCircle(dl, x + 8, y + 8, 7, col, 0, 1.4)
    ImGui.DrawList_AddLine(dl, x + 8, y + 8, x + 8, y + 4, col, 1.4)
    ImGui.DrawList_AddLine(dl, x + 8, y + 8, x + 11, y + 10, col, 1.4)
  elseif kind == "fx" then
    for i = 0, 2 do
      local xx = x + 3 + i * 5
      ImGui.DrawList_AddLine(dl, xx, y + 1, xx, y + 15, col, 1.4)
      ImGui.DrawList_AddRectFilled(dl, xx - 2, y + 4 + (i % 2) * 6, xx + 2, y + 7 + (i % 2) * 6, col, 1)
    end
  elseif kind == "keys" then
    ImGui.DrawList_AddRect(dl, x + 1, y + 2, x + 15, y + 14, col, 2, 0, 1.4)
    for i = 1, 3 do ImGui.DrawList_AddLine(dl, x + 1 + i * 3.5, y + 2, x + 1 + i * 3.5, y + 14, col, 1.2) end
  elseif kind == "tag" then
    ImGui.DrawList_AddLine(dl, x + 5, y + 2, x + 3.5, y + 14, col, 1.4)
    ImGui.DrawList_AddLine(dl, x + 11, y + 2, x + 9.5, y + 14, col, 1.4)
    ImGui.DrawList_AddLine(dl, x + 1.5, y + 5.5, x + 14, y + 5.5, col, 1.4)
    ImGui.DrawList_AddLine(dl, x + 1, y + 10.5, x + 13.5, y + 10.5, col, 1.4)
  elseif kind == "folder" then
    ImGui.DrawList_AddRect(dl, x + 1, y + 4, x + 15, y + 14, col, 2, 0, 1.4)
    ImGui.DrawList_AddLine(dl, x + 1, y + 4, x + 6, y + 4, col, 1.4)
    ImGui.DrawList_AddLine(dl, x + 2, y + 2.5, x + 6, y + 2.5, col, 1.4)
  elseif kind == "eye" then
    ImGui.DrawList_AddBezierQuadratic(dl, x + 1, y + 8, x + 8, y + 1, x + 15, y + 8, col, 1.4, 0)
    ImGui.DrawList_AddBezierQuadratic(dl, x + 1, y + 8, x + 8, y + 15, x + 15, y + 8, col, 1.4, 0)
    ImGui.DrawList_AddCircle(dl, x + 8, y + 8, 2.5, col, 0, 1.4)
  elseif kind == "format" then
    ImGui.DrawList_AddRect(dl, x + 2, y + 1, x + 14, y + 15, col, 2, 0, 1.4)
    ImGui.DrawList_AddLine(dl, x + 5, y + 6, x + 11, y + 6, col, 1.2)
    ImGui.DrawList_AddLine(dl, x + 5, y + 10, x + 11, y + 10, col, 1.2)
  elseif kind == "sort" then
    ImGui.DrawList_AddLine(dl, x + 5, y + 2, x + 5, y + 14, col, 1.3)
    ImGui.DrawList_AddLine(dl, x + 5, y + 2, x + 2, y + 5, col, 1.3)
    ImGui.DrawList_AddLine(dl, x + 5, y + 2, x + 8, y + 5, col, 1.3)
    ImGui.DrawList_AddLine(dl, x + 11, y + 2, x + 11, y + 14, col, 1.3)
    ImGui.DrawList_AddLine(dl, x + 11, y + 14, x + 8, y + 11, col, 1.3)
    ImGui.DrawList_AddLine(dl, x + 11, y + 14, x + 14, y + 11, col, 1.3)
  end
end

local function pushStyle()
  local cols = {
    { ImGui.Col_WindowBg, C.bg }, { ImGui.Col_ChildBg, C.panel }, { ImGui.Col_PopupBg, C.panel },
    { ImGui.Col_Border, C.line }, { ImGui.Col_FrameBg, C.field }, { ImGui.Col_FrameBgHovered, 0x2C2C2FFF },
    { ImGui.Col_FrameBgActive, 0x2C2C2FFF }, { ImGui.Col_Text, C.text }, { ImGui.Col_TextDisabled, C.text3 },
    { ImGui.Col_Button, C.card }, { ImGui.Col_ButtonHovered, C.cardHi }, { ImGui.Col_ButtonActive, 0x505056FF },
    { ImGui.Col_Header, C.accentB }, { ImGui.Col_HeaderHovered, 0xFFFFFF14 }, { ImGui.Col_HeaderActive, C.accentA },
    { ImGui.Col_CheckMark, C.accent }, { ImGui.Col_SliderGrab, C.accent }, { ImGui.Col_SliderGrabActive, C.accent },
    { ImGui.Col_ScrollbarBg, 0x00000000 }, { ImGui.Col_ScrollbarGrab, 0xFFFFFF26 },
    { ImGui.Col_ScrollbarGrabHovered, 0xFFFFFF40 }, { ImGui.Col_ScrollbarGrabActive, 0xFFFFFF55 },
    { ImGui.Col_TitleBg, C.panel }, { ImGui.Col_TitleBgActive, C.panel }, { ImGui.Col_Separator, C.line },
    { ImGui.Col_NavHighlight or ImGui.Col_NavCursor, C.accent }, { ImGui.Col_TextSelectedBg, C.accentA },
  }
  local nc = 0
  for _, c in ipairs(cols) do if c[1] then ImGui.PushStyleColor(ctx, c[1], c[2]); nc = nc + 1 end end
  local vars = {
    { ImGui.StyleVar_WindowRounding, 8 }, { ImGui.StyleVar_ChildRounding, 8 }, { ImGui.StyleVar_FrameRounding, 8 },
    { ImGui.StyleVar_PopupRounding, 8 }, { ImGui.StyleVar_GrabRounding, 6 }, { ImGui.StyleVar_ScrollbarRounding, 6 },
    { ImGui.StyleVar_ScrollbarSize, 10 }, { ImGui.StyleVar_WindowBorderSize, 0 }, { ImGui.StyleVar_ChildBorderSize, 0 },
  }
  local nv = 0
  for _, v in ipairs(vars) do if v[1] then ImGui.PushStyleVar(ctx, v[1], v[2]); nv = nv + 1 end end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 7)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 12)
  return nc, nv + 3
end

------------------------------------------------------------------ widgets
local function ellipsize(text, maxW)
  if ImGui.CalcTextSize(ctx, text) <= maxW then return text end
  local s = text
  while #s > 1 and ImGui.CalcTextSize(ctx, s .. "...") > maxW do
    s = s:sub(1, -2)
    while #s > 1 and s:byte(-1) >= 0x80 and s:byte(-1) < 0xC0 do s = s:sub(1, -2) end   -- never cut inside a UTF-8 character
    if #s > 0 and s:byte(-1) >= 0xC0 then s = s:sub(1, -2) end
  end
  return s .. "..."
end

local function initials(p)
  local a = p.base:match("%w") or "?"
  local b = p.base:match("[%s%-_]+(%w)") or ""
  return (a .. b):upper()
end

local function selectOnly(p) msel = {}; nsel = 0; if p then msel[p.name] = true; nsel = 1 end end
local function selectedList()
  local t = {}
  for _, q in ipairs(results) do if msel[q.name] then t[#t + 1] = q end end
  return t
end
local function clickSelect(i)
  local mods = ImGui.GetKeyMods(ctx)
  local cmd = (mods & ImGui.Mod_Ctrl) ~= 0 or (mods & ImGui.Mod_Super) ~= 0
  local shift = (mods & ImGui.Mod_Shift) ~= 0
  local p = results[i]
  if shift and results[sel] then
    local a, b = math.min(sel, i), math.max(sel, i)
    if not cmd then msel = {}; nsel = 0 end
    for k = a, b do if not msel[results[k].name] then msel[results[k].name] = true; nsel = nsel + 1 end end
  elseif cmd then
    if msel[p.name] then msel[p.name] = nil; nsel = nsel - 1 else msel[p.name] = true; nsel = nsel + 1 end
    sel = i
  else
    selectOnly(p); sel = i
  end
end

local function setHiddenPlugins(list, on)
  for _, q in ipairs(list) do hidPlug[q.key] = on or nil end
  saveSet("hiddenPlugins", hidPlug); selectOnly(nil); dirty = true
end
local function setHiddenFormat(devs, fmt, on)
  for _, d in ipairs(devs) do hidFmt[d .. "|" .. fmt] = on or nil end
  saveSet("hiddenFormats", hidFmt)
  scan(); selectOnly(nil); dirty = true
end
local function setHiddenDev(dev, on)
  if dev == "" then return end
  hidDev[dev] = on or nil
  saveSet("hiddenDevs", hidDev); dirty = true
end

-- give a brand another name (or merge it into an existing one); newName == nil restores REAPER's names
local function renameDev(dev, newName)
  local origs = devOrigs[dev]
  if not origs then return end
  for o in pairs(origs) do
    local n = newName or o
    devAlias[o] = (n ~= o) and n or nil
    if n ~= dev then                                      -- hidden state follows the brand to its new name
      if hidDev[dev] then hidDev[n] = true end
      local moved = {}
      for k in pairs(hidFmt) do
        local d, f = k:match("^(.*)|([^|]+)$")
        if d == dev then moved[#moved + 1] = { k, n .. "|" .. f } end
      end
      for _, m in ipairs(moved) do hidFmt[m[1]] = nil; hidFmt[m[2]] = true end
    end
  end
  if (newName or "") ~= dev then hidDev[dev] = nil end
  saveDevAlias(); saveSet("hiddenDevs", hidDev); saveSet("hiddenFormats", hidFmt)
  devSel = {}
  if category == "devs" or category == "dev:" .. dev then category = "all" end
  scan(); scanImages(); selectOnly(nil); dirty = true
end
local function askRenameDev(dev)
  local ok, name = reaper.GetUserInputs("Rename brand", 1, "Brand name:,extrawidth=220", dev)
  name = ok and name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[\t|]", " ") or ""
  if name == "" or name == dev then return end
  renameDev(dev, name)
  say(dev .. " -> " .. name)
end

local function askMergeDevs(devs, suggested)
  table.sort(devs, function(a, b) return a:lower() < b:lower() end)
  local ok, name = reaper.GetUserInputs(("Merge %d brands"):format(#devs), 1, "Name of the merged brand:,extrawidth=220", suggested)
  name = ok and name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[\t|]", " ") or ""
  if name == "" then return end
  for _, d in ipairs(devs) do if d ~= name then renameDev(d, name) end end
  say(("%d brands -> %s"):format(#devs, name))
end

local function pluginsOfDevs(devset)
  local t = {}
  for _, q in ipairs(all) do if q.primary and devset[q.dev] then t[#t + 1] = q end end
  return t
end
local function pluginsOfFolder(fo)
  local t = {}
  for nm in pairs(fo.set) do if byName[nm] then t[#t + 1] = byName[nm] end end
  table.sort(t, function(a, b) return a.lbase < b.lbase end)
  return t
end
local function addToFolder(fo, list)
  for _, q in ipairs(list) do if not fo.set[q.name] then fo.set[q.name] = true; fo.n = fo.n + 1 end end
  saveFolders(); dirty = true
  say(("%d plugin(s) -> %s"):format(#list, fo.name))
end
local function removeFromFolder(fo, list)
  for _, q in ipairs(list) do if fo.set[q.name] then fo.set[q.name] = nil; fo.n = fo.n - 1 end end
  saveFolders(); dirty = true
end
local function newFolder(list)
  local ok, name = reaper.GetUserInputs("New tag", 1, "Tag name:,extrawidth=180", "")
  name = ok and name:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if name == "" then return end
  local fo = findFolder(name)
  if not fo then fo = { name = name, set = {}, n = 0, kw = defaultKw(name) }; folders[#folders + 1] = fo end
  if list then addToFolder(fo, list) else saveFolders() end
end
local function captureMenu(list, label)
  if not IS_MAC then return end
  local missing = 0
  for _, q in ipairs(list) do if not imagePath(q) then missing = missing + 1 end end
  if ImGui.MenuItem(ctx, ("Capture missing images (%d)"):format(missing), nil, false, missing > 0) then
    queue(function() startBatch(list, false) end)
  end
  if ImGui.MenuItem(ctx, ("Re-capture all images (%d)"):format(#list)) then
    queue(function() startBatch(list, true) end)
  end
end

local function contextMenu(p)
  if ImGui.BeginPopupContextItem(ctx) then
    if not msel[p.name] then selectOnly(p) end
    local list = selectedList()
    if #list == 0 then list = { p } end
    local many = #list > 1
    if many then ImGui.TextDisabled(ctx, ("%d plugins selected"):format(#list)); ImGui.Separator(ctx) end
    if ImGui.MenuItem(ctx, "Insert on selected tracks", "Enter") then pending = { p, "tracks" } end
    if ImGui.MenuItem(ctx, "Insert on selected items", "Cmd+Enter") then pending = { p, "items" } end
    if ImGui.MenuItem(ctx, "Insert as input FX", "Shift+Enter") then pending = { p, "input" } end
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, favSet[p.name] and "Remove from favourites" or "Add to favourites") then
      local on = (not favSet[p.name]) or nil
      for _, q in ipairs(list) do favSet[q.name] = on end       -- the whole selection follows the clicked plugin
      saveFav(); dirty = true
    end
    ImGui.Separator(ctx)
    if IS_MAC and ImGui.MenuItem(ctx, many and ("Capture images automatically (%d)"):format(#list)
                                            or "Capture image automatically") then queue(function() startBatch(list, true) end) end
    if IS_MAC and not many and ImGui.MenuItem(ctx, "Capture image (click the plugin window)...") then queue(function() captureImage(p) end) end
    if ImGui.MenuItem(ctx, "Load image from file...") then queue(function() loadImageFile(p) end) end
    if imagePath(p) and not many and ImGui.MenuItem(ctx, "Remove image") then removeImage(p) end
    if not many then
      ImGui.PushFont(ctx, fontSmall)
      ImGui.TextDisabled(ctx, (imagePath(p) and "image: " or "expects: ") .. (imagePath(p) and imagePath(p):match("[^/\\]+$") or (p.img .. ".png")))
      ImGui.PopFont(ctx)
    end
    ImGui.Separator(ctx)
    if ImGui.BeginMenu(ctx, many and ("Tags (%d plugins)"):format(#list) or "Tags") then
      for _, fo in ipairs(folders) do
        local have = 0
        for _, q in ipairs(list) do if fo.set[q.name] then have = have + 1 end end
        local all = have == #list
        local label = fo.name .. ((have > 0 and not all) and ("  (" .. have .. ")") or "") .. "##tg"
        if ImGui.MenuItem(ctx, label, nil, all) then
          if all then removeFromFolder(fo, list) else addToFolder(fo, list) end
        end
      end
      if #folders > 0 then ImGui.Separator(ctx) end
      if ImGui.MenuItem(ctx, "New tag...") then local l = list; queue(function() newFolder(l) end) end
      ImGui.EndMenu(ctx)
    end
    local cf = category:match("^folder:(.+)$")
    if cf and ImGui.MenuItem(ctx, many and ("Untag %d from \"%s\""):format(#list, cf) or ('Untag from "' .. cf .. '"')) then
      local fo = findFolder(cf)
      if fo then removeFromFolder(fo, list) end
      selectOnly(nil)
    end
    ImGui.Separator(ctx)
    if category == "hidden" then
      if hidPlug[p.key] and ImGui.MenuItem(ctx, many and ("Unhide %d plugins"):format(#list) or "Unhide plugin") then
        setHiddenPlugins(list, false)
      end
      if hidDev[p.dev] and ImGui.MenuItem(ctx, "Unhide developer " .. p.dev) then setHiddenDev(p.dev, false) end
      if p.fmtHidden and ImGui.MenuItem(ctx, "Show " .. p.fmt .. " plugins of " .. p.dev) then
        local d, f = p.dev, p.fmt
        queue(function() setHiddenFormat({ d }, f, false) end)
      end
    else
      if ImGui.MenuItem(ctx, many and ("Hide %d plugins"):format(#list) or "Hide plugin") then setHiddenPlugins(list, true) end
      if p.dev ~= "" and ImGui.MenuItem(ctx, "Hide developer " .. p.dev) then setHiddenDev(p.dev, true) end
    end
    ImGui.EndPopup(ctx)
  end
end

local visibleDevs = {}
local brandQuery = ""
local splitDirty = false
-- sidebar row: pill when active, soft fill + text magnify on hover
local function itemButton(id, label, count, active, ic, magnify)
  local w = math.max(10, select(1, ImGui.GetContentRegionAvail(ctx)))
  local h = ic and 34 or 28
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local hov = ImGui.IsItemHovered(ctx)
  local t = animate(id, hov and 1 or 0)
  local dl = ImGui.GetWindowDrawList(ctx)
  if active then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, C.accent, 9)
  elseif t > 0 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, (math.floor(0x0E * t) & 0xFF) | 0xFFFFFF00, 9)
  end
  local col = active and 0xFFFFFFFF or C.text
  local tx = x + 12
  if ic then icon(dl, ic, x + 12, y + (h - 16) / 2, col); tx = x + 40 end
  local cw = 0
  local cs
  if count then
    cs = tostring(count)
    ImGui.PushFont(ctx, fontSmall)
    cw = ImGui.CalcTextSize(ctx, cs)
    ImGui.DrawList_AddText(dl, x + w - cw - 10, y + (h - 12) / 2, active and 0xFFFFFFCC or C.text3, cs)
    ImGui.PopFont(ctx)
  end
  local size, shift = 15, 0
  if magnify then
    -- macOS Dock-style: the row under the mouse grows most, its neighbours a little, falling off smoothly
    local f = 0
    if ImGui.IsWindowHovered(ctx) then
      local mx, my = ImGui.GetMousePos(ctx)
      if mx and mx >= x and mx <= x + w then
        local d = math.abs(my - (y + h / 2)) / h
        if d < 3 then f = math.exp(-(d * d) / (2 * 0.8 * 0.8)) end
      end
    end
    f = animate(id .. "#dock", f)
    size = 15 + 10 * f
    shift = 4 * f
  end
  ImGui.PushFont(ctx, fontNav)
  local maxW = w - (tx - x) - cw - 18 - shift
  local txt = ellipsize(label, maxW * 15 / size)
  ImGui.PopFont(ctx)
  ImGui.DrawList_AddTextEx(dl, fontNav, size, tx + shift, y + (h - size) / 2 - 1, col, txt)
  return clicked
end

local function sideItem(label, cat, count, ic)
  local dev = cat:match("^dev:(.+)$")
  local active = dev and (category == "devs" and devSel[dev]) or (category == cat)
  if itemButton("##side_" .. cat, label, count, active, ic, dev ~= nil) then
    if dev then
      local mods = ImGui.GetKeyMods(ctx)
      local cmd = (mods & ImGui.Mod_Ctrl) ~= 0 or (mods & ImGui.Mod_Super) ~= 0
      local shift = (mods & ImGui.Mod_Shift) ~= 0
      if category ~= "devs" then devSel = {} end
      if shift and devAnchor then
        local a, b
        for k, d in ipairs(visibleDevs) do
          if d == devAnchor then a = k end
          if d == dev then b = k end
        end
        if a and b then
          if not cmd then devSel = {} end
          for k = math.min(a, b), math.max(a, b) do devSel[visibleDevs[k]] = true end
        end
      elseif cmd then
        devSel[dev] = (not devSel[dev]) or nil
        devAnchor = dev
      else
        devSel = { [dev] = true }; devAnchor = dev
      end
      if next(devSel) then category = "devs" else category = "all" end
    else
      category = cat; devSel = {}
    end
    dirty = true; sel = 1; selectOnly(nil); autoPicked = false
  end
  local fname = cat:match("^folder:(.+)$")
  if fname then
    if drag and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenBlockedByActiveItem) then dropFolder = fname end
    if ImGui.BeginPopupContextItem(ctx) then
      local fo = findFolder(fname)
      if fo then
        captureMenu(pluginsOfFolder(fo))
        ImGui.Separator(ctx)
        if ImGui.MenuItem(ctx, "Match track names...") then
          queue(function()
            local ok, kws = reaper.GetUserInputs("Tracks for tag " .. fo.name, 1,
              "Track name words (comma separated):,extrawidth=420", table.concat(fo.kw or {}, ", "))
            if ok then fo.kw = parseKw(kws); saveFolders(); ctxTrackKey = nil end
          end)
        end
        if ImGui.MenuItem(ctx, "Rename...") then
          queue(function()
            local ok, nn = reaper.GetUserInputs("Rename tag", 1, "Tag name:,extrawidth=180", fo.name)
            nn = ok and nn:gsub("^%s+", ""):gsub("%s+$", "") or ""
            if nn ~= "" and not findFolder(nn) then
              if category == "folder:" .. fo.name then category = "folder:" .. nn end
              fo.name = nn; saveFolders(); dirty = true
            end
          end)
        end
        if ImGui.MenuItem(ctx, "Delete tag") then
          local _, idx = findFolder(fname)
          table.remove(folders, idx); saveFolders()
          if category == cat then category = "all" end
          dirty = true
        end
      end
      ImGui.EndPopup(ctx)
    end
  end
  if dev and ImGui.BeginPopupContextItem(ctx) then
    local list = {}
    if category == "devs" and devSel[dev] then for d in pairs(devSel) do list[#list + 1] = d end else list = { dev } end
    local dset = {}
    for _, d in ipairs(list) do dset[d] = true end
    captureMenu(pluginsOfDevs(dset))
    ImGui.Separator(ctx)
    if #list > 1 then
      if ImGui.MenuItem(ctx, ("Merge %d brands..."):format(#list)) then
        local l, d = list, dev
        queue(function() askMergeDevs(l, d) end)
      end
      ImGui.Separator(ctx)
    end
    if #list == 1 then
      if ImGui.MenuItem(ctx, "Rename brand...") then local d = dev; queue(function() askRenameDev(d) end) end
      local renamed = false
      for o in pairs(devOrigs[dev] or {}) do if o ~= dev then renamed = true end end
      if renamed and ImGui.MenuItem(ctx, "Restore original names (un-merge)") then local d = dev; queue(function() renameDev(d, nil) end) end
      ImGui.Separator(ctx)
    end
    if ImGui.BeginMenu(ctx, "Formats") then                -- ticked = shown for this brand
      local fm = {}
      for _, d in ipairs(list) do for f in pairs(devFormats[d] or {}) do fm[f] = true end end
      for _, f in ipairs({ "VST3", "AU", "CLAP", "VST", "LV2", "JS", "DX" }) do
        if fm[f] then
          local shown, n = 0, 0
          for _, d in ipairs(list) do
            if devFormats[d] and devFormats[d][f] then
              n = n + 1
              if not hidFmt[d .. "|" .. f] then shown = shown + 1 end
            end
          end
          if ImGui.MenuItem(ctx, f .. "##fmtvis", nil, shown == n) then
            local l, ff, hide = list, f, shown == n
            queue(function() setHiddenFormat(l, ff, hide) end)
          end
        end
      end
      ImGui.EndMenu(ctx)
    end
    if ImGui.MenuItem(ctx, #list > 1 and ("Hide %d developers"):format(#list) or ("Hide developer " .. dev)) then
      for _, d in ipairs(list) do setHiddenDev(d, true); devSel[d] = nil end
      if not next(devSel) and category == "devs" then category = "all" end
    end
    ImGui.EndPopup(ctx)
  end
end

local function star(dl, x, y, on)          -- drawn, not a glyph: works with any font
  local cx, cy, R, r = x + 7, y + 7, 6.5, 2.7
  local col = on and C.star or 0xFFFFFF30
  local pts = {}
  for k = 0, 9 do
    local a = -math.pi / 2 + k * math.pi / 5
    local rad = (k % 2 == 0) and R or r
    pts[k] = { cx + rad * math.cos(a), cy + rad * math.sin(a) }
  end
  for k = 0, 9, 2 do
    local p1, p2, p3 = pts[k], pts[(k + 1) % 10], pts[(k + 9) % 10]
    ImGui.DrawList_AddTriangleFilled(dl, p1[1], p1[2], p2[1], p2[2], p3[1], p3[2], col)
    ImGui.DrawList_AddTriangleFilled(dl, cx, cy, p2[1], p2[2], p3[1], p3[2], col)
  end
end

------------------------------------------------------------------ views
local scrollToSel = false
local focusSearch = true

local clipper = ImGui.CreateListClipper(ctx)
ImGui.Attach(ctx, clipper)

-- responsive grid: the size slider sets the card size for a wide window; narrower windows shrink the
-- cards (down to 60%) so more plugins fit, then the row is justified to fill the width exactly
local function gridLayout(w)
  local f = math.max(0.6, math.min(1.0, w / 1200))
  local target = math.max(110, S.thumb * f)
  local gap = math.floor(10 + 6 * f)
  local cols = math.max(1, math.floor((w + gap) / (target + gap)))
  local cardW = math.floor((w - gap * (cols - 1)) / cols)
  return cardW, cols, gap
end

local function drawCard(dl, p, x0, y0, cardW, cardH, imgH, t, isSel)
  local k = 1 + 0.15 * t                                     -- magnify
  local w, h = cardW * k, cardH * k
  local x, y = x0 - (w - cardW) / 2, y0 - (h - cardH) / 2
  local ih = imgH * k
  if t > 0 then                                              -- soft shadow grows with the lift
    local a = math.floor(110 * t)
    ImGui.DrawList_AddRectFilled(dl, x + 2, y + 10 * t, x + w - 2, y + h + 14 * t, a, 14)
  end
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, t > 0 and C.cardHi or C.card, 12)
  local img = getImage(p)
  if img then
    local iw, ihh = ImGui.Image_GetSize(img)
    if not iw or iw <= 0 or not ihh or ihh <= 0 then iw, ihh = w, ih end
    local s = math.max(w / iw, ih / ihh)                     -- fill, crop to the top of the plugin UI
    local uw, uh = math.min(1, w / (iw * s)), math.min(1, ih / (ihh * s))
    local u0 = (1 - uw) / 2
    if ImGui.DrawList_AddImageRounded then
      ImGui.DrawList_AddImageRounded(dl, img, x, y, x + w, y + ih, u0, 0, u0 + uw, uh, 0xFFFFFFFF, 12,
        ImGui.DrawFlags_RoundCornersTop)
    else
      ImGui.DrawList_AddImage(dl, img, x, y, x + w, y + ih, u0, 0, u0 + uw, uh, 0xFFFFFFFF)
    end
  else
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + ih, C.ph, 12, ImGui.DrawFlags_RoundCornersTop)
    ImGui.PushFont(ctx, fontHead)
    local ini = initials(p)
    local tw, th = ImGui.CalcTextSize(ctx, ini)
    ImGui.DrawList_AddTextEx(dl, fontHead, 30 * k, x + (w - tw * k) / 2, y + (ih - th * k) / 2, 0xFFFFFF26, ini)
    ImGui.PopFont(ctx)
  end
  ImGui.DrawList_AddTextEx(dl, font, 14 * k, x + 12 * k, y + ih + 9 * k, C.text, ellipsize(p.base, cardW - 38))
  ImGui.PushFont(ctx, fontSmall)
  local sub = ellipsize((p.dev ~= "" and (p.dev .. "  /  ") or "") .. p.fmt .. (p.inst and "i" or ""), cardW - 24)
  ImGui.PopFont(ctx)
  ImGui.DrawList_AddTextEx(dl, fontSmall, 12 * k, x + 12 * k, y + ih + 27 * k, C.text3, sub)
  star(dl, x + w - 24 * k, y + ih + 9 * k, favSet[p.name])
  local tg = tagsOf(p.name)
  if #tg > 0 then                                             -- tag chips over the top of the image
    ImGui.PushFont(ctx, fontSmall)
    local cx, cy = x + 8 * k, y + 8 * k
    for i, nm in ipairs(tg) do
      local tw = ImGui.CalcTextSize(ctx, nm) * k
      if cx + tw + 14 * k > x + w - 8 * k then
        if i > 1 then break end
        nm = ellipsize(nm, (w - 30 * k) / k); tw = ImGui.CalcTextSize(ctx, nm) * k
      end
      ImGui.DrawList_AddRectFilled(dl, cx, cy, cx + tw + 12 * k, cy + 18 * k, 0x101012D0, 9 * k)
      ImGui.DrawList_AddRect(dl, cx, cy, cx + tw + 12 * k, cy + 18 * k, 0xFFFFFF22, 9 * k, 0, 1)
      ImGui.DrawList_AddTextEx(dl, fontSmall, 12 * k, cx + 6 * k, cy + 2.5 * k, C.text2 or C.text, nm)
      cx = cx + tw + 17 * k
    end
    ImGui.PopFont(ctx)
  end
  if isSel then ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, C.accent, 12, 0, 2)
  else ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, C.edge, 12, 0, 1) end
end

local function gridView(w)
  local cardW, cols, gap = gridLayout(w - 4)
  local imgH = math.floor(cardW * 0.62)
  local cardH = imgH + 48
  local rows = math.ceil(#results / cols)
  local dl = ImGui.GetWindowDrawList(ctx)
  local deferred = {}
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, gap, gap)      -- row pitch must equal what the clipper is told
  ImGui.ListClipper_Begin(clipper, rows, cardH + gap)
  if scrollToSel then ImGui.ListClipper_IncludeItemByIndex(clipper, (sel - 1) // cols, (sel - 1) // cols + 1) end
  while ImGui.ListClipper_Step(clipper) do
    local r0, r1 = ImGui.ListClipper_GetDisplayRange(clipper)
    for r = r0, r1 - 1 do
      for c = 0, cols - 1 do
        local i = r * cols + c + 1
        local p = results[i]
        if not p then break end
        if c > 0 then ImGui.SameLine(ctx, 0, gap) end
        local x, y = ImGui.GetCursorScreenPos(ctx)
        ImGui.InvisibleButton(ctx, "##c" .. i, cardW, cardH)
        if ImGui.IsItemActive(ctx) and ImGui.IsMouseDragging(ctx, 0, 6) then drag = p end
        local hov = ImGui.IsItemHovered(ctx)
        if ImGui.IsItemClicked(ctx, 0) then clickSelect(i) end
        if hov and ImGui.IsMouseDoubleClicked(ctx, 0) then pending = { p, "tracks" } end
        contextMenu(p)
        if scrollToSel and i == sel then ImGui.SetScrollHereY(ctx, 0.5); scrollToSel = false end
        -- card (hovered / animating cards are drawn last so the magnified one sits on top)
        local isSel = msel[p.name] or (nsel == 0 and i == sel)
        local t = animate("card" .. p.name, hov and 1 or 0)
        if t > 0.001 then deferred[#deferred + 1] = { p, x, y, t, isSel }
        else drawCard(dl, p, x, y, cardW, cardH, imgH, 0, isSel) end
      end
    end
  end
  ImGui.PopStyleVar(ctx)
  table.sort(deferred, function(a, b) return a[4] < b[4] end)
  for _, d in ipairs(deferred) do drawCard(dl, d[1], d[2], d[3], cardW, cardH, imgH, d[4], d[5]) end
end

local function listView(w)
  local rowH = 26
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 2)          -- row pitch must equal what the clipper is told
  ImGui.ListClipper_Begin(clipper, #results, rowH + 2)
  if scrollToSel then ImGui.ListClipper_IncludeItemByIndex(clipper, sel - 1, sel) end
  while ImGui.ListClipper_Step(clipper) do
    local r0, r1 = ImGui.ListClipper_GetDisplayRange(clipper)
    for i = r0 + 1, r1 do
      local p = results[i]
      if ImGui.Selectable(ctx, "##r" .. i, msel[p.name] or (nsel == 0 and i == sel), ImGui.SelectableFlags_AllowDoubleClick, 0, rowH) then
        clickSelect(i)
        if ImGui.IsMouseDoubleClicked(ctx, 0) then pending = { p, "tracks" } end
      end
      if ImGui.IsItemActive(ctx) and ImGui.IsMouseDragging(ctx, 0, 6) then drag = p end
      contextMenu(p)
      if scrollToSel and i == sel then ImGui.SetScrollHereY(ctx, 0.5); scrollToSel = false end
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local x2 = select(1, ImGui.GetItemRectMax(ctx))
      local ty = y1 + (rowH - ImGui.GetTextLineHeight(ctx)) / 2
      star(dl, x1 + 6, ty, favSet[p.name])
      local right = (p.dev ~= "" and p.dev or "") .. "   " .. p.fmt .. (p.inst and "i" or "")
      ImGui.PushFont(ctx, fontSmall)
      local rw = ImGui.CalcTextSize(ctx, right)
      ImGui.DrawList_AddText(dl, x2 - rw - 8, ty + 1, C.text3, right)
      ImGui.PopFont(ctx)
      ImGui.DrawList_AddText(dl, x1 + 28, ty, C.text, ellipsize(p.base, (x2 - x1) - rw - 50))
    end
  end
  ImGui.PopStyleVar(ctx)
end

------------------------------------------------------------------ main loop
local showSettings = false

local function handleKeys(cols)
  local mods = ImGui.GetKeyMods(ctx)
  local cmd = (mods & ImGui.Mod_Ctrl) ~= 0 or (mods & ImGui.Mod_Super) ~= 0
  local shift = (mods & ImGui.Mod_Shift) ~= 0
  local n = #results
  local step = (S.images and cols) or 1
  local function move(d) if n > 0 then sel = math.min(n, math.max(1, sel + d)); scrollToSel = true; selectOnly(results[sel]) end end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then move(step) end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then move(-step) end
  if S.images and ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow) and not ImGui.IsAnyItemActive(ctx) then move(1) end
  if S.images and ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow) and not ImGui.IsAnyItemActive(ctx) then move(-1) end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter) then
    local mode = cmd and "items" or (shift and "input" or "tracks")
    local list = selectedList()
    if #list == 0 and results[sel] then list = { results[sel] } end
    if #list > 0 then pending = { list[1], mode, list } end
  end
  if cmd and ImGui.IsKeyPressed(ctx, ImGui.Key_F) then focusSearch = true end
  if cmd and ImGui.IsKeyPressed(ctx, ImGui.Key_A) and not ImGui.IsAnyItemActive(ctx) then
    msel = {}; nsel = 0
    for _, q in ipairs(results) do msel[q.name] = true; nsel = nsel + 1 end
  end
  if cmd and ImGui.IsKeyPressed(ctx, ImGui.Key_D) and results[sel] then
    local p = results[sel]; favSet[p.name] = (not favSet[p.name]) or nil; saveFav(); dirty = true
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    if query ~= "" then query = ""; dirty = true; focusSearch = true else return "close" end
  end
end

local function categoryTitle()
  if category == "all" then return "ALL PLUGINS"
  elseif category == "fav" then return "FAVOURITES"
  elseif category == "recent" then return "RECENT"
  elseif category == "fx" then return "EFFECTS"
  elseif category == "inst" then return "INSTRUMENTS"
  elseif category == "hidden" then return "HIDDEN"
  elseif category == "devs" then
    local n, one = 0, nil
    for d in pairs(devSel) do n = n + 1; one = d end
    return n == 1 and one:upper() or (n .. " BRANDS")
  end
  local k, v = category:match("^(%w+):(.+)$")
  if k == "folder" then return "#" .. v:upper() end
  if k then return v:upper() end
  return category:upper()
end

local function frameUI()
  ImGui.SetNextWindowSize(ctx, 980, 640, ImGui.Cond_FirstUseEver)
  ImGui.PushFont(ctx, font)
  local nc, nv = pushStyle()
  local visible, open = ImGui.Begin(ctx, SCRIPT, true, ImGui.WindowFlags_NoCollapse)
  local action
  if visible then
    if dirty then rebuild() end
    hoverSelf = ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_RootAndChildWindows | ImGui.HoveredFlags_AllowWhenBlockedByActiveItem)
    local availW, availH = ImGui.GetContentRegionAvail(ctx)

    -- top bar: search · view toggles
    if focusSearch then ImGui.SetKeyboardFocusHere(ctx); focusSearch = false end
    -- everything right of the search field: Images, Follow track, Sort, [size slider], Settings
    local reserve = 400 + (S.images and 118 or 0)
    ImGui.SetNextItemWidth(ctx, math.max(120, availW - reserve))
    local changed, q = ImGui.InputTextWithHint(ctx, "##search", "Search plugins, developers, formats...", query,
      ImGui.InputTextFlags_AutoSelectAll)
    if changed then query = q; dirty = true; sel = 1 end
    ImGui.SameLine(ctx)
    local rv
    rv, S.images = ImGui.Checkbox(ctx, "Images", S.images); if rv then saveSettings() end
    ImGui.SameLine(ctx)
    rv, S.follow = ImGui.Checkbox(ctx, "Follow track", S.follow)
    if rv then saveSettings(); ctxTrackKey = nil end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Show the tag that matches the selected track's name (Recent for unknown tracks)") end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 112)
    local SORTS = { { "name", "Name" }, { "brand", "Brand" }, { "type", "Type" } }
    local cur = "Name"
    for _, o in ipairs(SORTS) do if o[1] == S.sort then cur = o[2] end end
    if ImGui.BeginCombo(ctx, "##sort", "Sort: " .. cur) then
      for _, o in ipairs(SORTS) do
        if ImGui.Selectable(ctx, o[2], S.sort == o[1]) then S.sort = o[1]; saveSettings(); dirty = true end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SameLine(ctx)
    if S.images then
      ImGui.SetNextItemWidth(ctx, 110)
      rv, S.thumb = ImGui.SliderInt(ctx, "##size", S.thumb, 120, 320, "")
      if ImGui.IsItemDeactivatedAfterEdit(ctx) then saveSettings() end       -- once, not on every dragged frame
      ImGui.SameLine(ctx)
    end
    if ImGui.Button(ctx, "Settings") then showSettings = not showSettings end

    if showSettings then
      ImGui.PushFont(ctx, fontSmall)
      rv, S.hideDupes = ImGui.Checkbox(ctx, "One entry per plugin", S.hideDupes); if rv then saveSettings(); scan(); dirty = true end
      ImGui.SameLine(ctx); ImGui.SetNextItemWidth(ctx, 90)
      if ImGui.BeginCombo(ctx, "##pref", "Prefer " .. S.prefer) then
        for _, f in ipairs({ "VST3", "AU", "CLAP", "VST" }) do
          if ImGui.Selectable(ctx, f, S.prefer == f) then S.prefer = f; saveSettings(); scan(); dirty = true end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.SameLine(ctx); rv, S.openUI = ImGui.Checkbox(ctx, "Open UI after insert", S.openUI); if rv then saveSettings() end
      ImGui.SameLine(ctx); rv, S.closeAfter = ImGui.Checkbox(ctx, "Close after insert", S.closeAfter); if rv then saveSettings() end
      ImGui.SameLine(ctx); if ImGui.Button(ctx, "Images folder") then openFolder(IMG_DIR) end
      ImGui.SameLine(ctx)
      local nimg = 0
      for _ in pairs(imgFiles) do nimg = nimg + 1 end
      ImGui.SameLine(ctx)
      local nbad = 0
      for _ in pairs(imgBad) do nbad = nbad + 1 end
      ImGui.TextDisabled(ctx, ("loaded %d  failed %d  unmatched %d  broken %d"):format(imgStat.loaded, imgStat.failed, #imgOrphans, nbad))
      if #imgOrphans > 0 and ImGui.IsItemHovered(ctx) and ImGui.BeginTooltip(ctx) then
        for k = 1, math.min(15, #imgOrphans) do ImGui.Text(ctx, imgOrphans[k]) end
        if #imgOrphans > 15 then ImGui.TextDisabled(ctx, ("... and %d more"):format(#imgOrphans - 15)) end
        ImGui.EndTooltip(ctx)
      end
      if ImGui.Button(ctx, ("Reload images (%d)"):format(nimg)) then
        imgStat.loaded, imgStat.failed, imgStat.err = 0, 0, ""
        for k in pairs(imgCache) do dropImage(k) end
        scanImages()
      end
      ImGui.SameLine(ctx); if ImGui.Button(ctx, "Rescan") then scan(); scanImages(); dirty = true end
      ImGui.SameLine(ctx)
      if not batch and IS_MAC and ImGui.Button(ctx, ("Capture missing images (%d listed)"):format(#results)) then local l = results; queue(function() startBatch(l) end) end
      local nskip = 0
      for _ in pairs(skipCap) do nskip = nskip + 1 end
      if nskip > 0 then
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, ("Retry %d skipped"):format(nskip)) then skipCap = {}; writeList("skipCapture", {}) end
      end
      ImGui.PopFont(ctx)
    end

    local _, restH = ImGui.GetContentRegionAvail(ctx)
    local footH = 22
    local sideW = math.floor(math.max(150, math.min(420, S.sideW, availW - 260)))

    -- sidebar
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 10, 12)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 4, 3)
    if ImGui.BeginChild(ctx, "side", sideW, restH - footH, 0, 0) then
      sideItem("All plugins", "all", nil, "grid")
      sideItem("Favourites", "fav", #favList > 0 and #favList or nil, "star")
      sideItem("Recent", "recent", nil, "clock")
      sideItem("Effects", "fx", nil, "fx")
      sideItem("Instruments", "inst", nil, "keys")
      local nh = 0
      for _ in pairs(hidPlug) do nh = nh + 1 end
      for _ in pairs(hidDev) do nh = nh + 1 end
      for _ in pairs(hidFmt) do nh = nh + 1 end
      if nh > 0 then sideItem("Hidden", "hidden", nh, "eye")
      elseif category == "hidden" then category = "all"; dirty = true end
      if category == "hidden" then
        ImGui.PushFont(ctx, fontSmall)
        for d in pairs(hidDev) do
          ImGui.TextDisabled(ctx, "   " .. d); ImGui.SameLine(ctx)
          if ImGui.SmallButton(ctx, "show##hd" .. d) then setHiddenDev(d, false) end
        end
        ImGui.PopFont(ctx)
      end

      -- section header with an optional small control on the right
      local function header(txt, ctl)
        ImGui.Dummy(ctx, 0, 10)
        ImGui.PushFont(ctx, fontSmall); ImGui.TextColored(ctx, C.text3, "  " .. txt); ImGui.PopFont(ctx)
        if ctl then
          ImGui.SameLine(ctx, sideW - 42)
          local x, y = ImGui.GetCursorScreenPos(ctx)
          local clicked = ImGui.InvisibleButton(ctx, "##hdr" .. txt, 18, 16)
          local hov = ImGui.IsItemHovered(ctx)
          local dl = ImGui.GetWindowDrawList(ctx)
          local col = hov and C.text or C.text3
          if ctl == "plus" then
            ImGui.DrawList_AddLine(dl, x + 9, y + 3, x + 9, y + 15, col, 1.5)
            ImGui.DrawList_AddLine(dl, x + 3, y + 9, x + 15, y + 9, col, 1.5)
          else
            icon(dl, ctl, x + 1, y, col)
          end
          ImGui.Dummy(ctx, 0, 2)
          return clicked, hov
        end
        ImGui.Dummy(ctx, 0, 2)
      end

      if header("Tags", "plus") then queue(function() newFolder(nil) end) end
      dropFolder = nil
      for _, fo in ipairs(folders) do sideItem(fo.name, "folder:" .. fo.name, fo.n, "tag") end
      if #folders == 0 then
        ImGui.PushFont(ctx, fontSmall); ImGui.TextDisabled(ctx, "   drag plugins here or press +"); ImGui.PopFont(ctx)
      end

      header("Formats")
      for _, f in ipairs({ "VST3", "AU", "CLAP", "VST", "LV2", "JS" }) do
        if formatsPresent[f] then sideItem(f, "fmt:" .. f, nil, "format") end
      end

      local sortClick, sortHov = header("Brands", "sort")
      if sortClick then S.brandSort = S.brandSort == "name" and "count" or "name"; saveSettings() end
      if sortHov then ImGui.SetTooltip(ctx, S.brandSort == "name" and "Sorted A-Z  (click: by plugin count)" or "Sorted by plugin count  (click: A-Z)") end
      ImGui.SetNextItemWidth(ctx, -1)
      local bch, bq = ImGui.InputTextWithHint(ctx, "##brandsearch", "Search brands", brandQuery)
      if bch then brandQuery = bq end
      ImGui.Dummy(ctx, 0, 2)
      visibleDevs = {}
      local bql = brandQuery:lower()
      for _, d in ipairs(devList) do
        if not hidDev[d] and (bql == "" or d:lower():find(bql, 1, true)) then visibleDevs[#visibleDevs + 1] = d end
      end
      if S.brandSort == "count" then
        table.sort(visibleDevs, function(a, b)
          if devCounts[a] ~= devCounts[b] then return devCounts[a] > devCounts[b] end
          return a:lower() < b:lower()
        end)
      end
      for _, d in ipairs(visibleDevs) do sideItem(d, "dev:" .. d, devCounts[d]) end
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleVar(ctx, 2)
    ImGui.PopStyleColor(ctx)

    -- draggable splitter
    ImGui.SameLine(ctx, 0, 0)
    do
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      local sh = restH - footH
      ImGui.InvisibleButton(ctx, "##splitter", 8, sh)
      local hov, act = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
      if hov or act then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW) end
      if act then
        local dx = ImGui.GetMouseDelta(ctx)
        if dx ~= 0 then S.sideW = math.max(150, math.min(420, S.sideW + dx)); splitDirty = true end
      elseif splitDirty then
        splitDirty = false; saveSettings()
      end
      local t = animate("##splitter", (hov or act) and 1 or 0)
      if t > 0 then
        local col = act and C.accent or ((math.floor(0x50 * t) & 0xFF) | 0xFFFFFF00)
        ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx), sx + 4, sy + 6, sx + 4, sy + sh - 6, col, act and 2 or 1.5)
      end
    end
    ImGui.SameLine(ctx, 0, 0)

    -- results
    local mainW = availW - sideW - 8
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.bg)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 22, 18)
    local resOpen = ImGui.BeginChild(ctx, "results", mainW, restH - footH, 0, 0)
    ImGui.PopStyleVar(ctx)
    if resOpen then
      local wx, wy = ImGui.GetWindowPos(ctx)
      local ww, wh = ImGui.GetWindowSize(ctx)
      drawTopo(ImGui.GetWindowDrawList(ctx), wx, wy, ww, wh)
      local w = select(1, ImGui.GetContentRegionAvail(ctx))
      -- big section title
      ImGui.PushFont(ctx, fontHead)
      ImGui.Text(ctx, ellipsize(categoryTitle(), w))
      ImGui.PopFont(ctx)
      ImGui.PushFont(ctx, fontSmall)
      if autoPicked and ctxTrackName then
        if ctxFolder and category == "folder:" .. ctxFolder.name then
          ImGui.TextColored(ctx, C.accent, "Suggested for track \"" .. ctxTrackName .. "\"")
        elseif category == "recent" then
          ImGui.TextColored(ctx, C.text2 or C.text3, "No tag for track \"" .. ctxTrackName .. "\"  -  showing recent")
        end
      end
      ImGui.TextColored(ctx, C.text3, ("%d plugin%s%s"):format(#results, #results == 1 and "" or "s",
        query ~= "" and ('  -  matching "' .. query .. '"') or ""))
      ImGui.PopFont(ctx)
      ImGui.Dummy(ctx, 0, 8)
      if #results == 0 then
        local _, ah = ImGui.GetContentRegionAvail(ctx)
        ImGui.PushFont(ctx, fontHeadXL)
        local t = "NOTHING HERE"
        local tw, th = ImGui.CalcTextSize(ctx, t)
        ImGui.SetCursorPos(ctx, (ww - tw) / 2, math.max(ImGui.GetCursorPosY(ctx), wh / 2 - th))
        ImGui.Text(ctx, t)
        ImGui.PopFont(ctx)
        ImGui.PushFont(ctx, fontSmall)
        local sub = query ~= "" and "Nothing matches your search." or "This section is empty."
        local sw = ImGui.CalcTextSize(ctx, sub)
        ImGui.SetCursorPosX(ctx, (ww - sw) / 2)
        ImGui.TextColored(ctx, C.text2, sub)
        ImGui.PopFont(ctx)
      elseif S.images then
        action = gridView(w)
      else
        action = listView(w)
      end
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx)

    -- footer
    ImGui.PushFont(ctx, fontSmall)
    local now = reaper.time_precise()
    if batch then
      ImGui.TextColored(ctx, C.text2, ("Capturing %d / %d   %s"):format(batch.i, #batch.list, batch.p and batch.p.base or ""))
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Stop") then stopBatch() end
    elseif status ~= "" and now - statusT < 4 then
      ImGui.TextColored(ctx, C.text2, ellipsize(status, availW - 120))
    else
      ImGui.TextDisabled(ctx, ellipsize(("%d plugins     Enter: track   Cmd+Enter: item   Shift+Enter: input FX   Cmd/Shift-click: multi-select   Right-click: tags, images, hide")
        :format(#results), availW - 120))
    end
    do                                                   -- donate pill, right end of the footer
      local label = "Donate"
      local tw = ImGui.CalcTextSize(ctx, label)
      local bw, bh = tw + 34, 20
      local padX = ImGui.GetStyleVar(ctx, ImGui.StyleVar_WindowPadding)
      ImGui.SameLine(ctx, math.max(0, ImGui.GetWindowWidth(ctx) - padX - bw))
      local bx, by = ImGui.GetCursorScreenPos(ctx)
      if ImGui.InvisibleButton(ctx, "##donate", bw, bh) then openURL(DONATE_URL) end
      local hov = ImGui.IsItemHovered(ctx)
      if hov then
        ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
        ImGui.SetTooltip(ctx, "Like the browser? Support its development\n" .. DONATE_URL)
      end
      local t = animate("##donate", hov and 1 or 0)
      local dl = ImGui.GetWindowDrawList(ctx)
      local by2 = by - 1
      ImGui.DrawList_AddRectFilled(dl, bx, by2, bx + bw, by2 + bh, t > 0 and C.accent or C.card, bh / 2)
      if t == 0 then ImGui.DrawList_AddRect(dl, bx, by2, bx + bw, by2 + bh, C.line, bh / 2, 0, 1) end
      local hc = t > 0 and 0xFFFFFFFF or 0xFF5A7AFF
      icon(dl, "heart", bx + 8, by2 + 2.5, hc)
      ImGui.DrawList_AddText(dl, bx + 26, by2 + (bh - ImGui.GetTextLineHeight(ctx)) / 2, t > 0 and 0xFFFFFFFF or C.text2, label)
    end
    ImGui.PopFont(ctx)

    local _, cols = gridLayout(mainW - 48)
    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then
      action = handleKeys(cols) or action
    end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, nv)
  ImGui.PopStyleColor(ctx, nc)
  ImGui.PopFont(ctx)
  return open and action ~= "close"
end

local function dropAtMouse(p)
  local mx, my = reaper.GetMousePosition()
  local item, take = reaper.GetItemFromPoint(mx, my, true)
  if item and take then return insertTo(p, nil, take) end
  local tr = reaper.GetTrackFromPoint(mx, my)
  if tr then return insertTo(p, tr, nil) end
  say("Drop on a track, mixer strip or item")
end

local function loop()
  frame = frame + 1
  loadsThisFrame = 0
  releaseGraveyard()
  local keep = frameUI()
  if drag then
    local down = ImGui.IsMouseDown(ctx, 0)
    if reaper.JS_Mouse_GetState then down = (reaper.JS_Mouse_GetState(1) & 1) == 1 end
    if down then
      if ImGui.BeginTooltip(ctx) then ImGui.Text(ctx, "+ " .. drag.base); ImGui.EndTooltip(ctx) end
    else
      if dropFolder then
        local fo = findFolder(dropFolder)
        local list = msel[drag.name] and selectedList() or { drag }
        if fo then addToFolder(fo, list) end
      elseif not hoverSelf then dropAtMouse(drag) end   -- released outside the browser: drop on REAPER
      drag = nil
    end
  end
  if batch then stepBatch() end
  -- smart context: follow the selected track
  local now = reaper.time_precise()
  if S.follow and now - ctxCheckT > 0.25 then
    ctxCheckT = now
    local tr = reaper.GetSelectedTrack2(0, 0, true) or reaper.GetLastTouchedTrack()
    local key
    if tr then
      local _, nm = reaper.GetTrackName(tr)
      key = reaper.GetTrackGUID(tr) .. "|" .. (nm or "")
    end
    if key ~= ctxTrackKey then
      ctxTrackKey = key
      local fo, nm
      if tr then
        fo, nm = matchFolderForTrack(tr)
        if not fo then local _, tn = reaper.GetTrackName(tr); nm = tn end
      end
      ctxFolder, ctxTrackName = fo, nm
      if fo then
        category = "folder:" .. fo.name; devSel = {}; dirty = true; sel = 1; selectOnly(nil); autoPicked = true
      elseif tr and #recentList > 0 then          -- unfamiliar track: offer what was used lately
        category = "recent"; devSel = {}; dirty = true; sel = 1; selectOnly(nil); autoPicked = true
      elseif autoPicked then
        category = "all"; dirty = true; autoPicked = false
      end
    end
  end
  if #later > 0 then
    local q = later; later = {}
    for _, fn in ipairs(q) do fn() end
  end
  if pending then
    local p, mode, list = pending[1], pending[2], pending[3] or { pending[1] }
    pending = nil
    local okAny = false
    for _, q in ipairs(list) do okAny = insert(q, mode) or okAny end
    if okAny and S.closeAfter then keep = false end
  end
  if keep then reaper.defer(loop) end
end

scan()
scanImages()
do
  local crashed = reaper.GetExtState(EXT, "batchCurrent")
  if crashed ~= "" then
    skipCap[crashed] = true
    local t = {}
    for k in pairs(skipCap) do t[#t + 1] = k end
    writeList("skipCapture", t)
    setS("batchCurrent", "")
    say("Last capture stopped on \"" .. crashed:gsub("|.*", "") .. "\" - it will be skipped from now on")
  end
  for i = reaper.CountTracks(0) - 1, 0, -1 do              -- leftover temp track from an interrupted run
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == "LKSHV FX Browser capture" or nm == "LG FX Browser capture" then reaper.DeleteTrack(tr) end
  end
end
reaper.defer(loop)
