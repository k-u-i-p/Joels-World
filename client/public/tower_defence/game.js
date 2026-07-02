// Game constants and configuration
const CANVAS_WIDTH = 800;
const CANVAS_HEIGHT = 600;
const TILE_SIZE = 40;

const GAME_STATE = {
    MENU: 0,
    PLAYING: 1,
    GAME_OVER: 2,
    WIN: 3
};

// Minion types definition
const MINION_TYPES = {
    DYNAMITER: { name: 'Dynamiter', cost: 10, range: 100, damage: 10, fireRate: 60, color: '#e74c3c', effect: 'splash', splashRadius: 50 },
    BUFF_MONSTER: { name: 'Buff Monster', cost: 20, range: 80, damage: 25, fireRate: 90, color: '#8e44ad', effect: 'none' },
    WATER_MAN: { name: 'Water Man', cost: 30, range: 120, damage: 15, fireRate: 45, color: '#3498db', effect: 'slow' },
    FIRE_MAN: { name: 'Fire Man', cost: 40, range: 100, damage: 30, fireRate: 60, color: '#d35400', effect: 'none' },
    LEAF_MAN: { name: 'Leaf Man', cost: 50, range: 150, damage: 20, fireRate: 40, color: '#2ecc71', effect: 'none' },
    MECHA_ROBOT: { name: 'Mecha Robot', cost: 75, range: 180, damage: 40, fireRate: 30, color: '#95a5a6', effect: 'none' },
    JET_TANK: { name: 'Jet Tank', cost: 100, range: 200, damage: 100, fireRate: 120, color: '#f1c40f', effect: 'splash', splashRadius: 80 }
};

class Game {
    constructor() {
        this.canvas = document.getElementById('game-canvas');
        this.ctx = this.canvas.getContext('2d');
        
        // UI Elements
        this.moneyDisplay = document.getElementById('money-display');
        this.livesDisplay = document.getElementById('lives-display');
        this.waveDisplay = document.getElementById('wave-display');
        this.shopContainer = document.getElementById('shop');
        this.startWaveBtn = document.getElementById('start-wave-btn');
        this.restartBtn = document.getElementById('restart-btn');
        this.codeBtn = document.getElementById('code-btn');
        this.gameOverOverlay = document.getElementById('game-over-overlay');
        
        this.apocalypseContainer = document.getElementById('apocalypse-container');
        this.apocalypseTime = document.getElementById('apocalypse-time');
        
        // Setup Apocalypse Clock
        setInterval(() => {
            if (this.wave > 23 && this.apocalypseTime) {
                const now = new Date();
                this.apocalypseTime.textContent = now.toTimeString().split(' ')[0]; // HH:MM:SS
            }
        }, 1000);
        
        // Upgrade UI
        this.upgradePanel = document.getElementById('upgrade-panel');
        this.upgradeOptions = document.getElementById('upgrade-options');
        this.closeUpgradeBtn = document.getElementById('close-upgrade-btn');
        this.sellMinionBtn = document.getElementById('sell-minion-btn');
        
        // Game State
        this.state = GAME_STATE.PLAYING;
        this.money = 50;
        this.lives = 20;
        this.wave = 1;
        
        // Entities
        this.minions = [];
        this.flyingAllies = [];
        this.enemies = [];
        this.projectiles = [];
        this.enemyProjectiles = [];
        
        // Path (Black line)
        this.path = [
            {x: 0, y: 100},
            {x: 200, y: 100},
            {x: 200, y: 300},
            {x: 600, y: 300},
            {x: 600, y: 500},
            {x: 800, y: 500}
        ];
        
        // Interaction
        this.selectedMinionType = null;
        this.selectedPlacedMinion = null;
        this.mouseX = 0;
        this.mouseY = 0;
        
        // Rendering variables
        this.lastTime = 0;
        
        this.init();
    }
    
    init() {
        this.setupEventListeners();
        this.buildShop();
        this.updateUI();
        
        // Start game loop
        requestAnimationFrame((timestamp) => this.gameLoop(timestamp));
    }
    
    setupEventListeners() {
        // Mouse movement for hover effects/placement preview
        this.canvas.addEventListener('mousemove', (e) => {
            const rect = this.canvas.getBoundingClientRect();
            this.mouseX = e.clientX - rect.left;
            this.mouseY = e.clientY - rect.top;
        });
        
        // Canvas click for placing or selecting minions
        this.canvas.addEventListener('click', (e) => {
            // Check if clicking on an existing minion
            const clickedMinion = this.getMinionAt(this.mouseX, this.mouseY);
            
            if (clickedMinion) {
                // Select minion for upgrade
                this.selectedPlacedMinion = clickedMinion;
                this.showUpgradePanel();
                this.selectedMinionType = null; // Cancel shop selection
                document.querySelectorAll('.shop-item').forEach(el => el.classList.remove('selected'));
                return;
            }
            
            // If we click empty space, place minion or close panel
            if (this.selectedMinionType) {
                this.placeMinion();
            } else if (!this.selectedPlacedMinion) {
                this.hideUpgradePanel(); // clicking away cancels upgrade view
            }
        });
        
        // Start Wave button
        this.startWaveBtn.addEventListener('click', () => {
            this.spawnWave();
        });
        
        // Upgrade Panel buttons
        this.closeUpgradeBtn.addEventListener('click', () => this.hideUpgradePanel());
        this.sellMinionBtn.addEventListener('click', () => this.sellSelectedMinion());
        
        // Restart Button
        this.restartBtn.addEventListener('click', () => this.restartGame());
        
        // Code Button
        this.codeBtn.addEventListener('click', () => {
            const answer = prompt("What is the code?");
            if (answer === "67CODE25Vmoney") {
                this.wave = 24;
                this.money = 5000;
                this.updateUI();
                alert("Cheat code activated! Wave advanced to 24 and money set to £5000.");
            } else if (answer !== null) {
                alert("Incorrect code.");
            }
        });
    }
    
    restartGame() {
        // Reset Game State
        this.state = GAME_STATE.PLAYING;
        this.money = 50;
        this.lives = 20;
        this.wave = 1;
        
        // Clear Entities
        this.minions = [];
        this.flyingAllies = [];
        this.enemies = [];
        this.projectiles = [];
        this.enemyProjectiles = [];
        
        // Reset Win Overlay
        const gameOverText = document.getElementById('game-over-text');
        if (gameOverText) gameOverText.textContent = 'Game Over!';
        
        // Reset Interaction
        this.selectedMinionType = null;
        this.selectedPlacedMinion = null;
        
        // Update UI
        this.hideUpgradePanel();
        this.gameOverOverlay.classList.add('hidden');
        document.querySelectorAll('.shop-item').forEach(el => el.classList.remove('selected'));
        
        this.updateUI();
    }
    
