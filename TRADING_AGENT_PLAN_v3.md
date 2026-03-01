# Signal Trading Agent — Development Plan v3

---

## Current Status  _(updated 2026-03-01)_

| Phase | Goal | Status |
|---|---|---|
| 1 | Freqtrade + FreqAI in Docker, LightGBM, local dry-run | ✅ Complete |
| 2 | Vast.ai one-command training pipeline | ⚠️ Scripts done — Vast.ai log streaming broken, **deferred** |
| 2b | **Local training workflow** (new) | 🔄 Active — `scripts/local_train.sh` created |
| 3 | OpenClaw / Haiku skill | ✅ Complete |
| 4 | Prod host deployment (multi-arch Docker) | 🟡 Scripts done, host not configured |
| 5 | Signal integration on prod host | 🟡 Scripts done, host not configured |
| 6 | 7-day continuous dry-run | ⬜ Not started |
| 7 | Live trading sign-off | ⬜ Blocked by Phase 6 |

### Active work
- Training LightGBM locally with `scripts/local_train.sh` (BTC/USDT + ETH/USDT, Binance data)
- Tuned strategy: `stoploss -0.10`, `trailing_stop: true`, `entry_threshold: 0.02`
- Target: quality gate pass (Sortino ≥ 1.5, drawdown ≤ 20%)

### Deferred / TODO
- **Vast.ai log streaming** — `vastai_monitor.sh --logs` blocked by Vast.ai `.bashrc` `exec tmux` on all non-interactive SSH; sftp subsystem also unconfigured. Fix options: patch sshd in onstart.sh, or add HTTP log server to training image.
- **Prod host setup** — Phase 4: configure NAS or RPi as prod host, set `RASPI_HOST` etc. in `.environment`
- **Vast.ai pipeline end-to-end** — resume Phase 2 once local baseline is proven

### Last backtest (2026-02-28, local machine)
- Trades: 95 | Win rate: 65.3% ✅ | Drawdown: 4.44% ✅ | Sortino: -30.56 ❌
- Market was -36.45% bear — stoploss triggered too often. Strategy tuned above.

---

## Architecture Overview

Three distinct roles across three environments.

```
┌─────────────────────┐     ┌──────────────────────────┐     ┌─────────────────────┐
│      DEV PC         │     │   VAST.AI (on-demand)    │     │   RASPBERRY PI 4    │
│                     │     │                          │     │                     │
│  - Claude Code      │     │  - RTX 3090 GPU          │     │  - Freqtrade        │
│  - Strategy dev     │     │  - Download Kraken data  │     │  - FreqAI inference │
│  - Docker testing   │────►│  - FreqAI training       │────►│  - OpenClaw         │
│  - Git repo         │     │  - Backtesting           │     │  - signal-cli       │
│  - vastai CLI       │     │  - Hyperopt              │     │  - 24/7 execution   │
│                     │     │  - Quality gate check    │     │  - No training      │
│  Spins up/down      │     │  - rsync model → RPi     │     │  ARM64 Docker       │
│  Vast.ai instances  │     │  - Self-terminates       │     │  USB SSD required   │
└─────────────────────┘     └──────────────────────────┘     └─────────────────────┘
         │                           │                                  │
    vastai CLI                 ~1hr, ~€0.30                      model loaded
    one command                then gone                          at startup
```

**Flow:** PC triggers training → Vast.ai provisions GPU, trains, validates, pushes model to RPi, terminates → RPi loads new model automatically.

---

## Stack Decisions

| Component | Choice | Reason |
|---|---|---|
| Execution engine | **Freqtrade + FreqAI** | Backtesting, Kraken support, ARM64 Docker, REST API |
| ML model (prototype) | **LightGBMRegressor** | CPU-optimized, trains on PC locally, fast iteration |
| ML model (production) | **LSTM / CNN+Transformer** | GPU-trained on Vast.ai, richer temporal patterns |
| GPU training | **Vast.ai RTX 3090** | ~€0.30/run, interruptible, no persistent cost |
| LLM control | **Haiku via OpenClaw** | Strategy analyst + control interface, not trade executor |
| Messaging | **signal-cli + OpenClaw** | Signal on phone |
| Inference | **RPi 4 8GB** | 24/7, low power, LightGBM/LSTM inference is CPU-light |
| Training trigger | **vastai CLI from PC** | One command, fully automated, self-terminating |

