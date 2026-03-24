import { Document, NodeIO } from '@gltf-transform/core';
import fs from 'fs';
import path from 'path';

async function fixAllGLBs() {
    const io = new NodeIO();
    const dirPath = 'public/models/heads';
    const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.glb'));

    for (const file of files) {
        const filePath = path.join(dirPath, file);
        console.log(`\nProcessing ${filePath}...`);
        
        try {
            const document = await io.read(filePath);
            const root = document.getRoot();

            // 1. Rename Meshes
            console.log("Renaming meshes based on User criteria...");
            let faceIdx = 0;
            let hairIdx = 0;
            
            root.listNodes().forEach((node) => {
                const name = node.getName();
                const mesh = node.getMesh();
                if (mesh) {
                    // "ONLY Front_parts14* is face"
                    if (name.includes('Front_parts14')) {
                        const newName = `face_${faceIdx++}`;
                        node.setName(newName);
                        mesh.setName(newName);
                    } else {
                        // Everything else (PM3D_Sphere3D1, Front_parts13, ribbons, etc) is considered hair/accessory 
                        // and dyed by `characters.js` mats.hair!
                        const newName = `hair_${hairIdx++}`;
                        node.setName(newName);
                        mesh.setName(newName);
                    }
                }
            });

            // 2. Remove any previous Transform Wrappers we added that messed up the hierarchy
            const scene = root.listScenes()[0];
            const originalChildren = [];
            
            // Clean up: If we have 'TransformWrapper', unwrap its children and delete the wrapper
            let wrapper = scene.listChildren().find(n => n.getName() === 'TransformWrapper');
            if (wrapper) {
                for (const wrappedChild of wrapper.listChildren()) {
                    scene.addChild(wrappedChild);
                    originalChildren.push(wrappedChild);
                }
                wrapper.dispose(); // Delete our old wrapper entirely
            } else {
                for (const c of scene.listChildren()) {
                    originalChildren.push(c);
                }
            }

            // 3. To completely eliminate origin floating errors, we will MANUALLY modify the binary POSITION vertex attributes
            // This bypasses any bugs with clearNodeTransform.
            const meshes = root.listMeshes();
            let min = [Infinity, Infinity, Infinity];
            let max = [-Infinity, -Infinity, -Infinity];

            const accessorsToShift = new Set();

            // We want to calculate the origin ONLY from the face mesh!
            // If we use the hair, massive ponytails drag the mathematical center down,
            // pushing the head high into the sky!
            let minFace = [Infinity, Infinity, Infinity];
            let maxFace = [-Infinity, -Infinity, -Infinity];
            
            for (const mesh of meshes) {
                const name = mesh.getName() || "";
                if (name.includes('face')) {
                    for (const primitive of mesh.listPrimitives()) {
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
                }
            }

            // The exact mathematical center (X, Z) and the lowest point (Y - the chin/neck)
            const centerX = (minFace[0] + maxFace[0]) / 2;
            const centerY = minFace[1]; // Neck
            const centerZ = (minFace[2] + maxFace[2]) / 2;
            console.log(`Face neck origin: [${centerX}, ${centerY}, ${centerZ}]`);

            // Shift all vertices by -center so Origin is now PERFECTLY at neck
            console.log("Shifting POSITION data to neck anchor...");
            
            // Re-traverse ALL meshes (face and hair) to shift them TOGETHER using the calculated face anchor
            for (const mesh of meshes) {
                for (const primitive of mesh.listPrimitives()) {
                    const pos = primitive.getAttribute('POSITION');
                    if (pos) {
                        accessorsToShift.add(pos);
                    }
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

            // Because these models are so small compared to game dimensions, 
            // the user applies Scale (90,90,90) and Rotation in the code itself!
            // I will let characters.js handle the scale and rotation dynamically!
            // This guarantees the GLB is identical to standard Three.js exported models.

            await io.write(filePath, document);
            console.log("Saved.");
        } catch (err) {
            console.error(`Error processing ${file}:`, err);
        }
    }
    console.log("\nFinished all files!");
}

fixAllGLBs().catch(console.error);
