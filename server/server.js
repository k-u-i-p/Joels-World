import express from 'express';
import http from 'http';
import cookieParser from 'cookie-parser';
import { setupWebSocket } from './websocket.js';
import { setupVite } from './vite.js';

const port = process.env.PORT || 80;
const app = express();
const server = http.createServer(app);

app.use(cookieParser());

setupWebSocket(server);
setupVite(app, server, port);
