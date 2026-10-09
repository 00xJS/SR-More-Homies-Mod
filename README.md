# More Homies

A mod for [Saints Reborn](https://github.com/whompay/SaintsReborn) (Saints
Row, Xbox 360, recompiled for PC) that lets you recruit up to **10 homies**
instead of 1 to 3.

- The game's own progression is kept: `homies_start` as soon as recruiting
  unlocks, `homies_per_award` more at each city-ownership award (25% and
  50% of the hoods), `mission_homies` when a mission hands you a full party.
- The HUD shows up to six follower heads in a row.
- Followers can fall further behind before the game drops them.
- Gang wars bring more gang members and cars, sooner, and the gang hang-out
  spots on the street are always populated.

The game's party list holds 10 followers, which is the hard limit. Private
play only, like any gameplay mod (story co-op and private parties work;
public matches do not).

## Install

1. Copy the `MoreHomies` folder to `dist\mods\` in your Saints Reborn
   folder (`~/SaintsReborn/dist/mods/` on the Mac build).
2. Run Whompay's Mod Loader, tick **More Homies**, press **Play**.

## Settings

Everything is in `MoreHomies/mod.ini` under `[settings]`; restart the game
after changing them.

| Setting | Default | What it does |
|---|---|---|
| `homies_start` | 10 | Party size as soon as recruiting unlocks (the game gives 1) |
| `homies_per_award` | 1 | Added at each city-ownership award |
| `homies_cap` | 10 | Most the party may hold (10 is the game's limit) |
| `mission_homies` | 10 | Party size when a mission gives you a full party |
| `hud_heads` | 6 | Follower heads drawn on the HUD, 3 to 6 |
| `second_award_at`, `third_award_at` | 0.25, 0.5 | Share of hoods owned for each award |
| `follower_range_multiplier` | 2.0 | How far followers may fall behind (1.0 = 40 m) |
| `gang_war_multiplier` | 2.0 | Gang members and cars per notoriety level, and how soon |
| `gang_street_chance` | 1.0 | Chance gang street spots are populated |
| `gang_notoriety_multiplier` | 1.0 | Gang notoriety earned per action |
| `debug` | true | Logs party changes to `mods\wml.log` |

## How it works

`patch.lua` edits the game's tables inside your own packfiles before the
game starts (award thresholds in `gameplay_constants.xtbl`, gang waves in
`notoriety_spawn.xtbl`, street spots in `special_spawns.xtbl`). `main.lua`
hooks three engine functions: the one that decides the party maximum, the
street recruit (which has its own "already 3" refusal), and the HUD head
drawing (run a second time for heads 4 to 6). No game files are shipped.
