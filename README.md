TikTok LIVE Tug of War

A live, chat-and-gift-controlled tug-of-war game: TikTok LIVE comments and gifts drive a game running in Python, and a Roblox Studio script pulls the live game state over HTTP to animate it in real time — characters grow with gifts, a crown follows the top gifter, the overall biggest gifter becomes a giant dancing "cosmic entity," and the arena escalates into a lighting/fog/ music "overtime" state as a round nears its end.

How it fits together
TikTok LIVE  --(comments / gifts)-->  server.py (Flask + TikTokLive)
                                           |
                                      rules.py (Game state: rope position,
                                      strength, eliminations, winner)
                                           |
                                      GET /data  (JSON state)
                                           |
                                      Roblox Studio (main.lua, polling
                                      HttpService every 0.5s) -> renders
                                      everything in the 3D arena
rules.py — pure game logic, no networking. Tracks team strength (diminishing returns via sqrt(coins)), rope position, eliminations, and round/overtime/winner state. Has its own test suite (python rules.py test).
server.py — Flask app that connects to TikTok LIVE via TikTokLive, feeds comments/gifts into a Game instance, ticks it on a background scheduler, and exposes the state as JSON at /data.
main.lua — the Roblox Studio server script. Polls /data, spawns/ scales/positions avatars, draws the rope, runs the crown/cosmic-entity/ winner-banner/overtime-atmosphere/music/timer systems.
GiftEffects.lua — all the per-gift visual/audio effects (sparkles, shockwaves, lightning, meteors, persistent auras, the tug-animation system).
RagdollModule.lua — turns an eliminated character's Motor6D joints into ball-socket constraints so they ragdoll off the platform instead of just vanishing.
SkyArenaFloat.lua — gentle idle bob/sway for anything tagged FloatingDecor in the arena (sky rocks, clouds).
Setup
Python side
   pip install flask apscheduler requests TikTokLive

Edit server.py and replace "@your_tiktok_username" with the real, currently live TikTok username you want to connect to.

Run it:

   python server.py

This starts the Flask server on localhost:5000 and connects to TikTok LIVE in a background thread.

Exposing the server to a published Roblox game Roblox Studio's Play mode can reach http://localhost:5000 directly because the server and client share your machine. A published game runs on Roblox's own cloud servers, though, so localhost there resolves to Roblox's server, not yours — it can never see your Flask app. The fix is a public tunnel (ngrok or similar):
   ngrok http 5000

This gives you a public HTTPS URL that forwards to your local server.

Roblox Studio side Put main.lua, GiftEffects.lua, and RagdollModule.lua in ServerScriptService (the two modules as ModuleScripts, main.lua as a regular Script), and SkyArenaFloat.lua wherever you want the sky decor logic to run. Near the top of main.lua, set:
lua
   local DATA_ENDPOINT = "https://YOUR_NGROK_URL_HERE/data"

to your own ngrok URL (or http://localhost:5000/data if you're only testing in Studio's Play mode, never a published build).

You'll also need, in your Studio place:

A Part named TimerAnchor in Workspace, placed where you want the round timer/overtime popup to appear.
An OvertimeSky instance in ReplicatedStorage (the sky swapped in during overtime).
Any instances you want to bob gently tagged FloatingDecor via CollectionService.
A genuinely hard problem this solved

The trickiest bug wasn't in the game logic — it was architectural. Everything worked perfectly in Studio's Play mode, then broke the moment the game was published and run for real. The cause: Play mode runs the server and client on the same machine, so localhost means "this computer." A published game's server lives on Roblox's cloud infrastructure, where localhost means "Roblox's own machine" — it has no way to reach a Flask app running on a developer's laptop. Solving it meant recognizing this wasn't a bug in the code at all, but a difference in where the code runs, and fixing it with a tunnel (ngrok) rather than anything in the script itself.

Notes
Music tracks referenced by rbxassetid:// in main.lua are licensed via Monstercat SoundScout's "Copyright Safe" program for livestream use — the raw audio files themselves are intentionally not part of this repo (see .gitignore).
rules.py has a full test suite covering joining/team-balancing, gifting, strength, chat cooldowns, round/overtime/draw resolution, and the elimination system. Run with python rules.py test.
