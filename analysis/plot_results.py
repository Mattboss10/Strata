"""
Generates the three-panel backtest chart: price path with regime shading, the fee
schedule over time, and cumulative LP net P&L. Run this after run_backtest.py works.
"""

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from price_paths import generate_regime_switching_path
from amm_sim import run_simulation
from run_backtest import BASE_FEE_BPS, MAX_FEE_BPS, dynamic_fee_schedule


def main():
    prices, regimes = generate_regime_switching_path(n_steps=24 * 90, seed=42)
    t = np.arange(len(prices)) / 24.0

    static_30 = np.full(len(prices), BASE_FEE_BPS)
    static_100 = np.full(len(prices), MAX_FEE_BPS)
    dyn_03 = dynamic_fee_schedule(prices, k_multiplier=0.3)

    res_static30 = run_simulation(prices, static_30)
    res_static100 = run_simulation(prices, static_100)
    res_dyn03 = run_simulation(prices, dyn_03)

    fig, axes = plt.subplots(3, 1, figsize=(11, 10), sharex=True)

    ax = axes[0]
    in_stress = regimes == 1
    ax.plot(t, prices, color="black", linewidth=0.8)
    ax.fill_between(t, prices.min() * 0.97, prices.max() * 1.03, where=in_stress, color="red", alpha=0.08, step="mid")
    ax.set_ylabel("Price (synthetic)")
    ax.set_title("Synthetic price path (red shading = stressed-volatility regime)")

    ax = axes[1]
    ax.plot(t, static_30, label="Static 30bps", color="tab:blue", linewidth=1)
    ax.plot(t, static_100, label="Static 100bps (max)", color="tab:orange", linewidth=1, linestyle="--")
    ax.plot(t, dyn_03, label="Dynamic (k=0.3)", color="tab:green", linewidth=1.2)
    ax.set_ylabel("Fee (bps)")
    ax.set_title("Fee actually charged over time")
    ax.legend(loc="upper right", fontsize=8)

    ax = axes[2]
    arr_30 = res_static30.as_arrays()
    arr_100 = res_static100.as_arrays()
    arr_dyn = res_dyn03.as_arrays()
    ax.plot(t, arr_30["cum_fees"] - arr_30["cum_lvr"], label="Static 30bps", color="tab:blue")
    ax.plot(t, arr_100["cum_fees"] - arr_100["cum_lvr"], label="Static 100bps (max)", color="tab:orange", linestyle="--")
    ax.plot(t, arr_dyn["cum_fees"] - arr_dyn["cum_lvr"], label="Dynamic (k=0.3)", color="tab:green")
    ax.axhline(0, color="grey", linewidth=0.5)
    ax.set_ylabel("Cumulative net P&L (fees - LVR), $")
    ax.set_xlabel("Days")
    ax.set_title("Cumulative LP net P&L: fee income minus LVR")
    ax.legend(loc="lower left", fontsize=8)

    plt.tight_layout()
    plt.savefig("backtest_results.png", dpi=140)
    print("Saved backtest_results.png in the current directory.")


if __name__ == "__main__":
    main()
