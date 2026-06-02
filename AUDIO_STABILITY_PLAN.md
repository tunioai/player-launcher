# Audio stability rework — plan & reference

Branch: `infra/audio-stability` (forked from the branch that carries the stall
watchdog + proactive offline-mode fixes).

Goal: an appliance-grade player that "works like clockwork" — never silently
sleeps, never hangs, always recovers (live → cache → live) on phones and on
TVs (Samsung / Android TV / Xiaomi).

**Approach: targeted evolution, not a rewrite.** Keep the hard-won edge-case
handling (HLS recovery, service-suspended/warning mode, config polling, station
switching, web control, autostart, visualizer, updater). Replace only the
*foundation* the recovery logic stands on.

---

## 1. Current architecture map

Layers:

- `screens/home_screen.dart` — UI; play button calls `IRadioService.playPause()` / `reconnect()`.
- `services/radio/enhanced_radio_service.dart` (`EnhancedRadioService`, ~2.7k lines) — the state machine: connect/retry, config polling, failover orchestration, recovery triggers.
- `services/audio_service.dart` (`EnhancedAudioService`) — wraps a `just_audio` `AudioPlayer`; maps player state → `AudioState`; owns connectivity (`connectivity_plus`) and hang/stall detection.
- `services/audio/hls_stream_audio_source.dart` — custom `StreamAudioSource` that pulls the HLS playlist/segments over HTTP.
- `services/failover_service.dart` — local track cache (download/select/store).
- `services/api_service.dart` — backend config (`getStreamConfig`), syncs `SystemState.offlineMode` / service-suspended.
- `core/system_state.dart` — global flags (offline mode, service suspended).

### 1a. Player recreation (`_resetAudioPlayer`) — the core fragility

3 call sites in `audio_service.dart`:
1. **load-profile switch** (HLS↔live, different `AudioLoadConfiguration`) — fires on the *first* HLS connection every run (initial player is built non-HLS). **This is what breaks any single-player foreground service.**
2. **`stop()` timeout** — recovery.
3. **`stop()` error** — recovery.

Recreating ExoPlayer is heavy and leaves room for dangling connections / "ghost"
listeners (already noted in code comments). It is also incompatible with
`audio_service`/`just_audio_background` (which allow exactly one player).

### 1b. Failover triggers — 7 overlapping paths into `_activateFailover`

