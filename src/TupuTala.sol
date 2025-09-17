// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TupuTala
 * @dev The non-transferable ERC20 token used for the on-chain audit trail.
 * FIXED: Fixed total supply cap accounting bug
 */
contract TupuTala is ERC20, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // Track minting limits per minter
    mapping(address => uint256) public minterDailyLimit;
    mapping(address => mapping(uint256 => uint256)) public dailyMinted;
    
    // FIXED: Separate tracking for lifetime cap vs current supply
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1B tokens
    uint256 public cumulativeMinted; // NEVER decreases - tracks lifetime mints
    uint256 public currentSupply; // Can decrease on burns

    event MinterLimitUpdated(address indexed minter, uint256 newLimit);
    event TokensBurned(address indexed burner, address indexed from, uint256 amount);
    event TokensMinted(address indexed minter, address indexed to, uint256 amount);

    constructor() ERC20("TupuTala", "TALA") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    /**
     * @dev FIXED: Enforce max supply against cumulative mints
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Amount must be positive");
        require(cumulativeMinted + amount <= MAX_SUPPLY, "Exceeds lifetime max supply");
        
        uint256 today = block.timestamp / 1 days;
        uint256 todayMinted = dailyMinted[msg.sender][today];
        require(todayMinted + amount <= minterDailyLimit[msg.sender], "Exceeds daily limit");
        
        dailyMinted[msg.sender][today] = todayMinted + amount;
        cumulativeMinted += amount; // FIXED: Lifetime tracking
        currentSupply += amount;
        
        _mint(to, amount);
        emit TokensMinted(msg.sender, to, amount);
    }

    /**
     * @dev FIXED: Only decrease current supply, not cumulative
     */
    function burnFrom(address from, uint256 amount) external onlyRole(BURNER_ROLE) whenNotPaused {
        require(from != address(0), "Cannot burn from zero address");
        require(amount > 0, "Amount must be positive");
        require(balanceOf(from) >= amount, "Insufficient balance");
        
        currentSupply -= amount; // FIXED: Only current supply decreases
        _burn(from, amount);
        emit TokensBurned(msg.sender, from, amount);
    }

    /**
     * @dev Get current vs lifetime supply stats
     */
    function getSupplyStats() external view returns (uint256 current, uint256 lifetime, uint256 maxSupply) {
        return (currentSupply, cumulativeMinted, MAX_SUPPLY);
    }

    function setMinterDailyLimit(address minter, uint256 limit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minter != address(0), "Invalid minter address");
        minterDailyLimit[minter] = limit;
        emit MinterLimitUpdated(minter, limit);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        if (from != address(0) && to != address(0)) {
            revert("TupuTala tokens are non-transferable");
        }
    }
}