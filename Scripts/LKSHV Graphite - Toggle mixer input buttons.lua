-- @description LKSHV Graphite - Toggle mixer input buttons (rec mode / input FX)
-- @version 1.0
-- @author Ilia Lukashev
-- @about
--   For the Lukashev Graphite theme (49+). Shows or hides the record-mode ("IN") and input-FX buttons
--   in the mixer's input section. They are hidden by default.

local NEEDLE = "Mixer rec-mode and input FX buttons"
local found, target = 0, nil
local i = 0
while true do
  local ok, desc, value = reaper.ThemeLayout_GetParameter(i)
  if not ok then break end
  if desc and desc:find(NEEDLE, 1, true) then
    if target == nil then target = (value == 0) and 1 or 0 end
    reaper.ThemeLayout_SetParameter(i, target, true)
    found = found + 1
  end
  i = i + 1
end
if found == 0 then
  reaper.MB("This action needs the Lukashev Graphite theme, build 49 or newer.", "LKSHV Graphite", 0)
else
  reaper.ThemeLayout_RefreshAll()
end
