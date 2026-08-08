import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import Anthropic from '@anthropic-ai/sdk';
import { findCharactersNear } from '../proximity.js';
import { VALID_EMOTES } from '../emotes.js';
import { dataPath } from '../paths.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Sonnet 5: cheaper and faster than Opus 5, and near enough as clever for a teacher asking
// eight-year-olds riddles. `claude-opus-5` and `claude-haiku-4-5` are drop-in swaps either
// way — nothing else in this file depends on the choice.
const MODEL = 'claude-sonnet-5';

// The Messages API is stateless — unlike Gemini's `chats.create`, nothing server-side
// remembers the conversation, so `agentChats` below keeps the transcript itself. Left
// unbounded it would grow for as long as the process lives, so each agent keeps only the
// most recent turns. Trimming happens in whole user/assistant pairs: the API requires the
// first message to be a `user` one.
const MAX_HISTORY_MESSAGES = 40;

/**
 * What an agent is allowed to reply with.
 *
 * This replaces Gemini's `responseMimeType: "application/json"`, and goes further: the
 * Messages API constrains generation to the schema, so the reply is not merely JSON but
 * JSON of this exact shape. The prompt files still describe the actions in prose — the
 * model needs to know what they *mean* — but they no longer have to police the format.
 *
 * Structured outputs require every property to be listed in `required`, so the optional
 * actions are spelled as nullable instead; `handleAgentAction` skips the nulls.
 */
const ACTIONS_SCHEMA = {
    type: 'object',
    properties: {
        actions: {
            type: 'array',
            description: 'The actions to take. Empty when there is nothing worth saying or doing.',
            items: {
                type: 'object',
                properties: {
                    // Player and NPC ids are numbers everywhere in `data/` and in
                    // `ClientManager`'s counter, but the prompt files quote them inside a
                    // string, so both spellings are allowed and compared as strings below.
                    player_id: {
                        anyOf: [{ type: 'integer' }, { type: 'string' }],
                        description: "The acting NPC's own player_id.",
                    },
                    say: {
                        anyOf: [
                            { type: 'string' },
                            { type: 'array', items: { type: 'string' } },
                            { type: 'null' },
                        ],
                        description: 'What to say to the room, or null to stay quiet.',
                    },
                    emote: {
                        anyOf: [{ type: 'string', enum: VALID_EMOTES }, { type: 'null' }],
                        description: 'A visual emote to play, or null for none.',
                    },
                    change_map: {
                        anyOf: [{ type: 'integer' }, { type: 'null' }],
                        description: 'Map ID to send target_player_id to, or null to move nobody.',
                    },
                    target_player_id: {
                        anyOf: [{ type: 'integer' }, { type: 'string' }, { type: 'null' }],
                        description: 'The player to move. Required whenever change_map is set.',
                    },
                },
                required: ['player_id', 'say', 'emote', 'change_map', 'target_player_id'],
                additionalProperties: false,
            },
        },
    },
    required: ['actions'],
    additionalProperties: false,
};

export class AIAgentManager {
    constructor(mapManager, npcManager) {
        this.npcManager = npcManager;
        this.ai = null;
        this.apiKey = process.env.ANTHROPIC_API_KEY;
        this.agentChats = {};
        this.agentPendingMessages = {};
        this.mapManager = mapManager;
        this.agentLastPulseTime = {};
        this.agentPendingPulse = {};
        this.validEmotes = [];
        this.agentBusy = {};
    }

