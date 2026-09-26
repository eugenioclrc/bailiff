// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Local demo deploy, phase 1 of 2: RWA + PermissionsAdapter through the real factory.
// The PA address is NOT taken from here: scripts/deploy-local.sh reads it from PermissionsAdapterCreated in the mined receipt.

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowlistChecker} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {MockRWA3643} from "../src/e2e/MockRWA3643.sol";
import {LocalStack} from "./LocalStack.sol";

contract LocalDeployPA is LocalStack {
    function run() external {
        _preflight();
        uint256 issuerPk = vm.envUint("ISSUER_PK");
        address issuer = vm.addr(issuerPk);

        vm.startBroadcast(issuerPk);
        MockRWA3643 rwa = new MockRWA3643(issuer);
        rwa.setFlags(issuer, HOLDER); // O3: issuer keeps HOLDER only, no SWAP/LIQUIDITY
        address simulatedPa =
            FACTORY.createPermissionsAdapter(IERC20(address(rwa)), issuer, IAllowlistChecker(address(rwa)));
        vm.stopBroadcast();

        console2.log("simulated RWA", address(rwa));
        console2.log("simulated PA (not used; read from receipt)", simulatedPa);
    }
}
