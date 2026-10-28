# Driving Path of Building from Claude (MCP server)

`src/PoBMCP.lua` runs Path of Building without its window and exposes it as an
[MCP](https://modelcontextprotocol.io) server. Claude (Claude Code or Claude Desktop) can then load builds,
change passives, items, gems and config, and read the numbers PoB calculates, all through tool calls.
The numbers are PoB's own: the server runs the same calculation code as the app.

PoB starts once per session (about 5 seconds to load the tree and game data) and stays running, so every
call after that is fast.

## Tools

| Tool | What it does |
| --- | --- |
| `load_build` | Load a build from a `.xml` file, XML text or a PoB share code |
| `new_build` | Start an empty build with a class, ascendancy and level |
| `save_build` | Get a share code, and optionally write the build to a `.xml` file you can open in PoB |
| `list_build_files` | List `.xml` builds in a folder (default `POB_BUILDS_DIR`) |
| `get_summary` | Class, ascendancy, main skill, gems, items (with mods PoB can't parse), keystones, notables, masteries, loadouts |
| `get_stats` | DPS, hit/DoT DPS, EHP, max hit per damage type and the lowest one, pools, resistances, block, suppression, regen, costs, attributes, charges; optionally PoB's sidebar text and raw output fields |
| `search_passives` | Find nodes by name or stat text, with how many points they take to reach |
| `edit_tree` | Allocate/deallocate nodes, choose mastery effects, change class/ascendancy/bloodline, import a tree URL, set level |
| `get_items`, `equip_item`, `unequip_item` | Read items as text, equip pasted item text (in-game Ctrl+C format works), empty a slot |
| `get_skills`, `set_skill_group`, `set_gem`, `remove_skill_group`, `set_main_skill` | Socket groups and gems, and which skill/part the DPS is for |
| `get_config`, `set_config` | Configuration tab options (enemy type, charges, buffs...) and custom modifier lines |
| `loadouts`, `compare_loadouts` | List, switch and create loadouts; calculate every loadout side by side |
| `what_if` | Try several scenarios (any mix of the changes above) and get the deltas; the build is restored afterwards |
| `rank_passives` | Score reachable notables, keystones and mastery effects by gain per point, or what each allocated node is worth |
| `rank_gems` | Score every support gem (or a list) in one socket at once |
| `compare_items` | Score many candidate items against what is equipped |
| `ablation` | Remove one gem, item, keystone, notable or mastery at a time and measure the loss |
| `check_ssf_rules` | Check items and gems against SSF crafting rules (no legacy items or gems, influences, eldritch implicits, chase uniques, Archmage, awakened levels, jewel mods) |

Every tool that changes the build returns what changed (DPS, EHP, max hits, resistances, ...) so Claude
sees the effect of each step without asking again.

`rank_passives`, `rank_gems`, `compare_items` and `ablation` use PoB's fast comparison path, the same one
behind the power report and the gem/item sorting in the app, so they score hundreds of options in one call.
Rough timings on a large endgame build: ablation and gem ranking under 2 seconds, item comparison well under
a second, a full passive scan (about 900 options) around 12 seconds, and `what_if` about 1 to 1.5 seconds per
scenario.

## Setup on Windows

1. **Get this repository** somewhere on your machine, for example `C:\Users\<you>\src\PathOfBuilding`:

   ```
   git clone https://github.com/TomaDev1/PathOfBuilding
   ```

2. **Install 64-bit LuaJIT** and make sure `luajit` is on your `PATH`. The simplest route is
   [Scoop](https://scoop.sh): `scoop install luajit`. Any LuaJIT 2.1 build works. The server uses the
   `zlib1.dll` and `lua-utf8.dll` that ship in this repository's `runtime` folder, so nothing else is needed.

3. **Check it works:**

   ```
   luajit C:\Users\<you>\src\PathOfBuilding\src\PoBMCP.lua --selftest
   ```

   It should print `Path of Building 2.xx headless OK: ...`. The working directory doesn't matter.

4. **Connect Claude.**

   - **Claude Code**, inside this repository: the `.mcp.json` at the repository root already registers the
     server; approve it when Claude Code asks. Elsewhere:

     ```
     claude mcp add path-of-building -e POB_BUILDS_DIR="C:\Users\<you>\Documents\Path of Building\Builds" -- luajit C:\Users\<you>\src\PathOfBuilding\src\PoBMCP.lua
     ```

   - **Claude Desktop**: Settings, Developer, Edit Config, and add to `claude_desktop_config.json`:

     ```json
     {
       "mcpServers": {
         "path-of-building": {
           "command": "luajit",
           "args": ["C:\\Users\\<you>\\src\\PathOfBuilding\\src\\PoBMCP.lua"],
           "env": { "POB_BUILDS_DIR": "C:\\Users\\<you>\\Documents\\Path of Building\\Builds" }
         }
       }
     }
     ```

     Use the full path to `luajit.exe` as `command` if it isn't on `PATH`. Restart Claude Desktop afterwards.

On macOS and Linux the steps are the same with LuaJIT from your package manager (`brew install luajit`,
`apt install luajit`); zlib comes from the system.

## Safety

The server never writes to a build file unless `save_build` is called with a `path`. (When PoB runs from
a source checkout it is in dev mode, which normally autosaves the open build to its file whenever another
build is opened; the server turns that off, because what-if scenarios reload builds constantly.)
Loading a build reads it; to keep Claude's edits, save to a new file in your Builds folder and open it in PoB.

## Using it well

- Check `get_config` first. Enemy type (Pinnacle/Uber), charges, flasks and conditional buffs can make
  numbers look much better than they play.
- Make sure the main skill and skill part are right (`get_skills`, `set_main_skill`). Some skills default
  to their best-case part or maximum stages.
- Look at `unsupportedMods` on items: lines PoB can't parse do nothing in the calculation.
- Compare at the same level and point budget, and look at `minMaxHit` (the smallest max hit across damage
  types), not just EHP.
- `ablation` finds what actually scales a build; `rank_gems`, `compare_items` and `rank_passives` find the
  next upgrade; `what_if` with `custom_mods` prices hypothetical stats ("what is +1% max fire res worth?").
- Use loadouts for progression tiers (league start, early maps, endgame, chase) and `compare_loadouts`
  to verify the whole file.

When game knowledge is missing, look it up instead of guessing:
[poewiki.net](https://www.poewiki.net) for mechanics,
[poedb.tw](https://poedb.tw/us/) for mined mods, bases, gems and uniques,
[craftofexile.com](https://www.craftofexile.com) for mod pools, weights and crafting methods, and
[poe.ninja](https://poe.ninja/builds) for meta builds and prices.

## Limitations

- The server doesn't download anything. For a pobb.in or pastebin link, fetch the raw build code and pass
  it to `load_build`.
- PoB features that only exist as GUI dialogs (timeless jewel search, trade queries, item crafting
  windows) are not exposed. Paste finished item text instead.
- `check_ssf_rules` can't see mod tiers, so it can't tell an elevated or a perfect-tier mod from a normal
  one. Its chase unique list is short and lives in `src/Agent/SSFRules.lua`; extend it per call with
  `chase_uniques` or allow items with `allowed_uniques`.
- The PoB app ships a LuaJIT with a small syntax extension (`+=`). The one place `src` used it has been
  rewritten so stock LuaJIT can run PoB; if an upstream merge reintroduces it, `--selftest` will fail with
  a syntax error pointing at the line.

## For developers

- `src/Agent/Headless.lua` boots PoB headless with stdout kept clean for the protocol and working
  zlib (build codes).
- `src/Agent/BuildAPI.lua` holds the tools. Each takes a table and returns a plain table, so it can also be
  used from scripts or tests: `LoadModule("Agent/BuildAPI").Call("get_stats", { })`.
- `src/Agent/MCPServer.lua` is the JSON-RPC/MCP layer. Set `POB_MCP_DEBUG=1` to get Lua tracebacks for tool
  errors on stderr.
- Tests: `spec/System/TestAgentAPI_spec.lua`, run with the rest of the suite (`busted --lua=luajit`).
