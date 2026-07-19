"""
Synthetic price path generator.

IMPORTANT: this is synthetic data, not historical market data. It exists so the
simulation engine (amm_sim.py) can be tested and the fee logic calibrated against
a KNOWN, controllable volatility pattern. This is also standard practice in the
academic LVR literature (Milionis et al. and follow-ups largely use simulated GBM
paths, precisely because it isolates volatility as a variable instead of tangling
it with every other thing that moves a real market).

To swap in real data later: replace calls to generate_regime_switching_path() with
a function that returns a numpy array of prices loaded from a CSV. amm_sim.py
doesn't care where the array came from.
"""

import numpy as np


def generate_regime_switching_path(
    n_steps: int = 24 * 90,       # default: 90 days of hourly steps
    p0: float = 2000.0,           # starting price
    calm_vol_annual: float = 0.35,   # ~35% annualized vol, a quiet crypto market
    stressed_vol_annual: float = 1.20,  # ~120% annualized vol, a volatile stretch
    steps_per_year: float = 24 * 365,   # hourly steps
    mean_regime_length_steps: float = 48,  # regimes last ~2 days on average
    seed: int = 42,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Returns (prices, regime_labels) where regime_labels is 0 for calm, 1 for stressed.
    Regime durations are drawn from an exponential distribution so switches feel
    irregular rather than metronomic.
    """
    rng = np.random.default_rng(seed)
    dt = 1.0 / steps_per_year

    regime_labels = np.zeros(n_steps, dtype=int)
    i = 0
    current_regime = 0
    while i < n_steps:
        length = max(1, int(rng.exponential(mean_regime_length_steps)))
        end = min(n_steps, i + length)
        regime_labels[i:end] = current_regime
        current_regime = 1 - current_regime
        i = end

    vols = np.where(regime_labels == 0, calm_vol_annual, stressed_vol_annual)

    # geometric brownian motion, zero drift (LVR analysis is about volatility, not trend)
    shocks = rng.normal(loc=0.0, scale=1.0, size=n_steps)
    log_returns = -0.5 * (vols**2) * dt + vols * np.sqrt(dt) * shocks

    log_prices = np.log(p0) + np.cumsum(log_returns)
    prices = np.exp(log_prices)

    return prices, regime_labels


def rolling_realized_vol_bps(prices: np.ndarray, window: int = 24) -> np.ndarray:
    """
    Trailing realized volatility, expressed in bps of price move per step, over a
    rolling window. This is a reasonable stand-in for "what a reasonably good
    aggregate crowd prediction would look like" for calibrating the dynamic fee —
    it's not cheating (it only looks backward), but it's also not a real forecast,
    since it can't see regime changes coming. That gap is realistic: your actual
    SignalOracle contributors won't be perfect either.
    """
    log_returns = np.diff(np.log(prices), prepend=np.log(prices[0]))
    realized = np.zeros_like(prices)
    for i in range(len(prices)):
        start = max(0, i - window + 1)
        window_returns = log_returns[start : i + 1]
        realized[i] = np.std(window_returns) * 10_000  # to bps
    return realized
