export class GameLoop {
  constructor() {
    this.functions = [];
    this.postFunctions = [];
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
  registerFunction(fn, isPost = false) {
    if (typeof fn !== 'function') return;
    const targetArr = isPost ? this.postFunctions : this.functions;
    if (!targetArr.includes(fn)) {
      targetArr.push(fn);
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
    const idxPost = this.postFunctions.indexOf(fn);
    if (idxPost !== -1) {
      this.postFunctions.splice(idxPost, 1);
    }
  }

  /**
   * Clears all registered functions from the game loop.
   */
  clear() {
    this.functions = [];
    this.postFunctions = [];
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
    let dt = (now - this.lastFrameTime) / 1000;
    if (dt > 0.1) dt = 0.1; // Cap at 100ms to prevent huge jumps
    this.lastFrameTime = now;

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
      this.functions[i](dt);
    }
    for (let i = 0; i < this.postFunctions.length; i++) {
      this.postFunctions[i](dt);
    }
  }
}

export const gameLoop = new GameLoop();
