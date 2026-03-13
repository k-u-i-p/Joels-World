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
}

export const uiManager = new UIManager();
