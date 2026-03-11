window.isAdmin = true;

export function setupAdmin() {
  const canvas = document.getElementById('gameCanvas');
  const ctx = canvas.getContext('2d');
  const player = window.player;
  const getBuildings = () => window.buildings;
  const getPlants = () => window.plants;
  const ws = window.ws;

  const adminPanel = document.getElementById('admin-panel');

  let activeHoldInterval = null;

  function bindHoldAction(id, action) {
    const btn = document.getElementById(id);
    if (!btn) return;

    const start = (e) => {
      if (e && e.button !== 0) return;
      action();
      if (activeHoldInterval) clearInterval(activeHoldInterval);
      activeHoldInterval = setInterval(action, 50);
    };

    const stop = () => {
      if (activeHoldInterval) {
        clearInterval(activeHoldInterval);
        activeHoldInterval = null;
      }
    };

    btn.addEventListener('mousedown', start);
    btn.addEventListener('mouseup', stop);
    btn.addEventListener('mouseleave', stop);
    btn.addEventListener('contextmenu', e => e.preventDefault());
  }

  let draggedBuilding = null;
  let selectedBuilding = null;
  let draggedPlant = null;
  let selectedPlant = null;
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
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
    }
  });

  bindHoldAction('btn-rot-right', () => {
    if (!selectedBuilding) return;
    selectedBuilding.rotation = ((selectedBuilding.rotation || 0) + 1) % 360;
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
    }
  });

  bindHoldAction('btn-width-dec', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.width * 0.02));
    selectedBuilding.width = Math.max(10, selectedBuilding.width - change);
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-width-inc', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.width * 0.02));
    selectedBuilding.width += change;
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-height-dec', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.height * 0.02));
    selectedBuilding.height = Math.max(10, selectedBuilding.height - change);
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-height-inc', () => {
    if (!selectedBuilding) return;
    let change = Math.max(1, Math.round(selectedBuilding.height * 0.02));
    selectedBuilding.height += change;
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
    }
  });

  bindHoldAction('btn-plant-size-dec', () => {
    if (!selectedPlant) return;
    let change = Math.max(1, Math.round(selectedPlant.size * 0.02));
    selectedPlant.size = Math.max(5, selectedPlant.size - change);
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_plant', id: selectedPlant.id, size: selectedPlant.size }));
    }
  });

  bindHoldAction('btn-plant-size-inc', () => {
    if (!selectedPlant) return;
    let change = Math.max(1, Math.round(selectedPlant.size * 0.02));
    selectedPlant.size += change;
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize_plant', id: selectedPlant.id, size: selectedPlant.size }));
    }
  });

  function updateAdminPanel() {
    adminPanel.style.display = 'block';

    const editSection = document.getElementById('edit-building-section');
    const editPlantSection = document.getElementById('edit-plant-section');

    if (selectedBuilding) {
      editSection.style.display = 'block';
      editPlantSection.style.display = 'none';

      const nameInput = document.getElementById('building-name-input');
      nameInput.value = selectedBuilding.name || selectedBuilding.id;
    } else if (selectedPlant) {
      editSection.style.display = 'none';
      editPlantSection.style.display = 'block';
    } else {
      editSection.style.display = 'none';
      editPlantSection.style.display = 'none';
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
    selectedPlant = null;
    window.adminSelectedPlant = null;

    const buildings = getBuildings();
    const plants = getPlants();

    // Check plants and buildings backwards so that top items are selected first
    for (let i = plants.length - 1; i >= 0; i--) {
      const plant = plants[i];
      if (Math.hypot(worldX - plant.x, worldY - plant.y) <= plant.size) {
        console.log(`Dragging plant: ${plant.id}`);
        draggedPlant = plant;
        selectedPlant = plant;
        window.adminSelectedPlant = plant;
        dragOffsetX = plant.x - worldX;
        dragOffsetY = plant.y - worldY;
        break;
      }
    }

    if (!draggedPlant) {
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

    if (!draggedPlant && !draggedBuilding && !e.target.closest('#admin-panel')) {
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
    } else if (draggedPlant) {
      const canvasRect = canvas.getBoundingClientRect();
      const mouseX = e.clientX - canvasRect.left;
      const mouseY = e.clientY - canvasRect.top;

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + (window.cameraX ?? player.x);
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + (window.cameraY ?? player.y);

      draggedPlant.x = Math.round(worldX + dragOffsetX);
      draggedPlant.y = Math.round(worldY + dragOffsetY);
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
    if (draggedPlant) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'move_plant',
          id: draggedPlant.id,
          x: draggedPlant.x,
          y: draggedPlant.y
        }));
      }
      draggedPlant = null;
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

  window.adminDraw = function() {
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

    const plants = getPlants();
    plants.forEach(plant => {
      if (window.adminSelectedPlant && window.adminSelectedPlant.id === plant.id) {
        ctx.fillStyle = 'purple';
      } else {
        ctx.fillStyle = 'rgba(155, 89, 182, 0.5)';
      }
      ctx.beginPath();
      ctx.arc(plant.x, plant.y, plant.size, 0, Math.PI * 2);
      ctx.fill();
    });

    ctx.restore();
  };
}

window.addEventListener('load', setupAdmin);
