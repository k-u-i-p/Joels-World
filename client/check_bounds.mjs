import { Document, NodeIO } from '@gltf-transform/core';
import fs from 'fs';
import path from 'path';

async function checkBounds() {
    const io = new NodeIO();
    const dirPath = 'public/models/heads';
    const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.glb'));

    for (const file of files) {
        const filePath = path.join(dirPath, file);
        
        try {
            const document = await io.read(filePath);
            const root = document.getRoot();

            let min = [Infinity, Infinity, Infinity];
            let max = [-Infinity, -Infinity, -Infinity];

            const meshes = root.listMeshes();
            for (const mesh of meshes) {
                for (const primitive of mesh.listPrimitives()) {
                    const positionAccessor = primitive.getAttribute('POSITION');
                    if (positionAccessor) {
                        const array = positionAccessor.getArray();
                        for (let i = 0; i < array.length; i += 3) {
                            const x = array[i];
                            const y = array[i+1];
                            const z = array[i+2];
                            if (x < min[0]) min[0] = x;
                            if (y < min[1]) min[1] = y;
                            if (z < min[2]) min[2] = z;
                            if (x > max[0]) max[0] = x;
                            if (y > max[1]) max[1] = y;
                            if (z > max[2]) max[2] = z;
                        }
                    }
                }
            }

            const sizeX = max[0] - min[0];
            const sizeY = max[1] - min[1];
            const sizeZ = max[2] - min[2];
            console.log(`${file}: Size [${sizeX.toFixed(2)}, ${sizeY.toFixed(2)}, ${sizeZ.toFixed(2)}]`);
        } catch (err) {
            console.error(`Error processing ${file}:`, err);
        }
    }
}

checkBounds().catch(console.error);
