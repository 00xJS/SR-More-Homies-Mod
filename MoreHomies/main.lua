-- More Homies - runtime part.
--
-- The game keeps the party on the player object: a count at +2096 and a
-- list of ten 20-byte slots from +2100 (the forced-add path in the game's
-- own party code caps at 10, which is where the hard limit comes from).
-- Three places in the game hold the party to 3:
--
--  1. 0x824836E8 (player) -> max followers. Every recruit path asks it:
--     0 unless recruiting is on (byte 0x827ACBD7, party_set_recruitable);
--     3 while a mission has called party_allow_max_followers(true) (bit
--     0x80 of the byte at player+3592); 0 until the tss01 unlockable is
--     yours; otherwise 1 + the number of Hood_Awards (gameplay_constants
--     .xtbl) whose Required share of owned hoods you have reached; and a
--     per-mode table (0, 3, 10) when player+4012 is not 1 (single player).
--     Hooked: the game answers, then the answer is rewritten.
--  2. 0x8247CC48 (player, npc) -> recruited?, the street recruit (D-pad
--     up). It refuses outright when the party already has 3, before it
--     even asks (1). Hooked: when the party has 3 or more but room under
--     our maximum, the same steps the game takes for a smaller party are
--     run here: the eligibility test (0x8247CAB0), the party insert
--     (0x82483828, forced=1, which also sets the follower up) and the HUD
--     head registration (0x822D0188 / 0x822D1418).
--  3. 0x822DEA08 (player, f1 alpha): the HUD draws min(count, 3) heads from
--     the first three list entries into three fixed screen slots, then an
--     "empty slot" marker (slot index 4 + heads, up to 6) while the party
--     is under the maximum. Hooked: after the game's own pass, a second
--     pass is run with list entries 4-6 moved to the front, the count cut
--     by 3, the three head positions moved left by the span of the first
--     three, and the maximum reported as 0 so no marker is drawn.
--     Everything is put back before returning.

local PLAYER      = 0x8309ABEC  -- pointer to the player object (0 = no game loaded)
local PARTY_MAX   = 0x824836E8  -- (player) -> max followers
local RECRUIT_ONE = 0x8247CC48  -- (player, npc) -> 1 if recruited
local CAN_RECRUIT = 0x8247CAB0  -- (player, npc) -> eligible?
local PARTY_ADD   = 0x82483828  -- (player, npc, forced) -> added?
local HUD_SLOT    = 0x822D0188  -- (npc) -> HUD head slot or -1
local HUD_ADD     = 0x822D1418  -- (npc) registers the head
local HUD_HEADS   = 0x822DEA08  -- (player, f1 alpha) draws follower heads
local RECRUITABLE = 0x827ACBD7  -- byte set by party_set_recruitable
local COUNT, LIST, MISSION_FLAG, MODE = 2096, 2100, 3592, 4012
local ENTRY = 20                -- bytes per party list entry
-- HUD head slot layout: the HIN cluster's parts from user_interface.xtbl,
-- 16 bytes each {x, y, scale, alpha} with x and y as integers. Head j
-- (0-based) uses the part at this base + 16 j: Follower 1 to 3 at x -92,
-- -146 and -199 from the cluster anchor (confirmed from a memory dump).
-- There are no parts for more heads, so the second pass moves the three x
-- offsets left by the span of the first three.
local SLOT_BASE   = 0x8301AF48
-- Per-head fade state the HUD keeps: three arrays of three words.
local FADE_BASE, FADE_BYTES = 0x840B5EB0, 36

local start      = math.floor(wml.setting("homies_start", 10))
local per_award  = math.floor(wml.setting("homies_per_award", 1))
local cap        = math.max(1, math.min(30, math.floor(wml.setting("homies_cap", 10))))
local LIST_MAX   = 10                       -- slots in the game's party list
local list_cap   = math.min(cap, LIST_MAX)  -- what the list may hold
local extra_cap  = cap - list_cap           -- entourage: followers without a list slot
local mission    = math.floor(wml.setting("mission_homies", 10))
local hud_heads  = math.max(3, math.min(6, math.floor(wml.setting("hud_heads", 6))))
local range_mult = wml.setting("follower_range_multiplier", 1.0)
local debug      = wml.setting("debug", false)

local function to_int(v)
  v = v & 0xFFFFFFFF
  if v >= 0x80000000 then v = v - 0x100000000 end
  return v
end

local function in_single_player(p) return p ~= 0 and wml.read_u32(p + MODE) == 1 end

