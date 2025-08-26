// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GovernanceModule
 * @notice Simple onchain governance for managing proposals, voting,
 *         and execution of system-level changes.
 */
contract GovernanceModule {
    struct Proposal {
        address proposer;
        string description;
        address target;
        bytes data;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 startBlock;
        uint256 endBlock;
        bool executed;
    }

    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    mapping(address => uint256) public votingPower; // can be ERC20-backed later
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public votingPeriod = 20_000; // ~3 days at 15s blocks
    uint256 public quorum = 100; // minimal voting power needed

    event ProposalCreated(uint256 indexed id, address proposer, string description);
    event Voted(uint256 indexed id, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyVoter() {
        require(votingPower[msg.sender] > 0, "Governance: no voting power");
        _;
    }

    // --- Voting Power Management (gov controlled) ---
    function setVotingPower(address voter, uint256 power) external {
        // in prod, use ERC20 snapshots or staking
        votingPower[voter] = power;
    }

    // --- Proposal Lifecycle ---
    function createProposal(
        string calldata description,
        address target,
        bytes calldata data
    ) external onlyVoter returns (uint256) {
        proposalCount++;
        proposals[proposalCount] = Proposal({
            proposer: msg.sender,
            description: description,
            target: target,
            data: data,
            votesFor: 0,
            votesAgainst: 0,
            startBlock: block.number,
            endBlock: block.number + votingPeriod,
            executed: false
        });

        emit ProposalCreated(proposalCount, msg.sender, description);
        return proposalCount;
    }

    function vote(uint256 proposalId, bool support) external onlyVoter {
        Proposal storage p = proposals[proposalId];
        require(block.number >= p.startBlock, "Governance: voting not started");
        require(block.number <= p.endBlock, "Governance: voting ended");
        require(!hasVoted[proposalId][msg.sender], "Governance: already voted");

        uint256 weight = votingPower[msg.sender];
        if (support) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        hasVoted[proposalId][msg.sender] = true;
        emit Voted(proposalId, msg.sender, support, weight);
    }

    function executeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(block.number > p.endBlock, "Governance: voting not ended");
        require(!p.executed, "Governance: already executed");
        require(p.votesFor >= quorum && p.votesFor > p.votesAgainst, "Governance: not passed");

        (bool success, ) = p.target.call(p.data);
        require(success, "Governance: execution failed");

        p.executed = true;
        emit ProposalExecuted(proposalId);
    }
}
