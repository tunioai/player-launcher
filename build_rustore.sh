#!/bin/bash

# Tunio Spot - RuStore Build Script
# Builds a signed Android App Bundle (AAB) for the RuStore distribution channel.
#
# RuStore is a separate product flavor (dimension "distribution") that:
#   - is signed with the dedicated RuStore key (see android/key.properties)
#   - has in-app self-update DISABLED (RuStore delivers updates itself),
#     because APP_FLAVOR != "standalone".

set -e # Stop execution on error

echo "🚀 Starting Tunio Spot build for RuStore"

# --- Java 17 check (Flutter/Gradle need JDK 17) -----------------------------
echo "☕ Checking Flutter Java configuration..."
FLUTTER_JAVA_VERSION=$(flutter doctor --verbose 2>/dev/null | grep "Java version" | head -n 1 | grep -o "17\|11\|8" || echo "")

if [ "$FLUTTER_JAVA_VERSION" != "17" ]; then
    echo "⚠️  Flutter is using Java '$FLUTTER_JAVA_VERSION', configuring Java 17..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        JAVA_17_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null || echo "")
        if [ -n "$JAVA_17_HOME" ]; then
            echo "✅ Found Java 17 at: $JAVA_17_HOME"
            flutter config --jdk-dir="$JAVA_17_HOME"
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

export GRADLE_OPTS="-Xmx4g -Dfile.encoding=UTF-8"
if [ -n "$JAVA_HOME" ]; then
    export GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.java.home=$JAVA_HOME"
fi

# --- Prerequisites ----------------------------------------------------------
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter not found. Please install Flutter SDK."
    exit 1
fi

if [ ! -f "android/key.properties" ]; then
    echo "❌ File android/key.properties not found!"
    echo "   Add the RuStore signing keys to android/key.properties:"
    echo "     rustoreStorePassword=..."
    echo "     rustoreKeyPassword=..."
    echo "     rustoreKeyAlias=rustore-upload"
    echo "     rustoreStoreFile=../rustore-keystore.jks"
    exit 1
fi

if ! grep -q "^rustoreKeyAlias=" android/key.properties; then
    echo "❌ RuStore signing keys are missing in android/key.properties."
    echo "   Without rustoreKeyAlias the build would fall back to the Play key."
    exit 1
fi

# Resolve the RuStore keystore path (relative entries are resolved from android/app)
RUSTORE_STORE_FILE=$(grep "^rustoreStoreFile=" android/key.properties | cut -d'=' -f2-)
case "$RUSTORE_STORE_FILE" in
    /*) RESOLVED_STORE="$RUSTORE_STORE_FILE" ;;          # absolute path
    *)  RESOLVED_STORE="android/app/$RUSTORE_STORE_FILE" ;;  # relative to app module
esac
if [ ! -f "$RESOLVED_STORE" ]; then
    echo "❌ RuStore keystore not found at: $RESOLVED_STORE"
    echo "   (rustoreStoreFile=$RUSTORE_STORE_FILE)"
    exit 1
fi
echo "🔐 Using RuStore keystore: $RESOLVED_STORE"

# --- Build ------------------------------------------------------------------
echo "🧹 Cleaning project..."
flutter clean

echo "📦 Installing dependencies..."
flutter pub get

echo "🔍 Analyzing code..."
flutter analyze

echo "🧪 Running tests..."
flutter test || echo "⚠️  Tests failed or not available"

echo "🔨 Building Android App Bundle (rustore flavor)..."
flutter build appbundle --release --flavor rustore --dart-define=APP_FLAVOR=rustore

# --- Verify output ----------------------------------------------------------
AAB_FILE="build/app/outputs/bundle/rustoreRelease/app-rustore-release.aab"
if [ ! -f "$AAB_FILE" ]; then
    echo "❌ Error: AAB file not created at $AAB_FILE"
    exit 1
fi

FILE_SIZE=$(ls -lh "$AAB_FILE" | awk '{print $5}')
echo ""
echo "✅ AAB created: $AAB_FILE"
echo "📏 Size: $FILE_SIZE"

# Report which certificate the bundle was signed with (sanity check)
RUSTORE_ALIAS=$(grep "^rustoreKeyAlias=" android/key.properties | cut -d'=' -f2-)
echo ""
echo "🔎 Signing certificate (alias: $RUSTORE_ALIAS):"
keytool -list -keystore "$RESOLVED_STORE" \
    -storepass "$(grep '^rustoreStorePassword=' android/key.properties | cut -d'=' -f2-)" \
    -alias "$RUSTORE_ALIAS" 2>/dev/null | grep -i "SHA" || \
    echo "   (could not read certificate — check rustoreStorePassword)"

echo ""
echo "🎯 Ready for RuStore upload:"
echo "   AAB: $AAB_FILE"
echo ""
echo "📋 If this is the FIRST upload, RuStore also asks for the upload"
echo "   certificate (Step 4). Export it with:"
echo "     keytool -export -rfc -alias $RUSTORE_ALIAS \\"
echo "       -keystore $RESOLVED_STORE \\"
echo "       -file android/rustore-upload-certificate.pem"
echo ""
echo "🎉 Build completed successfully!"
