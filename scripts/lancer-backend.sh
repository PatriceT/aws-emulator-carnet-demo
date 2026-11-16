#!/usr/bin/env bash
# Lance le backend Python face à l'émulateur (après scripts/test-emulateur.sh).
set -eu
cd "$(dirname "$0")/.."
source scripts/env.sh
[ -f backend/.env ] || { echo "backend/.env absent : lance d'abord scripts/test-emulateur.sh" >&2; exit 1; }
set -a; source backend/.env; set +a

cd backend
if [ ! -d .venv ]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
fi
exec .venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
