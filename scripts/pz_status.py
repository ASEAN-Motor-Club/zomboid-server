#!/usr/bin/env python3
"""PZ server status -> single Discord message (edit-in-place).

Queries the PZ dedicated server via the Steam A2S protocol on its UDP query
port, then maintains ONE persistent Discord status message via the webhook API:
the first run POSTs it, every later run PATCH-edits the same message (no
channel clutter). The message id is persisted to a state file.

In-game clock source (v3, log-driven):
  * The authoritative in-game date is read ONCE from <save>/map_t.bin (the
    world save) as an anchor. We parse it with the offsets confirmed by
    decompiling zombie.GameTime.save()/load() from the B42 jar (2026-08):
        [4]  int  version=249
        [8]  float multiplier
        [12] int  nightsSurvived        <- whole in-game days elapsed
        [16] int  targetZombies
        [20] float lastTimeOfDay (hours, previous frame)
        [24] float timeOfDay      (hours)      <- clock within the day
        [28] int  day    (0-based day-of-month)
        [32] int  month  (0-based, Jan=0  -- game uses GregorianCalendar)
        [36] int  year
    DataOutputStream is big-endian. On the live world the bytes decode to
    (nights=42, tod=16.1, year=1993) which heals to a July-9-1993 start + 42
    nights. `startYear=1` in the sandbox is the *new-world* template; the live
    worldgen epoch is 1993.
  * Between that seed and now we CANNOT trust map_t.bin (SaveWorldEveryMinutes
    is 0, so it only rewrites on chunk-unload or clean shutdown). So we track a
    monotonically advancing in-game clock ourselves:
        in_game_seconds = seed_in_game_sec + SUM over online segments of
                          (real_wall_sec * 16)
    where online means ">=1 player connected" (PauseEmpty=true; the world clock
    is frozen at 0 players). DayLength=4 => one in-game day (24h) is 90m real
    => in-game runs 16x real time.
  * The state file persists {seed_abs_sec, last_wall_sec, running}. Each run we
    add (now_wall - last_wall) * 16 only while running; on the transition to 0
    players we persist and freeze; on the transition back (>0) we resume.
  * Display rolls the in-game day at in-game midnight (calendar-day rollover),
    like the game itself; drift self-corrects at each rollover.
"""

import argparse
import datetime
import json
import os
import socket
import struct
import time
import urllib.request
import urllib.error

A2S_INFO = b"\xff\xff\xff\xff\x54Source Engine Query\x00"
A2S_PLAYER = b"\xff\xff\xff\xff\x55Source Engine Query\x00"

# PZ's fictional calendar zero-point: the game starts in-game on 1993-07-09
# 09:00 (StartDay=9, StartMonth=7, StartTime=2). "days survived" counts whole
# in-game days elapsed since then. We use it to rebuild a real datetime from the
# world's day counter.
IN_GAME_EPOCH = datetime.datetime(1993, 7, 9, 9, 0)

# In-game time runs 16x real time while >=1 player is online
# (DayLength=4 => 24 in-game hours per 90 real minutes).
# in-game seconds per real second:
IN_GAME_X = 24 * 60 * 60 / (90 * 60)  # == 16.0

# --- map_t.bin offsets (verified by decompiling GameTime.save(); big-endian) --
MAP_T_VERSION_OFFSET  = 4   # int, == 249
MAP_T_NIGHTS_OFFSET   = 12  # int, whole in-game days survived
MAP_T_TIMEOFDAY_OFFSET = 24 # float, hour of day (0..24)
MAP_T_DAY_OFFSET      = 28  # int, 0-based day-of-month
MAP_T_MONTH_OFFSET    = 32  # int, 0-based month (Jan=0)
MAP_T_YEAR_OFFSET     = 36  # int, absolute Gregorian year


