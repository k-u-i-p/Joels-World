export class UIManager {
  constructor() {
    this._ac = null;
    this._do = null;
    this._dt = null;
    this._by = null;
    this._bn = null;
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

    const attemptStart = () => {
      let playerName = null;
      if (nameInput && nameInput.value.trim() !== '') {
        playerName = nameInput.value.trim();
      }
      if (nameDialog) nameDialog.style.display = 'none';
      
      const topUi = document.getElementById('top-center-ui');
      if (topUi) topUi.style.display = 'flex';

      if (onStartGame) {
        onStartGame(playerName);
      }
    };

    if (startBtn) {
      startBtn.addEventListener('click', attemptStart);
    }
    if (nameInput) {
      nameInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') attemptStart();
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

    const msgElement = document.createElement('div');
    msgElement.className = 'server-chat-message';
    msgElement.innerHTML = `<strong>${senderName}:</strong> ${message}`;

    // LIFO Stack Append - prepends to push older messages down
    this.serverChatStack.prepend(msgElement);

    // Culling mechanism (max 5 active elements)
    while (this.serverChatStack.children.length > 5) {
      this.serverChatStack.removeChild(this.serverChatStack.lastChild);
    }

    // Decay sequence (30 seconds)
    setTimeout(() => {
      msgElement.classList.add('fade-out');
      setTimeout(() => {
        if (msgElement.parentNode === this.serverChatStack) {
          this.serverChatStack.removeChild(msgElement);
        }
      }, 500); // 500ms aligns with CSS transition timeframe
    }, 30000);
  }
}

export const uiManager = new UIManager();
