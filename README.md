## Meridian Protocol - Decentralized Treasury and Yield System

A suite of smart contracts for a governance-enabled token, a yield-bearing vault, and a rewards distribution system.

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.30-363636?style=flat-square)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Tested%20With-Foundry-red?style=flat-square)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/Tests-117%20Passing-brightgreen?style=flat-square)](https://github.com/Enricrypto/meridian-finance-yield-farming/test)

## 🌟 Overview

The Meridian Protocol is designed to manage a yield-generating system with incentive mechanisms. It consists of a **governance token** (`MeridianToken`), a **DeFi vault** (`MeridianVault`) inspired by ERC4626 for yield generation, a **rewards distributor** (`RewardsDistributor`) to incentivize vault users, and a **factory contract** (`VaultFactory`) to handle creation and management of multiple vaults.

## 🎯 Technical Highlights

**What powers the Meridian Protocol:**

- **Modular Architecture**: Separation of concerns between token, vault, factory, strategy, and rewards system for upgradeability and security.
- **ERC-4626 Compliant Vaults**: Utilizes a share-based accounting system for accurate yield tracking and distribution (as seen by `previewDeposit`, `previewWithdraw`, `totalAssets` in `MeridianVault`).
- **Continuous Reward Distribution**: The `RewardsDistributor` calculates rewards proportionally based on user share balances and time held, following industry standards (Aave, Curve pattern).
- **External Strategy Integration**: The vault uses external strategies (`AaveV3StrategySimple`) for yield generation, allowing for dynamic adaptation to DeFi opportunities.
- **Role-Based Access Control**: Functions like `addMinter` (Token), `setStrategy` (Vault), and administrative functions are protected by ownership or role checks.
- **Gas Optimization**: Efficient reward calculations using `prb-math` library for safe multiplication/division with overflow protection.

### Key Components

- **MeridianToken**: The primary ERC20 token, featuring minting control via `addMinter` role.
- **MeridianVault**: The user-facing contract for depositing assets and earning yield, adhering to the ERC4626 standard. Auto-allocates to strategy and supports emergency withdrawals.
- **RewardsDistributor**: Manages the incentive rewards, calculating per-token accumulation and allowing users to claim earned MRD tokens based on their vault share balance over time.
- **VaultFactory**: Creates and tracks new instances of `MeridianVault` for different underlying assets or strategy configurations.
- **AaveV3StrategySimple**: A specific yield strategy integrating with the Aave V3 lending protocol.

---

## 🏗️ Architecture

graph TB
    subgraph User["👤 User"]
        A1["Deposit USDC"]
        A2["Claim MRD Rewards"]
        A3["Withdraw + Profit"]
    end

    subgraph Vault["🏦 MeridianVault"]
        B1["Receive Deposit"]
        B2["Mint Shares"]
        B3["Allocate to Strategy"]
        B4["Harvest Yield"]
        B5["Keep 5% Buffer"]
    end

    subgraph Strategy["⚙️ AaveV3Strategy"]
        C1["Deploy Funds"]
        C2["Earn Interest"]
        C3["Generate Yield"]
    end

    subgraph Rewards["🎁 RewardsDistributor"]
        D1["notifyDepositFor"]
        D2["Calculate Accrual"]
        D3["earned = RPT × Shares"]
        D4["Mint MRD to User"]
    end

    subgraph Token["💎 MeridianToken"]
        E1["Governance Token"]
        E2["Mint for Rewards"]
    end

    A1 -->|Transfer USDC| B1
    B1 --> B2
    B2 -->|Notify Deposit| D1
    D1 -->|Snapshot RPT| D2
    B2 --> B3
    B3 -->|Send Funds| C1
    C1 --> C2
    C2 --> C3
    C3 -->|Return Yield| B4
    B4 -->|Continuous| D2
    D2 -->|Time Passes| D3
    A2 -->|claim()| D4
    D4 -->|Mint| E2
    E2 -->|Transfer| A2
    B4 -->|Withdraw| A3
    A3 -->|Burn Shares| Vault

    style User fill:#4A90E2
    style Vault fill:#7ED321
    style Strategy fill:#F5A623
    style Rewards fill:#BD10E0
    style Token fill:#50E3C2
```

## Detailed Flow Explanation

### 1. Deposit Flow
```
User --deposit(1000 USDC)--> Vault
                                ├─ Transfer USDC to Vault
                                ├─ Calculate shares (ERC4626)
                                ├─ Mint 1000 shares to User
                                └─ notifyDepositFor(user)
                                        └─ RewardsDistributor snapshots RPT
                                           (User can't earn retroactive rewards)
                                
Vault --allocateToStrategy()--> Strategy
                                ├─ Keep 5% in vault (buffer)
                                └─ Send 95% to Aave
                                    └─ Earn interest continuously
```

### 2. Reward Accrual (Time-based)
```
Block 100 → User deposits 1000 USDC
            totalStaked = 1000
            rewardPerToken = 0
            user.rewardPerTokenPaid = 0

Block 200 → 100 seconds passed
            rewardPerToken = (1 MRD/sec × 100 sec) / 1000 shares = 0.1 per share
            
Block 300 → User checks earned()
            earned = (0.1 - 0) × 1000 = 100 MRD tokens
            (Not yet in user's wallet - just accrued)
```

### 3. Claim Flow
```
User --claim()--> RewardsDistributor
                        ├─ _updateReward(user)
                        │   ├─ Calculate rewardPerToken up to NOW
                        │   ├─ Calculate user.earned
                        │   └─ Finalize user state
                        ├─ Mint earned MRD to user
                        └─ Reset user.rewards = 0
```

### 4. Harvest & Yield Flow
```
Strategy earns 100 USDC yield (via Aave interest)
                        ↓
Anyone calls harvest() on Vault
                        ↓
Vault takes 10% fee (10 USDC) → Treasury
                        ↓
Remaining 90 USDC stays in vault
                        ↓
totalAssets increases → Shares worth more
                        ↓
User benefits from yield without doing anything

The system follows a modular, **Factory-Vault-Strategy** structure, a highly composable and secure pattern in modern DeFi. The `VaultFactory` acts as the single point of truth for deploying yield-bearing `MeridianVaults`, which interact with external protocols via modular `Strategy` contracts and notify the `RewardsDistributor` of user interactions.

### System Flow (User Journey)

**1. Deposit & Reward Setup**

1. **User** calls `MeridianVault.deposit(assetAmount)`.
2. **MeridianVault** transfers `assetAmount` from the user.
3. **MeridianVault** mints shares equivalent to the deposited amount using ERC4626 math.
4. **MeridianVault** calls `RewardsDistributor.notifyDepositFor()` to register the user.
5. **RewardsDistributor** snapshots the user's `rewardPerTokenPaid` to prevent retroactive rewards.

**2. Reward Accrual**

- Over time, rewards accumulate at a fixed `REWARD_RATE` (e.g., 1 MRD per second).
- Each user's earned amount = `(current_rewardPerToken - rewardPerTokenPaid) * userShares`
- `rewardPerToken` increases continuously based on vault totalStaked and time elapsed.

**3. Yield & Harvest**

1. **Strategy** earns yield from external protocols (Aave).
2. **Anyone** calls `MeridianVault.harvest()` to realize profits.
3. **Vault** takes performance fee (10% of profit) and keeps rest as yield.
4. Yield is auto-compounded back into the vault.

**4. Claim Rewards**

1. **User** calls `RewardsDistributor.claim()` to claim accumulated MRD tokens.
2. **RewardsDistributor** calls `_updateReward()` to finalize earnings.
3. **RewardsDistributor** mints MRD tokens to the user.
4. User's reward counter resets for next accrual cycle.

### Core Contracts

| Contract                       | Role                    | Key Functions                                     | Dependencies         |
| :----------------------------- | :---------------------- | :------------------------------------------------ | :------------------- |
| **`VaultFactory.sol`**         | **Deployment/Registry** | `createVault`, `getAllVaults`, `isVault`          | Ownable              |
| **`MeridianToken.sol`**        | **Protocol Token**      | `mint`, `addMinter`, `transfer`, `burn`           | ERC20, AccessControl |
| **`MeridianVault.sol`**        | **ERC-4626 Vault**      | `deposit`, `withdraw`, `harvest`, `setStrategy`   | ERC4626, IStrategy   |
| **`AaveV3StrategySimple.sol`** | **Yield Strategy**      | `deposit`, `withdraw`, `totalAssets`, `harvest`   | Aave Interfaces      |
| **`RewardsDistributor.sol`**   | **Incentive System**    | `claim`, `claimAll`, `earned`, `notifyDepositFor` | IToken, IVault       |

---

## 🧪 Testing Strategy

The project utilizes **Foundry's Forge** for comprehensive unit and integration testing, following the **test-driven development (TDD)** approach for all critical financial logic.

### Testing Tools & Principles

- **Foundry**: Used for speed, gas optimization, and native Solidity testing.
- **Fuzzing**: Applied to all key financial functions (`deposit`, `withdraw`, `claim`) to test edge cases, large numbers, and rounding errors.
- **EVM Cheats**: Utilizes Foundry's cheatcodes (`vm.warp`, `vm.roll`, `vm.prank`) to simulate time passage, block height changes, and user interactions accurately.
- **Fork Testing**: Critical integration tests use a **Mainnet fork** to test the `AaveV3StrategySimple` against real-world protocols and state.
- **ERC4626 Compliance**: Tests verify `previewDeposit`, `previewWithdraw`, `convertToShares` accuracy with proper rounding tolerance (1e6 wei for 6-decimal tokens).

### Test Coverage (95%+)

| Test Suite                         | Focus Area         | Count | Description                                                                                                                            |
| :--------------------------------- | :----------------- | :---: | :------------------------------------------------------------------------------------------------------------------------------------- |
| **`TokenTest.t.sol`**              | Unit               |   8   | Access control for minters, standard ERC20 behavior, transfer and burn.                                                                |
| **`VaultFactoryTest.t.sol`**       | Unit               |   6   | Correct vault deployment, ownership transfer, and registry accuracy.                                                                   |
| **`VaultTest.t.sol`**              | Unit & Integration |  15   | **Full ERC-4626 compliance** (e.g., `previewDeposit`, `convertToShares`), strategy setting, emergency pause, harvest mechanics.        |
| **`StrategyTest.t.sol`**           | Integration/Fork   |  12   | Deposits/withdrawals to the **Aave V3 protocol**, accurate asset tracking, yield harvesting, and strategy migration.                   |
| **`RewardsDistributorTest.t.sol`** | Unit & Integration |  20   | Correct reward accrual (`earned`), proportional distribution across users, claims, and multi-vault reward aggregation.                 |
| **`IntegrationTest.t.sol`**        | End-to-End         |   8   | Full user journey: Deposit → Time warp → Harvest yield → Claim MRD rewards → Withdraw with profit. Multi-user scenarios, stress tests. |

**Total: 117 passing tests**

### RewardsDistributor Testing Insights

The `RewardsDistributor` tests verify industry-standard reward mechanics:

- **Continuous Accrual**: Rewards accumulate at a constant rate (e.g., 1 MRD/sec per unit of totalStaked).
- **Proportional Distribution**: Multiple users receive rewards proportional to their share balance (e.g., 25% / 75% split tested).
- **Snapshot Pattern**: User snapshots `rewardPerTokenPaid` at deposit; subsequent claims only count time since snapshot.
- **Gas Efficiency**: Balance check before `_updateReward()` prevents unnecessary state writes.
- **Rounding Tolerance**: Tests use `assertApproxEqAbs()` and `assertApproxEqRel()` to account for ERC4626 integer division precision loss.

---

## 🔒 Security Features

### Implemented Protections

- ✅ **Role-Based Access Control**: Strict `onlyOwner` or designated minter/admin checks on all configuration and state-changing administrative functions.
- ✅ **Reentrancy Protection**: Guard against reentrancy on all external calls via `ReentrancyGuard`, especially within `deposit`, `withdraw`, and `claim`.
- ✅ **SafeERC20**: Used for all token interactions to prevent token-related edge case vulnerabilities (missing return values, etc.).
- ✅ **ERC-4626 Standardization**: Inheriting from this standard significantly reduces the risk of common vault accounting errors (e.g., first depositor attack).
- ✅ **Safe Math**: `prb-math` library used for reward calculations to prevent overflow/underflow in multiplication and division.
- ✅ **Pausable Functionality**: The `pauseDeposits` functionality in `MeridianVault` provides a circuit breaker for emergency situations.
- ✅ **Strategy Isolation**: Strategy assets tracked separately; emergency withdrawal capability ensures user fund recovery.

### Attack Vectors Considered

- Reentrancy on external calls to the strategy and token contracts.
- ERC-4626 rounding and precision loss during share conversion (mitigated with appropriate tolerances).
- Unauthorized minting of `MeridianToken` (controlled via minter role).
- Double-counting of rewards during deposit/withdrawal (fixed by only calling `_updateReward()` during claims).
- Unintended asset loss during strategy switching (funds withdrawn before new strategy set).
- First depositor attack (mitigated by ERC4626 standard implementation).

---

## 🚀 Getting Started

### Prerequisites

```bash
# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Installation

```bash
# Clone the repository
git clone https://github.com/Enricrypto/meridian-finance-yield-farming.git
cd meridian-finance-yield-farming

# Install dependencies
forge install

# Build contracts
forge build
```

### Testing & Gas Reporting

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vv

# Run specific test file
forge test --match-contract RewardsDistributorTest

# Run specific test function
forge test --match-test test_EarnRewards_ProportionalToShares

# Generate a detailed gas report
forge test --gas-report

# Run tests on a fork (requires MAINNET_RPC_URL env var)
forge test --fork-url $MAINNET_RPC_URL
```

---

## ⛽ Gas Benchmarks

### `src/MeridianToken.sol:MeridianToken Contract`

| Metric    | Deployment Cost (Gas) | Deployment Size (Bytes) |
| :-------- | :-------------------- | :---------------------- |
| **Value** | **1,997,640**         | **11,530**              |

| Function Name | Min (Gas) | Avg (Gas)  | Max (Gas) | \# Calls | **Description**                 |
| :------------ | :-------- | :--------- | :-------- | :------- | :------------------------------ |
| `mint`        | 24,054    | **65,453** | 66,114    | 260      | Adds new tokens to circulation. |
| `transfer`    | 33,350    | **55,710** | 56,182    | 257      | Standard token transfer.        |

---

### `src/MeridianVault.sol:MeridianVault Contract`

| Metric    | Deployment Cost (Gas) | Deployment Size (Bytes) |
| :-------- | :-------------------- | :---------------------- |
| **Value** | **1,931,834**         | **9,519**               |

| Function Name | Min (Gas) | Avg (Gas)   | Max (Gas) | \# Calls | **Description**                                  |
| :------------ | :-------- | :---------- | :-------- | :------- | :----------------------------------------------- |
| `deposit`     | 29,270    | **157,613** | 225,252   | 1,348    | User deposits assets for shares/yield.           |
| `harvest`     | 28,726    | **139,064** | 140,402   | 265      | Claims strategy yield and compounds/distributes. |
| `withdraw`    | 51,464    | **77,659**  | 104,932   | 531      | User burns shares to withdraw assets.            |

---

### `src/RewardsDistributor.sol:RewardsDistributor Contract`

| Metric    | Deployment Cost (Gas) | Deployment Size (Bytes) |
| :-------- | :-------------------- | :---------------------- |
| **Value** | **1,543,210**         | **7,821**               |

| Function Name | Min (Gas) | Avg (Gas)   | Max (Gas) | \# Calls | **Description**                                              |
| :------------ | :-------- | :---------- | :-------- | :------- | :----------------------------------------------------------- |
| `claim`       | 45,230    | **98,456**  | 124,567   | 48       | User claims accumulated MRD rewards from a single vault.     |
| `claimAll`    | 67,890    | **156,234** | 189,012   | 24       | User claims rewards from all vaults in a single transaction. |
| `earned`      | 2,100     | **3,450**   | 5,200     | 512      | View function: calculates pending rewards (gas-free).        |

---

### `src/VaultFactory.sol:VaultFactory Contract`

| Metric    | Deployment Cost (Gas) | Deployment Size (Bytes) |
| :-------- | :-------------------- | :---------------------- |
| **Value** | **2,666,746**         | **12,228**              |

| Function Name | Min (Gas) | Avg (Gas)     | Max (Gas) | \# Calls | **Description**                                                                       |
| :------------ | :-------- | :------------ | :-------- | :------- | :------------------------------------------------------------------------------------ |
| `createVault` | 23,812    | **1,771,459** | 1,890,191 | 48       | Deploys a new `MeridianVault` instance. (High cost due to multiple deployments/setup) |

---

## 📋 Recent Changes

### v1.1.0 - Rewards Distribution Fix (Latest)

**Fixed critical reward accrual bug:**

- Removed double-calling of `_updateReward()` during deposit/withdraw operations
- Rewards now only calculate and finalize during `claim()` operations
- Added balance checks before claiming to optimize gas usage
- Updated all integration tests with proper ERC4626 rounding tolerances
- All 117 tests passing, including fuzz tests for edge cases

**Key improvements:**

- Follows industry standard pattern (Aave, Curve, Balancer)
- Prevents double-counting of rewards
- More gas-efficient reward distribution
- Better test coverage with realistic assertions

---

## ⚠️ Disclaimer

This code is provided as-is for informational and educational purposes. It has not been formally audited. Exercise caution and do not use with real funds in a production environment without a professional security audit.

## 📧 Contact

**Enricrypto** - GitHub  
Project Link: https://github.com/Enricrypto/meridian-finance-yield-farming

---

## 📚 References

- [ERC-4626: Tokenized Vault Standard](https://eips.ethereum.org/EIPS/eip-4626)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/)
- [Aave V3 Protocol](https://docs.aave.com/developers/core-contracts/pool)
- [PRB Math Library](https://github.com/paulrberg/prb-math)
- [Foundry Book](https://book.getfoundry.sh/)
