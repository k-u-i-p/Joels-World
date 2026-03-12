import fs from 'fs';
import path from 'path';

export function handleAdminMessage(ws, data, mapData) {
  const { objects, objectsFile } = mapData;

  console.log('Admin message:', data);

  if (data.type === 'move_object') {
    const obj = objects.find(o => o.id === data.id);
    if (obj) {
      obj.x = data.x;
      obj.y = data.y;
      try {
        fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
      } catch (e) { console.error('Failed saving objects file:', e); }
    }
    return true;
  } else if (data.type === 'rename_object') {
    const obj = objects.find(o => o.id === data.id);
    if (obj) {
      if (data.name) obj.name = data.name;
      else delete obj.name;
      try {
        fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
      } catch (e) { console.error('Failed saving objects file:', e); }
    }
    return true;
  } else if (data.type === 'resize_object') {
    const obj = objects.find(o => o.id === data.id);
    if (obj) {
      if (data.width !== undefined) obj.width = data.width;
      if (data.length !== undefined) obj.length = data.length;
      try {
        fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
      } catch (e) { console.error('Failed saving objects file:', e); }
    }
    return true;
  } else if (data.type === 'rotate_object') {
    const obj = objects.find(o => o.id === data.id);
    if (obj) {
      if (data.rotation !== undefined) obj.rotation = data.rotation;
      try {
        fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
      } catch (e) { console.error('Failed saving objects file:', e); }
    }
    return true;
  } else if (data.type === 'delete_object') {
    const idx = objects.findIndex(o => o.id === data.id);
    if (idx !== -1) {
      objects.splice(idx, 1);
      try {
        fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
      } catch (e) { console.error('Failed saving objects file:', e); }
    }
    return true;
  } else if (data.type === 'toggle_object_noclip') {
    const obj = objects.find(o => o.id === data.id);
    if (obj) {
      if (data.noclip) obj.noclip = true;
      else delete obj.noclip;
      try {
        fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
      } catch (e) { console.error('Failed saving objects file:', e); }
    }
    return true;
  } else if (data.type === 'create_object') {
    const newObj = {
      id: `obj_${Date.now()}`,
      shape: data.shape || 'rect',
      x: data.x,
      y: data.y,
      width: 500,
      length: 500
    };
    if (data.name !== undefined) newObj.name = data.name;
    if (data.rotation !== undefined) newObj.rotation = data.rotation;
    
    objects.push(newObj);
    try {
      fs.writeFileSync(objectsFile, JSON.stringify(objects, null, 2), 'utf-8');
    } catch (e) { console.error('Failed saving objects file:', e); }
    return true;
  }

  return false;
}
