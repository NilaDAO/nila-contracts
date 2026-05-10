# NilaDAO Smart Contracts

Solidity contracts for the NilaDAO protocol — a DeFi lending platform on Polygon that bridges physical INR cash to on-chain credit via the **nIN** synthetic INR token.

## Overview

Farmers and borrowers access credit through local unions. Cash is collected on the ground, converted to nIN (pegged to INR), and disbursed on-chain. Loans are managed by the GenericFundCore, collateralised via a senior/junior pool structure, and settled through the FxPool.

## Contracts

| Contract | Description |
|---|---|
| `GenericFundCore.sol` | Core lending engine. Manages loans, senior/junior pools, and fund accounting. UUPS upgradeable. |
| `GenericFundViewer.sol` | Read-only views and EIP-712 voucher verification for off-chain oracle signatures. UUPS upgradeable. |
| `GenericFundMathLib.sol` | Linked library for interest accrual and pool math. |
| `NilaFxPool.sol` | FX settlement pool. Handles INR/USD rate oracle, escrow, and nIN burn. UUPS upgradeable. |
| `NilaLandTitle.sol` | On-chain land title registry (NFT-backed). UUPS upgradeable. |
| `NilaNIN.sol` | nIN ERC-20 token — synthetic INR, 18 decimals. |
| `NilaNINV2.sol` | nIN v2 with EIP-2612 permit support. UUPS upgradeable. |
| `NilaPOLSwap.sol` | Swaps nIN for POL (gas token) to fund borrower wallets. |
| `RolesRegistry.sol` | Central role registry for oracle, leader, core, and module addresses. |
| `GenericFund1155Module.sol` | ERC-1155 module extension for the fund. |
| `FoodTokenUpgradeable.sol` | Upgradeable token for agricultural commodity tracking. |

## Tech Stack

- Solidity `0.8.25`, `viaIR` optimizer
- OpenZeppelin Contracts Upgradeable (UUPS pattern)
- Hardhat + Chai + Mocha test suite
- Deployed on **Polygon mainnet** and **Amoy testnet**

## Architecture

```
Oracle (off-chain) ──signs──▶ EIP-712 Voucher
                                    │
                              GenericFundViewer (verify)
                                    │
                              GenericFundCore (disburse)
                                    │
                    ┌───────────────┴───────────────┐
               Senior Pool                     Junior Pool
                    │
                NilaFxPool ──▶ NilaNIN (burn/mint)
```

Loans are drawn against signed vouchers from a trusted oracle. The senior/junior pool structure allocates risk, and the FxPool handles currency settlement and escrow release.

## License

MIT
