#!/usr/bin/env python3
"""Host-side PZ workshop-update watcher.

Replaces the "Server Workshop Mod Update Checker & Auto-Restart" workshop mod
(3659447892 / ServerWorkshopModAutoRestartB42, removed 2026-08-27).

WHY NOT THE MOD: the mod shut the server down by calling getCore():quit() from
Lua without ever saving the world first — and because the JVM exited by
itself, systemd's ExecStop fifo-save safety net never ran. Every bounce
silently rolled the world back to the last explicit save while player data
stayed current (livestock loss + resurrected-butchered animals, Aug 26-27).

WHAT THIS DOES INSTEAD (stdlib-only, runs as a systemd oneshot timer):
  1. Query Steam GetPublishedFileDetails for every WorkshopItems= id passed
     via --items and compare time_updated against the persisted baseline
     (--state-file).
  2. First run: persist the baseline and exit (no restart storm).
  3. On change(s): announce via Discord webhook AND an in-game console
     servermsg, sleep --grace-minutes so players can reach safety.
  4. THEN save first ("save" via the console FIFO), pause for the world write,
     and only then send "quit" — exactly the graceful path systemd's ExecStop
     would take. The unit's Restart=always bounces the server, boot pulls the
     updated workshop items via steamcmd, play resumes with zero rollback.
  5. Persist the new baseline BEFORE sending quit. A pending-restart guard
     flag survives the run so a slow shutdown/reboot cycle can't cause
     duplicate bounces; the next tick verifies the PID actually changed.

If the PZ unit is not active, changes are absorbed silently into the baseline
(a maintainer window / stopped server picks mods up at next start anyway).
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

STEAM_API = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"


def log(msg):
    print(f"[workshop-watch] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def post_discord(webhook, content):
    """Fire-and-forget Discord webhook message (errors logged, never fatal)."""
    try:
        data = json.dumps({"content": content}).encode()
        req = urllib.request.Request(
            webhook, data=data, headers={"Content-Type": "application/json"},
            method="POST")
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:  # noqa: BLE001 - notifier must never kill the tick
        log(f"webhook post failed: {e}")


def fetch_workshop(ids):
    """Return {publishedfileid: {'time_updated': int, 'title': str}}."""
    fields = [("itemcount", str(len(ids)))]
    for i, wid in enumerate(ids):
        fields.append((f"publishedfileids[{i}]", wid))
    body = urllib.parse.urlencode(fields).encode()
    last_err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(STEAM_API, data=body, method="POST",
                                         headers={"Content-Type": "application/x-www-form-urlencoded"})
            with urllib.request.urlopen(req, timeout=30) as r:
                payload = json.load(r)
            out = {}
            for item in payload.get("response", {}).get("publishedfiledetails", []):
                out[str(item.get("publishedfileid"))] = {
                    "time_updated": int(item.get("time_updated", 0)),
                    "title": item.get("title", "?"),
                }
            return out
        except Exception as e:  # noqa: BLE001 - retry then give up for this tick
            last_err = e
            log(f"steam api attempt {attempt + 1} failed: {e}")
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"Steam API unreachable after retries: {last_err}")


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as e:  # noqa: BLE001 - corrupt state == treat as fresh
        log(f"state file unreadable ({e}); treating as fresh baseline")
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)




def pz_active(unit):
    r = subprocess.run(["systemctl", "is-active", "--quiet", unit])
    return r.returncode == 0


def pz_main_pid(unit):
    try:
        out = subprocess.check_output(
            ["systemctl", "show", unit, "--property=MainPID", "--value"],
            text=True, timeout=10).strip()
        return int(out) if out.isdigit() else None
    except Exception:  # noqa: BLE001
        return None


def fifo_write(fifo, command):
    """Write one console command to the PZ stdin FIFO. Raises on failure so
    callers can distinguish 'safety action landed' from 'nothing happened'."""
    with open(fifo, "w") as f:
        f.write(command + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--webhook-url", required=True)
    ap.add_argument("--state-file", required=True)
    ap.add_argument("--fifo", default="/run/zomboid-server/server.fifo")
    ap.add_argument("--unit", default="zomboid-server.service")
    ap.add_argument("--grace-minutes", type=int, default=5)
    ap.add_argument("--save-wait-seconds", type=int, default=25,
                    help="pause between the FIFO 'save' and 'quit' so the "
                         "world write completes before exit")
    ap.add_argument("--restart-confirm-timeout", type=int, default=180,
                    help="seconds to watch for a new MainPID after quit")
    ap.add_argument("--items", required=True,
                    help="semicolon-separated Steam workshop IDs to monitor")
    args = ap.parse_args()

    ids = [x.strip() for x in args.items.split(";") if x.strip()]
    if not ids:
        log("no workshop ids configured; nothing to do")
        return

    state = load_state(args.state_file)
    known = state.get("items", {})
    current = fetch_workshop(ids)

    # Pending-restart resolution pass (from a previous tick's shutdown).
    if state.get("pending_restart"):
        cur_pid = pz_main_pid(args.unit)
        if cur_pid != state.get("pending_old_pid"):
            log("previous restart confirmed: PZ MainPID changed "
                f"({state.get('pending_old_pid')} -> {cur_pid})")
            state["pending_restart"] = False
            state["pending_since"] = None
            post_discord(args.webhook_url,
                         "✅ PZ workshop-update restart completed; server is "
                         "back up on the refreshed mods.")
        elif time.time() - state.get("pending_since", 0) > 1800:
            log("WARN: restart did not confirm within 30 min; clearing guard "
                "(baseline kept — next legit boot absorbs the mods)")
            state["pending_restart"] = False
            state["pending_since"] = None
            post_discord(args.webhook_url,
                         "⚠️ PZ workshop-update restart did not verify within "
                         "30 min. Updated mods will apply at the next regular "
                         "restart — no action needed unless you want them live "
                         "sooner.")

    # First run or nothing tracked yet: absorb silently.
    changed = []
    for wid, info in current.items():
        prev = known.get(wid)
        if prev is not None and info["time_updated"] > prev["time_updated"]:
            changed.append((wid, info))
    if not known:
        log(f"first run: baselining {len(current)} workshop items (no restart)")
        state["items"] = current
        save_state(args.state_file, state)
        return

    state["items"] = current  # refresh titles/timestamps each tick

    if not changed:
        save_state(args.state_file, state)
        return

    names = ", ".join(f'**{info["title"]}**' for _, info in changed)
    log(f"workshop update(s) detected: {names}")

    if not pz_active(args.unit):
        log("PZ unit inactive — absorbing updates into baseline quietly")
        state["items"] = current
        save_state(args.state_file, state)
        return

    # Announce + grace period.
    minutes = max(1, args.grace_minutes)
    post_discord(args.webhook_url,
                 f"🔄 PZ workshop update detected: {names}. Graceful "
                 f"*save-and-restart* in ~{minutes} min to sync everyone "
                 f"(world will be saved first — no progress lost).")
    try:
        fifo_write(args.fifo,
                   'servermsg "Workshop update detected: restarting with a '
                   f'world SAVE in ~{minutes} minute(s)."')
    except Exception as e:  # noqa: BLE001 - console msg is best-effort
        log(f"in-game servermsg failed: {e}")
    time.sleep(minutes * 60)

    # Second warning right before the sequence.
    try:
        fifo_write(args.fifo, 'servermsg "Saving world now, restarting in ~30 seconds."')
    except Exception as e:  # noqa: BLE001
        log(f"in-game servermsg failed: {e}")

    old_pid = pz_main_pid(args.unit)

    # THE critical difference vs the removed mod: save FIRST, then quit.
    try:
        fifo_write(args.fifo, "save")
        log("FIFO 'save' sent; waiting for the world write to settle "
            f"({args.save_wait_seconds}s)")
        time.sleep(args.save_wait_seconds)
        fifo_write(args.fifo, "quit")
        log("FIFO 'quit' sent; Restart=always will bring the server back")
    except Exception as e:
        log(f"FIFO write failed ({e}) — abandoning this bounce, will retry "
            f"next tick. Baseline NOT advanced.")
        save_state(args.state_file, state)
        sys.exit(1)

    # Guard against duplicate bounces across ticks while PZ cycles down/up.
    state["pending_restart"] = True
    state["pending_since"] = time.time()
    state["pending_old_pid"] = old_pid
    save_state(args.state_file, state)

    # Wait briefly inline so the common case resolves in one tick...
    deadline = time.time() + args.restart_confirm_timeout
    while time.time() < deadline:
        time.sleep(15)
        cur = pz_main_pid(args.unit)
        if cur != old_pid:
            log(f"restart confirmed within tick (new MainPID {cur})")
            state["pending_restart"] = False
            state["pending_since"] = None
            save_state(args.state_file, state)
            post_discord(args.webhook_url,
                         "✅ PZ saved & restarted cleanly with the updated "
                         "mods. Back online.")
            return
    log(f"MainPID still {old_pid} after {args.restart_confirm_timeout}s — "
        f"leaving pending-restart guard set for the next tick")


if __name__ == "__main__":
    main()
