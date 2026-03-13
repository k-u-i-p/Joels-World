const POOL_SIZE = 10;
const DUMMY_SRC = "data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA";

class SoundManager {
  constructor() {
    this.audioPool = Array.from({ length: POOL_SIZE }, () => {
      const audio = new Audio();
      audio.crossOrigin = "anonymous";
      return audio;
    });

    this.audioCtx = null;
    this.gainNodes = [];
    
    this.bgAudio = new Audio();
    this.bgAudio.crossOrigin = "anonymous";
    this.bgAudio.loop = true;
    this.bgGainNode = null;

    this.unlocked = false;
  }

  unlock() {
    if (this.unlocked) return;
    this.unlocked = true;

    if (!this.audioCtx) {
      this.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    }
    
    if (this.audioCtx.state === 'suspended') {
      this.audioCtx.resume();
    }

    this.audioPool.forEach((audio, idx) => {
      if (!this.gainNodes[idx]) {
        const source = this.audioCtx.createMediaElementSource(audio);
        const gainNode = this.audioCtx.createGain();
        source.connect(gainNode);
        gainNode.connect(this.audioCtx.destination);
        this.gainNodes[idx] = gainNode;
      }
      audio.src = DUMMY_SRC;
      audio.play().catch(() => { });
    });

    if (!this.bgGainNode) {
      const bgSource = this.audioCtx.createMediaElementSource(this.bgAudio);
      this.bgGainNode = this.audioCtx.createGain();
      bgSource.connect(this.bgGainNode);
      this.bgGainNode.connect(this.audioCtx.destination);
    }
  }

  playPooled(src, volume = 1) {
    const index = this.audioPool.findIndex(a => a.paused || a.ended);
    const poolIndex = index !== -1 ? index : 0;
    const audio = this.audioPool[poolIndex];

    audio.pause();
    audio.src = src;

    if (this.gainNodes[poolIndex]) {
      audio.volume = 1;
      this.gainNodes[poolIndex].gain.value = Math.max(0, volume);
    } else {
      audio.volume = Math.max(0, volume); // Clamped if no Web Audio available, depending on browser
    }

    audio.play().catch(e => console.warn("Failed to play pooled sound:", e));
    return audio;
  }

  playBackground(src, volume = 1) {
    if (!this.bgAudio.src.endsWith(src)) {
      this.bgAudio.pause();
      this.bgAudio.src = src;
    }

    if (this.bgGainNode) {
      this.bgAudio.volume = 1;
      this.bgGainNode.gain.value = Math.max(0, volume);
    } else {
      this.bgAudio.volume = Math.max(0, volume);
    }

    this.bgAudio.play().catch(e => console.warn("Failed to play bg sound:", e));
  }

  stopBackground() {
    this.bgAudio.pause();
    this.bgAudio.src = "";
  }
}

export const soundManager = new SoundManager();

export function initSound() {
  const unlockAudio = () => soundManager.unlock();
  window.addEventListener('touchstart', unlockAudio, { once: true });
  window.addEventListener('pointerdown', unlockAudio, { once: true });
  window.addEventListener('keydown', unlockAudio, { once: true });
}

window.soundManager = soundManager;
