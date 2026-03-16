import { player } from './main.js';

export class UIManager {
  constructor() {
    this._ac = null;
    this._do = null;
    this._dt = null;
    this._by = null;
    this._bn = null;
    this.isMinimapOpen = false;
  }

  get avatarsContainer() { return this._ac || (this._ac = document.getElementById('avatars-container')); }
  get dialogOverlay() { return this._do || (this._do = document.getElementById('action-dialog')); }
  get dialogText() { return this._dt || (this._dt = document.getElementById('action-dialog-text')); }
  get btnYes() { return this._by || (this._by = document.getElementById('action-dialog-yes')); }
  get btnNo() { return this._bn || (this._bn = document.getElementById('action-dialog-no')); }
  get mapNameDisplay() { return this._mnd || (this._mnd = document.getElementById('map-name-display')); }
  get serverChatStack() { return this._scs || (this._scs = document.getElementById('server-chat-stack')); }

  initLobby(onStartGame) {
    const nameDialog = document.getElementById('name-dialog');
    const nameInput = document.getElementById('player-name-input');
    const startBtn = document.getElementById('start-game-btn');

    const attemptStart = (e) => {
      if (e) e.preventDefault();
      console.log('[UI] attemptStart triggered via:', e ? e.type : 'manual');
      let playerName = null;
      if (nameInput && nameInput.value.trim() !== '') {
        playerName = nameInput.value.trim();
      }
      if (nameDialog) nameDialog.style.display = 'none';

      const topUi = document.getElementById('top-center-ui');
      if (topUi) topUi.style.display = 'flex';

      if (onStartGame) {
        console.log('[UI] Calling onStartGame with playerName: ' + playerName);
        onStartGame(playerName);
      } else {
        console.log('[UI] ERROR: no onStartGame callback attached!');
      }
    };

    if (startBtn) {
      startBtn.addEventListener('click', attemptStart);
      startBtn.addEventListener('touchend', attemptStart);
    }
    if (nameInput) {
      nameInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') attemptStart(e);
      });
    }

    return { nameDialog, nameInput, startBtn };
  }

  initHelpDialog() {
    const helpButton = document.getElementById('help-button');
    const helpDialog = document.getElementById('help-dialog');
    const closeHelpBtn = document.getElementById('close-help-btn');

    if (helpButton && helpDialog && closeHelpBtn) {
      helpButton.addEventListener('click', () => {
        helpDialog.style.display = 'flex';
      });

      closeHelpBtn.addEventListener('click', () => {
        helpDialog.style.display = 'none';
      });

      // Close when clicking outside of the dialog box
      helpDialog.addEventListener('click', (e) => {
        if (e.target === helpDialog) {
          helpDialog.style.display = 'none';
        }
      });
    }
  }

  addServerChatMessage(senderName, message) {
    if (!this.serverChatStack) return;

    const now = Date.now();

    // Reduce time remaining on already displayed messages by 5 seconds
    Array.from(this.serverChatStack.children).forEach(child => {
      if (child.dataset.expireTime) {
        let expire = parseInt(child.dataset.expireTime, 10) - 5000;
        child.dataset.expireTime = expire;
        
        if (child.timeoutId) clearTimeout(child.timeoutId);
        
        const remaining = Math.max(0, expire - now);
        child.timeoutId = setTimeout(() => {
          child.classList.add('fade-out');
          setTimeout(() => {
            if (child.parentNode === this.serverChatStack) {
              this.serverChatStack.removeChild(child);
            }
          }, 500);
        }, remaining);
      }
    });

    const msgElement = document.createElement('div');
    msgElement.className = 'server-chat-message';
    msgElement.innerHTML = `<strong>${senderName}:</strong> ${message}`;

    // LIFO Stack Append - prepends to push older messages down
    this.serverChatStack.prepend(msgElement);
    msgElement.dataset.expireTime = now + 30000;

    // Culling mechanism (max 5 active elements)
    while (this.serverChatStack.children.length > 5) {
      const last = this.serverChatStack.lastChild;
      if (last.timeoutId) clearTimeout(last.timeoutId);
      this.serverChatStack.removeChild(last);
    }

    // Decay sequence (30 seconds)
    msgElement.timeoutId = setTimeout(() => {
      msgElement.classList.add('fade-out');
      setTimeout(() => {
        if (msgElement.parentNode === this.serverChatStack) {
          this.serverChatStack.removeChild(msgElement);
        }
      }, 500); // 500ms aligns with CSS transition timeframe
    }, 30000);
  }

  showMapChangeRejected() {
    let overlay = document.getElementById('map-change-rejected-overlay');
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.id = 'map-change-rejected-overlay';
      overlay.innerHTML = '❌';
      overlay.style.position = 'fixed';
      overlay.style.top = '50%';
      overlay.style.left = '50%';
      overlay.style.transform = 'translate(-50%, -50%)';
      overlay.style.fontSize = '200px';
      overlay.style.color = 'red';
      overlay.style.zIndex = '9999';
      overlay.style.pointerEvents = 'none';
      overlay.style.textShadow = '0 0 20px black';
      overlay.style.opacity = '0';
      overlay.style.transition = 'opacity 0.2s ease-in-out';
      document.body.appendChild(overlay);
    }
    
    // Force reflow if immediately triggering again
    void overlay.offsetWidth;
    overlay.style.opacity = '1';
    
    if (this._rejectTimeout) clearTimeout(this._rejectTimeout);
    this._rejectTimeout = setTimeout(() => {
      overlay.style.opacity = '0';
    }, 2000);
  }

  initMinimapDialog() {
    const mapButton = document.getElementById('map-button');
    const closeMapBtn = document.getElementById('close-minimap-btn');
    const minimapDialog = document.getElementById('minimap-dialog');
    const minimapImage = document.getElementById('minimap-image');

    if (mapButton && minimapDialog && closeMapBtn) {
      mapButton.onclick = () => {
        this.isMinimapOpen = true;
        minimapDialog.style.display = 'flex';
        if (window.init && window.init.mapData) {
          minimapImage.src = `/minimaps/${window.init.mapData.id}.png`;
          this.updateMinimapDot(player);
        }
      };

      closeMapBtn.onclick = () => {
        this.isMinimapOpen = false;
        minimapDialog.style.display = 'none';
      };
    }
  }

  updateMinimapDot(player) {
    if (!this.isMinimapOpen || !window.init || !window.init.mapData) return;
    
    const minimapDot = document.getElementById('minimap-player-dot');
    if (!minimapDot) return;

    const mapWidth = window.init.mapData.width;
    const mapHeight = window.init.mapData.height;
    
    // Coordinate system has 0,0 at center of map
    const pctX = ((player.x + (mapWidth / 2)) / mapWidth) * 100;
    const pctY = ((player.y + (mapHeight / 2)) / mapHeight) * 100;

    // Clamp values inside boundary visually
    const safeX = Math.max(0, Math.min(100, pctX));
    const safeY = Math.max(0, Math.min(100, pctY));

    minimapDot.style.left = `${safeX}%`;
    minimapDot.style.top = `${safeY}%`;
    
    // Debug helper to ensure mathematically it's calculating correctly
    // console.log(`[Minimap] Drawing Dot at X:${safeX}% Y:${safeY}%`);
  }
}

export const uiManager = new UIManager();
