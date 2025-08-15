# Farcaster Onchain Actions

This project implements a fully onchain execution layer for **Investre Bot** actions such as token transfers, trading, giveaways, raffles, and wallet management.  
Every user-facing action maps to a dedicated smart contract, ensuring transparency, trustlessness, and verifiability.

---

## 📜 Contract Architecture

### 1. Core Infrastructure
These contracts handle authentication, custody of funds, and base execution.

| Contract              | Purpose |
|-----------------------|---------|
| **WalletManager.sol** | Creates, imports, and manages user wallets onchain. Links Farcaster IDs to addresses. |
| **UserVault.sol**     | Per-user vault for custody of tokens and ETH. Supports deposits, withdrawals, and approvals. | 0xa3aE01BE8b0Ec12a8FB4c72eF2f57A137e0fD000
| **ActionExecutor.sol**| Central contract that executes whitelisted actions by delegating to modules. |
| **PermitManager.sol** | Manages EIP-712 signature-based permissions for secure bot-triggered actions without private key exposure. |
| **FarcasterRegistry.sol** | Maps Farcaster IDs ↔ Ethereum addresses ↔ UserVaults. |

---

### 2. Trading & Portfolio Management
Modules for token swaps, limit orders, and portfolio tracking.

| Contract               | Purpose |
|------------------------|---------|
| **TokenTrade.sol**     | Executes token swaps via integrated DEX routers with slippage control. |
| **SwapModule.sol**     | Uses Uniswap/0x/OpenOcean for buy/sell orders from vaults. |
| **LimitOrderModule.sol**| Stores user-defined limit orders and executes them on price triggers. |
| **TPSLModule.sol**     | Handles take-profit / stop-loss automation. |
| **PortfolioViewer.sol**| Read-only balance and position aggregator for vaults. |

---

### 3. P2P & Social Transfers
For direct or bulk transfers between users.

| Contract           | Purpose |
|--------------------|---------|
| **TokenTransfer.sol** | Sends ERC20 or ETH to single/multiple recipients. |
| **TokenSender.sol**   | Simple transfer from one vault to another or by Farcaster ID. |
| **BatchSender.sol**   | Bulk distribution to many recipients in a single transaction. |

---

### 4. Giveaways, Raffles & Raindrops
Onchain gamified distribution systems.

| Contract               | Purpose |
|------------------------|---------|
| **GiveawayManager.sol**| Creates token giveaways with rules, deadlines, and participant storage. |
| **RaffleManager.sol**  | Runs raffles with VRF-based provable fairness. |
| **RaindropModule.sol** | Instant distribution of tokens to all eligible users. |
| **InteractionTracker.sol** | (Optional) Tracks onchain proof of likes/recasts/replies for eligibility verification. |
| **CastReward.sol**     | Attaches token rewards to Farcaster casts and allows claims based on engagement. |

---

### 5. Automation & Scheduling
For future or recurring actions.

| Contract                 | Purpose |
|--------------------------|---------|
| **Scheduler.sol**        | Stores actions (buy, sell, send, giveaway) for future execution. |
| **AutomationExecutor.sol** | Works with Gelato/Chainlink Automation to execute scheduled actions. |

---

### 6. Governance & Configuration
Upgradable, configurable protocol controls.

| Contract             | Purpose |
|----------------------|---------|
| **BotController.sol**| Governance-controlled contract for upgrading modules and adjusting system parameters. |
| **FeeManager.sol**   | Handles protocol fees (flat %, gas reimbursements). |
| **ModuleRegistry.sol** | Registers and manages active action modules. |

---

### 7. Utility Contracts
Supporting modules for data feeds, randomness, and proofs.

| Contract                  | Purpose |
|---------------------------|---------|
| **OracleManager.sol**     | Aggregates prices from Chainlink, Uniswap TWAP, etc. |
| **RandomnessProvider.sol**| Supplies VRF randomness for raffles/giveaways. |
| **FarcasterProofVerifier.sol** | (Optional) Verifies onchain proofs linking Ethereum addresses to Farcaster IDs. |

---

## 📌 Example: Intent → Contract Mapping

| Intent                 | Contract(s) Used |
|------------------------|------------------|
| `buy_token` / `sell_token` | TokenTrade.sol / SwapModule.sol + UserVault.sol |
| `check_balance` / `analyze_portfolio` | PortfolioViewer.sol |
| `set_limit_order` / `set_tp_sl` | LimitOrderModule.sol + TPSLModule.sol |
| `send_token`           | TokenSender.sol / TokenTransfer.sol |
| `create_giveaway`      | GiveawayManager.sol + InteractionTracker.sol |
| `raindrop`             | RaindropModule.sol + BatchSender.sol |
| `auto_buy_setup`       | AutomationExecutor.sol + Scheduler.sol |
| `list_trending_tokens` | Offchain fetch + optional OracleManager.sol |

---

## 🛠 Foundry Setup

**Foundry** is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.

**Components:**
- **Forge** — Ethereum testing framework.
- **Cast** — Swiss army knife for interacting with contracts.
- **Anvil** — Local Ethereum node.
- **Chisel** — Solidity REPL.

**Docs:** https://book.getfoundry.sh/

---

### Build
```sh
forge build


Test
forge test

Format
forge fmt

Gas Snapshot
forge snapshot

Local Node
anvil

Deploy
forge script script/DeployAll.s.sol:DeployAll --rpc-url <your_rpc_url> --private-key <your_private_key>

Cast Commands
cast <subcommand>

Help
forge --help
anvil --help
cast --help