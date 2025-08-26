// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPolicast} from "./iv3.sol";

contract PolicastMarketV3 is Ownable, ReentrancyGuard, AccessControl, Pausable {

    bytes32 public constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 public constant QUESTION_RESOLVE_ROLE = keccak256("QUESTION_RESOLVE_ROLE");
    bytes32 public constant MARKET_VALIDATOR_ROLE = keccak256("MARKET_VALIDATOR_ROLE");

  // State variables
    IERC20 public bettingToken;
    address public previousBettingToken;     // Track previous token for migration
    uint256 public tokenUpdatedAt;           // When token was last updated
    uint256 public marketCount;
    uint256 public tradeCount;
    uint256 public platformFeeRate = 200; // 2% (basis points)
    uint256 public constant MAX_OPTIONS = 10;
    uint256 public constant MIN_MARKET_DURATION = 1 hours;
    uint256 public constant MAX_MARKET_DURATION = 365 days;
    uint256 public constant AMM_FEE_RATE = 30; // 0.3% AMM swap fee
    address public feeCollector;              // NEW: Address that can withdraw platform fees
    uint256 public totalPlatformFeesCollected; // NEW: Global platform fees

  // Mappings
    mapping(uint256 => IPolicast.Market) internal markets;
    mapping(address => IPolicast.UserPortfolio) public userPortfolios;
    mapping(address => IPolicast.Trade[]) public userTradeHistory;
    mapping(uint256 => IPolicast.Trade[]) public marketTrades;
    mapping(uint256 => mapping(uint256 => IPolicast.PricePoint[])) public priceHistory; // marketId => optionId => prices
    mapping(IPolicast.MarketCategory => uint256[]) public categoryMarkets;
    mapping(address => uint256) public totalWinnings;
    mapping(IPolicast.MarketType => uint256[]) public marketsByType; // Markets by type
    mapping(address => uint256) public lpRewardsEarned;   // NEW: LP rewards earned globally
    address[] public allParticipants;


    constructor(address _bettingToken) Ownable(msg.sender) {
        bettingToken = IERC20(_bettingToken);
        tokenUpdatedAt = block.timestamp;
        feeCollector = msg.sender; // Owner is initial fee collector
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

//     // Token Management Functions
    function updateBettingToken(address _newToken) external {
        if (msg.sender != owner() && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert IPolicast.OnlyAdminOrOwner();
        if (_newToken == address(0)) revert IPolicast.InvalidToken();
        if (_newToken == address(bettingToken)) revert IPolicast.SameToken();
        
        previousBettingToken = address(bettingToken);
        bettingToken = IERC20(_newToken);
        tokenUpdatedAt = block.timestamp;
        
        emit IPolicast.BettingTokenUpdated(previousBettingToken, _newToken, block.timestamp);
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        if (_feeCollector == address(0)) revert IPolicast.InvalidToken();
        address oldCollector = feeCollector;
        feeCollector = _feeCollector;
        emit IPolicast.FeeCollectorUpdated(oldCollector, _feeCollector);
    }

//     // Modifiers
    modifier validMarket(uint256 _marketId) {
        if (_marketId >= marketCount) revert IPolicast.InvalidMarket();
        _;
    }

    modifier marketActive(uint256 _marketId) {
        if (block.timestamp >= markets[_marketId].endTime) revert IPolicast.MarketEnded();
        if (markets[_marketId].resolved) revert IPolicast.MarketResolvedAlready();
        _;
    }

    modifier validOption(uint256 _marketId, uint256 _optionId) {
        if (_optionId >= markets[_marketId].optionCount) revert IPolicast.InvalidOption();
        if (!markets[_marketId].options[_optionId].isActive) revert IPolicast.OptionInactive();
        _;
    }

//     // Admin Functions
    function grantQuestionCreatorRole(address _account) external onlyOwner {
        grantRole(QUESTION_CREATOR_ROLE, _account);
    }

    function grantQuestionResolveRole(address _account) external onlyOwner {
        grantRole(QUESTION_RESOLVE_ROLE, _account);
    }

    function grantMarketValidatorRole(address _account) external onlyOwner {
        grantRole(MARKET_VALIDATOR_ROLE, _account);
    }

    function setPlatformFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > 1000) revert IPolicast.FeeTooHigh();
        platformFeeRate = _feeRate;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

//     // Market Creation
    function createMarket(
        string memory _question,
        string memory _description,
        string[] memory _optionNames,
        string[] memory _optionDescriptions,
        uint256 _duration,
        IPolicast.MarketCategory _category,
       IPolicast.MarketType _marketType,
        uint256 _initialLiquidity
    ) public whenNotPaused returns (uint256) {
        if (msg.sender != owner() && !hasRole(QUESTION_CREATOR_ROLE, msg.sender)) revert IPolicast.NotAuthorized();
        if (_duration < MIN_MARKET_DURATION || _duration > MAX_MARKET_DURATION) revert IPolicast.BadDuration();
        if (bytes(_question).length == 0) revert IPolicast.EmptyQuestion();
        if (_optionNames.length < 2 || _optionNames.length > MAX_OPTIONS) revert IPolicast.BadOptionCount();
        if (_optionNames.length != _optionDescriptions.length) revert IPolicast.LengthMismatch();
        if (_initialLiquidity < 100 * 1e18) revert IPolicast.MinTokensRequired();

        // Transfer initial liquidity from creator
        if (!bettingToken.transferFrom(msg.sender, address(this), _initialLiquidity)) revert IPolicast.TransferFailed();

        uint256 marketId = marketCount++;
        IPolicast.Market storage market = markets[marketId];
        market.question = _question;
        market.description = _description;
        market.endTime = block.timestamp + _duration;
        market.category = _category;
        market.marketType = _marketType;
        market.creator = msg.sender;
        market.createdAt = block.timestamp;
        market.optionCount = _optionNames.length;

        // Track admin's initial liquidity separately
        market.adminInitialLiquidity = _initialLiquidity;
        market.userLiquidity = 0; // No user liquidity yet

        // Initialize AMM liquidity pool with provided liquidity
        market.ammLiquidityPool = _initialLiquidity;

        // Initialize options with equal starting prices and AMM constants
        uint256 initialPrice = 1e18 / _optionNames.length; // Equal probability distribution
        uint256 initialK = _initialLiquidity / _optionNames.length; // AMM constant per option
        
        for (uint256 i = 0; i < _optionNames.length; i++) {
            market.options[i] = IPolicast.MarketOption({
                name: _optionNames[i],
                description: _optionDescriptions[i],
                totalShares: 0,
                totalVolume: 0,
                currentPrice: initialPrice,
                isActive: true,
                k: initialK,
                reserve: initialK
            });

            // Initialize price history
            priceHistory[marketId][i].push(IPolicast.PricePoint({
                price: initialPrice,
                timestamp: block.timestamp,
                volume: 0
            }));
        }

        categoryMarkets[_category].push(marketId);
        marketsByType[_marketType].push(marketId);

        emit IPolicast.MarketCreated(marketId, _question, _optionNames, market.endTime, _category, _marketType, msg.sender);
        return marketId;
    }

//     // Create Free Entry Market
    function createFreeMarket(
        string memory _question,
        string memory _description,
        string[] memory _optionNames,
        string[] memory _optionDescriptions,
        uint256 _duration,
        IPolicast.MarketCategory _category,
        uint256 _maxFreeParticipants,
        uint256 _tokensPerParticipant,
        uint256 _initialLiquidity
    ) external whenNotPaused returns (uint256) {
        // Calculate total required: liquidity + prize pool
        uint256 totalPrizePool = _maxFreeParticipants * _tokensPerParticipant;
        uint256 totalRequired = _initialLiquidity + totalPrizePool;
        
        // Transfer both liquidity and prize pool from creator
        if (!bettingToken.transferFrom(msg.sender, address(this), totalRequired)) revert IPolicast.TransferFailed();
        
        uint256 marketId = createMarket(_question, _description, _optionNames, _optionDescriptions, _duration, _category, IPolicast.MarketType.FREE_ENTRY, _initialLiquidity);
        
        IPolicast.Market storage market = markets[marketId];
        market.freeConfig.maxFreeParticipants = _maxFreeParticipants;
        market.freeConfig.tokensPerParticipant = _tokensPerParticipant;
        market.freeConfig.totalPrizePool = totalPrizePool;
        market.freeConfig.remainingPrizePool = totalPrizePool;
        market.freeConfig.isActive = true;
        
        return marketId;
    }

    // Create Sponsored Market
    function createSponsoredMarket(
        string memory _question,
        string memory _description,
        string[] memory _optionNames,
        string[] memory _optionDescriptions,
        uint256 _duration,
        IPolicast.MarketCategory _category,
        uint256 _minimumParticipants,
        string memory _sponsorMessage,
        uint256 _initialLiquidity
    ) external payable whenNotPaused returns (uint256) {
        if (msg.value == 0) revert IPolicast.SamePrizeRequired();
        
        uint256 marketId = createMarket(_question, _description, _optionNames, _optionDescriptions, _duration, _category, IPolicast.MarketType.SPONSORED, _initialLiquidity);
        
        IPolicast.Market storage market = markets[marketId];
        market.sponsorConfig.sponsor = msg.sender;
        market.sponsorConfig.sponsorPrize = msg.value;
        market.sponsorConfig.minimumParticipants = _minimumParticipants;
        market.sponsorConfig.sponsorMessage = _sponsorMessage;
        
        emit IPolicast.MarketSponsored(marketId, msg.sender, msg.value, _sponsorMessage);
        return marketId;
    }

    // Create Market with Default Liquidity (convenience function)
    function createMarketWithDefaultLiquidity(
        string memory _question,
        string memory _description,
        string[] memory _optionNames,
        string[] memory _optionDescriptions,
        uint256 _duration,
        IPolicast.MarketCategory _category,
       IPolicast.MarketType _marketType
    ) external whenNotPaused returns (uint256) {
        uint256 defaultLiquidity = 1000 * 1e18; // 1000 tokens default
        return createMarket(_question, _description, _optionNames, _optionDescriptions, _duration, _category, _marketType, defaultLiquidity);
    }

    function validateMarket(uint256 _marketId) external validMarket(_marketId) {
        if (!hasRole(MARKET_VALIDATOR_ROLE, msg.sender) && msg.sender != owner()) revert IPolicast.NotAuthorized();
        if (markets[_marketId].validated) revert IPolicast.MarketAlreadyResolved();
        
        markets[_marketId].validated = true;
        emit IPolicast.MarketValidated(_marketId, msg.sender);
    }

    // Trading Functions
    function claimFreeTokens(
        uint256 _marketId
    ) external nonReentrant whenNotPaused validMarket(_marketId) marketActive(_marketId) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.FREE_ENTRY) revert IPolicast.NotFreeMarket();
        if (!market.freeConfig.isActive) revert IPolicast.FreeEntryInactive();
        if (market.freeConfig.hasClaimedFree[msg.sender]) revert IPolicast.AlreadyClaimedFree();
        if (market.freeConfig.currentFreeParticipants >= market.freeConfig.maxFreeParticipants) revert IPolicast.FreeSlotseFull();
        if (market.freeConfig.remainingPrizePool < market.freeConfig.tokensPerParticipant) revert IPolicast.InsufficientPrizePool();

        uint256 freeTokens = market.freeConfig.tokensPerParticipant;
        
        // Update tracking
        market.freeConfig.hasClaimedFree[msg.sender] = true;
        market.freeConfig.tokensReceived[msg.sender] = freeTokens;
        market.freeConfig.currentFreeParticipants++;
        market.freeConfig.remainingPrizePool -= freeTokens;

        // Add user as participant if new
        if (_isNewParticipant(msg.sender, _marketId)) {
            market.participants.push(msg.sender);
            if (userPortfolios[msg.sender].totalInvested == 0) {
                allParticipants.push(msg.sender);
            }
        }

        // Transfer actual Buster tokens to user
        if (!bettingToken.transfer(msg.sender, freeTokens)) revert IPolicast.TransferFailed();
        
        // Update user portfolio (tokens received count as "investment" for tracking)
        userPortfolios[msg.sender].tradeCount++;

        emit IPolicast.FreeTokensClaimed(_marketId, msg.sender, freeTokens);
    }

    // AMM Swap Function
    function ammSwap(
        uint256 _marketId,
        uint256 _optionIdIn,
        uint256 _optionIdOut,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external nonReentrant whenNotPaused validMarket(_marketId) marketActive(_marketId) returns (uint256 amountOut) {
        if (_optionIdIn == _optionIdOut) revert IPolicast.CannotSwapSameOption();
        if (_amountIn == 0) revert IPolicast.AmountMustBePositive();
        if (markets[_marketId].userShares[msg.sender][_optionIdIn] < _amountIn) revert IPolicast.InsufficientShares();

        IPolicast.Market storage market = markets[_marketId];
        IPolicast.MarketOption storage optionIn = market.options[_optionIdIn];
        IPolicast.MarketOption storage optionOut = market.options[_optionIdOut];

        // Calculate AMM swap using constant product formula: x * y = k
        uint256 reserveIn = optionIn.reserve;
        uint256 reserveOut = optionOut.reserve;
        
        // Apply AMM fee
        uint256 amountInWithFee = _amountIn * (10000 - AMM_FEE_RATE) / 10000;
        uint256 ammFee = _amountIn - amountInWithFee;
        
        // Track AMM fees for LP rewards
        market.ammFeesCollected += ammFee;
        
        // Calculate output amount: amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee)
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);
        if (amountOut < _minAmountOut) revert IPolicast.InsufficientOutput();
        if (amountOut >= reserveOut) revert IPolicast.InsufficientLiquidity();

        // Update reserves
        optionIn.reserve += _amountIn;
        optionOut.reserve -= amountOut;

        // Update user shares
        market.userShares[msg.sender][_optionIdIn] -= _amountIn;
        market.userShares[msg.sender][_optionIdOut] += amountOut;

        // Update prices based on new reserves
        optionIn.currentPrice = (optionIn.k * 1e18) / optionIn.reserve;
        optionOut.currentPrice = (optionOut.k * 1e18) / optionOut.reserve;

        // Record price history
        priceHistory[_marketId][_optionIdIn].push(IPolicast.PricePoint({
            price: optionIn.currentPrice,
            timestamp: block.timestamp,
            volume: _amountIn * optionIn.currentPrice / 1e18
        }));

        priceHistory[_marketId][_optionIdOut].push(IPolicast.PricePoint({
            price: optionOut.currentPrice,
            timestamp: block.timestamp,
            volume: amountOut * optionOut.currentPrice / 1e18
        }));

        emit IPolicast.AMMSwap(_marketId, _optionIdIn, _optionIdOut, _amountIn, amountOut, msg.sender);
        return amountOut;
    }

    function buyShares(
        uint256 _marketId,
        uint256 _optionId,
        uint256 _quantity,
        uint256 _maxPricePerShare
    ) external nonReentrant whenNotPaused validMarket(_marketId) marketActive(_marketId) validOption(_marketId, _optionId) {
        if (_quantity == 0) revert IPolicast.AmountMustBePositive();
        if (!markets[_marketId].validated) revert IPolicast.MarketNotValidated();

        IPolicast.Market storage market = markets[_marketId];
        IPolicast.MarketOption storage option = market.options[_optionId];

        uint256 currentPrice = calculateCurrentPrice(_marketId, _optionId);
        if (currentPrice > _maxPricePerShare) revert IPolicast.PriceTooHigh();

        uint256 totalCost = currentPrice * _quantity / 1e18;
        uint256 fee = totalCost * platformFeeRate / 10000;
        uint256 netCost = totalCost + fee;

        if (!bettingToken.transferFrom(msg.sender, address(this), netCost)) revert IPolicast.TransferFailed();

        // Update user shares
        if (market.userShares[msg.sender][_optionId] == 0 && _isNewParticipant(msg.sender, _marketId)) {
            market.participants.push(msg.sender);
            if (userPortfolios[msg.sender].totalInvested == 0) {
                allParticipants.push(msg.sender);
            }
        }

        market.userShares[msg.sender][_optionId] += _quantity;
        option.totalShares += _quantity;
        option.totalVolume += totalCost;
        market.userLiquidity += totalCost; // Only user funds go to user liquidity
        market.totalVolume += totalCost;
        market.platformFeesCollected += fee; // Track platform fees separately
        totalPlatformFeesCollected += fee;   // Global platform fees

        // Update user portfolio
        userPortfolios[msg.sender].totalInvested += netCost;
        userPortfolios[msg.sender].tradeCount++;

        // Update price based on demand
        option.currentPrice = calculateNewPrice(_marketId, _optionId, _quantity, true);

        // Record price history
        priceHistory[_marketId][_optionId].push(IPolicast.PricePoint({
            price: option.currentPrice,
            timestamp: block.timestamp,
            volume: totalCost
        }));

        // Record trade
        IPolicast.Trade memory trade = IPolicast.Trade({
            marketId: _marketId,
            optionId: _optionId,
            buyer: msg.sender,
            seller: address(0), // Market maker
            price: currentPrice,
            quantity: _quantity,
            timestamp: block.timestamp
        });

        userTradeHistory[msg.sender].push(trade);
        marketTrades[_marketId].push(trade);

        emit IPolicast.TradeExecuted(_marketId, _optionId, msg.sender, address(0), currentPrice, _quantity, tradeCount++);
        emit IPolicast.FeeCollected(_marketId, fee);
    }

    function sellShares(
        uint256 _marketId,
        uint256 _optionId,
        uint256 _quantity,
        uint256 _minPricePerShare
    ) external nonReentrant whenNotPaused validMarket(_marketId) marketActive(_marketId) validOption(_marketId, _optionId) {
        if (_quantity == 0) revert IPolicast.AmountMustBePositive();
        if (markets[_marketId].userShares[msg.sender][_optionId] < _quantity) revert IPolicast.InsufficientShares();

        IPolicast.Market storage market = markets[_marketId];
        IPolicast.MarketOption storage option = market.options[_optionId];

        uint256 currentPrice = calculateCurrentPrice(_marketId, _optionId);
        if (currentPrice < _minPricePerShare) revert IPolicast.PriceTooLow();

        uint256 totalRevenue = currentPrice * _quantity / 1e18;
        uint256 fee = totalRevenue * platformFeeRate / 10000;
        uint256 netRevenue = totalRevenue - fee;

        // Update shares
        market.userShares[msg.sender][_optionId] -= _quantity;
        option.totalShares -= _quantity;
        option.totalVolume += totalRevenue;
        market.totalVolume += totalRevenue;
        market.platformFeesCollected += fee; // Track platform fees separately
        totalPlatformFeesCollected += fee;   // Global platform fees

        // Update price based on supply
        option.currentPrice = calculateNewPrice(_marketId, _optionId, _quantity, false);

        // Calculate P&L: (sell price - avg cost basis) * quantity
        // For simplicity, we'll use current price as cost basis approximation
        int256 pnl = int256(netRevenue) - int256(currentPrice * _quantity / 1e18);
        userPortfolios[msg.sender].realizedPnL += pnl;
        userPortfolios[msg.sender].tradeCount++;

        // Record price history
        priceHistory[_marketId][_optionId].push(IPolicast.PricePoint({
            price: option.currentPrice,
            timestamp: block.timestamp,
            volume: totalRevenue
        }));

        // Record trade
        IPolicast.Trade memory trade = IPolicast.Trade({
            marketId: _marketId,
            optionId: _optionId,
            buyer: address(0), // Market maker
            seller: msg.sender,
            price: currentPrice,
            quantity: _quantity,
            timestamp: block.timestamp
        });

        userTradeHistory[msg.sender].push(trade);
        marketTrades[_marketId].push(trade);

        if (!bettingToken.transfer(msg.sender, netRevenue)) revert IPolicast.TransferFailed();

        emit IPolicast.SharesSold(_marketId, _optionId, msg.sender, _quantity, currentPrice);
        emit IPolicast.TradeExecuted(_marketId, _optionId, address(0), msg.sender, currentPrice, _quantity, tradeCount++);
        emit IPolicast.FeeCollected(_marketId, fee);
    }

    // Market Resolution
    function resolveMarket(uint256 _marketId, uint256 _winningOptionId) external validMarket(_marketId) {
        if (msg.sender != owner() && !hasRole(QUESTION_RESOLVE_ROLE, msg.sender)) revert IPolicast.NotAuthorized();
        IPolicast.Market storage market = markets[_marketId];
        if (block.timestamp < market.endTime) revert IPolicast.MarketNotEndedYet();
        if (market.resolved) revert IPolicast.MarketAlreadyResolved();
        if (_winningOptionId >= market.optionCount) revert IPolicast.InvalidWinningOption();

        market.winningOptionId = _winningOptionId;
        market.resolved = true;

        emit IPolicast.MarketResolved(_marketId, _winningOptionId, msg.sender);
    }

    function disputeMarket(uint256 _marketId, string memory _reason) external validMarket(_marketId) {
        if (!markets[_marketId].resolved) revert IPolicast.MarketNotResolved();
        if (markets[_marketId].disputed) revert IPolicast.AlreadyClaimed();
        if (markets[_marketId].userShares[msg.sender][markets[_marketId].winningOptionId] > 0) revert IPolicast.CannotDisputeIfWon();

        markets[_marketId].disputed = true;
        emit IPolicast.MarketDisputed(_marketId, msg.sender, _reason);
    }

    // Payout Functions
    function claimWinnings(uint256 _marketId) external nonReentrant validMarket(_marketId) {
        IPolicast.Market storage market = markets[_marketId];
        if (!market.resolved || market.disputed) revert IPolicast.MarketNotReady();
        if (market.hasClaimed[msg.sender]) revert IPolicast.AlreadyClaimed();

        uint256 userWinningShares = market.userShares[msg.sender][market.winningOptionId];
        if (userWinningShares == 0) revert IPolicast.NoWinningShares();

        uint256 totalWinningShares = market.options[market.winningOptionId].totalShares;
        // Only distribute user liquidity, not admin liquidity or platform fees
        uint256 totalLosingValue = market.userLiquidity - (totalWinningShares * market.options[market.winningOptionId].currentPrice / 1e18);
        
        uint256 winnings = (userWinningShares * market.options[market.winningOptionId].currentPrice / 1e18) + 
                          (userWinningShares * totalLosingValue / totalWinningShares);

        market.hasClaimed[msg.sender] = true;
        userPortfolios[msg.sender].totalWinnings += winnings;
        totalWinnings[msg.sender] += winnings;

        if (!bettingToken.transfer(msg.sender, winnings)) revert IPolicast.TransferFailed();
        emit IPolicast.Claimed(_marketId, msg.sender, winnings);
    }

    // NEW: Claim sponsored market ETH prizes
    function claimSponsoredPrize(uint256 _marketId) external nonReentrant validMarket(_marketId) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.SPONSORED) revert IPolicast.NotSponsoredMarket();
        if (!market.resolved || market.disputed) revert IPolicast.MarketNotReady();
        if (market.hasClaimedSponsored[msg.sender]) revert IPolicast.AlreadyClaimed();
        if (market.sponsorConfig.prizeDistributed) revert IPolicast.SponsoredPrizeAlreadyDistributed();

        uint256 userWinningShares = market.userShares[msg.sender][market.winningOptionId];
        if (userWinningShares == 0) revert IPolicast.NoWinningShares();

        // Check if minimum participants threshold was met
        if (market.participants.length < market.sponsorConfig.minimumParticipants) revert IPolicast.InsufficientParticipants();

        uint256 totalWinningShares = market.options[market.winningOptionId].totalShares;
        if (totalWinningShares == 0) revert IPolicast.NoSponsoredPrize();

        // Calculate user's share of the ETH prize pool
        uint256 ethPrize = (userWinningShares * market.sponsorConfig.sponsorPrize) / totalWinningShares;
        
        market.hasClaimedSponsored[msg.sender] = true;
        
        // Transfer ETH prize to winner
        (bool success, ) = payable(msg.sender).call{value: ethPrize}("");
        if (!success) revert IPolicast.TransferFailed();

        emit IPolicast.SponsoredPrizeClaimed(_marketId, msg.sender, ethPrize);
    }

    // NEW: Refund sponsor if minimum participants not met
    function refundSponsor(uint256 _marketId) external nonReentrant validMarket(_marketId) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.SPONSORED) revert IPolicast.NotSponsoredMarket();
        if (!market.resolved) revert IPolicast.MarketNotResolved();
        if (market.sponsorConfig.prizeDistributed) revert IPolicast.SponsoredPrizeAlreadyDistributed();
        if (msg.sender != market.sponsorConfig.sponsor) revert IPolicast.NotAuthorized();

        // Only refund if minimum participants not met
        if (market.participants.length >= market.sponsorConfig.minimumParticipants) revert IPolicast.InsufficientParticipants();

        uint256 refundAmount = market.sponsorConfig.sponsorPrize;
        market.sponsorConfig.prizeDistributed = true; // Mark as handled
        
        // Refund ETH to sponsor
        (bool success, ) = payable(market.sponsorConfig.sponsor).call{value: refundAmount}("");
        if (!success) revert IPolicast.TransferFailed();

        emit IPolicast.SponsoredPrizeRefunded(_marketId, market.sponsorConfig.sponsor, refundAmount);
    }

    // Price Calculation Functions
    function calculateCurrentPrice(uint256 _marketId, uint256 _optionId) public view returns (uint256) {
        IPolicast.Market storage market = markets[_marketId];
        return market.options[_optionId].currentPrice;
    }

    function calculateNewPrice(uint256 _marketId, uint256 _optionId, uint256 _quantity, bool _isBuy) internal view returns (uint256) {
        IPolicast.Market storage market = markets[_marketId];
        IPolicast.MarketOption storage option = market.options[_optionId];
        
        // Use AMM pricing model based on reserves
        uint256 reserve = option.reserve;
        uint256 k = option.k;
        
        if (_isBuy) {
            // FIXED: When buying, reserve decreases (liquidity consumed) → price increases
            uint256 newReserve = reserve > _quantity ? reserve - _quantity : reserve / 2;
            return (k * 1e18) / newReserve;
        } else {
            // When selling, reserve increases (liquidity added) → price decreases
            uint256 newReserve = reserve + _quantity;
            return (k * 1e18) / newReserve;
        }
    }

    // Add AMM Liquidity
    function addAMMLiquidity(uint256 _marketId, uint256 _amount) external nonReentrant validMarket(_marketId) {
        if (_amount == 0) revert IPolicast.AmountMustBePositive();
        if (!bettingToken.transferFrom(msg.sender, address(this), _amount)) revert IPolicast.TransferFailed();
        
        IPolicast.Market storage market = markets[_marketId];
        market.ammLiquidityPool += _amount;
        
        // Track LP contribution
        if (market.lpContributions[msg.sender] == 0) {
            market.liquidityProviders.push(msg.sender);
        }
        market.lpContributions[msg.sender] += _amount;
        
        // Distribute liquidity across options proportionally
        uint256 amountPerOption = _amount / market.optionCount;
        for (uint256 i = 0; i < market.optionCount; i++) {
            market.options[i].k += amountPerOption;
            market.options[i].reserve += amountPerOption;
        }
        
        emit IPolicast.LiquidityAdded(_marketId, msg.sender, _amount);
    }

    function calculateSellPrice(uint256 _marketId, uint256 _optionId, uint256 _quantity) public view returns (uint256) {
        IPolicast.Market storage market = markets[_marketId];
        IPolicast.MarketOption storage option = market.options[_optionId];
        
        // Calculate sell price using AMM formula with 0.3% fee
        uint256 newReserve = option.reserve > _quantity ? option.reserve - _quantity : option.reserve / 2;
        uint256 newPrice = (option.k * 1e18) / newReserve;
        uint256 sellPrice = newPrice * _quantity / 1e18;
        
        // Apply 0.3% fee
        return sellPrice * 997 / 1000;
    }

    // Get current market odds for all options
    function getMarketOdds(uint256 _marketId) external view validMarket(_marketId) returns (uint256[] memory) {
        IPolicast.Market storage market = markets[_marketId];
        uint256[] memory odds = new uint256[](market.optionCount);
        
        uint256 totalLiquidity = 0;
        for (uint256 i = 0; i < market.optionCount; i++) {
            totalLiquidity += market.options[i].k;
        }
        
        for (uint256 i = 0; i < market.optionCount; i++) {
            odds[i] = (market.options[i].k * 1e18) / totalLiquidity;
        }
        
        return odds;
    }

    // Emergency functions
    function pauseMarket(uint256 _marketId) external onlyOwner validMarket(_marketId) {
        markets[_marketId].resolved = true;
        emit IPolicast.MarketPaused(_marketId);
    }

    function updateBettingTokenAddress(address _newToken) external onlyOwner {
        if (_newToken == address(0)) revert IPolicast.InvalidToken();
        previousBettingToken = address(bettingToken);
        bettingToken = IERC20(_newToken);
        tokenUpdatedAt = block.timestamp;
        
        emit IPolicast.BettingTokenUpdated(previousBettingToken, _newToken, block.timestamp);
    }

    // NEW: Platform Fee Management
    function withdrawPlatformFees() external nonReentrant {
        if (msg.sender != feeCollector && msg.sender != owner()) revert IPolicast.NotAuthorized();
        if (totalPlatformFeesCollected == 0) revert IPolicast.NoFeesToWithdraw();
        
        uint256 feesToWithdraw = totalPlatformFeesCollected;
        totalPlatformFeesCollected = 0;
        
        if (!bettingToken.transfer(feeCollector, feesToWithdraw)) revert IPolicast.TransferFailed();
        emit IPolicast.PlatformFeesWithdrawn(feeCollector, feesToWithdraw);
    }

    // NEW: Admin Liquidity Recovery
    function withdrawAdminLiquidity(uint256 _marketId) external nonReentrant validMarket(_marketId) {
        IPolicast.Market storage market = markets[_marketId];
        if (msg.sender != market.creator) revert IPolicast.NotAuthorized();
        if (!market.resolved) revert IPolicast.MarketNotResolved();
        if (market.adminLiquidityClaimed) revert IPolicast.AdminLiquidityAlreadyClaimed();
        if (market.adminInitialLiquidity == 0) revert IPolicast.AmountMustBePositive();
        
        uint256 liquidityToReturn = market.adminInitialLiquidity;
        market.adminLiquidityClaimed = true;
        
        if (!bettingToken.transfer(market.creator, liquidityToReturn)) revert IPolicast.TransferFailed();
        emit IPolicast.AdminLiquidityWithdrawn(_marketId, market.creator, liquidityToReturn);
    }

    // NEW: Withdraw unused prize pool from free markets
    function withdrawUnusedPrizePool(uint256 _marketId) external nonReentrant validMarket(_marketId) {
       IPolicast. Market storage market = markets[_marketId];
        if (msg.sender != market.creator) revert IPolicast.NotAuthorized();
        if (market.marketType != IPolicast.MarketType.FREE_ENTRY) revert IPolicast.NotFreeMarket();
        if (!market.resolved) revert IPolicast.MarketNotResolved();
        if (market.freeConfig.remainingPrizePool == 0) revert IPolicast.AmountMustBePositive();
        
        uint256 unusedTokens = market.freeConfig.remainingPrizePool;
        market.freeConfig.remainingPrizePool = 0;
        
        if (!bettingToken.transfer(market.creator, unusedTokens)) revert IPolicast.TransferFailed();
        emit IPolicast.AdminLiquidityWithdrawn(_marketId, market.creator, unusedTokens); // Reuse event
    }

    // NEW: LP Rewards Claiming
    function claimLPRewards(uint256 _marketId) external nonReentrant validMarket(_marketId) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.lpContributions[msg.sender] == 0) revert IPolicast.NotLiquidityProvider();
        if (market.lpRewardsClaimed[msg.sender]) revert IPolicast.AlreadyClaimed();
        if (market.ammFeesCollected == 0) revert IPolicast.NoLPRewards();
        
        // Calculate LP's share of AMM fees based on their contribution
        uint256 totalLPContributions = market.ammLiquidityPool;
        uint256 lpShare = (market.lpContributions[msg.sender] * market.ammFeesCollected) / totalLPContributions;
        
        if (lpShare == 0) revert IPolicast.NoLPRewards();
        
        market.lpRewardsClaimed[msg.sender] = true;
        lpRewardsEarned[msg.sender] += lpShare;
        
        if (!bettingToken.transfer(msg.sender, lpShare)) revert IPolicast.TransferFailed();
        emit IPolicast.LPRewardsClaimed(_marketId, msg.sender, lpShare);
    }

    // Helper Functions
    function _isNewParticipant(address _user, uint256 _marketId) internal view returns (bool) {
        IPolicast.Market storage market = markets[_marketId];
        for (uint256 i = 0; i < market.optionCount; i++) {
            if (market.userShares[_user][i] > 0) {
                return false;
            }
        }
        return true;
    }

    // View Functions
    function getMarketInfo(uint256 _marketId) external view validMarket(_marketId) returns (
        string memory question,
        string memory description,
        uint256 endTime,
        IPolicast.MarketCategory category,
        uint256 optionCount,
        bool resolved,
        bool disputed,
        uint256 winningOptionId,
        address creator
    ) {
        IPolicast.Market storage market = markets[_marketId];
        return (
            market.question,
            market.description,
            market.endTime,
            market.category,
            market.optionCount,
            market.resolved,
            market.disputed,
            market.winningOptionId,
            market.creator
        );
    }

    function getMarketOption(uint256 _marketId, uint256 _optionId) external view validMarket(_marketId) returns (
        string memory name,
        string memory description,
        uint256 totalShares,
        uint256 totalVolume,
        uint256 currentPrice,
        bool isActive
    ) {
       IPolicast.MarketOption storage option = markets[_marketId].options[_optionId];
        return (
            option.name,
            option.description,
            option.totalShares,
            option.totalVolume,
            option.currentPrice,
            option.isActive
        );
    }

    function getUserShares(uint256 _marketId, address _user) external view validMarket(_marketId) returns (uint256[] memory) {
        IPolicast.Market storage market = markets[_marketId];
        uint256[] memory shares = new uint256[](market.optionCount);
        for (uint256 i = 0; i < market.optionCount; i++) {
            shares[i] = market.userShares[_user][i];
        }
        return shares;
    }

    function getUserPortfolio(address _user) external view returns (IPolicast.UserPortfolio memory) {
        return userPortfolios[_user];
    }

    function getPriceHistory(uint256 _marketId, uint256 _optionId, uint256 _limit) external view returns (IPolicast.PricePoint[] memory) {
        IPolicast.PricePoint[] storage history = priceHistory[_marketId][_optionId];
        uint256 length = history.length;
        uint256 returnLength = _limit > length ? length : _limit;
        
        IPolicast.PricePoint[] memory result = new IPolicast.PricePoint[](returnLength);
        uint256 startIndex = length > _limit ? length - _limit : 0;
        
        for (uint256 i = 0; i < returnLength; i++) {
            result[i] = history[startIndex + i];
        }
        
        return result;
    }

    function getMarketsByCategory(IPolicast.MarketCategory _category, uint256 _limit) external view returns (uint256[] memory) {
        uint256[] storage categoryMarketIds = categoryMarkets[_category];
        uint256 length = categoryMarketIds.length;
        uint256 returnLength = _limit > length ? length : _limit;
        
        uint256[] memory result = new uint256[](returnLength);
        uint256 startIndex = length > _limit ? length - _limit : 0;
        
        for (uint256 i = 0; i < returnLength; i++) {
            result[i] = categoryMarketIds[startIndex + i];
        }
        
        return result;
    }

    function getMarketCount() external view returns (uint256) {
        return marketCount;
    }

    function getBettingToken() external view returns (address) {
        return address(bettingToken);
    }

    // NEW: Get market financial breakdown
    function getMarketFinancials(uint256 _marketId) external view validMarket(_marketId) returns (
        uint256 adminInitialLiquidity,
        uint256 userLiquidity,
        uint256 platformFeesCollected,
        uint256 ammFeesCollected,
        bool adminLiquidityClaimed
    ) {
        IPolicast.Market storage market = markets[_marketId];
        return (
            market.adminInitialLiquidity,
            market.userLiquidity,
            market.platformFeesCollected,
            market.ammFeesCollected,
            market.adminLiquidityClaimed
        );
    }

    // NEW: Get LP information for a market
    function getLPInfo(uint256 _marketId, address _lp) external view validMarket(_marketId) returns (
        uint256 contribution,
        bool rewardsClaimed,
        uint256 estimatedRewards
    ) {
        IPolicast.Market storage market = markets[_marketId];
        uint256 contribution = market.lpContributions[_lp];
        bool rewardsClaimed = market.lpRewardsClaimed[_lp];
        
        uint256 estimatedRewards = 0;
        if (contribution > 0 && market.ammLiquidityPool > 0) {
            estimatedRewards = (contribution * market.ammFeesCollected) / market.ammLiquidityPool;
        }
        
        return (contribution, rewardsClaimed, estimatedRewards);
    }

    // NEW: Get global platform statistics
    function getPlatformStats() external view returns (
        uint256 totalFeesCollected,
        address currentFeeCollector,
        uint256 totalMarkets,
        uint256 totalTrades
    ) {
        return (
            totalPlatformFeesCollected,
            feeCollector,
            marketCount,
            tradeCount
        );
    }

    // NEW: Get free market configuration
    function getFreeMarketInfo(uint256 _marketId) external view validMarket(_marketId) returns (
        uint256 maxFreeParticipants,
        uint256 tokensPerParticipant,
        uint256 currentFreeParticipants,
        uint256 totalPrizePool,
        uint256 remainingPrizePool,
        bool isActive
    ) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.FREE_ENTRY) revert IPolicast.NotFreeMarket();
        
        return (
            market.freeConfig.maxFreeParticipants,
            market.freeConfig.tokensPerParticipant,
            market.freeConfig.currentFreeParticipants,
            market.freeConfig.totalPrizePool,
            market.freeConfig.remainingPrizePool,
            market.freeConfig.isActive
        );
    }

    // NEW: Check if user claimed free tokens
    function hasUserClaimedFreeTokens(uint256 _marketId, address _user) external view validMarket(_marketId) returns (bool, uint256) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.FREE_ENTRY) revert IPolicast.NotFreeMarket();
        
        return (
            market.freeConfig.hasClaimedFree[_user],
            market.freeConfig.tokensReceived[_user]
        );
    }

    // NEW: Get sponsored market configuration
    function getSponsoredMarketInfo(uint256 _marketId) external view validMarket(_marketId) returns (
        address sponsor,
        uint256 sponsorPrize,
        uint256 minimumParticipants,
        uint256 currentParticipants,
        bool prizeDistributed,
        string memory sponsorMessage
    ) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.SPONSORED) revert IPolicast.NotSponsoredMarket();
        
        return (
            market.sponsorConfig.sponsor,
            market.sponsorConfig.sponsorPrize,
            market.sponsorConfig.minimumParticipants,
            market.participants.length,
            market.sponsorConfig.prizeDistributed,
            market.sponsorConfig.sponsorMessage
        );
    }

    // NEW: Check if user claimed sponsored prize
    function hasUserClaimedSponsoredPrize(uint256 _marketId, address _user) external view validMarket(_marketId) returns (bool) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.SPONSORED) revert IPolicast.NotSponsoredMarket();
        
        return market.hasClaimedSponsored[_user];
    }

    // NEW: Calculate user's potential sponsored prize
    function calculateSponsoredPrize(uint256 _marketId, address _user) external view validMarket(_marketId) returns (uint256) {
        IPolicast.Market storage market = markets[_marketId];
        if (market.marketType != IPolicast.MarketType.SPONSORED) revert IPolicast.NotSponsoredMarket();
        if (!market.resolved) return 0;
        
        uint256 userWinningShares = market.userShares[_user][market.winningOptionId];
        if (userWinningShares == 0) return 0;
        
        uint256 totalWinningShares = market.options[market.winningOptionId].totalShares;
        if (totalWinningShares == 0) return 0;
        
        // Check if minimum participants threshold was met
        if (market.participants.length < market.sponsorConfig.minimumParticipants) return 0;
        
        return (userWinningShares * market.sponsorConfig.sponsorPrize) / totalWinningShares;
    }
}