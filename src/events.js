export const EventHandlers = {
  avatar: (sourceObj, payload, context) => {
    const { UI } = context;
    const container = UI.avatarsContainer;
    if (container) {
      let el = container.querySelector(`[data-npc-id="${sourceObj.id}"]`);
      const avatarSrc = payload.startsWith('/') ? payload : '/' + payload;

      if (!el) {
        el = document.createElement('img');
        el.dataset.npcId = sourceObj.id;
        el.src = avatarSrc;
        el.style.width = '128px';
        el.style.height = '128px';
        el.style.borderRadius = '8px';
        el.style.border = '2px solid #ecf0f1';
        el.style.objectFit = 'cover';
        container.appendChild(el);
      } else {
        el.src = avatarSrc;
      }
    }
  },

  say: (sourceObj, payload, context) => {
    const { player } = context;
    if (payload && payload.length > 0) {
      let randomMsg = payload[Math.floor(Math.random() * payload.length)];
      if (player && player.name) {
        randomMsg = randomMsg.replace(/{name}/g, player.name);
      } else {
        randomMsg = randomMsg.replace(/{name}/g, 'Student');
      }
      sourceObj.chatMessage = randomMsg;
      sourceObj.chatTime = Date.now();
    }
  },

  show_dialog: (sourceObj, payload, context) => {
    const { UI } = context;
    const dialogOverlay = UI.dialogOverlay;
    const dialogText = UI.dialogText;
    const btnYes = UI.btnYes;
    const btnNo = UI.btnNo;

    if (dialogOverlay && dialogText && btnYes && btnNo) {
      dialogText.textContent = payload.description || 'Proceed?';
      dialogOverlay.style.display = 'block';

      btnNo.onclick = () => {
        dialogOverlay.style.display = 'none';
      };

      btnYes.onclick = () => {
        dialogOverlay.style.display = 'none';
        if (payload.type === 'change_map') {
          const mapId = Number(payload.map);
          if (!isNaN(mapId)) {
            if (window.ws.readyState === WebSocket.OPEN) {
              window.ws.send(JSON.stringify({ type: 'change_map', mapId: mapId }));
            }
          } else {
            console.warn("Invalid map ID provided:", payload.map);
          }
        }
      };
    }
  },

  play_sound: (sourceObj, payload, context) => {
    if (payload && payload.sound) {
      const soundSrc = payload.sound.startsWith('/') ? payload.sound : '/' + payload.sound;
      const isMapObj = (sourceObj === window.init?.mapData) || (sourceObj.id === 'map');

      if (isMapObj) {
        if (!window.bgAudio.src.endsWith(soundSrc)) {
          window.bgAudio.pause();
          window.bgAudio.src = soundSrc;
          if (typeof payload.volume === 'number') {
            window.bgAudio.volume = Math.max(0, Math.min(1, payload.volume));
          }
          window.bgAudio.play().catch(e => console.warn("Failed to play bg sound:", e));
        }
      } else {
        if (sourceObj.activeAudio) {
          sourceObj.activeAudio.pause();
          sourceObj.activeAudio.currentTime = 0;
        }
        sourceObj.activeAudio = new Audio(soundSrc);
        if (typeof payload.volume === 'number') {
          sourceObj.activeAudio.volume = Math.max(0, Math.min(1, payload.volume));
        }
        sourceObj.activeAudio.play().catch(e => console.warn("Failed to play sound:", e));
      }
    }
  },

  emote: (sourceObj, payload, context) => {
    const { player, syncPlayerToJSON } = context;
    const isInteractiveObj = sourceObj.shape === 'rect' || sourceObj.shape === 'circle' && !sourceObj.gender;
    const isMapObj = (sourceObj === window.init?.mapData) || (sourceObj.id === 'map');

    const targetEntity = (isInteractiveObj || isMapObj) ? player : sourceObj;
    targetEntity.emote = {
      name: payload,
      startTime: Date.now()
    };

    if (targetEntity === player) {
      syncPlayerToJSON();
    }
  },

  clear_emote: (sourceObj, payload, context) => {
    const { player, syncPlayerToJSON } = context;
    const isInteractiveObj = sourceObj.shape === 'rect' || sourceObj.shape === 'circle' && !sourceObj.gender;
    const isMapObj = (sourceObj === window.init?.mapData) || (sourceObj.id === 'map');

    const targetEntity = (isInteractiveObj || isMapObj) ? player : sourceObj;
    targetEntity.emote = null;

    if (targetEntity === player) {
      syncPlayerToJSON();
    }
  }
};
