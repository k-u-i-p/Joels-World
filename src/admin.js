import { gameLoop } from './gameloop.js';
import { player, camera } from './main.js';
import { networkClient } from './network.js';

networkClient.isAdmin = true;

console.log('Setting up admin');

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

const adminPanel = document.getElementById('admin-panel');
const adminFps = document.getElementById('admin-fps');

window.updateAdminFps = (fps) => {
  if (adminFps) {
    adminFps.textContent = `FPS: ${fps}`;
  }
};

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
    networkClient.send({ type: 'change_map', mapId: e.target.value });
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
  findObjectAtXY: function (worldX, worldY) {
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
  checkResizeHandleHit: function (worldX, worldY) {
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

    return Math.hypot(localX - handleX, localY - handleY) <= 15 / (camera.zoom || 1);
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
  findNpcAtXY: function (worldX, worldY) {
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

document.getElementById('btn-create-obj-rect').onclick = () => {
  networkClient.send({ type: 'create_object', shape: 'rect', x: Math.round(player.x), y: Math.round(player.y), width: 100, length: 100 });
};

document.getElementById('btn-create-obj-circle').onclick = () => {
  networkClient.send({ type: 'create_object', shape: 'circle', x: Math.round(player.x), y: Math.round(player.y), width: 100, length: 100 });
};

document.getElementById('btn-create-npc').onclick = () => {
  networkClient.send({ type: 'create_npc', x: Math.round(player.x), y: Math.round(player.y) });
};

document.getElementById('btn-delete-obj').onclick = () => {
  const selected = window.selectedObject.get();
  if (selected) {
    const identifier = selected.name || selected.id;
    if (window.confirm(`Are you sure you want to delete ${identifier}?`)) {
      networkClient.send({ type: 'delete_object', id: selected.id });
      window.selectedObject.set(null);

      updateAdminPanel();
    }
  }
};

document.getElementById('btn-delete-npc').onclick = () => {
  const selected = window.selectedNpc.get();
  if (selected) {
    const identifier = selected.name || selected.id;
    if (window.confirm(`Are you sure you want to delete ${identifier}?`)) {
      networkClient.send({ type: 'delete_npc', id: selected.id });
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
    networkClient.send({ type: 'rename_object', id: window.selectedObject.get().id, name: window.selectedObject.get().name });
  };
}

bindHoldAction('btn-obj-rot-left', () => {
  if (!window.selectedObject.get()) return;
  window.selectedObject.get().rotation = (window.selectedObject.get().rotation || 0) - 1;
}, () => {
  if (window.selectedObject.get()) networkClient.send({ type: 'rotate_object', id: window.selectedObject.get().id, rotation: window.selectedObject.get().rotation });
});

bindHoldAction('btn-obj-rot-right', () => {
  if (!window.selectedObject.get()) return;
  window.selectedObject.get().rotation = (window.selectedObject.get().rotation || 0) + 1;
}, () => {
  if (window.selectedObject.get()) networkClient.send({ type: 'rotate_object', id: window.selectedObject.get().id, rotation: window.selectedObject.get().rotation });
});

bindHoldAction('btn-obj-width-dec', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.width * 0.02));
  applyResizeWithTopLeftAnchor(obj, Math.max(5, obj.width - change), obj.length, anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj) networkClient.send({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y });
});

bindHoldAction('btn-obj-width-inc', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.width * 0.02));
  applyResizeWithTopLeftAnchor(obj, obj.width + change, obj.length, anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj) networkClient.send({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y });
});

bindHoldAction('btn-obj-length-dec', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.length * 0.02));
  applyResizeWithTopLeftAnchor(obj, obj.width, Math.max(5, obj.length - change), anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj) networkClient.send({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y });
});

bindHoldAction('btn-obj-length-inc', () => {
  const obj = window.selectedObject.get();
  if (!obj) return;
  const anchor = getObjectTopLeftAnchor(obj);
  let change = Math.max(1, Math.round(obj.length * 0.02));
  applyResizeWithTopLeftAnchor(obj, obj.width, obj.length + change, anchor.tlx, anchor.tly);
}, () => {
  const obj = window.selectedObject.get();
  if (obj) networkClient.send({ type: 'resize_object', id: obj.id, width: obj.width, length: obj.length, x: obj.x, y: obj.y });
});

