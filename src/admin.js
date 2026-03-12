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

let dragOffsetX = 0;
let dragOffsetY = 0;

let isDraggingBackground = false;
let isDraggingAdminImage = false;
let bgDragOffsetX = 0;
let bgDragOffsetY = 0;
let lastMouseX = 0;
let lastMouseY = 0;

document.getElementById('btn-create-obj-building').onclick = () => {
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_object', name: 'New Building', shape: 'rect', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
  }
};

document.getElementById('btn-create-obj-rect').onclick = () => {
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_object', shape: 'rect', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
  }
};

document.getElementById('btn-create-obj-circle').onclick = () => {
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_object', shape: 'circle', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
  }
};

document.getElementById('btn-delete-obj').onclick = () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'delete_object', id: selectedObject.id }));
    selectedObject = null;
    draggedObject = null;
    window.adminSelectedObject = null;
    updateAdminPanel();
  }
};

const nameInput = document.getElementById('obj-name-input');
if (nameInput) {
  nameInput.onchange = (e) => {
    if (!selectedObject) return;
    selectedObject.name = e.target.value.trim();
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'rename_object', id: selectedObject.id, name: selectedObject.name }));
    }
  };
}

bindHoldAction('btn-obj-rot-left', () => {
  if (!selectedObject) return;
  selectedObject.rotation = Math.max(0, (selectedObject.rotation || 0) - 1);
}, () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'rotate_object', id: selectedObject.id, rotation: selectedObject.rotation }));
});

bindHoldAction('btn-obj-rot-right', () => {
  if (!selectedObject) return;
  selectedObject.rotation = ((selectedObject.rotation || 0) + 1) % 360;
}, () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'rotate_object', id: selectedObject.id, rotation: selectedObject.rotation }));
});

bindHoldAction('btn-obj-width-dec', () => {
  if (!selectedObject) return;
  let change = Math.max(1, Math.round(selectedObject.width * 0.02));
  selectedObject.width = Math.max(5, selectedObject.width - change);
}, () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: selectedObject.id, width: selectedObject.width, length: selectedObject.length }));
});

bindHoldAction('btn-obj-width-inc', () => {
  if (!selectedObject) return;
  let change = Math.max(1, Math.round(selectedObject.width * 0.02));
  selectedObject.width += change;
}, () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: selectedObject.id, width: selectedObject.width, length: selectedObject.length }));
});

bindHoldAction('btn-obj-length-dec', () => {
  if (!selectedObject) return;
  let change = Math.max(1, Math.round(selectedObject.length * 0.02));
  selectedObject.length = Math.max(5, selectedObject.length - change);
}, () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: selectedObject.id, width: selectedObject.width, length: selectedObject.length }));
});

bindHoldAction('btn-obj-length-inc', () => {
  if (!selectedObject) return;
  let change = Math.max(1, Math.round(selectedObject.length * 0.02));
  selectedObject.length += change;
}, () => {
  if (selectedObject && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: selectedObject.id, width: selectedObject.width, length: selectedObject.length }));
});

const objNoclipCheckbox = document.getElementById('checkbox-obj-noclip');
if (objNoclipCheckbox) {
  objNoclipCheckbox.addEventListener('change', (e) => {
    if (!selectedObject) return;
    selectedObject.noclip = e.target.checked;
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'toggle_object_noclip', id: selectedObject.id, noclip: selectedObject.noclip }));
    }
  });
}

function updateAdminPanel() {
  adminPanel.style.display = 'block';

  const editObjSection = document.getElementById('edit-obj-section');

  if (selectedObject) {
    editObjSection.style.display = 'block';

    if (nameInput) {
      nameInput.value = selectedObject.name || '';
    }
    
    if (objNoclipCheckbox) {
      objNoclipCheckbox.checked = !!selectedObject.noclip;
    }
  } else {
    editObjSection.style.display = 'none';
  }
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
  const objects = window.objects || [];

  for (let i = objects.length - 1; i >= 0; i--) {
    const obj = objects[i];
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
      console.log(`Dragging object: ${obj.id}`);
      draggedObject = obj;
      selectedObject = obj;
      window.adminSelectedObject = obj;
      dragOffsetX = obj.x - worldX;
      dragOffsetY = obj.y - worldY;
      break;
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

    draggedObject.x = Math.round(worldX + dragOffsetX);
    draggedObject.y = Math.round(worldY + dragOffsetY);
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
      window.ws.send(JSON.stringify({
        type: 'move_object',
        id: draggedObject.id,
        x: draggedObject.x,
        y: draggedObject.y
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

  const objects = window.objects || [];
  objects.forEach(obj => {
    ctx.save();
    ctx.translate(obj.x, obj.y);
    if (obj.rotation) {
      ctx.rotate(obj.rotation * Math.PI / 180);
    }

    if (window.adminSelectedObject && window.adminSelectedObject.id === obj.id) {
      ctx.fillStyle = 'purple';
    } else {
      ctx.fillStyle = obj.name ? 'rgba(255, 0, 0, 0.5)' : 'rgba(155, 89, 182, 0.5)';
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
