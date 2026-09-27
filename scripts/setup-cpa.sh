#!/usr/bin/env bash
set -euo pipefail

CPA_PORT=8317
CPA_API_KEY="cpa"
CPA_MANAGE_KEY="manage"

USER_NAME="$(id -un)"
USER_HOME="$HOME"

INSTALL_DIR="$USER_HOME/cliproxyapi"
AUTH_DIR="$USER_HOME/.cli-proxy-api"
BIN="$INSTALL_DIR/cli-proxy-api"
CONFIG="$INSTALL_DIR/config.yaml"

echo "============================================================"
echo " CLIProxyAPI fresh setup"
echo "============================================================"
echo "User:        $USER_NAME"
echo "Home:        $USER_HOME"
echo "Install dir: $INSTALL_DIR"
echo "Auth dir:    $AUTH_DIR"
echo "Port:        $CPA_PORT"
echo

echo "[*] Installing Codex CLI using official installer..."

curl -fsSL https://chatgpt.com/codex/install.sh | sh

# Standalone installer normally places codex here.
export PATH="$USER_HOME/.local/bin:$PATH"

if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: Codex installation finished but 'codex' is not in PATH."
    echo "Expected location is usually:"
    echo "  $USER_HOME/.local/bin/codex"
    exit 1
fi

echo
echo "[+] Codex installed:"
codex --version
echo

# ------------------------------------------------------------
# 1. Install / upgrade CPA using the project's installer
# ------------------------------------------------------------

echo "[*] Installing CLIProxyAPI using official Linux installer..."

curl -fsSL \
  https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer \
  | bash

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: CPA binary not found at:"
    echo "  $BIN"
    exit 1
fi

echo
echo "[+] CLIProxyAPI installed:"
"$BIN" --version 2>/dev/null || true

# ------------------------------------------------------------
# 2. Disable installer's user-level service
#
# We use a system-wide service instead, matching the old setup.
# ------------------------------------------------------------

echo
echo "[*] Disabling installer-created user service..."

systemctl --user disable --now cliproxyapi.service >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 3. Write our config
# ------------------------------------------------------------

echo "[*] Writing config..."

mkdir -p "$AUTH_DIR"

cat > "$CONFIG" <<EOF
host: "127.0.0.1"
port: $CPA_PORT

remote-management:
  allow-remote: false
  secret-key: "$CPA_MANAGE_KEY"

auth-dir: "$AUTH_DIR"

api-keys:
  - "$CPA_API_KEY"

debug: false

request-retry: 3

routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "24h"

  session-affinity-subagents: true
EOF

chmod 600 "$CONFIG"

# ------------------------------------------------------------
# 4. Create system-wide systemd service
# ------------------------------------------------------------

echo "[*] Creating system-wide systemd service..."

sudo tee /etc/systemd/system/cliproxyapi.service >/dev/null <<EOF
[Unit]
Description=CLIProxyAPI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$USER_NAME
Group=$(id -gn)
Environment=HOME=$USER_HOME
WorkingDirectory=$INSTALL_DIR

ExecStart=$BIN --config $CONFIG

Restart=always
RestartSec=3

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cliproxyapi.service

# Keep CPA stopped while doing OAuth logins.
sudo systemctl stop cliproxyapi.service 2>/dev/null || true

# ------------------------------------------------------------
# 5. Codex login loop
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Codex OAuth login"
echo "============================================================"
echo
echo "This uses --no-browser for a remote/server machine."
echo "Open the URL shown by CPA in your local browser."
echo

LOGIN_COUNT=0

while true; do
    LOGIN_COUNT=$((LOGIN_COUNT + 1))

    echo
    echo "------------------------------------------------------------"
    echo " Codex login #$LOGIN_COUNT"
    echo "------------------------------------------------------------"
    echo

    cd "$INSTALL_DIR"

    "$BIN" \
        --config "$CONFIG" \
        --codex-login \
        --no-browser

    echo
    echo "[+] Login #$LOGIN_COUNT completed."
    echo

    while true; do
        read -r -p "Login another Codex account? [y/N] " ANSWER

        case "$ANSWER" in
            y|Y|yes|YES|Yes)
                CONTINUE_LOGIN=1
                break
                ;;
            n|N|no|NO|No|"")
                CONTINUE_LOGIN=0
                break
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done

    if [[ "$CONTINUE_LOGIN" -eq 0 ]]; then
        break
    fi
done

echo
echo "[*] Configuring Codex CLI..."

CODEX_DIR="$USER_HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
mkdir -p "$CODEX_DIR"

# Back up an existing config if present.
if [[ -f "$CODEX_CONFIG" ]]; then
    rm -f "$CODEX_CONFIG" 2>/dev/null || true
fi

cat > "$CODEX_CONFIG" <<EOF
model = "gpt-5.6-sol"
model_provider = "cliproxyapi"

model_context_window = 272000
model_reasoning_effort = "high"

[tui]
status_line = [
  "model-with-reasoning",
  "context-used",
  "permissions",
  "total-input-tokens",
  "total-output-tokens",
  "weekly-limit",
]
status_line_use_colors = true

[model_providers.cliproxyapi]
base_url = "http://127.0.0.1:8317/v1"
experimental_bearer_token = "cpa"
name = "OpenAI"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = true
EOF

chmod 600 "$CODEX_CONFIG"

echo "[+] Codex config written to:"
echo "    $CODEX_CONFIG"

cat > $USER_HOME/.codex/auth.json <<'EOF'
{
  "OPENAI_API_KEY": "cpa"
}
EOF

chmod 600 $USER_HOME/.codex/auth.json

# ------------------------------------------------------------
# 6. Start CPA
# ------------------------------------------------------------

echo
echo "[*] Starting CLIProxyAPI..."

sudo systemctl restart cliproxyapi.service

sleep 1

# ------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Setup complete"
echo "============================================================"
echo
echo "API:"
echo "  http://127.0.0.1:$CPA_PORT/v1"
echo
echo "API key:"
echo "  $CPA_API_KEY"
echo
echo "Management UI:"
echo "  http://127.0.0.1:$CPA_PORT/management.html"
echo
echo "Management key:"
echo "  $CPA_MANAGE_KEY"
echo
echo "Codex accounts logged in this run:"
echo "  $LOGIN_COUNT"
echo
echo "Auth files:"
find "$AUTH_DIR" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null || true

echo
echo "Useful commands:"
echo
echo "  sudo systemctl status cliproxyapi"
echo "  sudo systemctl restart cliproxyapi"
echo "  sudo systemctl stop cliproxyapi"
echo "  sudo journalctl -u cliproxyapi -f"
echo

sudo systemctl --no-pager --full status cliproxyapi.service || true