const inputObjClip = document.getElementById('input-obj-clip');
if (inputObjClip) {
  inputObjClip.addEventListener('change', (e) => {
    if (!window.selectedObject.get()) return;
    const clipVal = parseInt(e.target.value, 10);
    window.selectedObject.get().clip = isNaN(clipVal) ? 10 : clipVal;
    networkClient.send({ type: 'update_object', id: window.selectedObject.get().id, updates: { clip: window.selectedObject.get().clip } });
  });
}

const npcNameInput = document.getElementById('npc-name-input');
if (npcNameInput) {
  npcNameInput.onchange = (e) => {
    if (!window.selectedNpc.get()) return;
    window.selectedNpc.get().name = e.target.value.trim();
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { name: window.selectedNpc.get().name } });
  };
}

const npcRadiusInput = document.getElementById('npc-radius-input');
if (npcRadiusInput) {
  npcRadiusInput.addEventListener('change', (e) => {
    if (!window.selectedNpc.get()) return;
    const radiusVal = parseInt(e.target.value, 10);
    window.selectedNpc.get().interaction_radius = isNaN(radiusVal) ? 150 : radiusVal;
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { interaction_radius: window.selectedNpc.get().interaction_radius } });
  });
}

const npcRoamRadiusInput = document.getElementById('npc-roam-radius-input');
if (npcRoamRadiusInput) {
  npcRoamRadiusInput.addEventListener('change', (e) => {
    if (!window.selectedNpc.get()) return;
    const radiusVal = parseInt(e.target.value, 10);
    if (isNaN(radiusVal) || radiusVal <= 0) {
      delete window.selectedNpc.get().roam_radius;
      networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { roam_radius: null } });
    } else {
      window.selectedNpc.get().roam_radius = radiusVal;
      networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { roam_radius: radiusVal } });
    }
  });
}

['shirtColor', 'pantsColor', 'armColor', 'hairColor'].forEach(part => {
  const colInput = document.getElementById(`npc-${part === 'shirtColor' ? 'shirt' : part === 'pantsColor' ? 'pants' : part === 'armColor' ? 'arm' : 'hair'}-col`);
  if (colInput) {
    colInput.onchange = (e) => {
      if (!window.selectedNpc.get()) return;
      window.selectedNpc.get()[part] = e.target.value;
      networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { [part]: e.target.value } });
    };
  }
});

const npcHairStyle = document.getElementById('npc-hair-style');
if (npcHairStyle) {
  npcHairStyle.onchange = (e) => {
    if (!window.selectedNpc.get()) return;
    window.selectedNpc.get().hairStyle = e.target.value;
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { hairStyle: e.target.value } });
  };
}

const npcDefaultEmote = document.getElementById('npc-default-emote');
if (npcDefaultEmote) {
  npcDefaultEmote.onchange = (e) => {
    if (!window.selectedNpc.get()) return;
    
    // Send either a constructed emote object or null explicitly
    let emoteObj = null;
    if (e.target.value !== '') {
      emoteObj = { name: e.target.value, startTime: Date.now() };
    }
    
    window.selectedNpc.get().default_emote = emoteObj;
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { default_emote: emoteObj } });
  };
}

const npcGenderSelect = document.getElementById('npc-gender-select');
if (npcGenderSelect) {
  npcGenderSelect.onchange = (e) => {
    if (!window.selectedNpc.get()) return;
    window.selectedNpc.get().gender = e.target.value;
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { gender: e.target.value } });
  };
}

bindHoldAction('btn-npc-rot-left', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().rotation = (window.selectedNpc.get().rotation || 0) - 5;
}, () => {
  if (window.selectedNpc.get()) {
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { rotation: window.selectedNpc.get().rotation } });
  }
});

bindHoldAction('btn-npc-rot-right', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().rotation = (window.selectedNpc.get().rotation || 0) + 5;
}, () => {
  if (window.selectedNpc.get()) {
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { rotation: window.selectedNpc.get().rotation } });
  }
});

bindHoldAction('btn-npc-width-dec', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().width = Math.max(5, (window.selectedNpc.get().width || 40) - 2);
}, () => {
  if (window.selectedNpc.get()) {
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { width: window.selectedNpc.get().width } });
  }
});

