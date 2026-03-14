export class GameLoop {
  constructor() {
    this.functions = [];
    this.isActive = false;
    this.lastFrameTime = performance.now();
    this.lastFpsUpdate = performance.now();
    this.framesThisSecond = 0;
    this.fpsInterval = 1000 / 60; // Target 60 FPS cap
    this._loopBind = this.loop.bind(this);
  }

  /**
   * Registers a given function to run every update cycle.
   * @param {Function} fn - The function to run.
   */
  registerFunction(fn) {
    if (typeof fn !== 'function') return;
    if (!this.functions.includes(fn)) {
      this.functions.push(fn);
    }
  }

  /**
   * Unregisters a function so it stops running every update cycle.
   * @param {Function} fn - The function to remove.
   */
  unregisterFunction(fn) {
    const idx = this.functions.indexOf(fn);
    if (idx !== -1) {
      this.functions.splice(idx, 1);
    }
  }

  /**
   * Starts the internal `requestAnimationFrame` render loop if it's not already running.
   */
  start() {
    if (this.isActive) return;
    this.isActive = true;
    this.lastFrameTime = performance.now();
    requestAnimationFrame(this._loopBind);
  }

  /**
   * Returns true if the GameLoop is currently active and triggering frames.
   * @returns {boolean} True if active
   */
  isRunning() {
    return this.isActive;
  }

  /**
   * Halts the render loop immediately.
   */
  stop() {
    this.isActive = false;
  }

  /**
   * Internal recursive tick loop evaluating time elapsed against FPS threshold.
   */
  loop() {
    if (!this.isActive) return;

    requestAnimationFrame(this._loopBind);

    const now = performance.now();
    const elapsed = now - this.lastFrameTime;

    if (elapsed > this.fpsInterval) {
      this.lastFrameTime = now - (elapsed % this.fpsInterval);

      this.framesThisSecond++;
      if (now - this.lastFpsUpdate >= 1000) {
        if (window.isAdmin && window.updateAdminFps) {
          window.updateAdminFps(this.framesThisSecond);
        }
        this.framesThisSecond = 0;
        this.lastFpsUpdate = now;
      }

      // Execute all registered functions sequentially
      for (let i = 0; i < this.functions.length; i++) {
        this.functions[i]();
      }
    }
  }
}

export const gameLoop = new GameLoop();
