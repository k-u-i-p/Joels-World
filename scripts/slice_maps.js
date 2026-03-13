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
  
  let mapsModified = false;
  
  for (const map of mapsData) {
    if (!map.layers) continue;
    
    for (const layerGroup of map.layers) {
      for (const layer of layerGroup) {
        if (layer.chunked && layer.source_image) {
          const sourceRel = layer.source_image.startsWith('/') ? layer.source_image.substring(1) : layer.source_image;
          const inputPath = path.join(basePath, sourceRel);
          const parsed = path.parse(sourceRel);
          const chunksDir = path.join(basePath, parsed.dir, 'chunks');
          
          if (fs.existsSync(inputPath)) {
            try {
              const metadata = await sharp(inputPath).metadata();
              const calcGridW = Math.ceil(metadata.width / layer.chunk_size);
              const calcGridH = Math.ceil(metadata.height / layer.chunk_size);
              if (layer.grid_w !== calcGridW || layer.grid_h !== calcGridH) {
                layer.grid_w = calcGridW;
                layer.grid_h = calcGridH;
                mapsModified = true;
                console.log(`[Chunker] Updated grid dimensions for ${sourceRel}: ${calcGridW}x${calcGridH}`);
              }
            } catch (err) {
              console.warn(`[Chunker] Failed to read metadata for ${inputPath}`, err);
            }
          }
          
          const metadataPath = path.join(chunksDir, `${parsed.name}_meta.json`);
          let needsGeneration = false;
          
          if (!fs.existsSync(chunksDir)) {
            needsGeneration = true;
          } else if (fs.existsSync(inputPath)) {
            if (!fs.existsSync(metadataPath)) {
              needsGeneration = true;
            } else {
              const inputStat = fs.statSync(inputPath);
              try {
                const meta = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
                // Trigger re-chunk if the file size changed, or if mtime differs. 
                // Comparing exact match instead of '>' covers files pasted from Finder that have older mtimes.
                if (meta.size !== inputStat.size || meta.mtime !== inputStat.mtimeMs) {
                  needsGeneration = true;
                }
              } catch (e) {
                needsGeneration = true;
              }
            }
          }

          if (needsGeneration) {
            console.log(`[Chunker] Missing or outdated chunks for ${sourceRel}. Generating...`);
            if (!fs.existsSync(chunksDir)) {
              fs.mkdirSync(chunksDir, { recursive: true });
            }
            await processLayer(inputPath, chunksDir, parsed.name, parsed.ext, layer.chunk_size);
            
            const inputStat = fs.statSync(inputPath);
            fs.writeFileSync(metadataPath, JSON.stringify({ size: inputStat.size, mtime: inputStat.mtimeMs }));
          }
        }
      }
    }
  }

  if (mapsModified) {
    fs.writeFileSync(mapsJsonPath, JSON.stringify(mapsData, null, 2));
    console.log('[Chunker] Updated maps.json with calculated grid dimensions.');
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
