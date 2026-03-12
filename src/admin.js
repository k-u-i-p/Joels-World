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
  },
  checkResizeHandleHit: function(worldX, worldY) {
    const obj = this.get();
    if (!obj) return false;
    
    const bdx = worldX - obj.x;
    const bdy = worldY - obj.y;
    const angle = -(obj.rotation || 0) * Math.PI / 180;
    const localX = bdx * Math.cos(angle) - bdy * Math.sin(angle);
    const localY = bdx * Math.sin(angle) + bdy * Math.cos(angle);
    
    let handleX = 0, handleY = 0;
    if (obj.shape === 'circle') {
      const radius = Math.max(obj.width, obj.length) / 2;
      handleX = radius * 0.707;
      handleY = radius * 0.707;
    } else {
      handleX = obj.width / 2;
      handleY = obj.length / 2;
    }
    
    return Math.hypot(localX - handleX, localY - handleY) <= 15 / (window.cameraZoom || 1);
  }
};

window.selectedNpc = {
  _id: null,
  set: function (id) {
    this._id = id;
  },
  get: function () {
    return (window.init?.npcs || []).find(n => n.id === this._id);
  },
  findNpcAtXY: function(worldX, worldY) {
    const npcs = window.init?.npcs || [];
    for (let i = npcs.length - 1; i >= 0; i--) {
      const npc = npcs[i];
      const radius = Math.max(npc.width, npc.height) / 2 || 20;
      if (Math.hypot(worldX - npc.x, worldY - npc.y) <= radius) return npc;
    }
    return null;
  }
};

let dragOffsetX = 0;
let dragOffsetY = 0;

let isDraggingBackground = false;
let isDraggingAdminImage = false;
let isDraggingObject = false;
let isResizingObject = false;
let isDraggingNpc = false;
let isDraggingAdminPanel = false;
let adminPanelOffsetX = 0;
let adminPanelOffsetY = 0;
let bgDragOffsetX = 0;
let bgDragOffsetY = 0;
let lastMouseX = 0;
let lastMouseY = 0;
let resizeWorldTlx = 0;
let resizeWorldTly = 0;

function getObjectTopLeftAnchor(obj) {
  const angle = (obj.rotation || 0) * Math.PI / 180;
  return {
    tlx: obj.x + (-obj.width / 2) * Math.cos(angle) - (-obj.length / 2) * Math.sin(angle),
    tly: obj.y + (-obj.width / 2) * Math.sin(angle) + (-obj.length / 2) * Math.cos(angle)
  };
}

function applyResizeWithTopLeftAnchor(obj, newWidth, newLength, tlx, tly) {
  obj.width = newWidth;
  obj.length = newLength;
  const angle = (obj.rotation || 0) * Math.PI / 180;
  obj.x = Math.round(tlx - ((-newWidth / 2) * Math.cos(angle) - (-newLength / 2) * Math.sin(angle)));
  obj.y = Math.round(tly - ((-newWidth / 2) * Math.sin(angle) + (-newLength / 2) * Math.cos(angle)));
}

const adminPanelHandle = document.getElementById('admin-panel-handle');
if (adminPanelHandle) {
  adminPanelHandle.addEventListener('mousedown', (e) => {
    isDraggingAdminPanel = true;
    const rect = adminPanel.getBoundingClientRect();
    adminPanelOffsetX = e.clientX - rect.left;
    adminPanelOffsetY = e.clientY - rect.top;
    
    adminPanel.style.right = 'auto'; // Disable flex/right alignment
    adminPanel.style.left = `${rect.left}px`;
    adminPanel.style.top = `${rect.top}px`;
  });
}

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

document.getElementById('btn-create-npc').onclick = () => {
  if (window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'create_npc', x: Math.round(window.player.x), y: Math.round(window.player.y) }));
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