    getMinionAt(x, y) {
        // Look backwards so we click top-most if overlap
        for (let i = this.minions.length - 1; i >= 0; i--) {
            const m = this.minions[i];
            const dist = Math.hypot(m.x - x, m.y - y);
            if (dist <= 15) { // 15 is minion draw radius
                return m;
            }
        }
        return null;
    }
    
    showUpgradePanel() {
        if (!this.selectedPlacedMinion) return;
        
        this.shopContainer.classList.add('hidden');
        this.upgradePanel.classList.remove('hidden');
        
        this.buildUpgradeOptions();
    }
    
    hideUpgradePanel() {
        this.selectedPlacedMinion = null;
        this.shopContainer.classList.remove('hidden');
        this.upgradePanel.classList.add('hidden');
    }
    
    buildUpgradeOptions() {
        if (!this.selectedPlacedMinion) return;
        
        this.upgradeOptions.innerHTML = '';
        const m = this.selectedPlacedMinion;
        
        const upgrades = [
            { 
                id: 'range', name: 'Range Increase', desc: '+50% Range', cost: 20,
                apply: () => { m.info.range *= 1.5; m.upgrades.range++; }
            },
            { 
                id: 'fireRate', name: 'Rapid Fire', desc: 'Shoots 30% faster', cost: 25,
                apply: () => { m.info.fireRate *= 0.7; m.upgrades.fireRate++; }
            },
            { 
                id: 'damage', name: 'Damage Boost', desc: '+50% Damage', cost: 30,
                apply: () => { m.info.damage *= 1.5; m.upgrades.damage++; }
            }
        ];
        
        upgrades.forEach(upg => {
            const currentLevel = m.upgrades[upg.id];
            // Scale cost per level
            const actualCost = Math.floor(upg.cost * Math.pow(1.5, currentLevel));
            
            const item = document.createElement('div');
            item.className = 'upgrade-item';
            if (this.money < actualCost) {
                item.classList.add('disabled');
            }
            
            item.innerHTML = `
                <div style="display: flex; justify-content: space-between;">
                    <span class="upgrade-title">${upg.name} (Lvl ${currentLevel})</span>
                    <span class="item-cost">£${actualCost}</span>
                </div>
                <div class="upgrade-desc">${upg.desc}</div>
            `;
            
            item.addEventListener('click', () => {
                if (this.money >= actualCost) {
                    this.money -= actualCost;
                    upg.apply();
                    this.updateUI();
                    this.buildUpgradeOptions(); // Refresh costs
                }
            });
            
            this.upgradeOptions.appendChild(item);
        });
    }
    
    sellSelectedMinion() {
        if (!this.selectedPlacedMinion) return;
        
        const m = this.selectedPlacedMinion;
        let totalInvestment = m.info.cost; // Add upgrade costs later if we track total spent
        this.money += Math.floor(totalInvestment * 0.5);
        
        const index = this.minions.indexOf(m);
        if (index > -1) {
            this.minions.splice(index, 1);
        }
        
        this.updateUI();
        this.hideUpgradePanel();
    }
    
    buildShop() {
        this.shopContainer.innerHTML = '';
        
        Object.keys(MINION_TYPES).forEach(key => {
            const minion = MINION_TYPES[key];
            const item = document.createElement('div');
            item.className = 'shop-item';
            item.dataset.type = key;
            
            item.innerHTML = `
                <div class="item-name">${minion.name}</div>
                <div class="item-cost">£${minion.cost}</div>
            `;
            
            item.addEventListener('click', () => {
                if (this.money >= minion.cost) {
                    // Deselect previous
                    document.querySelectorAll('.shop-item').forEach(el => el.classList.remove('selected'));
                    
                    if (this.selectedMinionType === key) {
                        this.selectedMinionType = null; // Toggle off
                        item.classList.remove('selected');
                    } else {
                        item.classList.add('selected');
                        this.selectedMinionType = key;
                        // Hide upgrade panel if open
                        this.hideUpgradePanel();
                    }
                }
            });
            
            this.shopContainer.appendChild(item);
        });
        
        this.updateShopAvailability();
    }
    
    updateShopAvailability() {
        document.querySelectorAll('.shop-item').forEach(item => {
            const type = item.dataset.type;
            const cost = MINION_TYPES[type].cost;
            if (this.money < cost) {
                item.classList.add('disabled');
                if (this.selectedMinionType === type) {
                    this.selectedMinionType = null;
                    item.classList.remove('selected');
                }
            } else {
                item.classList.remove('disabled');
            }
        });
        
        // Update upgrade panel if open
        if (this.selectedPlacedMinion && !this.upgradePanel.classList.contains('hidden')) {
            this.buildUpgradeOptions();
        }
    }
    
    updateUI() {
        if (this.moneyDisplay) this.moneyDisplay.textContent = '£' + this.money;
        if (this.livesDisplay) this.livesDisplay.textContent = this.lives;
        if (this.waveDisplay) this.waveDisplay.textContent = this.wave;
        this.updateShopAvailability();
        
        if (this.apocalypseContainer) {
            if (this.wave > 23) {
                this.apocalypseContainer.classList.remove('hidden');
            } else {
                this.apocalypseContainer.classList.add('hidden');
            }
        }
    }
    
    placeMinion() {
        if (!this.selectedMinionType) return;
        
        const typeInfo = MINION_TYPES[this.selectedMinionType];
        
        // Snap to grid
        const gridX = Math.floor(this.mouseX / TILE_SIZE) * TILE_SIZE + TILE_SIZE / 2;
        const gridY = Math.floor(this.mouseY / TILE_SIZE) * TILE_SIZE + TILE_SIZE / 2;
        
        // Simple collision: check distance to path segments
        let isOnPath = false;
        for (let i = 0; i < this.path.length - 1; i++) {
            const p1 = this.path[i];
            const p2 = this.path[i+1];
            // distance from point (gridX, gridY) to line segment (p1, p2)
            const l2 = Math.pow(p1.x - p2.x, 2) + Math.pow(p1.y - p2.y, 2);
            let t = ((gridX - p1.x) * (p2.x - p1.x) + (gridY - p1.y) * (p2.y - p1.y)) / l2;
            t = Math.max(0, Math.min(1, t));
            const projX = p1.x + t * (p2.x - p1.x);
            const projY = p1.y + t * (p2.y - p1.y);
            const dist = Math.hypot(gridX - projX, gridY - projY);
            
            if (dist < 40) { // Keep away from path edges
                isOnPath = true;
                break;
            }
        }
        
        let hasMinion = this.minions.some(m => m.x === gridX && m.y === gridY);
        
        if (this.money >= typeInfo.cost && !isOnPath && !hasMinion) {
            this.money -= typeInfo.cost;
            this.minions.push(new Minion(gridX, gridY, this.selectedMinionType));
            this.updateUI();
            
            // Do not immediately deselect shop item so they can place multiple!
            // Just let them keep clicking. If they run out of money, buildShop/updateShopAvailability disables it.
        }
    }
    
