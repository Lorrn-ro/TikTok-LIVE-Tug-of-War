import math
import random
import sys
from dataclasses import dataclass

# ------------------------------------------------------------------ settings
ROPE_LIMIT = 68             # rope position where a team wins outright
ROUND_SECONDS = 180
OVERTIME_SECONDS = 45
OVERTIME_BAND = 20           # in overtime, rope leaving +-20 ends the round instantly
WINNER_DISPLAY_SECONDS = 5.0

CHAT_PULL = 0.5              # how far one chat message tugs the rope
CHAT_COOLDOWN = 2.0          # seconds between chat-pulls from the same player
FORCE_SCALE = 1.20          # how strongly team strength moves the rope per second

IMBALANCE_RATIO = 3          # join(): strength gap that overrides headcount balancing

ELIMINATION_ZONE = 66      # rope must be at least this far from center
ELIMINATION_INTERVAL = 3   # seconds between eliminations
MIN_TEAM_SIZE = 1            # never eliminate the last player(s) on a team


# ---------------------------------------------------------------------- data
@dataclass
class Player:
    name: str
    team: str                          # "red" or "blue"
    coins: int = 0                     # coins gifted this round
    last_chat_pull: float = -999.0     # time of their last chat pull


def strength(player):
    """Bigger gifters pull harder, with diminishing returns."""
    return 1 + math.sqrt(player.coins)


