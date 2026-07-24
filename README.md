# Tunio Spot

A Flutter application for Android, Android TV, macOS, and Windows that automatically plays online radio streams with auto-start, always-on background playback (Android foreground media service), advanced network resilience, and intelligent offline failover.

## Features

### 🎵 **Core Playback**
- **Auto-start**: Application automatically launches when device boots up
- **API Integration**: Connects to Tunio API for stream configuration
- **Always-on Background Playback**: Backed by an Android foreground media service (MediaSession) so audio — and the failover logic — keeps running with the screen off or the app in the background
- **Media Controls**: Notification and lock-screen controls, plus hardware/Bluetooth media buttons
- **Broad Stream Support**: Live ICY/Icecast streams and HLS (`.m3u8`) served by a single, long-lived audio engine
- **Adaptive Buffering**: Platform-tuned for stability over latency (always-on appliance)
- **Volume Control**: Local and remote volume management with real-time sync

### 🔄 **Advanced Network Resilience**
- **Intelligent Failover System**: Automatic offline mode with cached music tracks
- **Smart Network Detection**: Fast detection of connectivity issues (10-15 seconds vs 1-2 minutes)
- **Automatic Recovery**: Seamless restoration to live stream when network returns
- **Background Monitoring**: Continuous config updates and track downloads during failover
- **Network Status Display**: Real-time "Connected", "Disconnected", or "Offline Mode" indicators

### 💾 **Local Track Caching**
- **Smart Track Downloads**: Automatically caches up to 40 music tracks locally
- **Music-only Filtering**: Only downloads actual music tracks (skips ads, jingles, station IDs)
- **TTL Management**: Auto-refreshes tracks older than 2 days
- **Intelligent Cleanup**: Removes expired tracks and maintains cache size
- **Offline Playback**: Seamless playback of cached tracks when internet fails

### 📱 **Cross-Platform Support**
- **Android**: Full support with auto-start functionality
- **Android TV**: Optimized for TV screens with full remote control support
- **macOS**: Full support for desktop usage
- **TV Remote Support**: Complete navigation with TV remote control
- **Focus Management**: Optimized interface for TV screens

### 📦 **Release builds**

Pushing a version tag triggers GitHub Actions (`.github/workflows/release.yml`) to build and attach Android (Play `.aab` + standalone `.apk`), macOS, and Windows artifacts to a GitHub Release:

```bash
git tag v1.4.0
git push origin v1.4.0
```


## Installation

### Prerequisites

- Flutter SDK 3.5.0 or higher (CI builds on 3.32.4)
- Android SDK for Android / Android TV builds (API level 21+)
- Xcode for macOS builds
- Visual Studio (Desktop development with C++) for Windows builds

### Building the Application

1. Clone the repository:
```bash
git clone <repository-url>
cd tunio_radio_player
```

2. Install dependencies:
```bash
flutter pub get
```

3. For Android — build a flavored APK/bundle (`standalone` = direct install with in-app self-update, `play` = Google Play):
```bash
flutter build apk --release --flavor standalone --dart-define=APP_FLAVOR=standalone
flutter build appbundle --release --flavor play --dart-define=APP_FLAVOR=play
```

4. For macOS / Windows:
```bash
flutter build macos --release
flutter build windows --release
```

5. Install on device:
```bash
flutter install
```

## Usage

### Initial Setup

1. Launch the application
2. Enter your Tunio API key in the "API Key" field
3. Press the "Connect" button
4. The app will automatically start playback upon successful connection

### Playback Controls

- **Play/Pause**: Use the central button to control playback
- **Volume**: Adjust volume using the slider
- **Status**: Monitor connection and playback status through the status indicator

### Auto-start Functionality

After saving the API key, the application will:
- Automatically launch when the device boots up
- Connect to the API and begin playback
- Run in background mode
- Survive network disconnections with automatic reconnection

### TV Remote Control Support

The application is fully optimized for Android TV and supports complete navigation using TV remote control:

- **Navigation**: Use directional pad (D-pad) to navigate between interface elements
- **Selection**: OK/Enter button to activate selected elements
- **Media Keys**: Play/Pause, Stop, Volume +/- work globally
- **Number Input**: Use number keys (0-9) for PIN code entry
- **Visual Feedback**: Clear focus indicators with blue borders and highlighting
- **Seamless Control**: All functions accessible without touch input

For detailed instructions, see [TV Remote Guide](TV_REMOTE_GUIDE.md).

## 🔄 Intelligent Failover System

### How It Works

The Tunio Spot application features an advanced failover system that ensures continuous music playback even when the internet connection is lost or unstable.