-- Calls a game function with r3..r5 set, on a lowered stack as the trainer
-- does, and gives the registers back afterwards. Returns r3.
local function call(ctx, addr, a, b, c)
  local r1, r3, r4, r5 = ctx:r(1), ctx:r(3), ctx:r(4), ctx:r(5)
  ctx:set_r(1, r1 - 0x1000)
  ctx:set_r(3, a or 0); ctx:set_r(4, b or 0); ctx:set_r(5, c or 0)
  ctx:call(addr)
  local result = ctx:r(3)
  ctx:set_r(1, r1); ctx:set_r(3, r3); ctx:set_r(4, r4); ctx:set_r(5, r5)
  return result
end

-- ------------------------------------------------------------ party maximum

local hud_pass = false   -- true while the HUD's second pass runs
local asking_for_scan = false  -- true while the recruit hook asks for the full cap
local RECRUIT_SCAN_LO, RECRUIT_SCAN_HI = 0x82483DB8, 0x82484548  -- the D-pad recruit routine
local last_vanilla, last_given, last_mission = nil, nil, nil

local function wanted(p, vanilla)
  if (wml.read_u8(p + MISSION_FLAG) & 0x80) ~= 0 then return mission, true end
  return start + (vanilla - 1) * per_award, false            -- vanilla is 1, 2 or 3: awards reached
end

wml.hook(PARTY_MAX, function(ctx)
  local p = ctx:r(3)
  ctx:call_original()
  if hud_pass then ctx:set_r(3, 0) return end
  local vanilla = to_int(ctx:r(3))
  if vanilla <= 0 or not in_single_player(p) then return end  -- recruiting off, not unlocked, or not the single-player rule
  local want, in_mission = wanted(p, vanilla)
  -- The street recruit scan may see the whole cap (it recruits max - count
  -- people, and the recruit hook below places the extras); everything that
  -- writes the list sees at most its 10 slots.
  local lr = ctx:lr()
  local limit = (asking_for_scan or (lr >= RECRUIT_SCAN_LO and lr < RECRUIT_SCAN_HI)) and cap or list_cap
  want = math.max(1, math.min(limit, math.floor(want)))
  ctx:set_r(3, want)
  if debug and (vanilla ~= last_vanilla or want ~= last_given or in_mission ~= last_mission) then
    last_vanilla, last_given, last_mission = vanilla, want, in_mission
    wml.log(string.format("party max: game said %d%s, given %d (party now %d)",
      vanilla, in_mission and " (mission full party)" or "", want, to_int(wml.read_u32(p + COUNT))))
  end
end)

-- ------------------------------------------------------------ street recruit
--
-- Up to the list's 10 slots, recruits past 3 are added the way the game
-- adds them (eligibility, insert, HUD head). Past 10, the entourage: the
-- game's own add routine is run against a temporarily emptied slot 0 that
-- is put back right after, so the follower is set up (leader handle at
-- npc+4128, follower flags, health, weapon, follow-and-fight behaviour)
-- without a list entry. The mod remembers them by handle, releases them on
-- dismiss-all with the game's own dismiss routine (0x82483A60), and
-- forgets the ones that die or despawn. They are not on the HUD, do not
-- take car seats, are not revived, and are never dropped for distance.

local OBJECTS     = 0x830866C8  -- handle table, 16 bytes per entry
local DISMISS_ALL = 0x82483B78  -- (player) dismisses the whole list
local DISMISS_ONE = 0x82483A60  -- (player, npc) undoes the follower setup
local SUPPRESS, SUPPRESS_BIT = 3696, 0x20  -- npc byte and bit set by follower_suppress_distance
local entourage = {}            -- handles of followers without a list slot
local recruits, refusals = 0, 0

local function object_of(handle)
  if handle == 0 then return nil end
  local index = handle & 0xFFFF
  if index >= 4096 then return nil end
  local object = wml.read_u32(OBJECTS + 12 + index * 16)
  if object == 0 or wml.read_u32(object + 68) ~= handle or wml.read_u32(object + 72) ~= 1 then return nil end
  return object
end

