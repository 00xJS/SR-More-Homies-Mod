-- More Homies - table part.
--
--   gameplay_constants.xtbl  the three Hood_Awards the game checks when it
--                            works out how many followers you may have (and
--                            when it shows the "You can now have up to ..."
--                            unlocks): each has a Required share of the
--                            city's hoods. The first is 0 and stays 0; the
--                            second and third come from second_award_at and
--                            third_award_at. The game only reads three.
--   notoriety_spawn.xtbl     per gang and notoriety level, how many gang
--                            members and cars come after you and how often
--                            (npc_cap, max_vehicles, max_vehicle_occupants,
--                            min/max_spawn_time). Scaled by gang_war_multiplier.
--   special_spawns.xtbl      the chance that the gang hang-out spots on the
--                            street (Gang Cluster, Gang Standing, ...) are
--                            populated. Set to gang_street_chance.
--   notoriety.xtbl           gang notoriety points per action, so wars start
--                            sooner. Scaled by gang_notoriety_multiplier.
--
-- Both packfiles carry the tables.

local PACKS = { "misc.vpp_xbox2", "misc2.vpp_xbox2" }
local FILE = "gameplay_constants.xtbl"

local second = wml.setting("second_award_at", 0.25)
local third  = wml.setting("third_award_at", 0.5)
local war    = wml.setting("gang_war_multiplier", 2.0)
local street = wml.setting("gang_street_chance", 1.0)
local noto   = wml.setting("gang_notoriety_multiplier", 1.0)
local GANGS  = { "los carnales", "vice lords", "rollers" }

local function fmt(x)
  if x == math.floor(x) then return string.format("%d", x) end
  return (string.format("%.4f", x):gsub("0+$", ""):gsub("%.$", ""))
end

local function patch(xml)
  local table_end = xml:find("</Table>", 1, true) or #xml
  local head, tail = xml:sub(1, table_end - 1), xml:sub(table_end)
  local changed = 0
  head = head:gsub("<Hood_Awards>.-</Hood_Awards>", function(block)
    local i = 0
    return (block:gsub("(<Required>)%s*([%d%.]+)%s*(</Required>)", function(open, value, close)
      i = i + 1
      local new = (i == 2 and second) or (i == 3 and third) or nil
      if new == nil or tonumber(value) == new then return nil end
      changed = changed + 1
      return open .. fmt(new) .. close
    end))
  end, 1)
  return head .. tail, changed
end

-- Replaces the number inside every <tag>...</tag> in `xml` with f(value).
local function map_tag(xml, tag, f)
  local n = 0
  xml = xml:gsub("(<" .. tag .. ">)%s*(%-?[%d%.]+)%s*(</" .. tag .. ">)", function(open, value, close)
    local v = tonumber(value)
    if not v then return nil end
    local new = f(v)
    if new == nil or new == v then return nil end
    n = n + 1
    return open .. fmt(new) .. close
  end)
  return xml, n
end

-- The data part only; the <TableDescription> reuses the tag names (and in
-- notoriety_spawn.xtbl the entries are themselves called <Table>).
local function in_table(xml, f)
  local table_end = xml:find("<TableDescription>", 1, true) or xml:find("</Table>", 1, true) or #xml
  return f(xml:sub(1, table_end - 1)) .. xml:sub(table_end)
end

-- Gang notoriety waves: more people and cars per level, sooner.
local function patch_notoriety_spawn(xml)
  local changed = 0
  if war == 1 then return xml, 0 end
  xml = in_table(xml, function(head)
    for _, gang in ipairs(GANGS) do
      head = head:gsub("(<Name>" .. gang .. "</Name>.-)(<level_info>.-</level_info>%s*</level_info>)", function(before, levels)
        local n
        levels, n = map_tag(levels, "npc_cap", function(v) return math.floor(v * war + 0.5) end); changed = changed + n
        levels, n = map_tag(levels, "max_vehicles", function(v) return math.floor(v * war + 0.5) end); changed = changed + n
        levels, n = map_tag(levels, "max_vehicle_occupants", function(v) return math.min(4, math.floor(v * war + 0.5)) end); changed = changed + n
        levels, n = map_tag(levels, "min_spawn_time", function(v) return math.max(3, math.floor(v / war + 0.5)) end); changed = changed + n
        levels, n = map_tag(levels, "max_spawn_time", function(v) return math.max(5, math.floor(v / war + 0.5)) end); changed = changed + n
        return before .. levels
      end, 1)
    end
    return head
  end)
  return xml, changed
end

-- Gang hang-out spots on the street.
local function patch_special_spawns(xml)
  local changed = 0
  xml = in_table(xml, function(head)
    return (head:gsub("(<Name>Gang [^<]*</Name>.-)(<Spawn_chance>)%s*([%d%.]+)%s*(</Spawn_chance>)", function(before, open, value, close)
      local v = math.max(0, math.min(1, street))
      if tonumber(value) == v then return nil end
      changed = changed + 1
      return before .. open .. fmt(v) .. close
    end))
  end)
  return xml, changed
end

-- Gang notoriety per action.
local function patch_notoriety(xml)
  local changed = 0
  if noto == 1 then return xml, 0 end
  xml = in_table(xml, function(head)
    return (head:gsub("<Gang>.-</Gang>", function(block)
      local n
      block, n = map_tag(block, "Points", function(v) return v * noto end); changed = changed + n
      return block
    end))
  end)
  return xml, changed
end

local FILES = {
  { FILE, patch, string.format("awards at %s and %s", fmt(second), fmt(third)) },
  { "notoriety_spawn.xtbl", patch_notoriety_spawn, "gang waves x" .. fmt(war) },
  { "special_spawns.xtbl", patch_special_spawns, "gang spots at " .. fmt(street) },
  { "notoriety.xtbl", patch_notoriety, "gang notoriety x" .. fmt(noto) },
}
for _, pack in ipairs(PACKS) do
  for _, entry in ipairs(FILES) do
    local name, f, note = entry[1], entry[2], entry[3]
    local xml = wml.packfile_read(pack, name)
    if xml then
      local new, changed = f(xml)
      if changed > 0 then wml.packfile_write(pack, name, new) end
      wml.log(string.format("%s: %s - %d values changed (%s)", pack, name, changed, note))
    end
  end
end