#### **Live Stream Mode (Normal Operation)**
- Streams live audio from the server
- Downloads music tracks in the background for local cache
- Monitors network connectivity and stream health
- Real-time volume and configuration updates from server

#### **Offline Mode (Failover)**
- **Automatic Activation**: Triggered when network issues are detected
- **Seamless Transition**: Instantly switches to cached music tracks
- **Continuous Playback**: Plays cached tracks, prioritizing least recently played to avoid repeats
- **Background Recovery**: Monitors for network restoration while playing offline

#### **Network Recovery**
- **Automatic Detection**: Continuously checks for network restoration
- **Smart Restoration**: Attempts to return to live stream between tracks
- **Background Updates**: Downloads new tracks and config updates during failover
- **Volume Sync**: Applies server volume changes immediately during offline mode

### Failover Triggers

The system activates failover mode when:
- **Initial Connection Failure**: No internet during app startup
- **Stream Interruption**: Live stream stops unexpectedly
- **Network Loss**: WiFi/mobile data disconnection detected
- **Audio Errors**: Stream playback errors (buffering failures, source errors)
- **Ping Failures**: Server connectivity issues detected
- **API Timeouts**: Server becomes unreachable

### Local Track Caching

#### **Automatic Downloads**
- **Background Process**: Downloads tracks while live stream plays
- **Music Filter**: Only caches actual music (filters out ads, jingles, station IDs using `is_music` flag)
- **Smart Selection**: Prioritizes currently playing tracks for immediate availability

#### **Cache Management**
- **Storage Limit**: Maximum 40 tracks cached locally
- **TTL System**: Tracks expire after 2 days and are auto-refreshed
- **Size Optimization**: Automatic cleanup of oldest/expired tracks
- **Quality Balance**: Optimized for storage vs. quality

#### **Cache Location**
```
Android: /data/data/ai.tunio.radioplayer/files/failover_cache/
iOS: ~/Documents/failover_cache/
```

### Network Detection & Recovery

#### **Fast Detection (10-15 seconds)**
- **Ping Monitoring**: Server connectivity checks every 10 seconds
- **State Monitoring**: Connection state checks every 1 second
- **Stream Health**: Automatic detection of frozen/broken streams
- **Audio Error Handling**: Immediate failover on any audio errors

#### **Background Monitoring During Failover**
- **Config Updates**: Checks for server configuration changes every 30 seconds
- **New Track Downloads**: Automatically downloads fresh tracks when network available
- **Volume Sync**: Applies server volume changes immediately to current playback
- **Smart Recovery**: Attempts live stream restoration between offline tracks

### User Experience

#### **Status Indicators**
- **"Network: Connected"** - Live stream active
- **"Network: Offline Mode"** - Failover active, playing cached tracks
- **"Stream: Live"** - Streaming from server
- **"Stream: Failover"** - Playing local tracks

#### **Seamless Operation**
- **No Interruption**: Music continues playing during network issues
- **Transparent Recovery**: Automatic return to live stream when possible
- **Visual Feedback**: Clear status indicators for current mode
- **Background Operation**: All recovery happens automatically

## API Integration

The application uses the Tunio API to fetch stream configuration and current track information:

```
GET https://api.tunio.ai/v1/spot?pin=YOUR_PIN_CODE
```

Expected response format:
```json
{
  "stream_url": "http://stream.example.com:8000/stream",
  "volume": 0.8,
  "title": "Radio Station Name",
  "description": "Station description",
  "current": {
    "artist": "Artist Name",
    "title": "Song Title",
    "uuid": "unique-track-id",
    "duration": 180,
    "is_music": true,
    "url": "http://example.com/track.m4a"
  }
}
```

### API Features
- **Real-time Updates**: Periodic polling for configuration changes
- **Current Track Info**: Metadata for currently playing track
- **Music Classification**: `is_music` flag to filter content for caching
- **Volume Sync**: Server-controlled volume management
- **Track Downloads**: Direct URLs for offline caching

## Technical Details

### Architecture

The application follows a clean architecture pattern with enhanced state management:

- **Core States**: 
  - `AudioState` - Audio playback states (Idle, Loading, Buffering, Playing, Paused, Error)
  - `RadioState` - Radio service states (Disconnected, Connecting, Connected, Error, Failover)
  - `NetworkState` - Network connectivity tracking

- **Models**: 
  - `StreamConfig` - Stream configuration and metadata
  - `CurrentTrack` - Track information with music classification
  - `ApiError` - Structured error handling

