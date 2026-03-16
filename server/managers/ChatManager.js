export class ChatManager {
  constructor(mapManager, npcManager, aiAgentManager) {
    this.mapManager = mapManager;
    this.npcManager = npcManager;
    this.aiAgentManager = aiAgentManager;
  }

  sendError(ws, message) {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify({ type: 'error', message }));
    }
    ws.close();
  }

  handleLogMessage(ws, data, mapData) {
    const now = Date.now();
    if (ws.lastLogTime && now - ws.lastLogTime < 2000) return;
    ws.lastLogTime = now;

    console.log("LOG EVENT: ", data);
    if (typeof data.message !== 'string') return;

    const logMsg = data.message.trim();
    if (!logMsg || logMsg.length > 300) return;

    // Maintain LLM context security against newline injections or HTML markup
    if (/[\r\n\t\\<>]/.test(logMsg)) {
      console.warn(`[Security] Rejected malformed log message from ${ws.clientId}`);
      return;
    }

    this.npcManager.logEventToNearbyNPCs(mapData, logMsg, this.aiAgentManager, data.npc_id);
  }

  handleChatMessage(ws, data, mapData) {
    const now = Date.now();
    if (ws.lastChatTime && now - ws.lastChatTime < 2000) return;
    ws.lastChatTime = now;

    if (typeof data.message !== 'string') return;

    data.message = data.message.trim();
    if (!data.message || data.message.length > 200) return;

    // Discard if it contains newlines, tabs, escape backslashes, or HTML brackets.
    if (/[\r\n\t\\<>]/.test(data.message)) {
      this.sendError(ws, 'Invalid message. Please use only English letters with no spaces or symbols.');
      return;
    }

    // Log chat
    const sender = mapData.characters[ws.clientId];
    const name = sender ? sender.name || ws.clientId : ws.clientId;
    
    this.npcManager.logEventToNearbyNPCs(mapData, `${name} (${ws.clientId}) said: "${data.message}"`, this.aiAgentManager);

    const broadcastMsg = JSON.stringify({ type: 'chat', id: ws.clientId, message: data.message });
    this.mapManager.broadcastMessage(mapData.id, broadcastMsg);
  }
}
