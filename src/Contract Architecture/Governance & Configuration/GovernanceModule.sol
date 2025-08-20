// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GovernanceModule
 * @notice Simple governance system where token holders can propose and vote on actions.
 */
contract GovernanceModule {
    struct Proposal {
        address proposer;
        string description;
        uint256 deadline;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed id, address indexed proposer, string description, uint256 deadline);
    event Voted(uint256 indexed id, address indexed voter, bool support);
    event ProposalExecuted(uint256 indexed id, bool passed);

    modifier proposalActive(uint256 id) {
        require(block.timestamp < proposals[id].deadline, "Governance: proposal ended");
        _;
    }

    function createProposal(string calldata description, uint256 duration) external returns (uint256) {
        uint256 id = ++proposalCount;
        proposals[id] = Proposal(msg.sender, description, block.timestamp + duration, 0, 0, false);
        emit ProposalCreated(id, msg.sender, description, block.timestamp + duration);
        return id;
    }

    function vote(uint256 id, bool support) external proposalActive(id) {
        require(!hasVoted[id][msg.sender], "Governance: already voted");
        hasVoted[id][msg.sender] = true;

        if (support) proposals[id].yesVotes++;
        else proposals[id].noVotes++;

        emit Voted(id, msg.sender, support);
    }

    function executeProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(block.timestamp >= p.deadline, "Governance: proposal still active");
        require(!p.executed, "Governance: already executed");

        bool passed = p.yesVotes > p.noVotes;
        p.executed = true;

        emit ProposalExecuted(id, passed);
    }
}
