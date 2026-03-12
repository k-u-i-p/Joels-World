window.isAdmin = true;

console.log('Setting up admin');

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

const adminPanel = document.getElementById('admin-panel');

window.populateAdminMaps = () => {
  const select = document.getElementById('admin-map-select');
  if (!select || !window.mapsList) return;
  select.innerHTML = '';
  window.mapsList.forEach(mapData => {
    const opt = document.createElement('option');
    opt.value = mapData.id;
    opt.textContent = mapData.name;
    if (window.currentMapId === mapData.id) {
      opt.selected = true;
    }
    select.appendChild(opt);
  });
};

const mapSelect = document.getElementById('admin-map-select');
if (mapSelect) {
  mapSelect.addEventListener('change', (e) => {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'change_map', mapId: e.target.value }));
    }
  });
}

let activeHoldInterval = null;

function bindHoldAction(id, action, syncAction) {
  const btn = document.getElementById(id);
  if (!btn) return;

  let hasChanged = false;

  const start = (e) => {
    if (e && e.button !== 0) return;
    hasChanged = true;
    action();
    if (activeHoldInterval) clearInterval(activeHoldInterval);
    activeHoldInterval = setInterval(() => {
      hasChanged = true;
      action();
    }, 50);
  };

  const stop = () => {
    if (activeHoldInterval) {
      clearInterval(activeHoldInterval);
      activeHoldInterval = null;
    }
    if (hasChanged && syncAction) {
      syncAction();
    }
    hasChanged = false;
  };

  btn.addEventListener('mousedown', start);
  btn.addEventListener('mouseup', stop);
  btn.addEventListener('mouseleave', stop);
  btn.addEventListener('contextmenu', e => e.preventDefault());
}

let draggedObject = null;
let selectedObject = null;

function createObjectRef(type, id) {
  return {
    type,
    id,
    get data() {
      if (this.type === 'building') return (window.buildings || []).find(b => b.id === this.id);
      if (this.type === 'collision_object') return (window.collisionObjects || []).find(c => c.id === this.id);
      return null;
    }
  };
}

let dragOffsetX = 0;
let dragOffsetY = 0;

let isDraggingBackground = false;
let isDraggingAdminImage = false;
let bgDragOffsetX = 0;
let bgDragOffsetY = 0;
let lastMouseX = 0;
let lastMouseY = 0;

document.getElementById('btn-create-building').onclick = () => {
  console.log('Create building');
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_building', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
  }
};

document.getElementById('btn-create-col-rect').onclick = () => {
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_collision_object', shape: 'rect', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
  }
};

document.getElementById('btn-create-col-circle').onclick = () => {
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_collision_object', shape: 'circle', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
  }
};

document.getElementById('btn-delete-building').onclick = () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'delete_building', id: selectedObject.data.id }));
    selectedObject = null;
    draggedObject = null;
    window.adminSelectedObject = null;
    updateAdminPanel();
  }
};

document.getElementById('btn-delete-col').onclick = () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'delete_collision_object', id: selectedObject.data.id }));
    selectedObject = null;
    draggedObject = null;
    window.adminSelectedObject = null;
    updateAdminPanel();
  }
};

const nameInput = document.getElementById('building-name-input');
nameInput.onchange = (e) => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  selectedObject.data.name = e.target.value.trim();
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rename_building', id: selectedObject.data.id, name: selectedObject.data.name }));
  }
};

bindHoldAction('btn-rot-left', () => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  selectedObject.data.rotation = Math.max(0, (selectedObject.data.rotation || 0) - 1);
}, () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_building', id: selectedObject.data.id, rotation: selectedObject.data.rotation }));
  }
});

bindHoldAction('btn-rot-right', () => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  selectedObject.data.rotation = ((selectedObject.data.rotation || 0) + 1) % 360;
}, () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_building', id: selectedObject.data.id, rotation: selectedObject.data.rotation }));
  }
});

bindHoldAction('btn-width-dec', () => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  let change = Math.max(1, Math.round(selectedObject.data.width * 0.02));
  selectedObject.data.width = Math.max(10, selectedObject.data.width - change);
}, () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedObject.data.id, width: selectedObject.data.width, height: selectedObject.data.height }));
  }
});

bindHoldAction('btn-width-inc', () => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  let change = Math.max(1, Math.round(selectedObject.data.width * 0.02));
  selectedObject.data.width += change;
}, () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedObject.data.id, width: selectedObject.data.width, height: selectedObject.data.height }));
  }
});

