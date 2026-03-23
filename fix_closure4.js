const fs = require('fs');

let text = fs.readFileSync('client/public/src/characters.js', 'utf8');

const targets = [
  'drawHumanoid2D(ctx, c, limbs)',
  'drawHumanoidLowerBody2D(ctx, c, limbs, isVisible)',
  'drawHumanoidUpperBody2D(ctx, c, limbs, isVisible, getRaycastEnd)',
  'buildSkeletonMaterials(c)',
  'buildSkeletonRig(c, mats)',
  'buildSkeletonHair(c, mats)',
  'buildSkeletonLimbs(c, mats)',
  'buildShadowBlob(c)',
  'applyWalkCycle(c, legTimer)',
  'applyIdleSway(c, idleTime)',
  'applyEmoteOverrides(c, emoteDef, currentEmote)',
  'resolveInverseKinematics(c)',
  'updateHeadColor(c, hexColor)',
  'getLimbColor(c)',
  'updateLimbColors(c)'
];

targets.forEach(t => {
  const escaped = t.replace(/\(/g, '\\(').replace(/\)/g, '\\)');
  const regex = new RegExp(escaped + ' \\{');
  
  if (text.match(regex)) {
    // Only inject if not already injected manually
    text = text.replace(regex, `${t} {\n    if (!c) return;\n    const vis = getCharacterProxy(c.id);`);
  }
});

// Fix potential duplicate declarations if some already had them:
text = text.replace(/const vis = getCharacterProxy\(c\.id\);\n\s*if \(\!c\) return;\n\s*const vis = getCharacterProxy\(c\.id\);/g, "const vis = getCharacterProxy(c.id);");

fs.writeFileSync('client/public/src/characters.js', text);
console.log('Fixed closures 4');