    spawnWave() {
        if (this.spawningWave) return; // Prevent multiple waves spawning at once
        
        this.spawningWave = true;
        this.spawnIntervalCleared = false;
        
        let count = 0;
        const currentWave = this.wave;
        const totalEnemies = 5 + currentWave * 2;
        
        // Convert placed Jet Tanks into Flying Jet Tanks
        const placedJetTanks = this.minions.filter(m => m.type === 'JET_TANK');
        this.minions = this.minions.filter(m => m.type !== 'JET_TANK'); // Remove them from map
        
        for (let i = 0; i < placedJetTanks.length; i++) {
            const tank = placedJetTanks[i];
            this.flyingAllies.push(new FlyingJetTank(tank.x, tank.y));
        }
        
        // Base stats configuration for the wave
        let baseHp = 50 + (currentWave * 15);
        
        // Bonus HP for waves 25, 26, 27 (keep this for consistency if requested previously, though the prompt didn't explicitly ask to remove it, it asked for jets strictly > 23)
        if (currentWave === 25 || currentWave === 26 || currentWave === 27) {
            baseHp += 50;
        }

        if (currentWave > 23) {
            // Spawn 5 Enemy Jets every round past wave 23
            for (let i = 0; i < 5; i++) {
                this.enemies.push(new EnemyFlyingJet(-50, -50));
            }
            
            // Still spawn the flying phoenix for the player
            this.flyingAllies.push(new FlyingPhoenix(-50, -50));
            
            // Keep the 6 bosses specific to wave 25 as a special event
            if (currentWave === 25) {
                for (let i = 0; i < 6; i++) {
                    // baseHp passed is 1000 (Boss multiplies by 5 = 5000 HP)
                    let boss = new Boss(this.path, 1000, i + 1);
                    boss.speed *= 1.5; // Make them faster
                    setTimeout(() => {
                        this.enemies.push(boss);
                    }, i * 2000);
                }
            }
        }
        
        // Start the spawn interval
        
        const spawnInterval = setInterval(() => {
            if (count >= totalEnemies) {
                clearInterval(spawnInterval);
                this.spawnIntervalCleared = true;
                this.spawningWave = false;
                
                // Spawn Boss at the end of the wave
                if (currentWave % 4 === 0) {
                    setTimeout(() => {
                        this.spawnBoss(currentWave);
                    }, 1500);
                }
                return;
            }
            
            // Randomize enemy type based on wave
            let type = 'normal';
            const rand = Math.random();
            if (currentWave > 2) {
                if (rand > 0.8) type = 'tank';
                else if (rand > 0.6) type = 'fast';
            }
            
            this.enemies.push(new Enemy(this.path, baseHp, type));
            count++;
        }, 1000); // 1 enemy per second
        
        this.wave++;
        this.updateUI();
    }
    
    spawnBoss(waveNum) {
        // Bosses spawn every 4 waves
        const spawnCount = Math.floor(waveNum / 4);
        
        let targetHp = spawnCount * 50;
        if (waveNum > 23) {
            targetHp = 5000;
        }
        
        const baseHp = targetHp / 5; // Boss constructor multiplies baseHp by 5
        let boss = new Boss(this.path, baseHp, spawnCount);
        
        if (waveNum > 23) {
            boss.speed *= 1.5; // Make them faster
        }
        
        this.enemies.push(boss);
    }
    
    drawPath() {
        this.ctx.beginPath();
        this.ctx.strokeStyle = '#000000'; // Black line
        this.ctx.lineWidth = 30; // Thicker line for enemies to walk on
        this.ctx.lineCap = 'round';
        this.ctx.lineJoin = 'round';
        
        for (let i = 0; i < this.path.length; i++) {
            if (i === 0) {
                this.ctx.moveTo(this.path[i].x, this.path[i].y);
            } else {
                this.ctx.lineTo(this.path[i].x, this.path[i].y);
            }
        }
        
        this.ctx.stroke();
        
        // Optional: draw inner line for visual flair
        this.ctx.beginPath();
        this.ctx.strokeStyle = '#222222';
        this.ctx.lineWidth = 20;
        this.ctx.lineCap = 'round';
        this.ctx.lineJoin = 'round';
        
        for (let i = 0; i < this.path.length; i++) {
            if (i === 0) {
                this.ctx.moveTo(this.path[i].x, this.path[i].y);
            } else {
                this.ctx.lineTo(this.path[i].x, this.path[i].y);
            }
        }
        
        this.ctx.stroke();
    }
    
    drawPlacementPreview() {
        if (this.selectedMinionType) {
            const typeInfo = MINION_TYPES[this.selectedMinionType];
            const gridX = Math.floor(this.mouseX / TILE_SIZE) * TILE_SIZE + TILE_SIZE / 2;
            const gridY = Math.floor(this.mouseY / TILE_SIZE) * TILE_SIZE + TILE_SIZE / 2;
            
            // Draw range circle
            this.ctx.beginPath(); // MISSING BEGIN PATH
            this.ctx.arc(gridX, gridY, typeInfo.range, 0, Math.PI * 2);
            // Check viability for red tint
            let isOnPath = false;
            for (let i = 0; i < this.path.length - 1; i++) {
                const p1 = this.path[i]; const p2 = this.path[i+1];
                const l2 = Math.pow(p1.x - p2.x, 2) + Math.pow(p1.y - p2.y, 2);
                let t = Math.max(0, Math.min(1, ((gridX - p1.x) * (p2.x - p1.x) + (gridY - p1.y) * (p2.y - p1.y)) / l2));
                if (Math.hypot(gridX - (p1.x + t*(p2.x-p1.x)), gridY - (p1.y + t*(p2.y-p1.y))) < 40) { isOnPath = true; break; }
            }
            let hasMinion = this.minions.some(m => m.x === gridX && m.y === gridY);
            
            this.ctx.fillStyle = (isOnPath || hasMinion) ? 'rgba(255, 0, 0, 0.2)' : 'rgba(255, 255, 255, 0.2)';
            this.ctx.fill();
            this.ctx.strokeStyle = (isOnPath || hasMinion) ? 'rgba(255, 0, 0, 0.5)' : 'rgba(255, 255, 255, 0.5)';
            this.ctx.stroke();
            
            // Draw outline of minion
            this.ctx.beginPath();
            this.ctx.arc(gridX, gridY, 15, 0, Math.PI * 2);
            this.ctx.fillStyle = typeInfo.color + '88'; // semi-transparent
            this.ctx.fill();
        }
        
        if (this.selectedPlacedMinion) {
            // Draw range circle for selected placed minion
            this.ctx.beginPath();
            this.ctx.arc(this.selectedPlacedMinion.x, this.selectedPlacedMinion.y, this.selectedPlacedMinion.info.range, 0, Math.PI * 2);
            this.ctx.fillStyle = 'rgba(52, 152, 219, 0.2)';
            this.ctx.fill();
            this.ctx.strokeStyle = 'rgba(52, 152, 219, 0.8)';
            this.ctx.lineWidth = 1;
            this.ctx.setLineDash([5, 5]);
            this.ctx.stroke();
            this.ctx.setLineDash([]);
            
            // Highlight minion
            this.ctx.beginPath();
            this.ctx.arc(this.selectedPlacedMinion.x, this.selectedPlacedMinion.y, 18, 0, Math.PI * 2);
            this.ctx.strokeStyle = '#3498db';
            this.ctx.lineWidth = 2;
            this.ctx.stroke();
        }
    }
    