bindHoldAction('btn-height-dec', () => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  let change = Math.max(1, Math.round(selectedObject.data.height * 0.02));
  selectedObject.data.height = Math.max(10, selectedObject.data.height - change);
}, () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedObject.data.id, width: selectedObject.data.width, height: selectedObject.data.height }));
  }
});

bindHoldAction('btn-height-inc', () => {
  if (!selectedObject || selectedObject.type !== 'building') return;
  let change = Math.max(1, Math.round(selectedObject.data.height * 0.02));
  selectedObject.data.height += change;
}, () => {
  if (selectedObject && selectedObject.type === 'building' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedObject.data.id, width: selectedObject.data.width, height: selectedObject.data.height }));
  }
});

bindHoldAction('btn-col-rot-left', () => {
  if (!selectedObject || selectedObject.type !== 'collision_object') return;
  selectedObject.data.rotation = Math.max(0, (selectedObject.data.rotation || 0) - 1);
}, () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_collision_object', id: selectedObject.data.id, rotation: selectedObject.data.rotation }));
  }
});

bindHoldAction('btn-col-rot-right', () => {
  if (!selectedObject || selectedObject.type !== 'collision_object') return;
  selectedObject.data.rotation = ((selectedObject.data.rotation || 0) + 1) % 360;
}, () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_collision_object', id: selectedObject.data.id, rotation: selectedObject.data.rotation }));
  }
});

bindHoldAction('btn-col-width-dec', () => {
  if (!selectedObject || selectedObject.type !== 'collision_object') return;
  let change = Math.max(1, Math.round(selectedObject.data.width * 0.02));
  selectedObject.data.width = Math.max(5, selectedObject.data.width - change);
}, () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedObject.data.id, width: selectedObject.data.width, length: selectedObject.data.length }));
  }
});

bindHoldAction('btn-col-width-inc', () => {
  if (!selectedObject || selectedObject.type !== 'collision_object') return;
  let change = Math.max(1, Math.round(selectedObject.data.width * 0.02));
  selectedObject.data.width += change;
}, () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedObject.data.id, width: selectedObject.data.width, length: selectedObject.data.length }));
  }
});

bindHoldAction('btn-col-length-dec', () => {
  if (!selectedObject || selectedObject.type !== 'collision_object') return;
  let change = Math.max(1, Math.round(selectedObject.data.length * 0.02));
  selectedObject.data.length = Math.max(5, selectedObject.data.length - change);
}, () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedObject.data.id, width: selectedObject.data.width, length: selectedObject.data.length }));
  }
});

bindHoldAction('btn-col-length-inc', () => {
  if (!selectedObject || selectedObject.type !== 'collision_object') return;
  let change = Math.max(1, Math.round(selectedObject.data.length * 0.02));
  selectedObject.data.length += change;
}, () => {
  if (selectedObject && selectedObject.type === 'collision_object' && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedObject.data.id, width: selectedObject.data.width, length: selectedObject.data.length }));
  }
});

const colNoclipCheckbox = document.getElementById('checkbox-col-noclip');
if (colNoclipCheckbox) {
  colNoclipCheckbox.addEventListener('change', (e) => {
    if (!selectedObject || selectedObject.type !== 'collision_object') return;
    selectedObject.data.noclip = e.target.checked;
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'toggle_collision_object_noclip', id: selectedObject.data.id, noclip: selectedObject.data.noclip }));
    }
  });
}

function updateAdminPanel() {
  adminPanel.style.display = 'block';

  const editSection = document.getElementById('edit-building-section');
  const editColObjSection = document.getElementById('edit-col-obj-section');

  if (selectedObject && selectedObject.type === 'building') {
    editSection.style.display = 'block';
    editColObjSection.style.display = 'none';

    const nameInput = document.getElementById('building-name-input');
    nameInput.value = selectedObject.data.name || selectedObject.data.id;
  } else if (selectedObject && selectedObject.type === 'collision_object') {
    editSection.style.display = 'none';
    editColObjSection.style.display = 'block';

    const colNoclipCheckbox = document.getElementById('checkbox-col-noclip');
    if (colNoclipCheckbox) {
      colNoclipCheckbox.checked = !!selectedObject.data.noclip;
    }
  } else {
    editSection.style.display = 'none';
    editColObjSection.style.display = 'none';
  }
}

