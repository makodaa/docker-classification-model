# docker-classification-model

## What this project is

This repository contains a **production-ready image classification service** for detecting invasive plant species with **complete observability** (monitoring, logging, and alerting). It is packaged to run with Docker Compose and includes seven services:

-   **backend**: A Python classifier service with PyTorch model inference (model weights in `backend/models/model.pth`).
-   **frontend**: A static web UI served by nginx (files under `frontend/public`).
-   **database**: A PostgreSQL instance initialized using `database/init.sql`.
-   **prometheus**: Metrics collection and alerting engine.
-   **grafana**: Unified visualization for metrics and logs with auto-provisioned dashboards.
-   **loki**: Centralized log aggregation and storage.
-   **promtail**: Log collection agent that ships container logs to Loki.

The repo layout (relevant parts):

-   `backend/` — Python app with Prometheus metrics and structured logging, model weights, and `requirements.txt`.
-   `frontend/` — Dockerfile, `public/` static UI files.
-   `database/` — `init.sql` used to initialize the Postgres database in Docker.
-   `prometheus/` — Prometheus configuration and 11 production-ready alert rules.
-   `grafana/` — Auto-provisioned dashboards and datasource configurations.
-   `loki/` — Loki and Promtail configurations for centralized logging.
-   `scripts/` — Automated test scripts for monitoring, alerting, and logging.
-   `notes/` — Comprehensive documentation (monitoring, logging, alerting guides).
-   `docker-compose.yml` — orchestrates all seven services.

## Quick start (with Docker)

Prerequisites:

-   Docker and Docker Compose installed.

From the project root run:

```bash
# Build and start all services (7 containers)
docker compose up --build -d

# Wait for services to initialize (~30 seconds)
sleep 30

# Verify all services are healthy
docker compose ps

# Run comprehensive tests
./scripts/test-monitoring.sh
./scripts/test-alerts.sh
./scripts/test-logging.sh
```

**Services exposed:**

-   **Frontend UI**: http://localhost:3000
-   **Backend API**: http://localhost:8000
-   **Backend Metrics**: http://localhost:8000/metrics
-   **Prometheus**: http://localhost:9090
-   **Grafana**: http://localhost:3002 (admin/admin)
-   **Loki**: http://localhost:3100
-   **Database**: localhost:5432

**Key Features:**

-   **Metrics**: Request count, latency histograms (P50/P95/P99), error tracking by type
-   **Dashboards**: 2 auto-provisioned Grafana dashboards (6 metric panels + 8 log panels)
-   **Logging**: Structured JSON logs with request correlation (unique request_id)
-   **Alerting**: 11 production-ready alert rules (latency, error rate, service health)
-   **Persistence**: Data volumes for database, metrics (15 days), and logs (30 days)

Notes:

-   The backend service exposes port 8000 on the host. The frontend is exposed on port 3000.
-   The Compose file maps `./backend/models` into the backend container so you can replace `model.pth` without rebuilding the image.
-   Environment variables in `docker-compose.yml` provide `MODEL_PATH` and `DATABASE_URL` to the backend service.
-   All dashboards and datasources are auto-provisioned — no manual Grafana configuration needed.

Stopping the stack:

```bash
# Stop services (keeps data volumes)
docker compose down

# Stop and remove all data (clean slate)
docker compose down -v
```

### Observability Stack

This project includes a **complete production-grade observability stack**:

#### 1. Metrics (Prometheus + Grafana)

```bash
# Run automated tests
./scripts/test-monitoring.sh

# Generate sample traffic
for i in {1..10}; do
  curl -X POST -F "image=@backend/test_data/crasipes.jpg" http://localhost:8000/predict
  sleep 1
done

# View metrics dashboard
open http://localhost:3002  # Grafana: Dashboards → Backend ML Service Monitoring
```

**Metrics collected:**

-   `prediction_requests_total` - Total prediction requests
-   `prediction_processing_time_ms` - Latency histogram (P50, P95, P99)
-   `prediction_errors_total{error_type}` - Errors by type (5 categories)

**Dashboard panels:** Request rate, total predictions, latency percentiles, latency distribution, average latency gauge, P95 gauge

#### 2. Centralized Logging (Loki + Promtail)

