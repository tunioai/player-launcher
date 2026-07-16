#!/usr/bin/env bash
#
# adb stress test for tunio_radio_player.
#
# Drives the REAL installed app through hostile conditions (network loss,
# screen off, media buttons, process kill) and after each one asserts the core
# appliance invariant: within a recovery window the app is producing audio
# again (live OR cached). "Producing audio" = media session PLAYING and the
# playback position advances between two samples.
#
# Usage:   ./stress_test.sh
# Env:     WINDOW=70   recovery window seconds (default 70)
#          CYCLES=5    repeated failover on/off cycles (default 5)
# Output:  summary on stdout + /tmp/tunio_stress_results.log
#          per-failure logcat tail in /tmp/tunio_stress_fail_<name>.log
#
# Requires: a connected device (adb), the app installed and a PIN already
# entered (the app autoconnects on launch), and at least one cached failover
# track (the app downloads one shortly after connecting).

PKG=ai.tunio.radioplayer
ACT="$PKG/.MainActivity"
WINDOW="${WINDOW:-70}"
CYCLES="${CYCLES:-5}"
RESULTS=/tmp/tunio_stress_results.log
: > "$RESULTS"

PASS=0
FAIL=0

log() { echo "[$(date +%T)] $*" | tee -a "$RESULTS"; }

proc_alive() { [ -n "$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; }
app_pid()    { adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }
msession()   { adb shell dumpsys media_session 2>/dev/null | tr -d '\r'; }
mstate()     { msession | grep -oE 'state=[A-Z]+\([0-9]\)' | head -1; }

# Audio is actually flowing = ground truth from AudioFlinger: our app owns an
# AudioTrack in state:started (PCM is being written to the output). This is the
# only reliable "sound is coming out" signal on-device.
#
# Why not media_session.position? For a live stream Android extrapolates the
# effective position from (position + elapsed*speed) while it only refreshes the
# stored `position=` field every few seconds; for a LOCAL failover file that
# stored field is not refreshed at all (it stays frozen) even though audio plays
# perfectly. Polling the stored field therefore gives false "stalled" negatives
# during cache playback. The AudioTrack state does not have this problem.
flowing() {
  local pid; pid=$(app_pid); [ -n "$pid" ] || return 1
  # Poll briefly so a momentary rebuffer/reconfigure isn't misread as a stall.
  for _ in $(seq 1 8); do
    if adb shell dumpsys audio 2>/dev/null | tr -d '\r' \
        | grep -Eq "type:android\.media\.AudioTrack u/pid:[0-9]+/${pid} state:started"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Poll up to WINDOW seconds for a healthy (audio-flowing) state.
wait_healthy() {
  local end=$((SECONDS + WINDOW))
  while [ "$SECONDS" -lt "$end" ]; do
    if proc_alive && flowing; then return 0; fi
    sleep 2
  done
  return 1
}

assert_recovers() { # <name>
  if wait_healthy; then
    log "PASS  $1"
    PASS=$((PASS + 1))
  else
    log "FAIL  $1  (state=$(mstate) alive=$(proc_alive && echo yes || echo no))"
    FAIL=$((FAIL + 1))
    adb logcat -d -v time 2>/dev/null | tail -150 > "/tmp/tunio_stress_fail_$1.log"
  fi
}

net_off()    { adb shell svc wifi disable >/dev/null 2>&1; adb shell svc data disable >/dev/null 2>&1; }
net_on()     { adb shell svc wifi enable  >/dev/null 2>&1; adb shell svc data enable  >/dev/null 2>&1; }
screen_off() { adb shell input keyevent KEYCODE_SLEEP  >/dev/null 2>&1; }
screen_on()  { adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; }
relaunch()   { adb shell am start -n "$ACT" >/dev/null 2>&1; }
kill_app()   { adb shell am force-stop "$PKG" >/dev/null 2>&1; }

log "=== STRESS START (WINDOW=${WINDOW}s, CYCLES=${CYCLES}) ==="
net_on; screen_on; sleep 3
kill_app; sleep 1; relaunch
if wait_healthy; then log "baseline: app playing"; else log "baseline: NOT PLAYING (aborting)"; log "=== DONE: PASS=$PASS FAIL=$FAIL ==="; exit 1; fi

# 1. Short network blip (buffer should absorb; should stay/return to playing).
log "--- short net drop (12s) ---"; net_off; sleep 12; net_on; assert_recovers short_net_drop

# 2. Long outage -> must failover to cached audio.
log "--- long net drop (45s) ---"; net_off; sleep 45; assert_recovers long_outage_cache
net_on; assert_recovers long_outage_restore

# 3. Rapid network flapping.
log "--- rapid net flap x5 ---"; for i in 1 2 3 4 5; do net_off; sleep 1; net_on; sleep 1; done; assert_recovers net_flap

# 4. Screen off + outage (background failover - the phone-Doze case).
log "--- screen off + outage ---"; screen_off; sleep 2; net_off; sleep 45; assert_recovers bg_outage_cache
net_on; sleep 2; screen_on; assert_recovers bg_restore

# 5. Media notification pause/play.
log "--- media pause/play ---"; adb shell input keyevent KEYCODE_MEDIA_PAUSE >/dev/null 2>&1; sleep 6
adb shell input keyevent KEYCODE_MEDIA_PLAY >/dev/null 2>&1; assert_recovers media_pause_play

# 6. Process kill + relaunch (online -> autoreconnect).
log "--- proc kill (online) ---"; kill_app; sleep 2; relaunch; assert_recovers proc_kill_online

# 7. Process kill + relaunch (offline -> startup failover to cache).
log "--- proc kill (offline) ---"; net_off; sleep 2; kill_app; sleep 2; relaunch; assert_recovers proc_kill_offline_cache
net_on; assert_recovers proc_kill_offline_restore

# 8. Repeated failover cycles.
log "--- repeated cycles x$CYCLES ---"
cyc_pass=0
for i in $(seq 1 "$CYCLES"); do
  net_off; sleep 40
  if proc_alive && flowing; then o=ok; else o=BAD; fi
  net_on; sleep 25
  if proc_alive && flowing; then r=ok; else r=BAD; fi
  log "  cycle $i: outage=$o restore=$r"
  [ "$o" = ok ] && [ "$r" = ok ] && cyc_pass=$((cyc_pass + 1))
done
if [ "$cyc_pass" -eq "$CYCLES" ]; then log "PASS  repeated_cycles ($cyc_pass/$CYCLES)"; PASS=$((PASS + 1))
else log "FAIL  repeated_cycles ($cyc_pass/$CYCLES)"; FAIL=$((FAIL + 1)); fi

net_on; screen_on
log "=== DONE: PASS=$PASS FAIL=$FAIL ==="
