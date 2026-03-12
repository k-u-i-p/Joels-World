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
    if (window.init?.mapData?.id === mapData.id) {
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
    e.target.blur();
    window.selectedObject.set(null);
    updateAdminPanel();
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

window.selectedObject = {
  _id: null,
  set: function (id) {
    this._id = id;
  },
  get: function () {
    return (window.init?.objects || []).find(o => o.id === this._id);
  },
  findObjectAtXY: function(worldX, worldY) {
    const objects = window.init?.objects || [];
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
      if (hit) return obj;
    }
    return null;
  }
};


let dragOffsetX = 0;
let dragOffsetY = 0;

let isDraggingBackground = false;
let isDraggingAdminImage = false;
let isDraggingObject = false;
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
  const selected = window.selectedObject.get();
  if (selected && window.ws.readyState === WebSocket.OPEN) {
    const identifier = selected.name || selected.id;
    if (window.confirm(`Are you sure you want to delete ${identifier}?`)) {
      window.ws.send(JSON.stringify({ type: 'delete_object', id: selected.id }));
      window.selectedObject.set(null);

      updateAdminPanel();
    }
  }
};

const nameInput = document.getElementById('obj-name-input');
if (nameInput) {
  nameInput.onchange = (e) => {
    if (!window.selectedObject.get()) return;
    window.selectedObject.get().name = e.target.value.trim();
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'rename_object', id: window.selectedObject.get().id, name: window.selectedObject.get().name }));
    }
  };
}

bindHoldAction('btn-obj-rot-left', () => {
  if (!window.selectedObject.get()) return;
  window.selectedObject.get().rotation = Math.max(0, (window.selectedObject.get().rotation || 0) - 1);
}, () => {
  if (window.selectedObject.get() && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'rotate_object', id: window.selectedObject.get().id, rotation: window.selectedObject.get().rotation }));
});

bindHoldAction('btn-obj-rot-right', () => {
  if (!window.selectedObject.get()) return;
  window.selectedObject.get().rotation = ((window.selectedObject.get().rotation || 0) + 1) % 360;
}, () => {
  if (window.selectedObject.get() && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'rotate_object', id: window.selectedObject.get().id, rotation: window.selectedObject.get().rotation }));
});

bindHoldAction('btn-obj-width-dec', () => {
  if (!window.selectedObject.get()) return;
  let change = Math.max(1, Math.round(window.selectedObject.get().width * 0.02));
  window.selectedObject.get().width = Math.max(5, window.selectedObject.get().width - change);
}, () => {
  if (window.selectedObject.get() && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: window.selectedObject.get().id, width: window.selectedObject.get().width, length: window.selectedObject.get().length }));
});

bindHoldAction('btn-obj-width-inc', () => {
  if (!window.selectedObject.get()) return;
  let change = Math.max(1, Math.round(window.selectedObject.get().width * 0.02));
  window.selectedObject.get().width += change;
}, () => {
  if (window.selectedObject.get() && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: window.selectedObject.get().id, width: window.selectedObject.get().width, length: window.selectedObject.get().length }));
});

bindHoldAction('btn-obj-length-dec', () => {
  if (!window.selectedObject.get()) return;
  let change = Math.max(1, Math.round(window.selectedObject.get().length * 0.02));
  window.selectedObject.get().length = Math.max(5, window.selectedObject.get().length - change);
}, () => {
  if (window.selectedObject.get() && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: window.selectedObject.get().id, width: window.selectedObject.get().width, length: window.selectedObject.get().length }));
});

bindHoldAction('btn-obj-length-inc', () => {
  if (!window.selectedObject.get()) return;
  let change = Math.max(1, Math.round(window.selectedObject.get().length * 0.02));
  window.selectedObject.get().length += change;
}, () => {
  if (window.selectedObject.get() && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: window.selectedObject.get().id, width: window.selectedObject.get().width, length: window.selectedObject.get().length }));
});

const objNoclipCheckbox = document.getElementById('checkbox-obj-noclip');
if (objNoclipCheckbox) {
  objNoclipCheckbox.addEventListener('change', (e) => {
    if (!window.selectedObject.get()) return;
    window.selectedObject.get().noclip = e.target.checked;
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'toggle_object_noclip', id: window.selectedObject.get().id, noclip: window.selectedObject.get().noclip }));
    }
  });
}

function updateAdminPanel() {
  adminPanel.style.display = 'block';

  const editObjSection = document.getElementById('edit-obj-section');

  if (window.selectedObject.get()) {
    editObjSection.style.display = 'block';

    if (nameInput) {
      nameInput.value = window.selectedObject.get().name || '';
    }

    if (objNoclipCheckbox) {
      objNoclipCheckbox.checked = !!window.selectedObject.get().noclip;
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

  const lastClickedElem = document.getElementById('admin-last-clicked');
  if (lastClickedElem) {
    lastClickedElem.textContent = `Last Click: x: ${Math.round(worldX)}, y: ${Math.round(worldY)}`;
  }

  window.selectedObject.set(null);

  const hitObj = window.selectedObject.findObjectAtXY(worldX, worldY);
  if (hitObj) {
    console.log(`Dragging object: ${hitObj.id}`);
    window.selectedObject.set(hitObj.id);
    isDraggingObject = true;
    
    dragOffsetX = hitObj.x - worldX;
    dragOffsetY = hitObj.y - worldY;
  }

  if (!window.selectedObject.get() && !e.target.closest('#admin-panel')) {
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
  if (isDraggingObject && window.selectedObject.get()) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    window.selectedObject.get().x = Math.round(worldX + dragOffsetX);
    window.selectedObject.get().y = Math.round(worldY + dragOffsetY);
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
  if (isDraggingObject && window.selectedObject.get()) {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({
        type: 'move_object',
        id: window.selectedObject.get().id,
        x: window.selectedObject.get().x,
        y: window.selectedObject.get().y
      }));
    }
  }
  isDraggingObject = false;
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

  const objects = window.init?.objects || [];
  objects.forEach(obj => {
    ctx.save();
    ctx.translate(obj.x, obj.y);
    if (obj.rotation) {
      ctx.rotate(obj.rotation * Math.PI / 180);
    }

    if (window.selectedObject.get() && window.selectedObject.get().id === obj.id) {
      ctx.fillStyle = 'purple';
    } else if (obj.noclip) {
      ctx.fillStyle = 'rgba(0, 255, 0, 0.5)';
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
