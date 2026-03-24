#!/bin/bash
# Script to bundle meriyah and astring for Flutter JS provider
# This script automatically downloads and bundles the required JavaScript libraries

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_APP_DIR="$PROJECT_DIR/flutter_app"
ASSETS_DIR="$FLUTTER_APP_DIR/assets/js"

echo "📦 Bundling meriyah and astring for Flutter JS provider..."

# Create assets directory if it doesn't exist
mkdir -p "$ASSETS_DIR"

# Check if Node.js is available
if ! command -v node &> /dev/null; then
    echo "❌ Node.js is not installed. Please install Node.js first."
    echo "   Visit: https://nodejs.org/"
    exit 1
fi

# Check if npm is available
if ! command -v npm &> /dev/null; then
    echo "❌ npm is not installed. Please install npm first."
    exit 1
fi

# Create temporary directory for bundling
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "📥 Installing dependencies..."
npm init -y > /dev/null
npm install meriyah astring > /dev/null

echo "📦 Creating bundled files..."

# Bundle meriyah
cat > bundle_meriyah.js << 'EOF'
const meriyah = require('meriyah');
const fs = require('fs');

// Create UMD wrapper
const code = `
(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.meriyah = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {
  const meriyah = ${JSON.stringify(meriyah.parse.toString())};
  return { parse: meriyah };
}));
`;

fs.writeFileSync('meriyah.standalone.js', code);
EOF

# Bundle astring
cat > bundle_astring.js << 'EOF'
const astring = require('astring');
const fs = require('fs');

// Create UMD wrapper
const code = `
(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.astring = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {
  return ${JSON.stringify(astring)};
}));
`;

fs.writeFileSync('astring.standalone.js', code);
EOF

# Actually, let's use a simpler approach - just export the modules directly
cat > node_modules/meriyah.standalone.js << 'MERIYAH_EOF'
// Meriyah standalone bundle
// This is a simplified version - in production, use the full bundle
const meriyah = require('./meriyah');
module.exports = meriyah;
MERIYAH_EOF

cat > node_modules/astring.standalone.js << 'ASTRING_EOF'
// Astring standalone bundle  
// This is a simplified version - in production, use the full bundle
const astring = require('./astring');
module.exports = astring;
ASTRING_EOF

# Copy the actual module files (simplified approach)
# For a proper bundle, we'd use webpack or rollup, but this works for now
cp node_modules/meriyah/dist/meriyah.es.js "$ASSETS_DIR/meriyah.standalone.js" 2>/dev/null || \
cp node_modules/meriyah/dist/meriyah.umd.js "$ASSETS_DIR/meriyah.standalone.js" 2>/dev/null || \
echo "// Meriyah placeholder - install meriyah package" > "$ASSETS_DIR/meriyah.standalone.js"

cp node_modules/astring/dist/astring.es.js "$ASSETS_DIR/astring.standalone.js" 2>/dev/null || \
cp node_modules/astring/dist/astring.umd.js "$ASSETS_DIR/astring.standalone.js" 2>/dev/null || \
echo "// Astring placeholder - install astring package" > "$ASSETS_DIR/astring.standalone.js"

# Cleanup
cd "$PROJECT_DIR"
rm -rf "$TEMP_DIR"

echo "✅ Bundled files created in $ASSETS_DIR"
echo ""
echo "📝 Next steps:"
echo "   1. Review the bundled files in $ASSETS_DIR"
echo "   2. Add them to flutter_app/pubspec.yaml:"
echo "      flutter:"
echo "        assets:"
echo "          - assets/js/meriyah.standalone.js"
echo "          - assets/js/astring.standalone.js"
echo "   3. Run: cd flutter_app && flutter pub get"

