import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { GoogleGenAI } from '@google/genai';
import { PhysicsEngine } from '../src/physics.js';
import { appendToLog } from './websocket.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const physicsEngine = new PhysicsEngine();

let ai = null;
let apiKey = process.env.GEMINI_API_KEY;
let lastProcessed = {};
let _globalMapState = null;
const agentLastPulseTime = {};

export function startAIAgent(mapState) {
    if (!apiKey) {
        const keyPath = path.resolve(__dirname, '../gemini_key');
        if (fs.existsSync(keyPath)) {
            apiKey = fs.readFileSync(keyPath, 'utf8').trim();
            console.log("[AI] API Key loaded from gemini_key file.", apiKey);
        }
    }

    if (apiKey) {
        ai = new GoogleGenAI({
            apiKey: apiKey
        });
    }

    if (!ai) {
        console.warn("[AI] GEMINI_API_KEY env var or gemini_key file is not set. AI Agents will be disabled.");
        return;
    }
    console.log("[AI] Starting background agent system...");

    _globalMapState = mapState;

    // Initialize lastProcessed hashes to prevent immediate blast
    for (const mapId in mapState) {
        const mapData = mapState[mapId];
        if (mapData.npcs) {
            for (const npc of mapData.npcs) {
                if (npc.agent && npc.agent.log_file) {
                    const logFilePath = path.resolve(__dirname, 'data', npc.agent.log_file);
                    if (fs.existsSync(logFilePath)) {
                        try {
                            const raw = fs.readFileSync(logFilePath, 'utf8');
                            if (raw.trim()) {
                                lastProcessed[npc.id] = raw.trim();
                            }
                        } catch (e) { }
                    }
                }
            }
        }
    }
    // Setup complete. Listeners will trigger pulses.
}

export function pulseAgent(mapId, npcId) {
    if (!ai || !_globalMapState) return;

    const mapData = _globalMapState[mapId];
    if (!mapData || !mapData.npcs) return;

    const npc = mapData.npcs.find(n => n.id === npcId);
    if (!npc || !npc.agent || !npc.agent.log_file || !npc.agent.prompt_file) return;

    // Throttle to 5 seconds per Agent
    const now = Date.now();
    if (agentLastPulseTime[npcId] && now - agentLastPulseTime[npcId] < 5000) {
        return;
    }
    agentLastPulseTime[npcId] = now;

    try {
        if (mapData.clients.size === 0) return;

        const logFilePath = path.resolve(__dirname, 'data', npc.agent.log_file);
        const agentFilePath = path.resolve(__dirname, 'data', npc.agent.prompt_file);

        if (!fs.existsSync(agentFilePath) || !fs.existsSync(logFilePath)) {
            return;
        }

        let logsText = fs.readFileSync(logFilePath, 'utf8').trim();

        if (!logsText || lastProcessed[npc.id] === logsText) {
            return;
        }

        lastProcessed[npc.id] = logsText;
        console.log(`[AI][${mapData.name}] New events detected! Formatting prompt for ${npc.name}...`);

        let agentPrompt = fs.readFileSync(agentFilePath, 'utf8');
        const validEmotes = ["dance", "fart", "laugh", "cry", "angry", "surprised"];

        agentPrompt = agentPrompt
            .replace("{agent_id}", npc.id)
            .replace("{emotes}", validEmotes.join(", "));

        const prompt = `${agentPrompt}\n\nRecent Events Log:\n${logsText}\n\nRespond EXACTLY with a valid JSON array representing the actions.`;

        console.log(`[AI][${mapData.name}] Sending prompt for ${npc.name} to Gemini...`);

        ai.models.generateContent({
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
                    handleAgentAction(mapData, result);
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

async function handleAgentAction(mapData, action) {
    const actions = Array.isArray(action) ? action : [action];

    for (const act of actions) {
        if (!act.player_id) {
            console.warn(`[AI] Action missing player_id. Skipping:`, act);
            continue;
        }

        const npcId = act.player_id;

        // Ensure npc exists in map npcs array
        const npcChar = mapData.npcs.find(n => n.id === npcId);
        if (!npcChar) {
            console.warn(`[AI] Agent tried to act as player_id ${npcId} which is not an NPC on map ${mapData.name}.`);
            continue;
        }

        if (act.say) {
            console.log(`[AI][${mapData.name}] NPC '${npcChar.name || npcId}' says:`, act.say);
            const sayArr = Array.isArray(act.say) ? act.say : [act.say];
            
            // Find who is close enough to hear this agent
            const playerIdsInRange = new Set();
            if (mapData.characters) {
                Object.values(mapData.characters).forEach(player => {
                    const npcsNearPlayer = physicsEngine.findCharacters([npcChar], player.x, player.y);
                    if (npcsNearPlayer.length > 0) {
                        playerIdsInRange.add(player.id);
                    }
                });
            }

            for (let i = 0; i < sayArr.length; i++) {
                let msg = sayArr[i];
                // Strip out (username) or (PlayerID) logic from the string output
                msg = msg.replace(/\s*\([^)]*\)/g, '');
                
                const broadcastMsg = JSON.stringify({ type: 'chat', id: npcId, message: msg });
                
                // append to log to write to file
                const logLine = `${npcChar.name || npcId} (${npcId}) said: "${msg}"`;
                appendToLog(mapData, logLine);

                if (npcChar.agent && npcChar.agent.log_file) {
                    const logFilePath = path.resolve(__dirname, 'data', npcChar.agent.log_file);
                    try {
                        if (fs.existsSync(logFilePath)) {
                            lastProcessed[npcId] = fs.readFileSync(logFilePath, 'utf8').trim();
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
            
            // Broadcast NPC update
            const updateMsg = JSON.stringify({
              type: 'update',
              character: {
                id: npcId,
                emote: act.emote
              }
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
                      character: {
                        id: npcId,
                        emote: null
                      }
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

        // Apply delay between actions if necessary
        if (act.say && actions.indexOf(act) < actions.length - 1) {
            await new Promise(resolve => setTimeout(resolve, 5000));
        }
    }
}
