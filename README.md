# Tunio Spot

A Flutter application for Android and macOS that automatically plays online radio streams with auto-start functionality, advanced network resilience, and intelligent offline failover capabilities.

## Features

### 🎵 **Core Playback**
- **Auto-start**: Application automatically launches when device boots up
- **API Integration**: Connects to Tunio API for stream configuration
- **Background Playback**: Continues playing when app is minimized
- **Enhanced Buffering**: 4-second buffer for smooth playback
- **Volume Control**: Local and remote volume management with real-time sync

### 🔄 **Advanced Network Resilience**
- **Intelligent Failover System**: Automatic offline mode with cached music tracks
- **Smart Network Detection**: Fast detection of connectivity issues (10-15 seconds vs 1-2 minutes)
- **Automatic Recovery**: Seamless restoration to live stream when network returns
- **Background Monitoring**: Continuous config updates and track downloads during failover
- **Network Status Display**: Real-time "Connected", "Disconnected", or "Offline Mode" indicators

### 💾 **Local Track Caching**
- **Smart Track Downloads**: Automatically caches up to 20 music tracks locally
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

## Installation

### Prerequisites

- Flutter SDK (version 3.4.3 or higher)
- Android SDK for Android builds
- Xcode for macOS builds
- Android device or emulator (API level 21+)
- macOS device for macOS builds

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

3. For Android - Build APK:
```bash
flutter build apk --release
```

4. For macOS - Build app:
```bash
flutter build macos --release
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
- **Continuous Playback**: Plays random tracks from local cache
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
- **Storage Limit**: Maximum 20 tracks cached locally
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
  - `RadioService` - Enhanced radio service with failover management
  - `ApiService` - API communication with retry logic
  - `AudioService` - Advanced audio playback with buffering control
  - `StorageService` - Persistent data management
  - `FailoverService` - Local track caching and management
  - `NetworkService` - Network monitoring and connectivity

- **UI**: 
  - `HomeScreen` - Primary interface with real-time status
  - `StatusIndicator` - Enhanced connection and mode indicators

### Key Dependencies

- `just_audio: ^0.9.39` - Audio playback engine
- `shared_preferences: ^2.3.2` - Local storage
- `http: ^1.2.2` - Network requests
- `connectivity_plus: ^6.0.5` - Network monitoring
- `audio_session: ^0.1.21` - Audio session management

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
- **Enhanced Buffering**: 4-second audio buffer for stability
- **Adaptive Buffering**: Adjusts based on network conditions
- **Stream Continuity**: Smooth playback over temporary interruptions

#### **Error Handling**
- **Comprehensive Coverage**: Handles all network scenarios
- **Graceful Degradation**: Falls back to offline mode when needed
- **Automatic Recovery**: Self-healing capabilities
- **User Transparency**: Clear status indicators for all conditions

### Android Permissions

The application requires the following Android permissions:

- `INTERNET` - Internet access
- `ACCESS_NETWORK_STATE` - Network state monitoring
- `ACCESS_WIFI_STATE` - WiFi state monitoring
- `RECEIVE_BOOT_COMPLETED` - Auto-start capability
- `WAKE_LOCK` - Prevent device sleep during playback
- `FOREGROUND_SERVICE` - Background playback
- `MODIFY_AUDIO_SETTINGS` - Audio configuration
- `AUTOSTART` - Automatic startup
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` - Battery optimization bypass

## Development

### Project Structure

```
lib/
├── core/
│   ├── audio_state.dart           # Audio and radio state definitions
│   ├── dependency_injection.dart  # Service locator pattern
│   ├── result.dart               # Result wrapper for error handling
│   └── service_locator.dart      # Dependency injection container
├── models/
│   ├── api_error.dart            # Structured API error handling
│   ├── current_track.dart        # Track metadata with music classification
│   └── stream_config.dart        # Enhanced stream configuration
├── screens/
│   └── home_screen.dart          # Primary UI with real-time status
├── services/
│   ├── api_service.dart          # Enhanced API communication with retry
│   ├── audio_service.dart        # Advanced audio playback management
│   ├── failover_service.dart     # Local track caching and management
│   ├── network_service.dart      # Network monitoring and connectivity
│   ├── radio_service.dart        # Main service with failover orchestration
│   └── storage_service.dart      # Persistent data management
├── utils/
│   ├── constants.dart            # Application constants and cache settings
│   └── logger.dart               # Enhanced logging with categorization
├── widgets/
│   └── status_indicator.dart     # Enhanced status display widgets
└── main.dart                     # Application entry point
```

### Platform Support

- **Android**: Full support with auto-start functionality
- **Android TV**: Optimized for TV screens with full remote control support
- **macOS**: Full support for desktop usage
- **windows**: Full support for desktop usage

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

## ⚙️ Configuration & Performance

### Failover Configuration
```dart
// In lib/utils/constants.dart
class AppConstants {
  static const int maxFailoverTracks = 20;          // Max cached tracks
  static const Duration trackCacheTTL = Duration(days: 2);  // Track expiration
  static const String failoverCacheDir = 'failover_cache';  // Cache directory
}
```

### Performance Optimizations
- **Fast Network Detection**: 10-second ping intervals (vs 30-second default)
- **Rapid State Monitoring**: 1-second connection checks (vs 3-second default)
- **Quick Recovery**: 5-second force recovery (vs 10-second default)
- **Enhanced Buffering**: 4-second audio buffer (vs 2-second default)
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
- **Cached Tracks**: ~2-4 MB per track (40-80 MB total for 20 tracks)
- **Total Storage**: ~60-110 MB maximum

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
