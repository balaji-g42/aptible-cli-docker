# 🐳 Aptible Tunnel Service for Docker

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Ready-blue.svg)](https://hub.docker.com/r/balajig4292/aptible-cli-docker)

## 📋 Overview

This container provides a Docker-native way to deploy full-stack applications that use **Aptible-managed PostgreSQL and Redis databases**. It solves a fundamental limitation of Aptible's CLI tools by using `socat` proxies to expose database tunnels across Docker networks.

### 🎯 Why This Exists

Aptible's `db:tunnel` command binds exclusively to `localhost` (127.0.0.1) for security reasons. This means:

- ❌ **Problem**: In a multi-container Docker setup, other containers cannot reach services bound to `localhost` inside the aptible-cli container
- ✅ **Solution**: This container uses `socat` proxies to re-expose the localhost-bound tunnels on `0.0.0.0`, making them accessible to sibling containers on the same Docker network

### 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Network (aptible-net)                  │
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────┐             │
│  │   backend        │────────>│  aptible-cli     │             │
│  │                  │         │                  │             │
│  │  Connects to:    │         │  aptible db:tunnel│             │
│  │  - postgresql    │         │    └─> 127.0.0.1:54321          │
│  │  - redis         │         │                  │             │
│  │                  │         │  socat proxy     │             │
│  │                  │         │    └─> 0.0.0.0:54321            │
│  │                  │         │    └─> 0.0.0.0:51597            │
│  └──────────────────┘         └──────────────────┘             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### ⚙️ How the Proxy Works

The `startup.sh` script orchestrates the tunnel and proxy setup:

1. **Aptible Tunnels**: The `aptible db:tunnel` command creates secure tunnels to your Aptible-managed databases, binding to `127.0.0.1` on internal ports (e.g., `54321`, `51596`)

2. **Socat Proxies**: Each tunnel gets a corresponding `socat` proxy that:
   - Listens on `0.0.0.0:<PUBLIC_PORT>` (accessible from other containers)
   - Forwards traffic to `127.0.0.1:<INTERNAL_PORT>` (the actual tunnel)
   - PostgreSQL: Plain TCP proxy
   ```bash
   socat TCP-LISTEN:54321,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:54321
   ```
   - Redis: TLS-terminating proxy with certificate generation
   ```bash
   socat OPENSSL-LISTEN:51597,fork,reuseaddr,bind=0.0.0.0,cert=...,key=... \
         OPENSSL:ng-pep-aptible:51596,verify=1,...
   ```

### 💪 Benefits Over Aptible Maintained Deployment Stack

| Aspect | Aptible Stack | This Docker Solution |
|--------|---------------|---------------------|
| 🏢 **Infrastructure** | Requires Aptible-managed app deployment | Runs on any Docker host (local, AWS, GCP, Azure) |
| 🔒 **Network Isolation** | Apps deployed on Aptible's platform | Full control over Docker networking and service mesh |
| 🧩 **Service Composition** | Limited to Aptible's deployment model | Mix any services: Java, Node, Python, etc. |
| 💻 **Local Development** | Requires tunneling tools per developer | `docker-compose up` - everyone gets identical environment |
| 🚀 **CI/CD Integration** | Requires Aptible credentials in CI | Standard Docker builds and deployments |
| 💰 **Cost** | Aptible platform fees + compute | Infrastructure costs only |
| 🔍 **Debugging** | Limited to Aptible's tools | Full Docker access: exec, logs, network inspection |
| 📈 **Scaling** | Aptible's scaling model | Docker Swarm, Kubernetes, or any orchestrator |

### 🎯 Use Cases

1. 🐍 **Full-Stack Docker Deployments**: Backend services (Java Spring Boot, Node.js, Python) can connect to Aptible databases through this container
2. 🔗 **Microservices Architecture**: Multiple services share database access through a single tunnel container
3. 🛠️ **Local Development**: Developers get identical database access without per-machine tunnel setup
4. ⚡ **CI/CD Pipelines**: Integration tests can connect to staging Aptible databases

### 🖥️ Terminal UI

The container includes a web-based terminal interface for managing your Aptible account directly from the browser.

![Terminal UI - Main Interface](image.png)

![Terminal UI - Aptible CLI Commands](image1.png)

![Terminal UI - Tunnel Status Monitoring](image2.png)

**Features:**
- Full shell access to the container
- Run Aptible CLI commands interactively
- Monitor tunnel status and logs
- Manage database connections

Access the terminal UI at: `http://localhost:3000` (or your configured `UI_PORT`)

## 🔐 Authentication

### 🔑 Login to Aptible

Before the container can establish tunnels, you must authenticate with Aptible.

#### Option 1: Using Terminal UI

Access the web terminal at `http://localhost:3000` and run:

```bash
aptible login --email <your-email> --password <your-password> --lifetime=7D
```

#### Option 2: Using Docker Exec (When Terminal UI is Not Accessible)

If the Terminal UI is not accessible, use `docker exec` to run the login command directly:

```bash
docker exec -it aptible-cli aptible login --email <your-email> --password <your-password> --lifetime=7D
```

**Example:**
```bash
docker exec -it aptible-cli aptible login --email user@example.com --password mySecurePassword123 --lifetime=7D
```

**Parameters:**
- `--email`: Your Aptible account email
- `--password`: Your Aptible account password
- `--lifetime`: Token validity duration (e.g., `7D` for 7 days, `24h` for 24 hours)

**Example:**
```bash
aptible login --email user@example.com --password mySecurePassword123 --lifetime=7D
```

The authentication token is stored in `/root/.aptible/tokens.json` and persisted via the Docker volume mount.

### 🔄 Token Management

- Tokens are automatically renewed when they expire
- The container waits for a valid token before starting tunnels
- Use `--lifetime=7D` to reduce login frequency in long-running deployments

## ⚙️ Environment Variables Configuration

All configurable fields can be set via environment variables using a `.env` file.

### 📝 How to Configure

#### 🏠 Option 1: Local Development (Building from Source)

1. Copy the template file:
   ```bash
   cp aptible/.env.template aptible/.env
   ```

2. Edit the `aptible/.env` file with your configuration

3. Build and run:
   ```bash
   docker-compose up -d
   ```

#### 📦 Option 2: Using Published Docker Image (balajig4292/aptible-cli-docker)

1. Create your `.env` file:
   ```bash
   # Create .env file in your working directory
   cat > .env << EOF
   # PostgreSQL Configuration
   PG1_APP="my-postgres-db"
   PG1_INTERNAL_PORT=54321
   PG1_PUBLIC_PORT=54321
   
   # Redis Configuration
   REDIS_APP="my-redis-cache"
   REDIS_INTERNAL_PORT=51596
   REDIS_PUBLIC_PORT=51597
   
   # Redis TLS with extra domains
   REDIS_TLS_EXTRA_DOMAINS="redis.example.com,cache.example.com"
   
   # Terminal UI
   UI_PORT=3000
   EOF
   ```

2. Run the container:
   ```bash
   docker run -d \
     --name aptible-cli \
     --env-file .env \
     -p 3000:3000 \
     -p 54321:54321 \
     -p 51597:51597 \
     -v ./aptible-config:/root/.aptible \
     balajig4292/aptible-cli-docker
   ```

**Note**: The `.env` file is not committed to version control. Use `.env.template` as a reference to create your own configuration.

### 📋 Available Configuration Options

#### 🐘 PostgreSQL Tunnel 1
- `PG1_APP`: Aptible PostgreSQL app name (default: `postgresql-db`)
- `PG1_INTERNAL_PORT`: Internal port for PostgreSQL tunnel (default: `54321`)
- `PG1_PUBLIC_PORT`: Public port for PostgreSQL access (default: `54321`)
- `PG1_LOG`: Log file path for PostgreSQL tunnel (default: `/var/log/postgresql1-tunnel.log`)

#### 🐘 PostgreSQL Tunnel 2 (Optional)
- `PG2_APP`: Second PostgreSQL app name (default: `postgresql-db2`)
- `PG2_INTERNAL_PORT`: Internal port for second PostgreSQL tunnel (default: `54322`)
- `PG2_PUBLIC_PORT`: Public port for second PostgreSQL access (default: `61322`)
- `PG2_LOG`: Log file path for second PostgreSQL tunnel (default: `/var/log/postgresql2-tunnel.log`)

#### 🔴 Redis Tunnel
- `REDIS_APP`: Aptible Redis app name (default: `redis-db`)
- `REDIS_INTERNAL_PORT`: Internal port for Redis tunnel (default: `51596`)
- `REDIS_PUBLIC_PORT`: Public port for Redis access (default: `51597`)
- `REDIS_LOG`: Log file path for Redis tunnel (default: `/var/log/redis-tunnel.log`)

#### 🔒 Redis TLS Configuration
- `REDIS_TLS_EXTRA_DOMAINS`: Extra domains to add to Redis TLS certificate SANs (comma-separated, e.g., `example.com,api.example.com`)
  - Default SANs always include: `localhost` and `127.0.0.1`
  - Extra domains will be added to the certificate's Subject Alternative Names

#### 🖥️ Terminal UI
- `UI_PORT`: Port for Terminal UI web interface (default: `3000`)
- `UI_LOG`: Log file path for Terminal UI (default: `/var/log/terminal-ui.log`)

#### ⚙️ System Configuration
- `TOKEN_FILE`: Path to Aptible tokens file (default: `/root/.aptible/tokens.json`)
- `HOME`: Home directory (default: `/root`)
- `APTIBLE_HOME`: Aptible configuration directory (default: `/root/.aptible`)

### 📄 Example Configuration

```env
# PostgreSQL Configuration
PG1_APP="my-postgres-db"
PG1_INTERNAL_PORT=54321
PG1_PUBLIC_PORT=54321

# Redis Configuration
REDIS_APP="my-redis-cache"
REDIS_INTERNAL_PORT=51596
REDIS_PUBLIC_PORT=51597

# Redis TLS with extra domains
REDIS_TLS_EXTRA_DOMAINS="redis.example.com,cache.example.com"

# Terminal UI
UI_PORT=8080
```

### 🐙 Docker Compose Usage

The service uses the `.env` file automatically via Docker Compose:

```bash
docker-compose up -d
```

To override environment variables without editing the `.env` file:

```bash
PG1_APP="different-db" REDIS_TLS_EXTRA_DOMAINS="custom.domain.com" docker-compose up -d
```

### 📝 Notes

- If the `.env` file is missing, the service will use default values
- Log files are stored inside the container at the specified paths
- Port mappings in `docker-compose.yml` should match the configured ports

---

## 🤝 Contributing

1. **Fork** the repository
2. **Create branch**: `git checkout -b feature/awesome-feature`
3. **Commit**: `git commit -m "feat: add awesome feature"`
4. **Push & PR**: `git push origin feature/awesome-feature` → Create Pull Request

Branch naming: `feature/`, `fix/`, `docs/`, `refactor/`

---

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.
