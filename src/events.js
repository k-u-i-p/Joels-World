import { soundManager } from './sound.js';
import { networkClient } from './network.js';

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

      const actionDialog = document.getElementById('top-center-ui');
      if (actionDialog) actionDialog.classList.add('avatar-active');

      const mapNameDisplay = UI.mapNameDisplay;
      if (mapNameDisplay) {
        if (!mapNameDisplay.dataset.originalName) {
          mapNameDisplay.dataset.originalName = mapNameDisplay.textContent;
        }
        mapNameDisplay.textContent = sourceObj.name || 'NPC';
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
            networkClient.send({ type: 'change_map', mapId: mapId });
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
        soundManager.playBackground(soundSrc, payload.volume);
      } else {
        if (sourceObj.activeAudio) {
          sourceObj.activeAudio.pause();
          sourceObj.activeAudio.currentTime = 0;
        }
        let targetVolume = typeof payload.volume === 'number' ? Math.max(0, payload.volume) : 1;
        sourceObj.activeAudio = soundManager.playPooled(soundSrc, targetVolume);
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

  player_emote: (sourceObj, payload, context) => {
    const { player, syncPlayerToJSON } = context;
    player.emote = {
      name: payload,
      startTime: Date.now()
    };
    syncPlayerToJSON();
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
  },

  log: (sourceObj, payload, context) => {
    console.log("LOG EVENT: ", payload);
    const { player } = context;
    if (!payload || !sourceObj) return;

    let msg = typeof payload === 'string' ? payload : payload.message;
    let rateLimitSec = typeof payload === 'object' && payload.rate_limit ? payload.rate_limit : 0;

    if (msg) {
      if (rateLimitSec > 0) {
        if (!sourceObj._lastLogTimes) sourceObj._lastLogTimes = {};
        const now = Date.now();
        const lastTime = sourceObj._lastLogTimes[msg] || 0;
        if (now - lastTime < rateLimitSec * 1000) {
          return; // Rate limited, skip sending
        }
        sourceObj._lastLogTimes[msg] = now;
      }
        if (player && player.name) {
          msg = msg.replace(/{name}/g, player.name);
        } else {
          msg = msg.replace(/{name}/g, 'Student');
        }
        if (sourceObj && sourceObj.name) {
          msg = msg.replace(/{npc_name}/g, sourceObj.name);
        } else {
          msg = msg.replace(/{npc_name}/g, 'NPC');
        }
        networkClient.send({ type: 'log', message: msg, npc_id: sourceObj ? sourceObj.id : null });
      }
  }
};

export function processEvents(sourceObj, rawActions, eventType, context) {
  let actions = rawActions;
  if (typeof rawActions === 'number') {
    const parentObj = window.init?.objects?.find(o => o.id === rawActions);
    if (!parentObj || !parentObj[eventType]) return;
    actions = parentObj[eventType];
  }

  if (!actions || !Array.isArray(actions)) return;

  for (const action of actions) {
    for (const [key, payload] of Object.entries(action)) {
      if (EventHandlers[key]) {
        EventHandlers[key](sourceObj, payload, context);
      }
    }
  }
}
