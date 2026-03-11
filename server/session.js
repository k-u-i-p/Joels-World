import crypto from 'crypto';

export const sessions = new Map();

export function generateSessionId() {
  return crypto.randomBytes(16).toString('hex');
}

export function createSession(isAdmin = false) {
  const sessionId = generateSessionId();
  sessions.set(sessionId, {
    created: Date.now(),
    isAdmin: isAdmin
  });
  return sessionId;
}

export function getSession(sessionId) {
  return sessions.get(sessionId);
}
