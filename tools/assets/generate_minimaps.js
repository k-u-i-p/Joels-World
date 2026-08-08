import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { MINIMAPS_DIR, assetPath, assetRelative, readMaps } from './paths.js';

export async function ensureMinimaps() {
  console.log('[Minimaps] Checking map minimap generation...');
  const mapsData = readMaps('[Minimaps]');
  if (!mapsData) return;
  
  if (!fs.existsSync(MINIMAPS_DIR)) {
    fs.mkdirSync(MINIMAPS_DIR, { recursive: true });
  }
  
  for (const map of mapsData) {
    if (!map.layers || map.layers.length === 0) continue;
    
    // Grab the absolute bottom-most layer (z=0) to use as the minimap baseline
    const baseLayer = map.layers.find(l => l.z === 0) || map.layers[0];
    
    if (baseLayer && baseLayer.source_image) {
      const sourceRel = assetRelative(baseLayer.source_image);
      const inputPath = assetPath(sourceRel);
      
      const outputPath = path.join(MINIMAPS_DIR, `${map.id}.png`);
      let needsGeneration = false;
      
      if (!fs.existsSync(inputPath)) {
        console.warn(`[Minimaps] Skipping ${map.id} - Source image not found: ${inputPath}`);
        continue;
      }

      if (!fs.existsSync(outputPath)) {
        needsGeneration = true;
      } else {
        const inputStat = fs.statSync(inputPath);
        const outputStat = fs.statSync(outputPath);
        // Trigger re-generation if the source image is newer than the generated minimap.
        if (inputStat.mtimeMs > outputStat.mtimeMs) {
          needsGeneration = true;
        }
      }

      if (needsGeneration) {
        console.log(`[Minimaps] Generating/Updating minimap for ${map.id}...`);
        try {
          await sharp(inputPath)
            .resize(512, null, { withoutEnlargement: true })
            .png({ quality: 80 })
            .toFile(outputPath);
            
          console.log(`[Minimaps] Generated successfully for ${map.id}.`);
        } catch (err) {
           console.error(`[Minimaps] Failed to process minimap for ${map.id}:`, err);
        }
      }
    }
  }
}
