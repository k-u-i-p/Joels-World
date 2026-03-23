const fs = require('fs');

let text = fs.readFileSync('client/public/src/characters.js', 'utf8');

// 1. In drawCharacter
text = text.replace(/drawCharacter\(c, isNpc, layerType, scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera\) \{/g,
  "drawCharacter(c, isNpc, layerType, scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera) {\n    const vis = getCharacterProxy(c.id);"
);

// 2. In processDraw
text = text.replace(/const isVisible = \(vec\.z <= 1 && Math\.abs\(vec\.x\) <= 1\.3 && Math\.abs\(vec\.y\) <= 1\.3\);/g,
  "const isVisible = (vec.z <= 1 && Math.abs(vec.x) <= 1.3 && Math.abs(vec.y) <= 1.3);\n      const vis = getCharacterProxy(c.id);"
);

// 3. In updateLocalNPCs
// export function updateLocalNPCs(dt) {
//   ...
//   for (let i = 0; i < npcs.length; i++) {
//     const npc = npcs[i];
text = text.replace(/const npc = npcs\[i\];/g, "const npc = npcs[i];\n    const npcVis = getCharacterProxy(npc.id);");


// Replace the bodies:
text = text.replace(/getCharacterProxy\(c\.id\)/g, "vis");
text = text.replace(/getCharacterProxy\(npc\.id\)/g, "npcVis");

// Wait! If getCharacterProxy(c.id) was just replaced with vis globally,
// what about the `const vis = getCharacterProxy(c.id);` we just inserted?
// It will become `const vis = vis;` !!! We must prevent this!

// Fix the insertion strings so they don't get replaced:
text = text.replace(/const vis = vis;/g, "const vis = getCharacterProxy(c.id);");
text = text.replace(/const npcVis = npcVis;/g, "const npcVis = getCharacterProxy(npc.id);");

fs.writeFileSync('client/public/src/characters.js', text);
console.log('Optimized proxy caching');
