import { Document, NodeIO } from '@gltf-transform/core';
import fs from 'fs';
import path from 'path';

async function checkFaces() {
    const io = new NodeIO();
    const dirPath = 'public/models/heads';
    const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.glb'));

    for (const file of files) {
        const filePath = path.join(dirPath, file);
        try {
            const document = await io.read(filePath);
            const root = document.getRoot();

            let minFace = [Infinity, Infinity, Infinity];
            let maxFace = [-Infinity, -Infinity, -Infinity];
            let allMin = [Infinity, Infinity, Infinity];
            let allMax = [-Infinity, -Infinity, -Infinity];

            for (const mesh of root.listMeshes()) {
                const name = mesh.getName() || "";
                for (const primitive of mesh.listPrimitives()) {
                    const pos = primitive.getAttribute('POSITION');
                    if (pos) {
                        const arr = pos.getArray();
                        for (let i = 0; i < arr.length; i += 3) {
                            const x = arr[i], y = arr[i+1], z = arr[i+2];
                            if (name.includes('face')) {
                                if (x < minFace[0]) minFace[0] = x;
                                if (y < minFace[1]) minFace[1] = y;
                                if (z < minFace[2]) minFace[2] = z;
                                if (x > maxFace[0]) maxFace[0] = x;
                                if (y > maxFace[1]) maxFace[1] = y;
                                if (z > maxFace[2]) maxFace[2] = z;
                            }
                            if (x < allMin[0]) allMin[0] = x;
                            if (y < allMin[1]) allMin[1] = y;
                            if (z < allMin[2]) allMin[2] = z;
                            if (x > allMax[0]) allMax[0] = x;
                            if (y > allMax[1]) allMax[1] = y;
                            if (z > allMax[2]) allMax[2] = z;
                        }
                    }
                }
            }

            const faceWidth = maxFace[0] - minFace[0];
            const allWidth = allMax[0] - allMin[0];
            const allHeight = allMax[1] - allMin[1];
            
            console.log(`${file}: Face Width=${faceWidth.toFixed(3)}, Total Bounds=[${allWidth.toFixed(2)}, ${allHeight.toFixed(2)}]`);
        } catch (err) {
            console.error(err);
        }
    }
}

checkFaces().catch(console.error);
