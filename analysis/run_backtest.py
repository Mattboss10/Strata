"""
Week 4 backtest: does the dynamic fee actually beat a static fee on the same
price data?
"""

import numpy as np
from price_paths import generate_regime_switching_path, rolling_realized_vol_bps
from amm_sim import run_simulation

BASE_FEE_BPS = 30.0
MIN_FEE_BPS = 5.0
MAX_FEE_BPS = 100.0


def dynamic_fee_schedule(prices: np.ndarray, k_multiplier: float, vol_window: int = 24) -> np.ndarray:
    signal = rolling_realized_vol_bps(prices, window=vol_window)
    raw_fee = BASE_FEE_BPS + k_multiplier * signal
    return np.clip(raw_fee, MIN_FEE_BPS, MAX_FEE_BPS)


def summarize(label: str, res, prices) -> dict:
    fees = res.cumulative_fees_usd
    lvr = res.cumulative_lvr_usd
    net = res.net_pnl_usd
    coverage = fees / lvr if lvr > 0 else float("nan")
    print(f"{label:28s} | fees: ${fees:>10,.0f} | LVR: ${lvr:>10,.0f} | net: ${net:>11,.0f} | fee/LVR coverage: {coverage:.2f}x")
    return {"label": label, "fees": fees, "lvr": lvr, "net": net, "coverage": coverage}


def main():
    prices, regimes = generate_regime_switching_path(n_steps=24 * 90, seed=42)
    print(f"Simulated {len(prices)} hourly steps (~90 days). "
          f"{regimes.mean()*100:.0f}% of steps in the stressed-volatility regime.\n")

    results = []
    static_fee = np.full(len(prices), BASE_FEE_BPS)
    results.append(summarize("Static 30bps (baseline)", run_simulation(prices, static_fee), prices))

    static_fee_high = np.full(len(prices), MAX_FEE_BPS)
    results.append(summarize("Static 100bps (max, for reference)", run_simulation(prices, static_fee_high), prices))

    for k in [0.1, 0.2, 0.3, 0.5, 0.8]:
        dyn_fee = dynamic_fee_schedule(prices, k_multiplier=k)
        res = run_simulation(prices, dyn_fee)
        results.append(summarize(f"Dynamic, k={k}", res, prices))

    print("\nAverage dynamic fee charged at a few k values (sanity check it's actually moving):")
    for k in [0.1, 0.3, 0.8]:
        dyn_fee = dynamic_fee_schedule(prices, k_multiplier=k)
        print(f"  k={k}: mean={dyn_fee.mean():.1f}bps, min={dyn_fee.min():.1f}bps, max={dyn_fee.max():.1f}bps, "
              f"% of steps at ceiling={100*np.mean(dyn_fee >= MAX_FEE_BPS - 1e-9):.1f}%")

    return prices, regimes, results


if __name__ == "__main__":
    main()
