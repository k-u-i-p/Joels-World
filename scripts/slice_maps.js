import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const basePath = path.resolve(__dirname, '../public');
const mapsJsonPath = path.resolve(__dirname, '../server/data/maps.json');

export async function ensureMapChunks() {
  console.log('[Chunker] Checking map chunk allocations...');
  let mapsData;
  try {
    mapsData = JSON.parse(fs.readFileSync(mapsJsonPath, 'utf8'));
  } catch (err) {
    console.error('[Chunker] Error reading maps.json:', err);
    return;
  }
  
  for (const map of mapsData) {
    if (!map.layers) continue;
    
    for (const layerGroup of map.layers) {
      for (const layer of layerGroup) {
        if (layer.chunked && layer.source_image) {
          const sourceRel = layer.source_image.startsWith('/') ? layer.source_image.substring(1) : layer.source_image;
          const inputPath = path.join(basePath, sourceRel);
          const parsed = path.parse(sourceRel);
          const chunksDir = path.join(basePath, parsed.dir, 'chunks');
          
          if (!fs.existsSync(chunksDir)) {
            console.log(`[Chunker] Missing chunks for ${sourceRel}. Generating...`);
            fs.mkdirSync(chunksDir, { recursive: true });
            await processLayer(inputPath, chunksDir, parsed.name, parsed.ext, layer.chunk_size);
          }
        }
      }
    }
  }
}

async function processLayer(inputPath, chunksDir, baseName, ext, chunkSize) {
  if (!fs.existsSync(inputPath)) {
    console.warn(`[Skip] Missing file: ${inputPath}`);
    return;
  }

  try {
    const image = sharp(inputPath);
    const metadata = await image.metadata();
    
    const width = metadata.width;
    const height = metadata.height;
    
    const gridW = Math.ceil(width / chunkSize);
    const gridH = Math.ceil(height / chunkSize);

    console.log(`\nSlicing ${baseName}${ext} (${width}x${height}) into ${gridW}x${gridH} chunks...`);

    const extractPromises = [];
    let chunkCount = 0;

    const isPng = ext.toLowerCase() === '.png';

    for (let y = 0; y < gridH; y++) {
      for (let x = 0; x < gridW; x++) {
        const left = x * chunkSize;
        const top = y * chunkSize;
        
        const extractWidth = Math.min(chunkSize, width - left);
        const extractHeight = Math.min(chunkSize, height - top);

        const outputPath = path.join(chunksDir, `${baseName}_${x}_${y}${ext}`);

        let extractor = image.clone().extract({ left, top, width: extractWidth, height: extractHeight });
        
        if (isPng) {
          extractor = extractor.png();
        } else {
          // Removes alpha layer for solid JPG backgrounds to prevent sharp from 
          // feathering the transparent rendering edges - stops the faint grid effect!
          extractor = extractor.removeAlpha().jpeg({ quality: 85 });
        }

        extractPromises.push(
          extractor.toFile(outputPath).then(() => {
            chunkCount++;
            process.stdout.write(`\rProgress: ${chunkCount}/${gridW * gridH} chunks saved.`);
          })
        );
      }
    }

    await Promise.all(extractPromises);
    console.log(`\n[Success] Sliced ${baseName}${ext}!`);
    
  } catch (err) {
    console.error(`\n[Error] Failed processing ${inputPath}:`, err);
  }
}
