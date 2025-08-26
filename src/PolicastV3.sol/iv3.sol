//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPolicast {
    // Market Categories
    enum MarketCategory {
        POLITICS,
        SPORTS,
        ENTERTAINMENT,
        TECHNOLOGY,
        ECONOMICS,
        SCIENCE,
        WEATHER,
        OTHER
    }

//     // Market Types
    enum MarketType {
        PAID,           // Regular betting token markets
        FREE_ENTRY,     // Free markets with limited participation
        SPONSORED       // Sponsored by third parties with prize pools
    }


   struct MarketOption {
        string name;
        string description;
        uint256 totalShares;
        uint256 totalVolume;
        uint256 currentPrice; // Price in wei (scaled by 1e18)
        bool isActive;
        uint256 k; // AMM liquidity constant for this option
        uint256 reserve; // AMM reserve for this option
    }

    struct FreeMarketConfig {
        uint256 maxFreeParticipants;     // Max users who can enter for free
        uint256 tokensPerParticipant;    // Buster tokens per user (instead of shares)
        uint256 currentFreeParticipants; // Current count
        uint256 totalPrizePool;          // Total tokens allocated for free users
        uint256 remainingPrizePool;      // Remaining tokens available
        bool isActive;                   // Can still accept free entries
        mapping(address => bool) hasClaimedFree; // Track who claimed free tokens
        mapping(address => uint256) tokensReceived; // Amount of free tokens claimed per user
    }

    struct SponsoredMarketConfig {
        address sponsor;                 // Sponsor address
        uint256 sponsorPrize;           // Total prize pool from sponsor
        uint256 minimumParticipants;    // Min participants for prize distribution
        bool prizeDistributed;          // Whether prize has been distributed
        string sponsorMessage;          // Sponsor message/branding
    }

    struct Market {
        string question;
        string description;
        uint256 endTime;
        MarketCategory category;
        MarketType marketType;           // Market type (PAID, FREE_ENTRY, SPONSORED)
        uint256 winningOptionId;
        bool resolved;
        bool disputed;
        bool validated;
        address creator;
        uint256 adminInitialLiquidity;   // NEW: Admin's initial liquidity (separate tracking)
        uint256 userLiquidity;           // NEW: User contributions only
        uint256 totalVolume;
        uint256 createdAt;
        uint256 optionCount;
        uint256 ammLiquidityPool;        // Total AMM liquidity
        uint256 platformFeesCollected;   // NEW: Platform fees for this market
        uint256 ammFeesCollected;        // NEW: AMM fees for LPs
        bool adminLiquidityClaimed;      // NEW: Track if admin claimed their liquidity back
        mapping(uint256 => MarketOption) options;
        mapping(address => mapping(uint256 => uint256)) userShares; // user => optionId => shares
        mapping(address => bool) hasClaimed;
        mapping(address => bool) hasClaimedSponsored; // NEW: Track sponsored prize claims
        mapping(address => uint256) lpContributions; // NEW: Track LP contributions
        mapping(address => bool) lpRewardsClaimed;   // NEW: Track LP reward claims
        address[] participants;
        address[] liquidityProviders;    // NEW: Track LP addresses
        uint256 payoutIndex;
        FreeMarketConfig freeConfig;     // Free market configuration
        SponsoredMarketConfig sponsorConfig; // Sponsored market configuration
    }

     struct Trade {
        uint256 marketId;
        uint256 optionId;
        address buyer;
        address seller;
        uint256 price;
        uint256 quantity;
        uint256 timestamp;
    }

    struct PricePoint {
        uint256 price;
        uint256 timestamp;
        uint256 volume;
    }

    struct UserPortfolio {
        uint256 totalInvested;
        uint256 totalWinnings;
        int256 unrealizedPnL;
        int256 realizedPnL;
        uint256 tradeCount;
    }

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

   //     // Events
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        string[] options,
        uint256 endTime,
        MarketCategory category,
        MarketType marketType,
        address creator
    );
    event FreeTokensClaimed(uint256 indexed marketId, address indexed user, uint256 tokens);
    event MarketSponsored(uint256 indexed marketId, address indexed sponsor, uint256 prizeAmount, string message);
    event BettingTokenUpdated(address indexed oldToken, address indexed newToken, uint256 timestamp);
    event AMMSwap(uint256 indexed marketId, uint256 optionIdIn, uint256 optionIdOut, uint256 amountIn, uint256 amountOut, address trader);
    event LiquidityAdded(uint256 indexed marketId, address indexed provider, uint256 amount);
    event MarketValidated(uint256 indexed marketId, address validator);
    event TradeExecuted(
        uint256 indexed marketId,
        uint256 indexed optionId,
        address indexed buyer,
        address seller,
        uint256 price,
        uint256 quantity,
        uint256 tradeId
    );
    event SharesSold(
        uint256 indexed marketId,
        uint256 indexed optionId,
        address indexed seller,
        uint256 quantity,
        uint256 price
    );
    event MarketResolved(uint256 indexed marketId, uint256 winningOptionId, address resolver);
    event MarketDisputed(uint256 indexed marketId, address disputer, string reason);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 amount);
    event FeeCollected(uint256 indexed marketId, uint256 amount);
    event MarketPaused(uint256 indexed marketId);
    event PlatformFeesWithdrawn(address indexed collector, uint256 amount);
    event AdminLiquidityWithdrawn(uint256 indexed marketId, address indexed creator, uint256 amount);
    event LPRewardsClaimed(uint256 indexed marketId, address indexed provider, uint256 amount);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event SponsoredPrizeClaimed(uint256 indexed marketId, address indexed winner, uint256 amount);
    event SponsoredPrizeRefunded(uint256 indexed marketId, address indexed sponsor, uint256 amount);


}