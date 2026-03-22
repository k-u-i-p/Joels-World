class SoundManager {
  constructor() {
    this.audioCtx = null;
    this.bgGainNode = null;
    this.unlocked = false;
    this.bufferCache = new Map();
    this.bgSourceNode = null;
    this.currentBgSrc = null;
    
    // Track preloaded native assets
    this.nativeAssets = new Set();
  }

  getNativeAudio() {
    if (window.Capacitor && window.Capacitor.isNativePlatform() && window.Capacitor.Plugins && window.Capacitor.Plugins.NativeAudio) {
      return window.Capacitor.Plugins.NativeAudio;
    }
    return null;
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

  async ensureNativePreloaded(src) {
    const NativeAudio = this.getNativeAudio();
    if (!NativeAudio) return false;

    if (this.nativeAssets.has(src)) return true;

    // Convert to relative asset path (e.g., /media/sound.mp3 -> public/media/sound.mp3)
    let assetPath = src.startsWith('/') ? 'public' + src : 'public/' + src;

    try {
      await NativeAudio.preload({
        assetId: src,
        assetPath: assetPath,
        audioChannelNum: 4,
        isUrl: false
      });
      this.nativeAssets.add(src);
      return true;
    } catch (e) {
      console.warn("Native preloading failed for", src, e);
      return false;
    }
  }

  playPooled(src, volume = 1, loop = false) {
    const NativeAudio = this.getNativeAudio();
    if (NativeAudio) {
      const result = {
        stopped: false,
        rate: 1,
        pause: function() {
          this.stopped = true;
          NativeAudio.stop({ assetId: src }).catch(e => console.warn('NativeAudio stop error:', src, e));
        },
        fadeOut: function(durationMs = 500) {
          this.stopped = true;
          // Native audio lacks fade out, stop after short delay to simulate
          setTimeout(() => {
             NativeAudio.stop({ assetId: src }).catch(e => console.warn('NativeAudio stop error:', src, e));
          }, Math.min(durationMs, 200));
        },
        setRate: function(rate) {
          this.rate = rate; // Not fully supported by typical NativeAudio API without custom plugin tweaks
        }
      };

      this.ensureNativePreloaded(src).then(preloaded => {
        if (!preloaded || result.stopped) return;
        NativeAudio.setVolume({ assetId: src, volume: Math.max(0, volume) }).catch(e => console.warn('NativeAudio stop error:', src, e));
        if (loop) {
          NativeAudio.loop({ assetId: src }).catch(e => console.warn('NativeAudio stop error:', src, e));
        } else {
          NativeAudio.play({ assetId: src }).catch(e => console.warn('NativeAudio stop error:', src, e));
        }
      });

      return result;
    }

    // Web Audio API Fallback
    if (!this.audioCtx) return { pause: () => {}, fadeOut: () => {}, setRate: () => {} };
    if (this.audioCtx.state === 'suspended') this.audioCtx.resume();

    const audioCtx = this.audioCtx;

    const result = {
      source: null,
      gainNode: null,
      stopped: false,
      rate: 1,
      pause: function() {
        this.stopped = true;
        if (this.source) {
          try { this.source.stop(); } catch(e){}
        }
      },
      fadeOut: function(durationMs = 500) {
        this.stopped = true;
        if (this.gainNode && audioCtx) {
          try {
            const currentTime = audioCtx.currentTime;
            this.gainNode.gain.setValueAtTime(this.gainNode.gain.value, currentTime);
            this.gainNode.gain.linearRampToValueAtTime(0, currentTime + (durationMs / 1000));
            if (this.source) {
              this.source.stop(currentTime + (durationMs / 1000));
            }
          } catch(e) {}
        } else {
          this.pause();
        }
      },
      setRate: function(rate) {
        this.rate = rate;
        if (this.source) {
          this.source.playbackRate.value = rate;
        }
      }
    };

    this.getAudioBuffer(src).then(buffer => {
      if (!buffer || result.stopped) return;
      const source = this.audioCtx.createBufferSource();
      source.buffer = buffer;
      source.loop = loop;
      source.playbackRate.value = result.rate;
      const gainNode = this.audioCtx.createGain();
      gainNode.gain.value = Math.max(0, volume);
      source.connect(gainNode);
      gainNode.connect(this.audioCtx.destination);
      source.start();
      result.source = source;
      result.gainNode = gainNode;
    });

    return result;
  }

  playBackground(src, volume = 1) {
    const NativeAudio = this.getNativeAudio();
    if (NativeAudio) {
      if (this.currentBgSrc !== src) {
        if (this.currentBgSrc) {
          NativeAudio.stop({ assetId: this.currentBgSrc }).catch(e=>console.warn('NativeAudio stop bg error:', e));
        }
        this.currentBgSrc = src;
        
        this.ensureNativePreloaded(src).then(preloaded => {
          if (!preloaded || this.currentBgSrc !== src) return;
          NativeAudio.setVolume({ assetId: src, volume: Math.max(0, volume) }).catch(e=>console.warn('NativeAudio volume error:', e));
          NativeAudio.loop({ assetId: src }).catch(e=>console.warn('NativeAudio loop error:', e));
        });
      } else {
        NativeAudio.setVolume({ assetId: src, volume: Math.max(0, volume) }).catch(e=>console.warn('NativeAudio volume error:', e));
      }
      return;
    }

    // Web Audio API Fallback
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
    const NativeAudio = this.getNativeAudio();
    if (NativeAudio && this.currentBgSrc) {
      NativeAudio.stop({ assetId: this.currentBgSrc }).catch(e=>console.warn('NativeAudio stop bg error:', e));
      this.currentBgSrc = null;
      return;
    }

    // Web Audio API Fallback
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
