import { Document, NodeIO } from '@gltf-transform/core';
import fs from 'fs';

async function debug() {
    const io = new NodeIO();
    const doc = await io.read('public/models/heads/male_hair_short.glb');
    
    doc.getRoot().listNodes().forEach((node) => {
        console.log(node.getName());
    });
}
debug().catch(console.error);