bindHoldAction('btn-npc-width-inc', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().width = (window.selectedNpc.get().width || 40) + 2;
}, () => {
  if (window.selectedNpc.get()) {
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { width: window.selectedNpc.get().width } });
  }
});

bindHoldAction('btn-npc-height-dec', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().height = Math.max(5, (window.selectedNpc.get().height || 40) - 2);
}, () => {
  if (window.selectedNpc.get()) {
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { height: window.selectedNpc.get().height } });
  }
});

bindHoldAction('btn-npc-height-inc', () => {
  if (!window.selectedNpc.get()) return;
  window.selectedNpc.get().height = (window.selectedNpc.get().height || 40) + 2;
}, () => {
  if (window.selectedNpc.get()) {
    networkClient.send({ type: 'update_npc', id: window.selectedNpc.get().id, updates: { height: window.selectedNpc.get().height } });
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

    const npc = window.selectedNpc.get();
    let on_enter = npc.on_enter ? [...npc.on_enter] : [];
    let on_exit = npc.on_exit ? [...npc.on_exit] : [];

    if (onEnterLines.length > 0) {
      if (on_enter.length > 0) {
        on_enter[0] = { ...on_enter[0], say: onEnterLines };
      } else {
        on_enter.push({ say: onEnterLines });
      }
    } else if (on_enter.length > 0) {
      delete on_enter[0].say;
    }

    if (onExitLines.length > 0) {
      if (on_exit.length > 0) {
        on_exit[0] = { ...on_exit[0], say: onExitLines };
      } else {
        on_exit.push({ say: onExitLines });
      }
    } else if (on_exit.length > 0) {
      delete on_exit[0].say;
    }

    npc.on_enter = on_enter;
    npc.on_exit = on_exit;

    networkClient.send({
      type: 'update_npc',
      id: npc.id,
      updates: { on_enter, on_exit }
    });
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

    const idDisplay = document.getElementById('obj-id-display');
    if (idDisplay) {
      idDisplay.textContent = `ID: ${window.selectedObject.get().id || '-'}`;
    }

    const clipInputDisplay = document.getElementById('input-obj-clip');
    if (clipInputDisplay) {
      clipInputDisplay.value = window.selectedObject.get().clip !== undefined ? window.selectedObject.get().clip : 10;
    }
  } else {
    editObjSection.style.display = 'none';
  }

  const editNpcSection = document.getElementById('edit-npc-section');
  if (window.selectedNpc.get()) {
    if (editNpcSection) editNpcSection.style.display = 'block';
    const npc = window.selectedNpc.get();

    const npcNameInput = document.getElementById('npc-name-input');
    const npcRadiusInput = document.getElementById('npc-radius-input');
    const npcRoamRadiusInput = document.getElementById('npc-roam-radius-input');
    const npcShirtCol = document.getElementById('npc-shirt-col');
    const npcPantsCol = document.getElementById('npc-pants-col');
    const npcArmCol = document.getElementById('npc-arm-col');
    const npcHairCol = document.getElementById('npc-hair-col');
    const npcHairStyle = document.getElementById('npc-hair-style');
    const npcDefaultEmote = document.getElementById('npc-default-emote');
    const npcGenderSelect = document.getElementById('npc-gender-select');

    if (npcNameInput) npcNameInput.value = npc.name || '';
    if (npcRadiusInput) npcRadiusInput.value = npc.interaction_radius !== undefined ? npc.interaction_radius : 150;
    if (npcRoamRadiusInput) npcRoamRadiusInput.value = npc.roam_radius !== undefined ? npc.roam_radius : '';
    if (npcShirtCol) npcShirtCol.value = npc.shirtColor || '#3498db';
    if (npcPantsCol) npcPantsCol.value = npc.pantsColor || '#2c3e50';
    if (npcArmCol) npcArmCol.value = npc.armColor || '#f1c40f';
    if (npcHairCol) npcHairCol.value = npc.hairColor || '#000000';
    if (npcHairStyle) npcHairStyle.value = npc.hairStyle || 'short';
    if (npcGenderSelect) npcGenderSelect.value = npc.gender || 'male';
    if (npcDefaultEmote) {
      npcDefaultEmote.value = npc.default_emote && npc.default_emote.name ? npc.default_emote.name : '';
    }

    if (npcDefaultEmote) {
      npcDefaultEmote.value = npc.default_emote && npc.default_emote.name ? npc.default_emote.name : '';
    }
  } else {
    if (editNpcSection) editNpcSection.style.display = 'none';
  }

  // --- Generic Event Editor Bootstrap ---
  const eventsSection = document.getElementById('admin-events-section');
  if (window.selectedObject.get() || window.selectedNpc.get()) {
    eventsSection.style.display = 'block';
    const activeEntity = window.selectedObject.get() || window.selectedNpc.get();
    
    // Deep clone the events avoiding memory references
    window.currentEditingEvents = {
      on_enter: JSON.parse(JSON.stringify(activeEntity.on_enter || [])),
      on_exit: JSON.parse(JSON.stringify(activeEntity.on_exit || []))
    };

    renderEventUI(window.currentEditingEvents.on_enter, 'events-on-enter-container', 'on_enter');
    renderEventUI(window.currentEditingEvents.on_exit, 'events-on-exit-container', 'on_exit');
  } else {
    eventsSection.style.display = 'none';
  }
}

// Global generic event state
window.currentEditingEvents = { on_enter: [], on_exit: [] };

function renderEventUI(eventsArray, containerId, eventType) {
  const container = document.getElementById(containerId);
  if (!container) return;
  
  container.innerHTML = '';
  
  if (!eventsArray || eventsArray.length === 0) {
    const emptyMsg = document.createElement('div');
    emptyMsg.style.color = '#7f8c8d';
    emptyMsg.style.fontSize = '12px';
    emptyMsg.style.fontStyle = 'italic';
    emptyMsg.style.marginBottom = '10px';
    emptyMsg.textContent = 'No actions defined.';
    container.appendChild(emptyMsg);
    return;
  }

  eventsArray.forEach((actionObj, index) => {
    // Determine the key (say, emote, play_sound, etc).
    // Older schema used objects directly, but some might have multiple keys? 
    // Usually it's one key per action object in this array schema.
    const typeKey = Object.keys(actionObj)[0];
    const payload = actionObj[typeKey];

    const card = document.createElement('div');
    card.style.background = 'rgba(0,0,0,0.3)';
    card.style.border = '1px solid #7f8c8d';
    card.style.borderRadius = '4px';
    card.style.padding = '5px';
    card.style.marginBottom = '8px';

    // Header row
    const headerRow = document.createElement('div');
    headerRow.className = 'admin-control-row';
    headerRow.style.marginBottom = '5px';

    const typeSelect = document.createElement('select');
    typeSelect.style.width = '100px';
    typeSelect.style.padding = '2px';
    typeSelect.style.fontSize = '12px';
    typeSelect.style.borderRadius = '4px';
    typeSelect.style.background = 'rgba(255,255,255,0.1)';
    typeSelect.style.color = 'white';
    typeSelect.style.border = '1px solid #7f8c8d';

    const options = ['say', 'emote', 'play_sound', 'log', 'show_dialog', 'avatar', 'clear_emote', 'player_emote'];
    options.forEach(opt => {
      const optionEl = document.createElement('option');
      optionEl.value = opt;
      optionEl.textContent = opt.charAt(0).toUpperCase() + opt.slice(1).replace('_', ' ');
      if (opt === typeKey) optionEl.selected = true;
      optionEl.style.color = 'black';
      typeSelect.appendChild(optionEl);
    });

    typeSelect.onchange = (e) => {
      const newType = e.target.value;
      let newPayload = '';
      if (newType === 'say') newPayload = [''];
      if (newType === 'play_sound') newPayload = { sound: '', volume: 1.0 };
      if (newType === 'show_dialog') newPayload = { description: '', type: 'change_map', map: 1 };
      if (newType === 'log') newPayload = { message: '', rate_limit: 0 };
      
      window.currentEditingEvents[eventType][index] = { [newType]: newPayload };
      renderEventUI(window.currentEditingEvents[eventType], containerId, eventType);
    };

    const deleteBtn = document.createElement('button');
    deleteBtn.className = 'admin-btn';
    deleteBtn.style.color = '#e74c3c';
    deleteBtn.textContent = 'X';
    deleteBtn.onclick = () => {
      window.currentEditingEvents[eventType].splice(index, 1);
      renderEventUI(window.currentEditingEvents[eventType], containerId, eventType);
    };

    headerRow.appendChild(typeSelect);
    headerRow.appendChild(deleteBtn);
    card.appendChild(headerRow);

    // Payload Editor area
    const payloadContainer = document.createElement('div');
    payloadContainer.style.marginTop = '5px';

    if (typeKey === 'say') {
      const textarea = document.createElement('textarea');
      textarea.className = 'admin-textarea';
      textarea.value = Array.isArray(payload) ? payload.join('\n') : payload;
      textarea.onchange = (e) => {
        const lines = e.target.value.split('\n').filter(l => l.trim() !== '');
        window.currentEditingEvents[eventType][index][typeKey] = lines;
      };
      payloadContainer.appendChild(textarea);
    } 
    else if (typeKey === 'emote' || typeKey === 'player_emote') {
      const select = document.createElement('select');
      select.style.width = '100%';
      select.style.padding = '2px';
      select.style.fontSize = '12px';
      select.style.background = 'rgba(255,255,255,0.1)';
      select.style.color = 'white';
      
      const noOpt = document.createElement('option');
      noOpt.value = '';
      noOpt.textContent = 'Select...';
      noOpt.style.color = 'black';
      select.appendChild(noOpt);

      (window.validEmotes || []).forEach(emote => {
        const opt = document.createElement('option');
        opt.value = emote;
        opt.textContent = emote.charAt(0).toUpperCase() + emote.slice(1);
        opt.style.color = 'black';
        if (emote === payload) opt.selected = true;
        select.appendChild(opt);
      });

      select.onchange = (e) => {
        window.currentEditingEvents[eventType][index][typeKey] = e.target.value;
      };
      payloadContainer.appendChild(select);
    }
    else if (typeKey === 'play_sound') {
      const row1 = document.createElement('div');
      row1.className = 'admin-control-row';
      row1.style.marginBottom = '2px';
      row1.innerHTML = `<span style="font-size:11px;">Sound:</span>`;
      const input = document.createElement('input');
      input.className = 'admin-input';
      input.style.width = '120px';
      input.value = payload.sound || '';
      input.onchange = (e) => {
        window.currentEditingEvents[eventType][index][typeKey].sound = e.target.value;
      };
      row1.appendChild(input);

      const row2 = document.createElement('div');
      row2.className = 'admin-control-row';
      row2.innerHTML = `<span style="font-size:11px;">Volume:</span>`;
      const volInput = document.createElement('input');
      volInput.type = 'number';
      volInput.step = '0.1';
      volInput.max = '1.0';
      volInput.min = '0.0';
      volInput.style.width = '60px';
      volInput.style.fontSize = '12px';
      volInput.value = payload.volume !== undefined ? payload.volume : 1.0;
      volInput.onchange = (e) => {
        window.currentEditingEvents[eventType][index][typeKey].volume = parseFloat(e.target.value);
      };
      row2.appendChild(volInput);

      payloadContainer.appendChild(row1);
      payloadContainer.appendChild(row2);
    }
    else if (typeKey === 'avatar') {
      const input = document.createElement('input');
      input.className = 'admin-input';
      input.placeholder = "avatars/xxx.png";
      input.value = payload || '';
      input.onchange = (e) => {
        window.currentEditingEvents[eventType][index][typeKey] = e.target.value;
      };
      payloadContainer.appendChild(input);
    }
    else if (typeKey === 'log') {
      const input = document.createElement('input');
      input.className = 'admin-input';
      input.style.marginBottom = '2px';
      input.placeholder = "Log Message";
      input.value = typeof payload === 'string' ? payload : (payload.message || '');
      input.onchange = (e) => {
        if (typeof payload === 'string') {
          window.currentEditingEvents[eventType][index][typeKey] = e.target.value;
        } else {
          window.currentEditingEvents[eventType][index][typeKey].message = e.target.value;
        }
      };

      const row2 = document.createElement('div');
      row2.className = 'admin-control-row';
      row2.innerHTML = `<span style="font-size:11px;">Rate Limit (s):</span>`;
      const limitInput = document.createElement('input');
      limitInput.type = 'number';
      limitInput.style.width = '60px';
      limitInput.style.fontSize = '12px';
      limitInput.value = (typeof payload === 'object' && payload.rate_limit) ? payload.rate_limit : 0;
      limitInput.onchange = (e) => {
        const msgStr = typeof window.currentEditingEvents[eventType][index][typeKey] === 'string' 
          ? window.currentEditingEvents[eventType][index][typeKey] 
          : window.currentEditingEvents[eventType][index][typeKey].message;
          
        window.currentEditingEvents[eventType][index][typeKey] = {
          message: msgStr,
          rate_limit: parseFloat(e.target.value) || 0
        };
      };
      row2.appendChild(limitInput);

      payloadContainer.appendChild(input);
      payloadContainer.appendChild(row2);
    }
    else if (typeKey === 'show_dialog') {
      const txt = document.createElement('input');
      txt.className = 'admin-input';
      txt.style.marginBottom = '2px';
      txt.placeholder = "Dialog description";
      txt.value = payload.description || '';
      txt.onchange = (e) => window.currentEditingEvents[eventType][index][typeKey].description = e.target.value;
      
      const row1 = document.createElement('div');
      row1.className = 'admin-control-row';
      row1.innerHTML = `<span style="font-size:11px;">Type:</span>`;
      const typeInp = document.createElement('input');
      typeInp.className = 'admin-input';
      typeInp.style.width = '90px';
      typeInp.value = payload.type || 'change_map';
      typeInp.onchange = (e) => window.currentEditingEvents[eventType][index][typeKey].type = e.target.value;
      row1.appendChild(typeInp);

      const row2 = document.createElement('div');
      row2.className = 'admin-control-row';
      row2.innerHTML = `<span style="font-size:11px;">Map ID:</span>`;
      const mapInp = document.createElement('input');
      mapInp.type = 'number';
      mapInp.style.width = '60px';
      mapInp.style.fontSize = '12px';
      mapInp.value = payload.map || 1;
      mapInp.onchange = (e) => window.currentEditingEvents[eventType][index][typeKey].map = parseInt(e.target.value);
      row2.appendChild(mapInp);

      payloadContainer.appendChild(txt);
      payloadContainer.appendChild(row1);
      payloadContainer.appendChild(row2);
    }

    card.appendChild(payloadContainer);
    container.appendChild(card);
  });
}

function attachEventButtons() {
  const btnAddOnEnter = document.getElementById('btn-add-on-enter');
  if (btnAddOnEnter) {
    btnAddOnEnter.onclick = () => {
      window.currentEditingEvents.on_enter.push({ say: [''] });
      renderEventUI(window.currentEditingEvents.on_enter, 'events-on-enter-container', 'on_enter');
    };
  }

  const btnAddOnExit = document.getElementById('btn-add-on-exit');
  if (btnAddOnExit) {
    btnAddOnExit.onclick = () => {
      window.currentEditingEvents.on_exit.push({ say: [''] });
      renderEventUI(window.currentEditingEvents.on_exit, 'events-on-exit-container', 'on_exit');
    };
  }

  const btnSaveEvents = document.getElementById('btn-save-events');
  if (btnSaveEvents) {
    btnSaveEvents.onclick = () => {
      const activeEntity = window.selectedObject.get() || window.selectedNpc.get();
      if (!activeEntity) return;

      // Clean empty arrays
      const cleanEvents = (arr) => arr.length > 0 ? arr : undefined;

      activeEntity.on_enter = cleanEvents(JSON.parse(JSON.stringify(window.currentEditingEvents.on_enter)));
      activeEntity.on_exit = cleanEvents(JSON.parse(JSON.stringify(window.currentEditingEvents.on_exit)));

      if (window.selectedObject.get()) {
        networkClient.send({ 
          type: 'update_object', 
          id: activeEntity.id, 
          updates: { on_enter: activeEntity.on_enter, on_exit: activeEntity.on_exit } 
        });
      } else if (window.selectedNpc.get()) {
        networkClient.send({ 
          type: 'update_npc', 
          id: activeEntity.id, 
          updates: { on_enter: activeEntity.on_enter, on_exit: activeEntity.on_exit } 
        });
      }

      // Flash button green
      const oldBg = btnSaveEvents.style.backgroundColor;
      btnSaveEvents.style.backgroundColor = '#2ecc71';
      btnSaveEvents.textContent = 'Saved!';
      setTimeout(() => {
        btnSaveEvents.style.backgroundColor = oldBg;
        btnSaveEvents.textContent = 'Save Events';
      }, 1000);
    };
  }
}
// Attach them once on load
attachEventButtons();

window.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return; // Only left click
  if (e.target.closest('#admin-panel')) return; // Ignore clicks on the admin panel itself

  const canvasRect = canvas.getBoundingClientRect();
  const mouseX = e.clientX - canvasRect.left;
  const mouseY = e.clientY - canvasRect.top;

  // Use canvas coordinates for simple delta tracking
  lastMouseX = e.clientX;
  lastMouseY = e.clientY;

  const worldX = (mouseX - canvas.clientWidth / 2) / camera.zoom + camera.x;
  const worldY = (mouseY - canvas.clientHeight / 2) / camera.zoom + camera.y;

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

  const previousObjId = window.selectedObject.get() ? window.selectedObject.get().id : null;
  const previousNpcId = window.selectedNpc.get() ? window.selectedNpc.get().id : null;

  window.selectedObject.set(null);
  window.selectedNpc.set(null);

  const hitNpc = window.selectedNpc.findNpcAtXY(worldX, worldY);
  if (hitNpc) {
    window.selectedNpc.set(hitNpc.id);
    if (previousNpcId === hitNpc.id) {
      console.log(`Dragging npc: ${hitNpc.id}`);
      isDraggingNpc = true;
      dragOffsetX = hitNpc.x - worldX;
      dragOffsetY = hitNpc.y - worldY;
    } else {
      console.log(`Selected npc: ${hitNpc.id}`);
    }
  } else {
    const hitObj = window.selectedObject.findObjectAtXY(worldX, worldY);
    if (hitObj) {
      window.selectedObject.set(hitObj.id);
      if (previousObjId === hitObj.id) {
        console.log(`Dragging object: ${hitObj.id}`);
        isDraggingObject = true;
        dragOffsetX = hitObj.x - worldX;
        dragOffsetY = hitObj.y - worldY;
      } else {
        console.log(`Selected object: ${hitObj.id}`);
      }
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

    const worldX = (mouseX - canvas.clientWidth / 2) / camera.zoom + camera.x;
    const worldY = (mouseY - canvas.clientHeight / 2) / camera.zoom + camera.y;

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

    const worldX = (mouseX - canvas.clientWidth / 2) / camera.zoom + camera.x;
    const worldY = (mouseY - canvas.clientHeight / 2) / camera.zoom + camera.y;

    window.selectedObject.get().x = Math.round(worldX + dragOffsetX);
    window.selectedObject.get().y = Math.round(worldY + dragOffsetY);
  } else if (isDraggingNpc && window.selectedNpc.get()) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.clientWidth / 2) / camera.zoom + camera.x;
    const worldY = (mouseY - canvas.clientHeight / 2) / camera.zoom + camera.y;

    window.selectedNpc.get().x = Math.round(worldX + dragOffsetX);
    window.selectedNpc.get().y = Math.round(worldY + dragOffsetY);
  } else if (isDraggingAdminImage && window.adminBackgroundImage) {
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    const worldX = (mouseX - canvas.clientWidth / 2) / camera.zoom + camera.x;
    const worldY = (mouseY - canvas.clientHeight / 2) / camera.zoom + camera.y;

    window.adminBackgroundImage._x = Math.round(worldX + bgDragOffsetX);
    window.adminBackgroundImage._y = Math.round(worldY + bgDragOffsetY);
  } else if (isDraggingBackground) {
    const dx = (lastMouseX - e.clientX) / camera.zoom;
    const dy = (lastMouseY - e.clientY) / camera.zoom;
    player.x += dx;
    player.y += dy;
    lastMouseX = e.clientX;
    lastMouseY = e.clientY;
  }
});

