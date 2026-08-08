/**
 * Message framing shared by the socket handlers — the JS side of
 * `native/Engine/Net/Protocol.swift`.
 */

/**
 * Refuses a connection: tells the client why, then hangs up.
 *
 * Both `ClientManager` (bad session, bad name, session already live elsewhere) and
 * `ChatManager` (bad chat text) end a connection this way, and the client reads the reason
 * off the `error` message before the socket closes.
 *
 * @param {import('ws').WebSocket} ws - The socket to refuse.
 * @param {string} message - Shown to the player.
 */
export function sendError(ws, message) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify({ type: 'error', message }));
  }
  ws.close();
}
