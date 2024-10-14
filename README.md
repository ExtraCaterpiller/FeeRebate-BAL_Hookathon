# Balancer Hookathon - FeeRebate

## Overview

FeeRebate Hook is designed to provide liquidity providers (LPs) with a fee rebate mechanism that reduces or eliminates exit fees based on their liquidity provision and lock-up time. By integrating this hook, pools can encourage long-term liquidity provision by offering rebates to LPs, while still penalizing those who try to withdraw liquidity too early (within a defined lock-up period).

## What the Hook Does

The FeeRebate Hook introduces dynamic exit fees that are based on the liquidity provided by the LPs and the time they have kept their liquidity in the pool. The key functionality includes:

- Fee Rebates: LPs can earn fee rebates when removing liquidity. If an LP removes liquidity after a defined lock-up period (LOCKUP_TIME), they become eligible for a fee rebate. The rebate is dynamically computed based on the LP’s liquidity amount and lock-up duration.

- Exit Fees: If liquidity is removed before the lock-up period expires, an exit fee is charged. This fee is deducted from the LP's token withdrawals and is donated back to the pool for the benefit of remaining LPs.

- Dynamic Swap Fees: In addition to exit fees, the hook allows for dynamic swap fee computation. LPs who have provided significant liquidity and kept it locked for longer can benefit from reduced swap fees, further incentivizing long-term participation.

## Example Use Case

Imagine a liquidity provider (LP) adds liquidity to a pool on Balancer V3 using a router integrated with the FeeRebate hook. Here’s how it works step-by-step:

1. Initial Deposit: The LP deposits tokens into a pool and the onAfterAddLiquidity function records the amount of liquidity provided and the timestamp of the deposit.

2. Early Withdrawal: If the LP attempts to remove liquidity before the lock-up period (1 week) ends, the hook applies an exit fee. This fee is deducted from the LP's token withdrawals, and the remaining tokens are sent to the LP. The exit fees are automatically donated back into the pool, benefiting other LPs.

3. Post Lock-Up Withdrawal: If the LP waits for more than the lock-up period, they are eligible for a fee rebate. The hook dynamically calculates the rebate based on their liquidity amount and the time since the last deposit. The LP can remove liquidity with reduced or half fees, encouraging them to remain in the pool longer.

4. Dynamic Swap Fee Rebates: The hook also offers rebates on swap fees for LPs who have contributed large amounts of liquidity over time. This makes swaps cheaper for them, further incentivizing liquidity provision.

## Feedback about Developer Experience (DevX)

Developing the FeeRebate Hook was a rewarding experience, but it came with some challenges:

- Seamless Integration with Balancer Vault: The Balancer Vault API provides excellent modularity for implementing custom hooks. The extensive documentation and clear interface design allowed for smooth interaction between the hook and vault, particularly when handling liquidity events.

- Learning Curve for Dynamic Fee Computation: Implementing dynamic swap fee computation involved a bit of trial and error. While the Vault’s structure is well-documented, calculating real-time fees based on liquidity and time constraints required a solid understanding of the pool’s internal logic. However, the modularity of the Balancer system allowed for flexibility in how we approached this.


In summary, the experience with Balancer V3’s hook system was positive. The flexibility and power it provides allow for creative solutions like the FeeRebate hook, though attention to optimization and security is essential for production use.