---

## Machine Profiles

### PC — Development + Training Orchestration
- Claude Code runs here
- Docker for local testing (x86, arm64 emulation for RPi validation)
- Git repo lives here
- `vastai` CLI installed — triggers training runs remotely
- **Never trains models directly, never runs live**

### Vast.ai Instance — Ephemeral Training
- Provisioned on-demand by script, terminated when done
- RTX 3090, 24GB VRAM, CUDA 12+, PyTorch preinstalled
- Clones repo, downloads Kraken data, trains model
- Runs backtest quality gate — deploys to RPi only if passing
- rsync model files directly to RPi over SSH
- **Self-terminates after successful deploy or on failure**
- Cost: ~€0.30 per weekly retrain (LSTM), ~€0.05 (LightGBM)

### Raspberry Pi 4 (8GB) — 24/7 Production
- Runs Freqtrade in inference-only mode
- Loads pre-trained model from `user_data/models/` at startup
- Executes trades on Kraken via ccxt
- Runs OpenClaw + signal-cli for Signal interface
- **Always on, USB SSD mandatory**

---

## Prerequisites

### PC
- [ ] Anthropic API key (`console.anthropic.com`, ~€10 credit)
- [ ] Vast.ai account created, credit loaded (~$10 to start)
- [ ] `vastai` CLI installed: `pip install vastai`
- [ ] Vast.ai API key: `vastai set api-key <your_key>`
- [ ] SSH keypair generated: `ssh-keygen -t ed25519 -C "vastai-training"`
- [ ] SSH public key uploaded to Vast.ai account settings
- [ ] Docker installed (for local testing)
- [ ] Claude Code installed

### Vast.ai (automated, handled by scripts)
- [ ] SSH public key in account → instances get it automatically
- [ ] Training Docker image built and pushed to GHCR or Docker Hub
- [ ] `RASPI_HOST`, `RASPI_USER`, `RASPI_SSH_KEY` available as Vast.ai env vars

### Raspberry Pi 4
- [ ] 64-bit Raspberry Pi OS (mandatory for full 8GB RAM)
- [ ] USB SSD mounted at `/mnt/ssd`, Docker data-root on SSD
- [ ] Static local IP configured
- [ ] SSH key from Vast.ai training instance authorized (`~/.ssh/authorized_keys`)
- [ ] Bot phone number (second SIM or VoIP, e.g. Magenta prepaid AT)
- [ ] Kraken API key (trade-only, no withdrawals)
- [ ] Port 22 accessible from Vast.ai (via local network or tailscale/ngrok)

---

## Repository Structure

```
signal-trader/
├── freqtrade/
│   ├── config.json                   # Main Freqtrade config
│   ├── config.freqai.json            # FreqAI model config
│   └── user_data/
│       ├── strategies/
│       │   └── LightGBMStrategy.py
│       ├── models/                   # .gitignore — rsync'd from Vast.ai
│       └── data/                     # .gitignore — downloaded fresh each run
│
├── openclaw/
│   ├── openclaw.json
│   └── skills/
│       └── freqtrade-trader/
│           └── SKILL.md
│
├── training/
│   ├── Dockerfile.training           # GPU training image
│   ├── entrypoint.sh                 # Full pipeline: download→train→backtest→deploy
│   ├── download_data.sh              # Fetch Kraken OHLCV
│   ├── train.sh                      # FreqAI training
│   ├── backtest.sh                   # Backtest + parse results
│   ├── quality_gate.py               # Sortino/drawdown check
│   └── deploy_model.sh               # rsync to RPi if gate passes
│
├── scripts/
│   ├── vastai_train.sh               # ONE COMMAND: provision → train → terminate
│   ├── vastai_search.sh              # Find cheapest suitable instance
│   ├── raspi_setup.sh                # First-time RPi setup
│   └── deploy_stack.sh               # Push configs from PC to RPi
│
├── docker-compose.raspi.yml          # Full RPi production stack
├── docker-compose.dev.yml            # Local dev/test stack (PC)
├── .environment.example
└── .gitignore                        # models/, data/, .env
```