# ---------------------------------------------------------------------- game
class Game:
    def __init__(self):
        self.players = {}                       # name -> Player
        self.rope = 0.0
        self.time_left = float(ROUND_SECONDS)
        self.overtime_left = float(OVERTIME_SECONDS)
        self.winner = None                      # "red", "blue", "draw" or None
        self.winner_display_left = WINNER_DISPLAY_SECONDS
        self.round_number = 0
        self.eliminated = set()                 # names knocked out this round
        self.elim_timer = ELIMINATION_INTERVAL
        self.biggest_gifter_name = None

    # ---- helpers
    def team_members(self, team):
        return [p for p in self.players.values() if p.team == team]

    def team_strength(self, team):
        return sum(strength(p) for p in self.team_members(team))

    def push(self, team, amount):
        """Move the rope toward a team."""
        self.rope += amount if team == "blue" else -amount

    # ---- things viewers do
    def join(self, name):
        """Headcount balancing by default; strength balancing only when one
        side is severely stronger (so gifts aren't diluted by ordinary joins,
        but a huge whale can't snowball unchecked)."""
        name = name.strip()[:20]
        if name in self.players:
            return self.players[name]

        red_strength = self.team_strength("red")
        blue_strength = self.team_strength("blue")
        red_count = len(self.team_members("red"))
        blue_count = len(self.team_members("blue"))

        bigger = max(red_strength, blue_strength)
        smaller = min(red_strength, blue_strength)
        severely_imbalanced = smaller > 0 and (bigger / smaller) >= IMBALANCE_RATIO

        if severely_imbalanced:
            team = "red" if red_strength < blue_strength else "blue"
        elif red_count != blue_count:
            team = "red" if red_count < blue_count else "blue"
        else:
            team = random.choice(["red", "blue"])

        self.eliminated.discard(name)           # a returning player is no longer out
        self.players[name] = Player(name, team)
        return self.players[name]
    

    def chat(self, name, now):
        """A viewer typed their name. Joins them and gives a small pull."""
        player = self.join(name)
        can_pull = (now - player.last_chat_pull) >= CHAT_COOLDOWN
        if can_pull:
            player.last_chat_pull = now
            self.push(player.team, CHAT_PULL)

    def gift(self, name, coins):
        """A viewer sent a gift worth `coins`. Also revives an eliminated player."""
        player = self.join(name)
        player.coins += coins

    # ---- elimination
    def check_eliminations(self, dt):
        """While the rope sits deep on one side, knock out the losing team's
        FIRST MEMEBER THAT JOINED player every ELIMINATION_INTERVAL seconds."""
        if abs(self.rope) < ELIMINATION_ZONE:
            self.elim_timer = ELIMINATION_INTERVAL      # grace period on re-entry
            return
        
        if abs(self.rope) >= ELIMINATION_ZONE:
            self.elim_timer -= dt
            if self.elim_timer > 0:
                return
            
            red_count = len(self.team_members("red"))
            blue_count = len(self.team_members("blue"))


            if self.rope <= -ELIMINATION_ZONE:
                if blue_count <= MIN_TEAM_SIZE: return
                victim = self.team_members("blue")[0]
                del self.players[victim.name]
                self.elim_timer = ELIMINATION_INTERVAL
                self.eliminated.add(victim.name)
            elif self.rope >= ELIMINATION_ZONE:
                if red_count <= MIN_TEAM_SIZE: return
                victim = self.team_members("red")[0]
                del self.players[victim.name]
                self.elim_timer = ELIMINATION_INTERVAL
                self.eliminated.add(victim.name)
        

    # ---- time passing
    def tick(self, dt):
        """Advance the game by dt seconds."""
        if self.winner:
            self.winner_display_left -= dt
            if self.winner_display_left > 0.0:
                print(f"Winner is {self.winner}")
            else:
                self.new_round()
            return

        # 1. physics
        force = self.team_strength("blue") - self.team_strength("red")
        self.rope += force * FORCE_SCALE * dt

        # 2. eliminations
        self.check_eliminations(dt)

        # 3. normal phase
        if self.time_left > 0:
            self.time_left -= dt
            if self.rope >= ROPE_LIMIT:
                self.winner = "blue"
            elif self.rope <= -ROPE_LIMIT:
                self.winner = "red"

        # 4. overtime phase (starts once time_left runs out)
        else:
            self.overtime_left -= dt
            if abs(self.rope) > OVERTIME_BAND:          # sudden death
                self.winner = "blue" if self.rope > 0 else "red"
            elif self.overtime_left <= 0:
                if self.rope > 0:
                    self.winner = "blue"
                elif self.rope < 0:
                    self.winner = "red"
                else:
                    self.winner = "draw"

    def new_round(self):
        """Reset everything for the next round."""
        self.players.clear()
        self.rope = 0.0
        self.time_left = float(ROUND_SECONDS)
        self.overtime_left = float(OVERTIME_SECONDS)
        self.winner = None
        self.winner_display_left = WINNER_DISPLAY_SECONDS
        self.round_number += 1
        self.eliminated.clear()
        self.elim_timer = ELIMINATION_INTERVAL
        self.biggest_gifter_name = None

    def state(self):
            """Everything the front end needs to draw the game, as a plain dict."""
            ranked = sorted(self.players.values(), key=strength, reverse=True)
            highest_gifters_red = sorted(self.team_members("red"), key=strength, reverse=True)
            highest_gifters_blue = sorted(self.team_members("blue"), key=strength, reverse=True)

            if len(highest_gifters_red) == 0 or len(highest_gifters_blue) == 0:
                biggest_gifter = None
                self.biggest_gifter_name = None
            else:
                red_player = highest_gifters_red[0]
                blue_player = highest_gifters_blue[0]

                if red_player.coins > blue_player.coins:
                    current_leader = red_player
                elif blue_player.coins > red_player.coins:
                    current_leader = blue_player
                else:
                    current_leader = None

                if current_leader is not None:
                    self.biggest_gifter_name = current_leader.name
                    biggest_gifter = [current_leader.name, current_leader.team, current_leader.coins]
                elif self.biggest_gifter_name == red_player.name:
                    biggest_gifter = [red_player.name, red_player.team, red_player.coins]
                elif self.biggest_gifter_name == blue_player.name:
                    biggest_gifter = [blue_player.name, blue_player.team, blue_player.coins]
                else:
                    choice = random.choice([red_player, blue_player])
                    self.biggest_gifter_name = choice.name
                    biggest_gifter = [choice.name, choice.team, choice.coins]


            return {
                "rope": round(self.rope, 1),
                "time_left": round(self.time_left, 1),
                "winner": self.winner,
                "winner_display_time_left": round(self.winner_display_left, 1),
                "red_strength": round(self.team_strength("red"), 1),
                "blue_strength": round(self.team_strength("blue"), 1),
                "top_players": [(p.name, p.team, p.coins) for p in ranked[:5]],
                "round_number": self.round_number,
                "blue_roster_roblox": [(p.name, p.team, p.coins) for p in self.team_members("blue")],
                "red_roster_roblox": [(p.name, p.team, p.coins) for p in self.team_members("red")],
                "eliminated": sorted(self.eliminated), 
                "highest_gifters_red": [(p.name, p.team, p.coins) for p in highest_gifters_red], 
                "highest_gifters_blue": [(p.name, p.team, p.coins) for p in highest_gifters_blue],
                "biggest_gifter": biggest_gifter
            }


