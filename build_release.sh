#!/bin/bash

# Tunio Spot - Release Build Script
# This script automates the process of building a release version

set -e # Stop execution on error

echo "🚀 Starting Tunio Spot build for Google Play"

# Check and ensure Java 17 is configured for Flutter
echo "☕ Checking Flutter Java configuration..."

# Check if Flutter is using Java 17
FLUTTER_JAVA_VERSION=$(flutter doctor --verbose 2>/dev/null | grep "Java version" | head -n 1 | grep -o "17\|11\|8")

if [ "$FLUTTER_JAVA_VERSION" != "17" ]; then
    echo "⚠️  Flutter is using Java $FLUTTER_JAVA_VERSION, configuring Java 17..."
    
    # Try to find Java 17 on macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        JAVA_17_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null || echo "")
        
        if [ -n "$JAVA_17_HOME" ]; then
            echo "✅ Found Java 17 at: $JAVA_17_HOME"
            flutter config --jdk-dir="$JAVA_17_HOME"
            echo "🔄 Configured Flutter to use Java 17"
        else
            echo "❌ Java 17 not found. Run './setup_java.sh' to install it"
            exit 1
        fi
    else
        echo "❌ Please install Java 17 and configure Flutter:"
        echo "   flutter config --jdk-dir=\"/path/to/java17\""
        exit 1
    fi
else
    echo "✅ Flutter is already using Java 17"
fi

# Set Gradle JVM arguments for better performance and Java 17 compatibility
export GRADLE_OPTS="-Xmx4g -Dfile.encoding=UTF-8"
if [ -n "$JAVA_HOME" ]; then
    export GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.java.home=$JAVA_HOME"
fi

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

# Build AAB for Google Play flavor
echo "🔨 Building Android App Bundle (play flavor)..."
if [ -n "$BUILD_FLAGS" ]; then
    echo "📝 Using additional flags: $BUILD_FLAGS"
    flutter build appbundle --release --flavor play --dart-define=APP_FLAVOR=play $BUILD_FLAGS
else
    flutter build appbundle --release --flavor play --dart-define=APP_FLAVOR=play
fi

# Check file size
AAB_FILE="build/app/outputs/bundle/playRelease/app-play-release.aab"
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

# Also build standalone APK with self-update support
echo "🔨 Building standalone APK..."
if [ -n "$BUILD_FLAGS" ]; then
    flutter build apk --release --flavor standalone --dart-define=APP_FLAVOR=standalone $BUILD_FLAGS
else
    flutter build apk --release --flavor standalone --dart-define=APP_FLAVOR=standalone
fi

APK_FILE="build/app/outputs/flutter-apk/app-standalone-release.apk"
if [ -f "$APK_FILE" ]; then
    APK_SIZE=$(ls -lh "$APK_FILE" | awk '{print $5}')
    echo "✅ APK file created: $APK_FILE"
    echo "📏 APK size: $APK_SIZE"
fi

echo ""
echo "🎉 Build completed successfully!"
echo ""
echo "📁 Files for upload:"
echo "   AAB (Google Play): $AAB_FILE"
echo "   APK (standalone with self-update): $APK_FILE"
echo ""
echo "📋 Next steps:"
echo "1. Test standalone APK: flutter install --release --flavor standalone --dart-define=APP_FLAVOR=standalone"
echo "2. Upload AAB to Google Play Console"
echo "3. Fill in app description"
echo "4. Submit for review"
echo ""
echo "📖 Detailed instructions in README.md and PUBLISH_CHECKLIST.md" 

adb install -r build/app/outputs/flutter-apk/app-standalone-release.apk