def read_save_anchor(map_t_path):
    """Return (abs_wall_epoch, atom) anchoring in-game time, or None.

    Returns the in-game time as a real datetime reconstructed from the save:
    epoch(1993-07-09 09:00) + nightsSurvived days + timeOfDay hours. This is
    the *last-persisted* instant (may lag live play), used only as the seed for
    the accumulating clock.
    """
    if not map_t_path or not os.path.exists(map_t_path):
        return None
    try:
        with open(map_t_path, "rb") as f:
            d = f.read(40)
        if len(d) < 40:
            return None
        ver = struct.unpack_from(">i", d, MAP_T_VERSION_OFFSET)[0]
        nights = struct.unpack_from(">i", d, MAP_T_NIGHTS_OFFSET)[0]
        tod = struct.unpack_from(">f", d, MAP_T_TIMEOFDAY_OFFSET)[0]
        day0 = struct.unpack_from(">i", d, MAP_T_DAY_OFFSET)[0]
        mon0 = struct.unpack_from(">i", d, MAP_T_MONTH_OFFSET)[0]
        year = struct.unpack_from(">i", d, MAP_T_YEAR_OFFSET)[0]
        if ver != 249:
            return None
        if not (0 <= tod < 24 and 1990 <= year <= 2100 and 0 <= mon0 <= 11):
            return None
        hour = int(tod)
        minute = int(round((tod - hour) * 60))
        if minute == 60:
            hour += 1
            minute = 0
        day = day0 + 1  # 0-based -> 1-based day-of-month
        month = mon0 + 1  # 0-based -> 1-based
        # Sanity: derived date from night counter must agree within tolerance.
        derived = IN_GAME_EPOCH + datetime.timedelta(days=nights)
        if abs((derived.month - month)) > 1 or abs(derived.day - day) > 2:
            # Anchor from nights counter directly (more robust day signal).
            base = IN_GAME_EPOCH + datetime.timedelta(days=nights)
            anchor = base.replace(hour=hour, minute=minute, second=0)
        else:
            try:
                anchor = datetime.datetime(year, month, day, hour, minute)
            except ValueError:
                anchor = IN_GAME_EPOCH + datetime.timedelta(days=nights)
                anchor = anchor.replace(hour=hour, minute=minute, second=0)
        return anchor
    except (OSError, ValueError, struct.error):
        return None


def seed_in_game_seconds(map_t_path):
    """Absolute in-game seconds since epoch (+tz-free) from the save anchor."""
    anchor = read_save_anchor(map_t_path)
    if anchor is None:
        return None
    # epoch is a naive local; compute difference in days only for stability.
    delta = anchor - IN_GAME_EPOCH
    return int(delta.days * 86400 + delta.seconds)


def game_sec_to_datetime(sec):
    return IN_GAME_EPOCH + datetime.timedelta(seconds=sec)


# --- persistent clock state ---------------------------------------------
# { "seed_sec": int (in-game sec since epoch at seed),
#   "last_wall": float unix, "running": bool }
def load_state(path):
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            d = json.load(f)
        if not isinstance(d, dict):
            return None
        return d
    except (OSError, ValueError):
        return None


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def advance_clock(state, running, now_wall):
    """Return updated state dict after accruing the last interval."""
    if state is None:
        # first ever run: everything anchored by the save; just record the clock
        return state  # caller seeds seconds first
    last_wall = state.get("last_wall") or now_wall
    was_running = state.get("running", False)
    if running and was_running:
        dt = now_wall - last_wall
        if dt > 0:
            state["current_sec"] = state["current_sec"] + dt * IN_GAME_X
    state["last_wall"] = now_wall
    state["running"] = running
    return state


def try_reanchor_from_save(state, map_t_path):
    """If 0 players and map_t.bin got a fresh write since our last anchor,
    snap the clock to it (at 0 players PauseEmpty freezes the world, so the
    save IS the authoritative current time). Guards against stale/corrupt data
    so we never jump backward or to a nonsense value.

    Returns the (possibly updated) state.
    """
    if state is None or not map_t_path or not os.path.exists(map_t_path):
        return state
    last_anchor = state.get("anchor_mtime", 0.0)
    try:
        mtime = os.path.getmtime(map_t_path)
    except OSError:
        return state
    # only act on a save NEWER than one we've already incorporated
    if mtime <= last_anchor:
        return state
    new_sec = seed_in_game_seconds(map_t_path)
    if new_sec is None:
        return state
    cur_sec = state.get("current_sec", 0)
    # At 0 players the world is FROZEN, so a genuine fresh save can only match
    # our clock within poll lag (a few in-game minutes). A value substantially
    # BEHIND means it's a stale snapshot (save predates our last accrue), which
    # would wrongly rewind the clock. Reject backward jumps beyond a small
    # buffer (5 in-game minutes).
    if new_sec < cur_sec - 5 * 60:
        state["anchor_mtime"] = mtime  # remember it; stop re-checking this file
        return state
    # reject wild forward leaps too (corrupt / unrelated save)
    if new_sec - cur_sec > 6 * 3600:
        state["anchor_mtime"] = mtime
        return state
    state["current_sec"] = new_sec
    state["anchor_mtime"] = mtime
    return state


