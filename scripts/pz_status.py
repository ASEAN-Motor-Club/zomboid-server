#!/usr/bin/env python3
"""PZ server status -> single Discord message (edit-in-place).

Queries the PZ dedicated server via the Steam A2S protocol on its UDP query
port, then maintains ONE persistent Discord status message via the webhook API:
the first run POSTs it, every later run PATCH-edits the same message (no
channel clutter). The message id is persisted to a state file.

Protocol notes (verified 2026-08):
  * A2S_INFO  on the query port (default 16261) -> server online + player count + max.
  * A2S_PLAYER on the query port -> the connected players' usernames (type 0x44).
    Requires the challenge-response handshake when the server answers 0x41.
  * The RakNet game-data port (+1) is NOT A2S — don't probe it here.
"""
import argparse, datetime, json, os, socket, struct, sys, time, urllib.request, urllib.error

A2S_INFO = b"\xff\xff\xff\xff\x54Source Engine Query\x00"
A2S_PLAYER = b"\xff\xff\xff\xff\x55Source Engine Query\x00"

# PZ's fictional calendar zero-point: the game starts in-game on 1993-07-09
# 09:00 local, and "days survived" counts whole in-game days elapsed since
# then. Displayed date = zero point + days_survived.
IN_GAME_EPOCH = datetime.datetime(1993, 7, 9, 9, 0)
# Byte offsets in <save>/map_t.bin (the world state file PZ rewrites on save).
# Verified against the live B42 save (2026-08): days_survived [15], the file's
# own day-of-month [31]+1 and month [35]+1 cross-check to the same calendar
# date as epoch + days_survived. These offsets are stable across the observed
# B42 saves but ARE structure-sensitive — if they ever read garbage, readers
# fail closed (no time field) rather than printing a wrong date.
MAP_T_DAYS_OFFSET = 15
MAP_T_DAY_OFFSET = 31
MAP_T_MONTH_OFFSET = 35


def read_in_game_time(map_t_path):
    """Return (display_date, days_survived) or (None, None) if unreadable.

    The save is only written on the game's save cadence (SaveWorldEveryMinutes
    / periodic), so this is the *last-persisted* in-game date, not a live
    ticking clock — which matches the design: when nobody is online the world
    clock is frozen (PauseEmpty=true), so the persisted date holds; when
    players are present it advances between saves.
    """
    if not map_t_path or not os.path.exists(map_t_path):
        return None, None
    try:
        with open(map_t_path, "rb") as f:
            d = f.read()
        if len(d) <= max(MAP_T_DAY_OFFSET, MAP_T_MONTH_OFFSET):
            return None, None
        days = d[MAP_T_DAYS_OFFSET]
        # optional cross-check: the file also stores its own day/month; if they
        # wildly disagree with the derived date, the offset model is wrong.
        day_f = d[MAP_T_DAY_OFFSET] + 1
        month_f = d[MAP_T_MONTH_OFFSET] + 1
        derived = IN_GAME_EPOCH + datetime.timedelta(days=days)
        # allow 2-day tolerance (save lag + calendar edge); else fail safe
        if abs((derived.day) - day_f) > 2 or abs(derived.month - month_f) > 1:
            return None, None
        return derived.strftime("%Y-%m-%d %H:%M"), days
    except (OSError, ValueError):
        return None, None


def udp_query(host, port, payload, timeout=4):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(payload, (host, port))
        data, _ = s.recvfrom(65535)
        return data
    except socket.timeout:
        return None
    finally:
        s.close()


def read_nullstr(buf, i):
    e = buf.index(0, i)
    return buf[i:e].decode("utf-8", "replace"), e + 1


def a2s_info(host, port):
    d = udp_query(host, port, A2S_INFO)
    if d is None:
        return None
    if len(d) < 5:
        return None
    if d[4] == 0x41:  # challenge
        d = udp_query(host, port, A2S_INFO + d[5:9])
        if d is None:
            return None
    if d[4] != 0x49:
        return None
    # 4x FF + type + protocol
    i = 5
    name, i = read_nullstr(d, i + 1)
    _map, i = read_nullstr(d, i)
    _folder, i = read_nullstr(d, i)
    _game, i = read_nullstr(d, i)
    i += 2          # app id
    players = d[i]; i += 1
    max_players = d[i]
    return {"name": name, "players": players, "max_players": max_players}