```bash
# Run automated tests
./scripts/test-logging.sh

# Query logs via API
curl -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={container="backend"}' \
  --data-urlencode 'limit=10' | jq

# View logs in Grafana
open http://localhost:3002  # Explore → Loki or Centralized Logging Dashboard
```

**Features:**

-   Structured JSON logs with request correlation (request_id)
-   Log fields: timestamp, level, message, module, function, custom fields
-   Automatic container log discovery via Docker socket
-   30-day retention (configurable)

**Example queries (LogQL):**

```logql
{container="backend"}                           # All backend logs
{container="backend", level="ERROR"}            # Error logs only
{container="backend"} |= "Prediction successful" # Successful predictions
{container="backend"} | json | confidence > 0.9  # High confidence predictions
```

#### 3. Alerting (Prometheus Alert Rules)

```bash
# Run alert tests
./scripts/test-alerts.sh

# View alerts in Prometheus
open http://localhost:9090/alerts
```

**11 alert rules across 4 categories:**

-   **Latency**: High average (>1000ms), critical (>3000ms), P95 (>2000ms), P99 (>5000ms)
-   **Error Rate**: High (>5%), critical (>25%), no requests for 5min
-   **Specific Errors**: Model not loaded, high processing errors
-   **Service Health**: Backend down, high memory usage

**Error types tracked:**

-   `model_not_loaded`, `no_image_provided`, `empty_filename`, `file_too_large`, `processing_error`

#### Documentation

-   **[notes/MONITORING.md](notes/MONITORING.md)** - Complete monitoring guide with PromQL queries
-   **[notes/LOGGING.md](notes/LOGGING.md)** - Logging guide with LogQL examples
-   **[notes/ALERTING.md](notes/ALERTING.md)** - Alert configuration and testing
-   **[notes/TESTING_CHECKLIST.md](notes/TESTING_CHECKLIST.md)** - Testing procedures
-   **[notes/FEATURE_MATRIX.md](notes/FEATURE_MATRIX.md)** - Feature implementation status
-   **[notes/PROJECT_DOCUMENTATION.md](notes/PROJECT_DOCUMENTATION.md)** - Complete feature guide

## Run without Docker (development / manual)

Running the project without Docker means you will install and run each component on your machine. Below are concrete, ordered steps for macOS (zsh). The commands assume you're running from the repository root. Adjust usernames, passwords, and ports to your preferences.

High-level checklist (what you need to do):

-   Install and start PostgreSQL locally.
-   Create the DB and user, and run `database/init.sql` to create the schema.
-   Create a Python virtual environment for the backend and install `requirements.txt`.
-   Place the model file at `backend/models/model.pth` or set `MODEL_PATH` to the correct location.
-   Start the backend (dev mode with Flask or production with Gunicorn).
-   Serve the frontend static files with a simple static server (or a locally installed nginx).

Detailed steps (macOS / zsh):

