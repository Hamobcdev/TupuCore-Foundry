// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/ProjectVault.sol";
import "../../src/DonorVault.sol";
import "../../src/TupuRegistry.sol";
import "../../src/TupuTala.sol";
import "../../src/test/MockERC20.sol";

contract ProjectVaultTest is Test {
    TupuRegistry public registry;
    TupuTala public tupuTala;
    MockERC20 public fundingToken;
    ProjectVault public projectVault;
    DonorVault public donorVault;
    address public deployer;
    address public projectManager;
    address public oracle1;
    address public oracle2;

    function setUp() public {
        deployer = makeAddr("deployer");
        projectManager = makeAddr("projectManager");
        oracle1 = makeAddr("oracle1");
        oracle2 = makeAddr("oracle2");

        address[] memory admins = new address[](1);
        admins[0] = deployer;
        address[] memory oracles = new address[](2);
        oracles[0] = oracle1;
        oracles[1] = oracle2;
        
        vm.startPrank(deployer);
        fundingToken = new MockERC20("MockUSDT", "USDT", 6);
        tupuTala = new TupuTala();
        registry = new TupuRegistry(address(tupuTala), address(fundingToken), admins, oracles);
        
        address[] memory treasurers = new address[](2);
        treasurers[0] = makeAddr("treasurer1");
        treasurers[1] = makeAddr("treasurer2");
        donorVault = new DonorVault(address(registry), address(fundingToken), 100 ether, treasurers, 2);
        
        // Deploy a project vault via the registry
        registry.createProject(projectManager, "ipfs://metadata");
        address vaultAddress = registry.getProject(1).projectVault;
        projectVault = ProjectVault(vaultAddress);
        
        // Set the donor vault reference
        projectVault.setDonorVault(address(donorVault));
        vm.stopPrank();
    }

    /**
     * @dev Unit Tests for Fund Release (Dual Trigger)
     */
    function test_ReleaseFunds_EscrowsTokensAndMintsTupuTala() public {
        uint256 allocationAmount = 100 * 10**6; // 100 USDT
        
        // Mock a transfer from DonorVault to ProjectVault
        fundingToken.mint(address(projectVault), allocationAmount);
        vm.prank(address(registry));
        projectVault.receiveAllocation(allocationAmount);

        vm.prank(projectManager);
        uint256 txnId = projectVault.releaseFunds(makeAddr("recipient"), 25 * 10**6, "Purpose");
        
        // Check state change
        assertEq(projectVault.totalEscrowed(), 25 * 10**6);
        // TupuTala is minted as an escrow receipt
        assertEq(tupuTala.balanceOf(address(projectVault)), allocationAmount + 25 * 10**6);
    }
    
    function test_ConfirmFiatTransfer_NeedsConsensus() public {
        uint256 allocationAmount = 100 * 10**6;
        fundingToken.mint(address(projectVault), allocationAmount);
        vm.prank(address(registry));
        projectVault.receiveAllocation(allocationAmount);

        uint256 amountToRelease = 25 * 10**6;
        address recipient = makeAddr("recipient");
        
        vm.prank(projectManager);
        uint256 txnId = projectVault.releaseFunds(recipient, amountToRelease, "Purpose");
        
        // Oracle 1 confirms
        vm.prank(oracle1);
        projectVault.confirmFiatTransfer(txnId);
        
        // Funds should NOT be released yet
        assertEq(fundingToken.balanceOf(recipient), 0);
        
        // Oracle 2 confirms
        vm.prank(oracle2);
        projectVault.confirmFiatTransfer(txnId);
        
        // Funds should now be released
        assertEq(fundingToken.balanceOf(recipient), amountToRelease);
        assertEq(tupuTala.balanceOf(address(projectVault)), allocationAmount); // TupuTala is burned for the released amount
    }

    /**
     * @dev Unit Tests for Returning Funds
     */
    function test_ReturnFunds_ReturnsToDonorVaultAndBurnsTupuTala() public {
        uint256 allocationAmount = 100 * 10**6;
        fundingToken.mint(address(projectVault), allocationAmount);
        vm.prank(address(registry));
        projectVault.receiveAllocation(allocationAmount);

        uint256 initialDonorVaultBalance = fundingToken.balanceOf(address(donorVault));
        
        uint256 returnAmount = 50 * 10**6;
        
        vm.prank(projectManager);
        projectVault.returnFunds(returnAmount);
        
        // TupuTala is burned for the returned amount
        assertEq(tupuTala.balanceOf(address(projectVault)), allocationAmount - returnAmount);
        // Funding token is transferred back to the donor vault
        assertEq(fundingToken.balanceOf(address(donorVault)), initialDonorVaultBalance + returnAmount);
    }
}