function isPointInBuilding(worldX, worldY, building) {
  const bdx = worldX - building.x;
  const bdy = worldY - building.y;
  const angle = -(building.rotation || 0) * Math.PI / 180;

  // Inverse rotation to get local coordinates relative to center
  const localX = bdx * Math.cos(angle) - bdy * Math.sin(angle);
  const localY = bdx * Math.sin(angle) + bdy * Math.cos(angle);

  // Offset so (0,0) is top-left
  const tlX = localX + building.width / 2;
  const tlY = localY + building.height / 2;

  return tlX >= 0 && tlX <= building.width && tlY >= 0 && tlY <= building.height;
}



window.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return; // Only left click
  if (e.target.closest('#admin-panel')) return; // Ignore clicks on the admin panel itself

  const canvasRect = canvas.getBoundingClientRect();
  const mouseX = e.clientX - canvasRect.left;
  const mouseY = e.clientY - canvasRect.top;

  // Use canvas coordinates for simple delta tracking
  lastMouseX = e.clientX;
  lastMouseY = e.clientY;

  const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
  const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

  selectedObject = null;
  window.adminSelectedObject = null;
  draggedObject = null;
  const buildings = window.buildings || [];
  const collisionObjects = window.collisionObjects || [];

  // Check collision objects and buildings backwards so that top items are selected first
  for (let i = collisionObjects.length - 1; i >= 0; i--) {
    const obj = collisionObjects[i];
    let hit = false;
    if (obj.shape === 'circle') {
      const radius = Math.max(obj.width, obj.length) / 2;
      if (Math.hypot(worldX - obj.x, worldY - obj.y) <= radius) hit = true;
    } else {
      const bdx = worldX - obj.x;
      const bdy = worldY - obj.y;
      const angle = -(obj.rotation || 0) * Math.PI / 180;
      const localX = bdx * Math.cos(angle) - bdy * Math.sin(angle);
      const localY = bdx * Math.sin(angle) + bdy * Math.cos(angle);
      const hW = obj.width / 2;
      const hL = obj.length / 2;
      if (localX >= -hW && localX <= hW &&
        localY >= -hL && localY <= hL) {
        hit = true;
      }
    }

    if (hit) {
      console.log(`Dragging collision object: ${obj.id}`);
      draggedObject = createObjectRef('collision_object', obj.id);
      selectedObject = createObjectRef('collision_object', obj.id);
      window.adminSelectedObject = obj;
      dragOffsetX = obj.x - worldX;
      dragOffsetY = obj.y - worldY;
      break;
    }
  }

  if (!draggedObject) {
    for (let i = window.buildings.length - 1; i >= 0; i--) {
      if (isPointInBuilding(worldX, worldY, window.buildings[i])) {
        console.log(`Dragging building: ${window.buildings[i].id}`);
        draggedObject = createObjectRef('building', window.buildings[i].id);
        selectedObject = createObjectRef('building', window.buildings[i].id);
        window.adminSelectedObject = window.buildings[i];
        dragOffsetX = window.buildings[i].x - worldX;
        dragOffsetY = window.buildings[i].y - worldY;
        break;
      }
    }
  }

  if (!draggedObject && !e.target.closest('#admin-panel')) {
    if (e.shiftKey && window.adminBackgroundImage) {
      isDraggingAdminImage = true;
      bgDragOffsetX = (window.adminBackgroundImage._x || 0) - worldX;
      bgDragOffsetY = (window.adminBackgroundImage._y || 0) - worldY;
    } else {
      isDraggingBackground = true;
    }
  }

  // Only update panel if we didn't click on the panel itself
  if (!e.target.closest('#admin-panel')) {
    updateAdminPanel();
  }
});

window.addEventListener('mousemove', (e) => {
  if (draggedObject) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    draggedObject.data.x = Math.round(worldX + dragOffsetX);
    draggedObject.data.y = Math.round(worldY + dragOffsetY);
  } else if (isDraggingAdminImage && window.adminBackgroundImage) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    window.adminBackgroundImage._x = Math.round(worldX + bgDragOffsetX);
    window.adminBackgroundImage._y = Math.round(worldY + bgDragOffsetY);
  } else if (isDraggingBackground) {
    const dx = (lastMouseX - e.clientX) / window.cameraZoom;
    const dy = (lastMouseY - e.clientY) / window.cameraZoom;
    window.player.x += dx;
    window.player.y += dy;
    lastMouseX = e.clientX;
    lastMouseY = e.clientY;
  }
});

