#!/usr/bin/env bash
# Project Zomboid WORLD WIPE — ASEAN Motor Club (asean-mt-server)
# Scope: delete the world save, KEEP whitelist/roles (Zomboid/db/amc.db) and modlist.
# Usage:  CONFIRM=yes ./pz_reset_wipe.sh [FORCE_PLAYERS=yes]
#   FORCE_PLAYERS=yes is required when anyone is online (announce 15/5/1 min first).
# Does NOT touch: db/amc.db, Server/amc.ini, options.ini, workshop content, mods.
#
# The status notifier's clock state IS reset (see the "resetting status-notifier
# clock state" step): it carries in-game time accumulated from the world being
# wiped, and a surviving copy pins the public embed to the old world's date
# forever. Nothing else in the notifier path is touched.
set -euo pipefail

CONFIRM="${CONFIRM:-}"
FORCE_PLAYERS="${FORCE_PLAYERS:-no}"
Z=/var/lib/zomboid-server/Zomboid
SAVE=$Z/Saves/Multiplayer/amc
FIFO=/run/zomboid-server/server.fifo
B=$Z/backups
CLOCK_STATE=/var/lib/zomboid-server/zomboid-clock-state.json
TS=$(date +%Y%m%d_%H%M)
UNIT=zomboid-server

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

[[ "$CONFIRM" == "yes" ]] || die "refusing to wipe without CONFIRM=yes"

log "pre-flight"
systemctl is-active --quiet $UNIT || log "WARN: $UNIT not active"
if [[ -e $FIFO ]]; then
  echo players > "$FIFO"; sleep 3
  N=$(grep "Players connected" $Z/server-console.txt | tail -1 | grep -oE '\([0-9]+\)' | tr -dc '0-9' || echo "?")
  log "players online: ${N:-unknown}"
  if [[ "${N:-0}" != "0" && "$FORCE_PLAYERS" != "yes" ]]; then
    die "players online ($N) — announce first, then rerun with FORCE_PLAYERS=yes"
  fi
else
  log "no fifo (server down?) — continuing"
fi
[[ -d $SAVE ]] || die "save dir missing: $SAVE"

log "stopping workshop watcher timer (prevents announce/bounce mid-wipe)"
systemctl stop zomboid-workshop-watch.timer || true

log "graceful shutdown: fifo save + quit"
echo save > "$FIFO" 2>/dev/null || true; sleep 5
echo quit > "$FIFO" 2>/dev/null || true
for i in $(seq 1 60); do systemctl is-active --quiet $UNIT || break; sleep 5; done

log "stopping unit (Restart=always auto-bounces ~10s after a clean quit — must stay down)"
systemctl stop $UNIT || true
for i in $(seq 1 30); do systemctl is-active --quiet $UNIT && sleep 3 || break; done
systemctl is-active --quiet $UNIT && die "$UNIT still active — do not touch the save dir"
systemctl reset-failed $UNIT 2>/dev/null || true
pgrep -f ProjectZomboid >/dev/null && die "PZ process still alive — aborting before dir swap"
log "server fully down"

log "final pre-wipe archive (consistent, quiesced)"
mkdir -p "$B"
( cd $Z/Saves/Multiplayer && tar cf - amc | zstd -T0 -3 -q -o "$B/amc_prewipeFinal_$TS.tar.zst" )
zstd -t "$B/amc_prewipeFinal_$TS.tar.zst" >/dev/null && log "archive OK: $B/amc_prewipeFinal_$TS.tar.zst ($(du -h "$B/amc_prewipeFinal_$TS.tar.zst" | cut -f1))"
sha256sum "$B/amc_prewipeFinal_$TS.tar.zst" | tee "$B/amc_prewipeFinal_$TS.sha256"

log "moving world out of the way (never rm — old world stays restorable)"
mv "$SAVE" "$Z/Saves/Multiplayer/amc_wipe_$TS"
log "old world parked at: $Z/Saves/Multiplayer/amc_wipe_$TS"

log "resetting status-notifier clock state"
# zomboid-clock-state.json holds current_sec accumulated from the world just moved
# away. try_reanchor_from_save() only snaps to a fresh map_t.bin within a +/-21 day
# sanity window, so a surviving pre-wipe clock rejects every anchor of the new world
# forever: "[pz_status] map_t anchor REJECTED: gap -NNN.NNd exceeds 21d sanity window"
# once per tick, and the public status embed keeps advertising the OLD world's date
# (hit for real: wipe 2026-11-07 13:26 -> embed still read 1994-05-23 Day 318 while
# the live world was 1993-07-15). The guard is correct; the stale state is not.
# Removing the file — done AFTER the dir swap so no map_t.bin exists to seed from —
# makes the next tick re-seed current_sec straight out of the NEW world's map_t.bin.
if [[ -e $CLOCK_STATE ]]; then
  mv "$CLOCK_STATE" "$CLOCK_STATE.pre_wipe_$TS"
  log "clock state parked at: $CLOCK_STATE.pre_wipe_$TS"
