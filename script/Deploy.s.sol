// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/WhistleblowerEscrow.sol";

/**
 * @title DeployScript
 * @notice Deploys WhistleblowerEscrow to Cronos Testnet
 * @dev Usage:
 *      export PRIVATE_KEY=<your_private_key>
 *      export AGENT_ADDRESS=<agent_wallet_address>
 *      forge script script/Deploy.s.sol:DeployScript --rpc-url https://evm-t3.cronos.org --broadcast --verify
 */
contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address agentAddress = vm.envAddress("AGENT_ADDRESS");
        
        require(agentAddress != address(0), "AGENT_ADDRESS not set");

        console.log("Deploying WhistleblowerEscrow...");
        console.log("Agent address:", agentAddress);

        vm.startBroadcast(deployerPrivateKey);
        
        WhistleblowerEscrow escrow = new WhistleblowerEscrow(agentAddress);
        
        vm.stopBroadcast();

        console.log("========================================");
        console.log("WhistleblowerEscrow deployed at:", address(escrow));
        console.log("Owner:", escrow.owner());
        console.log("Agent:", escrow.authorizedAgent());
        console.log("========================================");
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify contract on explorer:");
        console.log("   forge verify-contract", address(escrow), "src/WhistleblowerEscrow.sol:WhistleblowerEscrow --chain 338");
        console.log("");
        console.log("2. Update frontend .env:");
        console.log("   VITE_CONTRACT_ADDRESS=", address(escrow));
    }
}