window.addEventListener('mouseup', () => {
  if (isResizingObject && window.selectedObject.get()) {
    networkClient.send({
      type: 'resize_object',
      id: window.selectedObject.get().id,
      width: window.selectedObject.get().width,
      length: window.selectedObject.get().length,
      x: window.selectedObject.get().x,
      y: window.selectedObject.get().y
    });
  } else if (isDraggingObject && window.selectedObject.get()) {
    networkClient.send({
      type: 'move_object',
      id: window.selectedObject.get().id,
      x: window.selectedObject.get().x,
      y: window.selectedObject.get().y
    });
  } else if (isDraggingNpc && window.selectedNpc.get()) {
    networkClient.send({
      type: 'move_npc',
      id: window.selectedNpc.get().id,
      x: window.selectedNpc.get().x,
      y: window.selectedNpc.get().y
    });
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
    camera.zoom -= e.deltaY * zoomSensitivity;
    camera.zoom = Math.max(0.1, Math.min(camera.zoom, 5));
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

let adminClipboard = null;

window.addEventListener('copy', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

  if (window.selectedObject.get()) {
    adminClipboard = { type: 'object', data: JSON.parse(JSON.stringify(window.selectedObject.get())) };
    console.log('Copied object');
  } else if (window.selectedNpc.get()) {
    adminClipboard = { type: 'npc', data: JSON.parse(JSON.stringify(window.selectedNpc.get())) };
    console.log('Copied npc');
  }
});

window.addEventListener('paste', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  if (!adminClipboard) return;

  const canvasRect = canvas.getBoundingClientRect();
  const mouseX = lastMouseX - canvasRect.left;
  const mouseY = lastMouseY - canvasRect.top;

  const worldX = Math.round((mouseX - canvas.clientWidth / 2) / camera.zoom + camera.x);
  const worldY = Math.round((mouseY - canvas.clientHeight / 2) / camera.zoom + camera.y);

  if (adminClipboard.type === 'object') {
    networkClient.send({
      type: 'create_object',
      x: worldX,
      y: worldY,
      cloneData: adminClipboard.data
    });
  } else if (adminClipboard.type === 'npc') {
    networkClient.send({
      type: 'create_npc',
      x: worldX,
      y: worldY,
      cloneData: adminClipboard.data
    });
  }
});

updateAdminPanel();

function adminDraw() {
  const dpr = window.devicePixelRatio || 1;
  ctx.save();
  ctx.scale(dpr, dpr);
  ctx.translate(canvas.clientWidth / 2, canvas.clientHeight / 2);
  ctx.scale(camera.zoom, camera.zoom);
  ctx.translate(-camera.x, -camera.y);

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
      ctx.fillStyle = 'rgba(128, 0, 128, 0.5)';
    } else if (obj.noclip || obj.clip === -1) {
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
      ctx.lineWidth = 2 / camera.zoom;
      ctx.beginPath();
      const s = 10 / camera.zoom;
      ctx.rect(handleX - s / 2, handleY - s / 2, s, s);
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

      // Hitbox
      ctx.beginPath();
      ctx.arc(0, 0, (Math.max(npc.width, npc.height) / 2 || 20) + 5, 0, Math.PI * 2);
      ctx.lineWidth = 3;
      ctx.strokeStyle = 'cyan';
      ctx.setLineDash([]); // Ensure no dashes for hitbox
      ctx.stroke();

      // Roam Radius Visualizer
      if (npc.roam_radius !== undefined && typeof npc.roam_radius === 'number' && npc.roam_radius > 0) {
        const startXDist = npc._startX !== undefined ? npc._startX - npc.x : 0;
        const startYDist = npc._startY !== undefined ? npc._startY - npc.y : 0;

        ctx.beginPath();
        // Shift drawing center back to the anchor point the NPC is roaming around
        ctx.arc(startXDist, startYDist, npc.roam_radius, 0, Math.PI * 2);
        ctx.lineWidth = 2;
        ctx.strokeStyle = 'rgba(255, 0, 0, 0.7)';
        ctx.setLineDash([10, 10]);
        ctx.stroke();
        ctx.setLineDash([]); // Reset to solid line for others
      }

      // Interaction Radius
      const r = npc.interaction_radius !== undefined ? npc.interaction_radius : 150;
      ctx.beginPath();
      ctx.arc(0, 0, r, 0, Math.PI * 2);
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(0, 0, 255, 0.8)';
      ctx.setLineDash([5, 5]);
      ctx.stroke();

      ctx.restore();
    }
  });

  ctx.restore();
}

gameLoop.registerFunction(adminDraw, true);
