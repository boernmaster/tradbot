# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**signal-trader** is a Freqtrade + FreqAI algorithmic trading bot with automated GPU retraining on Vast.ai and 24/7 inference on a always-on server (RPi 4, NAS, mini-PC, or any x86_64/ARM64 Linux host). The LLM (Claude Haiku via OpenClaw) acts as a quant analyst and control interface only — it never places, modifies, or cancels orders.

## Three-Environment Architecture

```
Dev PC  ──►  Vast.ai RTX 3090 (ephemeral, ~€0.30/run)  ──►  Production host (24/7)
strategy       clone → download → train → backtest →           inference + trades
dev/git        quality gate → rsync to host → terminate        Freqtrade + FreqAI
```

**PC:** develops strategy, runs `vastai_train.sh` to kick off training. Never trains or runs live.

**Vast.ai:** provisions on demand, runs `entrypoint.sh` inside `Dockerfile.training`, self-terminates. SSH key injected via `RASPI_SSH_KEY_B64` env var (base64-encoded).

**Production host:** `docker-compose.raspi.yml` runs Freqtrade, signal-cli, and OpenClaw. Any Linux host works (RPi 4 ARM64, Synology NAS x86_64, etc.). All images are multi-arch — Docker pulls the correct variant automatically. Models and data live under `DATA_ROOT` (default `/mnt/ssd`).

## Key Commands

**Trigger a training run from PC:**
```bash
./vastai_train.sh                    # LightGBM (default, ~20 min, ~€0.10)
./vastai_train.sh --model lstm       # LSTM (~60 min, ~€0.30)
./vastai_train.sh --dry-run          # search for instance only, don't provision
```

**Run quality gate locally against a backtest result:**
```bash
python3 training/quality_gate.py /path/to/last_backtest.json
python3 training/quality_gate.py /path/to/last_backtest.json --sortino 2.0 --drawdown 15
python3 training/quality_gate.py /path/to/last_backtest.json --strategy MyStrategy
```

**Build and push the training Docker image (do this on PC after Dockerfile changes):**
```bash
docker build -f training/Dockerfile.training -t ghcr.io/boernmaster/tradbot-training:latest .
docker push ghcr.io/boernmaster/tradbot-training:latest
```

**On production host — start/restart the full stack:**
```bash
# DATA_ROOT defaults to /mnt/ssd; override for NAS or other paths
docker compose -f docker-compose.raspi.yml --env-file .environment up -d
docker compose -f docker-compose.raspi.yml --env-file .environment restart freqtrade
# Example for Synology NAS:
DATA_ROOT=/volume1/docker/tradbot-data docker compose -f docker-compose.raspi.yml --env-file .environment up -d
```

**Download dev data (Binance — Kraken requires --dl-trades and is too slow for dev):**
```bash
# First download (or extend backwards with --prepend):
docker compose -f docker-compose.dev.yml --env-file .environment run --rm freqtrade download-data \
  --exchange binance --pairs BTC/USDT ETH/USDT --timeframes 1h --days 500
# Extend backwards if data already exists:
docker compose -f docker-compose.dev.yml --env-file .environment run --rm freqtrade download-data \
  --exchange binance --pairs BTC/USDT ETH/USDT --timeframes 1h --days 500 --prepend
```

**Freqtrade backtest locally (dry-run dev, Binance data):**
```bash
docker compose -f docker-compose.dev.yml --env-file .environment run --rm freqtrade backtesting \
  --config /freqtrade/config.json \
  --config /freqtrade/config.freqai.json \
  --config /freqtrade/config.dev.json \
  --strategy LightGBMStrategy \
  --freqaimodel LightGBMRegressor \
  --timerange 20260101-20260228
```
Note: `config.dev.json` overrides exchange to `binance`. FreqAI needs ≥90 days of data
before the backtest start date. Data lives in `user_data/data/binance/`.

## Quality Gate Thresholds

`quality_gate.py` blocks deployment if any threshold fails (all overridable via CLI args):

| Metric | Default threshold |
|---|---|
| Sortino ratio | ≥ 1.5 |
| Max drawdown | ≤ 20% |
| Total trades | ≥ 20 |
| Win rate | ≥ 45% |

Exit 0 = deploy, exit 1 = do not deploy.

## Environment Configuration

Copy `.env.example` to `.environment` and fill in values. **Never commit `.environment`.**

