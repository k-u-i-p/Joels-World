import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { GoogleGenAI } from '@google/genai';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let ai = null;
let apiKey = process.env.GEMINI_API_KEY;

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

const lastProcessed = {};

export function startAIAgent(mapState) {
    if (!ai) {
        console.warn("[AI] GEMINI_API_KEY env var or gemini_key file is not set. AI Agents will be disabled.");
        return;
    }
    console.log("[AI] Starting background agent loop...");

    // Initialize lastProcessed hashes to prevent immediate blast
    for (const mapId in mapState) {
        const mapData = mapState[mapId];
        if (mapData.logFile && fs.existsSync(mapData.logFile)) {
            try {
                const raw = fs.readFileSync(mapData.logFile, 'utf8');
                if (raw.trim()) {
                    lastProcessed[mapId] = JSON.stringify(JSON.parse(raw));
                }
            } catch (e) { }
        }
    }

    setInterval(async () => {
        for (const mapId in mapState) {
            const mapData = mapState[mapId];

            if (mapData.agentFile && mapData.logFile) {
                try {
                    // Only process if there are humans on the map to interact with
                    if (mapData.clients.size === 0) {
                        // console.log(`[AI] Skipping map ${mapId} (${mapData.name}): no players.`);
                        continue;
                    }

                    let logs = [];
                    if (fs.existsSync(mapData.logFile)) {
                        const raw = fs.readFileSync(mapData.logFile, 'utf8');
                        if (raw.trim()) logs = JSON.parse(raw);
                    }

                    if (logs.length === 0) {
                        // console.log(`[AI] Skipping map ${mapId} (${mapData.name}): logs are empty.`);
                        continue;
                    }

                    const currentLogsStr = JSON.stringify(logs);
                    if (lastProcessed[mapId] === currentLogsStr) {
                        // console.log(`[AI] Skipping map ${mapId} (${mapData.name}): no new logs since last check.`);
                        continue;
                    }

                    // We have new logs!
                    console.log(`[AI][${mapData.name}] New events detected! Formatting prompt...`);
                    lastProcessed[mapId] = currentLogsStr;

                    let agentPrompt = fs.readFileSync(mapData.agentFile, 'utf8');

                    // Find the NPC for this prompt (assuming one agent per map for now, or use the first NPC)
                    const npcTarget = mapData.npcs && mapData.npcs.length > 0 ? mapData.npcs[0] : null;
                    const npcId = npcTarget ? npcTarget.id : "UNKNOWN";

                    const validEmotes = ["dance", "fart", "laugh", "cry", "angry", "surprised"]; // Add available emotes here
                    
                    agentPrompt = agentPrompt
                        .replace("{agent_id}", npcId)
                        .replace("{emotes}", validEmotes.join(", "));
                    
                    // Compile full prompt
                    const prompt = `${agentPrompt}\n\nRecent Events Log:\n${JSON.stringify(logs, null, 2)}\n\nRespond EXACTLY with a valid JSON array representing the actions.`;

                    console.log(`[AI][${mapData.name}] Sending prompt to Gemini...`);

                    console.log(prompt);

                    const response = await ai.models.generateContent({
                        model: 'gemini-2.5-flash',
                        contents: prompt,
                        config: {
                            responseMimeType: "application/json",
                        }
                    });

                    let resultText = response.text;
                    console.log(`[AI][${mapData.name}] Received response from Gemini:`, resultText);

                    if (resultText) {
                        try {
                            const result = JSON.parse(resultText);
                            console.log(`[AI][${mapData.name}] Parsed response successfully! Applying actions...`);
                            handleAgentAction(mapData, result);
                        } catch (e) {
                            console.error(`[AI][${mapData.name}] Failed to parse agent JSON:`, resultText, e);
                        }
                    } else {
                        console.log(`[AI][${mapData.name}] Gemini returned an empty response.`);
                    }

                } catch (err) {
                    console.error(`[AI][${mapData.name}] Error in loop for map`, mapId, err);
                }
            }
        }
    }, 5000); // Check every 5 seconds
}

function handleAgentAction(mapData, action) {
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
            for (const msg of sayArr) {
                const broadcastMsg = JSON.stringify({ type: 'chat', id: npcId, message: msg });

                // log it
                let logArr = [];
                try {
                    if (fs.existsSync(mapData.logFile)) {
                        const raw = fs.readFileSync(mapData.logFile, 'utf8');
                        if (raw.trim()) logArr = JSON.parse(raw);
                    }
                } catch (e) { }
                logArr.push({ player_id: npcId, message: `${npcChar.name || npcId} said: "${msg}"` });
                if (logArr.length > 50) logArr = logArr.slice(logArr.length - 50);
                fs.writeFileSync(mapData.logFile, JSON.stringify(logArr, null, 2), 'utf8');

                lastProcessed[mapData.id] = JSON.stringify(logArr);

                mapData.clients.forEach(client => {
                    if (client.readyState === 1) {
                        client.send(broadcastMsg);
                    }
                });
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
                    mapId: act.change_map
                }));
                targetWs.emit('message', simMessage);
            } else {
                console.warn(`[AI] Target player ${act.target_player_id} not found on map.`);
            }
        }
    }
}
