import { emotes } from './emotes.js';
import { uiManager } from './ui.js';
import { player } from './main.js';

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

    window.addEventListener("pagehide", () => {
      if (this.ws) {
        console.log("CLOSING");
        this.ws.close();
        this.ws = null;
      }
    });

    window.addEventListener("pageshow", (event) => {
      if (event.persisted) {
        console.log("RECONNECTING");
        this.connect(this.onInitDataCallback);
      }
    });
  }

  /**
   * Initializes WebSocket connections and sets up event routers.
   * @param {Function} onInitDataCallback Callback for when the server sends initial map and entity state.
   */
  connect(onInitDataCallback) {
    if (onInitDataCallback) {
      this.onInitDataCallback = onInitDataCallback;
    }
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const state = window.init ? 'running' : 'new';
    const wsUrl = `${protocol}//${window.location.host}?state=${state}`;
    console.log(`[NetworkClient] 1. Initiating WebSocket connection to ${wsUrl}`);

    this.ws = new WebSocket(wsUrl);
    console.log(`[NetworkClient] 2. WebSocket instantiated. readyState: ${this.ws.readyState}`);

    this.initializeWebSocketListeners(this.ws);
  }

  initializeWebSocketListeners(ws) {
    ws.addEventListener('open', () => {
      console.log(`[NetworkClient] 3. Connection OPENED successfully! readyState: ${ws.readyState}`);
      this.reconnectAttempts = 0;

      const ld = document.getElementById('loading-dialog');
      if (ld) ld.style.display = 'none';

      // Delay showing name dialog slightly to see if we already have a session restored which would instantly fire 'init' packet.
      setTimeout(() => {
        if (!window.init || (!window.init.mapData && !player?.id)) {
          const nd = document.getElementById('name-dialog');
          if (nd) nd.style.display = 'flex';
        }
      }, 150);
    });

    ws.addEventListener('message', (event) => {
      try {
        const data = JSON.parse(event.data);
        console.log(`[NetworkClient] Received packet of type: ${data.type}`);
        if (data.type === 'error') {
          console.error('Server Error:', data.message);
          if (data.message === 'Session already active in another window.') {
            document.body.innerHTML = `<div style="display:flex;align-items:center;justify-content:center;height:100vh;background:#222;color:white;font-family:sans-serif;"><h2>${data.message}</h2></div>`;

            // Prevent reconnect loop by removing the close event listener
            if (ws._closeHandler) {
              ws.removeEventListener('close', ws._closeHandler);
            }

            ws.close();
            return;
          }
          window.location.reload();
          return;
        } else if (data.type === 'init') {
          if (this.onInitDataCallback) this.onInitDataCallback(data);
        } else if (data.type === 'update' || data.type === 'tick') {
          const charactersToUpdate = data.type === 'tick' ? data.characters : [data.character];

          charactersToUpdate.forEach(serverChar => {
            if (player && serverChar.id === player.id) return; // Prevent echoing our own state

            // Check if this update belongs to an NPC
            const localNpcIndex = (window.init?.npcs || []).findIndex(n => n.id === serverChar.id);
            if (localNpcIndex > -1) {
              const localNpc = window.init.npcs[localNpcIndex];
              if (serverChar.emote !== undefined) localNpc.emote = serverChar.emote;
              if (serverChar.x !== undefined) {
                localNpc.x = serverChar.x;
                localNpc.y = serverChar.y;
              }
              return; // Processed. Do not let it cascade into human character lists.
            }

            const localCharIndex = (window.init?.characters || []).findIndex(c => c.id === serverChar.id);
            if (localCharIndex > -1) {
              const localChar = window.init.characters[localCharIndex];
              // Set targets for interpolation
              localChar.targetX = serverChar.x;
              localChar.targetY = serverChar.y;
              localChar.targetRotation = serverChar.rotation;

              // Directly sync visual properties
              localChar.name = serverChar.name;
              localChar.pantsColor = serverChar.pantsColor;
              localChar.armColor = serverChar.armColor;
              localChar.emote = serverChar.emote;
            } else {
              serverChar.targetX = serverChar.x;
              serverChar.targetY = serverChar.y;
              serverChar.targetRotation = serverChar.rotation;
              if (!window.init) return;
              if (!window.init.characters) window.init.characters = [];
              window.init.characters.push(serverChar);
            }
          });
        } else if (data.type === 'disconnect') {
          if (window.init?.characters) window.init.characters = window.init.characters.filter(c => c.id !== data.id);
        } else if (data.type === 'chat') {
          let senderName = `User ${data.id}`;

          // Check human characters first
          let charIndex = (window.init?.characters || []).findIndex(c => c.id === data.id);
          if (charIndex > -1) {
            window.init.characters[charIndex].chatMessage = data.message;
            window.init.characters[charIndex].chatTime = Date.now();
            senderName = window.init.characters[charIndex].name || senderName;
          } else if (player && player.id === data.id) {
            player.chatMessage = data.message;
            player.chatTime = Date.now();
            senderName = player.name || senderName;
          } else {
            // Check NPCs
            let npcIndex = (window.init?.npcs || []).findIndex(n => n.id === data.id);
            if (npcIndex > -1) {
              senderName = window.init.npcs[npcIndex].name || senderName;
            }
          }

          uiManager.addServerChatMessage(senderName, data.message);

          console.log(`[Chat] ${senderName}: ${data.message}`);
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
    });

    const closeHandler = () => {
      console.warn('Disconnected from WebSocket server');
      this.attemptReconnect(this.onInitDataCallback);
    };

    ws._closeHandler = closeHandler;
    ws.addEventListener('close', closeHandler);
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
   * Helper utility to safely stringify and dispatch a JSON payload to the server.
   * @param {Object} payload 
   */
  send(payload) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(payload));
    }
  }

  /**
   * Send arbitrary chat or command messages upstream.
   * @param {string} msg 
   */
  sendChat(msg) {
    this.send({ type: 'chat', message: msg });
  }

  /**
   * Initializes a brand new non-admin playing character based on the naming dialog.
   * @param {string} name 
   */
  sendCreateCharacter(name) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      console.log(`[NetworkClient] Sending create_character command for name: ${name}`);
      this.send({ type: 'create_character', name: name });
    } else if (this.ws && this.ws.readyState === WebSocket.CONNECTING) {
      console.log('[NetworkClient] WebSocket is still connecting. Queuing create_character command until open.');

      const onOpenSend = () => {
        console.log(`[NetworkClient] WebSocket resolved! Sending queued create_character command for name: ${name}`);
        this.send({ type: 'create_character', name: name });
        this.ws.removeEventListener('open', onOpenSend);
      };

      this.ws.addEventListener('open', onOpenSend);
    } else {
      console.error('[NetworkClient] WebSocket is closed or in an invalid state. Cannot send create_character.');
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
    if (!player) return;

    const charIndex = (window.init?.characters || []).findIndex(c => c.id === player.id);
    if (charIndex > -1) {
      window.init.characters[charIndex].x = player.x;
      window.init.characters[charIndex].y = player.y;
      window.init.characters[charIndex].rotation = player.rotation;
      window.init.characters[charIndex].name = player.name; // Keep name synced
      window.init.characters[charIndex].emote = player.emote;

      this.send({ type: 'update', character: window.init.characters[charIndex] });
    }
  }
}

export const networkClient = new NetworkClient();
