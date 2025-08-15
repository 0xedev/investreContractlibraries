# Farcaster Onchain Actions

This project implements a fully onchain execution layer for investre bot actions such as token transfers, trading, giveaways, raffles, and wallet management.  
Every user-facing action maps to a dedicated smart contract, ensuring transparency, trustlessness, and verifiability.

## Contract List & Functions

### 1. **WalletManager.sol**
- **Purpose:** Create, import, and manage user wallets onchain.
- **Functions:**
  - `createWallet(address owner)`
  - `importWallet(bytes privateKeyEncrypted)`
  - `exportWallet(address owner)` (returns encrypted data)
  - `linkFarcasterId(uint256 fid, address wallet)`

---

### 2. **TokenTransfer.sol**
- **Purpose:** Send ERC20 tokens or native ETH to multiple recipients.
- **Functions:**
  - `sendToken(address token, address to, uint256 amount)`
  - `bulkSendToken(address token, address[] recipients, uint256[] amounts)`
  - `sendETH(address to, uint256 amount)`
  - `bulkSendETH(address[] recipients, uint256[] amounts)`

---

### 3. **TokenTrade.sol**
- **Purpose:** Swap tokens onchain via integrated DEX routers.
- **Functions:**
  - `buyToken(address tokenIn, address tokenOut, uint256 amountIn)`
  - `sellToken(address tokenIn, address tokenOut, uint256 amountIn)`
  - Supports slippage control & DEX routing.

---

### 4. **Leaderboard.sol**
- **Purpose:** Track trading, giveaway, and engagement rankings.
- **Functions:**
  - `updateScore(address user, uint256 points)`
  - `getTopUsers(uint256 limit)`
  - `getUserScore(address user)`
  - Points can be earned via verified onchain actions.

---

### 5. **GiveawayManager.sol**
- **Purpose:** Create and manage token giveaways.
- **Functions:**
  - `createGiveaway(address token, uint256 amount, uint256 deadline, uint256 maxWinners)`
  - `enterGiveaway(uint256 giveawayId)`
  - `pickWinners(uint256 giveawayId)`
  - `claimPrize(uint256 giveawayId)`

---

### 6. **RaffleManager.sol**
- **Purpose:** Host token raffles with provable fairness.
- **Functions:**
  - `createRaffle(address token, uint256 ticketPrice, uint256 endTime)`
  - `buyTicket(uint256 raffleId)`
  - `drawWinner(uint256 raffleId)` (VRF integration)
  - `claimRafflePrize(uint256 raffleId)`

---

### 7. **CastReward.sol**
- **Purpose:** Attach token rewards to Farcaster casts.
- **Functions:**
  - `fundCastReward(uint256 castId, address token, uint256 amount)`
  - `claimCastReward(uint256 castId, address user)`
  - Supports like/recast-based eligibility.

---

### 8. **Treasury.sol**
- **Purpose:** Manage project-owned funds and approve payouts.
- **Functions:**
  - `deposit(address token, uint256 amount)`
  - `withdraw(address token, uint256 amount, address to)`
  - `approveSpender(address spender, uint256 amount)`

---

### 9. **FarcasterRegistry.sol**
- **Purpose:** Link Farcaster IDs to onchain wallets for action routing.
- **Functions:**
  - `registerFid(uint256 fid, address wallet)`
  - `getWallet(uint256 fid)`
  - `isRegistered(uint256 fid)`

---

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build
```sh
forge build

forge test
