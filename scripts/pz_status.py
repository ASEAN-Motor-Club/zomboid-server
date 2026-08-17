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
import argparse, json, os, socket, struct, sys, time, urllib.request, urllib.error

A2S_INFO = b"\xff\xff\xff\xff\x54Source Engine Query\x00"
A2S_PLAYER = b"\xff\xff\xff\xff\x55Source Engine Query\x00"


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
    return {
        "content": None,
        "embeds": [{
            "title": title,
            "color": color,
            "description": body,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--webhook-url", required=True)
    ap.add_argument("--state-file", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=16261)
    args = ap.parse_args()

    info = a2s_info(args.host, args.port)
    if info is None:
        status = None
    else:
        names = a2s_player_names(args.host, args.port) or []
        status = {"online": True, "players": info["players"],
                  "max_players": info["max_players"], "names": names}

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
