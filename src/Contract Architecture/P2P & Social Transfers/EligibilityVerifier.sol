// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EligibilityVerifier
 * @notice Minimal contract to enforce per-user eligibility rules for modules.
 *         Can be extended with token/NFT gating or external verifiers.
 */
contract EligibilityVerifier {
    mapping(address => bool) public isEligible;

    event EligibilitySet(address indexed user, bool eligible);

    modifier onlyEligible(address user) {
        require(isEligible[user], "EligibilityVerifier: user not eligible");
        _;
    }

    function setEligibility(address user, bool eligible) external {
        // In production, replace `external` with proper admin access (Ownable / AccessControl)
        isEligible[user] = eligible;
        emit EligibilitySet(user, eligible);
    }

    function checkEligibility(address user) external view returns (bool) {
        return isEligible[user];
    }
}
