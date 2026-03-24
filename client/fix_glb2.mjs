import { Document, NodeIO } from '@gltf-transform/core';
import fs from 'fs';
import path from 'path';

async function verifyAndFix() {
    const io = new NodeIO();
    const dirPath = 'public/models/heads';
    const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.glb'));

    for (const file of files) {
        const filePath = path.join(dirPath, file);
        try {
            const document = await io.read(filePath);
            const root = document.getRoot();

            let trueFaceMesh = null;
            let otherFaceMeshes = [];

            // First pass: identify the TRUE face vs the faux-face hair
            for (const mesh of root.listMeshes()) {
                const name = mesh.getName() || "";
                if (name.includes('face_')) {
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
                    // The standard imported anime face height is ~0.29.
                    // If it's smaller than 0.35, it's definitively the face geometry, not a massive ponytail!
                    if (height > 0 && height < 0.35) {
                        trueFaceMesh = mesh;
                    } else {
                        otherFaceMeshes.push(mesh);
                    }
                }
            }

            if (trueFaceMesh && otherFaceMeshes.length > 0) {
                console.log(`\nFixing corrupted ${file}:`);
                console.log(`Found true face: ${trueFaceMesh.getName()}`);
                
                // Re-name the faux faces that are actually hair!
                let hairIdx = 100;
                for (const fauxFace of otherFaceMeshes) {
                    console.log(`Found faux-face (hair): ${fauxFace.getName()}`);
                    const newName = `hair_${hairIdx++}`;
                    fauxFace.setName(newName);
                    
                    // Also rename its Node if possible
                    root.listNodes().forEach(n => {
                        if (n.getMesh() === fauxFace) {
                            n.setName(newName);
                        }
                    });
                }

                // Now re-calculate the true chin anchor from the trueFaceMesh!
                let minFace = [Infinity, Infinity, Infinity];
                let maxFace = [-Infinity, -Infinity, -Infinity];
                for (const primitive of trueFaceMesh.listPrimitives()) {
                    const pos = primitive.getAttribute('POSITION');
                    if (pos) {
                        const arr = pos.getArray();
                        for (let i = 0; i < arr.length; i += 3) {
                            const x = arr[i], y = arr[i+1], z = arr[i+2];
                            if (x < minFace[0]) minFace[0] = x;
                            if (y < minFace[1]) minFace[1] = y;
                            if (z < minFace[2]) minFace[2] = z;
                            if (x > maxFace[0]) maxFace[0] = x;
                            if (y > maxFace[1]) maxFace[1] = y;
                            if (z > maxFace[2]) maxFace[2] = z;
                        }
                    }
                }

                const centerX = (minFace[0] + maxFace[0]) / 2;
                const centerY = minFace[1]; // The true chin!
                const centerZ = (minFace[2] + maxFace[2]) / 2;

                console.log(`True chin offset needed: [${centerX}, ${centerY}, ${centerZ}]`);
                
                // If centerY is not 0, we need to shift EVERYTHING by -centerY!
                if (Math.abs(centerY) > 0.001 || Math.abs(centerX) > 0.001 || Math.abs(centerZ) > 0.001) {
                    const accessorsToShift = new Set();
                    for (const mesh of root.listMeshes()) {
                        for (const primitive of mesh.listPrimitives()) {
                            const pos = primitive.getAttribute('POSITION');
                            if (pos) accessorsToShift.add(pos);
                        }
                    }

                    for (const accessor of accessorsToShift) {
                        const array = accessor.getArray();
                        for (let i = 0; i < array.length; i += 3) {
                            array[i] -= centerX;
                            array[i+1] -= centerY;
                            array[i+2] -= centerZ;
                        }
                        accessor.setArray(array);
                    }
                    console.log("Successfully shifted meshes to true chin anchor!");
                }

                await io.write(filePath, document);
            }
        } catch (err) {
            console.error(`Error on ${file}:`, err);
        }
    }
}

verifyAndFix().catch(console.error);