- **Services**: 
  - `EnhancedRadioService` (`services/radio/`) - Core state machine orchestrating connection, failover, and live-restore
  - `EnhancedAudioService` (`services/audio_service.dart`) - Single long-lived `just_audio` player with `just_audio_background` integration and silent-stall detection
  - `HlsStreamAudioSource` (`services/audio/`) - Custom HLS / streaming source that surfaces sustained playlist outages
  - `FailoverService` - Local track caching and offline playback
  - `FailoverRecoveryBackoff` - Backoff policy for unstable live-restore
  - `ApiService` - API communication with retry logic
  - `NetworkService` - Network monitoring and connectivity
  - `StorageService` - Persistent data management
  - `AppUpdateService` - In-app self-update (standalone flavor)

- **UI**: 
  - `HomeScreen` - Primary interface with real-time status
  - `StatusIndicator` - Enhanced connection and mode indicators

### Background Playback & Reliability

The player is built to run unattended for long stretches (radio appliance / TV box), so background survival is a first-class concern:

- **Foreground media service**: `just_audio_background` runs a `mediaPlayback` foreground service (`com.ryanheise.audioservice.AudioService`); `MainActivity` extends `AudioServiceActivity`. This keeps the process — and the failover/recovery logic — alive while the screen is off or the app is backgrounded.
- **Single audio engine**: one `AudioPlayer` is created for the app's lifetime (no per-stream-type recreation), removing a class of state-loss/recreation races.
- **Battery-optimization exemption**: on Android startup the app proactively requests `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` to avoid Doze / process-freeze stalling background failover.
- **Silent-stall detection**: a position-based watchdog catches streams that stop advancing without raising an error and triggers recovery/failover.
- **Proactive offline mode**: when the backend `offline_mode` flag is enabled the player switches to cached tracks immediately, instead of waiting for the next interruption.
- **Reliable live-restore**: returning to the live stream is confirmed by actual player state (not just the `play()` future), with backoff that avoids thrashing between live and cache.

### Key Dependencies

- `just_audio: ^0.9.46` - Audio playback engine (ExoPlayer/media3 on Android)
- `just_audio_background: ^0.0.1-beta.17` - Android foreground media service, MediaSession, notification & lock-screen controls
- `just_audio_windows: ^0.2.2` - Windows playback backend
- `audio_session: ^0.1.21` - Audio session / focus management
- `connectivity_plus: ^6.1.0` - Network monitoring
- `shared_preferences: ^2.3.3` - Local storage
- `http: ^1.2.2` - Network requests

### Enhanced Network Resilience

#### **Multi-Layer Detection**
- **Ping Monitoring**: Server connectivity checks every 10 seconds
- **State Monitoring**: Connection state verification every 1 second  
- **Audio Error Detection**: Immediate response to playback failures
- **Stream Health Checks**: Proactive detection of frozen streams
- **Connectivity Tracking**: Real-time network state monitoring

#### **Intelligent Recovery**
- **Fast Failover**: 10-15 second detection vs. previous 1-2 minutes
- **Smart Retry Logic**: Adaptive reconnection with 5-second intervals
- **Failover Activation**: Automatic switch to cached tracks when network fails
- **Background Recovery**: Continuous restoration attempts during offline mode
- **Seamless Restoration**: Automatic return to live stream between tracks

#### **Buffering Strategy**
- **Unified Load Configuration**: one profile for both live and HLS — Android ~10–40 s buffer (8 MB target), Darwin 30 s forward buffer — tuned for stability over latency
- **Stream Continuity**: smooth playback over temporary interruptions, with silent-stall detection as a backstop

#### **Error Handling**
- **Comprehensive Coverage**: Handles all network scenarios
- **Graceful Degradation**: Falls back to offline mode when needed
- **Automatic Recovery**: Self-healing capabilities
- **User Transparency**: Clear status indicators for all conditions

### Android Permissions

The application declares the following key Android permissions:

- `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` - Network access & monitoring
- `WAKE_LOCK` - Prevent device sleep during playback
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` - Background media-playback service
- `MODIFY_AUDIO_SETTINGS` - Audio configuration
- `RECEIVE_BOOT_COMPLETED`, `AUTOSTART` - Auto-start on boot
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` - Battery-optimization exemption (background survival)
- `START_FOREGROUND_SERVICES_FROM_BACKGROUND`, `USE_FULL_SCREEN_INTENT` - TV box / set-top reliability

## Development

### Project Structure

