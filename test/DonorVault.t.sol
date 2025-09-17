// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/DonorVault.sol";
import "../../src/TupuRegistry.sol";
import "../../src/TupuTala.sol";
import "../../src/ProjectVault.sol";
import "../../src/test/MockERC20.sol";

contract DonorVaultTest is Test {
    TupuRegistry public registry;
    TupuTala public tupuTala;
    MockERC20 public fundingToken;
    DonorVault public donorVault;
    address public deployer;
    address public donor;
    address public treasurer1;
    address public treasurer2;
    address public manager1;

    function setUp() public {
        deployer = makeAddr("deployer");
        donor = makeAddr("donor");
        treasurer1 = makeAddr("treasurer1");
        treasurer2 = makeAddr("treasurer2");
        manager1 = makeAddr("manager1");
        
        address[] memory admins = new address[](1);
        admins[0] = deployer;
        address[] memory oracles = new address[](2);
        oracles[0] = makeAddr("oracle1");
        oracles[1] = makeAddr("oracle2");

        vm.startPrank(deployer);
        fundingToken = new MockERC20("MockUSDT", "USDT", 6);
        tupuTala = new TupuTala();
        registry = new TupuRegistry(address(tupuTala), address(fundingToken), admins, oracles);
        
        address[] memory treasurers = new address[](2);
        treasurers[0] = treasurer1;
        treasurers[1] = treasurer2;
        donorVault = new DonorVault(address(registry), address(fundingToken), 100 ether, treasurers, 2);
        vm.stopPrank();
    }

    /**
     * @dev Unit Tests for Deposits and Withdrawals
     */
    function test_DepositAndWithdraw_Success() public {
        uint256 amount = 50 * 10**6;
        fundingToken.mint(donor, amount);
        
        vm.startPrank(donor);
        fundingToken.approve(address(donorVault), amount);
        donorVault.deposit(amount);
        vm.stopPrank();

        // Check state after deposit
        assertEq(donorVault.donorBalances(donor), amount);
        assertEq(tupuTala.balanceOf(donor), amount);

        // Perform withdrawal
        vm.prank(donor);
        donorVault.withdraw(amount);

        // Check state after withdrawal
        assertEq(donorVault.donorBalances(donor), 0);
        assertEq(tupuTala.balanceOf(donor), 0);
        assertEq(fundingToken.balanceOf(donor), amount);
    }
    
    function test_Withdrawal_ExceedsDailyLimitReverts() public {
        uint256 amount = 100 * 10**6;
        fundingToken.mint(donor, amount);
        
        vm.startPrank(donor);
        fundingToken.approve(address(donorVault), amount);
        donorVault.deposit(amount);
        
        // First withdrawal within limit
        donorVault.withdraw(50 * 10**6);
        
        // Second withdrawal exceeds daily limit
        vm.expectRevert("Daily limit exceeded");
        donorVault.withdraw(51 * 10**6);
        vm.stopPrank();
    }

    /**
     * @dev Unit Tests for Allocation Proposals
     */
    function test_ProposeAllocation_Success() public {
        vm.prank(deployer);
        registry.createProject(manager1, "ipfs://metadata");
        
        uint256 allocationAmount = 50 * 10**6;
        
        fundingToken.mint(donor, 100 * 10**6);
        vm.prank(donor);
        fundingToken.approve(address(donorVault), 100 * 10**6);
        vm.prank(donor);
        donorVault.deposit(100 * 10**6);

        vm.prank(treasurer1);
        uint256 proposalId = donorVault.proposeAllocation(1, allocationAmount);
        
        assertEq(donorVault.proposals(proposalId).amount, allocationAmount);
    }

    function test_SignAndExecuteAllocation_Success() public {
        vm.prank(deployer);
        uint256 projectId = registry.createProject(manager1, "ipfs://metadata");
        
        uint256 allocationAmount = 50 * 10**6;
        fundingToken.mint(donor, 100 * 10**6);
        vm.prank(donor);
        fundingToken.approve(address(donorVault), 100 * 10**6);
        vm.prank(donor);
        donorVault.deposit(100 * 10**6);

        vm.prank(treasurer1);
        uint256 proposalId = donorVault.proposeAllocation(projectId, allocationAmount);

        // Sign with first treasurer
        vm.prank(treasurer1);
        donorVault.signProposal(proposalId);

        // Sign with second treasurer (quorum met)
        vm.prank(treasurer2);
        donorVault.signProposal(proposalId);
        
        // Get the project vault address
        address projectVaultAddress = registry.getProject(projectId).projectVault;

        // Check that funds have been transferred
        assertEq(fundingToken.balanceOf(projectVaultAddress), allocationAmount);
        assertEq(donorVault.totalAllocated(), allocationAmount);
    }
}