    startAIAgent() {
        if (!this.apiKey) {
            const keyPath = path.resolve(__dirname, '../claude-key.txt');
            if (fs.existsSync(keyPath)) {
                this.apiKey = fs.readFileSync(keyPath, 'utf8').trim();
                console.log("[AI] API Key loaded from claude-key.txt file.");
            }
        }

        if (this.apiKey) {
            this.ai = new Anthropic({
                apiKey: this.apiKey
            });
        }

        if (!this.ai) {
            console.warn("[AI] ANTHROPIC_API_KEY env var or claude-key.txt file is not set. AI Agents will be disabled.");
            return;
        }
        console.log(`[AI] Starting background agent system on ${MODEL}...`);

        // Was scraped out of the web client's `emotes.js`; now read from `server/emotes.js`
        // so the server does not depend on `client/` (PLAN.md §8).
        this.validEmotes = [...VALID_EMOTES];
        console.log(`[AI] Loaded ${this.validEmotes.length} valid emotes for AI configuration.`);
    }

    appendEvent(mapId, npcId, message) {
        if (!this.ai || !this.mapManager) return;

        if (!this.agentPendingMessages[npcId]) {
            this.agentPendingMessages[npcId] = [];
        }
        if (message) {
            this.agentPendingMessages[npcId].push(message);
        }

        this.pulseAgent(mapId, npcId);
    }

    pulseAgent(mapId, npcId) {
        if (!this.ai || !this.mapManager) return;

        const mapData = this.mapManager.getMap(mapId);
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

        if (this.agentBusy[npcId]) return;

        try {
            if (mapData.clients.size === 0) return;

            const pending = this.agentPendingMessages[npcId];
            if (!pending || pending.length === 0) return;

            const agentFilePath = dataPath(npc.agent.prompt_file);
            if (!fs.existsSync(agentFilePath)) {
                return;
            }

            // Ensure the persistent chat session is created the first time an event occurs
            if (!this.agentChats[npcId]) {
                console.log(`[AI][${mapData.name}] Initializing persistent chat session for ${npc.name}...`);
                let agentPrompt = fs.readFileSync(agentFilePath, 'utf8');
                const validEmotesList = this.validEmotes.length > 0 ? this.validEmotes.join(", ") : "dance, fart, laugh, cry, love, wave";

                // `replaceAll`, because `{agent_id}` appears twice in every prompt file — once
                // where the agent is told its own id and once in the rules — and `replace`
                // only ever substituted the first.
                agentPrompt = agentPrompt
                    .replaceAll("{agent_id}", String(npc.id))
                    .replaceAll("{emotes}", validEmotesList)
                    .replaceAll("{logsText}", ""); // Keep logs out of systemPrompt, they are supplied continuously as user turns

                this.agentChats[npcId] = { system: agentPrompt, messages: [] };
            }

            const chat = this.agentChats[npcId];

            // Pop buffered messages
            const combinedMessage = pending.join('\n');
            this.agentPendingMessages[npcId] = [];
            if (!combinedMessage) return;

            console.log(`[AI][${mapData.name}] Sending prompt for ${npc.name} to Claude...`);

            this.agentBusy[npcId] = true;

            // The transcript is only committed once the reply lands, so a failed call leaves
            // `chat.messages` exactly as it was and the buffered events can be safely retried.
            const sentMessages = [...chat.messages, { role: 'user', content: combinedMessage }];

            this.ai.messages.create({
                model: MODEL,
                max_tokens: 2048,
                // A detention teacher does not need to deliberate, and the children are
                // waiting: no thinking, low effort, and the schema keeps the reply honest.
                thinking: { type: 'disabled' },
                output_config: {
                    effort: 'low',
                    format: { type: 'json_schema', schema: ACTIONS_SCHEMA },
                },
                system: chat.system,
                // The cache breakpoint goes on the *newest* turn rather than on the system
                // prompt, so the cached prefix is the system prompt plus the whole transcript
                // behind it. A prompt on its own is around 500 tokens — under Sonnet 5's
                // 1024-token minimum, so a system-only breakpoint would silently never cache;
                // once a conversation has a few exchanges in it, this one does.
                //
                // The marker is added to the outgoing copy only. `chat.messages` stays clean,
                // or the markers would pile up past the four-breakpoint limit.
                messages: [
                    ...sentMessages.slice(0, -1),
                    {
                        role: 'user',
                        content: [{ type: 'text', text: combinedMessage, cache_control: { type: 'ephemeral' } }],
                    },
                ],
            })
                .then(response => {
                    this.agentBusy[npcId] = false;

                    if (response.stop_reason === 'refusal') {
                        console.warn(`[AI][${mapData.name}] Claude declined to respond for ${npc.name}:`, response.stop_details);
                        return;
                    }

                    const resultText = response.content
                        .filter(block => block.type === 'text')
                        .map(block => block.text)
                        .join('');
                    console.log(`[AI][${mapData.name}] Received response for ${npc.name}:`, resultText);

                    chat.messages = this.trimHistory([
                        ...sentMessages,
                        { role: 'assistant', content: response.content },
                    ]);

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
                    this.agentBusy[npcId] = false;
                    console.error(`[AI][${mapData.name}] API Error for ${npc.name}:`, err);
                    // Attempt to restore messages to buffer on API failure so they aren't lost unconditionally
                    const currentPending = this.agentPendingMessages[npcId] || [];
                    this.agentPendingMessages[npcId] = [combinedMessage, ...currentPending];
                });

        } catch (err) {
            console.error(`[AI][${mapData.name}] Error pulsing agent ${npcId}`, err);
        }
    }