1. **Player error / idle** in `_handleAudioStateChange`: network-error branch, error-after-delay branch, and unexpected idle/paused ("stream interruption") branch — each attempts `_attemptStreamRestart` first, then failover.
2. **Network loss** in `_handleNetworkLoss` (HLS vs non-HLS), gated on a `connectivity_plus` disconnect event + sustained-loss timers.
3. **Connect/retry failure** in `_scheduleRetry` (network error + cached tracks → failover instead of retry).
4. **Stream health check** in `_handleHealthCheckFailure` (driven by ping failures).
5. **Hung-state watchdog** in `_forceConnectionRecovery` (via the 1s `_stateMonitorTimer`).
6. **Offline mode** (backend `offline_mode=true`) in `_performConnection` and `_refreshConfig`.
7. **Stall watchdog** (fix #1) in `audio_service._checkForHangs` → raises `AudioStateError('Network error')` → feeds path 1.

### 1c. Timer inventory (the "sprawl")

Periodic: config polling (60s), ping (30s), failover-background (30s),
hung-state monitor (1s) — radio; hang detection (5s) — audio.
One-shot delays: error-fallback (8s/4s), interruption (6s/3s), network-loss
(3s+), extra-HLS-wait (5s), connecting-timeout (70s), retry backoff, ping-grace
(6s), track-end-confirm (2s), warning-loop (20s), next-failover-track (1s).

These interact through ~5 boolean guards (`_isConnectionInProgress`,
`_isStreamSwitchInProgress`, `_isFailoverOperationInProgress`, `_userPaused`,
`_serviceSuspendedMode`). The interactions are hard to verify and are the main
breeding ground for rare hangs (e.g. notification-pause ambiguity, "Paused = is
it an interruption?" ambiguity).

### 1d. Known fragilities (observed this session)

- `connectivity_plus` reports interface presence, not reachability → blind to
  "Wi-Fi up but stream/internet gone" (common on TVs).
- Mid-stream stall surfaces as `AudioStatePlaying` (player keeps `playing=true`
  while buffering) → masks every `isPlaying`-gated trigger. (Mitigated by the
  position-progress watchdog; should become the single source of truth.)
- No Android foreground service → OS freezes/Dozes the process in background
  once audio stops → recovery logic can't run until foregrounded (phones).
- HLS source historically swallowed network errors (mitigated: surfaces an
  error after a sustained outage).

---

## 2. Target architecture

1. **Single `AudioPlayer` instance.** Create once; never recreate. Decide the
   buffer/load configuration once (or change it without recreating). Replace
   `_resetAudioPlayer` recovery with `stop()` + re-`setAudioSource` on the same
   player, or a guarded one-time re-init.
2. **Foreground service on Android.** With single-player in place,
   `just_audio_background` (or `audio_service` directly) provides the
   foreground service + MediaSession so the OS won't freeze the process.
   Platform-branch: Android uses the FGS; Windows/macOS keep plain `just_audio`
   (FGS unsupported/unneeded there). Route MediaSession controls through the
   radio service so notification play/pause matches in-app pause (suspends auto
   recovery), avoiding the auto-resume-on-notification-pause issue.
3. **One authoritative watchdog.** "Are we actually producing audio right now?
   If not for N seconds → one clean recovery action (restart → cache)." The
   position-progress watchdog (fix #1) is its core. Collapse the overlapping
   error/idle/ping/network-loss heuristics into feeding this single decision,
   reducing guard interactions.

Non-goals: changing *what* failover does, the cache logic, the
service-suspended/warning flow, web control, autostart, or the UI.

---

## 3. Phased, verifiable plan

Each phase ships independently and is verified on a real phone **and** a Samsung
TV before the next. Keep `infra/just-audio` as the working fallback.

- **Phase 0 — safety net.** Add/extend tests around the audio-service player
  lifecycle and the recovery state machine so regressions are caught before
  device testing.
- **Phase 1 — single-player.** Remove the load-profile recreation; create the
  player once with a config that serves both HLS and live (or switch config
  without recreation). Convert the two `stop()`-recovery recreations to
  same-player recovery. Verify: normal playback, station switch, HLS↔live,
  failover↔restore all still work; no second `AudioPlayer` is ever created.
- **Phase 2 — foreground service.** Re-introduce the FGS on top of single-player
  (Android only). Verify background playback + background failover with the
  screen off; verify notification controls route through the radio service.
- **Phase 3 — unify recovery.** Make the position/output watchdog the single
  recovery trigger; reduce the other heuristics to inputs. Shrink the guard set.
  Verify all failover scenarios still trigger and none double-fire.
- **Phase 4 — device provisioning.** Actively prompt for battery-optimization
  exemption (permission already declared) and guide OEM autostart / "don't sleep"
  settings; consider kiosk/lock-task for appliance deployments.

---

## 4. Risks & mitigations

- **Regressing battle-tested edge handling.** → Incremental phases, real-device
  verification each step, working fallback branch, Phase 0 tests first.
- **`just_audio_background` constraints** (single player; no Windows support). →
  Single-player is a prerequisite (Phase 1); platform-branch the FGS.
- **Buffer tuning when not recreating per stream type.** → Pick a unified
  `AudioLoadConfiguration` validated for both HLS and live; tune by measurement.
- **OEM process killers (Xiaomi/Samsung).** → Phase 4; document that code alone
  cannot guarantee survival without battery/autostart exemptions.

---

## 5. Honest limits

Even perfect code cannot 100% guarantee "never sleeps" on aggressive OEMs
without device-side battery/autostart exemptions (Phase 4) or kiosk mode. By
platform: TVs (always on, no battery killers) are covered mainly by the stall
watchdog (fix #1, already in); phones additionally need the FGS (Phase 2) and
provisioning (Phase 4).
