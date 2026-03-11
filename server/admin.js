import fs from 'fs';
import path from 'path';

export function handleAdminMessage(ws, data, mapData) {
  const { buildings, buildingsFile, collisionObjects, collisionObjectsFile } = mapData;

  console.log('Admin message:', data);

  if (data.type === 'move_building') {
    const building = buildings.find(b => b.id === data.id);
    if (building) {
      building.x = data.x;
      building.y = data.y;
      try {
        fs.writeFileSync(buildingsFile, JSON.stringify(buildings, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving buildings file:', e);
      }
    }
    return true;
  } else if (data.type === 'rename_building') {
    const building = buildings.find(b => b.id === data.id);
    if (building) {
      if (data.name) {
        building.name = data.name;
      } else {
        delete building.name;
      }
      try {
        fs.writeFileSync(buildingsFile, JSON.stringify(buildings, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving buildings file:', e);
      }
    }
    return true;
  } else if (data.type === 'move_collision_object') {
    const obj = collisionObjects.find(p => p.id === data.id);
    if (obj) {
      obj.x = data.x;
      obj.y = data.y;
      try {
        fs.writeFileSync(collisionObjectsFile, JSON.stringify(collisionObjects, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving collision objects file:', e);
      }
    }
    return true;
  } else if (data.type === 'resize_collision_object') {
    const obj = collisionObjects.find(p => p.id === data.id);
    if (obj) {
      if (data.width !== undefined) obj.width = data.width;
      if (data.length !== undefined) obj.length = data.length;
      try {
        fs.writeFileSync(collisionObjectsFile, JSON.stringify(collisionObjects, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving collision objects file:', e);
      }
    }
    return true;
  } else if (data.type === 'rotate_collision_object') {
    const obj = collisionObjects.find(p => p.id === data.id);
    if (obj) {
      if (data.rotation !== undefined) obj.rotation = data.rotation;
      try {
        fs.writeFileSync(collisionObjectsFile, JSON.stringify(collisionObjects, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving collision objects file:', e);
      }
    }
    return true;
  } else if (data.type === 'delete_building') {
    const idx = buildings.findIndex(b => b.id === data.id);
    if (idx !== -1) {
      buildings.splice(idx, 1);
      try {
        fs.writeFileSync(buildingsFile, JSON.stringify(buildings, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving buildings file:', e);
      }
    }
    return true;
  } else if (data.type === 'delete_collision_object') {
    const idx = collisionObjects.findIndex(c => c.id === data.id);
    if (idx !== -1) {
      collisionObjects.splice(idx, 1);
      try {
        fs.writeFileSync(collisionObjectsFile, JSON.stringify(collisionObjects, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving collision objects file:', e);
      }
    }
    return true;
  } else if (data.type === 'rotate_building') {
    const building = buildings.find(b => b.id === data.id);
    if (building) {
      building.rotation = data.rotation;
      try {
        fs.writeFileSync(buildingsFile, JSON.stringify(buildings, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving buildings file:', e);
      }
    }
    return true;
  } else if (data.type === 'resize_building') {
    const building = buildings.find(b => b.id === data.id);
    if (building) {
      building.width = data.width;
      building.height = data.height;
      try {
        fs.writeFileSync(buildingsFile, JSON.stringify(buildings, null, 2), 'utf-8');
      } catch (e) {
        console.error('Failed saving buildings file:', e);
      }
    }
    return true;
  } else if (data.type === 'create_building') {
    const newBuilding = {
      id: `building_${Date.now()}`,
      name: "New Building",
      x: data.x,
      y: data.y,
      rotation: 0,
      width: 500,
      height: 500,
      walls: []
    };
    buildings.push(newBuilding);
    fs.writeFileSync(buildingsFile, JSON.stringify(buildings, null, 2), 'utf-8');
    return true;
  } else if (data.type === 'create_collision_object') {
    const newObj = {
      id: `col_${Date.now()}`,
      shape: data.shape || 'rect',
      x: data.x,
      y: data.y,
      width: 500,
      length: 500
    };
    collisionObjects.push(newObj);
    try {
      fs.writeFileSync(collisionObjectsFile, JSON.stringify(collisionObjects, null, 2), 'utf-8');
    } catch (e) {
      console.error('Failed saving collision objects file:', e);
    }
    return true;
  }

  return false;
}