    /**
     * Drop the oldest turns once the transcript outgrows `MAX_HISTORY_MESSAGES`.
     *
     * Always cuts to a `user` message: the API rejects a conversation that opens on an
     * assistant turn. The system prompt is not part of this and is never trimmed.
     */
    trimHistory(messages) {
        if (messages.length <= MAX_HISTORY_MESSAGES) return messages;
        let start = messages.length - MAX_HISTORY_MESSAGES;
        while (start < messages.length && messages[start].role !== 'user') {
            start++;
        }
        return messages.slice(start);
    }

    async handleAgentAction(mapData, action) {
        // `action` is `{ actions: [...] }` under the response schema; the older shapes — a
        // bare array, or a lone action object — are still accepted so a hand-edited prompt
        // or an older log replay does not silently do nothing.
        let actions;
        if (Array.isArray(action)) {
            actions = action;
        } else if (action && Array.isArray(action.actions)) {
            actions = action.actions;
        } else {
            actions = [action];
        }

        for (const act of actions) {
            if (!act || !act.player_id) {
                console.warn(`[AI] Action missing player_id. Skipping:`, act);
                continue;
            }

            // Compared as strings: the schema lets the model spell an id either way, and the
            // world's own ids are numbers.
            const npcChar = mapData.npcs.find(n => String(n.id) === String(act.player_id));
            const npcId = npcChar ? npcChar.id : act.player_id;
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
                        const npcsNearPlayer = findCharactersNear([npcChar], player.x, player.y);
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
                    // Passing `null` as the 3rd argument bypasses the synchronous pulse trigger that causes infinite loops when generation latency exceeds the 5s debounce threshold
                    this.npcManager.logEventToNearbyNPCs(mapData, logLine, null);



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
                const emoteObj = { name: act.emote, startTime: Date.now() };
                npcChar.emote = emoteObj;

                const updateMsg = JSON.stringify({
                    type: 'update',
                    character: { id: npcId, emote: emoteObj }
                });

                mapData.clients.forEach(client => {
                    if (client.readyState === 1) client.send(updateMsg);
                });

                setTimeout(() => {
                    const currentNpc = mapData.npcs.find(n => n.id === npcId);
                    // Clear if it hasn't been overwritten by a new emote
                    if (currentNpc && currentNpc.emote === emoteObj) {
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

            if (act.change_map !== undefined && act.change_map !== null && act.target_player_id) {
                if (act.say) {
                    await new Promise(resolve => setTimeout(resolve, 5000));
                }
                console.log(`[AI][${mapData.name}] Map Change Action: Target ${act.target_player_id} -> Map ${act.change_map}`);
                const targetWs = Array.from(mapData.clients).find(c => String(c.clientId) === String(act.target_player_id));
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
