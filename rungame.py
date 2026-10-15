from rules import Game
from flask import Flask, render_template, jsonify
from apscheduler.schedulers.background import BackgroundScheduler
import time
import httpx  # Changed from requests to aiohttp/httpx for async support
import threading
from TikTokLive import TikTokLiveClient
from TikTokLive.events import ConnectEvent, CommentEvent, GiftEvent

app = Flask(__name__)
game_instance = Game()

tiktok_users = {}
last_round = 0

def reset_dic():
    """Clear the registration list the moment a new round starts."""
    global last_round
    if game_instance.state()["round_number"] > last_round:
        tiktok_users.clear()
        last_round = game_instance.state()["round_number"]


async def check_roblox_username(username: str):
    """Ask Roblox's API whether `username` is a real account asynchronously."""
    url = "https://users.roblox.com/v1/usernames/users"
    payload = {"usernames": [username], "excludeBannedUsers": False}
    try:
        # Use an async client so it doesn't freeze the TikTok event loop
        async with httpx.AsyncClient() as client_http:
            response = await client_http.post(url, json=payload)
            if response.status_code == 200:
                data = response.json().get("data", [])
                return bool(data)
            else:
                print(f"Roblox API error: status {response.status_code}")
                return False
    except Exception as e:
        print(f"Network error checking Roblox username: {e}")
        return False


# ---------------------------------------------------------- TikTok events
# Removed the '@' from the username
client = TikTokLiveClient(unique_id="@your_tiktok_username")

def run_tiktok_forever():
    while True:
        try:
            print("Connecting to TikTok...")
            client.run()  # Use the global client that has the event handlers attached
        except Exception as e:
            print(f"TikTok connection dropped: {e}")
        print("Reconnecting in 5 seconds...")
        time.sleep(5)


@client.on(ConnectEvent)
async def on_connect(event: ConnectEvent):
    print(f"Connected to @{event.unique_id}")


@client.on(CommentEvent)
async def on_comment(event: CommentEvent):
    now = time.time()
    reset_dic()
    print(event.user.nickname, "->", event.comment)

    is_valid = await check_roblox_username(event.comment)   
    if is_valid:
        if event.user.nickname in tiktok_users:
            return   
        tiktok_users[event.user.nickname] = event.comment
        game_instance.chat(event.comment, now)


@client.on(GiftEvent)
async def on_gift(event: GiftEvent):
    reset_dic()
    if event.repeat_end:
        total_coins = event.repeat_count * event.gift.diamond_count
        if event.user.nickname in tiktok_users:
            roblox_user = tiktok_users[event.user.nickname]
            game_instance.gift(roblox_user, total_coins)
        print(f"{event.user.nickname} sent {event.repeat_count}x {event.gift.name} = {total_coins} coins")


# ---------------------------------------------------------- keep the game ticking
def run_forever():
    game_instance.tick(0.5)

scheduler = BackgroundScheduler()


# ---------------------------------------------------------- Flask routes
@app.route("/data")
def data():
    return jsonify({"state": game_instance.state()})


@app.route('/')
def home():
    return render_template('index.html')


@app.route('/chat/<username>')
def test_chat(username):
    game_instance.chat(username, time.time())
    return f"chat registered: {username}"


@app.route('/gift/<username>/<coins>')
def test_gift(username, coins):
    game_instance.gift(username, int(coins))
    return f"gift registered: {username} +{coins}"


if __name__ == '__main__':
    client_thread = threading.Thread(target=run_tiktok_forever, daemon=True)
    client_thread.start()

    scheduler.add_job(id='tick_job', func=run_forever, trigger='interval', seconds=0.5)
    scheduler.start()

    app.run(debug=True, use_reloader=False)
