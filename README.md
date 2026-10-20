# Beast Brawl

A wobbly online brawler in the style of Gang Beasts. Built with Godot 4.7 (GL Compatibility + Jolt physics), runs multiplayer over Supabase Realtime, and deploys to Vercel as a static web build.

## How to play

| Key | Action |
|---|---|
| WASD / arrow keys | Move |
| Space | Jump |
| J / left click | Punch (alternates arms; enough hits knock the target out) |
| K / right click (hold) | Grab (works on opponents, ledges, and the edge of the truck) |
| Grab + Shift / L | Lift / climb. Release the grab to throw |
| Esc | Back to the menu |

Last one standing on the roof wins the round. Each room has its own code (`?room=CODE` link), and **Copy invite link** copies an invite URL.

## Structure

```
scripts/main.gd     Menu/HUD, input, round flow (host-authoritative), bots, camera
scripts/beast.gd    Ragdoll character: balance PD control, hover legs, arm springs, grab joints, punch hit detection, network snapshots
scripts/level.gd    Truck-rooftop arena
scripts/net.gd      Godot <-> JS bridge (Autoload "Net")
web/supanet.js      Supabase Realtime channel (Broadcast + Presence)
web/config.js       Supabase URL / publishable key
```

Netcode: each client simulates only **its own beast's physics** and broadcasts a body-part snapshot 10 times per second (`st`).
Other players appear as kinematic puppets interpolated 140ms behind real time.
Punches are sent to the victim as a `hit` event. Grabs ride along in the state message, and the victim's client applies the pull force.
Round progression (countdown → round start → out → round end) is driven by the earliest player to join the room (the host). If the host leaves, the next player takes over automatically.

## Build and deploy

```bash
./scripts/tools/build_web.sh        # export to build/web
vercel deploy --prod                # vercel.json deploys build/web as-is
```

Vercel doesn't run the Godot build, so run `build_web.sh` again after any code change and commit or deploy `build/web` with it.
The export uses no threads, so no COOP/COEP headers are needed.

Local test: `python3 -m http.server 8060 --directory build/web` → http://localhost:8060

## Notes

- The Supabase project is `beast-brawl` (ref `vvmytjikbnonfszkyufg`). Only Realtime is used; there are no DB tables.
- Free-plan Realtime has a message cap. Up to about 3–4 players per room is comfortable.
- Running from the Godot editor (desktop) works offline only; there you can test with "PRACTICE vs BOTS".
- The default font has no Korean glyphs, so Korean nicknames render as boxes (use English names).
