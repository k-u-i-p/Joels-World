import { Document, NodeIO } from '@gltf-transform/core';
import fs from 'fs';

async function debug() {
    const io = new NodeIO();
    const doc = await io.read('public/models/heads/male_hair_short.glb');
    
    doc.getRoot().listNodes().forEach((node) => {
        const name = node.getName();
        const mesh = node.getMesh();
        if (mesh && name.includes('Front_parts14')) {
            let min = [Infinity, Infinity, Infinity];
            let max = [-Infinity, -Infinity, -Infinity];
            for (const primitive of mesh.listPrimitives()) {
                const pos = primitive.getAttribute('POSITION');
                if (pos) {
                    const arr = pos.getArray();
                    for (let i = 0; i < arr.length; i += 3) {
                        const y = arr[i+1];
                        if (y < min[1]) min[1] = y;
                        if (y > max[1]) max[1] = y;
                    }
                }
            }
            const height = max[1] - min[1];
            console.log(`Node: ${name}, min[1]: ${min[1]}, max[1]: ${max[1]}, height: ${height}`);
        }
    });
}
debug().catch(console.error);
