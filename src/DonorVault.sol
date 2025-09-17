// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./TupuRegistry.sol";
import "./TupuTala.sol";
import "./ProjectVault.sol";

/**
 * @title DonorVault
 * @dev CORRECTED: Fixed withdrawal limit logic and proposal IDs
 */
contract DonorVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    TupuRegistry public immutable registry;
    TupuTala public immutable tupuTala;
    IERC20 public immutable fundingToken;
    
    uint256 public dailyWithdrawalLimit;
    uint256 public totalDeposited;
    uint256 public totalAllocated;
    uint256 public requiredSignatures;
    uint256 public proposalCounter; // FIXED: Monotonic proposal counter
    
    mapping(address => uint256) public donorBalances;
    mapping(uint256 => uint256) public dailyWithdrawn;
    mapping(uint256 => AllocationProposal) public proposals; // FIXED: Use counter as key
    mapping(uint256 => mapping(address => bool)) public proposalSignatures;
    mapping(uint256 => uint256) public proposalSignatureCount;
    
    struct AllocationProposal {
        uint256 id;
        uint256 projectId;
        uint256 amount;
        address proposer;
        uint256 createdAt;
        uint256 executedAt;
        bool executed;
    }

    event FundsDeposited(address indexed donor, uint256 amount);
    event FundsWithdrawn(address indexed donor, uint256 amount);
    event AllocationProposed(uint256 indexed proposalId, uint256 indexed projectId, uint256 amount);
    event AllocationExecuted(uint256 indexed proposalId, uint256 indexed projectId, uint256 amount);
    event ProposalSigned(uint256 indexed proposalId, address indexed signer);

    modifier dailyLimit(uint256 amount) {
        uint256 today = block.timestamp / 1 days;
        require(dailyWithdrawn[today] + amount <= dailyWithdrawalLimit, "Daily limit exceeded");
        _;
    }

    constructor(
        address _registry,
        address _fundingToken,
        uint256 _dailyWithdrawalLimit,
        address[] memory _treasurers,
        uint256 _requiredSignatures
    ) {
        require(_registry != address(0), "Invalid registry address");
        require(_fundingToken != address(0), "Invalid funding token address");
        require(_treasurers.length >= _requiredSignatures, "Invalid signature requirement");
        require(_requiredSignatures > 0, "Required signatures must be > 0");
        
        registry = TupuRegistry(_registry);
        tupuTala = registry.tupuTala();
        fundingToken = IERC20(_fundingToken);
        dailyWithdrawalLimit = _dailyWithdrawalLimit;
        requiredSignatures = _requiredSignatures;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        for (uint i = 0; i < _treasurers.length; i++) {
            require(_treasurers[i] != address(0), "Invalid treasurer address");
            _grantRole(TREASURER_ROLE, _treasurers[i]);
            _grantRole(ALLOCATOR_ROLE, _treasurers[i]);
        }
    }

    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be positive");
        
        fundingToken.safeTransferFrom(msg.sender, address(this), amount);
        donorBalances[msg.sender] += amount;
        totalDeposited += amount;
        
        tupuTala.mint(msg.sender, amount);
        
        emit FundsDeposited(msg.sender, amount);
    }

    /**
     * @dev FIXED: Update daily limit only after successful transfer
     */
    function withdraw(uint256 amount) external whenNotPaused nonReentrant dailyLimit(amount) {
        require(amount > 0, "Amount must be positive");
        require(donorBalances[msg.sender] >= amount, "Insufficient balance");
        
        donorBalances[msg.sender] -= amount;
        totalDeposited -= amount;
        
        tupuTala.burnFrom(msg.sender, amount);
        fundingToken.safeTransfer(msg.sender, amount);
        
        // FIXED: Update daily limit only after successful transfer
        uint256 today = block.timestamp / 1 days;
        dailyWithdrawn[today] += amount;
        
        emit FundsWithdrawn(msg.sender, amount);
    }

    /**
     * @dev FIXED: Use monotonic proposal counter
     */
    function proposeAllocation(
        uint256 projectId,
        uint256 amount
    ) external onlyRole(ALLOCATOR_ROLE) whenNotPaused returns (uint256) {
        require(amount > 0, "Amount must be positive");
        require(fundingToken.balanceOf(address(this)) >= amount, "Insufficient funds");
        
        TupuRegistry.Project memory project = registry.getProject(projectId);
        require(project.active, "Project not active");
        
        uint256 proposalId = ++proposalCounter; // FIXED: Monotonic counter
        
        proposals[proposalId] = AllocationProposal({
            id: proposalId,
            projectId: projectId,
            amount: amount,
            proposer: msg.sender,
            createdAt: block.timestamp,
            executedAt: 0,
            executed: false
        });
        
        emit AllocationProposed(proposalId, projectId, amount);
        return proposalId;
    }

    /**
     * @dev FIXED: Use proposal ID as key instead of hash
     */
    function signProposal(uint256 proposalId) external onlyRole(TREASURER_ROLE) whenNotPaused {
        AllocationProposal storage proposal = proposals[proposalId];
        require(proposal.createdAt > 0, "Proposal does not exist");
        require(!proposal.executed, "Proposal already executed");
        require(!proposalSignatures[proposalId][msg.sender], "Already signed");
        require(block.timestamp <= proposal.createdAt + 7 days, "Proposal expired");
        
        proposalSignatures[proposalId][msg.sender] = true;
        proposalSignatureCount[proposalId]++;
        
        emit ProposalSigned(proposalId, msg.sender);
        
        if (proposalSignatureCount[proposalId] >= requiredSignatures) {
            _executeAllocation(proposalId);
        }
    }

    function _executeAllocation(uint256 proposalId) internal {
        AllocationProposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(fundingToken.balanceOf(address(this)) >= proposal.amount, "Insufficient funds");
        
        proposal.executed = true;
        proposal.executedAt = block.timestamp;
        totalAllocated += proposal.amount;
        
        TupuRegistry.Project memory project = registry.getProject(proposal.projectId);
        require(registry.isAuthorizedVault(project.projectVault), "Invalid project vault");
        
        fundingToken.safeTransfer(project.projectVault, proposal.amount);
        ProjectVault(project.projectVault).receiveAllocation(proposal.amount);
        
        emit AllocationExecuted(proposalId, proposal.projectId, proposal.amount);
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