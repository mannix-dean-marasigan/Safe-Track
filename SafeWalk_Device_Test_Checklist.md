# SafeWalk real-device test (≈15 min per phone)

**Setup (once):** the page must be served over **HTTPS or localhost** — opening the .html file directly (`file://`) may block location.
Easiest: on your PC run `python -m http.server 8000` in the project folder, then use a tunnel that gives HTTPS (e.g. `npx localtunnel --port 8000` or `cloudflared tunnel --url http://localhost:8000`) and open that `https://…` link on the phone.
Add `?safetrackDebug=1` to the URL to show a small debug panel on the map (GPS accuracy/age, speed, heading, progress, off-route distance, water-check state). Take screenshots with it on.
Go outside, clear of tall buildings, for the walking tests.

Legend: ✅ PASS · ❌ FAIL → send the item number + what you sent in the last column.

## A. Android Chrome  /  B. iPhone Safari (same steps)

| # | Tap / do | You should see | PASS if | FAIL if | If it fails, send |
|---|---|---|---|---|---|
| 1 | Open the link → tap **SafeWalk** | Browser asks for location; chip says "GETTING YOUR LOCATION…" | Prompt appears | No prompt and chip stays "GPS OFF" | Screenshot |
| 2 | Tap **Allow** (precise) | Chip → "GPS ACTIVE · ±Xm" within ~15 s, blue dot on map | Dot is on your real position, X < 50 | Dot far from you, or chip stuck | Screenshot with debug panel |
| 3 | Type **SM Megamall** (or a place ~300 m away) → **Go** | Status: Finding → Building → Checking route for water crossings… then a route preview with distance, minutes, turns, "VERIFIED WALKING ROUTE" | Route appears, whole route + flag visible above the bottom panel | Error text, spinner never ends, flag hidden under panel | Screenshot + the status text |
| 4 | Tap **Start SafeWalk** | Full-screen map, zoomed in (~street level), you in the lower-middle, big "in X m / Turn …" card | Blue dot stays on screen, tab bar hidden | Dot off-screen, map jumps around | 10-s screen recording |
| 5 | Walk **100–300 m** | Dot moves smoothly, grey trail behind you, remaining distance falls | Map moves only every few seconds (not every step); no zoom flicker | Map jitters/zooms back and forth | Screen recording + debug-panel screenshot |
| 6 | Reach the first turn | "Now · Turn left/right" with a matching arrow, then next turn line | Arrow matches the real turn | Wrong direction/street | Screenshot + photo of the junction |
| 7 | Drag the map with a finger | Recenter button turns **amber**; map stops following | Map stays where you put it | Map snaps back by itself | Screen recording |
| 8 | Tap **Recenter** (⌖) | Button turns green, map returns to you | Back to following | Nothing happens | Screenshot |
| 9 | Pinch-zoom out/in | Zoom stays where you set it | Zoom not forced back | Zoom keeps changing | Screen recording |
| 10 | Walk ~60 m **away from the route** and keep going ~15 s | "You're off route" + **Recalculate** / **Keep current route** | Appears after ~10 s, not instantly | Never appears, or appears while on the route | Debug-panel screenshot |
| 11 | Tap **Recalculate** | New route from where you stand, navigation continues | New route, still navigating | Error / stops | Screenshot |
| 12 | Lock the phone 20 s, unlock | Chip shows "GPS SIGNAL LOST"/"LAST FIX…" then recovers to ACTIVE | Honest stale state, then recovers; no second GPS indicator | Stays "ACTIVE" while locked, or stuck lost | Screenshot right after unlock |
| 13 | Walk to the destination | "You've arrived" + **Done**; location indicator in the browser goes off | Arrival card stays until you tap Done | No arrival, or GPS stays on | Screenshot |
| 14 | Tap **Done**, then SafeWalk again, **Stop** during a walk | Returns to planner; Stop returns to preview | Clean state each time | Stuck spinner / old route | Screenshot |

Also check on **each** phone: top card isn't hidden by the notch/status bar; the **SOS** and ⌖ buttons are reachable and not under the home bar (note which phone).

## C. Laptop (Chrome/Edge/Safari)

| # | Do | PASS if | FAIL if |
|---|---|---|---|
| 1 | Open SafeWalk, click **Block** on the location prompt | Chip "LOCATION PERMISSION NEEDED", message + **Retry Location**; no route can be planned | A route appears or a fake position is used |
| 2 | Browser settings → allow location → **Retry Location** | Becomes "GPS ACTIVE", or "GPS APPROXIMATE ±hundreds of m" on Wi-Fi-only laptops (this is expected) | Stays blocked after allowing |
| 3 | With approximate location, plan a route | Orange "approximate" notice; dot has a large translucent circle | Shown as precise |
| 4 | Turn Wi-Fi off, plan a route | "Routing unavailable / map-data check unavailable… not verified", **no route drawn** | A route is drawn anyway |
| 5 | Block location, click **Use DEMO LOCATION (preview only)**, plan a route | Amber "DEMO LOCATION — NOT YOUR REAL LOCATION" everywhere; Start says "Use my GPS & start" | Demo looks like real GPS |
| 6 | Open the file directly (`file://`) | Yellow note: serve over localhost/HTTPS | No explanation |

## What to send me when something fails
1. The row number, phone model + browser version.
2. A screenshot (or 10-s screen recording) **with `?safetrackDebug=1` on**.
3. Roughly where you were (no exact address needed) and whether you had mobile data/Wi-Fi.
