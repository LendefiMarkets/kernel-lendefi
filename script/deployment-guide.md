# Lendefi Smart Wallet Deployment Guide

## Overview

This guide covers deploying the Lendefi smart wallet infrastructure:

| Contract | Purpose |
|----------|---------|
| **Kernel** | ERC-7579 modular smart account implementation |
| **KernelFactory** | Deploys user wallet proxies |
| **LendefiStaking** | LDFI token staking for gas sponsorship tiers |
| **LendefiStakingPaymaster** | ERC-4337 paymaster that sponsors gas based on stake |

---

## Prerequisites

### 1. Install Dependencies

```bash
# Install Foundry (if not installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install project dependencies
npm install
forge install
```

### 2. Configure Environment

Copy `.env.example` or create `.env`:

```bash
# Required
PRIVATE_KEY=0x...              # Deployer private key (with ETH for gas)
LDFI_TOKEN=0x...               # Your LDFI ERC20 token address
OWNER=0x...                    # Admin/owner address for contracts
RPC_URL=https://...            # RPC endpoint for target chain

# For contract verification
ETHERSCAN_API_KEY=...          # Etherscan/Basescan/etc API key

# Filled after deployment (used by subsequent scripts)
# STAKING_ADDRESS=0x...
# PAYMASTER_ADDRESS=0x...

# Optional
# USE_ENTRYPOINT_V08=true      # Use EntryPoint v0.8 instead of v0.7
# DEPOSIT_AMOUNT=1000000000000000000   # 1 ETH default
# STAKE_AMOUNT=100000000000000000      # 0.1 ETH default
```

---

## Contracts You DON'T Deploy

These are already deployed on all EVM chains by the Ethereum Foundation:

| Contract | Address | Notes |
|----------|---------|-------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Default, battle-tested |
| EntryPoint v0.8 | `0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108` | Latest version |

---

## Deployment Steps

### Step 1: Deploy Kernel Implementation & Factory

```bash
npm run deploy:kernel
```

**What it deploys:**
- `Kernel` - The smart account implementation
- `KernelFactory` - Factory to create user wallets

**Output:**
```
Kernel Implementation: 0x...
KernelFactory: 0x...
```

Save these addresses for your records.

---

### Step 2: Deploy LendefiStaking

```bash
npm run deploy:staking
```

**What it deploys:**
- `LendefiStaking` - LDFI token staking contract

**Output:**
```
LendefiStaking deployed: 0x...
Add to .env: STAKING_ADDRESS=0x...
```

**Action Required:** Add the staking address to your `.env` file:
```bash
STAKING_ADDRESS=0x...  # Copy from output
```

---

### Step 3: Deploy LendefiStakingPaymaster

```bash
npm run deploy:paymaster
```

**What it deploys:**
- `LendefiStakingPaymaster` - ERC-4337 paymaster

**What it does automatically:**
- Authorizes the paymaster in the staking contract

**Output:**
```
LendefiStakingPaymaster deployed: 0x...
Paymaster authorized in staking contract
Add to .env: PAYMASTER_ADDRESS=0x...
```

**Action Required:** Add the paymaster address to your `.env` file:
```bash
PAYMASTER_ADDRESS=0x...  # Copy from output
```

---

### Step 4: Fund the Paymaster

The paymaster needs ETH to sponsor gas for users.

```bash
npm run fund:paymaster
```

**What it does:**
1. Deposits ETH into the paymaster (default: 1 ETH)
2. Stakes ETH for paymaster reputation (default: 0.1 ETH)

**Custom amounts:**
```bash
# In .env
DEPOSIT_AMOUNT=5000000000000000000   # 5 ETH
STAKE_AMOUNT=500000000000000000      # 0.5 ETH
```

---

## Full Deployment Sequence

```bash
# 1. Configure .env with PRIVATE_KEY, LDFI_TOKEN, OWNER, RPC_URL, ETHERSCAN_API_KEY

# 2. Deploy Kernel
npm run deploy:kernel

# 3. Deploy Staking (add STAKING_ADDRESS to .env after)
npm run deploy:staking

# 4. Deploy Paymaster (add PAYMASTER_ADDRESS to .env after)  
npm run deploy:paymaster

# 5. Fund Paymaster
npm run fund:paymaster
```

---

## Multi-Chain Deployment

You need to deploy on **each chain** you want to support. The EntryPoint is already there, but your contracts are not.

### Per-Chain Deployment

```bash
# Base Mainnet
export RPC_URL=https://mainnet.base.org
export ETHERSCAN_API_KEY=<basescan-api-key>
npm run deploy:kernel
npm run deploy:staking
# ... add STAKING_ADDRESS to .env
npm run deploy:paymaster
# ... add PAYMASTER_ADDRESS to .env
npm run fund:paymaster

# Arbitrum
export RPC_URL=https://arb1.arbitrum.io/rpc
export ETHERSCAN_API_KEY=<arbiscan-api-key>
# ... repeat
```

