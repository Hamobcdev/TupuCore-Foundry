// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/TupuTala.sol";
import "../src/TupuRegistry.sol";
import "../src/DonorVault.sol";
import "../src/test/MockERC20.sol";

// This is the main deployment script for the TupuPlatform ecosystem.
contract DeployTupuPlatformScript is Script {
    // These will be set by the caller of the script
    address public deployer;
    address[] public initialAdmins;
    address[] public initialOracles;
    address[] public initialTreasurers;
    uint256 public initialTreasuryQuorum;
    uint256 public donorVaultDailyWithdrawalLimit;

    // Deployed contract instances
    TupuTala public tupuTala;
    TupuRegistry public registry;
    DonorVault public donorVault;
    MockERC20 public fundingToken;

    function setUp() public {
        deployer = msg.sender;
        console2.log("Deployer address:", deployer);
    }

    function run() external {
        // --- 1. Load configuration from environment variables or hardcoded values ---
        // For a production deployment, these should be securely handled, e.g., via CLI arguments.
        // For this example, we'll use placeholder values.
        initialAdmins = new address[](1);
        initialAdmins[0] = deployer;

        initialOracles = new address[](2);
        initialOracles[0] = deployer; // Placeholder
        initialOracles[1] = makeAddr("oracle2");

        initialTreasurers = new address[](2);
        initialTreasurers[0] = deployer; // Placeholder
        initialTreasurers[1] = makeAddr("treasurer2");

        initialTreasuryQuorum = 2;
        donorVaultDailyWithdrawalLimit = 100 * 10**6; // 100 USDT (assuming 6 decimals)

        // --- 2. Start the transaction block ---
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // --- 3. Deploy foundational contracts ---
        console2.log("Deploying MockERC20 (FundingToken)...");
        fundingToken = new MockERC20("TupuUSDC", "USDC", 6);
        console2.log("FundingToken deployed at:", address(fundingToken));

        console2.log("Deploying TupuTala...");
        tupuTala = new TupuTala();
        console2.log("TupuTala deployed at:", address(tupuTala));

        // --- 4. Deploy the TupuRegistry and link foundational contracts ---
        console2.log("Deploying TupuRegistry...");
        registry = new TupuRegistry(
            address(tupuTala),
            address(fundingToken),
            initialAdmins,
            initialOracles
        );
        console2.log("TupuRegistry deployed at:", address(registry));

        // Grant TupuRegistry the minter/burner role for TupuTala
        // This is a critical step to enable the registry to manage vaults that mint/burn TupuTala
        tupuTala.grantRole(tupuTala.DEFAULT_ADMIN_ROLE(), address(registry));
        tupuTala.renounceRole(tupuTala.DEFAULT_ADMIN_ROLE(), address(this));

        // --- 5. Deploy the main DonorVault and link to Registry ---
        console2.log("Deploying DonorVault...");
        donorVault = new DonorVault(
            address(registry),
            address(fundingToken),
            donorVaultDailyWithdrawalLimit,
            initialTreasurers,
            initialTreasuryQuorum
        );
        console2.log("DonorVault deployed at:", address(donorVault));

        // Authorize the DonorVault within the Registry
        vm.prank(address(registry));
        registry.setAuthorizedVault(address(donorVault), true);

        // --- 6. End the transaction block ---
        vm.stopBroadcast();

        console2.log("\n--- Deployment Complete ---");
        console2.log("TupuTala:", address(tupuTala));
        console2.log("FundingToken (Mock):", address(fundingToken));
        console2.log("TupuRegistry:", address(registry));
        console2.log("DonorVault:", address(donorVault));
    }
}