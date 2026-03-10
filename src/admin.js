export function setupAdmin(deps) {
  const { canvas, player, getBuildings, ws } = deps;

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
    const canvasRect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - canvasRect.left;
    const mouseY = e.clientY - canvasRect.top;
    
    // Use canvas coordinates for simple delta tracking
    lastMouseX = e.clientX;
    lastMouseY = e.clientY;
    
    const worldX = mouseX - canvas.width / 2 + player.x;
    const worldY = mouseY - canvas.height / 2 + player.y;

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
    
    if (!draggedBuilding) {
      isDraggingBackground = true;
    }
  });

  window.addEventListener('mousemove', (e) => {
    if (draggedBuilding) {
      const canvasRect = canvas.getBoundingClientRect();
      const mouseX = e.clientX - canvasRect.left;
      const mouseY = e.clientY - canvasRect.top;
      
      const worldX = mouseX - canvas.width / 2 + player.x;
      const worldY = mouseY - canvas.height / 2 + player.y;

      draggedBuilding.x = Math.round(worldX + dragOffsetX);
      draggedBuilding.y = Math.round(worldY + dragOffsetY);
    } else if (isDraggingBackground) {
      const dx = lastMouseX - e.clientX;
      const dy = lastMouseY - e.clientY;
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

  window.addEventListener('keydown', (e) => {
    const chatInput = document.getElementById('chat-input');
    if (document.activeElement === chatInput) return; // Let chat handle keys

    if ((e.key === 'r' || e.key === 'R') && selectedBuilding) {
      selectedBuilding.rotation = ((selectedBuilding.rotation || 0) + 10) % 360;
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ 
          type: 'rotate_building', 
          id: selectedBuilding.id, 
          rotation: selectedBuilding.rotation 
        }));
      }
    }
  });
}
