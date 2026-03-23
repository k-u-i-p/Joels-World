const fs = require('fs');

let text = fs.readFileSync('client/public/src/characters.js', 'utf8');

// Array of known helper methods that take `c` but where `vis` was orphaned.
const targets = [
  'createCharacterRig(c)',
  'applyShoeModel(rig, mats, c)',
  'updateCharacter3D(c, isNpc, player, syncPlayerToJSON)'
];

targets.forEach(t => {
  // Regex to match the exact spacing
  const escaped = t.replace(/\(/g, '\\(').replace(/\)/g, '\\)');
  const regex = new RegExp(escaped + ' \\{');
  
  if (text.match(regex)) {
    text = text.replace(regex, `${t} {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);`);
  }
});

fs.writeFileSync('client/public/src/characters.js', text);
console.log('Fixed closures 3');
