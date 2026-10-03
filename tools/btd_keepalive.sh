#!/bin/bash
# btd_keepalive.sh start|stop|status   (2026-10-02, Jon)
# Keeps the BTD 700's Auracast broadcast alive: the dongle stops broadcasting when the Mac stops sending samples, and the
# headphones then drop off (and may not rejoin by themselves). This plays pink noise (audiokeepalive) at -70 dBFS -- below hearing, never pure
# digital silence (some dongles power down on all-zero samples) -- straight to the device BY NAME, so the default output does not
# matter, under caffeinate (no display / idle / system sleep). It runs outside SuperCollider, so rebooting SC never drops the
# stream. If the BTD 700 disappears, audiokeepalive exits and the loop retries every 5 s.
DEV="${BTD_DEVICE:-BTD 700}"; LEVEL="${BTD_LEVEL:--70}"
STATE="$HOME/.local/state"; PIDF="$STATE/btd_keepalive.pid"; LOG="$STATE/btd_keepalive.log"; mkdir -p "$STATE"
KA="$HOME/.local/bin/audiokeepalive"   # rig/tools/audiokeepalive.swift (sox could not open the BTD 700 by name: it took the input half)
running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }
case "${1:-status}" in
  start)
    if running; then echo "btd_keepalive: already running (pid $(cat "$PIDF"))"; exit 0; fi
    nohup caffeinate -dims bash -c "while true; do \"$KA\" \"$DEV\" $LEVEL; echo \"\$(date +%T) keepalive exited (is '$DEV' connected?) -- retrying in 5 s\"; sleep 5; done" >>"$LOG" 2>&1 &
    echo $! > "$PIDF"; sleep 1
    if running; then echo "btd_keepalive: started (pid $(cat "$PIDF")) -> '$DEV' at ${LEVEL} dBFS pink noise"; else echo "btd_keepalive: FAILED to start (see $LOG)"; exit 1; fi ;;
  stop)
    if running; then pkill -P "$(cat "$PIDF")" 2>/dev/null; pkill -f "audiokeepalive $DEV" 2>/dev/null; kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; echo "btd_keepalive: stopped"; else echo "btd_keepalive: not running"; fi ;;
  status)
    if running; then echo "btd_keepalive: running (pid $(cat "$PIDF")) -> '$DEV'"; tail -2 "$LOG" 2>/dev/null; else echo "btd_keepalive: not running"; fi ;;
  *) echo "usage: btd_keepalive.sh start|stop|status"; exit 2 ;;
esac
