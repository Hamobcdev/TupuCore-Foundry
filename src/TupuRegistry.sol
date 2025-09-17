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
import "./ProjectVault.sol"; // Import the ProjectVault contract

/**
 * @title TupuRegistry
 * @dev CORRECTED: Fixed emergency withdrawal and governance separation
 */
contract TupuRegistry is AccessControl, TimelockController, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant PROJECT_MANAGER_ROLE = keccak256("PROJECT_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant EMERGENCY_MULTISIG_ROLE = keccak256("EMERGENCY_MULTISIG_ROLE");

    TupuTala public immutable tupuTala;
    IERC20Metadata public fundingToken; // FIXED: Use IERC20Metadata for decimals check
    
    uint256 public projectCounter;
    uint256 public proposalCounter; // FIXED: Monotonic proposal IDs
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant EXPECTED_FUNDING_TOKEN_DECIMALS = 6; // USDT standard
    
    struct Project {
        uint256 id;
        address projectVault;
        address manager;
        string metadataURI;
        bool active;
        uint256 createdAt;
        uint256 totalAllocated;
    }
    
    mapping(uint256 => Project) public projects;
    mapping(address => bool) public authorizedVaults;
    mapping(address => bool) public activeOracles;
    
    // FIXED: Emergency withdrawal requires multisig
    struct EmergencyWithdrawalProposal {
        uint256 amount;
        address recipient;
        uint256 signatures;
        mapping(address => bool) signed;
        bool executed;
        uint256 createdAt;
    }
    mapping(uint256 => EmergencyWithdrawalProposal) public emergencyProposals;
    uint256 public emergencyProposalCounter;
    uint256 public requiredEmergencySignatures = 2;
    
    uint256 public oracleCount;
    uint256 public requiredOracleConsensus = 2;

    event ProjectCreated(uint256 indexed projectId, address indexed projectVault, address indexed manager);
    event ProjectDeactivated(uint256 indexed projectId);
    event OracleUpdated(address indexed oracle, bool active);
    event FundingTokenUpdated(address indexed oldToken, address indexed newToken);
    event EmergencyWithdrawalProposed(uint256 indexed proposalId, uint256 amount, address recipient);
    event EmergencyWithdrawalExecuted(uint256 indexed proposalId, address indexed admin, uint256 amount);
    event EmergencyPaused(address indexed admin);
    event OracleConsensusReached(uint256 indexed transactionId);

    constructor(
        address _tupuTala,
        address _fundingToken,
        address[] memory _initialAdmins,
        address[] memory _initialOracles
    ) TimelockController(TIMELOCK_DELAY, _initialAdmins, _initialAdmins, address(0)) {
        require(_tupuTala != address(0), "Invalid TupuTala address");
        require(_fundingToken != address(0), "Invalid funding token address");
        require(_initialAdmins.length > 0, "No initial admins");
        require(_initialOracles.length >= 2, "Need at least 2 oracles");
        
        tupuTala = TupuTala(_tupuTala);
        
        // FIXED: Validate funding token decimals
        IERC20Metadata tokenContract = IERC20Metadata(_fundingToken);
        require(tokenContract.decimals() == EXPECTED_FUNDING_TOKEN_DECIMALS, "Invalid token decimals");
        fundingToken = tokenContract;
        
        for (uint i = 0; i < _initialAdmins.length; i++) {
            require(_initialAdmins[i] != address(0), "Invalid admin address");
            _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmins[i]);
            _grantRole(EMERGENCY_ROLE, _initialAdmins[i]);
            _grantRole(EMERGENCY_MULTISIG_ROLE, _initialAdmins[i]); // FIXED: Emergency multisig role
        }
        
        for (uint i = 0; i < _initialOracles.length; i++) {
            require(_initialOracles[i] != address(0), "Invalid oracle address");
            _setOracle(_initialOracles[i], true);
        }
        
        _grantRole(PAUSER_ROLE, address(this));
    }

    /**
     * @dev FIXED: Use monotonic counter for deterministic project vault addresses
     */
    function createProject(
        address manager,
        string calldata metadataURI
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused nonReentrant returns (uint256) {
        require(manager != address(0), "Invalid manager address");
        require(bytes(metadataURI).length > 0, "Empty metadata URI");
        
        uint256 projectId = ++projectCounter;
        
        // FIXED: Deterministic salt using only projectId and manager
        bytes32 salt = keccak256(abi.encodePacked(projectId, manager));
        ProjectVault projectVault = new ProjectVault{salt: salt}(
            address(this),
            address(tupuTala),
            address(fundingToken),
            manager
        );
        
        projects[projectId] = Project({
            id: projectId,
            projectVault: address(projectVault),
            manager: manager,
            metadataURI: metadataURI,
            active: true,
            createdAt: block.timestamp,
            totalAllocated: 0
        });
        
        authorizedVaults[address(projectVault)] = true;
        
        tupuTala.grantRole(tupuTala.MINTER_ROLE(), address(projectVault));
        tupuTala.setMinterDailyLimit(address(projectVault), 1_000_000 * 10**18);
        _grantRole(PROJECT_MANAGER_ROLE, manager);
        
        emit ProjectCreated(projectId, address(projectVault), manager);
        return projectId;
    }

    /**
     * @dev FIXED: Timelock-protected function clearly marked
     */
    function deactivateProject(uint256 projectId) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(projects[projectId].active, "Project not active");
        projects[projectId].active = false;
        authorizedVaults[projects[projectId].projectVault] = false;
        emit ProjectDeactivated(projectId);
    }

    /**
     * @dev FIXED: Timelock-protected with decimals validation
     */
    function updateFundingToken(address newToken) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(newToken != address(0), "Invalid token address");
        IERC20Metadata tokenContract = IERC20Metadata(newToken);
        require(tokenContract.decimals() == EXPECTED_FUNDING_TOKEN_DECIMALS, "Invalid token decimals");
        
        address oldToken = address(fundingToken);
        fundingToken = tokenContract;
        emit FundingTokenUpdated(oldToken, newToken);
    }

    /**
     * @dev FIXED: Emergency withdrawal requires multisig proposal
     */
    function proposeEmergencyWithdrawal(uint256 amount, address recipient) 
        external onlyRole(EMERGENCY_MULTISIG_ROLE) whenPaused returns (uint256) {
        require(amount > 0, "Invalid amount");
        require(recipient != address(0), "Invalid recipient");
        require(fundingToken.balanceOf(address(this)) >= amount, "Insufficient balance");
        
        uint256 proposalId = ++emergencyProposalCounter;
        EmergencyWithdrawalProposal storage proposal = emergencyProposals[proposalId];
        proposal.amount = amount;
        proposal.recipient = recipient;
        proposal.createdAt = block.timestamp;
        
        emit EmergencyWithdrawalProposed(proposalId, amount, recipient);
        return proposalId;
    }

    /**
     * @dev FIXED: Sign emergency withdrawal proposal
     */
    function signEmergencyWithdrawal(uint256 proposalId) external onlyRole(EMERGENCY_MULTISIG_ROLE) {
        EmergencyWithdrawalProposal storage proposal = emergencyProposals[proposalId];
        require(proposal.createdAt > 0, "Proposal not found");
        require(!proposal.executed, "Already executed");
        require(!proposal.signed[msg.sender], "Already signed");
        require(block.timestamp <= proposal.createdAt + 1 days, "Proposal expired");
        
        proposal.signed[msg.sender] = true;
        proposal.signatures++;
        
        // Execute if threshold met
        if (proposal.signatures >= requiredEmergencySignatures) {
            proposal.executed = true;
            fundingToken.safeTransfer(proposal.recipient, proposal.amount);
            emit EmergencyWithdrawalExecuted(proposalId, msg.sender, proposal.amount);
        }
    }

    function setOracle(address oracle, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setOracle(oracle, active);
    }

    function _setOracle(address oracle, bool active) internal {
        require(oracle != address(0), "Invalid oracle address");
        
        if (active && !activeOracles[oracle]) {
            activeOracles[oracle] = true;
            oracleCount++;
            _grantRole(ORACLE_ROLE, oracle);
        } else if (!active && activeOracles[oracle]) {
            activeOracles[oracle] = false;
            oracleCount--;
            _revokeRole(ORACLE_ROLE, oracle);
        }
        
        require(oracleCount >= 2, "Must maintain at least 2 active oracles");
        emit OracleUpdated(oracle, active);
    }

    /**
     * @dev FIXED: Emergency pause emits event
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function isAuthorizedVault(address vault) external view returns (bool) {
        return authorizedVaults[vault];
    }

    function getProject(uint256 projectId) external view returns (Project memory) {
        return projects[projectId];
    }
}