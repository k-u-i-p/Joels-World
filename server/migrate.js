import fs from 'fs';
import path from 'path';

const dataDir = path.join(process.cwd(), 'data');
const mapDirs = fs.readdirSync(dataDir, { withFileTypes: true })
  .filter(d => d.isDirectory())
  .map(d => d.name);

mapDirs.forEach(mapDir => {
  ['objects.json', 'npc.json'].forEach(fileName => {
    const filePath = path.join(dataDir, mapDir, fileName);
    if (!fs.existsSync(filePath)) return;

    let data;
    try {
      data = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
    } catch (e) {
      console.error('Error reading', filePath);
      return;
    }

    if (!Array.isArray(data)) return;

    let nextId = 1;
    let changed = false;

    data.forEach(item => {
      if (typeof item.id !== 'number' || item.id !== nextId) {
         item.id = nextId;
         changed = true;
      }
      nextId++;
    });

    if (changed) {
      fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf-8');
      console.log(`Migrated IDs in ${mapDir}/${fileName}`);
    }
  });
});