# --------------------------------------------------------------------- tests
def run_tests():
    import json
    failed = 0

    def check(label, condition):
        nonlocal failed
        print(("PASS  " if condition else "FAIL  ") + label)
        failed += 0 if condition else 1

    def game_with(red=(), blue=()):
        g = Game()
        for name, coins in red:
            g.players[name] = Player(name, "red", coins)
        for name, coins in blue:
            g.players[name] = Player(name, "blue", coins)
        return g

    # -- joining
    g = Game()
    for i in range(10):
        g.join(f"p{i}")
    check("10 free joins split 5 vs 5",
          len(g.team_members("red")) == 5 and len(g.team_members("blue")) == 5)

    g = Game()
    g.join("a"); g.join("a")
    check("joining twice doesn't duplicate", len(g.players) == 1)

    g = game_with(red=[(f"r{i}", 0) for i in range(3)], blue=[(f"b{i}", 0) for i in range(2)])
    check("mild imbalance: new joiner goes to the smaller team",
          g.join("new").team == "blue")

    g = game_with(red=[(f"r{i}", 0) for i in range(5)], blue=[("whale", 10000)])
    check("severe imbalance: new joiner goes to the WEAKER team, not the winner",
          g.join("new").team == "red")

    # -- gifting and strength
    g = Game()
    g.gift("rich", 100)
    check("gifting adds coins", g.players["rich"].coins == 100)
    check("100 coins is strong but under 20x a 1-coin player",
          strength(Player("y", "red", 100)) < 20 * strength(Player("x", "red", 1)))
    check("everyone has strength of at least 1", strength(Player("z", "red", 0)) >= 1)

    # -- chat cooldown
    g = Game()
    g.chat("spammer", now=0.0)
    g.chat("spammer", now=0.5)
    check("chat cooldown blocks spam", abs(g.rope) == CHAT_PULL)

    # -- ending a round
    g = Game()
    g.rope = ROPE_LIMIT
    g.tick(0.1)
    check("reaching the rope limit ends the round", g.winner == "blue")

    g = Game()
    g.time_left, g.rope = 0.1, 5
    g.tick(0.5); g.tick(0.5)
    check("time up with a close rope starts overtime (no instant winner)", g.winner is None)

    g = Game()
    g.time_left, g.rope = 0.1, 95
    g.tick(0.5); g.tick(0.5)
    check("time up with a decisive rope resolves within one tick", g.winner == "blue")

    g = Game()
    g.time_left, g.rope = 0.0, 50
    g.tick(0.5)
    check("sudden death: rope leaving the band in overtime ends it", g.winner == "blue")

    g = Game()
    g.time_left, g.overtime_left = 0.0, 0.1
    g.tick(0.5)
    check("overtime expiring with a centered rope is a draw", g.winner == "draw")

    g = game_with(red=[("r", 0)])
    g.winner, g.winner_display_left, g.rope = "red", 0.1, 50
    g.overtime_left, g.time_left = 3.0, 3.0
    g.eliminated.add("ghost")
    g.tick(0.5)
    check("celebration ends -> new round resets everything",
          g.winner is None and g.round_number == 1 and not g.players and g.rope == 0
          and g.overtime_left == OVERTIME_SECONDS and g.time_left == ROUND_SECONDS
          and not g.eliminated)

    # -- elimination
    g = game_with(red=[("whale", 100), ("mid", 10), ("free", 0)],
                  blue=[("b1", 0), ("b2", 0), ("b3", 0)])
    g.rope = 40
    g.check_eliminations(ELIMINATION_INTERVAL)
    check("lowest-coin player on the losing team goes first", g.eliminated == {"free"})
    g.check_eliminations(ELIMINATION_INTERVAL)
    g.check_eliminations(ELIMINATION_INTERVAL)
    check("stops at MIN_TEAM_SIZE, the top gifter survives",
          [p.name for p in g.team_members("red")] == ["whale"]
          and g.eliminated == {"free", "mid"})

    g = game_with(red=[("r1", 0), ("r2", 0)], blue=[("b1", 0), ("b2", 0)])
    g.rope = 10
    g.check_eliminations(100)
    check("no eliminations while the rope is inside the zone", not g.eliminated)

    g = game_with(red=[("r1", 0), ("r2", 0)], blue=[("b1", 0), ("b2", 0)])
    g.rope = -40
    g.check_eliminations(ELIMINATION_INTERVAL)
    check("rope on red's side eliminates from BLUE", len(g.eliminated) == 1
          and next(iter(g.eliminated)).startswith("b"))

    g = game_with(red=[("whale", 100), ("free", 0)], blue=[("b1", 0), ("b2", 0)])
    g.rope = 40
    g.check_eliminations(ELIMINATION_INTERVAL)
    g.gift("free", 5)
    check("gifting revives an eliminated player",
          "free" in g.players and "free" not in g.eliminated)

    g = game_with(red=[("r1", 0)], blue=[("b1", 0)])
    g.eliminated.add("gone")
    s = g.state()
    check("state() is JSON-safe and exposes eliminated + rosters",
          isinstance(s["eliminated"], list) and json.dumps(s) and "blue_roster_roblox" in s)

    print(f"\n{failed} failed")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "test":
        run_tests()
    else:
        print("rules.py is imported by server.py. Run `python rules.py test` to run the tests.")