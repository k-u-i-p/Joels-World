class SoundManager {
  constructor() {
    this.audioCtx = null;
    this.bgGainNode = null;
    this.unlocked = false;
    this.bufferCache = new Map();
    this.bgSourceNode = null;
    this.currentBgSrc = null;
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

    // Play a silent oscillator to fully unlock the audio context on iOS
    const osc = this.audioCtx.createOscillator();
    const gain = this.audioCtx.createGain();
    gain.gain.value = 0;
    osc.connect(gain);
    gain.connect(this.audioCtx.destination);
    osc.start(0);
    osc.stop(this.audioCtx.currentTime + 0.1);

    if (!this.bgGainNode) {
      this.bgGainNode = this.audioCtx.createGain();
      this.bgGainNode.connect(this.audioCtx.destination);
    }
  }

  async getAudioBuffer(src) {
    if (this.bufferCache.has(src)) {
      return this.bufferCache.get(src);
    }
    try {
      const response = await fetch(src);
      const arrayBuffer = await response.arrayBuffer();
      const audioBuffer = await this.audioCtx.decodeAudioData(arrayBuffer);
      this.bufferCache.set(src, audioBuffer);
      return audioBuffer;
    } catch (e) {
      console.warn("Failed to load audio:", src, e);
      return null;
    }
  }

  playPooled(src, volume = 1) {
    if (!this.audioCtx) return { pause: () => {} };
    if (this.audioCtx.state === 'suspended') this.audioCtx.resume();

    const result = {
      source: null,
      stopped: false,
      pause: function() {
        this.stopped = true;
        if (this.source) {
          try { this.source.stop(); } catch(e){}
        }
      }
    };

    this.getAudioBuffer(src).then(buffer => {
      if (!buffer || result.stopped) return;
      const source = this.audioCtx.createBufferSource();
      source.buffer = buffer;
      const gainNode = this.audioCtx.createGain();
      gainNode.gain.value = Math.max(0, volume);
      source.connect(gainNode);
      gainNode.connect(this.audioCtx.destination);
      source.start();
      result.source = source;
    });

    return result;
  }

  playBackground(src, volume = 1) {
    if (!this.audioCtx) return;
    if (this.audioCtx.state === 'suspended') this.audioCtx.resume();

    if (!this.bgGainNode) {
      this.bgGainNode = this.audioCtx.createGain();
      this.bgGainNode.connect(this.audioCtx.destination);
    }

    if (this.currentBgSrc !== src) {
      if (this.bgSourceNode) {
        try { this.bgSourceNode.stop(); } catch(e){}
        this.bgSourceNode.disconnect();
        this.bgSourceNode = null;
      }
      this.currentBgSrc = src;
      
      this.getAudioBuffer(src).then(buffer => {
        if (!buffer || this.currentBgSrc !== src) return;
        this.bgSourceNode = this.audioCtx.createBufferSource();
        this.bgSourceNode.buffer = buffer;
        this.bgSourceNode.loop = true;
        this.bgSourceNode.connect(this.bgGainNode);
        this.bgSourceNode.start();
      });
    }
    
    this.bgGainNode.gain.value = Math.max(0, volume);
  }

  stopBackground() {
    if (this.bgSourceNode) {
       try { this.bgSourceNode.stop(); } catch(e){}
       this.bgSourceNode.disconnect();
       this.bgSourceNode = null;
    }
    this.currentBgSrc = null;
  }
}

export const soundManager = new SoundManager();

export function initSound() {
  const unlockAudio = () => soundManager.unlock();
  window.addEventListener('touchstart', unlockAudio, { once: true });
  window.addEventListener('touchend', unlockAudio, { once: true });
  window.addEventListener('pointerdown', unlockAudio, { once: true });
  window.addEventListener('click', unlockAudio, { once: true });
  window.addEventListener('keydown', unlockAudio, { once: true });
}

