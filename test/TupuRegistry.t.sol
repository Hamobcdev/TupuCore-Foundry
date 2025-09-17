// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/TupuRegistry.sol";
import "../../src/TupuTala.sol";
import "../../src/ProjectVault.sol";
import "../../src/test/MockERC20.sol";

contract TupuRegistryTest is Test {
    TupuRegistry public registry;
    TupuTala public tupuTala;
    MockERC20 public fundingToken;
    address[] public initialAdmins;
    address[] public initialOracles;
    address public admin1;
    address public admin2;
    address public oracle1;
    address public oracle2;
    address public manager1;

    function setUp() public {
        admin1 = makeAddr("admin1");
        admin2 = makeAddr("admin2");
        oracle1 = makeAddr("oracle1");
        oracle2 = makeAddr("oracle2");
        manager1 = makeAddr("manager1");
        
        initialAdmins = new address[](2);
        initialAdmins[0] = admin1;
        initialAdmins[1] = admin2;
        
        initialOracles = new address[](2);
        initialOracles[0] = oracle1;
        initialOracles[1] = oracle2;

        vm.startPrank(admin1);
        fundingToken = new MockERC20("MockUSDT", "USDT", 6);
        tupuTala = new TupuTala();
        registry = new TupuRegistry(address(tupuTala), address(fundingToken), initialAdmins, initialOracles);
        vm.stopPrank();
    }

    /**
     * @dev Unit Tests for Project Creation
     */
    function test_ProjectCreation_Success() public {
        vm.prank(admin1);
        uint256 projectId = registry.createProject(manager1, "ipfs://metadata");
        
        TupuRegistry.Project memory project = registry.getProject(projectId);
        assertEq(project.id, projectId);
        assertEq(project.manager, manager1);
        assertTrue(project.active);
        
        // Check if roles are granted correctly
        assertTrue(registry.hasRole(registry.PROJECT_MANAGER_ROLE(), manager1));
        assertTrue(registry.isAuthorizedVault(project.projectVault));
        assertTrue(tupuTala.hasRole(tupuTala.MINTER_ROLE(), project.projectVault));
    }
    
    function test_ProjectCreation_RevertsOnInvalidManager() public {
        vm.prank(admin1);
        vm.expectRevert("Invalid manager address");
        registry.createProject(address(0), "ipfs://metadata");
    }

    /**
     * @dev Unit Tests for Emergency Withdrawal
     */
    function test_EmergencyWithdrawal_Success() public {
        address recoveryAddress = makeAddr("recovery");
        uint256 amountToWithdraw = 50 * 10**6;

        // Fund the registry first
        fundingToken.mint(address(registry), 100 * 10**6);
        
        // Pause the registry to enable emergency withdrawal
        vm.prank(admin1);
        registry.emergencyPause();
        
        // Propose withdrawal
        vm.prank(admin1);
        uint256 proposalId = registry.proposeEmergencyWithdrawal(amountToWithdraw, recoveryAddress);

        // Sign with first admin
        vm.prank(admin1);
        registry.signEmergencyWithdrawal(proposalId);
        
        // Funds should not be withdrawn yet
        assertEq(fundingToken.balanceOf(recoveryAddress), 0);

        // Sign with second admin (quorum met)
        vm.prank(admin2);
        registry.signEmergencyWithdrawal(proposalId);
        
        // Funds should now be withdrawn
        assertEq(fundingToken.balanceOf(recoveryAddress), amountToWithdraw);
    }

    function test_EmergencyWithdrawal_RevertsOnInsufficientSignatures() public {
        address recoveryAddress = makeAddr("recovery");
        uint256 amountToWithdraw = 50 * 10**6;
        fundingToken.mint(address(registry), 100 * 10**6);
        vm.prank(admin1);
        registry.emergencyPause();
        
        vm.prank(admin1);
        uint256 proposalId = registry.proposeEmergencyWithdrawal(amountToWithdraw, recoveryAddress);

        // Sign with only one admin
        vm.prank(admin1);
        registry.signEmergencyWithdrawal(proposalId);
        
        assertEq(fundingToken.balanceOf(recoveryAddress), 0);
    }

    function test_EmergencyWithdrawal_RevertsOnExpiredProposal() public {
        address recoveryAddress = makeAddr("recovery");
        uint256 amountToWithdraw = 50 * 10**6;
        fundingToken.mint(address(registry), 100 * 10**6);
        vm.prank(admin1);
        registry.emergencyPause();
        
        vm.prank(admin1);
        uint256 proposalId = registry.proposeEmergencyWithdrawal(amountToWithdraw, recoveryAddress);
        
        // Increase time to expire the proposal
        vm.warp(block.timestamp + 2 days);

        // Expect revert on signature
        vm.prank(admin2);
        vm.expectRevert("Proposal expired");
        registry.signEmergencyWithdrawal(proposalId);
    }

    /**
     * @dev Unit Tests for Oracle Management
     */
    function test_OracleManagement_AddAndRemove() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin1);
        registry.setOracle(newOracle, true);
        assertTrue(registry.hasRole(registry.ORACLE_ROLE(), newOracle));
        
        vm.prank(admin1);
        registry.setOracle(oracle1, false);
        assertFalse(registry.hasRole(registry.ORACLE_ROLE(), oracle1));
        
        vm.prank(admin1);
        vm.expectRevert("Must maintain at least 2 active oracles");
        registry.setOracle(oracle2, false);
    }
}