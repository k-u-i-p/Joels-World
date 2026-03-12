window.isAdmin = true;

console.log('Setting up admin');

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');
const getBuildings = () => window.buildings;
const getCollisionObjects = () => window.collisionObjects;

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

let draggedBuilding = null;
let selectedBuilding = null;
let draggedCollisionObject = null;
let selectedCollisionObject = null;
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
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'delete_building', id: selectedBuilding.id }));
    selectedBuilding = null;
    draggedBuilding = null;
    window.adminSelectedBuilding = null;
    updateAdminPanel();
  }
};

document.getElementById('btn-delete-col').onclick = () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'delete_collision_object', id: selectedCollisionObject.id }));
    selectedCollisionObject = null;
    draggedCollisionObject = null;
    window.adminSelectedCollisionObject = null;
    updateAdminPanel();
  }
};

const nameInput = document.getElementById('building-name-input');
nameInput.onchange = (e) => {
  if (!selectedBuilding) return;
  selectedBuilding.name = e.target.value.trim();
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rename_building', id: selectedBuilding.id, name: selectedBuilding.name }));
  }
};

bindHoldAction('btn-rot-left', () => {
  if (!selectedBuilding) return;
  selectedBuilding.rotation = Math.max(0, (selectedBuilding.rotation || 0) - 1);
}, () => {
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
  }
});

bindHoldAction('btn-rot-right', () => {
  if (!selectedBuilding) return;
  selectedBuilding.rotation = ((selectedBuilding.rotation || 0) + 1) % 360;
}, () => {
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
  }
});

bindHoldAction('btn-width-dec', () => {
  if (!selectedBuilding) return;
  let change = Math.max(1, Math.round(selectedBuilding.width * 0.02));
  selectedBuilding.width = Math.max(10, selectedBuilding.width - change);
}, () => {
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
  }
});

bindHoldAction('btn-width-inc', () => {
  if (!selectedBuilding) return;
  let change = Math.max(1, Math.round(selectedBuilding.width * 0.02));
  selectedBuilding.width += change;
}, () => {
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
  }
});

bindHoldAction('btn-height-dec', () => {
  if (!selectedBuilding) return;
  let change = Math.max(1, Math.round(selectedBuilding.height * 0.02));
  selectedBuilding.height = Math.max(10, selectedBuilding.height - change);
}, () => {
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
  }
});

bindHoldAction('btn-height-inc', () => {
  if (!selectedBuilding) return;
  let change = Math.max(1, Math.round(selectedBuilding.height * 0.02));
  selectedBuilding.height += change;
}, () => {
  if (selectedBuilding && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
  }
});

bindHoldAction('btn-col-rot-left', () => {
  if (!selectedCollisionObject) return;
  selectedCollisionObject.rotation = Math.max(0, (selectedCollisionObject.rotation || 0) - 1);
}, () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_collision_object', id: selectedCollisionObject.id, rotation: selectedCollisionObject.rotation }));
  }
});

bindHoldAction('btn-col-rot-right', () => {
  if (!selectedCollisionObject) return;
  selectedCollisionObject.rotation = ((selectedCollisionObject.rotation || 0) + 1) % 360;
}, () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'rotate_collision_object', id: selectedCollisionObject.id, rotation: selectedCollisionObject.rotation }));
  }
});

bindHoldAction('btn-col-width-dec', () => {
  if (!selectedCollisionObject) return;
  let change = Math.max(1, Math.round(selectedCollisionObject.width * 0.02));
  selectedCollisionObject.width = Math.max(5, selectedCollisionObject.width - change);
}, () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
  }
});

bindHoldAction('btn-col-width-inc', () => {
  if (!selectedCollisionObject) return;
  let change = Math.max(1, Math.round(selectedCollisionObject.width * 0.02));
  selectedCollisionObject.width += change;
}, () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
  }
});

bindHoldAction('btn-col-length-dec', () => {
  if (!selectedCollisionObject) return;
  let change = Math.max(1, Math.round(selectedCollisionObject.length * 0.02));
  selectedCollisionObject.length = Math.max(5, selectedCollisionObject.length - change);
}, () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
  }
});

bindHoldAction('btn-col-length-inc', () => {
  if (!selectedCollisionObject) return;
  let change = Math.max(1, Math.round(selectedCollisionObject.length * 0.02));
  selectedCollisionObject.length += change;
}, () => {
  if (selectedCollisionObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
  }
});

function updateAdminPanel() {
  adminPanel.style.display = 'block';

  const editSection = document.getElementById('edit-building-section');
  const editColObjSection = document.getElementById('edit-col-obj-section');

  if (selectedBuilding) {
    editSection.style.display = 'block';
    editColObjSection.style.display = 'none';

    const nameInput = document.getElementById('building-name-input');
    nameInput.value = selectedBuilding.name || selectedBuilding.id;
  } else if (selectedCollisionObject) {
    editSection.style.display = 'none';
    editColObjSection.style.display = 'block';
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

  selectedBuilding = null;
  window.adminSelectedBuilding = null;
  selectedCollisionObject = null;
  window.adminSelectedCollisionObject = null;

  const buildings = getBuildings();
  const collisionObjects = getCollisionObjects() || [];

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
      draggedCollisionObject = obj;
      selectedCollisionObject = obj;
      window.adminSelectedCollisionObject = obj;
      dragOffsetX = obj.x - worldX;
      dragOffsetY = obj.y - worldY;
      break;
    }
  }

  if (!draggedCollisionObject) {
    for (let i = buildings.length - 1; i >= 0; i--) {
      const building = buildings[i];
      if (isPointInBuilding(worldX, worldY, building)) {
        console.log(`Dragging building: ${building.id}`);
        draggedBuilding = building;
        selectedBuilding = building;
        window.adminSelectedBuilding = building;
        dragOffsetX = building.x - worldX;
        dragOffsetY = building.y - worldY;
        break;
      }
    }
  }

  if (!draggedCollisionObject && !draggedBuilding && !e.target.closest('#admin-panel')) {
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
  if (draggedBuilding) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    draggedBuilding.x = Math.round(worldX + dragOffsetX);
    draggedBuilding.y = Math.round(worldY + dragOffsetY);
  } else if (draggedCollisionObject) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    draggedCollisionObject.x = Math.round(worldX + dragOffsetX);
    draggedCollisionObject.y = Math.round(worldY + dragOffsetY);
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
  if (draggedBuilding) {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({
        type: 'move_building',
        id: draggedBuilding.id,
        x: draggedBuilding.x,
        y: draggedBuilding.y
      }));
    }
    draggedBuilding = null;
  }
  if (draggedCollisionObject) {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({
        type: 'move_collision_object',
        id: draggedCollisionObject.id,
        x: draggedCollisionObject.x,
        y: draggedCollisionObject.y
      }));
    }
    draggedCollisionObject = null;
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

  const buildings = getBuildings();
  buildings.forEach(building => {
    ctx.save();
    ctx.translate(building.x, building.y);
    ctx.rotate((building.rotation || 0) * Math.PI / 180);
    if (window.adminSelectedBuilding && window.adminSelectedBuilding.id === building.id) {
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

  const collisionObjects = getCollisionObjects() || [];
  collisionObjects.forEach(obj => {
    ctx.save();
    ctx.translate(obj.x, obj.y);
    if (obj.rotation) {
      ctx.rotate(obj.rotation * Math.PI / 180);
    }
    
    if (window.adminSelectedCollisionObject && window.adminSelectedCollisionObject.id === obj.id) {
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
