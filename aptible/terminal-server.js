const express = require("express");
const http = require("http");
const WebSocket = require("ws");
const pty = require("node-pty");
const os = require("os");
const path = require("path");

const app = express();

// Serve static files from the public directory if it exists
app.use(express.static(path.join(__dirname, "public")));

// Serve index.html for root route
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

// Create HTTP server
const server = http.createServer(app);

// Create WebSocket server
const wss = new WebSocket.Server({ server });

// Store active PTY processes
const activePtys = new Map();

wss.on("connection", (ws, req) => {
  const clientId = Date.now() + Math.random();

  console.log(`🔌 New terminal connection: ${clientId}`);

  // Determine shell based on platform
  const shell = os.platform() === "win32" ? "powershell.exe" : "bash";

  // Create PTY process
  const ptyProcess = pty.spawn(shell, [], {
    name: "xterm-color",
    cols: 100,
    rows: 30,
    cwd: "/root", // Aptible config is in /root/.aptible
    env: {
      ...process.env,
      PATH: "/opt/aptible-toolbelt/bin:" + process.env.PATH,
      HOME: "/root"
    },
  });

  // Store the PTY process
  activePtys.set(clientId, ptyProcess);

  // Send data from PTY to WebSocket
  ptyProcess.onData((data) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(data);
    }
  });

  // Handle WebSocket messages (user input)
  ws.on("message", (msg) => {
    const data = msg.toString();
    if (ptyProcess) {
      ptyProcess.write(data);
    }
  });

  // Handle WebSocket close
  ws.on("close", () => {
    console.log(`🔌 Terminal connection closed: ${clientId}`);
    if (ptyProcess) {
      ptyProcess.kill();
      activePtys.delete(clientId);
    }
  });

  // Handle PTY process exit
  ptyProcess.onExit(({ exitCode }) => {
    console.log(`💀 PTY process exited with code ${exitCode}: ${clientId}`);
    activePtys.delete(clientId);
    if (ws.readyState === WebSocket.OPEN) {
      ws.close();
    }
  });

  // Terminal is ready - no welcome messages
});

// Cleanup on process exit
process.on("SIGINT", () => {
  console.log("🧹 Cleaning up active PTY processes...");
  for (const [clientId, ptyProcess] of activePtys) {
    ptyProcess.kill();
  }
  activePtys.clear();
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("🧹 Cleaning up active PTY processes...");
  for (const [clientId, ptyProcess] of activePtys) {
    ptyProcess.kill();
  }
  activePtys.clear();
  process.exit(0);
});

// Health check endpoint
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    activeConnections: activePtys.size,
    timestamp: new Date().toISOString()
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`🌐 Aptible Terminal server running at http://localhost:${PORT}`);
  console.log(`🔌 WebSocket endpoint: ws://localhost:${PORT}`);
});

module.exports = { app, server, wss };