def a2s_player_names(host, port):
    d = udp_query(host, port, A2S_PLAYER)
    if d is None:
        return None
    if len(d) < 5:
        return None
    if d[4] == 0x41:  # challenge
        d = udp_query(host, port, A2S_PLAYER[:-1] + d[5:9])
        if d is None:
            return None
    if d[4] != 0x44:
        return None
    n = d[5]
    names = []
    i = 6
    for _ in range(n):
        i += 1                       # player index byte
        name, i = read_nullstr(d, i)
        i += 4                       # score
        i += 4                       # duration (float)
        names.append(name)
    return names


def _req(url, method, payload):
    req = urllib.request.Request(url, method=method,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 # Discord 403s urllib's default UA; a real UA is required.
                 "User-Agent": "pz-status/1.0 (ASEAN Motor Club; https://aseanmotorclub.com)"})
    return req


def webhook_post(url, payload):
    # ?wait=true makes Discord return the created message JSON (otherwise 204 no body).
    sep = "&" if "?" in url else "?"
    with urllib.request.urlopen(_req(url + sep + "wait=true", "POST", payload), timeout=10) as r:
        return json.loads(r.read())


def webhook_patch(url, payload):
    try:
        with urllib.request.urlopen(_req(url, "PATCH", payload), timeout=10) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None  # message gone -> re-post
        raise


def build_embed(status):
    if status is None:
        return {
            "content": None,
            "embeds": [{
                "title": "Project Zomboid — OFFLINE",
                "color": 0xC0392B,
                "description": "The PZ server is not reachable on the query port right now.",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }],
        }
    online = status.get("online", False)
    players = status.get("players", 0)
    maxp = status.get("max_players", 0)
    names = status.get("names", [])
    if online:
        title = f"Project Zomboid — Online ({players}/{maxp})"
        color = 0x27AE60
        body = "**Connected:** " + (", ".join(names) if names else "*nobody*")
    else:
        title = "Project Zomboid — OFFLINE"
        color = 0xC0392B
        body = "The PZ server is not reachable on the query port right now."

    embed = {
        "title": title,
        "color": color,
        "description": body,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    # In-game date/time. PauseEmpty=true freezes the world clock at 0 players,
    # so "players == 0" is the stopped signal; when players are present the
    # persisted save date reflects (and advances with) in-game time.
    map_t = status.get("map_t_path")
    if online and map_t:
        date_str, days = read_in_game_time(map_t)
        if date_str is not None and days is not None:
            day_no = int(days) + 1
            if players == 0:
                time_line = f"⏸ {date_str} (Day {day_no} — stopped: no players)"
            else:
                time_line = f"🕐 {date_str} (Day {day_no})"
            embed["fields"] = [{
                "name": "In-game time",
                "value": time_line,
                "inline": True,
            }]
    return {"content": None, "embeds": [embed]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--webhook-url", required=True)
    ap.add_argument("--state-file", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=16261)
    ap.add_argument("--map-t-file", default=None,
                    help="Path to the world save map_t.bin; enables the in-game "
                         "date field in the status message.")
    args = ap.parse_args()

    info = a2s_info(args.host, args.port)
    if info is None:
        status = None
    else:
        names = a2s_player_names(args.host, args.port) or []
        status = {"online": True, "players": info["players"],
                  "max_players": info["max_players"], "names": names}
        if args.map_t_file:
            status["map_t_path"] = args.map_t_file

    payload = build_embed(status)

    # base webhook URL -> append /messages/<id> for editing
    base = args.webhook_url.rstrip("/")
    msg_id = None
    if os.path.exists(args.state_file):
        try:
            msg_id = open(args.state_file).read().strip()
        except OSError:
            msg_id = None

    if msg_id:
        # try to PATCH the existing message; if gone (404), fall through to POST
        try:
            webhook_patch(f"{base}/messages/{msg_id}", payload)
            return
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        except urllib.error.URLError:
            raise

    resp = webhook_post(base, payload)
    if resp and resp.get("id"):
        with open(args.state_file, "w") as f:
            f.write(resp["id"])


if __name__ == "__main__":
    main()
