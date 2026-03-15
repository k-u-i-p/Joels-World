import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const basePath = path.resolve(__dirname, '../public');
const mapsJsonPath = path.resolve(__dirname, '../server/data/maps.json');

export async function processOverlays() {
  console.log('[OverlayGen] Starting overlay generation process...');

  let mapsData;
  try {
    mapsData = JSON.parse(fs.readFileSync(mapsJsonPath, 'utf8'));
  } catch (err) {
    console.error('[OverlayGen] Error reading maps.json:', err);
    return;
  }

  for (const map of mapsData) {
    if (!map.clip_mask || !map.layers) continue;

    const clipMaskRel = map.clip_mask.startsWith('/') ? map.clip_mask.substring(1) : map.clip_mask;
    const clipMaskPath = path.join(basePath, clipMaskRel);

    if (!fs.existsSync(clipMaskPath)) {
      console.warn(`[OverlayGen] Map "${map.name}" defines a clip_mask but the file is missing: ${clipMaskPath}`);
      continue;
    }

    console.log(`\n[OverlayGen] Processing map: "${map.name}" utilizing mask: ${clipMaskRel}`);

    for (const layerGroup of map.layers) {
      for (const layer of layerGroup) {
        if (!layer.source_image || layer.overlay || layer.source_image.includes('_overlay.')) continue;

        const sourceRel = layer.source_image.startsWith('/') ? layer.source_image.substring(1) : layer.source_image;
        const sourcePath = path.join(basePath, sourceRel);

        if (!fs.existsSync(sourcePath)) {
          console.warn(`[OverlayGen] Layer source image missing, skipping: ${sourcePath}`);
          continue;
        }

        const parsedSource = path.parse(sourceRel);
        const outName = `${parsedSource.name}_overlay.png`;
        const outPath = path.join(basePath, parsedSource.dir, outName);

        if (fs.existsSync(outPath)) {
          console.log(`  -> Skipping existing overlay: ${sourceRel}`);
          continue;
        }

        console.log(`  -> Processing layer: ${sourceRel}`);

        try {
          // 1. Get dimensions of the source image
          const sourceObj = sharp(sourcePath);
          const sourceMeta = await sourceObj.metadata();

          // Ensure source has alpha channel
          const sourceBuffer = await sourceObj.ensureAlpha().raw().toBuffer();

          // 2. Load and resize the clip mask to match the source exactly
          const maskObj = sharp(clipMaskPath);
          const maskBuffer = await maskObj
            .resize(sourceMeta.width, sourceMeta.height, { fit: 'fill' })
            .ensureAlpha() // Just to be safe that we get 4 channels (RGBA)
            .raw()
            .toBuffer();

          // 3. Modifying raw pixel buffers
          // Both buffers are now RGBA format, matching byte alignment: 4 bytes per pixel.
          const totalBytes = sourceMeta.width * sourceMeta.height * 4;

          for (let i = 0; i < totalBytes; i += 4) {
            const maskR = maskBuffer[i];
            const maskG = maskBuffer[i + 1];
            const maskB = maskBuffer[i + 2];
            const maskA = maskBuffer[i + 3];

            // If pixel is mostly black and opaque... keep it! Else, transparent.
            // Also keep pure green (0, 255, 0) which players can walk behind.
            if (maskA == 255 && maskR == 0 && maskB == 0 && maskG == 0 || maskA == 255 && maskG == 255 && maskR == 0 && maskB == 0) {
              // Do nothing, leave source pixel as is regarding alpha.
            } else {
              // Pixel is NOT part of the clipping path, make it fully transparent in the new image
              sourceBuffer[i + 3] = 0;
            }
          }

          // 4. Encode the buffer back into a PNG file
          await sharp(sourceBuffer, {
            raw: {
              width: sourceMeta.width,
              height: sourceMeta.height,
              channels: 4
            }
          })
            .png({
              compressionLevel: 9,
              adaptiveFiltering: true,
              effort: 10
            })
            .toFile(outPath);

          console.log(`     [Success] Saved overlay: ${path.join(parsedSource.dir, outName)}`);

        } catch (err) {
          console.error(`     [Error] Failed to generate overlay for ${sourceRel}:`, err);
        }
      }
    }
  }

  console.log('\n[OverlayGen] Finished generating overlays!');
}

if (process.argv[1] === __filename) {
  processOverlays().catch(console.error);
}
