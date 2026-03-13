export const audioPool = Array.from({ length: 10 }, () => {
  const audio = new Audio();
  audio.crossOrigin = "anonymous";
  return audio;
});

export let audioCtx = null;
export const audioGainNodes = [];
export let bgGainNode = null;

export const bgAudio = new Audio();
bgAudio.crossOrigin = "anonymous";
bgAudio.loop = true;

let audioUnlocked = false;

export function unlockAudio() {
  if (audioUnlocked) return;
  audioUnlocked = true;

  if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  if (audioCtx.state === 'suspended') audioCtx.resume();

  // Play a tiny silent wav file to unlock the HTML5 Audio context on the document
  const dummySrc = "data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA";
  
  audioPool.forEach((audio, idx) => {
    if (!audioGainNodes[idx]) {
      const source = audioCtx.createMediaElementSource(audio);
      const gainNode = audioCtx.createGain();
      source.connect(gainNode);
      gainNode.connect(audioCtx.destination);
      audioGainNodes[idx] = gainNode;
    }
    audio.src = dummySrc;
    audio.play().catch(() => { });
  });

  if (bgAudio && !bgGainNode) {
    const bgSource = audioCtx.createMediaElementSource(bgAudio);
    bgGainNode = audioCtx.createGain();
    bgSource.connect(bgGainNode);
    bgGainNode.connect(audioCtx.destination);
  }
}

export function playPooledAudio(src, volume = 1) {
  const index = audioPool.findIndex(a => a.paused || a.ended);
  const poolIndex = index !== -1 ? index : 0;
  const available = audioPool[poolIndex];

  available.pause();
  available.src = src;

  if (audioGainNodes[poolIndex]) {
    available.volume = 1;
    audioGainNodes[poolIndex].gain.value = volume;
  } else {
    available.volume = Math.min(1, Math.max(0, volume));
  }

  available.play().catch(e => console.warn("Failed to play pooled sound:", e));
  return available;
}

export function initSound() {
  window.addEventListener('touchstart', unlockAudio, { once: true });
  window.addEventListener('pointerdown', unlockAudio, { once: true });
  window.addEventListener('keydown', unlockAudio, { once: true });
}

window.bgAudio = bgAudio;
window.audioPool = audioPool;
window.playPooledAudio = playPooledAudio;
