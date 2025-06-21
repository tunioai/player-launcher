# Tunio Player

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
GET https://api.tunio.ai/stream/config?token=YOUR_API_KEY
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

### Adding New Features

1. Add new models in the `models/` directory
2. Extend existing services or create new ones in `services/`
3. Update the controller to integrate new logic
4. Modify the UI to accommodate new features
5. Update permissions in platform-specific manifests if needed

## Troubleshooting

### Auto-start Issues

1. Ensure the app has auto-start permission in Android settings
2. Verify the API key is saved correctly
3. Some Android versions may require disabling battery optimization
4. Check that the boot receiver is properly configured

### Playback Issues

1. Verify internet connection
2. Confirm API key validity
3. Check stream URL accessibility
4. Ensure audio permissions are granted
5. Verify audio session configuration

### Network Issues

- The app automatically reconnects when network is restored
- Long interruptions may require manual reconnection
- Check firewall and proxy settings
- Verify network stability

### Platform-specific Issues

**Android:**
- Ensure minimum API level 21
- Check battery optimization settings
- Verify auto-start permissions

**macOS:**
- Ensure proper entitlements are configured
- Check network access permissions
- Verify audio access permissions

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

## License

[Specify your project license]

## Support

For support and issues:
- Create an issue in the project repository
- Contact the development team
- Check the troubleshooting section above

---

**Note**: This application is designed for streaming radio content and requires a valid Tunio API key for operation.

## Google Play Publishing Guide

### Prerequisites

- Flutter SDK installed
- Android SDK with build tools
- Google Play Console account
- Java JDK 11 or higher

### Step 1: Generate Upload Keystore

Create a keystore for signing your app:

```bash
keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**Important:** Save the keystore file and remember the passwords! You'll need them for all future updates.

### Step 2: Configure Signing

Create a `key.properties` file in the `android/` directory:

```properties
storePassword=your_store_password
keyPassword=your_key_password
keyAlias=upload
storeFile=/path/to/your/upload-keystore.jks
```

Example:
```properties
storePassword=myStorePassword123
keyPassword=myKeyPassword123
keyAlias=upload
storeFile=/Users/yourname/upload-keystore.jks
```

**⚠️ Security:** Add `key.properties` to `.gitignore` to keep your credentials safe!

### Step 3: Update App Information

1. **Update version in `pubspec.yaml`:**
   ```yaml
   version: 1.0.0+1  # Format: semantic_version+build_number
   ```

2. **App name and description:**
   - Update `android/app/src/main/AndroidManifest.xml` if needed
   - The current app name is "Tunio Player"

### Step 4: Build Release APK/AAB

#### Build Android App Bundle (AAB) - Recommended for Google Play:
```bash
flutter build appbundle --release
```

#### Build APK (alternative):
```bash
flutter build apk --release
```

The built files will be located at:
- AAB: `build/app/outputs/bundle/release/app-release.aab`
- APK: `build/app/outputs/flutter-apk/app-release.apk`

### Step 5: Test Release Build

Before uploading, test your release build:

```bash
# Install and test the release APK
flutter install --release
```

### Step 6: Upload to Google Play Console

1. **Go to Google Play Console:** https://play.google.com/console
2. **Create new app** or select existing app
3. **Upload your AAB file** in "Release management" → "App releases"
4. **Fill in app details:**
   - App title: "Tunio Player"
   - Short description: "Radio streaming app with auto-start functionality"
   - Full description: Detailed description of features
   - Screenshots: Take screenshots of the app
   - App icon: Use the existing icon from `assets/icon/app_icon.png`

### Step 7: Configure App Details

#### Required Information:
- **Category:** Music & Audio
- **Content rating:** Complete the questionnaire
- **Target audience:** Select appropriate age groups
- **Privacy policy:** Provide if collecting user data

#### App Permissions Explanation:
Your app requests several permissions. Provide explanations:
- `INTERNET`, `ACCESS_NETWORK_STATE`: For streaming radio
- `MODIFY_AUDIO_SETTINGS`: For volume control
- `WAKE_LOCK`, `FOREGROUND_SERVICE`: For background playback
- `RECEIVE_BOOT_COMPLETED`: For auto-start functionality
- `SYSTEM_ALERT_WINDOW`: For TV box compatibility

### Step 8: Review and Publish

1. Complete all sections in Google Play Console
2. Review your app listing
3. Submit for review
4. Wait for approval (usually 1-3 days)

## Updating Your App

For future updates:

1. **Update version in `pubspec.yaml`:**
   ```yaml
   version: 1.0.1+2  # Increment version and build number
   ```

2. **Build new release:**
   ```bash
   flutter build appbundle --release
   ```

3. **Upload to Google Play Console** in the same app listing