else
  log "no clock state to reset"
fi

log "booting fresh world"
# Baseline the boot marker BEFORE starting: server-console.txt is append-only and
# still holds "SERVER STARTED" from PREVIOUS boots, so a plain grep matches at once
# and the script races ahead of a boot that has not happened yet (hit 2026-11-07).
MARK=$(grep -c "SERVER STARTED" $Z/server-console.txt 2>/dev/null || echo 0)
systemctl start $UNIT
BOOTED=no
for i in $(seq 1 180); do
  NOW=$(grep -c "SERVER STARTED" $Z/server-console.txt 2>/dev/null || echo 0)
  if [[ "${NOW:-0}" -gt "${MARK:-0}" ]]; then BOOTED=yes; break; fi
  sleep 5
done
[[ "$BOOTED" == "yes" ]] || die "server did not report SERVER STARTED — check journalctl -u $UNIT"

log "waiting for the fresh world to write map_t.bin"
# The save dir is (re)created only once the world actually loads; map_t can lag the
# boot marker. Wait, then force one save if it still is not there.
SAVED=no
for i in $(seq 1 60); do
  if [[ -s $SAVE/map_t.bin ]]; then SAVED=yes; break; fi
  sleep 5
done
if [[ "$SAVED" != "yes" ]]; then
  log "map_t absent after 5min — forcing a save through the fifo"
  echo save > "$FIFO" 2>/dev/null || true
  for i in $(seq 1 24); do
    sleep 5
    [[ -s $SAVE/map_t.bin ]] && { SAVED=yes; break; }
  done
fi
[[ "$SAVED" == "yes" ]] || die "no map_t.bin after boot + forced save — world did not initialize"

log "post-boot verification"
python3 - "$SAVE" <<'PY'
import struct, sys, os
d = open(os.path.join(sys.argv[1], "map_t.bin"), "rb").read()
assert d[0:4] == b"GMTM", "bad map_t magic"
n = struct.unpack(">i", d[12:16])[0]; t = struct.unpack(">f", d[24:28])[0]
day, m, y = struct.unpack(">iii", d[28:40])
print(f"  clock: nights={n} tod={t:.2f}h day={day+1} month={m+1} year={y}")
print("  fresh-world signature: nights==0 and year==1993")
print("  OK" if (n == 0 and y == 1993) else "  WARN: clock is not a fresh world")
PY
grep -E "loading [0-9]+ zones from map_animals.bin|Workshop: onItemQueryCompleted" $Z/server-console.txt | tail -2
ss -ulpn | grep -E '1626[12]' | awk '{print "  bound: "$4}'
python3 - <<'PY'
import sqlite3
c = sqlite3.connect("/var/lib/zomboid-server/Zomboid/db/amc.db")
print("  whitelist rows:", c.execute("select count(*) from whitelist").fetchone()[0],
      "| roles:", c.execute("select role,count(*) from whitelist group by role").fetchall())
PY

log "waiting for the status notifier to re-seed its clock from the new world"
# The notifier is a 1-min timer; give it a few ticks, then assert the state it wrote
# tracks the fresh map_t instead of silently having kept the pre-wipe clock.
SEEDED=no
for i in $(seq 1 30); do
  if [[ -s $CLOCK_STATE ]]; then SEEDED=yes; break; fi
  sleep 10
done
if [[ "$SEEDED" == "yes" ]]; then
  python3 - "$CLOCK_STATE" "$SAVE/map_t.bin" <<'PY'
import json, struct, sys
st = json.load(open(sys.argv[1]))
d = open(sys.argv[2], "rb").read()
n = struct.unpack(">i", d[12:16])[0]; t = struct.unpack(">f", d[24:28])[0]
save = n * 86400 + t * 3600
gap = (st.get("current_sec", 0) - save) / 86400
print(f"  notifier clock gap vs map_t: {gap:+.2f}d")
print("  OK" if abs(gap) <= 1 else "  WARN: notifier clock did not re-seed from the new world")
PY
else
  log "WARN: notifier wrote no clock state yet — check journalctl -u zomboid-status-notify"
fi

log "restarting workshop watcher timer"
systemctl start zomboid-workshop-watch.timer

cat <<EOF

=== WIPE COMPLETE ($TS) ===
old world : $Z/Saves/Multiplayer/amc_wipe_$TS
archive   : $B/amc_prewipeFinal_$TS.tar.zst
kept      : db/amc.db (whitelist/roles), amc.ini, options.ini, workshop/mods
clock     : status-notifier state reset (old copy at $CLOCK_STATE.pre_wipe_$TS)
rollback  : stop unit -> mv amc_wipe_$TS amc -> start unit
            (+ restore the parked clock state if you roll the world back)
EOF
