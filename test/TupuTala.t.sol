// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/TupuTala.sol";

contract TupuTalaTest is Test {
    TupuTala public tupuTala;
    address public deployer;
    address public minter;
    address public pauser;
    address public burner;
    address public user1;
    address public user2;

    function setUp() public {
        deployer = makeAddr("deployer");
        minter = makeAddr("minter");
        pauser = makeAddr("pauser");
        burner = makeAddr("burner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.startPrank(deployer);
        tupuTala = new TupuTala();
        tupuTala.grantRole(tupuTala.MINTER_ROLE(), minter);
        tupuTala.grantRole(tupuTala.PAUSER_ROLE(), pauser);
        tupuTala.grantRole(tupuTala.BURNER_ROLE(), burner);
        vm.stopPrank();
    }

    /**
     * @dev Unit Tests for Minting
     */
    function test_Minting_RevertsOnExceedingMaxSupply() public {
        vm.prank(deployer);
        tupuTala.setMinterDailyLimit(minter, tupuTala.MAX_SUPPLY());
        
        vm.prank(minter);
        tupuTala.mint(user1, tupuTala.MAX_SUPPLY());

        vm.prank(minter);
        vm.expectRevert("Exceeds lifetime max supply");
        tupuTala.mint(user1, 1);
    }
    
    function test_Minting_RevertsOnExceedingDailyLimit() public {
        uint256 dailyLimit = 100 * 10**18;
        vm.prank(deployer);
        tupuTala.setMinterDailyLimit(minter, dailyLimit);

        vm.prank(minter);
        tupuTala.mint(user1, dailyLimit);

        vm.prank(minter);
        vm.expectRevert("Exceeds daily limit");
        tupuTala.mint(user1, 1);
    }

    function test_Minting_AllowsWithinLimit() public {
        uint256 dailyLimit = 100 * 10**18;
        uint256 amount = 50 * 10**18;

        vm.prank(deployer);
        tupuTala.setMinterDailyLimit(minter, dailyLimit);

        vm.prank(minter);
        tupuTala.mint(user1, amount);

        assertEq(tupuTala.balanceOf(user1), amount);
        assertEq(tupuTala.cumulativeMinted(), amount);
        assertEq(tupuTala.currentSupply(), amount);
    }

    /**
     * @dev Unit Tests for Burning
     */
    function test_Burning_ReducesCurrentSupplyOnly() public {
        uint256 amount = 100 * 10**18;

        vm.prank(deployer);
        tupuTala.setMinterDailyLimit(minter, amount);
        vm.prank(minter);
        tupuTala.mint(user1, amount);

        uint256 cumulativeBefore = tupuTala.cumulativeMinted();
        uint256 currentBefore = tupuTala.currentSupply();

        vm.prank(burner);
        tupuTala.burnFrom(user1, amount);

        assertEq(tupuTala.currentSupply(), currentBefore - amount);
        assertEq(tupuTala.cumulativeMinted(), cumulativeBefore);
    }

    /**
     * @dev Unit Tests for Access Control and Pause
     */
    function test_AccessControl_NonMinterCannotMint() public {
        vm.expectRevert("AccessControl: account ");
        tupuTala.mint(user1, 1);
    }

    function test_Pause_BlocksMinting() public {
        vm.prank(pauser);
        tupuTala.pause();

        vm.prank(minter);
        vm.expectRevert("Pausable: paused");
        tupuTala.mint(user1, 1);
    }

    /**
     * @dev Unit Tests for Non-Transferable Tokens
     */
    function test_Transfer_Reverts() public {
        vm.prank(deployer);
        tupuTala.setMinterDailyLimit(minter, 1);
        vm.prank(minter);
        tupuTala.mint(user1, 1);

        vm.prank(user1);
        vm.expectRevert("TupuTala tokens are non-transferable");
        tupuTala.transfer(user2, 1);
    }
}