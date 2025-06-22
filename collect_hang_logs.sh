#!/bin/bash

echo "🚨 Collecting Logs for Audio Hang Issue"
echo "======================================="

# Check if adb is available
if ! command -v adb &> /dev/null; then
    echo "❌ Error: adb not found. Please install Android SDK Platform-tools"
    exit 1
fi

# Check if device is connected
if ! adb devices | grep -q "device$"; then
    echo "❌ Error: No Android device connected via ADB"
    exit 1
fi

echo "📱 Device connected. Collecting logs..."

# Create logs directory
mkdir -p logs
timestamp=$(date +"%Y%m%d_%H%M%S")

echo "🔍 Collecting debug logs (last 1000 lines)..."

# Collect recent debug logs (last 1000 lines should cover last few minutes)
adb logcat -d -s "flutter" | grep -E "(API_DEBUG|AUDIO_DEBUG|NET_DEBUG|CONTROLLER_DEBUG|BUFFER_DEBUG|STATE_DEBUG|PING_DEBUG|ATTEMPT_DEBUG|TIMEOUT_DEBUG|RECONNECT_DEBUG|DIAGNOSTIC_|HEALTH_DEBUG)" | tail -500 > "logs/debug_full_${timestamp}.log"

# Collect critical errors and state changes
adb logcat -d -s "flutter" | grep -E "(ERROR|CRITICAL|ZERO BUFFER|Stream stuck|Timeout|Failed|STATE_DEBUG|CONTROLLER_DEBUG)" | tail -200 > "logs/critical_${timestamp}.log"

# Collect recent audio state changes
adb logcat -d -s "flutter" | grep -E "(AUDIO_DEBUG|STATE_DEBUG)" | tail -100 > "logs/audio_states_${timestamp}.log"

# Collect diagnostic dumps
adb logcat -d -s "flutter" | grep "DIAGNOSTIC_" | tail -50 > "logs/diagnostic_${timestamp}.log"

# Show recent critical issues
echo ""
echo "🚨 RECENT CRITICAL ISSUES:"
echo "========================="
adb logcat -d -s "flutter" | grep -E "(ERROR|CRITICAL|ZERO BUFFER|Stream stuck|Timeout|Failed)" | tail -20

echo ""
echo "🎵 RECENT AUDIO STATE CHANGES:"
echo "============================="
adb logcat -d -s "flutter" | grep "STATE_DEBUG" | tail -10

echo ""
echo "🎛️ RECENT CONTROLLER STATES:"
echo "============================"
adb logcat -d -s "flutter" | grep "CONTROLLER_DEBUG" | tail -10

echo ""
echo "📊 LATEST DIAGNOSTIC INFO:"
echo "=========================="
adb logcat -d -s "flutter" | grep "DIAGNOSTIC_" | tail -5

echo ""
echo "🔄 RECENT API CALLS:"
echo "==================="
adb logcat -d -s "flutter" | grep "API_DEBUG" | tail -5

echo ""
echo "📊 RECENT BUFFER STATUS:"
echo "======================="
adb logcat -d -s "flutter" | grep "BUFFER_DEBUG" | tail -5

echo ""
echo "✅ Logs saved to:"
echo "   - logs/debug_full_${timestamp}.log (all debug logs)"
echo "   - logs/critical_${timestamp}.log (critical issues)"  
echo "   - logs/audio_states_${timestamp}.log (audio states)"
echo "   - logs/diagnostic_${timestamp}.log (diagnostic dumps)"

echo ""
echo "💡 Please share the content of these files and the console output above for analysis" 