```
lib/
├── core/
│   ├── audio_state.dart                  # Audio & radio state definitions
│   ├── system_state.dart                 # Global runtime state (e.g. offline_mode)
│   ├── service_locator.dart              # Dependency injection container
│   └── result.dart                       # Result wrapper for error handling
├── models/
│   ├── stream_config.dart                # Stream configuration & metadata
│   ├── current_track.dart                # Track metadata with music classification
│   ├── failover_event.dart               # Failover reporting events
│   └── api_error.dart                    # Structured API error handling
├── screens/
│   └── home_screen.dart                  # Primary UI; requests battery exemption on start
├── services/
│   ├── radio/
│   │   ├── enhanced_radio_service.dart   # Core state machine (connect/failover/restore)
│   │   ├── failover_recovery_backoff.dart  # Backoff for unstable live-restore
│   │   ├── retry_manager.dart            # Reconnection retry policy
│   │   └── i_radio_service.dart          # Service interface
│   ├── audio/
│   │   └── hls_stream_audio_source.dart  # Custom HLS / streaming source
│   ├── audio_service.dart                # Single just_audio player + background service
│   ├── failover_service.dart             # Local track caching & offline playback
│   ├── failover_reporting_service.dart   # Failover telemetry reporting
│   ├── network_service.dart              # Network monitoring & connectivity
│   ├── api_service.dart                  # API communication with retry
│   ├── app_update_service.dart           # In-app self-update (standalone flavor)
│   ├── autostart_service.dart            # Boot auto-start + battery-exemption helpers
│   ├── local_web_server.dart             # On-device web management interface
│   └── storage_service.dart              # Persistent data management
├── utils/
│   ├── audio_config.dart                 # Unified player load configuration
│   ├── constants.dart                    # Cache settings (max tracks, TTL)
│   ├── platform_info.dart                # Platform detection / user agent
│   └── logger.dart                       # Categorized logging
├── widgets/
│   ├── status_indicator.dart             # Status display widgets
│   └── code_input_widget.dart            # PIN / API-key input
└── main.dart                             # Application entry point
```

### Platform Support

- **Android**: Full support with auto-start functionality
- **Android TV**: Optimized for TV screens with full remote control support
- **macOS**: Full support for desktop usage
- **Windows**: Full support for desktop usage (x64)

## Build Configuration

### Android
- Minimum SDK: API 21 (Android 5.0)
- Target SDK: Latest stable
- Supports arm64-v8a and armeabi-v7a architectures

### Generate icons
```
flutter pub run flutter_launcher_icons
```

### macOS
- Minimum version: macOS 10.14
- Supports both Intel and Apple Silicon

### Windows
- 64-bit (x64) desktop build
- Playback via `just_audio_windows`
- Pass `--minimized` to start with the window minimized:
  `tunio_radio_player.exe --minimized`
- The runner allows one instance per interactive Windows session; launching it
  again restores the existing window instead of creating a second audio player.
- For Task Scheduler, use **At log on**, **Run only when the user is logged on**,
  and a 20–30 second trigger delay. Start the executable directly rather than
  through `start` or a batch file.

## ⚙️ Configuration & Performance

### Failover Configuration
```dart
// In lib/utils/constants.dart
class AppConstants {
  static const int maxFailoverTracks = 40;          // Max cached tracks
  static const Duration trackCacheTTL = Duration(days: 2);  // Track expiration
  static const String failoverCacheDir = 'failover_cache';  // Cache directory
}
```

### Performance Optimizations
- **Fast Network Detection**: 10-second ping intervals (vs 30-second default)
- **Rapid State Monitoring**: 1-second connection checks (vs 3-second default)
- **Quick Recovery**: 5-second force recovery (vs 10-second default)
- **Stability-first Buffering**: generous platform-tuned buffers (see `lib/utils/audio_config.dart`)
- **Smart Caching**: Music-only filtering reduces storage by ~60%

### Monitoring & Debugging

#### **Log Categories**
- `🔄 CONNECTION`: Connection process stages
- `🚨 FAILOVER`: Failover activation and management
- `🔍 STREAM HEALTH`: Stream monitoring and health checks
- `🌐 NETWORK RESTORED`: Network recovery detection
- `🔄 FAILOVER BACKGROUND`: Background monitoring during offline mode

#### **Status Tracking**
- Connection attempts and stages
- Failover activation triggers
- Cache management operations
- Network state transitions
- Audio playback health

### Storage Requirements
- **Base App**: ~15-30 MB
- **Cached Tracks**: ~2-4 MB per track (~80-160 MB total for 40 tracks)
- **Total Storage**: ~95-190 MB maximum

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly on both platforms
5. Submit a pull request

## Support

For support and issues:
- Create an issue in the project repository
- Contact the development team
- Check the troubleshooting section above

---

**Note**: This application is designed for streaming radio content and requires a valid Tunio API key for operation.