---

## Phase 1 — Strategy Development on PC

**Goal:** Working Freqtrade + FreqAI strategy, validated locally in Docker.
**Training on PC (LightGBM is fast enough — no GPU needed yet).**

### Claude Code session prompt

```
Set up Freqtrade with FreqAI in Docker on this machine using docker-compose.dev.yml.
Use Kraken exchange in dry-run mode with sandbox credentials.
Create a LightGBMRegressor strategy with RSI, MACD, EMA, volume features.
Target pairs: BTC/USDT, ETH/USDT, 1h timeframe.
Enable FreqAI with live_retrain_hours: 0 (fixed model, no live retraining).
Expose Freqtrade web UI at localhost:8080.
Run a short backtest to validate everything works.
```

### Freqtrade + FreqAI config (key settings)

```json
{
  "exchange": { "name": "kraken" },
  "dry_run": true,
  "stake_currency": "USDT",
  "stake_amount": 50,
  "max_open_trades": 3,
  "timeframe": "1h",
  "freqai": {
    "enabled": true,
    "model_type": "LightGBMRegressor",
    "train_period_days": 90,
    "backtest_period_days": 7,
    "live_retrain_hours": 0,
    "fit_live_predictions_candles": 0
  }
}
```

### Feature engineering (strategy file)

```python
def feature_engineering_expand_all(self, dataframe, period, **kwargs):
    dataframe["%-rsi"]         = ta.RSI(dataframe, timeperiod=period)
    dataframe["%-macd"]        = ta.MACD(dataframe).macd
    dataframe["%-ema"]         = ta.EMA(dataframe, timeperiod=period)
    dataframe["%-volume_mean"] = dataframe["volume"].rolling(period).mean()
    dataframe["%-close_pct"]   = dataframe["close"].pct_change(period)
    dataframe["%-hl_ratio"]    = dataframe["high"] / dataframe["low"]
    dataframe["%-atr"]         = ta.ATR(dataframe, timeperiod=period)
    return dataframe
```

### Exit criteria

- [ ] Freqtrade + FreqAI starts in Docker on PC
- [ ] LightGBM model trains locally on downloaded data
- [ ] Web UI at `localhost:8080`
- [ ] Backtest produces report with Sortino, drawdown, win rate
- [ ] Dry-run generates buy/sell signals

---

## Phase 2 — Vast.ai Training Pipeline

**Goal:** Full automated training pipeline runs on Vast.ai GPU. One command from PC provisions instance, trains, validates, deploys to RPi, terminates.

### Claude Code session prompt

```
Build the Vast.ai training pipeline in ./training/ and ./scripts/.

Deliverables:
1. training/Dockerfile.training — GPU image with FreqAI, PyTorch, LightGBM
2. training/entrypoint.sh — full pipeline (download → train → backtest → gate → deploy → terminate)
3. training/quality_gate.py — parse backtest JSON, check Sortino ≥ 1.5 and drawdown ≤ 20%
4. scripts/vastai_train.sh — provision RTX 3090 interruptible on Vast.ai, run entrypoint, auto-terminate
5. scripts/vastai_search.sh — find cheapest available instance matching our filters

Requirements:
- vastai CLI for provisioning (pip install vastai)
- Instance: RTX 3090, interruptible, ≥16GB RAM, ≥20GB disk, CUDA 12+, Europe preferred
- Instance receives RASPI_HOST, RASPI_USER, RASPI_SSH_KEY_B64 as env vars
- On success: rsync models/ to RPi, restart freqtrade container, then self-terminate
- On failure: send failure signal (write to /tmp/training_failed), then terminate
- Full run should complete in under 90 minutes
```

### `scripts/vastai_train.sh` (what Claude Code should produce)