    update(deltaTime) {
        if (this.state !== GAME_STATE.PLAYING) return;
        
        // Update enemies
        for (let i = this.enemies.length - 1; i >= 0; i--) {
            const enemy = this.enemies[i];
            enemy.update(deltaTime, this); // Pass 'this' (Game) for certain boss abilities
            
            // Check if reached end
            if (enemy.reachedEnd) {
                // Bosses deal more damage to lives
                this.lives -= (enemy.isBoss ? 5 : 1);
                this.updateUI();
                this.enemies.splice(i, 1);
                
                if (this.lives <= 0) {
                    this.state = GAME_STATE.GAME_OVER;
                    this.gameOverOverlay.classList.remove('hidden');
                    if (window.parent !== window) window.parent.postMessage('td_lose', '*');
                }
            } else if (enemy.hp <= 0) {
                // Enemy died
                if (enemy.onDeath) {
                    enemy.onDeath(this); // Trigger special death abilities
                }
                
                this.money += enemy.reward; 
                this.updateUI();
                this.enemies.splice(i, 1);
            }
        }
        
        // Update minions
        for (let i = this.minions.length - 1; i >= 0; i--) {
            const minion = this.minions[i];
            if (minion.hp <= 0) {
                if (this.selectedPlacedMinion === minion) {
                    this.hideUpgradePanel();
                }
                this.minions.splice(i, 1);
                continue;
            }
            minion.update(this.enemies, this.projectiles);
        }
        
        // Update flying allies
        for (let i = this.flyingAllies.length - 1; i >= 0; i--) {
            const ally = this.flyingAllies[i];
            
            // Check if ally died
            if (ally.hp <= 0) {
                this.flyingAllies.splice(i, 1);
                continue;
            }
            
            ally.update(deltaTime, this.enemies, this.projectiles);
            
            // Flying allies now stay forever and do not despawn when wave ends
            // (Despawn logic removed)
        }
        
        // Update Projectiles
        for (let i = this.projectiles.length - 1; i >= 0; i--) {
            const proj = this.projectiles[i];
            proj.update(this.enemies);
            
            if (proj.hasHit) {
                // Handle splash effects visually if needed (could add a particle system here later)
                this.projectiles.splice(i, 1);
            }
        }
        
        // Update Enemy Projectiles
        for (let i = this.enemyProjectiles.length - 1; i >= 0; i--) {
            const proj = this.enemyProjectiles[i];
            proj.update();
            if (proj.hasHit) {
                this.enemyProjectiles.splice(i, 1);
            }
        }
        
        // Check Win Condition (Wave 27 completed)
        // Since this.wave increments right after spawnWave is called, 
        // finishing wave 27 means this.wave is 28 and enemies array is empty
        if (this.wave > 27 && this.enemies.length === 0 && this.spawnIntervalCleared) {
            this.state = GAME_STATE.WIN;
            const gameOverText = document.getElementById('game-over-text');
            if (gameOverText) gameOverText.textContent = 'You Win!';
            this.gameOverOverlay.classList.remove('hidden');
            if (window.parent !== window) window.parent.postMessage('td_win', '*');
        }
    }
    
    draw() {
        // Clear canvas
        this.ctx.clearRect(0, 0, CANVAS_WIDTH, CANVAS_HEIGHT);
        
        // Draw Map/Path
        this.drawPath();
        
        // Draw entities
        this.minions.forEach(minion => minion.draw(this.ctx));
        this.enemies.forEach(enemy => enemy.draw(this.ctx));
        this.flyingAllies.forEach(ally => ally.draw(this.ctx));
        this.projectiles.forEach(proj => proj.draw(this.ctx));
        this.enemyProjectiles.forEach(proj => proj.draw(this.ctx));
        
        // Draw UI overlay
        this.drawPlacementPreview();
    }
    
    gameLoop(timestamp) {
        let deltaTime = timestamp - this.lastTime;
        this.lastTime = timestamp;
        
        // Cap deltaTime to avoid massive jumps when tabbing out
        if (deltaTime > 100) deltaTime = 16;
        
        this.update(deltaTime);
        this.draw();
        
        requestAnimationFrame((ts) => this.gameLoop(ts));
    }
}

// Entity Classes Placeholder - will implement fully later
class Enemy {
    constructor(path, hp, type = 'normal') {
        this.path = path;
        this.waypointIndex = 0;
        this.x = path[0].x;
        this.y = path[0].y;
        this.type = type; // normal, fast, tank
        this.isBoss = false;
        
        this.hp = hp;
        this.baseSpeed = 0.05; // pixels per ms
        
        // Apply type modifers
        if (this.type === 'fast') {
            this.hp = hp * 0.6;
            this.baseSpeed = 0.08;
        } else if (this.type === 'tank') {
            this.hp = hp * 2.0;
            this.baseSpeed = 0.03;
        }
        
        this.maxHp = this.hp;
        // Reward lowered from hp / 10 to hp / 20
        this.reward = Math.max(1, Math.floor(this.hp / 20)); 
        this.speed = this.baseSpeed;
        this.slowTimer = 0;
        this.reachedEnd = false;
        this.untargetable = false; // Used by some bosses
        this.damageReduction = 0; // Used by some bosses
        
        // Aim for next waypoint immediately
        this.targetX = path[1].x;
        this.targetY = path[1].y;
    }
    
    takeDamage(amount) {
        this.hp -= (amount * (1 - this.damageReduction));
    }
    
    update(deltaTime, gameObj) {
        // Handle Slow Effect
        if (this.slowTimer > 0) {
            this.slowTimer -= deltaTime;
            this.speed = this.baseSpeed * 0.5;
        } else {
            this.speed = this.baseSpeed;
        }
        
        const dx = this.targetX - this.x;
        const dy = this.targetY - this.y;
        const distance = Math.hypot(dx, dy);
        
        const moveDist = this.speed * deltaTime;
        
        if (distance < moveDist) {
            // Reached waypoint
            this.x = this.targetX;
            this.y = this.targetY;
            this.waypointIndex++;
            
            if (this.waypointIndex >= this.path.length - 1) {
                this.reachedEnd = true;
            } else {
                this.targetX = this.path[this.waypointIndex + 1].x;
                this.targetY = this.path[this.waypointIndex + 1].y;
            }
        } else {
            // Move towards waypoint
            this.x += (dx / distance) * moveDist;
            this.y += (dy / distance) * moveDist;
        }
    }
    
