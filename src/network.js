import { emotes } from './emotes.js';

export class NetworkClient {
  constructor() {
    this.isAdmin = window.isAdmin === true;
    this.ws = null;

    this.syncTimeout = null;
    this.lastSyncCallTime = 0;
    this.SYNC_THROTTLE_MS = 50;

    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 5;
    this.baseReconnectDelay = 1000;
  }

  /**
   * Initializes WebSocket connections and sets up event routers.
   * @param {Function} onInitDataCallback Callback for when the server sends initial map and entity state.
   */
  connect(onInitDataCallback) {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}`;
    
    this.ws = new WebSocket(wsUrl);
    window.ws = this.ws;

    this.ws.onopen = () => {
      console.log('Connected to WebSocket server');
      this.reconnectAttempts = 0;
    };

    this.ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data.type === 'error') {
          console.error('Server Error:', data.message);
          if (window.gameStarted) {
            window.gameStarted = false;
            window.init = null;
            const nameDialog = document.getElementById('name-dialog');
            if (nameDialog) nameDialog.style.display = 'flex';
            const topUi = document.getElementById('top-center-ui');
            if (topUi) topUi.style.display = 'none';
          }
          return;
        } else if (data.type === 'init') {
          if (onInitDataCallback) onInitDataCallback(data);
        } else if (data.type === 'update' || data.type === 'tick') {
          const charactersToUpdate = data.type === 'tick' ? data.characters : [data.character];
          const player = window.player;

          charactersToUpdate.forEach(serverChar => {
            if (player && serverChar.id === player.id) return; // Prevent echoing our own state

            const localCharIndex = (window.init?.characters || []).findIndex(c => c.id === serverChar.id);
            if (localCharIndex > -1) {
              const localChar = window.init.characters[localCharIndex];
              // Set targets for interpolation
              localChar.startX = localChar.x !== undefined ? localChar.x : serverChar.x;
              localChar.startY = localChar.y !== undefined ? localChar.y : serverChar.y;
              localChar.startRotation = localChar.rotation !== undefined ? localChar.rotation : serverChar.rotation;
              localChar.targetX = serverChar.x;
              localChar.targetY = serverChar.y;
              localChar.targetRotation = serverChar.rotation;
              localChar.targetStartTime = Date.now();

              // Directly sync visual properties
              localChar.name = serverChar.name;
              localChar.pantsColor = serverChar.pantsColor;
              localChar.armColor = serverChar.armColor;
              localChar.emote = serverChar.emote;
            } else {
              serverChar.startX = serverChar.x;
              serverChar.startY = serverChar.y;
              serverChar.startRotation = serverChar.rotation;
              serverChar.targetX = serverChar.x;
              serverChar.targetY = serverChar.y;
              serverChar.targetRotation = serverChar.rotation;
              serverChar.targetStartTime = Date.now();
              if (!window.init) return;
              if (!window.init.characters) window.init.characters = [];
              window.init.characters.push(serverChar);
            }
          });
        } else if (data.type === 'disconnect') {
          if (window.init?.characters) window.init.characters = window.init.characters.filter(c => c.id !== data.id);
        } else if (data.type === 'chat') {
          const player = window.player;
          // Check human characters first
          let charIndex = (window.init?.characters || []).findIndex(c => c.id === data.id);
          if (charIndex > -1) {
            window.init.characters[charIndex].chatMessage = data.message;
            window.init.characters[charIndex].chatTime = Date.now();
          } else if (player && player.id === data.id) {
            player.chatMessage = data.message;
            player.chatTime = Date.now();
          } else {
            // Check NPCs
            let npcIndex = (window.init?.npcs || []).findIndex(n => n.id === data.id);
            if (npcIndex > -1) {
              window.init.npcs[npcIndex].chatMessage = data.message;
              window.init.npcs[npcIndex].chatTime = Date.now();
            }
          }
        } else if (data.type === 'objects_update') {
          if (window.init) {
            window.init.objects = data.objects || [];
          } else {
            window.init = { objects: data.objects || [] };
          }
        } else if (data.type === 'npcs_update') {
          if (window.init) {
            window.init.npcs = data.npcs || [];
          } else {
            window.init = { npcs: data.npcs || [] };
          }
        }
      } catch (e) {
        console.error(e);
      }
    };

    this.ws.onclose = () => {
      console.warn('Disconnected from WebSocket server');
      this.attemptReconnect(onInitDataCallback);
    };
  }

  /**
   * Attempts to reconnect to the WebSocket server with exponential backoff.
   * @param {Function} onInitDataCallback 
   */
  attemptReconnect(onInitDataCallback) {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      console.error('Max reconnect attempts reached. Reloading the page...');
      window.location.reload();
      return;
    }

    const delay = this.baseReconnectDelay * Math.pow(1.5, this.reconnectAttempts);
    console.log(`Attempting to reconnect in ${Math.round(delay)}ms... (Attempt ${this.reconnectAttempts + 1}/${this.maxReconnectAttempts})`);

    setTimeout(() => {
      this.reconnectAttempts++;
      this.connect(onInitDataCallback);
    }, delay);
  }

  /**
   * Send arbitrary chat or command messages upstream.
   * @param {string} msg 
   */
  sendChat(msg) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: 'chat', message: msg }));
    }
  }

  /**
   * Initializes a brand new non-admin playing character based on the naming dialog.
   * @param {string} name 
   */
  sendCreateCharacter(name) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: 'create_character', name: name }));
    }
  }

  /**
   * Throttles the synchronization of the player's state (position, rotation, etc.)
   * to the server via WebSocket. Ensures a maximum of one payload sent every SYNC_THROTTLE_MS.
   */
  syncPlayerToJSON() {
    const now = Date.now();
    if (now - this.lastSyncCallTime >= this.SYNC_THROTTLE_MS) {
      this.lastSyncCallTime = now;
      if (this.syncTimeout) {
        clearTimeout(this.syncTimeout);
        this.syncTimeout = null;
      }
      this.doSyncPlayerToJSON();
    } else {
      if (!this.syncTimeout) {
        this.syncTimeout = setTimeout(() => {
          this.lastSyncCallTime = Date.now();
          this.syncTimeout = null;
          this.doSyncPlayerToJSON();
        }, this.SYNC_THROTTLE_MS - (now - this.lastSyncCallTime));
      }
    }
  }

  /**
   * Executes the actual payload construction and WebSocket transmission for the player's 
   * synchronized state towards the server.
   */
  doSyncPlayerToJSON() {
    const player = window.player;
    if (!player) return;

    const charIndex = (window.init?.characters || []).findIndex(c => c.id === player.id);
    if (charIndex > -1) {
      window.init.characters[charIndex].x = player.x;
      window.init.characters[charIndex].y = player.y;
      window.init.characters[charIndex].rotation = player.rotation;
      window.init.characters[charIndex].name = player.name; // Keep name synced
      window.init.characters[charIndex].emote = player.emote;

      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'update', character: window.init.characters[charIndex] }));
      }
    }
  }
}

export const networkClient = new NetworkClient();