```bash
#!/bin/bash
# Usage: ./scripts/vastai_train.sh
# Provisions a Vast.ai GPU instance, runs training pipeline, auto-terminates.

set -e
source .environment

# Find cheapest RTX 3090 in Europe
INSTANCE_ID=$(vastai search offers \
  'gpu_name=RTX_3090 \
   rentable=true \
   num_gpus=1 \
   inet_down>200 \
   cpu_ram>16 \
   disk_space>20 \
   reliability>0.95 \
   geolocation=EU' \
  -o dph_total \
  --limit 1 \
  --raw | jq -r '.[0].id')

echo "▶ Provisioning instance $INSTANCE_ID..."

LAUNCHED=$(vastai create instance $INSTANCE_ID \
  --image ghcr.io/YOURUSER/signal-trader-training:latest \
  --env "RASPI_HOST=$RASPI_HOST" \
  --env "RASPI_USER=$RASPI_USER" \
  --env "RASPI_SSH_KEY_B64=$RASPI_SSH_KEY_B64" \
  --env "KRAKEN_PAIRS=$KRAKEN_PAIRS" \
  --disk 20 \
  --onstart "bash /app/training/entrypoint.sh" \
  --raw)

RUNNING_ID=$(echo $LAUNCHED | jq -r '.new_contract')
echo "▶ Instance $RUNNING_ID started. Watching logs..."

# Tail logs until training completes
vastai logs $RUNNING_ID --tail 100 &

# Poll until instance self-terminates (entrypoint exits)
while vastai show instance $RUNNING_ID --raw | jq -e '.actual_status == "running"' > /dev/null 2>&1; do
  sleep 30
done

echo "✅ Training instance finished and terminated."
```

### `training/entrypoint.sh` (pipeline on the GPU instance)

```bash
#!/bin/bash
# Runs inside the Vast.ai Docker container
set -e

cd /app

echo "=== [1/5] Cloning latest strategy ==="
git clone https://github.com/YOURUSER/signal-trader.git .

echo "=== [2/5] Downloading Kraken data ==="
bash training/download_data.sh

echo "=== [3/5] Training FreqAI model ==="
bash training/train.sh

echo "=== [4/5] Running backtest ==="
bash training/backtest.sh

echo "=== [5/5] Quality gate + deploy ==="
python3 training/quality_gate.py backtest_results.json
if [ $? -eq 0 ]; then
  echo "✅ Quality gate passed. Deploying to RPi..."
  bash training/deploy_model.sh
else
  echo "❌ Quality gate failed. Not deploying."
fi

echo "=== Training complete. Instance will terminate. ==="
# Vast.ai terminates when the --onstart script exits
```

### `training/quality_gate.py`

```python
#!/usr/bin/env python3
import json, sys

with open(sys.argv[1]) as f:
    results = json.load(f)

sortino   = results["strategy"]["LightGBMStrategy"]["sortino"]
drawdown  = results["strategy"]["LightGBMStrategy"]["max_drawdown"] * 100
win_rate  = results["strategy"]["LightGBMStrategy"]["wins"] / results["strategy"]["LightGBMStrategy"]["total_trades"] * 100

print(f"Sortino: {sortino:.2f} (min 1.5)")
print(f"Drawdown: {drawdown:.1f}% (max 20%)")
print(f"Win rate: {win_rate:.1f}%")

if sortino < 1.5:
    print("FAIL: Sortino below threshold")
    sys.exit(1)
if drawdown > 20:
    print("FAIL: Drawdown too high")
    sys.exit(1)

print("PASS: Model meets quality gate")
sys.exit(0)
```

### `training/Dockerfile.training`

```dockerfile
FROM pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime

RUN apt-get update && apt-get install -y \
    git rsync openssh-client curl jq \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    freqtrade[freqai] \
    lightgbm \
    torch \
    scikit-learn \
    pandas-ta

WORKDIR /app

# SSH key injected at runtime via RASPI_SSH_KEY_B64 env var
# entrypoint.sh decodes and sets it up
CMD ["bash", "/app/training/entrypoint.sh"]
```

### `training/deploy_model.sh`

