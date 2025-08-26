// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPolicast {

    //EERRORS
    //     // ERRORS
       // ERRORS
    error InsufficientBalance();
    error InvalidMarket();
    error MarketNotActive();
    error InvalidOption();
    error NotAuthorized();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error AlreadyClaimed();
    error NoWinningShares();
    error TransferFailed();
    error InvalidInput();
    error OnlyAdminOrOwner();
    error MarketEnded();
    error MarketResolvedAlready();
    error OptionInactive();
    error FeeTooHigh();
    error BadDuration();
    error EmptyQuestion();
    error BadOptionCount();
    error LengthMismatch();
    error MinTokensRequired();
    error SamePrizeRequired();
    error NotFreeMarket();
    error FreeEntryInactive();
    error AlreadyClaimedFree();
    error FreeSlotseFull();
    error ExceedsFreeAllowance();
    error InsufficientPrizePool();
    error CannotSwapSameOption();
    error AmountMustBePositive();
    error InsufficientShares();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error MarketNotValidated();
    error PriceTooHigh();
    error PriceTooLow();
    error MarketNotEndedYet();
    error InvalidWinningOption();
    error CannotDisputeIfWon();
    error MarketNotReady();
    error InvalidToken();
    error SameToken();
    error NoFeesToWithdraw();
    error NoLPRewards();
    error NotLiquidityProvider();
    error AdminLiquidityAlreadyClaimed();
    error NotSponsoredMarket();
    error InsufficientParticipants();
    error SponsoredPrizeAlreadyDistributed();
    error NoSponsoredPrize();
}