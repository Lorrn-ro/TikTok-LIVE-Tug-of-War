from TikTokLive import TikTokLiveClient
from TikTokLive.events import ConnectEvent, CommentEvent, GiftEvent

from rules import Game
import time
import math
import random
import requests

import requests  # Make sure this is imported at the very top
game = Game()
client = TikTokLiveClient(unique_id="@robert__369")

tiktok_users = {}
last_round = 0

def reset_dic():
    global last_round
    if (game.state()["round_number"]) > last_round:
        tiktok_users.clear()
        last_round=game.state()["round_number"]

async def check_roblox_username(username: str):
        url = "https://users.roblox.com/v1/usernames/users"
        payload = {
            "usernames": [username],
            "excludeBannedUsers": False
        }
        
        try:
            response = requests.post(url, json=payload)
            if response.status_code == 200:
                data = response.json().get("data", [])
                if data:
                    user_info = data[0]  # Correct!
                    print(f"✅ Account Exists!")
                    print(f"   - Username: {user_info['name']}")
                    print(f"   - Display Name: {user_info['displayName']}")
                    print(f"   - User ID: {user_info['id']}")
                    return True
                else:
                    print(f"❌ The username '{username}' does not exist.")
                    return False
            else:
                print(f"⚠️ Error: API responded with status code {response.status_code}")
                return False
        except requests.exceptions.RequestException as e:
            print(f"🔌 Network Error: {e}")
            return False



@client.on(ConnectEvent)
async def on_connect(event: ConnectEvent):
    print(f"Connected to @{event.unique_id}")

@client.on(CommentEvent)
async def on_comment(event: CommentEvent):
    now = time.time()
    reset_dic()
    if await check_roblox_username(f"{event.comment}"):
            if event.user.nickname in tiktok_users:
                return
            elif event.user.nickname not in tiktok_users:
                tiktok_users[event.user.nickname] = event.comment
                game.chat(event.comment, now)
    else:
        return
        
    print(event.user.nickname, "->", event.comment)

@client.on(GiftEvent)
async def on_gift(event: GiftEvent):
    # Streakable gift: TikTok fires this over and over while they're still
    # sending it. Only act once the streak has actually finished.
    reset_dic()
    if event.gift.streakable and not event.streaking:
        total_coins = event.repeat_count * event.gift.diamond_count
        if event.user.nickname in tiktok_users:

            game.gift(tiktok_users.get(event.user.nickname), total_coins)
        print(f"{event.user.nickname} sent {event.repeat_count}x {event.gift.name} = {total_coins} coins")
    # Non-streakable gift: always a single event, count it right away.
    elif not event.gift.streakable:
        total_coins = event.gift.diamond_count
        if event.user.nickname in tiktok_users:
             game.gift(tiktok_users.get(event.user.nickname), total_coins)
        print(f"{event.user.nickname} sent {event.gift.name} = {total_coins} coins")

if __name__ == '__main__':
    client.run()

    