#!/bin/bash
# Script to download meriyah and astring from CDN (no Node.js required)
# This script uses curl to download pre-built libraries from CDN

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_APP_DIR="$PROJECT_DIR/flutter_app"
ASSETS_DIR="$FLUTTER_APP_DIR/assets/js"

echo "📦 Downloading meriyah and astring from CDN..."

# Create assets directory if it doesn't exist
mkdir -p "$ASSETS_DIR"

# Check if curl is available
if ! command -v curl &> /dev/null; then
    echo "❌ curl is not installed. Please install curl first."
    exit 1
fi

# Download meriyah from unpkg CDN
echo "📥 Downloading meriyah..."
MERIYAH_URL="https://unpkg.com/meriyah@4.3.0/dist/meriyah.umd.js"
if curl -f -s -o "$ASSETS_DIR/meriyah.standalone.js" "$MERIYAH_URL"; then
    echo "✅ Downloaded meriyah.standalone.js"
else
    echo "⚠️ Failed to download from unpkg, trying jsdelivr..."
    MERIYAH_URL="https://cdn.jsdelivr.net/npm/meriyah@4.3.0/dist/meriyah.umd.js"
    if curl -f -s -o "$ASSETS_DIR/meriyah.standalone.js" "$MERIYAH_URL"; then
        echo "✅ Downloaded meriyah.standalone.js from jsdelivr"
    else
        echo "❌ Failed to download meriyah"
        exit 1
    fi
fi

# Download astring from unpkg CDN
echo "📥 Downloading astring..."
# Try different possible paths for astring
ASTRING_URLS=(
    "https://unpkg.com/astring@1.8.6/dist/astring.js"
    "https://unpkg.com/astring@1.8.6/dist/astring.umd.js"
    "https://cdn.jsdelivr.net/npm/astring@1.8.6/dist/astring.js"
    "https://cdn.jsdelivr.net/npm/astring@1.8.6/dist/astring.umd.js"
    "https://unpkg.com/astring@latest/dist/astring.js"
    "https://cdn.jsdelivr.net/npm/astring@latest/dist/astring.js"
)

DOWNLOADED=0
for ASTRING_URL in "${ASTRING_URLS[@]}"; do
    if curl -f -s -o "$ASSETS_DIR/astring.standalone.js" "$ASTRING_URL" 2>/dev/null; then
        echo "✅ Downloaded astring.standalone.js from $ASTRING_URL"
        DOWNLOADED=1
        break
    fi
done

if [ "$DOWNLOADED" -eq 0 ]; then
    echo "❌ Failed to download astring from all CDN sources"
    echo "   Please check your internet connection or download manually"
    exit 1
fi

echo ""
echo "✅ All libraries downloaded successfully!"
echo "📁 Files saved to: $ASSETS_DIR"
echo ""
echo "📝 Next steps:"
echo "   1. Verify files exist:"
echo "      ls -lh $ASSETS_DIR"
echo "   2. Run: cd flutter_app && flutter pub get"
echo "   3. Restart your Flutter app"