### Chain-Specific Configuration

| Chain | RPC URL | Block Explorer |
|-------|---------|----------------|
| Base | `https://mainnet.base.org` | basescan.org |
| Base Sepolia | `https://sepolia.base.org` | sepolia.basescan.org |
| Arbitrum | `https://arb1.arbitrum.io/rpc` | arbiscan.io |
| Optimism | `https://mainnet.optimism.io` | optimistic.etherscan.io |
| Ethereum | `https://eth.llamarpc.com` | etherscan.io |
| Polygon | `https://polygon-rpc.com` | polygonscan.com |

---

## Tier Configuration

The staking contract has these default tiers:

| Tier | LDFI Required | Gas Subsidy | Monthly Gas Limit |
|------|---------------|-------------|-------------------|
| NONE | 0 | 0% | 0 |
| BASIC | 1,000 | 50% | 500,000 |
| PREMIUM | 10,000 | 90% | 2,000,000 |
| ULTIMATE | 100,000 | 100% | 10,000,000 |

These are set at deployment and can be updated by the owner.

---

## Post-Deployment Checklist

- [ ] Kernel & Factory deployed
- [ ] LendefiStaking deployed
- [ ] LendefiStakingPaymaster deployed
- [ ] Paymaster authorized in staking contract
- [ ] Paymaster funded with ETH deposit
- [ ] Paymaster has stake for reputation
- [ ] All contracts verified on block explorer
- [ ] Addresses saved to config

---

## Configure Privy

After deployment, configure Privy dashboard:

1. Go to **dashboard.privy.io**
2. Select your app
3. Settings:
   - **Smart Wallets** → Enable
   - **Account Type** → Kernel
   - **Paymaster URL** → Your API endpoint
   - **Chains** → Select deployed chains
4. Your paymaster API should return:
   ```json
   { "paymasterAndData": "0x<your-paymaster-address>" }
   ```

---

## Contract Addresses Template

After deployment, save addresses:

```typescript
// config.ts
export const CONTRACTS = {
  // Per-chain addresses
  base: {
    KERNEL_IMPL: "0x...",
    KERNEL_FACTORY: "0x...",
    STAKING: "0x...",
    PAYMASTER: "0x...",
  },
  arbitrum: {
    KERNEL_IMPL: "0x...",
    KERNEL_FACTORY: "0x...", 
    STAKING: "0x...",
    PAYMASTER: "0x...",
  },
  // ... other chains
};

// Same on all chains
export const ENTRY_POINTS = {
  v07: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  v08: "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108",
};

export const LDFI_TOKEN = "0x..."; // Your LDFI token (may differ per chain)
```

---

## Troubleshooting

### "Insufficient funds"
- Ensure deployer wallet has enough ETH for gas
- Check RPC_URL is correct for the chain

### "Contract verification failed"
- Ensure ETHERSCAN_API_KEY is correct for the chain
- Wait a few blocks and retry
- Use `forge verify-contract` manually if needed

### "Paymaster rejected"
- Check paymaster has sufficient deposit
- Check paymaster has stake (required by ERC-4337)
- Verify user has staked LDFI tokens

### "Invalid staking address"
- Ensure STAKING_ADDRESS is set in .env before deploying paymaster

---

## NPM Scripts Reference

| Script | Description |
|--------|-------------|
| `npm run compile` | Build all contracts |
| `npm run test` | Run all tests |
| `npm run test:staking` | Test staking contract |
| `npm run test:paymaster` | Test paymaster contract |
| `npm run deploy:kernel` | Deploy Kernel + Factory |
| `npm run deploy:staking` | Deploy LendefiStaking |
| `npm run deploy:paymaster` | Deploy LendefiStakingPaymaster |
| `npm run fund:paymaster` | Fund paymaster with ETH |
| `npm run clean` | Clean build artifacts |

---

## Security Considerations

1. **Private Key Security**
   - Never commit `.env` to git
   - Use hardware wallet for mainnet deployments
   - Consider using a multisig for OWNER

2. **Paymaster Funding**
   - Monitor paymaster ETH balance
   - Set up alerts for low balance
   - Consider automated top-up

3. **Admin Functions**
   - Owner can update tier thresholds
   - Owner can pause/unpause staking
   - Owner can withdraw paymaster funds
   - Consider timelock for sensitive operations

---

## Support

- **Kernel Docs**: https://docs.zerodev.app/
- **ERC-4337 Spec**: https://eips.ethereum.org/EIPS/eip-4337
- **Privy Docs**: https://docs.privy.io/