1. Install PostgreSQL (if you don't already have it)

```bash
# Option A: Homebrew
brew update
brew install postgresql
brew services start postgresql

# Option B: Postgres.app - download and open the app, then use its psql binary
```

2. Create DB user and database, then apply the init SQL

```bash
# Replace these commands if you use Postgres.app or a different postgres admin user
psql -U postgres -c "CREATE USER classifier_user WITH PASSWORD 'secure_password';"
psql -U postgres -c "CREATE DATABASE classifier_db OWNER classifier_user;"

# Run the init SQL to create schema/tables
psql -U classifier_user -d classifier_db -f database/init.sql
```

If you prefer, you can run only the database inside Docker and run backend/frontend locally: the Compose file already maps `postgres:15-alpine` and the `init.sql` file — run only the database service with `docker compose up database` and point `DATABASE_URL` at it.

3. Prepare and run the backend

```bash
cd backend
# create and activate a virtualenv
python3 -m venv .venv
source .venv/bin/activate

# upgrade pip and install deps
pip install --upgrade pip
# PyTorch installation can be platform-specific (CUDA vs CPU). If you need GPU support, pick the correct torch wheel/install command from the PyTorch install selector.
pip install -r requirements.txt

# place model file if not already present (or set MODEL_PATH below)
# cp ../backend/models/model.pth ./models/model.pth   # example, if you have the file elsewhere

# export env vars used by the app
export MODEL_PATH=$(pwd)/models/model.pth
export LABELS_PATH=$(pwd)/models/class_labels.json
export DATABASE_URL=postgresql://classifier_user:secure_password@localhost:5432/classifier_db

# Run in development (Flask built-in server; good for testing)
python app.py

# Or run in a more production-like server using Gunicorn (install it if needed):
# pip install gunicorn
# gunicorn --workers 4 --bind 0.0.0.0:8000 app:app
```

Notes about PyTorch: installing the correct `torch` wheel can be the trickiest part of local setup. If you don't need GPU acceleration, use the CPU-only install recommended by the PyTorch project (the `requirements.txt` may include a generic torch dependency; if it fails, install torch explicitly before `pip install -r requirements.txt`).

4. Serve the frontend static files locally

```bash
# Quick option using Python's simple HTTP server
cd frontend/public
python3 -m http.server 3000

# Now open http://localhost:3000 in your browser. Adjust API endpoints if the frontend expects a different backend host/port.
```

If the frontend needs the backend to be at a specific host (for example `http://localhost:8000`), confirm the frontend configuration (in `frontend/public/app.js`) or set up a local proxy.

5. Smoke tests and verification

```bash
# Health check (should show model_loaded true after startup)
curl http://localhost:8000/health

# Model info
curl http://localhost:8000/info

# Try a prediction (replace /path/to/image.jpg)
curl -X POST -F "image=@/path/to/image.jpg" http://localhost:8000/predict
```

### Windows (PowerShell / Command Prompt / WSL)

If you're developing on Windows, there are platform-specific differences and several options (native Windows vs WSL). Using WSL2 is the simplest way to match the Linux environment used by Docker. If you prefer native Windows, follow these steps.

1. Install PostgreSQL

-   Option A: PostgreSQL installer (recommended for native Windows)

    -   Download and run the PostgreSQL installer for Windows (choose a recent 14/15 build). The installer configures a postgres service and provides `psql` and `pgAdmin`.
    -   Ensure the `bin` folder (for example `C:\Program Files\PostgreSQL\15\bin`) is on your PATH so `psql` is available from the terminal.

-   Option B: Chocolatey (if you use it)
    ```powershell
    choco install postgresql
    # then open a new shell so PATH updates
    ```

2. Create DB user and database, then run `init.sql`

PowerShell / Command Prompt (run as an admin if needed):

```powershell
# From the repo root (adjust the path to psql if it's not on PATH):
# If psql is not on PATH, use the full path, e.g. "C:\\Program Files\\PostgreSQL\\15\\bin\\psql.exe"
psql -U postgres -c "CREATE USER classifier_user WITH PASSWORD 'secure_password';"
psql -U postgres -c "CREATE DATABASE classifier_db OWNER classifier_user;"
psql -U classifier_user -d classifier_db -f database\init.sql
```

Notes:

-   If you used the installer you may have a password set for the `postgres` superuser — use that password when prompted.
-   If commands fail due to PATH, call `psql.exe` with its absolute installation path.

3. Python virtual environment and dependencies (backend)

Command Prompt / PowerShell:

```powershell
cd backend
python -m venv .venv

# Activate (PowerShell)
.\.venv\Scripts\Activate.ps1

# If PowerShell blocks scripts, allow user-level script execution:
# Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Activate (cmd.exe)
# .venv\Scripts\activate.bat

pip install --upgrade pip
# Install PyTorch carefully: use the PyTorch install selector for Windows if you need CUDA.
# Example CPU-only install (may need adaptation):
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

pip install -r requirements.txt
```

4. Environment variables on Windows

PowerShell (session-only):

```powershell
$env:MODEL_PATH = (Join-Path (Get-Location) 'models\\model.pth')
$env:LABELS_PATH = (Join-Path (Get-Location) 'models\\class_labels.json')
$env:DATABASE_URL = 'postgresql://classifier_user:secure_password@localhost:5432/classifier_db'
```

Command Prompt (session-only):

```cmd
set MODEL_PATH=C:\\full\\path\\to\\backend\\models\\model.pth
set LABELS_PATH=C:\\full\\path\\to\\backend\\models\\class_labels.json
set DATABASE_URL=postgresql://classifier_user:secure_password@localhost:5432/classifier_db
```

To persist environment variables across sessions, use `setx` or set them in System Properties.

5. Run the backend on Windows

-   Development (debug):

```powershell
python app.py
```

-   Production-like: Gunicorn does not run on Windows. Use Waitress (a pure-Python WSGI server) or run the backend inside WSL/Docker for closer parity.

Install and run Waitress:

```powershell
pip install waitress
waitress-serve --listen=0.0.0.0:8000 app:app
```

6. Serve the frontend locally on Windows

```powershell
cd frontend\public
python -m http.server 3000

# Or use Node's static servers if you have Node installed:
# npx serve -l 3000
```

7. Verify endpoints (PowerShell)

```powershell
Invoke-RestMethod http://localhost:8000/health
Invoke-RestMethod http://localhost:8000/info

# For file uploads use a tool like Postman or curl from WSL (Windows' curl may map to Invoke-WebRequest).
```

Windows-specific troubleshooting

-   `psql` not found: ensure the Postgres `bin` folder is on PATH or call `psql.exe` with its absolute path.
-   Firewall: Windows Firewall may block incoming connections — allow the ports you need (8000, 3000, 5432) or access via `localhost`.
-   Virtualenv activation blocked: PowerShell's execution policy may block script activation. Use `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` to allow venv activation.
-   PyTorch wheel selection: Windows users needing CUDA must install a torch wheel matched to their CUDA driver. If unsure, install the CPU wheel or use WSL/Docker where GPU access can be more straightforward.
-   For production or testing parity, prefer WSL2 or Docker as they more closely match the Linux environment in the Compose setup.

Common issues and checks

-   Database connection errors: verify `DATABASE_URL` credentials, that Postgres is listening on the expected port, and `database/init.sql` ran successfully.
-   Model load failures: check permissions and file path for `MODEL_PATH`, ensure the model checkpoint format is supported by the code. See backend logs for details.
-   PyTorch incompatibilities: installing the wrong torch wheel (e.g., CPU vs CUDA mismatch) can cause import or runtime errors. If you have a GPU and want to use it, you must install a torch build compatible with your CUDA driver.
-   Port conflicts: ensure ports 8000 (backend), 3000 (frontend), and 5432 (Postgres) are available or change them and update env vars accordingly.

Why running without Docker is different (expanded)

-   Environment isolation and reproducibility: Docker captures exact OS-level dependencies and guarantees the runtime image. Running locally means you must manage Python versions, system libs, and database versions yourself.
-   Installation steps you will personally perform:

    -   Install system packages (Postgres, optional nginx).
    -   Create DB users and databases and run the init SQL.
    -   Create Python virtual environments and install Python packages.
    -   Manage model files on disk and keep file paths in sync with the app's env vars.
    -   Optionally configure a process manager (systemd, launchd, or a container runtime) for production runs.

-   Operational differences:
    -   Docker simplifies networking (containers can reach each other by service name); locally you'll need to use `localhost` and correct ports.
    -   For multi-developer teams, Docker Compose ensures everyone runs the same stack; local installs can diverge unless you document versions precisely.

If you'd like, I can add a small helper script such as `scripts/run-local-backend.sh` to automate the backend steps above and a `scripts/init-db.sh` to run the `psql` commands (with safety checks). Let me know if you want me to add those files.

## API Endpoints

The backend exposes the following endpoints:

-   `POST /predict` - Upload image for classification (returns predictions with confidence scores)
-   `GET /health` - Service health check (includes model load status)
-   `GET /info` - Model metadata and system information
-   `GET /history` - Retrieve prediction history
-   `DELETE /history` - Clear prediction history
-   `GET /metrics` - Prometheus metrics endpoint (request count, latency, errors)

**Request correlation:** Each request receives a unique `request_id` that appears in:

-   Response body
-   Response headers (`X-Request-ID`)
-   Structured logs (for tracing)

## Environment variables used by the backend

-   **MODEL_PATH** — Path to the model file (default in Docker: `/app/models/model.pth`).
-   **LABELS_PATH** — Path to class labels JSON file.
-   **DATABASE_URL** — SQLAlchemy/Postgres connection URL used by the app.

## Where to look next

-   **`backend/`** — Inspect `app.py` (with Prometheus metrics and JSON logging) and `requirements.txt`.
-   **`backend/models/`** — Replace `model.pth` with your trained model if you want different behavior.
-   **`frontend/public`** — Edit UI files.
-   **`prometheus/`** — Modify alert rules or scrape configuration.
-   **`grafana/dashboards/`** — Customize pre-built dashboards.
-   **`loki/`** — Adjust log retention or parsing configuration.
-   **`scripts/`** — Review or modify test scripts.
-   **`notes/`** — Comprehensive documentation for all features.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                       Docker Compose Stack                      │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                       │
│  │ Backend  │  │ Frontend │  │ Database │                       │
│  │  :8000   │  │  :3000   │  │  :5432   │                       │
│  └────┬─────┘  └──────────┘  └──────────┘                       │
│       │                                                         │
│       │ Metrics (/metrics)        Logs (stdout/stderr)          │
│       │                                  │                      │
│       ▼                                  ▼                      │
│  ┌──────────┐                      ┌──────────┐                 │
│  │Prometheus│◄──Alert Rules────┐   │ Promtail │                 │
│  │  :9090   │                  │   │          │                 │
│  └────┬─────┘                  │   └────┬─────┘                 │
│       │                        │        │                       │
│       │ Datasource             │        │ Logs                  │
│       ▼                        │        ▼                       │
│  ┌──────────┐                  │   ┌──────────┐                 │
│  │ Grafana  │◄─────────────────┘   │   Loki   │                 │
│  │  :3002   │◄──Datasource─────────┤  :3100   │                 │
│  └──────────┘                      └──────────┘                 │
│       │                                                         │
│       └─ Auto-provisioned: 2 Dashboards, 2 Datasources          │
└─────────────────────────────────────────────────────────────────┘
```

## Production Readiness

**Implemented ✅:**

-   Health checks for all services
-   Metrics collection and visualization
-   Centralized logging with structured logs
-   Proactive alerting with 11 alert rules
-   Request correlation for distributed tracing
-   Persistent storage for data, metrics, and logs
-   Auto-provisioned dashboards (zero manual config)
-   Comprehensive test scripts
-   Error categorization and tracking
-   Resource limits and restart policies

**Recommended for production 🔧:**

-   Add authentication/authorization (JWT, OAuth)
-   Implement rate limiting
-   Add SSL/TLS termination (reverse proxy)
-   Set up Alertmanager for notifications (email, Slack, PagerDuty)
-   Configure long-term storage for metrics/logs (S3, GCS)
-   Implement CI/CD pipeline
-   Add GPU support for faster inference
-   Configure backup automation
-   Implement secrets management (Docker secrets, Vault)

## Troubleshooting

### General Issues

-   **Backend can't connect to Postgres**: Check `docker compose ps` and database service logs with `docker compose logs database`.
-   **Frontend shows connection error**: Ensure backend is reachable at `http://localhost:8000` and CORS is configured.
-   **Services not starting**: Check logs with `docker compose logs <service-name>`.

### Monitoring Issues

-   **Metrics not appearing**: Run `./scripts/test-monitoring.sh` to diagnose issues.
-   **Dashboards empty**: Wait 1-2 minutes for initial data, check time range in Grafana (top-right).
-   **Prometheus not scraping**: Check targets at http://localhost:9090/targets.

### Logging Issues

-   **Logs not in Loki**: Run `./scripts/test-logging.sh` to validate the stack.
-   **Loki container crashes**: Check disk space with `df -h` and `docker system df`.
-   **JSON parsing fails**: Verify backend outputs JSON logs with `docker logs backend | head`.

### Alert Issues

-   **Alerts not firing**: Check alert rules loaded at http://localhost:9090/rules.
-   **Alert stays inactive**: Verify metric conditions with Prometheus queries.
-   **Test alerts**: Use `./scripts/test-alerts.sh` for interactive testing.

### Performance Issues

-   **High latency**: Check Grafana latency dashboard, review concurrent request handling.
-   **High memory usage**: Monitor with `docker stats`, adjust resource limits if needed.
-   **Disk space issues**: Check volume sizes with `docker system df -v`.

## License / attribution

This README is intended to help developers run the project locally or with Docker. See repository files for more implementation details.
