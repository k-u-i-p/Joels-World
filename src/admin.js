export function setupAdmin(deps) {
  const { canvas, player, getBuildings, ws } = deps;

  // Create UI overlay
  const adminPanel = document.createElement('div');
  adminPanel.id = 'admin-panel';
  adminPanel.style.display = 'none';
  document.body.appendChild(adminPanel);

  function updateAdminPanel() {
    if (!selectedBuilding) {
      adminPanel.style.display = 'none';
      return;
    }

    adminPanel.style.display = 'block';
    adminPanel.innerHTML = `
      <h3>Edit Building</h3>
      <div class="control-row">
        <span>Rotate:</span>
        <button id="btn-rot-left">↺</button>
        <button id="btn-rot-right">↻</button>
      </div>
      <div class="control-row">
        <span>Size:</span>
        <button id="btn-size-dec">-</button>
        <button id="btn-size-inc">+</button>
      </div>
    `;

    document.getElementById('btn-rot-left').onclick = () => {
      selectedBuilding.rotation = ((selectedBuilding.rotation || 0) - 10) % 360;
      console.log('rotate');
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
      }
    };

    document.getElementById('btn-rot-right').onclick = () => {
      selectedBuilding.rotation = ((selectedBuilding.rotation || 0) + 10) % 360;
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'rotate_building', id: selectedBuilding.id, rotation: selectedBuilding.rotation }));
      }
    };

    document.getElementById('btn-size-dec').onclick = () => {
      selectedBuilding.width = Math.max(10, Math.round((selectedBuilding.width / 100) * 90));
      selectedBuilding.height = Math.max(10, Math.round((selectedBuilding.height / 100) * 90));
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
      }
    };

    document.getElementById('btn-size-inc').onclick = () => {
      selectedBuilding.width = Math.round((selectedBuilding.width / 100) * 110);
      selectedBuilding.height = Math.round((selectedBuilding.height / 100) * 110);
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize_building', id: selectedBuilding.id, width: selectedBuilding.width, height: selectedBuilding.height }));
      }
    };
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

  let draggedBuilding = null;
  let selectedBuilding = null;
  let dragOffsetX = 0;
  let dragOffsetY = 0;

  let isDraggingBackground = false;
  let lastMouseX = 0;
  let lastMouseY = 0;

  window.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return; // Only left click
    if (e.target.closest('#admin-panel')) return; // Ignore clicks on the admin panel itself

    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;

    // Use canvas coordinates for simple delta tracking
    lastMouseX = e.clientX;
    lastMouseY = e.clientY;

    const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + player.x;
    const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + player.y;

    selectedBuilding = null;

    const buildings = getBuildings();

    // Search backwards so that buildings drawn last (on top) are picked first
    for (let i = buildings.length - 1; i >= 0; i--) {
      const building = buildings[i];
      if (isPointInBuilding(worldX, worldY, building)) {
        console.log(`Dragging building: ${building.id}`);
        draggedBuilding = building;
        selectedBuilding = building;
        dragOffsetX = building.x - worldX;
        dragOffsetY = building.y - worldY;
        break;
      }
    }

    if (!draggedBuilding && !e.target.closest('#admin-panel')) {
      isDraggingBackground = true;
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

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + player.x;
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + player.y;

      draggedBuilding.x = Math.round(worldX + dragOffsetX);
      draggedBuilding.y = Math.round(worldY + dragOffsetY);
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
    isDraggingBackground = false;
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

    // Check if it is an SVG file
    if (file.type !== 'image/svg+xml' && !file.name.toLowerCase().endsWith('.svg')) {
      console.warn("Dropped file is not an SVG:", file.name);
      return;
    }

    const reader = new FileReader();
    reader.onload = (event) => {
      const content = event.target.result;

      const canvasRect = canvas.getBoundingClientRect();
      const mouseX = e.clientX - canvasRect.left;
      const mouseY = e.clientY - canvasRect.top;

      const worldX = (mouseX - canvas.width / 2) / window.cameraZoom + player.x;
      const worldY = (mouseY - canvas.height / 2) / window.cameraZoom + player.y;

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
}