local function prune_entourage(p)
  local kept = {}
  for _, h in ipairs(entourage) do
    local o = object_of(h)
    if o and wml.read_u32(o + 4128) == wml.read_u32(p + 68) and wml.read_f32(o + 1912) > 0 then kept[#kept + 1] = h end
  end
  entourage = kept
end

local function ghost_add(ctx, p, npc)
  local saved = {}
  for i = 0, ENTRY - 4, 4 do saved[#saved + 1] = wml.read_u32(p + LIST + i) end
  local count = wml.read_u32(p + COUNT)
  wml.write_u32(p + COUNT, 0)
  local ok = (call(ctx, PARTY_ADD, p, npc, 1) & 0xFF) ~= 0
  wml.write_u32(p + COUNT, count)
  for i = 0, ENTRY - 4, 4 do wml.write_u32(p + LIST + i, saved[i // 4 + 1]) end
  return ok
end

wml.hook(RECRUIT_ONE, function(ctx)
  local p, npc = ctx:r(3), ctx:r(4)
  if not in_single_player(p) or npc == 0 then ctx:call_original() return end
  local count = to_int(wml.read_u32(p + COUNT))
  if count < 3 then ctx:call_original() return end            -- the game handles this itself
  asking_for_scan = true
  local max = to_int(call(ctx, PARTY_MAX, p))                 -- the full cap, through the hook above
  asking_for_scan = false
  local in_list = count < math.min(max, list_cap)
  if not in_list then prune_entourage(p) end
  if not in_list and count + #entourage >= max then
    refusals = refusals + 1
    ctx:call_original()                                       -- full: let the game refuse as usual
    return
  end
  if (call(ctx, CAN_RECRUIT, p, npc) & 0xFF) == 0 then ctx:set_r(3, 0) return end
  if wml.read_u32(npc + 4128) ~= 0 then ctx:set_r(3, 0) return end  -- already following someone
  local added
  if in_list then
    added = (call(ctx, PARTY_ADD, p, npc, 1) & 0xFF) ~= 0
    if added and to_int(call(ctx, HUD_SLOT, npc)) ~= -1 then call(ctx, HUD_ADD, npc) end
  else
    added = ghost_add(ctx, p, npc)
    if added then
      entourage[#entourage + 1] = wml.read_u32(npc + 68)
      -- The per-follower update drops a follower who is far for 15 s and
      -- counts far list members for its warning (so it says 0 for these).
      -- follower_suppress_distance's bit skips that check: set it here.
      wml.write_u8(npc + SUPPRESS, wml.read_u8(npc + SUPPRESS) | SUPPRESS_BIT)
    end
  end
  if added then
    recruits = recruits + 1
    if debug then wml.log(string.format("recruit: follower %d of %d added%s", count + #entourage + (in_list and 1 or 0), max,
      in_list and " past the game's 3" or " to the entourage")) end
  end
  ctx:set_r(3, added and 1 or 0)
end)

-- Hold-to-dismiss clears the list; release the entourage the same way.
wml.hook(DISMISS_ALL, function(ctx)
  local p = ctx:r(3)
  ctx:call_original()
  if #entourage == 0 then return end
  prune_entourage(p)
  for _, h in ipairs(entourage) do
    local o = object_of(h)
    if o then
      call(ctx, DISMISS_ONE, p, o)
      wml.write_u32(o + 4128, 0)
      wml.write_u8(o + SUPPRESS, wml.read_u8(o + SUPPRESS) & ~SUPPRESS_BIT & 0xFF)
    end
  end
  if debug then wml.log(string.format("dismissed %d entourage followers", #entourage)) end
  entourage = {}
end)

-- ------------------------------------------------------------ HUD heads

local fade_extra = {}      -- our own copy of the fade state for heads 4-6
local dumped = false
local function dump_hud()
  if dumped or not debug then return end
  dumped = true
  local words = {}
  for i = 0, 35 do words[#words + 1] = string.format("%.1f", wml.read_f32(0x8301AF08 + i * 4)) end
  wml.log("hud slots @8301AF08: " .. table.concat(words, " "))
end

local function swap_bytes(a, b, n)
  for i = 0, n - 4, 4 do
    local x, y = wml.read_u32(a + i), wml.read_u32(b + i)
    wml.write_u32(a + i, y); wml.write_u32(b + i, x)
  end
end

wml.hook(HUD_HEADS, function(ctx)
  local p = ctx:r(3)
  local alpha = ctx:f(1)
  ctx:call_original()
  if hud_heads <= 3 or not in_single_player(p) then return end
  local count = to_int(wml.read_u32(p + COUNT))
  if count <= 3 then return end
  dump_hud()
  local extra = math.min(count - 3, hud_heads - 3)
  -- Entries 4-6 to the front, count cut, slot layouts 4-6 over 1-3, our fade state in.
  swap_bytes(p + LIST, p + LIST + 3 * ENTRY, 3 * ENTRY)
  wml.write_u32(p + COUNT, extra)
  local saved = {}
  local x0, x1, x2 = to_int(wml.read_u32(SLOT_BASE)), to_int(wml.read_u32(SLOT_BASE + 16)), to_int(wml.read_u32(SLOT_BASE + 32))
  local shift = (x2 - x0) + (x1 - x0)         -- one more step past the third head
  for j = 0, 2 do
    local a = SLOT_BASE + 16 * j
    local x = to_int(wml.read_u32(a))
    saved[#saved + 1] = { a, wml.read_u32(a) }
    wml.write_u32(a, (x + shift) & 0xFFFFFFFF)
  end
  local fade_saved = {}
  for i = 0, FADE_BYTES - 4, 4 do
    fade_saved[#fade_saved + 1] = wml.read_u32(FADE_BASE + i)
    wml.write_u32(FADE_BASE + i, fade_extra[i] or 0)
  end
  hud_pass = true
  ctx:set_r(3, p); ctx:set_f(1, alpha)
  ctx:call_original()
  hud_pass = false
  for i = 0, FADE_BYTES - 4, 4 do
    fade_extra[i] = wml.read_u32(FADE_BASE + i)
    wml.write_u32(FADE_BASE + i, fade_saved[i // 4 + 1])
  end
  for _, s in ipairs(saved) do wml.write_u32(s[1], s[2]) end
  wml.write_u32(p + COUNT, count)
  swap_bytes(p + LIST, p + LIST + 3 * ENTRY, 3 * ENTRY)
end)

-- ------------------------------------------------------------ follower range
--
-- The per-follower check (0x82449168) drops a follower who has been further
-- than 40 m from you for 15 s, unless a mission suppressed it; a second
-- threshold of 20 m is used alongside. Both are squared distances in
-- read-only data, scaled once here.
local ABANDON_SQ, NEAR_SQ = 0x8208966C, 0x82089364   -- 1600.0 and 400.0
if range_mult > 0 and range_mult ~= 1 then
  local a, n = wml.read_f32(ABANDON_SQ), wml.read_f32(NEAR_SQ)
  wml.write_f32(ABANDON_SQ, a * range_mult * range_mult)
  wml.write_f32(NEAR_SQ, n * range_mult * range_mult)
  wml.log(string.format("follower range: %.0f m -> %.0f m", math.sqrt(a), math.sqrt(a) * range_mult))
end

-- ------------------------------------------------------------ ambient gangs
--
-- How the game keeps gang members on the street (see RESEARCH.md):
-- a manager (0x824189E0) ticks every 20 s (next tick time at 0x82832960,
-- game clock at 0x827AA6E0). Each tick it works out which scripted gang
-- groups from pb_sr_city.cts should be active near you, keeps up to 8 of
-- them (slots at 0x83AD2DF0, count +1480), and processes a 24-entry queue
-- of spawn requests (0x83AD2878, count +1368) that spawn a gang car with
-- four members from the "City - Gang - ..." spawn groups at one of those
-- group points. Nine slots (0x82832758, count +516) track the resulting
-- active ambient groups; when a gang member despawns a replacement request
-- is queued. The slot counts are fixed arrays in the engine, so the tick
-- interval is the one knob here: gang_spawn_interval shortens it.
local SPAWN_MANAGER, NEXT_TICK, GAME_CLOCK = 0x824189E0, 0x82832960, 0x827AA6E0
local ACTIVE_GROUPS, QUEUE_COUNT, AMBIENT_SLOTS = 0x83AD33B8, 0x83AD2DD0, 0x8283295C
local interval = wml.setting("gang_spawn_interval", 20)
if interval > 0 and interval < 20 then
  wml.hook(SPAWN_MANAGER, function(ctx)
    ctx:call_original()
    local now, next_tick = to_int(wml.read_u32(GAME_CLOCK)), to_int(wml.read_u32(NEXT_TICK))
    if next_tick - now > interval * 1000 then wml.write_u32(NEXT_TICK, (now + interval * 1000) & 0xFFFFFFFF) end
  end)
end
local last_ambient_log = os.time()
local function log_ambient()
  local now = os.time()
  if now - last_ambient_log < 5 then return end
  last_ambient_log = now
  wml.log(string.format("ambient: %d scripted groups active, %d requests queued, %d ambient slots used",
    to_int(wml.read_u32(ACTIVE_GROUPS)), to_int(wml.read_u32(QUEUE_COUNT)), to_int(wml.read_u32(AMBIENT_SLOTS))))
end

-- ------------------------------------------------------------ logging

local last_count, last_second = nil, os.time()
wml.on_frame(function()
  if not debug then return end
  local now = os.time()
  if now == last_second then return end
  last_second = now
  local p = wml.read_u32(PLAYER)
  if p == 0 or wml.read_u32(p + 72) ~= 1 then return end
  log_ambient()
  prune_entourage(p)
  local count = to_int(wml.read_u32(p + COUNT)) + #entourage
  if debug and count ~= last_count then
    last_count = count
    wml.log(string.format("party: %d followers (%d in the list, %d entourage; recruitable %d, mission flag %s, extra recruits %d, refusals %d)",
      count, count - #entourage, #entourage, wml.read_u8(RECRUITABLE), ((wml.read_u8(p + MISSION_FLAG) & 0x80) ~= 0) and "on" or "off", recruits, refusals))
  end
end)

wml.log(string.format("Party size %d at the first award, +%d per award, cap %d (%d in the list, %d entourage), missions %d, HUD heads %d (debug=%s)",
  start, per_award, cap, list_cap, extra_cap, mission, hud_heads, tostring(debug)))
