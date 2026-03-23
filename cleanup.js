const fs = require('fs');

const file = 'server/data/detention/npc.json';
const data = JSON.parse(fs.readFileSync(file, 'utf8'));

function clean(obj) {
    if (obj.nameElement) delete obj.nameElement;
    if (obj.meshGroup) delete obj.meshGroup;
    if (obj.chatElement) delete obj.chatElement;
    if (obj.activeAudio) delete obj.activeAudio;
    if (obj.labelElement) delete obj.labelElement;
    if (obj.rig) delete obj.rig;
    if (obj.shadowMesh) delete obj.shadowMesh;
    if (obj.chatTextNode) delete obj.chatTextNode;
    if (obj._distSq) delete obj._distSq;
}

data.forEach(clean);
fs.writeFileSync(file, JSON.stringify(data, null, 2));
console.log('Deep Cleaned npc.json! Removed heavy 33MB DOM geometries.');
