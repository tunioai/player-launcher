# GitHub Actions Setup for Automated Builds

## Overview

GitHub Actions are configured to automatically build the application for each release. The system creates builds for Android, macOS, and Windows, then automatically creates a release with artifacts.

## Workflows

1. **`ci.yml`** - Code checks on push/PR
2. **`release.yml`** - Release creation on tag push

## Setup Secrets

To enable automated builds, you need to configure the following secrets in GitHub:

### Navigate to secrets settings:
1. Go to the repository on GitHub
2. Settings → Secrets and variables → Actions
3. Click "New repository secret"

### Required secrets:

#### 1. `ANDROID_KEYSTORE`
```bash
# Convert your keystore to base64
base64 -i android/app/upload-keystore.jks | pbcopy
```
Paste the result into the `ANDROID_KEYSTORE` secret

#### 2. `KEYSTORE_PASSWORD`
Password for the keystore file

#### 3. `KEY_PASSWORD`
Password for the key

#### 4. `KEY_ALIAS`
Key alias (usually "upload")

## How to create a release

### 1. Update version in pubspec.yaml
```yaml
version: 1.0.1+7  # Increment version
```

### 2. Create and push tag
```bash
# Create tag
git tag v1.0.1

# Push tag
git push origin v1.0.1
```

### 3. Automatic build
GitHub Actions will automatically:
- Build APK and AAB for Android
- Build application for macOS
- Build application for Windows
- Create release with downloadable files
- Add release description

## Release structure

Each release will contain:
- `app-release.aab` - for Google Play upload
- `app-release.apk` - for testing/direct installation
- `tunio-player-macos.tar.gz` - macOS application
- `tunio-player-windows.zip` - Windows application

## Benefits

✅ **Automation** - no need for manual builds
✅ **Consistency** - same build environment
✅ **Security** - keys stored in GitHub Secrets
✅ **Multi-platform** - Android, macOS, and Windows simultaneously
✅ **Artifacts** - automatic release creation

## Monitoring

You can track the build process:
1. Go to the "Actions" tab in the repository
2. Select the required workflow
3. Watch progress in real-time

## Troubleshooting

### Keystore issues
If build fails due to keystore:
1. Make sure keystore file exists
2. Check that all secrets are filled
3. Ensure base64 conversion was done correctly

### Flutter version issues
If you need a different Flutter version, change in workflows:
```yaml
- name: Setup Flutter
  uses: subosito/flutter-action@v2
  with:
    flutter-version: '3.27.0'  # Change version
    channel: 'stable'
```

### Dependencies issues
If build fails due to dependencies:
1. Check that all dependencies are compatible
2. Make sure pubspec.yaml is correct
3. Check error logs in Actions

## Commands for local verification

```bash
# Check formatting
flutter format lib/ test/

# Code analysis
flutter analyze

# Run tests
flutter test

# Local build
flutter build apk --release
flutter build appbundle --release
```

## Alternatives

If GitHub Actions doesn't suit you, consider:
- **Codemagic** - specialized CI/CD for Flutter
- **GitLab CI** - if using GitLab
- **Bitrise** - mobile CI/CD platform

## Additional features

### Automatic Google Play upload
You can add automatic upload to Google Play Console:
```yaml
- name: Upload to Google Play
  uses: r0adkll/upload-google-play@v1
  with:
    serviceAccountJsonPlainText: ${{ secrets.GOOGLE_PLAY_SERVICE_ACCOUNT }}
    packageName: ai.tunio.radioplayer
    releaseFiles: build/app/outputs/bundle/release/app-release.aab
    track: production
```

### Notifications
You can add notifications to Slack/Discord/Telegram on successful builds.

### Testing
You can add more advanced tests, integration tests, etc.

---

**Done!** Now every time you push a tag, GitHub Actions will automatically create a release with ready-to-download files. 