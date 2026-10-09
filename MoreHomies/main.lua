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
local cap        = math.max(1, math.min(10, math.floor(wml.setting("homies_cap", 10))))
local mission    = math.floor(wml.setting("mission_homies", 10))
local hud_heads  = math.max(3, math.min(6, math.floor(wml.setting("hud_heads", 6))))
local range_mult = wml.setting("follower_range_multiplier", 2.0)
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
  want = math.max(1, math.min(cap, math.floor(want)))
  ctx:set_r(3, want)
  if debug and (vanilla ~= last_vanilla or want ~= last_given or in_mission ~= last_mission) then
    last_vanilla, last_given, last_mission = vanilla, want, in_mission
    wml.log(string.format("party max: game said %d%s, given %d (party now %d)",
      vanilla, in_mission and " (mission full party)" or "", want, to_int(wml.read_u32(p + COUNT))))
  end
end)

-- ------------------------------------------------------------ street recruit

local recruits, refusals = 0, 0
wml.hook(RECRUIT_ONE, function(ctx)
  local p, npc = ctx:r(3), ctx:r(4)
  if not in_single_player(p) or npc == 0 then ctx:call_original() return end
  local count = to_int(wml.read_u32(p + COUNT))
  if count < 3 then ctx:call_original() return end            -- the game handles this itself
  local max = to_int(call(ctx, PARTY_MAX, p))                 -- through the hook above
  if count >= max then
    refusals = refusals + 1
    ctx:call_original()                                       -- full: let the game refuse as usual
    return
  end
  if (call(ctx, CAN_RECRUIT, p, npc) & 0xFF) == 0 then ctx:set_r(3, 0) return end
  local added = (call(ctx, PARTY_ADD, p, npc, 1) & 0xFF) ~= 0
  if added then
    recruits = recruits + 1
    if to_int(call(ctx, HUD_SLOT, npc)) ~= -1 then call(ctx, HUD_ADD, npc) end
    if debug then wml.log(string.format("recruit: follower %d of %d added past the game's 3", count + 1, max)) end
  end
  ctx:set_r(3, added and 1 or 0)
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

-- ------------------------------------------------------------ ambient gangs (research)
--
-- The ambient population replaces people as they despawn: each removed
-- person queues a request for their category (law 2/3, friendly gang 4/5,
-- Los Carnales 6/7, Vice Kings 8/9, Rollerz 10/11; the odd one is the
-- "flagged" variant), and the queue processor (0x82417218) spawns them
-- subject to a per-category cap read from 0x827AD004 + 4 * category,
-- against live counts at 0x82962D90 + 12 * category. Not yet confirmed in
-- game: with debug on, both rows are logged every few seconds so the
-- model can be checked. ambient_gang_cap, when above 0, is written into
-- the gang categories' caps; leave it at 0 until the log confirms them.
local CAT_CAPS, CAT_COUNTS, CATEGORIES = 0x827AD004, 0x82962D90, 12
local gang_cap = math.floor(wml.setting("ambient_gang_cap", 0))
local caps_written = false
local function apply_gang_caps()
  if gang_cap <= 0 or caps_written then return end
  caps_written = true
  for cat = 4, 11 do wml.write_u32(CAT_CAPS + 4 * cat, gang_cap) end
  wml.log(string.format("ambient gangs: caps for categories 4-11 set to %d", gang_cap))
end
local last_caps_log = os.time()
local function log_categories()
  local now = os.time()
  if now - last_caps_log < 5 then return end
  last_caps_log = now
  local caps, counts = {}, {}
  for cat = 0, CATEGORIES - 1 do
    caps[#caps + 1] = tostring(to_int(wml.read_u32(CAT_CAPS + 4 * cat)))
    counts[#counts + 1] = tostring(to_int(wml.read_u32(CAT_COUNTS + 12 * cat)))
  end
  wml.log("ambient caps " .. table.concat(caps, ",") .. " counts " .. table.concat(counts, ","))
end

-- ------------------------------------------------------------ logging

local last_count, last_second = nil, os.time()
wml.on_frame(function()
  if not debug and gang_cap <= 0 then return end
  local now = os.time()
  if now == last_second then return end
  last_second = now
  local p = wml.read_u32(PLAYER)
  if p == 0 or wml.read_u32(p + 72) ~= 1 then return end
  apply_gang_caps()
  log_categories()
  local count = to_int(wml.read_u32(p + COUNT))
  if debug and count ~= last_count then
    last_count = count
    wml.log(string.format("party: %d followers (recruitable %d, mission flag %s, extra recruits %d, refusals %d)", count,
      wml.read_u8(RECRUITABLE), ((wml.read_u8(p + MISSION_FLAG) & 0x80) ~= 0) and "on" or "off", recruits, refusals))
  end
end)

wml.log(string.format("Party size %d at the first award, +%d per award, cap %d, missions %d, HUD heads %d (debug=%s)",
  start, per_award, cap, mission, hud_heads, tostring(debug)))