document.getElementById('btn-delete-npc').onclick = () => {
  const selected = window.selectedNpc.get();
  if (selected && window.ws.readyState === WebSocket.OPEN) {
    const identifier = selected.name || selected.id;
    if (window.confirm(`Are you sure you want to delete ${identifier}?`)) {
      window.ws.send(JSON.stringify({ type: 'delete_npc', id: selected.id }));
      window.selectedNpc.set(null);

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
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.width * 0.02));
  applyResizeWithTopLeftAnchor(obj, Math.max(5, obj.width - change), obj.length, anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y }));
});

bindHoldAction('btn-obj-width-inc', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.width * 0.02));
  applyResizeWithTopLeftAnchor(obj, obj.width + change, obj.length, anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y }));
});

bindHoldAction('btn-obj-length-dec', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.length * 0.02));
  applyResizeWithTopLeftAnchor(obj, obj.width, Math.max(5, obj.length - change), anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y }));
});

bindHoldAction('btn-obj-length-inc', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.length * 0.02));
  applyResizeWithTopLeftAnchor(obj, obj.width, obj.length + change, anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj && window.ws.readyState === WebSocket.OPEN) window.ws.send(JSON.stringify({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y }));
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

const npcNameInput = document.getElementById('npc-name-input');
if (npcNameInput) {
  npcNameInput.onchange = (e) => {
    if (!window.selectedNpc.get()) return;
    window.selectedNpc.get().name = e.target.value.trim();
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { name: window.selectedNpc.get().name } }));
    }
  };
}

['shirtColor', 'pantsColor', 'armColor'].forEach(part => {
  const colInput = document.getElementById(`npc-${part === 'shirtColor' ? 'shirt' : part === 'pantsColor' ? 'pants' : 'arm'}-col`);
  if (colInput) {
    colInput.onchange = (e) => {
      if (!window.selectedNpc.get()) return;
      window.selectedNpc.get()[part] = e.target.value;
      if (window.ws.readyState === WebSocket.OPEN) {
        window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { [part]: e.target.value } }));
      }
    };
  }
});

bindHoldAction('btn-npc-rot-left', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().rotation = Math.max(0, (window.selectedNpc.get().rotation || 0) - 5);
}, () => {
  if (window.selectedNpc.get() && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { rotation: window.selectedNpc.get().rotation } }));
  }
});

bindHoldAction('btn-npc-rot-right', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().rotation = ((window.selectedNpc.get().rotation || 0) + 5) % 360;
}, () => {
  if (window.selectedNpc.get() && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { rotation: window.selectedNpc.get().rotation } }));
  }
});

bindHoldAction('btn-npc-width-dec', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().width = Math.max(5, (window.selectedNpc.get().width || 40) - 2);
}, () => {
  if (window.selectedNpc.get() && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { width: window.selectedNpc.get().width } }));
  }
});

bindHoldAction('btn-npc-width-inc', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().width = (window.selectedNpc.get().width || 40) + 2;
}, () => {
  if (window.selectedNpc.get() && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { width: window.selectedNpc.get().width } }));
  }
});

bindHoldAction('btn-npc-height-dec', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().height = Math.max(5, (window.selectedNpc.get().height || 40) - 2);
}, () => {
  if (window.selectedNpc.get() && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { height: window.selectedNpc.get().height } }));
  }
});

bindHoldAction('btn-npc-height-inc', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().height = (window.selectedNpc.get().height || 40) + 2;
}, () => {
  if (window.selectedNpc.get() && window.ws.readyState === WebSocket.OPEN) {
    window.ws.send(JSON.stringify({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { height: window.selectedNpc.get().height } }));
  }
});