    draw(ctx) {
        if (this.untargetable) {
            ctx.globalAlpha = 0.3; // Phantom boss effect
        }
        
        // Shadow
        ctx.beginPath();
        ctx.ellipse(this.x, this.y + 8, 12, 6, 0, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(0, 0, 0, 0.4)';
        ctx.fill();

        // Draw Enemy
        ctx.beginPath();
        ctx.arc(this.x, this.y, 10, 0, Math.PI * 2);
        
        // If slowed, add icy tint
        let baseColor = '#e74c3c'; // normal
        if (this.type === 'fast') baseColor = '#f39c12';
        else if (this.type === 'tank') baseColor = '#7f8c8d';
        
        ctx.fillStyle = this.slowTimer > 0 ? '#74b9ff' : baseColor;
        ctx.fill();
        ctx.strokeStyle = this.slowTimer > 0 ? '#0984e3' : '#c0392b';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        // Internal body
        ctx.beginPath();
        ctx.arc(this.x, this.y, 5, 0, Math.PI * 2);
        ctx.fillStyle = this.slowTimer > 0 ? '#0984e3' : '#800000';
        ctx.fill();
        
        // Health bar background
        ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
        ctx.fillRect(this.x - 15, this.y - 20, 30, 4);
        
        // Health bar
        const hpPercent = Math.max(0, this.hp / this.maxHp);
        ctx.fillStyle = hpPercent > 0.5 ? '#2ecc71' : hpPercent > 0.2 ? '#f1c40f' : '#e74c3c';
        ctx.fillRect(this.x - 15, this.y - 20, 30 * hpPercent, 4);
        
        ctx.globalAlpha = 1.0;
    }
}

class Boss extends Enemy {
    constructor(path, baseHp, bossLevel) {
        super(path, baseHp * 5, 'boss'); // Bosses have 5x base HP
        this.isBoss = true;
        this.bossLevel = bossLevel;
        this.bossIndex = (bossLevel % 10) === 0 ? 10 : (bossLevel % 10);
        this.reward = Math.max(10, Math.floor(this.maxHp / 10)); // Bosses give better rewards
        
        this.abilityTimer = 0;
        
        // Boss 1: Speed Demon
        if (this.bossIndex === 1) {
            this.baseSpeed = 0.12 + (bossLevel * 0.005);
        }
        // Boss 2: Armored Behemoth
        else if (this.bossIndex === 2) {
            this.damageReduction = Math.min(0.5 + (bossLevel * 0.02), 0.9); // Max 90% dmg reduction
            this.hp = this.hp * (1.5 + (bossLevel * 0.2));
            this.maxHp = this.hp;
            this.baseSpeed = 0.03;
        }
        // Boss 8: Juggernaut
        else if (this.bossIndex === 8) {
            this.hp = this.hp * (3.0 + (bossLevel * 0.5)); // Massive health
            this.maxHp = this.hp;
            this.baseSpeed = 0.02;
        }
    }
    
    update(deltaTime, gameObj) {
        super.update(deltaTime, gameObj);
        
        this.abilityTimer += deltaTime;
        
        // Boss 3: Regenerator
        if (this.bossIndex === 3) {
            const healInterval = Math.max(200, 1000 - (this.bossLevel * 50)); // Heals faster
            if (this.abilityTimer > healInterval) {
                const healPercent = Math.min(0.02 + (this.bossLevel * 0.005), 0.1);
                this.hp = Math.min(this.maxHp, this.hp + (this.maxHp * healPercent));
                this.abilityTimer = 0;
            }
        }
        // Boss 4: Sprinter (Dash)
        else if (this.bossIndex === 4) {
            const dashInterval = Math.max(1000, 3000 - (this.bossLevel * 100)); // Dashes more often
            if (this.abilityTimer > dashInterval) {
                const skipAmount = Math.min(0.2 + (this.bossLevel * 0.02), 0.8);
                this.x += (this.targetX - this.x) * skipAmount;
                this.y += (this.targetY - this.y) * skipAmount;
                this.abilityTimer = 0;
            }
        }
        // Boss 6: Shield Breaker
        else if (this.bossIndex === 6) {
            const disableInterval = Math.max(1000, 4000 - (this.bossLevel * 150));
            if (this.abilityTimer > disableInterval) {
                let nearest = null;
                let minDist = Infinity;
                gameObj.minions.forEach(m => {
                    const d = Math.hypot(m.x - this.x, m.y - this.y);
                    if (d < minDist) {
                        minDist = d;
                        nearest = m;
                    }
                });
                if (nearest) {
                    nearest.cooldown = 300 + (this.bossLevel * 50); // Disable duration increases
                }
                this.abilityTimer = 0;
            }
        }
        // Boss 7: Phantom
        else if (this.bossIndex === 7) {
            // Toggle every 2s, but stays solid for less time higher the level
            const solidTime = Math.max(500, 2000 - (this.bossLevel * 100));
            const phantomTime = 2000 + (this.bossLevel * 200);
            
            if (this.untargetable && this.abilityTimer > phantomTime) {
                this.untargetable = false;
                this.abilityTimer = 0;
            } else if (!this.untargetable && this.abilityTimer > solidTime) {
                this.untargetable = true;
                this.abilityTimer = 0;
            }
        }
        // Boss 9: Teleporter
        else if (this.bossIndex === 9) {
            const blinkInterval = Math.max(1000, 5000 - (this.bossLevel * 200));
            if (this.abilityTimer > blinkInterval) {
                this.x = this.targetX; 
                this.y = this.targetY;
                this.abilityTimer = 0;
            }
        }
    }
    
    onDeath(gameObj) {
        // Boss 5: Summoner
        if (this.bossIndex === 5) {
            const spawnCount = 2 + Math.floor(this.bossLevel / 2);
            for (let i = 0; i < spawnCount; i++) {
                const sp = new Enemy(this.path, this.maxHp * 0.2, 'fast');
                sp.x = this.x + (Math.random() * 20 - 10);
                sp.y = this.y + (Math.random() * 20 - 10);
                sp.waypointIndex = this.waypointIndex;
                sp.targetX = this.targetX; sp.targetY = this.targetY;
                gameObj.enemies.push(sp);
            }
        }
        // Boss 10: The Overlord
        else if (this.bossIndex === 10) {
            const spawnCount = 3 + this.bossLevel;
            for (let i = 0; i < spawnCount; i++) {
                const sp = new Enemy(this.path, this.maxHp * 0.1, 'tank');
                sp.x = this.x + (Math.random() * 20 - 10);
                sp.y = this.y + (Math.random() * 20 - 10);
                sp.waypointIndex = this.waypointIndex;
                sp.targetX = this.targetX; sp.targetY = this.targetY;
                gameObj.enemies.push(sp);
            }
        }
    }
    
