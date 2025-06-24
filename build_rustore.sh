#!/bin/bash

echo "🏗️  Building AAB for RuStore..."
echo ""

# Clean previous builds
echo "🧹 Cleaning previous builds..."
flutter clean

# Get dependencies
echo "📦 Getting dependencies..."
flutter pub get

# Build AAB for RuStore using Gradle directly
echo "🔨 Building AAB with RuStore signing..."
cd android && ./gradlew bundleRustore
cd ..

# Check if build was successful
if [ -f "build/app/outputs/bundle/rustore/app-rustore.aab" ]; then
    echo ""
    echo "✅ Success! AAB file created:"
    echo "📁 Location: build/app/outputs/bundle/rustore/app-rustore.aab"
    echo "📊 Size: $(ls -lh build/app/outputs/bundle/rustore/app-rustore.aab | awk '{print $5}')"
    echo ""
    
    # Create all possible key formats for RuStore
    cd android
    
    # Check if certificate exists
    if [ -f "rustore-upload-certificate.pem" ]; then
        echo "✅ Upload certificate already exists"
    else
        echo "📜 Creating upload certificate..."
        keytool -export -alias rustore-upload -keystore rustore-keystore.jks -rfc -file rustore-upload-certificate.pem -storepass rustorepass123
        echo "✅ Upload certificate created"
    fi
    
    # Create alternative key formats for RuStore
    echo "🔑 Creating alternative key formats..."
    
    # 1. Convert to PKCS12 and extract private key
    if [ ! -f "rustore-keystore.p12" ]; then
        keytool -importkeystore -srckeystore rustore-keystore.jks -destkeystore rustore-keystore.p12 -deststoretype PKCS12 -srcalias rustore-upload -destalias rustore-upload -srcstorepass rustorepass123 -deststorepass rustorepass123 2>/dev/null
    fi
    
    if [ ! -f "rustore-private-key.pem" ]; then
        openssl pkcs12 -in rustore-keystore.p12 -nodes -nocerts -out rustore-private-key.pem -passin pass:rustorepass123 2>/dev/null
    fi
    
    # 2. Create simple private key zip
    if [ ! -f "rustore-private-key.zip" ]; then
        zip rustore-private-key.zip rustore-private-key.pem >/dev/null 2>&1
    fi
    
    # 3. Create keystore zip
    if [ ! -f "rustore-keystore.zip" ]; then
        cp rustore-keystore.jks rustore-upload-key.jks
        zip rustore-keystore.zip rustore-upload-key.jks >/dev/null 2>&1
    fi
    
    cd ..
    
    echo ""
    echo "📋 For RuStore upload, try these files in order:"
    echo ""
    echo "   🔐 Step 3 - Encrypted Key (try these options):"
    echo "      Option 1: android/rustore-private-key.zip (1.6 KB) - Simple private key"
    echo "      Option 2: android/rustore-keystore.zip (2.8 KB) - Keystore file"
    if [ -f "android/rustore-encrypted-key.zip" ]; then
        echo "      Option 3: android/rustore-encrypted-key.zip (1.8 KB) - PEPK encrypted"
    fi
    echo ""
    echo "   📜 Step 4 - Upload Certificate:"
    echo "      Use: android/rustore-upload-certificate.pem (1.2 KB)"
    echo ""
    echo "   🎯 Step 5 - AAB file:"
    echo "      Use: build/app/outputs/bundle/rustore/app-rustore.aab"
    echo ""
    echo "💡 If first option doesn't work, try the next one!"
    echo ""
    echo "🔑 Key Details for manual input if needed:"
    echo "   - Password: rustorepass123"
    echo "   - Alias: rustore-upload"
    echo ""
    echo "🎯 Ready for RuStore upload!"
else
    echo ""
    echo "❌ Build failed! Check the logs above."
    exit 1
fi 