window.addEventListener('mouseup', () => {
  if (draggedObject) {
    if (window.ws.readyState === WebSocket.OPEN) {
      const typeStr = draggedObject.type === 'building' ? 'move_building' : 'move_collision_object';
      window.ws.send(JSON.stringify({
        type: typeStr,
        id: draggedObject.data.id,
        x: draggedObject.data.x,
        y: draggedObject.data.y
      }));
    }
    draggedObject = null;
  }
  isDraggingBackground = false;
  isDraggingAdminImage = false;
});

window.addEventListener('wheel', (e) => {
  if (e.ctrlKey) {
    e.preventDefault();
    const zoomSensitivity = 0.01;
    window.cameraZoom -= e.deltaY * zoomSensitivity;
    window.cameraZoom = Math.max(0.1, Math.min(window.cameraZoom, 5));
  }
}, { passive: false });

window.addEventListener('dragover', (e) => {
  e.preventDefault();
});

window.addEventListener('drop', (e) => {
  e.preventDefault();
  if (!e.dataTransfer.files || e.dataTransfer.files.length === 0) return;
  const file = e.dataTransfer.files[0];

  // Check for PNG or JPG file to set as a background
  const lowerName = file.name.toLowerCase();
  if (file.type.startsWith('image/') && (lowerName.endsWith('.png') || lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg'))) {
    const reader = new FileReader();
    reader.onload = (event) => {
      const img = new Image();
      img.onload = () => {
        window.adminBackgroundImage = img;
      };
      img.src = event.target.result;
    };
    reader.readAsDataURL(file);
  } else {
    console.warn("Dropped file is not a supported background image (PNG/JPG):", file.name);
  }
});

updateAdminPanel();

window.adminDraw = function () {
  ctx.save();
  ctx.translate(canvas.width / 2, canvas.height / 2);
  ctx.scale(window.cameraZoom, window.cameraZoom);
  ctx.translate(-window.cameraX, -window.cameraY);

  if (window.adminBackgroundImage && window.adminBackgroundImage.complete) {
    ctx.drawImage(window.adminBackgroundImage, window.adminBackgroundImage._x || 0, window.adminBackgroundImage._y || 0);
  }
  const buildings = window.buildings || [];
  buildings.forEach(building => {
    ctx.save();
    ctx.translate(building.x, building.y);
    ctx.rotate((building.rotation || 0) * Math.PI / 180);
    if (window.adminSelectedObject && window.adminSelectedObject.id === building.id) {
      ctx.fillStyle = 'rgba(155, 89, 182, 0.7)';
    } else {
      ctx.fillStyle = 'rgba(255, 0, 0, 0.5)';
    }
    ctx.fillRect(-building.width / 2, -building.height / 2, building.width, building.height);

    if (building.walls && building.walls.length > 0) {
      ctx.save();
      // Walls are relative to top-left of the building
      ctx.translate(-building.width / 2, -building.height / 2);
      ctx.strokeStyle = 'red';
      ctx.lineWidth = 2;

      building.walls.forEach(wall => {
        const wStartX = wall.x;
        const wStartY = wall.y;
        let wEndX = wStartX;
        let wEndY = wStartY;

        if (wall.endX !== undefined && wall.endY !== undefined) {
          wEndX = wall.endX;
          wEndY = wall.endY;
        } else if (wall.height !== undefined) {
          wEndY = wStartY + wall.height;
        } else {
          wEndX = wStartX + (wall.length || wall.width || 0);
        }

        ctx.beginPath();
        ctx.moveTo(wStartX, wStartY);
        ctx.lineTo(wEndX, wEndY);
        ctx.stroke();
      });

      ctx.restore();
    }

    ctx.restore();
  });
  const collisionObjects = window.collisionObjects || [];
  collisionObjects.forEach(obj => {
    ctx.save();
    ctx.translate(obj.x, obj.y);
    if (obj.rotation) {
      ctx.rotate(obj.rotation * Math.PI / 180);
    }

    if (window.adminSelectedObject && window.adminSelectedObject.id === obj.id) {
      ctx.fillStyle = 'purple';
    } else {
      ctx.fillStyle = 'rgba(155, 89, 182, 0.5)';
    }

    ctx.beginPath();
    if (obj.shape === 'circle') {
      const radius = Math.max(obj.width, obj.length) / 2;
      ctx.arc(0, 0, radius, 0, Math.PI * 2);
    } else {
      ctx.rect(-obj.width / 2, -obj.length / 2, obj.width, obj.length);
    }
    ctx.fill();
    ctx.restore();
  });

  ctx.restore();
};


window.addEventListener('load', function () {
  if (window.gameLoop) {
    requestAnimationFrame(window.gameLoop);
  }
});
