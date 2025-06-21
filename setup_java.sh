#!/bin/bash

# Java 17 Setup Script for Tunio Player Local Development
# This script helps install and configure Java 17 for Android builds

set -e

echo "☕ Java 17 Setup for Tunio Player"
echo "=================================="

# Check current Java version
if command -v java &> /dev/null; then
    CURRENT_JAVA=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
    echo "Current Java version: $CURRENT_JAVA"
else
    echo "Java not found"
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "🍎 Detected macOS"
    
    # Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
        echo "❌ Homebrew not found. Please install Homebrew first:"
        echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    
    # Install Java 17
    echo "📦 Installing OpenJDK 17 via Homebrew..."
    brew install openjdk@17
    
    # Create symlink for system recognition
    echo "🔗 Creating system symlink..."
    sudo ln -sfn /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-17.jdk
    
    # Update shell profile
    SHELL_PROFILE=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        SHELL_PROFILE="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        SHELL_PROFILE="$HOME/.bash_profile"
    fi
    
    if [ -n "$SHELL_PROFILE" ]; then
        echo "📝 Adding Java 17 to $SHELL_PROFILE"
        echo "" >> "$SHELL_PROFILE"
        echo "# Java 17 for Android development" >> "$SHELL_PROFILE" 
        echo "export JAVA_HOME=\$(/usr/libexec/java_home -v 17)" >> "$SHELL_PROFILE"
        echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\"" >> "$SHELL_PROFILE"
        
        echo "✅ Java 17 setup completed!"
        echo ""
        echo "🔄 Please restart your terminal or run:"
        echo "   source $SHELL_PROFILE"
        echo ""
        echo "🧪 Then verify with:"
        echo "   java -version"
    fi
    
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "🐧 Detected Linux"
    
    # Check if apt is available (Ubuntu/Debian)
    if command -v apt &> /dev/null; then
        echo "📦 Installing OpenJDK 17 via apt..."
        sudo apt update
        sudo apt install -y openjdk-17-jdk
        
        # Set as default
        sudo update-alternatives --config java
        
        echo "📝 Add to your ~/.bashrc or ~/.zshrc:"
        echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
        echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
        
    # Check if yum is available (CentOS/RHEL)
    elif command -v yum &> /dev/null; then
        echo "📦 Installing OpenJDK 17 via yum..."
        sudo yum install -y java-17-openjdk-devel
        
        echo "📝 Add to your ~/.bashrc or ~/.zshrc:"
        echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk"
        echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
        
    else
        echo "❌ Package manager not found. Please install Java 17 manually."
        exit 1
    fi
    
else
    echo "❌ Unsupported operating system: $OSTYPE"
    echo "Please install Java 17 manually and set JAVA_HOME"
    exit 1
fi

echo ""
echo "🎉 Java 17 installation completed!"
echo ""
echo "Next steps:"
echo "1. Restart your terminal"
echo "2. Run: ./build_release.sh"
echo "3. Your Android builds should now work!" 