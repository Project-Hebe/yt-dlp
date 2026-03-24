#!/usr/bin/env node
/**
 * Script to bundle meriyah and astring for Flutter JS provider
 * Usage: node bundle_js_libs.js
 */

const fs = require('fs');
const path = require('path');

const PROJECT_DIR = path.resolve(__dirname, '..');
const FLUTTER_APP_DIR = path.join(PROJECT_DIR, 'flutter_app');
const ASSETS_DIR = path.join(FLUTTER_APP_DIR, 'assets', 'js');

// Ensure assets directory exists
if (!fs.existsSync(ASSETS_DIR)) {
  fs.mkdirSync(ASSETS_DIR, { recursive: true });
}

console.log('📦 Bundling meriyah and astring for Flutter JS provider...');

try {
  // Try to require the packages
  const meriyah = require('meriyah');
  const astring = require('astring');

  // Create UMD wrapper for meriyah
  const meriyahCode = `
// Meriyah standalone bundle
(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.meriyah = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {
  // Meriyah code will be injected here
  // For now, we'll use a placeholder that loads from CDN or requires the package
  return {
    parse: function(code, options) {
      return meriyah.parse(code, options);
    }
  };
}));
`;

  // Create UMD wrapper for astring
  const astringCode = `
// Astring standalone bundle
(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.astring = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {
  // Astring code will be injected here
  return astring;
}));
`;

  // Actually, let's copy the dist files directly
  const meriyahDistPath = path.join(__dirname, '..', 'node_modules', 'meriyah', 'dist');
  const astringDistPath = path.join(__dirname, '..', 'node_modules', 'astring', 'dist');

  let meriyahSource = '';
  let astringSource = '';

  // Try to find meriyah dist file
  if (fs.existsSync(meriyahDistPath)) {
    const files = fs.readdirSync(meriyahDistPath);
    const esFile = files.find(f => f.includes('meriyah.es'));
    const umdFile = files.find(f => f.includes('meriyah.umd'));
    const distFile = esFile || umdFile || files[0];
    
    if (distFile) {
      meriyahSource = fs.readFileSync(path.join(meriyahDistPath, distFile), 'utf8');
      console.log(`✓ Found meriyah: ${distFile}`);
    }
  }

  // Try to find astring dist file
  if (fs.existsSync(astringDistPath)) {
    const files = fs.readdirSync(astringDistPath);
    const esFile = files.find(f => f.includes('astring.es'));
    const umdFile = files.find(f => f.includes('astring.umd'));
    const distFile = esFile || umdFile || files[0];
    
    if (distFile) {
      astringSource = fs.readFileSync(path.join(astringDistPath, distFile), 'utf8');
      console.log(`✓ Found astring: ${distFile}`);
    }
  }

  // Write the files
  if (meriyahSource) {
    fs.writeFileSync(path.join(ASSETS_DIR, 'meriyah.standalone.js'), meriyahSource);
    console.log('✓ Created meriyah.standalone.js');
  } else {
    console.log('⚠ Could not find meriyah dist file');
  }

  if (astringSource) {
    fs.writeFileSync(path.join(ASSETS_DIR, 'astring.standalone.js'), astringSource);
    console.log('✓ Created astring.standalone.js');
  } else {
    console.log('⚠ Could not find astring dist file');
  }

  console.log('\n✅ Bundling complete!');
  console.log('\n📝 Next steps:');
  console.log('   1. Add to flutter_app/pubspec.yaml:');
  console.log('      flutter:');
  console.log('        assets:');
  console.log('          - assets/js/meriyah.standalone.js');
  console.log('          - assets/js/astring.standalone.js');
  console.log('   2. Run: cd flutter_app && flutter pub get');

} catch (error) {
  if (error.code === 'MODULE_NOT_FOUND') {
    console.log('❌ meriyah or astring not found. Installing...');
    console.log('   Run: npm install meriyah astring');
    console.log('   Then run this script again.');
  } else {
    console.error('❌ Error:', error.message);
    process.exit(1);
  }
}

