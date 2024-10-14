// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVault} from "@balancer-labs/contracts/interfaces/contracts/vault/IVault.sol";
import {IRouterCommon} from "@balancer-labs/v3-interfaces/contracts/vault/IRouterCommon.sol";
import {BaseHooks} from "@balancer-labs/contracts/vault/contracts/BaseHooks.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IBasePoolFactory} from "@balancer-labs/contracts/interfaces/contracts/vault/IBasePoolFactory.sol";
import {
    LiquidityManagement,
    TokenConfig,
    HookFlags,
    AfterSwapParams,
    AddLiquidityKind,
    PoolSwapParams,
    RemoveLiquidityKind,
    AddLiquidityParams,
    AddLiquidityKind
} from "@balancer-labs/contracts/interfaces/contracts/vault/VaultTypes.sol";
import {Router} from "@balancer-labs/v3-vault/contracts/Router.sol";
import {VaultGuard} from "@balancer-labs/contracts/vault/contracts/VaultGuard.sol";

contract FeeRebate is BaseHooks, VaultGuard {
    error FeeRebate__NotAllowedRouter(address router, address trustedRouter);
    
    /**
     * @notice An exit fee has been charged on a pool to JIT liquidity provider.
     * @param pool The pool that was charged
     * @param token The address of the fee token
     * @param feeAmount The amount of the fee (in native decimals)
     */
    event ExitFeeCharged(address indexed pool, IERC20 indexed token, uint256 feeAmount);

    // only calls from a trusted routers are allowed to call this hook, because the hook relies on the getSender
    // implementation to work properly
    address private immutable i_trustedRouter;
    // only pools from the allowedFactory are able to register and use this hook
    address private immutable i_allowedFactory;
    IVault private immutable i_vault;
    uint256 public exitFeePercentage = 5e16;
    uint256 public constant LOCKUP_TIME = 1 weeks;

    mapping(address pool => mapping(address lp => uint256[])) public liquiditySupplied;
    mapping(address => uint256) private lastDepositTime;

    constructor(IVault vault, address allowedFactory, address trustedRouter) VaultGuard(vault) {
        i_allowedFactory = allowedFactory;
        i_trustedRouter = trustedRouter;
        i_vault = vault;
    }

    /// @notice Get the hook flags
    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallComputeDynamicSwapFee = true;
        hookFlags.shouldCallAfterAddLiquidity = true;
        hookFlags.shouldCallAfterRemoveLiquidity = true;
        hookFlags.enableHookAdjustedAmounts = true;
    }

    /// @notice Check if the pool is allowed to register with this hook
    /// @dev This hook implements a restrictive approach, where we check if the factory is an allowed factory and if the pool is created by the allowed factory
    /// @param factory The factory contract that is deploying the pool
    /// @param pool The pool that is being registered with this hook
    function onRegister(
        address factory,
        address pool,
        TokenConfig[] memory, /* tokenConfig */
        LiquidityManagement calldata /* liquidityManagement */
    ) public view override onlyVault returns (bool) {
        // This hook implements a restrictive approach, where we check if the factory is an allowed factory and if
        // the pool was created by the allowed factory
        return factory == i_allowedFactory && IBasePoolFactory(factory).isPoolFromFactory(pool);
    }

    function onAfterAddLiquidity(
        address router,
        address pool,
        AddLiquidityKind, /* kind */
        uint256[] memory amountsInScaled18,
        uint256[] memory amountsInRaw,
        uint256, /* bptAmountOut */
        uint256[] memory, /* balancesScaled18 */
        bytes memory /* userData */
    ) public override onlyVault returns (bool, uint256[] memory) {
        if (router != i_trustedRouter) {
            revert FeeRebate__NotAllowedRouter(router, i_trustedRouter);
        }
        address sender = Router(payable(router)).getSender();
        for (uint256 i = 0; i < amountsInScaled18.length; i++) {
            liquiditySupplied[pool][sender][i] += amountsInScaled18[i];
        }

        if (lastDepositTime[sender] == 0) {
            lastDepositTime[sender] = block.timestamp;
        }

        return (true, amountsInRaw);
    }

    function onAfterRemoveLiquidity(
        address router,
        address pool,
        RemoveLiquidityKind, /* kind */
        uint256, /* bptAmountIn */
        uint256[] memory amountsOutScaled18,
        uint256[] memory amountsOutRaw,
        uint256[] memory, /* balancesScaled18 */
        bytes memory /* userData */
    ) public override onlyVault returns (bool, uint256[] memory) {
        if (router != i_trustedRouter) {
            revert FeeRebate__NotAllowedRouter(router, i_trustedRouter);
        }
        address sender = Router(payable(router)).getSender();
        uint256[] memory hookAdjustedAmountsOutRaw = amountsOutRaw;

        if (block.timestamp - lastDepositTime[sender] < LOCKUP_TIME) {
            if (exitFeePercentage > 0) {
                IERC20[] memory tokens = i_vault.getPoolTokens(pool);
                uint256[] memory accruedFees = new uint256[](tokens.length);

                // Charge fees proportional to the `amountOut` of each token.
                for (uint256 i = 0; i < amountsOutRaw.length; i++) {
                    //uint256 exitFee = amountsOutRaw[i].mulDown(exitFeePercentage);
                    uint256 exitFee = mulDown(amountsOutRaw[i], exitFeePercentage);
                    accruedFees[i] = exitFee;
                    hookAdjustedAmountsOutRaw[i] -= exitFee;

                    emit ExitFeeCharged(pool, tokens[i], exitFee);
                    // Fees don't need to be transferred to the hook, because donation will redeposit them in the Vault.
                    // In effect, we will transfer a reduced amount of tokensOut to the caller and leave the remainder
                    // in the pool balance.
                }

                // Donates accrued fees back to LPs
                i_vault.addLiquidity(
                    AddLiquidityParams({
                        pool: pool,
                        to: msg.sender, // It would mint BPTs to router, but it's a donation so no BPT is minted
                        maxAmountsIn: accruedFees, // Donate all accrued fees back to the pool (i.e. to the LPs)
                        minBptAmountOut: 0, // Donation does not return BPTs, any number above 0 will revert
                        kind: AddLiquidityKind.DONATION,
                        userData: bytes("")
                    })
                );
            }
        }

        bool allLiquidityRemoved = true;

        for (uint256 i = 0; i < amountsOutScaled18.length; i++) {
            if (liquiditySupplied[pool][sender][i] <= amountsOutScaled18[i]) {
                liquiditySupplied[pool][sender][i] = 0;
            } else {
                liquiditySupplied[pool][sender][i] -= amountsOutScaled18[i];
                allLiquidityRemoved = false;
            }
        }

        if (allLiquidityRemoved) {
            lastDepositTime[sender] = 0;
        }

        return (true, hookAdjustedAmountsOutRaw);
    }

    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool,
        uint256 staticSwapFeePercentage
    ) public view override onlyVault returns (bool, uint256) {
        if (params.router != i_trustedRouter) {
            revert FeeRebate__NotAllowedRouter(params.router, i_trustedRouter);
        }
        address sender = Router(payable(params.router)).getSender();
        uint256 lpAmount =
            liquiditySupplied[pool][sender][params.indexIn] + liquiditySupplied[pool][sender][params.indexOut];

        if (lpAmount > 0 && block.timestamp - lastDepositTime[sender] > LOCKUP_TIME) {
            uint256 loggedPercentage = _log2(lpAmount);
            uint256 rebate = (staticSwapFeePercentage * loggedPercentage) / 100;
            if (rebate >= staticSwapFeePercentage / 2) {
                return (true, staticSwapFeePercentage / 2);
            } else {
                return (true, staticSwapFeePercentage - rebate);
            }
        } else {
            return (true, staticSwapFeePercentage);
        }
    }

    function _log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        return product / 1e18;
    }
}
