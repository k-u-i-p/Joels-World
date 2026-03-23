const fs = require('fs');

let text = fs.readFileSync('client/public/src/characters.js', 'utf8');

text = text.replace(/ensureDomElements\(c\) \{/g, 
  "ensureDomElements(c) {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);"
);

text = text.replace(/updateAnimation\(c, isNpc, timeScale\) \{/g, 
  "updateAnimation(c, isNpc, timeScale) {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);"
);

text = text.replace(/updateChatBubble\(c, isNpc\) \{/g, 
  "updateChatBubble(c, isNpc) {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);"
);

fs.writeFileSync('client/public/src/characters.js', text);
console.log('Fixed closures 2');