```bash
#!/bin/bash
set -e

# Decode SSH key from env
echo "$RASPI_SSH_KEY_B64" | base64 -d > /tmp/raspi_key
chmod 600 /tmp/raspi_key

SSH="ssh -i /tmp/raspi_key -o StrictHostKeyChecking=no $RASPI_USER@$RASPI_HOST"
RSYNC="rsync -avz -e 'ssh -i /tmp/raspi_key -o StrictHostKeyChecking=no'"

echo "Deploying models to RPi..."
$RSYNC freqtrade/user_data/models/ \
  $RASPI_USER@$RASPI_HOST:/mnt/ssd/freqtrade/user_data/models/

echo "Restarting Freqtrade on RPi..."
$SSH "cd /mnt/ssd/signal-trader && docker compose restart freqtrade"

echo "✅ Model deployed. Freqtrade restarted with new model."

# Notify via RPi (optional — writes a file that triggers Signal notification)
$SSH "echo 'Neues Modell deployed.' > /mnt/ssd/freqtrade/user_data/model_update.txt"
```

### Cost summary

| Run type | GPU | Duration | Cost |
|---|---|---|---|
| LightGBM weekly | RTX 3090 interruptible | ~20 min | ~€0.10 |
| LSTM weekly | RTX 3090 interruptible | ~60 min | ~€0.30 |
| CNN+Transformer | RTX 3090 interruptible | ~90 min | ~€0.50 |
| Hyperopt (occasional) | RTX 3090 interruptible | ~3 hrs | ~€1.00 |
| **Monthly total (LSTM)** | | | **~€1.50** |

### Exit criteria

- [ ] `./scripts/vastai_train.sh` provisions instance with one command
- [ ] Training pipeline runs end-to-end without intervention
- [ ] Quality gate correctly blocks a bad model and passes a good one
- [ ] Model files appear on RPi after successful run
- [ ] Freqtrade restarts with new model on RPi
- [ ] Instance terminates itself after pipeline exits
- [ ] Total cost per run logged and within budget

---

## Phase 3 — OpenClaw Skill

**Goal:** Haiku reads Freqtrade state, interprets backtest results, controls start/stop. Does NOT make trade decisions.

### Claude Code session prompt

```
Create the OpenClaw skill in ./openclaw/skills/freqtrade-trader/SKILL.md.
The skill connects Haiku to:
1. Freqtrade REST API at http://freqtrade:8080/api/v1/
2. Latest backtest report at /mnt/ssd/freqtrade/user_data/backtest_results/

Haiku's role: quant analyst.
- Reports portfolio status in German
- Interprets Sortino, drawdown, win rate (good/bad thresholds)
- Suggests parameter adjustments based on performance
- Starts and stops the bot
- Reads model_update.txt and reports new model deployments

Haiku must NEVER place, modify, or cancel individual orders.
All trade decisions are deterministic Freqtrade strategy logic.
```

### Key Freqtrade REST endpoints for the skill

```
GET  /api/v1/status          Open trades + unrealized P&L
GET  /api/v1/profit          Total profit, Sharpe, trade count
GET  /api/v1/performance     Per-pair breakdown
GET  /api/v1/balance         Portfolio balances
GET  /api/v1/trades          Trade history
GET  /api/v1/logs            Last N log lines
GET  /api/v1/freqai/info     Current model metadata
POST /api/v1/start           Start bot
POST /api/v1/stop            Stop bot
POST /api/v1/forceexit/{id}  Emergency exit specific trade
```

### Test queries

```
Was sind die aktuellen offenen Trades?
Wie ist die Performance diese Woche?
Analysiere den letzten Backtest — soll ich das Modell deployen?
Stop den Bot, ich bin auf Urlaub bis Freitag
Zeig mir den Gewinn seit Monatsbeginn
Welche Pairs performen am schlechtesten?
Wurde ein neues Modell deployed?
Wie hoch ist mein maximaler Drawdown heute?
```

### Exit criteria

- [ ] Skill connects to Freqtrade API cleanly
- [ ] All queries return natural German responses
- [ ] Haiku never attempts to place orders
- [ ] Start/stop commands work
- [ ] Model update notifications work

---

## Phase 4 — RPi Freqtrade Deployment

