const fs = require('fs');

let text = fs.readFileSync('client/public/src/characters.js', 'utf8');

text = text.replace(/updateHeadColor\(c, hexColor\) \{/g, 
  "updateHeadColor(c, hexColor) {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);"
);

text = text.replace(/getLimbColor\(c\) \{/g, 
  "getLimbColor(c) {\n    if (!c) return null;\n    const vis = getCharacterProxy(c.id);"
);

text = text.replace(/updateLimbColors\(c\) \{/g, 
  "updateLimbColors(c) {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);"
);

text = text.replace(/ensureThreeSetup\(c, scene\) \{/g, 
  "ensureThreeSetup(c, scene) {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);"
);

fs.writeFileSync('client/public/src/characters.js', text);
console.log('Fixed closures');
