#!/bin/bash

# Debug script for Tunio Radio App - helps diagnose hanging issues

echo "🚀 Tunio Radio Debug Log Viewer"
echo "================================"

# Check if adb is available
if ! command -v adb &> /dev/null; then
    echo "❌ Error: adb not found. Please install Android SDK Platform-tools"
    exit 1
fi

# Check if device is connected
if ! adb devices | grep -q "device$"; then
    echo "❌ Error: No Android device connected via ADB"
    echo "💡 Make sure USB debugging is enabled and device is connected"
    exit 1
fi

echo "📱 Connected device:"
adb devices

echo ""
echo "🔍 Choose debug option:"
echo "1) Show ALL debug logs (comprehensive)"
echo "2) Show API debug logs only"
echo "3) Show Audio debug logs only"
echo "4) Show Network debug logs only"
echo "5) Show Controller debug logs only"
echo "6) Show Buffer debug logs only"
echo "7) Show diagnostic logs only"
echo "8) Monitor live logs (real-time)"
echo "9) Show critical errors only"
echo "0) Clear logs and start fresh monitoring"

echo ""
read -p "Enter your choice (0-9): " choice

case $choice in
    1)
        echo "📋 Showing ALL debug logs..."
        adb logcat -s "flutter" | grep -E "(API_DEBUG|AUDIO_DEBUG|NET_DEBUG|CONTROLLER_DEBUG|BUFFER_DEBUG|STATE_DEBUG|PING_DEBUG|ATTEMPT_DEBUG|TIMEOUT_DEBUG|RECONNECT_DEBUG|DIAGNOSTIC_|HEALTH_DEBUG)"
        ;;
    2)
        echo "📋 Showing API debug logs..."
        adb logcat -s "flutter" | grep "API_DEBUG"
        ;;
    3)
        echo "📋 Showing Audio/State debug logs..."
        adb logcat -s "flutter" | grep -E "(AUDIO_DEBUG|STATE_DEBUG)"
        ;;
    4)
        echo "📋 Showing Network debug logs..."
        adb logcat -s "flutter" | grep -E "(NET_DEBUG|PING_DEBUG)"
        ;;
    5)
        echo "📋 Showing Controller debug logs..."
        adb logcat -s "flutter" | grep -E "(CONTROLLER_DEBUG|ATTEMPT_DEBUG|TIMEOUT_DEBUG|RECONNECT_DEBUG)"
        ;;
    6)
        echo "📋 Showing Buffer debug logs..."
        adb logcat -s "flutter" | grep "BUFFER_DEBUG"
        ;;
    7)
        echo "📋 Showing Diagnostic logs..."
        adb logcat -s "flutter" | grep -E "(DIAGNOSTIC_|HEALTH_DEBUG)"
        ;;
    8)
        echo "📺 Starting live log monitoring... (Press Ctrl+C to stop)"
        echo "🎯 This will show real-time debug logs as they happen"
        adb logcat -s "flutter" | grep --line-buffered -E "(API_DEBUG|AUDIO_DEBUG|NET_DEBUG|CONTROLLER_DEBUG|BUFFER_DEBUG|STATE_DEBUG|PING_DEBUG|ATTEMPT_DEBUG|TIMEOUT_DEBUG|RECONNECT_DEBUG|DIAGNOSTIC_|HEALTH_DEBUG)"
        ;;
    9)
        echo "🚨 Showing critical errors only..."
        adb logcat -s "flutter" | grep -E "(ERROR|CRITICAL|ZERO BUFFER|Stream stuck|Timeout|Failed)"
        ;;
    0)
        echo "🧹 Clearing logs and starting fresh monitoring..."
        adb logcat -c
        echo "✅ Logs cleared. Starting live monitoring..."
        adb logcat -s "flutter" | grep --line-buffered -E "(API_DEBUG|AUDIO_DEBUG|NET_DEBUG|CONTROLLER_DEBUG|BUFFER_DEBUG|STATE_DEBUG|PING_DEBUG|ATTEMPT_DEBUG|TIMEOUT_DEBUG|RECONNECT_DEBUG|DIAGNOSTIC_|HEALTH_DEBUG)"
        ;;
    *)
        echo "❌ Invalid choice. Please run the script again."
        exit 1
        ;;
esac 