**Goal:** Freqtrade running 24/7 on RPi, loading pre-trained model, inference only.

### Claude Code session prompt

```
Create docker-compose.raspi.yml for the RPi.
Requirements:
- freqtradeorg/freqtrade:stable_freqai (ARM64 compatible)
- All user_data mounted from USB SSD at /mnt/ssd/freqtrade/user_data/
- Web UI bound to LAN IP only (not 0.0.0.0)
- live_retrain_hours: 0 in config (no on-device retraining)
- SSH server accessible for Vast.ai rsync (or configure rsync over existing SSH)
- All env vars from .env file

Also create scripts/raspi_setup.sh for first-time setup:
- Format and mount USB SSD
- Move Docker data-root to SSD
- Configure static IP
- Enable SSH
- Create directory structure
```

### docker-compose.raspi.yml (Freqtrade only, for this phase)

```yaml
services:
  freqtrade:
    image: freqtradeorg/freqtrade:stable_freqai
    platform: linux/arm64
    restart: unless-stopped
    volumes:
      - /mnt/ssd/freqtrade/user_data:/freqtrade/user_data
    ports:
      - "${RASPI_LAN_IP}:8080:8080"
    command: >
      trade
      --config /freqtrade/user_data/config.json
      --config /freqtrade/user_data/config.freqai.json
      --strategy LightGBMStrategy
    env_file: .environment
    environment:
      - FREQTRADE__API_SERVER__ENABLED=true
      - FREQTRADE__API_SERVER__LISTEN_IP_ADDRESS=0.0.0.0
      - FREQTRADE__API_SERVER__USERNAME=${FREQTRADE_USERNAME}
      - FREQTRADE__API_SERVER__PASSWORD=${FREQTRADE_PASSWORD}
```

### Exit criteria

- [ ] Freqtrade starts on RPi with ARM64 image
- [ ] Pre-trained model loads (no retraining at boot)
- [ ] Web UI accessible from PC at `http://RASPI_IP:8080`
- [ ] Dry-run trades executing
- [ ] Stack survives RPi reboot
- [ ] All writes going to USB SSD

---

## Phase 5 — Signal Integration on RPi

**Goal:** Full stack on RPi — Freqtrade + OpenClaw + signal-cli in one Compose file.

### Claude Code session prompt

```
Extend docker-compose.raspi.yml with signal-cli and OpenClaw services.
Configure OpenClaw:
- Model: claude-haiku-4-5-20251001 via ANTHROPIC_API_KEY
- Signal channel: bot number from OPENCLAW_BOT_NUMBER env var
- allowFrom: OPENCLAW_ALLOW_FROM env var only (personal number)
- Skill: mounted from ./openclaw/skills/
- Daily cron at 20:00 Europe/Vienna for P&L summary

Register the signal-cli bot number during setup.
Verify end-to-end: Signal message → OpenClaw → Haiku → Freqtrade API → Signal reply.
```

### Full docker-compose.raspi.yml

```yaml
services:
  freqtrade:
    image: freqtradeorg/freqtrade:stable_freqai
    platform: linux/arm64
    restart: unless-stopped
    volumes:
      - /mnt/ssd/freqtrade/user_data:/freqtrade/user_data
    ports:
      - "${RASPI_LAN_IP}:8080:8080"
    command: >
      trade
      --config /freqtrade/user_data/config.json
      --config /freqtrade/user_data/config.freqai.json
      --strategy LightGBMStrategy
    env_file: .environment

  signal-cli:
    image: bbernhard/signal-cli-rest-api:latest
    restart: unless-stopped
    volumes:
      - /mnt/ssd/signal-data:/home/.local/share/signal-cli
    environment:
      - MODE=json-rpc

  openclaw:
    image: node:22-alpine
    platform: linux/arm64
    restart: unless-stopped
    working_dir: /app
    command: sh -c "npm install -g openclaw@latest && openclaw gateway --port 18789"
    volumes:
      - /mnt/ssd/openclaw:/root/.openclaw
      - ./openclaw/skills:/root/.openclaw/workspace/skills
    depends_on:
      - signal-cli
      - freqtrade
    env_file: .environment
```

