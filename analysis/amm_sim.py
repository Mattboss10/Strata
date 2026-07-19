"""
Constant-product AMM + arbitrageur simulation, used to measure LVR (loss-versus-
rebalancing) and LP fee income under a given fee schedule.

Model, in words:
- The pool holds reserves (x, y) with invariant k = x * y. Pool price = y / x.
- At each time step the TRUE market price moves (this comes from whatever price
  feed you plug in — synthetic or real).
- A rational arbitrageur only trades when it's profitable net of fees. This creates
  a "no-arbitrage band" around the pool's price: [p*(1-f), p/(1-f)]. If the market
  price lands inside that band, nothing happens this step. If it lands outside,
  the arbitrageur trades the pool exactly to the edge of the band (not all the way
  to the market price — that's the point of the fee).
- Every step, we also compute the theoretical LVR using the standard closed-form
  result from the literature: a constant-product pool's value loses ground at rate
  (sigma^2 / 8) * pool_value purely from price convexity, even with zero fees and
  perfect continuous arbitrage. This is unavoidable structural loss, independent of
  your fee's specific value. Fees are what's supposed to compensate LPs for it.

This file has no opinion about WHERE the fee schedule comes from — a caller can
pass a constant fee, or a fee that changes every step based on a signal, and this
engine treats them identically. That's what makes it useful for comparing a static
pool against your dynamic-fee hook on the same price data.
"""

from dataclasses import dataclass, field
import numpy as np


@dataclass
class StepResult:
    market_price: float
    fee_bps: float
    pool_price_before: float
    pool_price_after: float
    traded: bool
    fee_revenue_usd: float
    lvr_loss_usd: float
    reserve_x: float
    reserve_y: float


@dataclass
class SimResult:
    steps: list = field(default_factory=list)

    @property
    def cumulative_fees_usd(self) -> float:
        return sum(s.fee_revenue_usd for s in self.steps)

    @property
    def cumulative_lvr_usd(self) -> float:
        return sum(s.lvr_loss_usd for s in self.steps)

    @property
    def net_pnl_usd(self) -> float:
        return self.cumulative_fees_usd - self.cumulative_lvr_usd

    def as_arrays(self):
        """Convenience accessor for plotting."""
        return {
            "market_price": np.array([s.market_price for s in self.steps]),
            "fee_bps": np.array([s.fee_bps for s in self.steps]),
            "fee_revenue_usd": np.array([s.fee_revenue_usd for s in self.steps]),
            "lvr_loss_usd": np.array([s.lvr_loss_usd for s in self.steps]),
            "cum_fees": np.cumsum([s.fee_revenue_usd for s in self.steps]),
            "cum_lvr": np.cumsum([s.lvr_loss_usd for s in self.steps]),
        }


def run_simulation(prices: np.ndarray, fee_schedule_bps: np.ndarray, initial_tvl_usd: float = 1_000_000.0) -> SimResult:
    """
    prices: array of market prices (USD per unit of the risky asset), one per step.
    fee_schedule_bps: array of fee, in basis points (100 = 1%), one per step, same length as prices.
    initial_tvl_usd: starting pool value, split 50/50 at prices[0].
    """
    assert len(prices) == len(fee_schedule_bps), "prices and fee_schedule_bps must be the same length"

    p0 = prices[0]
    # 50/50 split at the starting price
    x = (initial_tvl_usd / 2.0) / p0   # units of the risky asset
    y = initial_tvl_usd / 2.0          # units of USD-like numeraire
    k = x * y

    result = SimResult()
    log_m_prev = np.log(prices[0])

    for i in range(len(prices)):
        m = prices[i]
        f = fee_schedule_bps[i] / 10_000.0  # bps -> fraction

        # --- LVR: standard closed-form convexity cost ---
        log_m = np.log(m)
        step_log_return_sq = (log_m - log_m_prev) ** 2
        current_pool_value = x * prices[i - 1] + y if i > 0 else x * m + y
        lvr_loss = 0.5 * step_log_return_sq * current_pool_value
        log_m_prev = log_m

        traded = False
        fee_revenue_usd = 0.0
        pool_price_before = y / x

        if f <= 0:
            p_target = m
            traded = abs(p_target - pool_price_before) > 1e-12
        else:
            upper_no_trade = pool_price_before / (1 - f)
            lower_no_trade = pool_price_before * (1 - f)
            if m > upper_no_trade:
                p_target = m * (1 - f)
                traded = True
            elif m < lower_no_trade:
                p_target = m / (1 - f)
                traded = True
            else:
                p_target = pool_price_before
                traded = False

        if traded:
            new_x = np.sqrt(k / p_target)
            new_y = np.sqrt(k * p_target)

            if new_y > y:
                dy_curve = new_y - y
                dy_paid = dy_curve / (1 - f) if f > 0 else dy_curve
                fee_revenue_usd = dy_paid - dy_curve
                x, y = new_x, y + dy_paid
            else:
                dx_curve = new_x - x
                dx_paid = dx_curve / (1 - f) if f > 0 else dx_curve
                fee_revenue_x = dx_paid - dx_curve
                fee_revenue_usd = fee_revenue_x * m
                x, y = x + dx_paid, new_y

            k = x * y

        result.steps.append(
            StepResult(
                market_price=m,
                fee_bps=fee_schedule_bps[i],
                pool_price_before=pool_price_before,
                pool_price_after=y / x,
                traded=traded,
                fee_revenue_usd=fee_revenue_usd,
                lvr_loss_usd=lvr_loss,
                reserve_x=x,
                reserve_y=y,
            )
        )

    return result