Key vars required before first run:
- `VASTAI_API_KEY` — Vast.ai account API key
- `RASPI_SSH_KEY_B64` — `base64 -w0 ~/.ssh/vastai_raspi_key` (deploy key, not passphrase-protected)
- `RASPI_HOST`, `RASPI_USER` — RPi SSH target
- `KRAKEN_API_KEY`, `KRAKEN_SECRET` — trade-only permissions, withdrawal NEVER
- `ANTHROPIC_API_KEY` — for OpenClaw/Haiku
- `DRY_RUN=true` — set `false` only at Phase 7 live sign-off
- `TRAINING_IMAGE` — replace `YOURUSER` placeholder before first push

## Repository Structure

```
signal-trader/
├── freqtrade/
│   ├── config.json                   # Main Freqtrade config
│   ├── config.freqai.json            # FreqAI model config (LightGBM params, feature settings)
│   └── user_data/
│       ├── strategies/LightGBMStrategy.py
│       ├── models/                   # gitignored — rsync'd from Vast.ai
│       ├── data/                     # gitignored — downloaded fresh each run
│       └── backtest_results/         # gitignored — generated by backtesting command
├── openclaw/
│   ├── openclaw.json                 # cron: daily P&L summary at 20:00 Vienna
│   └── skills/freqtrade-trader/SKILL.md  # Haiku quant analyst skill (German)
├── training/
│   ├── Dockerfile.training           # GPU training image (PyTorch 2.3 + CUDA 12.1)
│   ├── entrypoint.sh                 # Full Vast.ai pipeline: clone→download→train→backtest→deploy
│   ├── download_data.sh              # Fetch Kraken OHLCV (stub — called by entrypoint.sh)
│   ├── train.sh                      # FreqAI training runner (stub — called by entrypoint.sh)
│   ├── backtest.sh                   # Backtest + save JSON (stub — called by entrypoint.sh)
│   ├── quality_gate.py               # Sortino/drawdown/win-rate check — exit 0/1
│   └── deploy_model.sh               # rsync model to prod host + restart Freqtrade
├── scripts/
│   ├── vastai_train.sh               # ONE COMMAND: provision → train → terminate
│   ├── vastai_search.sh              # Find cheapest RTX 3090
│   ├── server_setup.sh               # First-time setup: any Linux host (RPi, NAS, x86_64)
│   ├── raspi_setup.sh                # Shim → server_setup.sh (backward compat)
│   └── deploy_stack.sh               # Push configs PC → prod host via rsync
├── docker-compose.dev.yml            # PC local dev/test stack
├── docker-compose.raspi.yml          # Production stack (multi-arch, any Linux host)
└── .env.example                      # Copy to .environment and fill in values
```

## Model Progression Rules

Only upgrade the model type when the current one is stable and profitable in dry-run:
1. LightGBMRegressor (prototype + baseline production)
2. PyTorchLSTMRegressor (only after LightGBM baseline proven)
3. PyTorchTransformerModel (only after LSTM shows improvement)

## Key Constraints

- **Multi-arch images**: all production images are multi-arch. No `platform:` pins in `docker-compose.raspi.yml` — Docker auto-selects the right variant for x86_64 or ARM64. Images used: `freqtradeorg/freqtrade:stable_freqai`, `node:22-alpine`, `bbernhard/signal-cli-rest-api:latest`.
- **DATA_ROOT**: all persistent data (models, signal-cli, openclaw) lives under `DATA_ROOT` (default `/mnt/ssd`). Override in `.environment` for NAS paths like `/volume1/docker/tradbot-data`.
- **Vast.ai interruptible**: entrypoint.sh uses `set -e` and exits non-zero on failure; instance self-terminates when script exits.
- **`YOURUSER` placeholder**: replace in `Dockerfile.training`, `entrypoint.sh`, and `vastai_train.sh` with your actual GitHub username before first use.
- **FreqAI config**: `live_retrain_hours: 0` on prod host — inference only, no on-device retraining.
- **OpenClaw**: `allowFrom` must be set to your personal Signal number. Haiku (model: `claude-haiku-4-5-20251001`) reports in German and may start/stop the bot but must never call order endpoints.

## Development Phases

The plan is in `TRADING_AGENT_PLAN_v3.md`. Exit criteria per phase:

| Phase | Goal | Status |
|---|---|---|
| 1 | Freqtrade + FreqAI in Docker on PC, LightGBM strategy, dry-run | **complete** |
| 2 | Vast.ai one-command training pipeline | pipeline scripts drafted |
| 3 | OpenClaw skill for Freqtrade control | **complete** |
| 4 | Production host deployment (multi-arch Docker) | scripts done, host not set up |
| 5 | Signal integration on production host (full stack) | scripts done, host not set up |
| 6 | 7-day continuous dry-run | not started |
| 7 | Live trading sign-off | blocked by Phase 6 |
