import { uiManager } from './ui.js';
import { player } from './main.js';

export class InputManager {
  constructor() {
    this.keys = {
      ArrowUp: false,
      ArrowDown: false,
      ArrowLeft: false,
      ArrowRight: false,
      Space: false,
      TouchMove: false
    };

    this.isChatFocused = false;
    this.initKeyboard();
    this.initJoystick();
  }

  isPressed(key) {
    return this.keys[key] || false;
  }

  /**
   * Translates the current active key presses (tank controls or joystick) into
   * an intended X/Y delta movement vector.
   * @param {number} entitySpeed - Base movement speed of the character.
   * @param {number} currentRotation - The character's current rotation in degrees.
   * @returns {Object} An object { dx, dy } representing the movement intent.
   */
  getDemandedMovementVector(entitySpeed, currentRotation) {
    let dx = 0;
    let dy = 0;

    const angleRad = currentRotation * (Math.PI / 180);
    const speed = entitySpeed || 3;

    if (this.keys['TouchMove']) {
      dx += Math.cos(angleRad) * speed;
      dy += Math.sin(angleRad) * speed;
    } else {
      // Keyboard tank controls
      if (this.keys['ArrowUp']) {
        dx += Math.cos(angleRad) * speed;
        dy += Math.sin(angleRad) * speed;
      }
      if (this.keys['ArrowDown']) {
        dx -= Math.cos(angleRad) * speed;
        dy -= Math.sin(angleRad) * speed;
      }
    }

    return { dx, dy };
  }

  initKeyboard() {
    const chatInput = document.getElementById('chat-input');
    if (chatInput) {
      chatInput.addEventListener('focus', () => { this.isChatFocused = true; });
      chatInput.addEventListener('blur', () => { this.isChatFocused = false; });
    }

    window.addEventListener('keydown', (e) => {
      const nameDialog = document.getElementById('name-dialog');
      if (nameDialog && nameDialog.style.display !== 'none') return;

      if (e.code === 'Enter') {
        if (this.isChatFocused) {
          if (chatInput && chatInput.value.trim() !== '') {
            const msg = chatInput.value.trim();
            chatInput.value = '';
            
            // Dispatch custom event for chat submission
            window.dispatchEvent(new CustomEvent('chatSubmit', { detail: { message: msg } }));
          }
          if (chatInput) chatInput.blur();
        } else {
          if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
            return; // Let the input/textarea handle the enter key naturally
          }
          if (chatInput) {
            chatInput.focus();
            e.preventDefault();
          }
        }
        return;
      }

      if (this.isChatFocused || e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

      if (e.code === 'Space') e.preventDefault();

      if (this.keys.hasOwnProperty(e.code)) {
        this.keys[e.code] = true;
      }
    });

    window.addEventListener('keyup', (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
      if (this.keys.hasOwnProperty(e.code)) {
        this.keys[e.code] = false;
      }
    });

    window.addEventListener('blur', () => {
      for (const key in this.keys) {
        this.keys[key] = false;
      }
    });
  }

  initJoystick() {
    const moveContainer = document.getElementById('joystick-move-container');
    const moveKnob = document.getElementById('joystick-move-knob');
    const maxRadius = 40;

    if (!moveContainer || !moveKnob) return;

    let activeTouchId = null;
    let origin = { x: 0, y: 0 };

    const handleStart = (e) => {
      if (activeTouchId !== null) return; // Already active

      let clientX, clientY;
      if (e.changedTouches) {
        const touch = e.changedTouches[0];
        activeTouchId = touch.identifier;
        clientX = touch.clientX;
        clientY = touch.clientY;
      } else {
        activeTouchId = 'mouse';
        clientX = e.clientX;
        clientY = e.clientY;
      }

      const rect = moveContainer.getBoundingClientRect();
      origin = {
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2
      };
      handleMove(e);
    };

    const handleMove = (e) => {
      if (activeTouchId === null) return;
      if (e.cancelable) e.preventDefault();

      let clientX, clientY;
      if (e.changedTouches) {
        let found = false;
        for (let i = 0; i < e.changedTouches.length; i++) {
          if (e.changedTouches[i].identifier === activeTouchId) {
            clientX = e.changedTouches[i].clientX;
            clientY = e.changedTouches[i].clientY;
            found = true;
            break;
          }
        }
        if (!found) return; // This touch isn't ours
      } else {
        clientX = e.clientX;
        clientY = e.clientY;
      }

      const dx = clientX - origin.x;
      const dy = clientY - origin.y;
      const distance = Math.min(maxRadius, Math.hypot(dx, dy));
      const angle = Math.atan2(dy, dx);

      const knobX = distance * Math.cos(angle);
      const knobY = distance * Math.sin(angle);
      moveKnob.style.transform = `translate(${knobX}px, ${knobY}px)`;

      this.keys.TouchMove = false;
      if (distance > 10) {
        this.keys.TouchMove = true;
        // Direct global override for player targeting rotation immediately
        if (player) {
           player.rotation = angle * 180 / Math.PI;
        }
      }
    };

    const handleEnd = (e) => {
      if (activeTouchId === null) return;

      if (e.changedTouches) {
        let found = false;
        for (let i = 0; i < e.changedTouches.length; i++) {
          if (e.changedTouches[i].identifier === activeTouchId) {
            found = true;
            break;
          }
        }
        if (!found) return; // This touch isn't ours
      }

      activeTouchId = null;
      moveKnob.style.transform = `translate(0px, 0px)`;
      this.keys.TouchMove = false;
    };

    moveContainer.addEventListener('mousedown', handleStart);
    window.addEventListener('mousemove', handleMove, { passive: false });
    window.addEventListener('mouseup', handleEnd);

    moveContainer.addEventListener('touchstart', handleStart, { passive: false });
    window.addEventListener('touchmove', handleMove, { passive: false });
    window.addEventListener('touchend', handleEnd);
    window.addEventListener('touchcancel', handleEnd);
  }
}

export const inputManager = new InputManager();
