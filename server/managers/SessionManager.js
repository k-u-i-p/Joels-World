import fs from 'fs/promises';
import { existsSync, mkdirSync } from 'fs';
import path from 'path';
import crypto from 'crypto';

export class Session {
    constructor(id, data, manager) {
        this.id = id;
        this.manager = manager;
        // Merge the stored data back into this class
        Object.assign(this, data);
    }
    
    // Mimics the old express-session save() method
    async save() {
        const dataToSave = { ...this };
        delete dataToSave.manager; // Don't serialize the manager instance
        delete dataToSave.id; // The ID is in the filename
        await this.manager.saveSession(this.id, dataToSave);
    }
}

export class SessionManager {
    constructor(sessionsDir) {
        this.sessionsDir = sessionsDir;
        // Ensure the sessions directory exists
        if (!existsSync(sessionsDir)) {
            mkdirSync(sessionsDir, { recursive: true });
        }
    }

    /**
     * Retrieves an existing session by token
     * @param {string} token 
     * @returns {Promise<Session|null>}
     */
    async get(token) {
        if (!token) return null;
        
        // Strict UUID v4 regex to prevent directory traversal attacks
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
        if (!uuidRegex.test(token)) {
            console.warn(`[SessionManager] Attempted to load invalid UUID format: ${token}`);
            return null;
        }

        try {
            const filePath = path.join(this.sessionsDir, `${token}.json`);
            const data = await fs.readFile(filePath, 'utf8');
            const parsed = JSON.parse(data);
            return new Session(token, parsed, this);
        } catch (e) {
            // File not found or invalid JSON
            return null;
        }
    }

    /**
     * Creates a brand new session with a crypto UUID
     * @param {object} initialData 
     * @returns {Promise<Session>}
     */
    async create(initialData = {}) {
        const token = crypto.randomUUID();
        const session = new Session(token, initialData, this);
        await session.save();
        return session;
    }

    // Internal save method called by Session wrapper
    async saveSession(token, data) {
        if (!token) return;

        // Ensure token is a valid UUID before writing
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
        if (!uuidRegex.test(token)) {
            console.error(`[SessionManager] Blocked potentially malicious file write. Invalid UUID: ${token}`);
            return;
        }

        try {
            const filePath = path.join(this.sessionsDir, `${token}.json`);
            await fs.writeFile(filePath, JSON.stringify(data, null, 2));
        } catch (e) {
            console.error('[SessionManager] Failed to save session', token, e);
        }
    }
}
