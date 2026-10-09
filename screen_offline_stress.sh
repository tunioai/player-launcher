#!/usr/bin/env bash
#
# adb stress test for the launcher's SCREEN (visualizer) under network loss.
#
# Companion to stress_test.sh, which asserts audio. This one asserts the
# display: through an outage, a cold start without a network (stream point and
# screen-only point), flapping and an optional real reboot, the device must
# show the screen page -- never the pairing screen, never the browser's error
# page -- and must not reload it when the network returns.
#
# Ground truth per check:
#   front activity   `dumpsys activity activities` topResumedActivity
#                    (.VisualizerActivity = screen page, .MainActivity = pairing/home)
#   page reloads     "onPageFinished" lines from VisualizerActivity in logcat
#   offline copy     "Page cache serving the offline copy" in logcat
#   app state        local admin http://localhost:9292/api/state (adb forward)
#   audio (stream)   an AudioTrack of our pid in state:started (as stress_test.sh)
#   screenshots      $OUT/<step>.png for a human look
#
# Usage:  PIN_STREAM=111111 PIN_SCREEN=222222 ./screen_offline_stress.sh
# Env:    PIN_STREAM  pin of a link with a stream AND a screen (required)
#         PIN_SCREEN  pin of a screen-only link (optional; skipped if unset)
#         APK=path    install this apk first (adb install -r), optional
#         WARMUP=180  seconds to let the page/video cache fill after pairing
#         OUTAGE=180  outage length for the open-screen scenario
#         FLAPS=5     off/on cycles in the flapping scenario
#         REBOOT=1    also reboot the device without a network (autostart must
#                     be allowed for the app on the device)
#         SKIP_STREAM=1  run only the screen-only scenarios (PIN_STREAM is
#                     still required by the argument check, any value will do)
#         SERIAL=...  adb serial when several devices are attached
#         OUT=dir     results dir (default /tmp/tunio_screen_stress/<timestamp>)
#
# Requires: adb, curl, python3. Toggles the device's Wi-Fi and mobile data
# (`svc`), kills and relaunches the app, and may reboot it with REBOOT=1.

PKG=ai.tunio.radioplayer
MAIN="$PKG/.MainActivity"
VIS="$PKG/.VisualizerActivity"
ADMIN=http://127.0.0.1:9292
ADMIN_KEY="${ADMIN_KEY:-tunio}"
WARMUP="${WARMUP:-180}"
OUTAGE="${OUTAGE:-180}"
FLAPS="${FLAPS:-5}"
OUT="${OUT:-/tmp/tunio_screen_stress/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
RESULTS="$OUT/results.log"
: > "$RESULTS"

PASS=0
FAIL=0

adb() { command adb ${SERIAL:+-s "$SERIAL"} "$@"; }

log()  { echo "[$(date +%T)] $*" | tee -a "$RESULTS"; }
pass() { log "PASS  $1"; PASS=$((PASS + 1)); }
fail() {
  log "FAIL  $1  ($2)"
  FAIL=$((FAIL + 1))
  tr -d '\r' < "$LOGCAT_FILE" | grep -E "flutter|VisualizerActivity|STRESS" | tail -400 > "$OUT/fail_$1.log"
  shot "fail_$1"
}
die() { log "ABORT: $*"; summary; exit 2; }

# ---- device helpers -------------------------------------------------------

