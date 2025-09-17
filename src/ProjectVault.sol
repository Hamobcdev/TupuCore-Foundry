// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./TupuRegistry.sol";
import "./TupuTala.sol";
import "./DonorVault.sol";

/**
 * @title ProjectVault
 * @dev COMPLETED & CORRECTED: ESCROW MODEL - Tokens held until oracle confirmation
 */
contract ProjectVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    TupuRegistry public immutable registry;
    TupuTala public immutable tupuTala;
    IERC20 public immutable fundingToken;
    address public immutable projectManager;
    DonorVault public donorVault; 
    
    uint256 public totalAllocated;
    uint256 public totalDisbursed;
    uint256 public totalReturned;
    uint256 public transactionCounter;
    
    // FIXED: Escrow model - tokens held until confirmation
    struct Transaction {
        uint256 id;
        address recipient;
        uint256 amount;
        string purpose;
        uint256 createdAt;
        uint256 confirmedAt;
        uint256 oracleConfirmations;
        bool fiatTransferRequested;
        bool fiatTransferConfirmed;
        bool tokensReleased; 
        mapping(address => bool) oracleConfirmed;
    }
    
    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public transactionOracleConfirmations;
    uint256 public totalEscrowed; // FIXED: Track escrowed amounts

    event FundsReceived(uint256 amount);
    event FiatTransferRequested(uint256 indexed transactionId, address indexed recipient, uint256 amount);
    event FiatTransferConfirmed(uint256 indexed transactionId, address indexed oracle);
    event TokensReleased(uint256 indexed transactionId, address indexed recipient, uint256 amount);
    event FundsReturned(uint256 amount);
    event OracleConfirmation(uint256 indexed transactionId, address indexed oracle);
    event OracleConsensusReached(uint256 indexed transactionId); 

    modifier onlyAuthorizedOracle() {
        require(registry.hasRole(registry.ORACLE_ROLE(), msg.sender), "Not authorized oracle");
        _;
    }

    constructor(
        address _registry,
        address _tupuTala,
        address _fundingToken,
        address _projectManager
    ) {
        require(_registry != address(0), "Invalid registry address");
        require(_tupuTala != address(0), "Invalid TupuTala address");
        require(_fundingToken != address(0), "Invalid funding token address");
        require(_projectManager != address(0), "Invalid project manager address");
        
        registry = TupuRegistry(_registry);
        tupuTala = TupuTala(_tupuTala);
        fundingToken = IERC20(_fundingToken);
        projectManager = _projectManager;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _registry);
        _grantRole(MANAGER_ROLE, _projectManager);
    }

    /**
     * @dev FIXED: Store donor vault reference for returns
     */
    function setDonorVault(address _donorVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_donorVault != address(0), "Invalid donor vault");
        donorVault = DonorVault(_donorVault);
    }

    function receiveAllocation(uint256 amount) external nonReentrant {
        require(msg.sender == address(registry) || registry.isAuthorizedVault(msg.sender), "Unauthorized");
        require(amount > 0, "Amount must be positive");
        
        totalAllocated += amount;
        tupuTala.mint(address(this), amount);
        
        emit FundsReceived(amount);
    }

    /**
     * @dev FIXED: ESCROW MODEL - Request fiat transfer but hold tokens
     */
    function releaseFunds(
        address recipient,
        uint256 amount,
        string calldata purpose
    ) external onlyRole(MANAGER_ROLE) whenNotPaused nonReentrant returns (uint256) {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be positive");
        require(bytes(purpose).length > 0, "Purpose required");
        require(fundingToken.balanceOf(address(this)) >= totalEscrowed + amount, "Insufficient available funds");
        
        uint256 transactionId = ++transactionCounter;
        
        Transaction storage txn = transactions[transactionId];
        txn.id = transactionId;
        txn.recipient = recipient;
        txn.amount = amount;
        txn.purpose = purpose;
        txn.createdAt = block.timestamp;
        txn.fiatTransferRequested = true;
        
        // FIXED: Hold tokens in escrow, don't transfer yet
        totalEscrowed += amount;
        
        // Mint TupuTala receipt showing funds are committed (but not released)
        tupuTala.mint(address(this), amount);
        
        emit FiatTransferRequested(transactionId, recipient, amount);
        return transactionId;
    }

    /**
     * @dev FIXED: Oracle confirms AND releases tokens
     */
    function confirmFiatTransfer(uint256 transactionId) external onlyAuthorizedOracle whenNotPaused {
        Transaction storage txn = transactions[transactionId];
        require(txn.fiatTransferRequested, "Transaction not found or not requested");
        require(!txn.fiatTransferConfirmed, "Already confirmed");
        require(!transactionOracleConfirmations[transactionId][msg.sender], "Oracle already confirmed");
        
        transactionOracleConfirmations[transactionId][msg.sender] = true;
        txn.oracleConfirmations++;
        
        emit OracleConfirmation(transactionId, msg.sender);
        
        // FIXED: Check if enough confirmations received - emit consensus event once
        if (txn.oracleConfirmations >= registry.requiredOracleConsensus() && !txn.fiatTransferConfirmed) {
            txn.fiatTransferConfirmed = true;
            txn.confirmedAt = block.timestamp;
            
            // FIXED: NOW release the tokens
            _releaseEscrowedTokens(transactionId);
            
            emit OracleConsensusReached(transactionId);
            emit FiatTransferConfirmed(transactionId, msg.sender);
        }
    }

    /**
     * @dev FIXED: Release escrowed tokens after confirmation
     */
    function _releaseEscrowedTokens(uint256 transactionId) internal {
        Transaction storage txn = transactions[transactionId];
        require(txn.fiatTransferConfirmed, "Not confirmed yet");
        require(!txn.tokensReleased, "Tokens already released");
        
        txn.tokensReleased = true;
        totalEscrowed -= txn.amount;
        totalDisbursed += txn.amount;
        
        // Transfer funds to recipient
        fundingToken.safeTransfer(txn.recipient, txn.amount);
        
        // Burn TupuTala tokens to reflect the transfer
        tupuTala.burnFrom(address(this), txn.amount);
        
        emit TokensReleased(transactionId, txn.recipient, txn.amount);
    }
    
    /**
     * @dev Allows project manager to return unused funds to the DonorVault.
     * This is a critical part of the capital efficiency and audit trail.
     */
    function returnFunds(uint256 amount) external onlyRole(MANAGER_ROLE) whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be positive");
        require(fundingToken.balanceOf(address(this)) >= amount, "Insufficient funds");
        
        // Burn the TupuTala tokens first to update the on-chain audit trail
        tupuTala.burnFrom(address(this), amount);
        
        // Return the underlying funding token to the DonorVault
        fundingToken.safeTransfer(address(donorVault), amount);
        totalReturned += amount;
        
        emit FundsReturned(amount);
    }

    function getAvailableBalance() external view returns (uint256) {
        return fundingToken.balanceOf(address(this));
    }
    
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}