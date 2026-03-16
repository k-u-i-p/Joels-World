import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const basePath = path.resolve(__dirname, '../public');
const mapsJsonPath = path.resolve(__dirname, '../server/data/maps.json');
const minimapsDir = path.resolve(__dirname, '../public/minimaps');

export async function ensureMinimaps() {
  console.log('[Minimaps] Checking map minimap generation...');
  let mapsData;
  try {
    mapsData = JSON.parse(fs.readFileSync(mapsJsonPath, 'utf8'));
  } catch (err) {
    console.error('[Minimaps] Error reading maps.json:', err);
    return;
  }
  
  if (!fs.existsSync(minimapsDir)) {
    fs.mkdirSync(minimapsDir, { recursive: true });
  }
  
  for (const map of mapsData) {
    if (!map.layers || map.layers.length === 0 || map.layers[0].length === 0) continue;
    
    // Grab the absolute bottom-most layer (Layer 0, Image 0) to use as the minimap baseline
    const baseLayer = map.layers[0][0];
    
    if (baseLayer && baseLayer.source_image) {
      const sourceRel = baseLayer.source_image.startsWith('/') ? baseLayer.source_image.substring(1) : baseLayer.source_image;
      const inputPath = path.join(basePath, sourceRel);
      
      const outputPath = path.join(minimapsDir, `${map.id}.png`);
      const metadataPath = path.join(minimapsDir, `${map.id}_meta.json`);
      
      let needsGeneration = false;
      
      if (!fs.existsSync(inputPath)) {
        console.warn(`[Minimaps] Skipping ${map.id} - Source image not found: ${inputPath}`);
        continue;
      }

      if (!fs.existsSync(outputPath)) {
        needsGeneration = true;
      } else if (!fs.existsSync(metadataPath)) {
        needsGeneration = true;
      } else {
        const inputStat = fs.statSync(inputPath);
        try {
          const meta = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
          // Trigger re-generation if the file size changed, or if mtime differs. 
          if (meta.size !== inputStat.size || meta.mtime !== inputStat.mtimeMs) {
            needsGeneration = true;
          }
        } catch (e) {
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
            
          const inputStat = fs.statSync(inputPath);
          fs.writeFileSync(metadataPath, JSON.stringify({ size: inputStat.size, mtime: inputStat.mtimeMs }));
          console.log(`[Minimaps] Generated successfully for ${map.id}.`);
        } catch (err) {
           console.error(`[Minimaps] Failed to process minimap for ${map.id}:`, err);
        }
      }
    }
  }
}
