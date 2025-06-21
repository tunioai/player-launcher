#!/bin/bash

# Tunio Player - Release Build Script
# This script automates the process of building a release version

set -e # Stop execution on error

echo "🚀 Starting Tunio Player build for Google Play"

# Check if Flutter is available
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter not found. Please install Flutter SDK."
    exit 1
fi

# Check Android toolchain
echo "🔍 Checking Android toolchain..."
if ! flutter doctor | grep -q "Android toolchain.*✓"; then
    echo "⚠️  Issues detected with Android toolchain."
    echo "Will try to build with additional flags..."
    BUILD_FLAGS="--no-shrink"
else
    BUILD_FLAGS=""
fi

# Check for key.properties file
if [ ! -f "android/key.properties" ]; then
    echo "❌ File android/key.properties not found!"
    echo "Create android/key.properties file with content:"
    echo "storePassword=your_store_password"
    echo "keyPassword=your_key_password"
    echo "keyAlias=upload"
    echo "storeFile=./upload-keystore.jks"
    exit 1
fi

# Clean project
echo "🧹 Cleaning project..."
flutter clean

# Install dependencies
echo "📦 Installing dependencies..."
flutter pub get

# Check configuration
echo "🔍 Checking configuration..."
flutter doctor

# Analyze code
echo "🔍 Analyzing code..."
flutter analyze

# Run tests (if available)
echo "🧪 Running tests..."
flutter test || echo "⚠️  Tests failed or not available"

# Build AAB
echo "🔨 Building Android App Bundle..."
if [ -n "$BUILD_FLAGS" ]; then
    echo "📝 Using additional flags: $BUILD_FLAGS"
    flutter build appbundle --release $BUILD_FLAGS
else
    flutter build appbundle --release
fi

# Check file size
AAB_FILE="build/app/outputs/bundle/release/app-release.aab"
if [ -f "$AAB_FILE" ]; then
    FILE_SIZE=$(ls -lh "$AAB_FILE" | awk '{print $5}')
    echo "✅ AAB file successfully created: $AAB_FILE"
    echo "📏 File size: $FILE_SIZE"
    
    # Check size (warning if larger than 100MB)
    FILE_SIZE_BYTES=$(stat -c%s "$AAB_FILE" 2>/dev/null || stat -f%z "$AAB_FILE" 2>/dev/null)
    if [ "$FILE_SIZE_BYTES" -gt 104857600 ]; then
        echo "⚠️  Warning: File size is larger than 100MB"
    fi
else
    echo "❌ Error: AAB file not created"
    exit 1
fi

# Also build APK for testing
echo "🔨 Building APK for testing..."
if [ -n "$BUILD_FLAGS" ]; then
    flutter build apk --release $BUILD_FLAGS
else
    flutter build apk --release
fi

APK_FILE="build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK_FILE" ]; then
    APK_SIZE=$(ls -lh "$APK_FILE" | awk '{print $5}')
    echo "✅ APK file created: $APK_FILE"
    echo "📏 APK size: $APK_SIZE"
fi

echo ""
echo "🎉 Build completed successfully!"
echo ""
echo "📁 Files for upload:"
echo "   AAB (for Google Play): $AAB_FILE"
echo "   APK (for testing): $APK_FILE"
echo ""
echo "📋 Next steps:"
echo "1. Test APK: flutter install --release"
echo "2. Upload AAB to Google Play Console"
echo "3. Fill in app description"
echo "4. Submit for review"
echo ""
echo "📖 Detailed instructions in README.md and PUBLISH_CHECKLIST.md" 

adb install -r build/app/outputs/flutter-apk/app-release.apk
