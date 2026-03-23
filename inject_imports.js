const fs = require('fs');

const files = [
  'client/public/src/emotes.js',
  'client/public/src/physics.js',
  'client/public/src/main.js',
  'client/public/src/admin.js',
  'client/public/src/network.js'
];

files.forEach(f => {
  if (!fs.existsSync(f)) return;
  let text = fs.readFileSync(f, 'utf8');
  let original = text;
  
  if (f.includes('admin.js')) {
    if (!text.includes('import { getCharacterProxy')) {
      text = `import { getCharacterProxy, clearCharacterProxy } from './characters.js';\nimport { getObjectProxy, clearObjectProxy } from './maps.js';\n` + text;
    }
  } else if (!f.includes('characters.js') && !f.includes('maps.js')) {
    if (!text.includes('import { getCharacterProxy')) {
      text = `import { getCharacterProxy } from './characters.js';\n` + text;
    }
  }
  
  if (text !== original) {
    fs.writeFileSync(f, text);
    console.log(`Injected imports into ${f}`);
  }
});
