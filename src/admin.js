window.isAdmin = true;

export function setupAdmin() {
  const canvas = document.getElementById('gameCanvas');
  const ctx = canvas.getContext('2d');
  const player = window.player;
  const getBuildings = () => window.buildings;
  const getCollisionObjects = () => window.collisionObjects;
  const ws = window.ws;

  const adminPanel = document.getElementById('admin-panel');

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
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'create_building_generic', x: Math.round(player.x), y: Math.round(player.y) }));
    }
  };

  document.getElementById('btn-create-col-rect').onclick = () => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'create_collision_object', shape: 'rect', x: Math.round(player.x), y: Math.round(player.y) }));
    }
  };

  document.getElementById('btn-create-col-circle').onclick = () => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'create_collision_object', shape: 'circle', x: Math.round(player.x), y: Math.round(player.y) }));
    }
  };

  document.getElementById('btn-delete-building').onclick = () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'delete_building', id: selectedBuilding.id }));
      selectedBuilding = null;
      draggedBuilding = null;
      window.adminSelectedBuilding = null;
      updateAdminPanel();
    }
  };

  document.getElementById('btn-delete-col').onclick = () => {
    if (selectedCollisionObject && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'delete_collision_object', id: selectedCollisionObject.id }));
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
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'rename_building', id: selectedBuilding.id, name: selectedBuilding.name }));
    }
  };

  bindHoldAction('btn-rot-left', () => {
    if (!selectedBuilding) return;
    selectedBuilding.rotation = Math.max(0, (selectedBuilding.rotation || 0) - 1);
  }, () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
    }
  });

  bindHoldAction('btn-rot-right', () => {
    if (!selectedBuilding) return;
    selectedBuilding.rotation = ((selectedBuilding.rotation || 0) + 1) % 360;
  }, () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
    }
  });

  bindHoldAction('btn-width-dec', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.width * 0.02));
    selectedBuilding.width = Math.max(10, selectedBuilding.width - change);
  }, () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-width-inc', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.width * 0.02));
    selectedBuilding.width += change;
  }, () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-height-dec', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.height * 0.02));
    selectedBuilding.height = Math.max(10, selectedBuilding.height - change);
  }, () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-height-inc', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.height * 0.02));
    selectedBuilding.height += change;
  }, () => {
    if (selectedBuilding && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-col-width-dec', () => {
    if (!selectedCollisionObject) return;
    let change = Math.max(1, Math.round(selectedCollisionObject.width * 0.02));
    selectedCollisionObject.width = Math.max(5, selectedCollisionObject.width - change);
  }, () => {
    if (selectedCollisionObject && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
    }
  });

  bindHoldAction('btn-col-width-inc', () => {
    if (!selectedCollisionObject) return;
    let change = Math.max(1, Math.round(selectedCollisionObject.width * 0.02));
    selectedCollisionObject.width += change;
  }, () => {
    if (selectedCollisionObject && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
    }
  });

  bindHoldAction('btn-col-length-dec', () => {
    if (!selectedCollisionObject) return;
    let change = Math.max(1, Math.round(selectedCollisionObject.length * 0.02));
    selectedCollisionObject.length = Math.max(5, selectedCollisionObject.length - change);
  }, () => {
    if (selectedCollisionObject && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
    }
  });

  bindHoldAction('btn-col-length-inc', () => {
    if (!selectedCollisionObject) return;
    let change = Math.max(1, Math.round(selectedCollisionObject.length * 0.02));
    selectedCollisionObject.length += change;
  }, () => {
    if (selectedCollisionObject && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_collision_object', id: selectedCollisionObject.id, width: selectedCollisionObject.width, length: selectedCollisionObject.length }));
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

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? player.x);
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? player.y);

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
        const hW = obj.width / 2;
        const hL = obj.length / 2;
        if (worldX >= obj.x - hW && worldX <= obj.x + hW &&
          worldY >= obj.y - hL && worldY <= obj.y + hL) {
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

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? player.x);
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? player.y);

      draggedBuilding.x = Math.round(worldX + dragOffsetX);
      draggedBuilding.y = Math.round(worldY + dragOffsetY);
    } else if (draggedCollisionObject) {
      const canvasRect = canvas.getBoundingClientRect();
      const mouseX = e.clientX - canvasRect.left;
      const mouseY = e.clientY - canvasRect.top;

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? player.x);
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? player.y);

      draggedCollisionObject.x = Math.round(worldX + dragOffsetX);
      draggedCollisionObject.y = Math.round(worldY + dragOffsetY);
    } else if (isDraggingAdminImage && window.adminBackgroundImage) {
      const canvasRect = canvas.getBoundingClientRect();
      const mouseX = e.clientX - canvasRect.left;
      const mouseY = e.clientY - canvasRect.top;

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? player.x);
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? player.y);

      window.adminBackgroundImage._x = Math.round(worldX + bgDragOffsetX);
      window.adminBackgroundImage._y = Math.round(worldY + bgDragOffsetY);
    } else if (isDraggingBackground) {
      const dx = (lastMouseX - e.clientX) / window.cameraZoom;
      const dy = (lastMouseY - e.clientY) / window.cameraZoom;
      player.x += dx;
      player.y += dy;
      lastMouseX = e.clientX;
      lastMouseY = e.clientY;
    }
  });

  window.addEventListener('mouseup', () => {
    if (draggedBuilding) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'move_building',
          id: draggedBuilding.id,
          x: draggedBuilding.x,
          y: draggedBuilding.y
        }));
      }
      draggedBuilding = null;
    }
    if (draggedCollisionObject) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
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
      return;
    }

    // Check if it is an SVG file
    if (file.type !== 'image/svg+xml' && !lowerName.endsWith('.svg')) {
      console.warn("Dropped file is not an SVG, PNG, or JPG:", file.name);
      return;
    }

    const reader = new FileReader();
    reader.onload = (event) => {
      const content = event.target.result;

      const canvasRect = canvas.getBoundingClientRect();
      const mouseX = e.clientX - canvasRect.left;
      const mouseY = e.clientY - canvasRect.top;

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX || player.x);
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY || player.y);

      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'create_building',
          filename: file.name,
          content: content,
          x: Math.round(worldX),
          y: Math.round(worldY)
        }));
      }
    };
    reader.readAsText(file);
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
      ctx.restore();
    });

    const collisionObjects = getCollisionObjects() || [];
    collisionObjects.forEach(obj => {
      if (window.adminSelectedCollisionObject && window.adminSelectedCollisionObject.id === obj.id) {
        ctx.fillStyle = 'purple';
      } else {
        ctx.fillStyle = 'rgba(155, 89, 182, 0.5)';
      }
      ctx.beginPath();
      if (obj.shape === 'circle') {
        const radius = Math.max(obj.width, obj.length) / 2;
        ctx.arc(obj.x, obj.y, radius, 0, Math.PI * 2);
      } else {
        ctx.rect(obj.x - obj.width / 2, obj.y - obj.length / 2, obj.width, obj.length);
      }
      ctx.fill();
    });

    ctx.restore();
  };

  if (window.gameLoop) {
    requestAnimationFrame(window.gameLoop);
  }

}

window.addEventListener('load', setupAdmin);