### Cron job (openclaw.json)

```json
{
  "cron": [
    {
      "schedule": "0 20 * * *",
      "timezone": "Europe/Vienna",
      "message": "Tages-Zusammenfassung: Portfolio-Wert, heutiger P&L, Anzahl Trades, Risk-Status, aktuelle offene Positionen."
    }
  ]
}
```

### Exit criteria

- [ ] All three services start with `docker compose -f docker-compose.raspi.yml --env-file .environment up -d`
- [ ] Signal message → reply in under 5 seconds
- [ ] Daily summary at 20:00 Vienna time
- [ ] Stack survives full RPi reboot
- [ ] All data on USB SSD

---

## Phase 6 — Hardening + Dry-Run Week

**Goal:** 7 days continuous dry-run, zero manual intervention, everything stable.

### Daily Signal checks

```
Wie ist der Status heute?          → trades, P&L
Zeig mir die letzten 10 Trades     → signal quality
Irgendwelche Fehler heute?         → log check
Wie läuft das Modell?              → FreqAI model info
```

### Exit criteria

- [ ] 7 days continuous dry-run
- [ ] No crashes or missed daily summaries
- [ ] Vast.ai retrain ran once and deployed successfully
- [ ] Model deployed by Vast.ai loaded without manual steps
- [ ] Signal notification for model deployment arrived

---

## Phase 7 — Live Trading Sign-off

**Only after Phase 6 passes completely.**

### Checklist

- [ ] Backtest Sortino ≥ 1.5 on most recent 3-month period
- [ ] Max drawdown ≤ 20% in backtest
- [ ] Kraken API key confirmed trade-only (no withdrawal permission)
- [ ] Daily loss limit: €50 (conservative start)
- [ ] Max per-trade: €25–50 for first two weeks
- [ ] Kill switch tested: "Stop den Bot" via Signal → confirmed stopped

### Go live

```bash
# On RPi
sed -i 's/DRY_RUN=true/DRY_RUN=false/' .environment
docker compose -f docker-compose.raspi.yml --env-file .environment restart freqtrade
```

---

## Retraining Workflow (Weekly, Ongoing)

```
Every Sunday evening:

PC:
  $ ./scripts/vastai_train.sh
  ↓
  Searches for cheapest RTX 3090 in EU (interruptible)
  Provisions instance with training Docker image
  ↓

Vast.ai instance (auto):
  1. Clone latest strategy from git
  2. Download latest 12mo Kraken OHLCV data
  3. Train LightGBM / LSTM model (FreqAI)
  4. Run backtest on last 30 days
  5. quality_gate.py: Sortino ≥ 1.5, Drawdown ≤ 20%?
     ├─ PASS → rsync models/ to RPi
     │          SSH: docker compose restart freqtrade
     │          Write model_update.txt → triggers Signal notification
     │          Terminate instance ✅
     └─ FAIL → Log failure details
               Terminate instance (no deploy) ❌

RPi (auto):
  Freqtrade restarts with new model
  OpenClaw sends Signal notification:
  "Neues Modell deployed. Sortino: 1.8, Drawdown: 12%, Win Rate: 61%"
```

**Total elapsed time:** ~60–90 min
**Total cost:** ~€0.30–0.50
**Human effort:** one command

---

## Model Progression

| Stage | Model | Where trained | Notes |
|---|---|---|---|
| Phase 1–2 (dev) | LightGBM | PC locally | Fast iteration, no GPU needed |
| Phase 2+ (production) | LightGBM | Vast.ai RTX 3090 | Baseline production |
| Phase 3+ (upgrade) | LSTM (FreqAI PyTorch) | Vast.ai RTX 3090 | Only if LightGBM baseline proven |
| Later | CNN + Transformer | Vast.ai RTX 3090 | Only if LSTM shows improvement |

**Rule:** never upgrade the model until the current one is stable and profitable in dry-run.

---

## RAM Budget on RPi 4 (8GB)