    draw(ctx) {
        if (this.untargetable) {
            ctx.globalAlpha = 0.3; // Phantom boss effect
        }
        
        ctx.beginPath();
        // Bosses get slightly bigger with level, capped
        const baseRadius = Math.min(20 + this.bossLevel, 35);
        ctx.arc(this.x, this.y, baseRadius, 0, Math.PI * 2); 
        ctx.fillStyle = '#8e44ad'; // Purple boss hue
        
        // Add specific visual flair based on index
        if (this.bossIndex === 1) ctx.fillStyle = '#f39c12';
        if (this.bossIndex === 2) ctx.fillStyle = '#2c3e50';
        
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 3;
        ctx.stroke();
        
        // Health bar background
        ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
        ctx.fillRect(this.x - 20, this.y - 30, 40, 6);
        
        // Health bar
        const hpPercent = Math.max(0, this.hp / this.maxHp);
        ctx.fillStyle = '#e74c3c';
        ctx.fillRect(this.x - 20, this.y - 30, 40 * hpPercent, 6);
        
        // Boss Label
        ctx.fillStyle = '#fff';
        ctx.font = '10px Arial';
        ctx.textAlign = 'center';
        ctx.fillText(`Lv.${this.bossLevel} Boss ${this.bossIndex}`, this.x, this.y - 35);
        
        ctx.globalAlpha = 1.0;
    }
}

class Minion {
    constructor(x, y, type) {
        this.x = x;
        this.y = y;
        this.type = type;
        // Deep copy info so upgrades don't affect shop template
        this.info = JSON.parse(JSON.stringify(MINION_TYPES[type])); 
        this.cooldown = 0;
        this.target = null;
        
        // Track upgrade levels
        this.upgrades = {
            range: 0,
            fireRate: 0,
            damage: 0
        };
        if (type === 'JET_TANK') {
            this.hp = 1000;
            this.maxHp = 1000;
        } else {
            this.hp = 100;
            this.maxHp = 100;
        }
    }
    
    takeDamage(amount) {
        this.hp -= amount;
    }
    
    update(enemies, projectiles) {
        if (this.cooldown > 0) this.cooldown--;
        
        // Basic targeting: find first TARGETABLE enemy in range
        this.target = null;
        for (let enemy of enemies) {
            if (enemy.untargetable) continue;
            
            const dist = Math.hypot(enemy.x - this.x, enemy.y - this.y);
            if (dist <= this.info.range) {
                this.target = enemy;
                break;
            }
        }
        
        // Shoot
        if (this.target && this.cooldown <= 0) {
            projectiles.push(new Projectile(this.x, this.y, this.target, this.info));
            this.cooldown = this.info.fireRate;
        }
    }
    
    draw(ctx) {
        // Base minion shadow
        ctx.beginPath();
        ctx.ellipse(this.x, this.y + 10, 18, 10, 0, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(0, 0, 0, 0.3)';
        ctx.fill();

        // Minion body
        ctx.beginPath();
        ctx.arc(this.x, this.y, 15, 0, Math.PI * 2);
        
        // Gradient body for premium look
        let gradient = ctx.createRadialGradient(this.x - 5, this.y - 5, 2, this.x, this.y, 15);
        gradient.addColorStop(0, '#ffffff');
        gradient.addColorStop(0.3, this.info.color);
        gradient.addColorStop(1, '#000000');
        
        ctx.fillStyle = gradient;
        ctx.fill();
        ctx.strokeStyle = 'rgba(255, 255, 255, 0.5)';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        // Simple cannon indicator if target exists
        if (this.target) {
            const dx = this.target.x - this.x;
            const dy = this.target.y - this.y;
            const angle = Math.atan2(dy, dx);
            
            ctx.beginPath();
            ctx.moveTo(this.x, this.y);
            ctx.lineTo(this.x + Math.cos(angle) * 20, this.y + Math.sin(angle) * 20);
            ctx.strokeStyle = this.info.color;
            ctx.lineWidth = 4;
            ctx.lineCap = 'round';
            ctx.stroke();
            
            // Inner cannon line
            ctx.beginPath();
            ctx.moveTo(this.x, this.y);
            ctx.lineTo(this.x + Math.cos(angle) * 18, this.y + Math.sin(angle) * 18);
            ctx.strokeStyle = '#fff';
            ctx.lineWidth = 2;
            ctx.lineCap = 'round';
            ctx.stroke();
        }
        
        // Health bar
        if (this.hp < this.maxHp) {
            ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
            ctx.fillRect(this.x - 15, this.y - 20, 30, 4);
            
            const hpPercent = Math.max(0, this.hp / this.maxHp);
            ctx.fillStyle = hpPercent > 0.5 ? '#2ecc71' : hpPercent > 0.2 ? '#f1c40f' : '#e74c3c';
            ctx.fillRect(this.x - 15, this.y - 20, 30 * hpPercent, 4);
        }
    }
}

class Projectile {
    constructor(x, y, target, sourceInfo) {
        this.x = x;
        this.y = y;
        this.target = target;
        this.damage = sourceInfo.damage;
        this.color = sourceInfo.color;
        this.effect = sourceInfo.effect;
        this.splashRadius = sourceInfo.splashRadius || 0;
        this.speed = 10;
        this.hasHit = false;
    }
    
    update(allEnemies) {
        if (this.target.hp <= 0) {
            this.hasHit = true;
            return;
        }
        
        const dx = this.target.x - this.x;
        const dy = this.target.y - this.y;
        const dist = Math.hypot(dx, dy);
        
        if (dist < this.speed) {
            // Hit
            this.hasHit = true;
            
            // Apply damage/effects
            if (this.effect === 'splash') {
                allEnemies.forEach(enemy => {
                    if (enemy.untargetable) return;
                    if (Math.hypot(enemy.x - this.target.x, enemy.y - this.target.y) <= this.splashRadius) {
                        enemy.takeDamage(this.damage);
                    }
                });
            } else {
                this.target.takeDamage(this.damage);
                if (this.effect === 'slow') {
                    this.target.slowTimer = 2000; // 2 seconds slow
                }
            }
            
        } else {
            // Move
            this.x += (dx / dist) * this.speed;
            this.y += (dy / dist) * this.speed;
        }
    }
    draw(ctx) {
        ctx.beginPath();
        ctx.arc(this.x, this.y, 4, 0, Math.PI * 2);
        ctx.fillStyle = this.color;
        ctx.shadowBlur = 10;
        ctx.shadowColor = this.color;
        ctx.fill();
        
        // Reset shadow
        ctx.shadowBlur = 0;
        
        // Trail effect
        ctx.beginPath();
        ctx.moveTo(this.x, this.y);
        ctx.lineTo(this.x - (this.target.x - this.x) * 0.1, this.y - (this.target.y - this.y) * 0.1);
        ctx.strokeStyle = this.color + 'aa';
        ctx.lineWidth = 2;
        ctx.stroke();
    }
}

class FlyingJetTank extends Minion {
    constructor(startX = -50, startY = -50) {
        // Spawn at placed location or off-screen
        super(startX, startY, 'JET_TANK');
        this.targetX = CANVAS_WIDTH / 2;
        this.targetY = CANVAS_HEIGHT / 2;
        this.speed = 0.1; // pixels per ms
        
        // Jet tanks fly higher, so give them slightly more range from air
        this.info.range = 300; 
        this.info.fireRate = 45; // Shoot faster from air
    }
    
