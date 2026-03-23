const fs = require('fs');
let phys = fs.readFileSync('client/public/src/physics.js', 'utf8');

// 1. In physics.js `processInterpolation(c, timeScale)`
phys = phys.replace(/processInterpolation\(c, timeScale\) \{/g, 
  "processInterpolation(c, timeScale) {\n    const vis = getCharacterProxy(c.id);"
);

// 2. In physics.js `convergePhysics(c)`
phys = phys.replace(/convergePhysics\(c\) \{/g, 
  "convergePhysics(c) {\n    const vis = getCharacterProxy(c.id);"
);

phys = phys.replace(/getCharacterProxy\(c\.id\)/g, "vis");
phys = phys.replace(/const vis = vis;/g, "const vis = getCharacterProxy(c.id);");

fs.writeFileSync('client/public/src/physics.js', phys);
console.log('Optimized physics proxy caching');
