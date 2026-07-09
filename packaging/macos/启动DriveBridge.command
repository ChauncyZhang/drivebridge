#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$ROOT_DIR/app/drivebridge-manager.sh" menu
