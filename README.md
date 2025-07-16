# Tunio Spot

A Flutter application for Android and macOS that automatically plays online radio streams with auto-start functionality and network resilience.

## Features

- **Auto-start**: Application automatically launches when device boots up
- **API Integration**: Connects to Tunio API for stream configuration
- **Resilient Playback**: Automatic reconnection on network interruptions
- **Buffering**: Optimized buffering for continuous playback
- **Volume Control**: Local and remote volume management
- **Local Storage**: API key persistence for automatic connection
- **Cross-platform**: Supports Android, macOS, and Android TV
- **TV Remote Support**: Full navigation with TV remote control
- **Background Playback**: Continues playing when app is minimized
- **Network Monitoring**: Real-time connectivity status tracking
- **Focus Management**: Optimized interface for TV screens and remote control

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

## API Integration

The application uses the Tunio API to fetch stream configuration:

```
GET https://api.tunio.ai/stream/config?token=YOUR_PIN_CODE
```

Expected response format:
```json
{
  "stream_url": "http://stream.example.com:8000/stream",
  "volume": 0.8,
  "title": "Radio Station Name",
  "description": "Station description"
}
```

## Technical Details

### Architecture

The application follows a clean architecture pattern with:

- **Models**: `StreamConfig` for stream configuration data
- **Services**: 
  - `ApiService` - API communication
  - `AudioService` - audio playback management
  - `StorageService` - local data persistence
- **Controllers**: `RadioController` - main application logic
- **UI**: `HomeScreen` - primary user interface
- **Widgets**: `StatusIndicator` - connection status display

### Key Dependencies

- `just_audio: ^0.9.39` - Audio playback engine
- `shared_preferences: ^2.3.2` - Local storage
- `http: ^1.2.2` - Network requests
- `connectivity_plus: ^6.0.5` - Network monitoring
- `audio_session: ^0.1.21` - Audio session management

### Network Resilience

- Automatic reconnection on network loss
- Maximum 10 reconnection attempts with 5-second intervals
- Buffering to smooth over temporary interruptions
- Comprehensive error handling for various network scenarios
- Real-time connectivity monitoring

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
├── controllers/
│   └── radio_controller.dart      # Main application controller
├── models/
│   └── stream_config.dart         # Stream configuration model
├── screens/
│   └── home_screen.dart           # Primary UI screen
├── services/
│   ├── api_service.dart           # API communication service
│   ├── audio_service.dart         # Audio playback service
│   └── storage_service.dart       # Local storage service
├── utils/
│   ├── constants.dart             # Application constants
│   └── logger.dart                # Logging utilities
├── widgets/
│   └── status_indicator.dart      # Status display widget
└── main.dart                      # Application entry point
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
