#!/bin/bash
set -e

# Auto-generate SECRET_KEY if not provided so the app boots out-of-the-box
# without requiring the user to create backend/.env first. Persists in the
# data volume so JWTs survive container restarts.
if [ -z "$SECRET_KEY" ]; then
    SECRET_FILE="${DATA_DIR:-/app/data}/.secret_key"
    mkdir -p "$(dirname "$SECRET_FILE")"
    if [ ! -f "$SECRET_FILE" ]; then
        echo "🔑 No SECRET_KEY provided — generating one (saved to $SECRET_FILE)"
        head -c 48 /dev/urandom | base64 | tr -d '\n' > "$SECRET_FILE"
    fi
    export SECRET_KEY="$(cat "$SECRET_FILE")"
fi

# Initialize arduino-cli config if missing (failsafe)
if [ ! -f /root/.arduino15/arduino-cli.yaml ]; then
    arduino-cli config init 2>/dev/null || true
fi

# Sourcing ESP-IDF environment
if [ -f /opt/esp-idf/export.sh ]; then
    . /opt/esp-idf/export.sh >/dev/null 2>&1 || true
fi

# Start FastAPI backend in the background on port 8001
# Use --reload in development (when backend/app is mounted)
echo "🚀 Starting Velxio Backend..."
if [ -d "/app/backend/app" ]; then
    uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload &
else
    uvicorn app.main:app --host 127.0.0.1 --port 8001 &
fi
UVICORN_PID=$!

# Start Frontend Dev Server if mounted
if [ -d "/app/frontend/src" ]; then
    echo "⚡ Starting Frontend Dev Server..."
    cd /app/frontend && npm run dev -- --host 0.0.0.0 &
    FRONTEND_PID=$!
fi

# Wait for backend to be healthy before starting nginx
sleep 2

# Start Nginx in the background (not exec — we need to monitor both)
echo "🌐 Starting Nginx Web Server on port 80..."
nginx -g "daemon off;" &
NGINX_PID=$!

# Exit as soon as either process dies so Docker can restart the container.
# wait -n requires bash 4.3+ (standard on Debian Bullseye / Ubuntu 20.04+).
wait -n $UVICORN_PID $NGINX_PID $FRONTEND_PID
EXIT_CODE=$?

echo "⚠️  A process exited (code $EXIT_CODE) — shutting down container"
kill $UVICORN_PID $NGINX_PID $FRONTEND_PID 2>/dev/null || true
wait $UVICORN_PID $NGINX_PID $FRONTEND_PID 2>/dev/null || true
exit $EXIT_CODE