const btnSaveNpcDialog = document.getElementById('btn-save-npc-dialog');
const npcOnEnterInput = document.getElementById('npc-on-enter-input');
const npcOnExitInput = document.getElementById('npc-on-exit-input');
if (btnSaveNpcDialog && npcOnEnterInput && npcOnExitInput) {
  btnSaveNpcDialog.onclick = () => {
    if (!window.selectedNpc.get()) return;
    
    const onEnterLines = npcOnEnterInput.value.split('\n').map(l => l.trim()).filter(l => l.length > 0);
    const onExitLines = npcOnExitInput.value.split('\n').map(l => l.trim()).filter(l => l.length > 0);

    const on_enter = onEnterLines.length > 0 ? [{ say: onEnterLines }] : [];
    const on_exit = onExitLines.length > 0 ? [{ say: onExitLines }] : [];

    window.selectedNpc.get().on_enter = on_enter;
    window.selectedNpc.get().on_exit = on_exit;

    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({ 
        type: 'update_npc', 
        id: window.selectedNpc.get().id, 
        updates: { on_enter, on_exit } 
      }));
    }
    alert('NPC dialog saved!');
  };
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

  const editNpcSection = document.getElementById('edit-npc-section');
  if (window.selectedNpc.get()) {
    if (editNpcSection) editNpcSection.style.display = 'block';
    const npc = window.selectedNpc.get();
    
    if (npcNameInput) npcNameInput.value = npc.name || '';
    
    if (document.getElementById('npc-shirt-col')) document.getElementById('npc-shirt-col').value = npc.shirtColor || '#3498db';
    if (document.getElementById('npc-pants-col')) document.getElementById('npc-pants-col').value = npc.pantsColor || '#2c3e50';
    if (document.getElementById('npc-arm-col')) document.getElementById('npc-arm-col').value = npc.armColor || '#3498db';
    
    const npcOnEnterInput = document.getElementById('npc-on-enter-input');
    const npcOnExitInput = document.getElementById('npc-on-exit-input');
    
    if (npcOnEnterInput) {
      if (npc.on_enter && npc.on_enter[0] && npc.on_enter[0].say) {
        npcOnEnterInput.value = npc.on_enter[0].say.join('\n');
      } else {
        npcOnEnterInput.value = '';
      }
    }
    
    if (npcOnExitInput) {
      if (npc.on_exit && npc.on_exit[0] && npc.on_exit[0].say) {
        npcOnExitInput.value = npc.on_exit[0].say.join('\n');
      } else {
        npcOnExitInput.value = '';
      }
    }
  } else {
    if (editNpcSection) editNpcSection.style.display = 'none';
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

  if (window.selectedObject.get() && window.selectedObject.checkResizeHandleHit(worldX, worldY)) {
    isResizingObject = true;
    const anchor = getObjectTopLeftAnchor(window.selectedObject.get());
    resizeWorldTlx = anchor.tlx;
    resizeWorldTly = anchor.tly;
    return;
  }

  window.selectedObject.set(null);
  window.selectedNpc.set(null);

  const hitNpc = window.selectedNpc.findNpcAtXY(worldX, worldY);
  if (hitNpc) {
    console.log(`Dragging npc: ${hitNpc.id}`);
    window.selectedNpc.set(hitNpc.id);
    isDraggingNpc = true;
    
    dragOffsetX = hitNpc.x - worldX;
    dragOffsetY = hitNpc.y - worldY;
  } else {
    const hitObj = window.selectedObject.findObjectAtXY(worldX, worldY);
    if (hitObj) {
      console.log(`Dragging object: ${hitObj.id}`);
      window.selectedObject.set(hitObj.id);
      isDraggingObject = true;
      
      dragOffsetX = hitObj.x - worldX;
      dragOffsetY = hitObj.y - worldY;
    }
  }

  if (!window.selectedObject.get() && !window.selectedNpc.get() && !e.target.closest('#admin-panel')) {
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
  if (isDraggingAdminPanel) {
    adminPanel.style.left = `${e.clientX - adminPanelOffsetX}px`;
    adminPanel.style.top = `${e.clientY - adminPanelOffsetY}px`;
    return;
  }

  if (isResizingObject && window.selectedObject.get()) {
    const obj = window.selectedObject.get();
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    const dX = worldX - resizeWorldTlx;
    const dY = worldY - resizeWorldTly;
    const angle = -(obj.rotation || 0) * Math.PI / 180;
    
    const localMouseXFromTl = dX * Math.cos(angle) - dY * Math.sin(angle);
    const localMouseYFromTl = dX * Math.sin(angle) + dY * Math.cos(angle);

    let newWidth, newLength;
    if (obj.shape === 'circle') {
      const size = Math.max(10, Math.round(Math.max(localMouseXFromTl, localMouseYFromTl)));
      newWidth = size;
      newLength = size;
    } else {
      newWidth = Math.max(10, Math.round(localMouseXFromTl));
      newLength = Math.max(10, Math.round(localMouseYFromTl));
    }

    applyResizeWithTopLeftAnchor(obj, newWidth, newLength, resizeWorldTlx, resizeWorldTly);
  } else if (isDraggingObject && window.selectedObject.get()) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    window.selectedObject.get().x = Math.round(worldX + dragOffsetX);
    window.selectedObject.get().y = Math.round(worldY + dragOffsetY);
  } else if (isDraggingNpc && window.selectedNpc.get()) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? window.player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? window.player.y);

    window.selectedNpc.get().x = Math.round(worldX + dragOffsetX);
    window.selectedNpc.get().y = Math.round(worldY + dragOffsetY);
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
  if (isResizingObject && window.selectedObject.get()) {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({
        type: 'resize_object',
        id: window.selectedObject.get().id,
        width: window.selectedObject.get().width,
        length: window.selectedObject.get().length,
        x: window.selectedObject.get().x,
        y: window.selectedObject.get().y
      }));
    }
  } else if (isDraggingObject && window.selectedObject.get()) {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({
        type: 'move_object',
        id: window.selectedObject.get().id,
        x: window.selectedObject.get().x,
        y: window.selectedObject.get().y
      }));
    }
  } else if (isDraggingNpc && window.selectedNpc.get()) {
    if (window.ws.readyState === WebSocket.OPEN) {
      window.ws.send(JSON.stringify({
        type: 'move_npc',
        id: window.selectedNpc.get().id,
        x: window.selectedNpc.get().x,
        y: window.selectedNpc.get().y
      }));
    }
  }
  isDraggingObject = false;
  isResizingObject = false;
  isDraggingNpc = false;
  isDraggingBackground = false;
  isDraggingAdminImage = false;
  isDraggingAdminPanel = false;
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

    if (window.selectedObject.get() && window.selectedObject.get().id === obj.id) {
      let handleX = 0, handleY = 0;
      if (obj.shape === 'circle') {
        const radius = Math.max(obj.width, obj.length) / 2;
        handleX = radius * 0.707;
        handleY = radius * 0.707;
      } else {
        handleX = obj.width / 2;
        handleY = obj.length / 2;
      }

      ctx.fillStyle = 'white';
      ctx.strokeStyle = 'black';
      ctx.lineWidth = 2 / window.cameraZoom;
      ctx.beginPath();
      const s = 10 / window.cameraZoom;
      ctx.rect(handleX - s/2, handleY - s/2, s, s);
      ctx.fill();
      ctx.stroke();
    }

    ctx.restore();
  });

  const npcs = window.init?.npcs || [];
  npcs.forEach(npc => {
    if (window.selectedNpc.get() && window.selectedNpc.get().id === npc.id) {
      ctx.save();
      ctx.translate(npc.x, npc.y);
      ctx.beginPath();
      ctx.arc(0, 0, (Math.max(npc.width, npc.height) / 2 || 20) + 5, 0, Math.PI * 2);
      ctx.lineWidth = 3;
      ctx.strokeStyle = 'cyan';
      ctx.stroke();
      ctx.restore();
    }
  });

  ctx.restore();
};


window.addEventListener('load', function () {
  if (window.gameLoop) {
    requestAnimationFrame(window.gameLoop);
  }
});
