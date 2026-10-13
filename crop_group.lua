--[[

  Crop Group:

  Script to copy the crop of an image to all other images in its group;
  particularly useful for RAW+JPEG shooters who want both files of a pair to
  carry the same crop.

  Only the crop module is touched, the rest of the history stack of the other
  images is left alone.


  Installation and usage:

    1. Copy this file into ~/.config/darktable/lua/contrib/

    2. Add `require "contrib/crop_group"` to a new line in ~/.config/darktable/luarc
       (or enable it with script_manager)

    3. Restart darktable

    4. Assign a keyboard shortcut to the action via settings > shortcuts > lua
       ("crop group")

    5. Crop an image as usual, then press the shortcut, either in the darkroom
       or in the lighttable (with the cropped image selected or hovered).  The
       crop is copied to every other member of the group.


  How it works:

    The Lua API has no direct access to module parameters.  Instead the script
    reads the crop entry from the XMP sidecar of the cropped image, merges it
    into a copy of the XMP sidecar of each other group member (replacing any
    crop that member has) and loads the result with image:apply_sidecar().
    The crop parameters are plain fractions of the image, so they are valid for
    any image of the same shape, e.g. a RAW and its JPEG.


  Requirements:

    * sidecar files must be written (preferences > storage > xmp > write sidecar
      file for each image), and have to be up to date.  In the darkroom the
      script switches to the lighttable and back so that darktable flushes the
      current history first.

    * the images should have the same shape.  The crop is not rotated.

  Author:  based on rate_group by Dom H (dom@hxy.io)
  License: GPLv2

]]

local dt = require "darktable"
local du = require "lib/dtutils"

du.check_min_api_version("9.0.0", "crop_group")

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = _("crop group"),
  purpose = _("copy the crop of an image to all images in its group"),
  author = "based on rate_group by Dom H (dom@hxy.io)",
  help = "https://docs.darktable.org/lua/stable/lua.scripts.manual/scripts/contrib/crop_group"
}

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them

local MODULE <const> = "crop_group"

-- - - - - - - - - - - - - - - - - - - - - - - -
-- X M P  H E L P E R S
-- - - - - - - - - - - - - - - - - - - - - - - -

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("a")
  f:close()
  return data
end

