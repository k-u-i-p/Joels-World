const fs = require('fs');

function replaceBlock(code, startStr, endStr, replacement) {
  const startIndex = code.indexOf(startStr);
  if (startIndex === -1) throw new Error("Start string not found: " + startStr.substring(0, 30));
  
  const endIndex = code.indexOf(endStr, startIndex);
  if (endIndex === -1) throw new Error("End string not found: " + endStr.substring(0, 30));
  
  const endTotalIndex = endIndex + endStr.length;
  return code.substring(0, startIndex) + replacement + code.substring(endTotalIndex);
}

// === CLEANUP MAIN.JS ===
let mainCode = fs.readFileSync('client/public/src/main.js', 'utf8');

const emoteAudioReplacement = `
function clearEmoteAudio() {
  const proxy = getCharacterProxy(player.id);
  if (proxy && proxy.activeEmoteAudio) {
    proxy.activeEmoteAudio.fadeOut(500);
    proxy.activeEmoteAudio = null;
  }
}

function clearWalkingAudio() {
  const proxy = getCharacterProxy(player.id);
  if (proxy && proxy.walkingAudio) {
    proxy.walkingAudio.pause();
    proxy.walkingAudio = null;
  }
}
`;

if (mainCode.indexOf('function clearEmoteAudio()') === -1) {
  mainCode = mainCode.replace('function update(dt = 0.016) {', emoteAudioReplacement + '\\nfunction update(dt = 0.016) {');
}

mainCode = mainCode.replace(/if \\(getCharacterProxy\\(player\\.id\\)\\.activeEmoteAudio\\) \\{\\s*getCharacterProxy\\(player\\.id\\)\\.activeEmoteAudio\\.fadeOut\\(500\\);\\s*getCharacterProxy\\(player\\.id\\)\\.activeEmoteAudio = null;\\s*\\}/g, 'clearEmoteAudio();');
mainCode = mainCode.replace(/if \\(getCharacterProxy\\(player\\.id\\)\\.walkingAudio\\) \\{\\s*getCharacterProxy\\(player\\.id\\)\\.walkingAudio\\.pause\\(\\);\\s*getCharacterProxy\\(player\\.id\\)\\.walkingAudio = null;\\s*\\}/g, 'clearWalkingAudio();');

fs.writeFileSync('client/public/src/main.js', mainCode);

// === CLEANUP UI.JS ===
let uiCode = fs.readFileSync('client/public/src/ui.js', 'utf8');

if (uiCode.indexOf('_bindDialog(') === -1) {
  const bindDialogHelper = `  _bindDialog(btnId, dialogId, closeId, onOpen) {
    const btn = document.getElementById(btnId);
    const dialog = document.getElementById(dialogId);
    const closeBtn = document.getElementById(closeId);
    if (!btn || !dialog || !closeBtn) return;
    btn.addEventListener('click', () => {
      if (onOpen) onOpen();
      dialog.style.display = 'flex';
    });
    const hide = () => dialog.style.display = 'none';
    closeBtn.addEventListener('click', hide);
    dialog.addEventListener('click', (e) => { if (e.target === dialog) hide(); });
    window.addEventListener('keydown', (e) => { if (e.key === 'Escape' && dialog.style.display === 'flex') hide(); });
  }

`;
  uiCode = uiCode.replace('  initHelpDialog() {', bindDialogHelper + '  initHelpDialog() {');
}

const helpStart = '  initHelpDialog() {';
const helpEnd = `    }
  }`;
const helpRep = `  initHelpDialog() {
    this._bindDialog('help-button', 'help-dialog', 'close-help-btn');
  }`;
if (uiCode.includes(helpStart) && uiCode.includes('helpBtn.addEventListener') && uiCode.includes(helpEnd)) {
    uiCode = replaceBlock(uiCode, helpStart, helpEnd, helpRep);
}

const badgeStart = '  initBadgesDialog() {';
const badgeEnd = `    }
  }`;
const badgeRep = `  initBadgesDialog() {
    this._bindDialog('badges-button', 'badges-dialog', 'close-badges-btn', () => this.populateBadgesList());
  }`;
if (uiCode.includes(badgeStart) && uiCode.includes('badgesButton.addEventListener') && uiCode.includes(badgeEnd)) {
    uiCode = replaceBlock(uiCode, badgeStart, badgeEnd, badgeRep);
}

const emotesStart = '      emotesButton.addEventListener(\'click\', () => {';
const emotesEnd = `      });
    }`;
const emotesRep = `      this._bindDialog('emotes-button', 'emotes-dialog', 'close-emotes-btn');
    }`;
if (uiCode.includes(emotesStart) && uiCode.includes('emotesDialog.style.display = \'flex\'') && uiCode.includes(emotesEnd)) {
    uiCode = replaceBlock(uiCode, emotesStart, emotesEnd, emotesRep);
}

fs.writeFileSync('client/public/src/ui.js', uiCode);
console.log('Cleanup completed successfully!');