def trigger_fifo_save_and_wait(fifo_path, map_t_path, state, wait_max=25):
    """Send `save` to the PZ console fifo, then wait for map_t.bin to be
    rewritten (mtime newer than before), up to wait_max seconds. Returns True
    if the save made progress.

    This lets the notifier re-anchor the clock at a 0-player moment WITHOUT
    restarting the game server: a fifo `save` writes a fresh map_t.bin, and we
    then re-anchor to it.

    Blocking-safe: opens the fifo non-blocking so a missing reader (game down
    / mid-restart) can never hang the notifier.
    """
    if not fifo_path or not os.path.exists(fifo_path):
        return False
    if not map_t_path or not os.path.exists(map_t_path):
        return False
    try:
        before = os.path.getmtime(map_t_path)
    except OSError:
        before = 0.0
    try:
        # O_NONBLOCK so we error immediately (ENXIO/BlockingIOError) if the game
        # has no console reader right now, instead of blocking forever.
        fd = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, b"save\n")
        finally:
            os.close(fd)
    except OSError:
        return False
    # poll map_t for a new mtime
    deadline = time.time() + wait_max
    while time.time() < deadline:
        try:
            now_m = os.path.getmtime(map_t_path)
        except OSError:
            now_m = 0.0
        if now_m > before:
            return True
        time.sleep(0.5)
    return False


# --- A2S ----------------------------------------------------------------
def udp_query(host, port, payload, timeout=4):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(payload, (host, port))
        return s.recvfrom(65535)[0]
    except socket.timeout:
        return None
    finally:
        s.close()


def read_nullstr(buf, i):
    e = buf.index(0, i)
    return buf[i:e].decode("utf-8", "replace"), e + 1


def a2s_info(host, port):
    d = udp_query(host, port, A2S_INFO)
    if d is None or len(d) < 5:
        return None
    if d[4] == 0x41:
        d = udp_query(host, port, A2S_INFO + d[5:9])
        if d is None:
            return None
    if d[4] != 0x49:
        return None
    i = 5
    name, i = read_nullstr(d, i + 1)
    _map, i = read_nullstr(d, i)
    _folder, i = read_nullstr(d, i)
    _game, i = read_nullstr(d, i)
    i += 2
    players = d[i]; i += 1
    max_players = d[i]
    return {"name": name, "players": players, "max_players": max_players}


def a2s_player_names(host, port):
    d = udp_query(host, port, A2S_PLAYER)
    if d is None or len(d) < 5:
        return None
    if d[4] == 0x41:
        d = udp_query(host, port, A2S_PLAYER[:-1] + d[5:9])
        if d is None:
            return None
    if d[4] != 0x44:
        return None
    n = d[5]
    names = []
    i = 6
    for _ in range(n):
        i += 1
        name, i = read_nullstr(d, i)
        i += 4
        i += 4
        names.append(name)
    return names


def _req(url, method, payload):
    return urllib.request.Request(
        url, method=method, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "User-Agent": "pz-status/1.0 (ASEAN Motor Club; https://aseanmotorclub.com)"})


def webhook_post(url, payload):
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
            return None
        raise