local function write_file(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

-- split an xmp document into its history entries
-- returns a table of {text, operation, priority, active}, and the history_end
local function parse_history(xml)
  local body = xml:match("<darktable:history>(.-)</darktable:history>")
  local history_end = tonumber(xml:match('darktable:history_end="(%d+)"'))
  if not body or not history_end then
    return nil
  end
  local entries = {}
  for li in body:gmatch("<rdf:li%s.-/>") do
    local num = tonumber(li:match('darktable:num="(%d+)"'))
    table.insert(entries, {
      text = li,
      operation = li:match('darktable:operation="([^"]*)"'),
      priority = tonumber(li:match('darktable:multi_priority="(%d+)"')) or 0,
      active = num ~= nil and num < history_end,
    })
  end
  return entries, history_end
end

local function is_crop(e)
  return e.operation == "crop" and e.priority == 0
end

-- the crop entry that is in effect in an xmp document, or nil
local function find_crop(xml)
  local entries = parse_history(xml)
  if not entries then return nil end
  local found = nil
  for _, e in ipairs(entries) do
    if is_crop(e) and e.active then
      found = e
    end
  end
  if found and found.text:match('darktable:enabled="1"') then
    return found
  end
  return nil
end

-- return the xml of target with its crop replaced by crop_entry
local function merge_crop(target_xml, crop_entry)
  local entries = parse_history(target_xml)
  if not entries then return nil end

  -- keep the active entries only (that is what darktable shows) minus any crop
  local kept = {}
  for _, e in ipairs(entries) do
    if e.active and not is_crop(e) then
      table.insert(kept, e.text)
    end
  end
  table.insert(kept, crop_entry.text)

  local renumbered = {}
  for i, text in ipairs(kept) do
    local n = tostring(i - 1)
    text = text:gsub('darktable:num="%d+"', function() return 'darktable:num="' .. n .. '"' end, 1)
    table.insert(renumbered, "     " .. text)
  end
  local body = "\n    <rdf:Seq>\n" .. table.concat(renumbered, "\n") .. "\n    </rdf:Seq>\n   "

  local xml = target_xml
  xml = xml:gsub("(<darktable:history>).-(</darktable:history>)",
    function(a, b) return a .. body .. b end, 1)
  xml = xml:gsub('darktable:history_end="%d+"',
    function() return 'darktable:history_end="' .. #kept .. '"' end, 1)
  -- the hashes no longer match, let darktable recompute them
  xml = xml:gsub('%s*darktable:history_basic_hash="[^"]*"', "")
  xml = xml:gsub('%s*darktable:history_current_hash="[^"]*"', "")
  return xml
end

-- - - - - - - - - - - - - - - - - - - - - - - -
-- M A I N  P R O G R A M
-- - - - - - - - - - - - - - - - - - - - - - - -

-- the image currently shown in the darkroom, tracked via event
local current_image = nil

local function log(fmt, ...)
  dt.print_log(MODULE .. ": " .. string.format(fmt, ...))
end

local function fail(fmt, ...)
  dt.print_error(MODULE .. ": " .. string.format(fmt, ...))
end

-- copy the crop of source to every group member not in skip
-- returns number of images changed, number of failures
local function copy_crop(source, skip)
  local source_xml, err = read_file(source.sidecar)
  if not source_xml then
    fail("cannot read %s: %s", source.sidecar, tostring(err))
    return 0, 1
  end
  local crop = find_crop(source_xml)
  if not crop then
    fail("%s has no active crop in its sidecar", source.filename)
    return 0, 1, true
  end

  local changed, failed = 0, 0
  for _, target in ipairs(source:get_group_members()) do
    if target.id ~= source.id and not skip[target.id] then
      local target_xml, terr = read_file(target.sidecar)
      local merged = target_xml and merge_crop(target_xml, crop)
      if not merged then
        fail("cannot process sidecar of %s: %s", target.filename, tostring(terr or "no history"))
        failed = failed + 1
      else
        local tmp = os.tmpname() .. ".xmp"
        local ok, werr = write_file(tmp, merged)
        if ok then
          target:apply_sidecar(tmp)
          target:drop_cache()
          changed = changed + 1
          log("copied crop from %s to %s", source.filename, target.filename)
        else
          fail("cannot write %s: %s", tmp, tostring(werr))
          failed = failed + 1
        end
        os.remove(tmp)
      end
    end
  end
  return changed, failed
end

local function crop_group()
  local in_darkroom = dt.gui.current_view() == dt.gui.views.darkroom

  local sources = {}
  if in_darkroom then
    local img = current_image or dt.gui.action_images[1]
    if img then sources = {img} end
  else
    for _, img in ipairs(dt.gui.action_images) do
      table.insert(sources, img)
    end
  end
  if #sources == 0 then
    dt.print(_("crop group: no image to copy the crop from"))
    return
  end

  -- images that are themselves sources must not be overwritten
  local skip = {}
  for _, img in ipairs(sources) do skip[img.id] = true end

  -- make darktable write the history of the open image to its sidecar
  if in_darkroom then
    dt.gui.current_view(dt.gui.views.lighttable)
    dt.control.sleep(1000)
  end

  local changed, failed, missing = 0, 0, 0
  for _, img in ipairs(sources) do
    local c, f, nocrop = copy_crop(img, skip)
    changed = changed + c
    failed = failed + f
    if nocrop then missing = missing + 1 end
  end

  if in_darkroom then
    dt.gui.views.darkroom.display_image(sources[1])
  end

  if missing > 0 and changed == 0 then
    dt.print(_("crop group: no crop found, is the image cropped and are sidecar files written?"))
  elseif failed > 0 then
    dt.print(string.format(_("crop group: %d image(s) cropped, %d failed, see the log"), changed, failed))
  else
    dt.print(string.format(_("crop group: cropped %d image(s)"), changed))
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - -
-- D A R K T A B L E  I N T E G R A T I O N
-- - - - - - - - - - - - - - - - - - - - - - - -

local function destroy()
  dt.destroy_event(MODULE, "shortcut")
  dt.destroy_event(MODULE, "darkroom-image-loaded")
end

script_data.destroy = destroy

-- the callback receives (event, image) in the documented API and
-- (event, clean, image) in some darktable versions, so take the last argument
dt.register_event(MODULE, "darkroom-image-loaded",
  function(event, ...)
    local args = table.pack(...)
    local image = args[args.n]
    if type(image) == "userdata" then
      current_image = image
    end
  end
)

local busy = false

dt.register_event(MODULE, "shortcut",
  function(event, shortcut)
    if busy then return end
    busy = true
    local ok, err = pcall(crop_group)
    busy = false
    if not ok then
      fail("%s", tostring(err))
      dt.print(_("crop group failed, see the log"))
    end
  end, _("crop group")
)

return script_data