    update(deltaTime, enemies, projectiles) {
        // Handle Movement
        const dx = this.targetX - this.x;
        const dy = this.targetY - this.y;
        const dist = Math.hypot(dx, dy);
        
        if (dist < 10) {
            // Pick a new random point on canvas
            this.targetX = Math.random() * (CANVAS_WIDTH - 100) + 50;
            this.targetY = Math.random() * (CANVAS_HEIGHT - 100) + 50;
        } else {
            const moveDist = this.speed * deltaTime;
            this.x += (dx / dist) * moveDist;
            this.y += (dy / dist) * moveDist;
        }
        
        // Handle Combat (Super call minus cooldown which relies on frames in Minion currently)
        // Convert fireRate to MS cooldown to match deltaTime
        if (this.cooldown > 0) this.cooldown -= deltaTime;
        
        this.target = null;
        for (let enemy of enemies) {
            if (enemy.untargetable) continue;
            
            const d = Math.hypot(enemy.x - this.x, enemy.y - this.y);
            if (d <= this.info.range) {
                this.target = enemy;
                break;
            }
        }
        
        if (this.target && this.cooldown <= 0) {
            projectiles.push(new Projectile(this.x, this.y, this.target, this.info));
            this.cooldown = this.info.fireRate * 16; // Approx converting frames to ms
        }
    }
    
    draw(ctx) {
        // Shadow (Dropped lower to look like it's flying)
        ctx.beginPath();
        ctx.ellipse(this.x, this.y + 30, 15, 8, 0, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(0, 0, 0, 0.2)';
        ctx.fill();

        // Hull
        ctx.beginPath();
        ctx.arc(this.x, this.y, 18, 0, Math.PI * 2);
        let gradient = ctx.createRadialGradient(this.x - 5, this.y - 5, 2, this.x, this.y, 18);
        gradient.addColorStop(0, '#ffffff');
        gradient.addColorStop(0.4, this.info.color);
        gradient.addColorStop(1, '#8e44ad'); // slight purple metallic sheen
        
        ctx.fillStyle = gradient;
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        // Wings
        ctx.beginPath();
        ctx.moveTo(this.x - 18, this.y);
        ctx.lineTo(this.x - 30, this.y + 10);
        ctx.lineTo(this.x - 15, this.y + 5);
        ctx.moveTo(this.x + 18, this.y);
        ctx.lineTo(this.x + 30, this.y + 10);
        ctx.lineTo(this.x + 15, this.y + 5);
        ctx.fillStyle = '#ff8c00'; // lighter orange for top flames
        ctx.fill();
        ctx.stroke();
        
        // Cannon
        if (this.target) {
            const tdx = this.target.x - this.x;
            const tdy = this.target.y - this.y;
            const angle = Math.atan2(tdy, tdx);
            
            ctx.beginPath();
            ctx.moveTo(this.x, this.y);
            ctx.lineTo(this.x + Math.cos(angle) * 25, this.y + Math.sin(angle) * 25);
            ctx.strokeStyle = this.info.color;
            ctx.lineWidth = 6;
            ctx.lineCap = 'round';
            ctx.stroke();
        }
        
        // Health bar background
        ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
        ctx.fillRect(this.x - 15, this.y - 35, 30, 4);
        
        // Health bar
        const hpPercent = Math.max(0, this.hp / this.maxHp);
        ctx.fillStyle = hpPercent > 0.5 ? '#2ecc71' : hpPercent > 0.2 ? '#f1c40f' : '#e74c3c';
        ctx.fillRect(this.x - 15, this.y - 35, 30 * hpPercent, 4);
    }
}

class EnemyProjectile {
    constructor(x, y, target, damage = 10) {
        this.x = x;
        this.y = y;
        this.target = target;
        this.damage = damage;
        this.color = '#e74c3c';
        this.speed = 8;
        this.hasHit = false;
    }
    
    update() {
        if (this.target.hp <= 0) {
            this.hasHit = true;
            return;
        }
        
        const dx = this.target.x - this.x;
        const dy = this.target.y - this.y;
        const dist = Math.hypot(dx, dy);
        
        if (dist < this.speed) {
            this.hasHit = true;
            this.target.takeDamage(this.damage);
        } else {
            this.x += (dx / dist) * this.speed;
            this.y += (dy / dist) * this.speed;
        }
    }
    draw(ctx) {
        ctx.beginPath();
        ctx.arc(this.x, this.y, 4, 0, Math.PI * 2);
        ctx.fillStyle = this.color;
        ctx.shadowBlur = 10;
        ctx.shadowColor = this.color;
        ctx.fill();
        ctx.shadowBlur = 0;
        
        ctx.beginPath();
        ctx.moveTo(this.x, this.y);
        ctx.lineTo(this.x - (this.target.x - this.x) * 0.1, this.y - (this.target.y - this.y) * 0.1);
        ctx.strokeStyle = this.color + 'aa';
        ctx.lineWidth = 2;
        ctx.stroke();
    }
}

class EnemyFlyingJet {
    constructor(startX = -50, startY = -50) {
        this.x = startX;
        this.y = startY;
        this.hp = 50000;
        this.maxHp = 50000;
        this.targetX = CANVAS_WIDTH / 2;
        this.targetY = CANVAS_HEIGHT / 2;
        this.speed = 0.08;
        this.range = 250;
        this.cooldown = 0;
        this.reward = 50;
        this.reachedEnd = false; 
        this.targetMinion = null;
        this.isBoss = false;
        this.untargetable = false;
        this.damageReduction = 0;
    }

    takeDamage(amount) {
        this.hp -= (amount * (1 - this.damageReduction));
    }

