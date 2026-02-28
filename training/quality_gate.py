#!/usr/bin/env python3
"""
quality_gate.py
Parses a Freqtrade backtest JSON result and checks minimum quality thresholds.
Exits 0 if the model passes, 1 if it fails.

Usage:
    python3 quality_gate.py /path/to/last_backtest.json
    python3 quality_gate.py /path/to/last_backtest.json --sortino 2.0 --drawdown 15
"""

import json
import sys
import argparse

# ── Thresholds (can override via args) ────────────────────────────────────────
DEFAULT_MIN_SORTINO   = 1.5
DEFAULT_MAX_DRAWDOWN  = 20.0   # percent
DEFAULT_MIN_TRADES    = 20     # too few trades = unreliable stats
DEFAULT_MIN_WIN_RATE  = 45.0   # percent

PASS  = "\033[92m✅ PASS\033[0m"
FAIL  = "\033[91m❌ FAIL\033[0m"
INFO  = "\033[94mℹ️  INFO\033[0m"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("result_file", help="Path to Freqtrade backtest JSON")
    p.add_argument("--sortino",   type=float, default=DEFAULT_MIN_SORTINO)
    p.add_argument("--drawdown",  type=float, default=DEFAULT_MAX_DRAWDOWN)
    p.add_argument("--min-trades",type=int,   default=DEFAULT_MIN_TRADES)
    p.add_argument("--win-rate",  type=float, default=DEFAULT_MIN_WIN_RATE)
    p.add_argument("--strategy",  type=str,   default=None)
    return p.parse_args()


def load_results(path):
    with open(path) as f:
        data = json.load(f)
    # Freqtrade backtest JSON structure
    strategies = data.get("strategy", data.get("strategy_comparison", {}))
    return strategies


def check(label, value, threshold, mode="min", unit=""):
    ok = (value >= threshold) if mode == "min" else (value <= threshold)
    symbol = PASS if ok else FAIL
    comp = f">= {threshold}" if mode == "min" else f"<= {threshold}"
    print(f"  {symbol}  {label}: {value:.2f}{unit}  (required: {comp}{unit})")
    return ok


def main():
    args = parse_args()

    try:
        strategies = load_results(args.result_file)
    except FileNotFoundError:
        print(f"❌ Result file not found: {args.result_file}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"❌ Invalid JSON in result file: {e}")
        sys.exit(1)

    # Find strategy name
    if args.strategy:
        strat_name = args.strategy
    else:
        strat_name = next(iter(strategies))

    if strat_name not in strategies:
        print(f"❌ Strategy '{strat_name}' not found in results.")
        print(f"   Available: {list(strategies.keys())}")
        sys.exit(1)

    s = strategies[strat_name]

    # Extract metrics
    total_trades = s.get("total_trades", 0)
    wins         = s.get("wins", 0)
    losses       = s.get("losses", 0)
    win_rate     = (wins / total_trades * 100) if total_trades > 0 else 0
    sortino      = s.get("sortino", 0)
    max_drawdown = s.get("max_drawdown", s.get("max_drawdown_abs", 0))
    if max_drawdown < 1:
        max_drawdown *= 100  # convert fraction to percent if needed
    profit_pct   = s.get("profit_total_abs", s.get("profit_mean", 0))
    sharpe       = s.get("sharpe", 0)

    print(f"\n{'='*50}")
    print(f"  Quality Gate — {strat_name}")
    print(f"{'='*50}")
    print(f"  {INFO}  Period: {s.get('backtest_start', '?')} → {s.get('backtest_end', '?')}")
    print(f"  {INFO}  Trades: {total_trades}  |  Wins: {wins}  |  Losses: {losses}")
    print(f"  {INFO}  Total profit: {profit_pct:.2f}%")
    print(f"  {INFO}  Sharpe: {sharpe:.2f}")
    print()

    results = [
        check("Sortino ratio",  sortino,      args.sortino,    mode="min"),
        check("Max drawdown",   max_drawdown, args.drawdown,   mode="max", unit="%"),
        check("Total trades",   total_trades, args.min_trades, mode="min"),
        check("Win rate",       win_rate,     args.win_rate,   mode="min", unit="%"),
    ]

    print()
    passed = all(results)

    if passed:
        print(f"  {PASS}  Model meets all quality thresholds. Deploying.\n")
        sys.exit(0)
    else:
        failed = sum(1 for r in results if not r)
        print(f"  {FAIL}  {failed} threshold(s) not met. Not deploying.\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