# The activity the user sees, as "<pkg>/.Name". The window manager's focused
# app is the most direct answer; the activity manager's resumed activity is
# the fallback (older Android reports it as mResumedActivity).
front() {
  local a
  a=$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -E 'mFocusedApp=' | head -1 \
      | grep -oE "$PKG/\.[A-Za-z]+" | head -1)
  [ -n "$a" ] && { echo "$a"; return; }
  adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' \
    | grep -E 'topResumedActivity=|mResumedActivity=' | head -1 \
    | grep -oE "$PKG/\.[A-Za-z]+" | head -1
}
screen_in_front() { [ "$(front)" = "$VIS" ]; }
proc_alive()      { [ -n "$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; }
app_pid()         { adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }
shot()            { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; }

# Audio is flowing = our pid owns an AudioTrack in state:started (see
# stress_test.sh for why media_session.position is not usable here).
flowing() {
  local pid; pid=$(app_pid); [ -n "$pid" ] || return 1
  for _ in $(seq 1 8); do
    if adb shell dumpsys audio 2>/dev/null | tr -d '\r' \
        | grep -Eq "type:android\.media\.AudioTrack u/pid:[0-9]+/${pid} state:started"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Best effort: MIUI refuses input injection and WRITE_SETTINGS from the shell
# unless "USB debugging (security settings)" is on; keep the device unlocked
# by hand in that case.
wake() {
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
  adb shell wm dismiss-keyguard >/dev/null 2>&1
  adb shell cmd statusbar collapse >/dev/null 2>&1
}
relaunch() { adb shell am start -n "$MAIN" >/dev/null 2>&1; }
kill_app() { adb shell am force-stop "$PKG" >/dev/null 2>&1; }

# ---- network --------------------------------------------------------------

has_internet() { adb shell ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; }
net_off() {
  adb shell svc wifi disable >/dev/null 2>&1
  adb shell svc data disable >/dev/null 2>&1
  local i
  for i in $(seq 1 15); do has_internet || { log "network OFF"; return 0; }; sleep 1; done
  # svc did not cut it on this device: airplane mode as the big hammer.
  adb shell cmd connectivity airplane-mode enable >/dev/null 2>&1
  for i in $(seq 1 15); do has_internet || { log "network OFF (airplane)"; return 0; }; sleep 1; done
  log "WARN: device still reaches the internet after net_off"
  return 1
}
net_on() {
  adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1
  adb shell svc wifi enable >/dev/null 2>&1
  adb shell svc data enable >/dev/null 2>&1
  local i
  for i in $(seq 1 40); do has_internet && { log "network ON"; return 0; }; sleep 1; done
  log "WARN: device has no internet after net_on"
  return 1
}

# ---- local admin (port 9292, forwarded) -----------------------------------

admin()       { curl -s -m 5 "$ADMIN/$1?key=$ADMIN_KEY" "${@:2}"; }
admin_up()    { admin api/state | grep -q '"ok":true'; }
state_field() { admin api/state | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }
set_pin()     { admin api/pin -X POST -H 'Content-Type: application/json' -d "{\"pin\":\"$1\"}" >/dev/null; }
cache_info()  {
  admin api/screen-cache | python3 -c '
import json,sys
d=json.load(sys.stdin)
v=d.get("video",{}); i=d.get("images",{}); p=d.get("page",{})
print("videos=%s (%d MB) images=%s page=%s" % (v.get("count"), int(v.get("bytes",0))//1048576, i.get("count"), p.get("count")))' 2>/dev/null
}
state_connected() { state_field source | grep -q '^Online'; }

# ---- logcat windows -------------------------------------------------------
# logcat is streamed to a file for the whole run: the device's own ring
# buffer is 256 KiB and a chatty phone wraps it in a minute, so a marker
# line injected at the start of a scenario is gone by the time the
# scenario ends. Windows are cut by device time instead ("since M" is every
# line logged after mark M was taken), and the marker is still injected so a
# human reading the log can see where each scenario began.

LOGCAT_FILE="$OUT/logcat_live.txt"
logcat_start() {
  adb logcat -G 16M >/dev/null 2>&1   # best effort, not every device allows it
  adb logcat -c >/dev/null 2>&1
  logcat_resume
}
logcat_resume() {
  adb logcat -v epoch >> "$LOGCAT_FILE" 2>/dev/null &
  LOGCAT_PID=$!
}
logcat_stop() { [ -n "${LOGCAT_PID:-}" ] && kill "$LOGCAT_PID" 2>/dev/null; LOGCAT_PID=; }

mark() {
  adb shell date +%s 2>/dev/null | tr -d '\r' > "$OUT/mark_$1"
  adb shell log -t STRESS "$1" >/dev/null 2>&1
}
since() {
  local t; t=$(cat "$OUT/mark_$1" 2>/dev/null || echo 0)
  tr -d '\r' < "$LOGCAT_FILE" | awk -v t="$t" '($1 + 0) >= t'
}
count_since() { since "$1" | grep -cE "$2"; }

wait_for() { # <seconds> <command...>
  local end=$((SECONDS + $1)); shift
  while [ "$SECONDS" -lt "$end" ]; do "$@" && return 0; sleep 2; done
  return 1
}

# ---- scenarios ------------------------------------------------------------

# Pair with <pin> (via the local admin, no typing on the device) and let the
# page/video cache fill while online. Everything else builds on this warm
# state, exactly as a point in the field has been running for days.
scenario_warmup() { # <pin> <label>
  local pin=$1 label=$2
  log "--- warm-up [$label]: pair $pin, cache fills for ${WARMUP}s ---"
  net_on
  kill_app; sleep 1; relaunch
  wait_for 60 admin_up || die "local admin not reachable on :9292 (is the app running?)"
  [ "$(state_field pin)" = "$pin" ] || set_pin "$pin"
  if wait_for 120 screen_in_front; then pass "warmup_${label}_screen_opens"
  else fail "warmup_${label}_screen_opens" "front=$(front) source=$(state_field source)"; fi
  sleep "$WARMUP"
  log "  cache: $(cache_info)"
  shot "${label}_01_warm_online"
}

# The network goes away while the screen is open and stays away for OUTAGE
# seconds. The page must stay, keep its data from the offline copy, and come
# back without a reload.
scenario_outage_open() { # <label> <stream|screen>
  local label=$1 kind=$2 n
  log "--- outage with the screen open (${OUTAGE}s) [$label] ---"
  mark "OUT_${label}"
  net_off
  sleep "$OUTAGE"
  shot "${label}_02_outage_open"
  if screen_in_front; then pass "${label}_outage_screen_stays"
  else fail "${label}_outage_screen_stays" "front=$(front) source=$(state_field source)"; fi
  n=$(count_since "OUT_${label}" 'VisualizerActivity.*onPageFinished')
  [ "$n" -eq 0 ] && pass "${label}_outage_no_reload" || fail "${label}_outage_no_reload" "reloads=$n"
  n=$(count_since "OUT_${label}" 'Page cache serving the offline copy')
  [ "$n" -gt 0 ] && pass "${label}_outage_offline_copy_served" \
                 || log "  note: the page made no requests in ${OUTAGE}s (none served from the copy)"
  if [ "$kind" = stream ]; then
    flowing && pass "${label}_outage_audio_from_cache" || fail "${label}_outage_audio_from_cache" "source=$(state_field source)"
  fi

  mark "BACK_${label}"
  net_on
  if [ "$kind" = stream ]; then
    # Audio restore waits for a track boundary or the 3 min grace.
    if wait_for 240 state_connected && flowing; then pass "${label}_restore_audio_live"
    else fail "${label}_restore_audio_live" "source=$(state_field source)"; fi
  else
    sleep 60
  fi
  shot "${label}_03_after_restore"
  if screen_in_front; then pass "${label}_restore_screen_stays"
  else fail "${label}_restore_screen_stays" "front=$(front)"; fi
  n=$(count_since "BACK_${label}" 'VisualizerActivity.*onPageFinished')
  [ "$n" -eq 0 ] && pass "${label}_restore_no_reload" || fail "${label}_restore_no_reload" "reloads=$n"
}

# The box boots (here: the process is killed and relaunched) with no network
# at all -- the morning at the venue. The screen must open from the cache.
scenario_cold_start_offline() { # <label> <stream|screen>
  local label=$1 kind=$2 n
  log "--- cold start without network [$label] ---"
  net_off; sleep 2
  kill_app; sleep 2
  mark "COLD_${label}"
  relaunch
  if wait_for 150 screen_in_front; then pass "${label}_cold_screen_opens"
  else fail "${label}_cold_screen_opens" "front=$(front) source=$(state_field source)"; fi
  # Offline, every request waits out its timeout before the copy is served.
  sleep 45
  shot "${label}_04_cold_start_offline"
  n=$(count_since "COLD_${label}" 'Page cache serving the offline copy')
  [ "$n" -gt 0 ] && pass "${label}_cold_page_from_copy" || fail "${label}_cold_page_from_copy" "nothing served from the offline copy"
  n=$(count_since "COLD_${label}" 'Page cache miss while offline')
  log "  offline misses: $n (expected 0 after a warm-up; a miss is a resource the page needs that was never cached)"
  if [ "$kind" = stream ]; then
    n=$(count_since "COLD_${label}" 'OFFLINE FAILOVER: Using the remembered config')
    [ "$n" -gt 0 ] && pass "${label}_cold_remembered_config" || fail "${label}_cold_remembered_config" "no remembered-config line in logcat"
    flowing && pass "${label}_cold_audio_from_cache" || fail "${label}_cold_audio_from_cache" "source=$(state_field source)"
  else
    n=$(count_since "COLD_${label}" 'SCREEN-ONLY OFFLINE')
    [ "$n" -gt 0 ] && pass "${label}_cold_screen_only_offline" || fail "${label}_cold_screen_only_offline" "no screen-only offline line in logcat"
  fi

  mark "COLDBACK_${label}"
  net_on
  if [ "$kind" = stream ]; then
    if wait_for 240 state_connected && flowing; then pass "${label}_cold_restore_audio_live"
    else fail "${label}_cold_restore_audio_live" "source=$(state_field source)"; fi
  else
    sleep 90
    state_connected && pass "${label}_cold_restore_connected" || fail "${label}_cold_restore_connected" "source=$(state_field source)"
  fi
  shot "${label}_05_cold_after_restore"
  if screen_in_front; then pass "${label}_cold_restore_screen_stays"
  else fail "${label}_cold_restore_screen_stays" "front=$(front)"; fi
  n=$(count_since "COLDBACK_${label}" 'VisualizerActivity.*onPageFinished')
  [ "$n" -eq 0 ] && pass "${label}_cold_restore_no_reload" || fail "${label}_cold_restore_no_reload" "reloads=$n"
}

# Repeated short outages. The screen must stay up throughout, nothing may
# reload, and the process must be the same one at the end.
scenario_flapping() { # <label>
  local label=$1 i a b ok=0 pid0 n
  log "--- flapping x$FLAPS (off 40s / on 80s) [$label] ---"
  pid0=$(app_pid)
  mark "FLAP_${label}"
  for i in $(seq 1 "$FLAPS"); do
    net_off; sleep 40
    if screen_in_front; then a=ok; else a=BAD; shot "${label}_flap${i}_outage"; fi
    net_on; sleep 80
    if screen_in_front; then b=ok; else b=BAD; shot "${label}_flap${i}_restore"; fi
    log "  cycle $i: outage=$a restore=$b"
    [ "$a" = ok ] && [ "$b" = ok ] && ok=$((ok + 1))
  done
  [ "$ok" -eq "$FLAPS" ] && pass "${label}_flapping_screen_stays ($ok/$FLAPS)" || fail "${label}_flapping_screen_stays" "$ok/$FLAPS"
  n=$(count_since "FLAP_${label}" 'VisualizerActivity.*onPageFinished')
  [ "$n" -eq 0 ] && pass "${label}_flapping_no_reload" || fail "${label}_flapping_no_reload" "reloads=$n"
  [ "$(app_pid)" = "$pid0" ] && pass "${label}_flapping_same_process" || fail "${label}_flapping_same_process" "pid $pid0 -> $(app_pid)"
}

# A real reboot with Wi-Fi off: BootReceiver autostart, no network from the
# first second -- the exact venue morning.
scenario_reboot_offline() { # <label> <stream|screen>
  local label=$1 kind=$2 n
  log "--- reboot without network [$label] ---"
  net_off; sleep 2
  logcat_stop
  adb reboot
  adb wait-for-device
  wait_for 180 sh -c '[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ]' || die "device did not finish booting"
  log "  booted; waiting for autostart"
  logcat_resume
  mark "REBOOT_${label}"
  wake
  adb forward tcp:9292 tcp:9292 >/dev/null
  if wait_for 240 screen_in_front; then pass "${label}_reboot_screen_opens"
  else fail "${label}_reboot_screen_opens" "front=$(front) alive=$(proc_alive && echo yes || echo no)"; fi
  sleep 45
  shot "${label}_06_reboot_offline"
  net_on
  if [ "$kind" = stream ]; then
    if wait_for 240 state_connected && flowing; then pass "${label}_reboot_restore_audio_live"
    else fail "${label}_reboot_restore_audio_live" "source=$(state_field source)"; fi
  else
    sleep 90
  fi
  screen_in_front && pass "${label}_reboot_restore_screen_stays" || fail "${label}_reboot_restore_screen_stays" "front=$(front)"
  shot "${label}_07_reboot_after_restore"
}

summary() {
  net_on >/dev/null 2>&1
  logcat_stop
  log "=== DONE: PASS=$PASS FAIL=$FAIL  results: $OUT ==="
}

# ---- main -----------------------------------------------------------------

[ -n "${PIN_STREAM:-}" ] || { echo "PIN_STREAM is required (a link with a stream and a screen)"; exit 2; }
command -v adb >/dev/null || { echo "adb not found"; exit 2; }
adb get-state >/dev/null 2>&1 || { echo "no device (adb get-state failed)"; exit 2; }

log "=== SCREEN STRESS START (WARMUP=${WARMUP}s OUTAGE=${OUTAGE}s FLAPS=$FLAPS) ==="
log "device: $(adb shell getprop ro.product.model | tr -d '\r') android $(adb shell getprop ro.build.version.release | tr -d '\r')"
logcat_start
trap logcat_stop EXIT
wake
if [ -n "${APK:-}" ]; then
  log "installing $APK"
  adb install -r "$APK" >/dev/null || die "install failed"
fi
adb forward tcp:9292 tcp:9292 >/dev/null

if [ "${SKIP_STREAM:-0}" = 1 ]; then
  log "SKIP_STREAM=1: stream-point scenarios skipped"
else
  scenario_warmup "$PIN_STREAM" stream
  scenario_outage_open stream stream
  scenario_cold_start_offline stream stream
  scenario_flapping stream
  [ "${REBOOT:-0}" = 1 ] && scenario_reboot_offline stream stream
fi

if [ -n "${PIN_SCREEN:-}" ]; then
  scenario_warmup "$PIN_SCREEN" screen
  scenario_outage_open screen screen
  scenario_cold_start_offline screen screen
  scenario_flapping screen
  [ "${REBOOT:-0}" = 1 ] && scenario_reboot_offline screen screen
else
  log "PIN_SCREEN not set: screen-only scenarios skipped"
fi

summary
[ "$FAIL" -eq 0 ]
