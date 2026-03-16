import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { GoogleGenAI } from '@google/genai';
import { PhysicsEngine } from '../../src/physics.js';
import { appendToLog } from '../websocket.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export class AIAgentManager {
    constructor(mapState) {
        this.physicsEngine = new PhysicsEngine();
        this.ai = null;
        this.apiKey = process.env.GEMINI_API_KEY;
        this.lastProcessed = {};
        this.globalMapState = mapState;
        this.agentLastPulseTime = {};
        this.agentPendingPulse = {};
    }

    startAIAgent() {
        if (!this.apiKey) {
            const keyPath = path.resolve(__dirname, '../../gemini_key');
            if (fs.existsSync(keyPath)) {
                this.apiKey = fs.readFileSync(keyPath, 'utf8').trim();
                console.log("[AI] API Key loaded from gemini_key file.", this.apiKey);
            }
        }

        if (this.apiKey) {
            this.ai = new GoogleGenAI({
                apiKey: this.apiKey
            });
        }

        if (!this.ai) {
            console.warn("[AI] GEMINI_API_KEY env var or gemini_key file is not set. AI Agents will be disabled.");
            return;
        }
        console.log("[AI] Starting background agent system...");

        for (const mapId in this.globalMapState) {
            const mapData = this.globalMapState[mapId];
            if (mapData.npcs) {
                for (const npc of mapData.npcs) {
                    if (npc.agent && npc.agent.log_file) {
                        const logFilePath = path.resolve(__dirname, '..', 'data', npc.agent.log_file);
                        if (fs.existsSync(logFilePath)) {
                            try {
                                const raw = fs.readFileSync(logFilePath, 'utf8');
                                if (raw.trim()) {
                                    this.lastProcessed[npc.id] = raw.trim();
                                }
                            } catch (e) { }
                        }
                    }
                }
            }
        }
    }

    pulseAgent(mapId, npcId) {
        if (!this.ai || !this.globalMapState) return;

        const mapData = this.globalMapState[mapId];
        if (!mapData || !mapData.npcs) return;

        const npc = mapData.npcs.find(n => n.id === npcId);
        if (!npc || !npc.agent || !npc.agent.log_file || !npc.agent.prompt_file) return;

        const now = Date.now();
        const timeSinceLastPulse = now - (this.agentLastPulseTime[npcId] || 0);

        if (timeSinceLastPulse < 5000) {
            if (!this.agentPendingPulse[npcId]) {
                const delay = 5000 - timeSinceLastPulse;
                this.agentPendingPulse[npcId] = setTimeout(() => {
                    this.agentPendingPulse[npcId] = null;
                    this.pulseAgent(mapId, npcId);
                }, delay);
            }
            return;
        }

        this.agentLastPulseTime[npcId] = now;
        if (this.agentPendingPulse[npcId]) {
            clearTimeout(this.agentPendingPulse[npcId]);
            this.agentPendingPulse[npcId] = null;
        }

        try {
            if (mapData.clients.size === 0) return;

            const logFilePath = path.resolve(__dirname, '..', 'data', npc.agent.log_file);
            const agentFilePath = path.resolve(__dirname, '..', 'data', npc.agent.prompt_file);

            if (!fs.existsSync(agentFilePath) || !fs.existsSync(logFilePath)) {
                return;
            }

            let logsText = fs.readFileSync(logFilePath, 'utf8').trim();

            if (!logsText || this.lastProcessed[npc.id] === logsText) {
                return;
            }

            this.lastProcessed[npc.id] = logsText;
            console.log(`[AI][${mapData.name}] New events detected! Formatting prompt for ${npc.name}...`);

            let agentPrompt = fs.readFileSync(agentFilePath, 'utf8');
            const validEmotes = ["dance", "fart", "laugh", "cry", "angry", "surprised"];

            agentPrompt = agentPrompt
                .replace("{agent_id}", npc.id)
                .replace("{emotes}", validEmotes.join(", "));

            const prompt = `${agentPrompt}\n\nRecent Events Log:\n${logsText}\n\nRespond EXACTLY with a valid JSON array representing the actions.`;

            console.log(`[AI][${mapData.name}] Sending prompt for ${npc.name} to Gemini...`);

            this.ai.models.generateContent({
                model: 'gemini-2.5-flash',
                contents: prompt,
                config: {
                    responseMimeType: "application/json",
                }
            }).then(response => {
                let resultText = response.text;
                console.log(`[AI][${mapData.name}] Received response for ${npc.name}:`, resultText);

                if (resultText) {
                    try {
                        const result = JSON.parse(resultText);
                        console.log(`[AI][${mapData.name}] Parsed response for ${npc.name} successfully! Applying actions...`);
                        this.handleAgentAction(mapData, result);
                    } catch (e) {
                        console.error(`[AI][${mapData.name}] Failed to parse agent JSON:`, resultText, e);
                    }
                }
            }).catch(err => {
                console.error(`[AI][${mapData.name}] API Error for ${npc.name}:`, err);
            });

        } catch (err) {
            console.error(`[AI][${mapData.name}] Error pulsing agent ${npcId}`, err);
        }
    }

    async handleAgentAction(mapData, action) {
        const actions = Array.isArray(action) ? action : [action];

        for (const act of actions) {
            if (!act.player_id) {
                console.warn(`[AI] Action missing player_id. Skipping:`, act);
                continue;
            }

            const npcId = act.player_id;
            const npcChar = mapData.npcs.find(n => n.id === npcId);
            if (!npcChar) {
                console.warn(`[AI] Agent tried to act as player_id ${npcId} which is not an NPC on map ${mapData.name}.`);
                continue;
            }

            if (act.say) {
                console.log(`[AI][${mapData.name}] NPC '${npcChar.name || npcId}' says:`, act.say);
                const sayArr = Array.isArray(act.say) ? act.say : [act.say];
                
                const playerIdsInRange = new Set();
                if (mapData.characters) {
                    Object.values(mapData.characters).forEach(player => {
                        const npcsNearPlayer = this.physicsEngine.findCharacters([npcChar], player.x, player.y);
                        if (npcsNearPlayer.length > 0) {
                            playerIdsInRange.add(player.id);
                        }
                    });
                }

                for (let i = 0; i < sayArr.length; i++) {
                    let msg = sayArr[i];
                    msg = msg.replace(/\s*\([^)]*\)/g, '');
                    
                    const broadcastMsg = JSON.stringify({ type: 'chat', id: npcId, message: msg });
                    const logLine = `${npcChar.name || npcId} (${npcId}) said: "${msg}"`;
                    appendToLog(mapData, logLine);

                    if (npcChar.agent && npcChar.agent.log_file) {
                        const logFilePath = path.resolve(__dirname, '..', 'data', npcChar.agent.log_file);
                        try {
                            if (fs.existsSync(logFilePath)) {
                                this.lastProcessed[npcId] = fs.readFileSync(logFilePath, 'utf8').trim();
                            }
                        } catch (e) {}
                    }

                    mapData.clients.forEach(client => {
                        if (client.readyState === 1 && playerIdsInRange.has(client.clientId)) {
                            client.send(broadcastMsg);
                        }
                    });

                    if (i < sayArr.length - 1) {
                        await new Promise(resolve => setTimeout(resolve, 5000));
                    }
                }
            }

            if (act.emote) {
                console.log(`[AI][${mapData.name}] NPC '${npcChar.name || npcId}' emoting: ${act.emote}`);
                npcChar.emote = act.emote;
                
                const updateMsg = JSON.stringify({
                  type: 'update',
                  character: { id: npcId, emote: act.emote }
                });
                
                mapData.clients.forEach(client => {
                  if (client.readyState === 1) client.send(updateMsg);
                });

                setTimeout(() => {
                    const currentNpc = mapData.npcs.find(n => n.id === npcId);
                    if (currentNpc && currentNpc.emote === act.emote) {
                        currentNpc.emote = null;
                        const clearMsg = JSON.stringify({
                          type: 'update',
                          character: { id: npcId, emote: null }
                        });
                        mapData.clients.forEach(client => {
                          if (client.readyState === 1) client.send(clearMsg);
                        });
                    }
                }, 5000);
            }

            if (act.change_map !== undefined && act.target_player_id) {
                console.log(`[AI][${mapData.name}] Map Change Action: Target ${act.target_player_id} -> Map ${act.change_map}`);
                const targetWs = Array.from(mapData.clients).find(c => c.clientId === act.target_player_id);
                if (targetWs) {
                    console.log(`[AI][${mapData.name}] Forcing target ${act.target_player_id} to map ${act.change_map}`);
                    const simMessage = Buffer.from(JSON.stringify({
                        type: "change_map",
                        mapId: act.change_map,
                        force: true
                    }));
                    targetWs.emit('message', simMessage);
                } else {
                    console.warn(`[AI] Target player ${act.target_player_id} not found on map.`);
                }
            }

            if (act.say && actions.indexOf(act) < actions.length - 1) {
                await new Promise(resolve => setTimeout(resolve, 5000));
            }
        }
    }
}
