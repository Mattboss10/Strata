// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LvrFeeHook} from "../src/LvrFeeHook.sol";
import {SignalOracle} from "../src/SignalOracle.sol";

/// @notice Forking test: deploys the hook against the REAL, already-deployed PoolManager
///         on a live fork instead of a freshly-deployed local one.
/// @dev Requires a real RPC URL:
///          export SEPOLIA_RPC_URL="https://your-rpc-url-here"
///          forge test --match-contract LvrFeeHookForkTest --fork-url $SEPOLIA_RPC_URL -vv
///      Free public Sepolia RPC endpoints work fine -- no paid key needed.
contract LvrFeeHookForkTest is Test {
    // Same address across every chain Uniswap has deployed v4 to, via deterministic
    // CREATE2 deployment. Cross-check https://docs.uniswap.org/contracts/v4/deployments
    // if this doesn't find a contract here on whatever chain you fork.
    address constant POOL_MANAGER_ADDRESS = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    IPoolManager poolManager;
    LvrFeeHook hook;
    SignalOracle oracle;

    address settler = makeAddr("settler");

    function setUp() public {
        string memory rpcUrl = vm.envString("SEPOLIA_RPC_URL");
        vm.createSelectFork(rpcUrl);

        poolManager = IPoolManager(POOL_MANAGER_ADDRESS);

        uint256 size;
        address pm = address(poolManager);
        assembly {
            size := extcodesize(pm)
        }
        assertGt(size, 0, "no contract at the expected PoolManager address on this fork");

        address sustainabilityFeeRecipient = makeAddr("sustainabilityFeeRecipient");
        oracle = new SignalOracle(settler, 5 minutes, 5 minutes, 0.01 ether, sustainabilityFeeRecipient, 0);

        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG) ^ (0x6666 << 144));
        bytes memory constructorArgs = abi.encode(poolManager, oracle);
        deployCodeTo("LvrFeeHook.sol:LvrFeeHook", constructorArgs, flags);
        hook = LvrFeeHook(flags);
    }

    function test_HookDeploysAgainstRealPoolManager() public view {
        assertEq(address(hook.poolManager()), POOL_MANAGER_ADDRESS);
        assertEq(hook.previewFee(), hook.BASE_FEE());
    }
}