| Service | Idle | Peak |
|---|---|---|
| OS + system | ~400MB | ~500MB |
| Freqtrade (inference) | ~300MB | ~600MB |
| LightGBM inference | ~50MB | ~200MB |
| signal-cli (Java) | ~200MB | ~250MB |
| OpenClaw (Node) | ~150MB | ~250MB |
| **Total** | **~1.1GB** | **~1.8GB** |

~6GB headroom. Comfortable.

---

## Environment Variables (.environment.example)

```bash
# ── Exchange ───────────────────────────────────────────────
KRAKEN_API_KEY=
KRAKEN_SECRET=
DRY_RUN=true                    # false only for Phase 7 sign-off

# ── Anthropic ─────────────────────────────────────────────
ANTHROPIC_API_KEY=

# ── OpenClaw / Signal ─────────────────────────────────────
OPENCLAW_BOT_NUMBER=+43XXXXXXXXX
OPENCLAW_ALLOW_FROM=+43XXXXXXXXX   # Your personal number

# ── Freqtrade web UI ──────────────────────────────────────
FREQTRADE_USERNAME=trader
FREQTRADE_PASSWORD=
RASPI_LAN_IP=192.168.x.x           # RPi LAN IP for port binding

# ── Vast.ai training ──────────────────────────────────────
VASTAI_API_KEY=
KRAKEN_PAIRS=BTC/USDT,ETH/USDT    # Pairs to download + train on

# ── RPi SSH (used by Vast.ai deploy_model.sh) ─────────────
RASPI_HOST=192.168.x.x
RASPI_USER=pi
RASPI_SSH_KEY_B64=                 # base64 -w0 ~/.ssh/vastai_raspi_key
# IMPORTANT: This key must be in RPi ~/.ssh/authorized_keys
# Vast.ai instance uses this to rsync models and restart Freqtrade
```

---

## Security Notes

- Vast.ai instances are ephemeral — no credentials stored on them beyond the run
- `RASPI_SSH_KEY_B64` is a deploy-only key (no sudo, no shell access ideally)
- Kraken API key: trade-only, withdrawal disabled — enforce this in Kraken dashboard
- OpenClaw `allowFrom` locks Signal to your personal number only
- Freqtrade web UI binds to LAN IP only, never `0.0.0.0`
- All secrets in `.env` which is gitignored

---

## Key Constraints

**RPi — no GPU, ARM64**
- LightGBM and LSTM inference runs fine on ARM CPU (milliseconds per prediction)
- All Docker images must have linux/arm64 variants
- USB SSD mandatory — SD card dies under SQLite write load

**Vast.ai — ephemeral, interruptible**
- Interruptible instances can be reclaimed — entrypoint.sh should checkpoint
- Always terminate after pipeline exits (billing stops immediately)
- Never store persistent data on Vast.ai instance

**LLM — analyst only**
- Haiku reads results and controls start/stop
- Zero direct order placement, ever
- Trade decisions are 100% deterministic Freqtrade strategy

---

## Deferred / Known Issues

### Vast.ai log streaming (low priority)
`vastai_monitor.sh --logs` cannot stream `/var/log/onstart.log` because:
1. Vast.ai's `.bashrc` does `exec tmux new-session` on all SSH connections — even non-interactive ones. `exec` replaces bash, so any command passed to SSH never runs.
2. The sftp subsystem is not configured in Vast.ai's sshd — sftp exits with code 1 immediately.
`--logs` currently falls back to `vastai logs` API polling (shows container stdout, not onstart.log).

**Fix options (pick one when resuming Vast.ai work):**
- A. In `vastai_train.sh` onstart script: add sftp subsystem + `sed -i '/exec tmux/d' ~/.bashrc` + restart sshd, then monitor can sftp-poll the log file.
- B. Add a small Python HTTP server to the training image that serves `/var/log/onstart.log` on port 8080. Monitor fetches via `curl` through the `-L 8080:localhost:8080` SSH tunnel.

### Local training scripts
- `scripts/local_train.sh` — created 2026-03-01
- Uses `docker-compose.dev.yml` + Binance data (fast, no --dl-trades)
- Runs FreqAI walk-forward backtest, quality gate, optional `--deploy` to prod host