    update(deltaTime, gameObj) {
        const dx = this.targetX - this.x;
        const dy = this.targetY - this.y;
        const dist = Math.hypot(dx, dy);
        
        if (dist < 10) {
            this.targetX = Math.random() * (CANVAS_WIDTH - 100) + 50;
            this.targetY = Math.random() * (CANVAS_HEIGHT - 100) + 50;
        } else {
            const moveDist = this.speed * deltaTime;
            this.x += (dx / dist) * moveDist;
            this.y += (dy / dist) * moveDist;
        }

        if (this.cooldown > 0) this.cooldown -= deltaTime;
        
        this.targetMinion = null;
        
        // Target grounded minions or flying allies!
        const possibleTargets = [...gameObj.minions, ...gameObj.flyingAllies];
        for (let target of possibleTargets) {
            if (target.hp <= 0) continue;
            const d = Math.hypot(target.x - this.x, target.y - this.y);
            if (d <= this.range) {
                this.targetMinion = target;
                break;
            }
        }
        
        if (this.targetMinion && this.cooldown <= 0) {
            gameObj.enemyProjectiles.push(new EnemyProjectile(this.x, this.y, this.targetMinion, 25));
            this.cooldown = 1500; 
        }
    }

    draw(ctx) {
        ctx.beginPath();
        ctx.ellipse(this.x, this.y + 30, 15, 8, 0, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(0, 0, 0, 0.2)';
        ctx.fill();

        ctx.beginPath();
        ctx.arc(this.x, this.y, 18, 0, Math.PI * 2);
        let gradient = ctx.createRadialGradient(this.x - 5, this.y - 5, 2, this.x, this.y, 18);
        gradient.addColorStop(0, '#555555');
        gradient.addColorStop(0.4, '#1a1a1a');
        gradient.addColorStop(1, '#000000'); 
        
        ctx.fillStyle = gradient;
        ctx.fill();
        ctx.strokeStyle = '#444';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        ctx.beginPath();
        ctx.moveTo(this.x - 18, this.y);
        ctx.lineTo(this.x - 30, this.y + 10);
        ctx.lineTo(this.x - 15, this.y + 5);
        ctx.moveTo(this.x + 18, this.y);
        ctx.lineTo(this.x + 30, this.y + 10);
        ctx.lineTo(this.x + 15, this.y + 5);
        ctx.fillStyle = '#0a0a0a';
        ctx.fill();
        ctx.stroke();
        
        ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
        ctx.fillRect(this.x - 15, this.y - 30, 30, 4);
        
        const hpPercent = Math.max(0, this.hp / this.maxHp);
        ctx.fillStyle = hpPercent > 0.5 ? '#2ecc71' : hpPercent > 0.2 ? '#f1c40f' : '#e74c3c';
        ctx.fillRect(this.x - 15, this.y - 30, 30 * hpPercent, 4);

        if (this.targetMinion) {
            const tdx = this.targetMinion.x - this.x;
            const tdy = this.targetMinion.y - this.y;
            const angle = Math.atan2(tdy, tdx);
            
            ctx.beginPath();
            ctx.moveTo(this.x, this.y);
            ctx.lineTo(this.x + Math.cos(angle) * 25, this.y + Math.sin(angle) * 25);
            ctx.strokeStyle = '#e74c3c'; // Keep lasers red for visibility
            ctx.lineWidth = 6;
            ctx.lineCap = 'round';
            ctx.stroke();
        }
    }
}

class FlyingPhoenix extends Minion {
    constructor(startX = -50, startY = -50) {
        super(startX, startY, 'JET_TANK');
        this.info.name = 'Phoenix';
        this.info.damage = 25;
        this.info.color = '#d35400';
        this.hp = 200;
        this.maxHp = 200;
        this.targetX = CANVAS_WIDTH / 2;
        this.targetY = CANVAS_HEIGHT / 2;
        this.speed = 0.12;
        this.info.range = 280;
        this.info.fireRate = 30;
    }
    
    update(deltaTime, enemies, projectiles) {
        const dx = this.targetX - this.x;
        const dy = this.targetY - this.y;
        const dist = Math.hypot(dx, dy);
        
        if (dist < 10) {
            this.targetX = Math.random() * (CANVAS_WIDTH - 100) + 50;
            this.targetY = Math.random() * (CANVAS_HEIGHT - 100) + 50;
        } else {
            const moveDist = this.speed * deltaTime;
            this.x += (dx / dist) * moveDist;
            this.y += (dy / dist) * moveDist;
        }
        
        if (this.cooldown > 0) this.cooldown -= deltaTime;
        
        this.target = null;
        for (let enemy of enemies) {
            if (enemy.untargetable) continue;
            
            const d = Math.hypot(enemy.x - this.x, enemy.y - this.y);
            if (d <= this.info.range) {
                this.target = enemy;
                break;
            }
        }
        
        if (this.target && this.cooldown <= 0) {
            projectiles.push(new Projectile(this.x, this.y, this.target, this.info));
            this.cooldown = this.info.fireRate * 16;
        }
    }
    
    draw(ctx) {
        ctx.beginPath();
        ctx.ellipse(this.x, this.y + 30, 15, 8, 0, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(0, 0, 0, 0.2)';
        ctx.fill();

        ctx.beginPath();
        ctx.arc(this.x, this.y, 18, 0, Math.PI * 2);
        let gradient = ctx.createRadialGradient(this.x - 5, this.y - 5, 2, this.x, this.y, 18);
        gradient.addColorStop(0, '#ffffff');
        gradient.addColorStop(0.4, '#e67e22');
        gradient.addColorStop(1, '#c0392b');
        
        ctx.fillStyle = gradient;
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        ctx.beginPath();
        ctx.moveTo(this.x - 18, this.y);
        ctx.lineTo(this.x - 30, this.y + 10);
        ctx.lineTo(this.x - 15, this.y + 5);
        ctx.moveTo(this.x + 18, this.y);
        ctx.lineTo(this.x + 30, this.y + 10);
        ctx.lineTo(this.x + 15, this.y + 5);
        ctx.fillStyle = '#f39c12';
        ctx.fill();
        ctx.stroke();
        
        if (this.hp < this.maxHp) {
            ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
            ctx.fillRect(this.x - 15, this.y - 30, 30, 4);
            
            const hpPercent = Math.max(0, this.hp / this.maxHp);
            ctx.fillStyle = hpPercent > 0.5 ? '#2ecc71' : hpPercent > 0.2 ? '#f1c40f' : '#e74c3c';
            ctx.fillRect(this.x - 15, this.y - 30, 30 * hpPercent, 4);
        }
        
        if (this.target) {
            const tdx = this.target.x - this.x;
            const tdy = this.target.y - this.y;
            const angle = Math.atan2(tdy, tdx);
            
            ctx.beginPath();
            ctx.moveTo(this.x, this.y);
            ctx.lineTo(this.x + Math.cos(angle) * 25, this.y + Math.sin(angle) * 25);
            ctx.strokeStyle = '#f39c12';
            ctx.lineWidth = 6;
            ctx.lineCap = 'round';
            ctx.stroke();
        }
    }
}

// Start game when page loads
window.onload = () => {
    const game = new Game();
};
