// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Governance
/// @notice Multi-signature governance contract for GhostChain protocol decisions.
///         Requires a minimum number of signers to approve proposals before execution.
///         Includes time-lock mechanism for sensitive operations.
contract Governance {
    // ───── State ─────

    /// @notice Minimum number of signatures required to approve a proposal
    uint256 public requiredSignatures;

    /// @notice Time-lock duration for critical operations (default: 2 days)
    uint256 public constant TIMELOCK_DURATION = 2 days;

    /// @notice Minimum time-lock duration (default: 1 day)
    uint256 public constant MIN_TIMELOCK = 1 days;

    /// @notice Maps signer address to boolean (is authorized signer)
    mapping(address => bool) public isSigner;

    /// @notice List of all authorized signers
    address[] public signers;

    /// @notice Proposal ID counter
    uint256 private _proposalCount;

    /// @notice Maps proposal ID to proposal details
    mapping(uint256 => Proposal) private _proposals;

    /// @notice Maps proposal ID => signer => has voted
    mapping(uint256 => mapping(address => bool)) private _votes;

    /// @notice Maps proposal ID => number of votes received
    mapping(uint256 => uint256) private _voteCount;

    // ───── Structs ─────

    /// @notice Represents a governance proposal
    struct Proposal {
        uint256 id;
        string title;
        string description;
        address target;
        bytes callData;
        uint256 value;
        uint256 createdAt;
        uint256 executionTime;
        uint256 expiresAt;
        ProposalStatus status;
        address proposer;
    }

    enum ProposalStatus {
        Pending,
        Active,
        Approved,
        Executed,
        Failed,
        Expired,
        Cancelled
    }

    // ───── Events ─────

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event RequiredSignaturesUpdated(uint256 newRequired);
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        address target,
        bytes callData
    );
    event VoteCasted(uint256 indexed proposalId, address indexed signer);
    event ProposalApproved(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);

    // ───── Custom Errors ─────

    error UnauthorizedSigner();
    error InvalidAddress();
    error InvalidSignatureCount();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalNotApproved();
    error ProposalAlreadyVoted();
    error ProposalAlreadyExecuted();
    error ProposalExpired();
    error ProposalTimeLocked();
    error ExecutionFailed();
    error DuplicateSigner();
    error SignerNotFound();
    error InsufficientSigners();
    error EmptySignerList();

    // ───── Modifiers ─────

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert UnauthorizedSigner();
        _;
    }

    // ───── Constructor ─────

    constructor(address[] memory _signers, uint256 _requiredSignatures) {
        if (_signers.length == 0) revert EmptySignerList();
        if (_requiredSignatures == 0 || _requiredSignatures > _signers.length) {
            revert InvalidSignatureCount();
        }

        // Add initial signers
        for (uint256 i = 0; i < _signers.length; i++) {
            if (_signers[i] == address(0)) revert InvalidAddress();
            if (isSigner[_signers[i]]) revert DuplicateSigner();

            isSigner[_signers[i]] = true;
            signers.push(_signers[i]);
        }

        requiredSignatures = _requiredSignatures;
    }

    // ───── Signer Management ─────

    /// @notice Adds a new authorized signer
    /// @param _signer Address to add as signer
    function addSigner(address _signer) external onlySigner {
        if (_signer == address(0)) revert InvalidAddress();
        if (isSigner[_signer]) revert DuplicateSigner();

        isSigner[_signer] = true;
        signers.push(_signer);

        emit SignerAdded(_signer);
    }

    /// @notice Removes an authorized signer
    /// @param _signer Address to remove from signers
    function removeSigner(address _signer) external onlySigner {
        if (!isSigner[_signer]) revert SignerNotFound();
        if (signers.length == 1) revert InsufficientSigners();
        if (requiredSignatures > signers.length - 1) revert InvalidSignatureCount();

        isSigner[_signer] = false;

        // Remove from array
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == _signer) {
                signers[i] = signers[signers.length - 1];
                signers.pop();
                break;
            }
        }

        emit SignerRemoved(_signer);
    }

    /// @notice Updates the required number of signatures for proposal approval
    /// @param _newRequired New required signature count
    function setRequiredSignatures(uint256 _newRequired) external onlySigner {
        if (_newRequired == 0 || _newRequired > signers.length) {
            revert InvalidSignatureCount();
        }

        requiredSignatures = _newRequired;
        emit RequiredSignaturesUpdated(_newRequired);
    }

    // ───── Proposal Management ─────

    /// @notice Creates a new governance proposal
    /// @param _title Title of the proposal
    /// @param _description Description of the proposal
    /// @param _target Contract address to call
    /// @param _callData Encoded function call data
    /// @param _value ETH value to send (0 for most calls)
    /// @return proposalId ID of the created proposal
    function createProposal(
        string memory _title,
        string memory _description,
        address _target,
        bytes memory _callData,
        uint256 _value
    ) external onlySigner returns (uint256 proposalId) {
        if (_target == address(0)) revert InvalidAddress();

        proposalId = _proposalCount++;

        _proposals[proposalId] = Proposal({
            id: proposalId,
            title: _title,
            description: _description,
            target: _target,
            callData: _callData,
            value: _value,
            createdAt: block.timestamp,
            executionTime: block.timestamp + TIMELOCK_DURATION,
            expiresAt: block.timestamp + 14 days,
            status: ProposalStatus.Pending,
            proposer: msg.sender
        });

        emit ProposalCreated(proposalId, msg.sender, _title, _target, _callData);
    }

    /// @notice Casts a vote on a proposal
    /// @param _proposalId ID of the proposal to vote on
    function vote(uint256 _proposalId) external onlySigner {
        Proposal storage proposal = _proposals[_proposalId];

        if (proposal.status == ProposalStatus.Pending) {
            proposal.status = ProposalStatus.Active;
        }

        if (proposal.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.timestamp > proposal.expiresAt) revert ProposalExpired();
        if (_votes[_proposalId][msg.sender]) revert ProposalAlreadyVoted();

        _votes[_proposalId][msg.sender] = true;
        _voteCount[_proposalId]++;

        emit VoteCasted(_proposalId, msg.sender);

        // Check if proposal is now approved
        if (_voteCount[_proposalId] >= requiredSignatures) {
            proposal.status = ProposalStatus.Approved;
            emit ProposalApproved(_proposalId);
        }
    }

    /// @notice Executes an approved proposal (after time-lock)
    /// @param _proposalId ID of the proposal to execute
    function executeProposal(uint256 _proposalId) external {
        Proposal storage proposal = _proposals[_proposalId];

        if (proposal.status == ProposalStatus.Pending || proposal.status == ProposalStatus.Active) {
            if (block.timestamp > proposal.expiresAt) {
                proposal.status = ProposalStatus.Expired;
                revert ProposalExpired();
            }
            revert ProposalNotApproved();
        }

        if (proposal.status != ProposalStatus.Approved) revert ProposalNotApproved();
        if (proposal.status == ProposalStatus.Executed) revert ProposalAlreadyExecuted();
        if (block.timestamp < proposal.executionTime) revert ProposalTimeLocked();

        proposal.status = ProposalStatus.Executed;

        // Execute the proposal
        (bool success, ) = proposal.target.call{value: proposal.value}(proposal.callData);
        if (!success) revert ExecutionFailed();

        emit ProposalExecuted(_proposalId);
    }

    /// @notice Cancels a proposal
    /// @param _proposalId ID of the proposal to cancel
    function cancelProposal(uint256 _proposalId) external onlySigner {
        Proposal storage proposal = _proposals[_proposalId];

        if (
            proposal.status == ProposalStatus.Executed ||
            proposal.status == ProposalStatus.Expired ||
            proposal.status == ProposalStatus.Cancelled
        ) {
            revert ProposalNotActive();
        }

        proposal.status = ProposalStatus.Cancelled;
        emit ProposalCancelled(_proposalId);
    }

    // ───── Query Functions ─────

    /// @notice Returns the number of signers
    /// @return Number of authorized signers
    function getSignerCount() external view returns (uint256) {
        return signers.length;
    }

    /// @notice Returns all signers
    /// @return Array of authorized signer addresses
    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    /// @notice Returns a proposal's details
    /// @param _proposalId ID of the proposal
    /// @return Proposal struct containing all details
    function getProposal(uint256 _proposalId) external view returns (Proposal memory) {
        return _proposals[_proposalId];
    }

    /// @notice Returns vote count for a proposal
    /// @param _proposalId ID of the proposal
    /// @return Number of votes received
    function getVoteCount(uint256 _proposalId) external view returns (uint256) {
        return _voteCount[_proposalId];
    }

    /// @notice Checks if an address has voted on a proposal
    /// @param _proposalId ID of the proposal
    /// @param _signer Address to check
    /// @return True if the signer has voted
    function hasVoted(uint256 _proposalId, address _signer) external view returns (bool) {
        return _votes[_proposalId][_signer];
    }

    /// @notice Returns total number of proposals created
    /// @return Number of proposals
    function getProposalCount() external view returns (uint256) {
        return _proposalCount;
    }

    // ───── Emergency Functions ─────

    /// @notice Allows contract to receive ETH
    receive() external payable {}

    /// @notice Withdraws accidentally sent ETH
    /// @param _to Address to send ETH to
    function withdrawETH(address payable _to) external onlySigner {
        if (_to == address(0)) revert InvalidAddress();
        (bool success, ) = _to.call{value: address(this).balance}("");
        if (!success) revert ExecutionFailed();
    }
}
