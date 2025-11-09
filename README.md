# docker-classification-model

## What this project is

This repository contains a small image-classification service for detecting invasive plant species. It is packaged to run with Docker Compose and includes three services:

-   backend: a Python classifier service (model weights in `backend/models/model.pth`).
-   frontend: a static web UI served by nginx (files under `frontend/public`).
-   database: a PostgreSQL instance initialized using `database/init.sql`.

The repo layout (relevant parts):

-   `backend/` — Python app, model weights, and `requirements.txt`.
-   `frontend/` — Dockerfile, `public/` static UI files.
-   `database/` — `init.sql` used to initialize the Postgres database in Docker.
-   `docker-compose.yml` — orchestrates the three services.

## Quick start (with Docker)

Prerequisites:

-   Docker and Docker Compose installed.

From the project root run:

```bash
# build and start all services (backend:8000, frontend:3000, db:5432)
docker compose up --build
```

Notes:

-   The backend service exposes port 8000 on the host. The frontend is exposed on port 3000.
-   The Compose file maps `./backend/models` into the backend container so you can replace `model.pth` without rebuilding the image.
-   Environment variables in `docker-compose.yml` provide `MODEL_PATH` and `DATABASE_URL` to the backend service.

Stopping the stack:

```bash
docker compose down
```

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

## Environment variables used by the backend

-   MODEL_PATH — path to the model file (default in Docker: `/app/models/model.pth`).
-   DATABASE_URL — SQLAlchemy/Postgres connection URL used by the app.

## Where to look next

-   `backend/` — inspect `app.py` and `requirements.txt` to adapt the local run command if needed.
-   `backend/models/` — replace `model.pth` with your trained model if you want different behavior.
-   `frontend/public` — edit UI files.

## Troubleshooting

-   If the backend can't connect to Postgres in Docker, check `docker compose ps` and the database service logs.
-   If the frontend shows an error connecting to the backend, ensure the backend is reachable from the browser and CORS (if used) is configured appropriately.

## License / attribution

This README is intended to help developers run the project locally or with Docker. See repository files for more implementation details.
