// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GiveawayManager
 * @notice Onchain, scheduled token giveaways with VRF-backed winner selection and secure claims.
 *
 * Features:
 *  - ERC20 and native ETH (token == address(0))
 *  - startTime / endTime scheduling
 *  - Optional eligibility verifier for gated entry (likes/recasts/replies)
 *  - Onchain participant storage (dedupe)
 *  - Random winner drawing via pluggable randomness provider
 *  - Equal prize per winner; creator can sweep remainder after all claims
 *
 * Trust boundaries:
 *  - Funds are escrowed in this contract per giveaway.
 *  - Randomness is supplied by `IRandomnessProvider` (e.g., Chainlink VRF wrapper).
 *  - Eligibility (optional) is enforced by `IEligibilityVerifier`.
 */

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IEligibilityVerifier {
    /// @notice Return true if `user` is eligible to enter the given giveaway.
    function isEligible(uint256 giveawayId, address user) external view returns (bool);
}

interface IRandomnessProvider {
    /// @notice Called by GiveawayManager to request randomness. Should arrange a later callback.
    function requestRandomness(uint256 giveawayId) external returns (bytes32 reqId);
}

contract GiveawayManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);

    // --- External hooks ---
    IRandomnessProvider public randomnessProvider; // must call back fulfillRandomness
    IEligibilityVerifier public eligibilityVerifier; // optional (can be address(0))

    event RandomnessProviderUpdated(address indexed provider);
    event EligibilityVerifierUpdated(address indexed verifier);

    // --- Giveaway model ---
    struct Giveaway {
        address creator;
        address token;        // ERC20 or address(0) for native
        uint256 totalAmount;  // escrowed
        uint64  startTime;    // unix seconds
        uint64  endTime;      // unix seconds
        uint32  maxWinners;   // >=1
        bool    drawn;        // winners selected
        bool    cancelled;    // creator cancelled before draw
        uint256 randomWord;   // set on VRF fulfillment
        uint32  winnersCount; // actual number selected (min(maxWinners, participants))
        uint32  claims;       // number of winners who claimed
        uint96  perWinner;    // computed on finalize (equal split)
        uint96  remainder;    // leftover after equal split (creator can sweep after all claims)
    }

    uint256 public nextGiveawayId;
    mapping(uint256 => Giveaway) public giveaways;

    // Participants
    mapping(uint256 => address[]) public participants;
    mapping(uint256 => mapping(address => bool)) public hasEntered;

    // Winners set & claim status
    mapping(uint256 => address[]) public winners;
    mapping(uint256 => mapping(address => bool)) public isWinner;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    // --- Events ---
    event GiveawayCreated(
        uint256 indexed id,
        address indexed creator,
        address indexed token,
        uint256 amount,
        uint64 startTime,
        uint64 endTime,
        uint32 maxWinners
    );
    event Entered(uint256 indexed id, address indexed user);
    event Cancelled(uint256 indexed id);
    event RandomnessRequested(uint256 indexed id, bytes32 reqId);
    event RandomnessFulfilled(uint256 indexed id, uint256 randomWord);
    event WinnersFinalized(uint256 indexed id, uint32 winnersCount, uint96 perWinner, uint96 remainder);
    event Claimed(uint256 indexed id, address indexed winner, uint256 amount);
    event RemainderSwept(uint256 indexed id, address indexed to, uint256 amount);

    constructor(address _randomnessProvider, address _eligibilityVerifier) Ownable() {
        if (_randomnessProvider != address(0)) {
            randomnessProvider = IRandomnessProvider(_randomnessProvider);
            emit RandomnessProviderUpdated(_randomnessProvider);
        }
        if (_eligibilityVerifier != address(0)) {
            eligibilityVerifier = IEligibilityVerifier(_eligibilityVerifier);
            emit EligibilityVerifierUpdated(_eligibilityVerifier);
        }
    }

    // --- Admin wiring ---

    function setRandomnessProvider(address _p) external onlyOwner {
        randomnessProvider = IRandomnessProvider(_p);
        emit RandomnessProviderUpdated(_p);
    }

    function setEligibilityVerifier(address _v) external onlyOwner {
        eligibilityVerifier = IEligibilityVerifier(_v);
        emit EligibilityVerifierUpdated(_v);
    }

    // --- Create / Fund ---

    /**
     * @notice Create a giveaway. For ERC20, prior approve is required. For native, send `amount` as msg.value.
     */
    function createGiveaway(
        address token,
        uint256 amount,
        uint64  startTime,
        uint64  endTime,
        uint32  maxWinners
    ) external payable returns (uint256 id) {
        require(amount > 0, "amount=0");
        require(maxWinners >= 1, "winners=0");
        require(endTime == 0 || endTime > startTime, "time");
        if (startTime == 0) startTime = uint64(block.timestamp);

        // Pull funds
        if (token == NATIVE) {
            require(msg.value == amount, "bad value");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            require(msg.value == 0, "no eth");
        }

        id = ++nextGiveawayId;
        giveaways[id] = Giveaway({
            creator: msg.sender,
            token: token,
            totalAmount: amount,
            startTime: startTime,
            endTime: endTime,
            maxWinners: maxWinners,
            drawn: false,
            cancelled: false,
            randomWord: 0,
            winnersCount: 0,
            claims: 0,
            perWinner: 0,
            remainder: 0
        });

        emit GiveawayCreated(id, msg.sender, token, amount, startTime, endTime, maxWinners);
    }

    // --- Participation ---

    function enterGiveaway(uint256 id) external {
        Giveaway memory g = giveaways[id];
        require(g.creator != address(0), "not found");
        require(!g.cancelled, "cancelled");
        require(block.timestamp >= g.startTime, "not started");
        if (g.endTime != 0) require(block.timestamp <= g.endTime, "ended");
        require(!g.drawn, "already drawn");

        // Optional eligibility
        if (address(eligibilityVerifier) != address(0)) {
            require(eligibilityVerifier.isEligible(id, msg.sender), "ineligible");
        }

        require(!hasEntered[id][msg.sender], "already");
        hasEntered[id][msg.sender] = true;
        participants[id].push(msg.sender);

        emit Entered(id, msg.sender);
    }

    // --- Cancellation (before draw)