def build_embed(status):
    if status is None:
        return {"content": None, "embeds": [{
            "title": "Project Zomboid — OFFLINE",
            "color": 0xC0392B,
            "description": "The PZ server is not reachable on the query port right now.",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}]}
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

    embed = {"title": title, "color": color, "description": body,
             "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

    clock = status.get("clock")
    clock_str = status.get("clock_str")
    if online and clock is not None and clock_str is not None:
        day_no = status.get("day_no")
        stopped = status.get("stopped", False)
        if stopped:
            time_line = f"⏸ {clock_str} (Day {day_no} — stopped: no players)"
        else:
            time_line = f"🕐 {clock_str} (Day {day_no})"
        embed["fields"] = [{"name": "In-game time", "value": time_line, "inline": True}]
    return {"content": None, "embeds": [embed]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--webhook-url", required=True)
    ap.add_argument("--state-file", required=True)
    ap.add_argument("--clock-state-file", default=None,
                    help="Separate JSON file holding the accumulating in-game clock; "
                         "if omitted, uses --state-file suffix -clock")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=16261)
    ap.add_argument("--map-t-file", default=None,
                    help="Path to the world save map_t.bin; used as the clock seed.")
    ap.add_argument("--pz-fifo", default=None,
                    help="Path to the PZ server console FIFO (e.g. /run/zomboid-server/"
                         "server.fifo). When set, the notifier sends a mid-flight "
                         "`save` at each 0-player transition so it can re-anchor the "
                         "clock to a fresh map_t.bin without restarting the server.")
    args = ap.parse_args()

    info = a2s_info(args.host, args.port)
    if info is None:
        status = None
    else:
        names = a2s_player_names(args.host, args.port) or []
        status = {"online": True, "players": info["players"],
                  "max_players": info["max_players"], "names": names}

    status_payload = build_embed(status)

    # --- clock management ---
    clock_state_path = args.clock_state_file or (args.state_file + "-clock")
    now_wall = time.time()
    players = (status or {}).get("players", 0)
    running = bool(status is not None and status.get("online") and players > 0)

    st = load_state(clock_state_path)
    if st is None:
        # Seed the accumulating clock from the save anchor (or, if the save is
        # unreadable, from nothing -> no time line until a good seed appears).
        sec = seed_in_game_seconds(args.map_t_file)
        if sec is not None:
            try:
                amt = os.path.getmtime(args.map_t_file)
            except OSError:
                amt = 0.0
            st = {"current_sec": sec, "last_wall": now_wall, "running": running,
                  "anchor_mtime": amt}
            # seed counts as running-from-now; no accrual for the whole past
    if st is not None:
        # Backfill anchor_mtime for state written before this feature existed:
        # consider the CURRENT save already incorporated, so we don't snap the
        # live clock back to it on the first run (it's likely stale/behind).
        if "anchor_mtime" not in st:
            try:
                st["anchor_mtime"] = os.path.getmtime(args.map_t_file)
            except (OSError, TypeError):
                st["anchor_mtime"] = 0.0
        # was there someone online at the LAST tick? (persisted `running` is
        # the previous state before advance_clock rewrites it below)
        was_running = bool(st.get("running"))
        st = advance_clock(st, running, now_wall)
        # At a 0-player transition (players online last tick -> now 0), the
        # world just froze. Trigger a mid-flight `save` so map_t.bin is fresh,
        # then re-anchor to it -- no server restart required. Also
        # opportunistically re-anchor on any later fresh save at 0 players.
        if players == 0:
            if was_running and args.pz_fifo:
                trigger_fifo_save_and_wait(args.pz_fifo, args.map_t_file, st)
            st = try_reanchor_from_save(st, args.map_t_file)
        save_state(clock_state_path, st)
        if status is not None:
            cur = game_sec_to_datetime(st["current_sec"])
            status["clock"] = st["current_sec"]
            status["clock_str"] = cur.strftime("%Y-%m-%d %H:%M")
            status["stopped"] = (players == 0)
            # Day N = whole in-game days survived (24h day), calendar rollover
            delta = int(st["current_sec"] // 86400)
            status["day_no"] = delta
    else:
        # no seed yet; show offline-map path only
        pass

    payload = build_embed(status)

    base = args.webhook_url.rstrip("/")
    msg_id = None
    if os.path.exists(args.state_file):
        try:
            msg_id = open(args.state_file).read().strip()
        except OSError:
            msg_id = None

    if msg_id:
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