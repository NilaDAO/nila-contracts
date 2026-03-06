# CS003 PWA Integration — Change Document

This document describes what the PWA front-end needs to change or implement for Change Spec 003. It covers the cash-scan escrow flow (new) and the updated loan draw flow.

Contracts are on Polygon mainnet (chainId 137).

| Contract | Address |
|---|---|
| GenericFundCore (proxy) | `0x4173BbaF66A4f9A2705d05B800e8602370366756` |
| NilaFxPool (proxy) | `0xBaE307FE0A453955c649cD8f81e3DA572dF448eA` |
| NilaNIN | `0xD1F49598E42D30Cd900Ea86244485ca0647d31C7` |
| USDT (Polygon) | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` |

---

## Part 1 — Cash-Scan Escrow Flow (new)

### Overview

When a union scans physical INR cash, they call `cashScanMint` on NilaFxPool. This:
- Mints nIN into GenericFundCore equal to the INR value scanned (1 INR = 1 nIN, 18 decimals)
- Registers the nIN as available junior market liquidity for the specified `loanType`
- Creates an escrow record with a 3-day deadline

The escrow tracks whether the cash was verified (farmer drew a loan) or not. If unverified after 3 days, any address can burn the escrowed nIN.

### 1a. `cashScanMint` — union side

Called by the union's cash-scan signer (must hold `UNION_ROLE` on NilaFxPool).

```solidity
NilaFxPool.cashScanMint(
    bytes32 loanType,   // which junior market to credit (e.g. keccak256("KISAN_CREDIT"))
    uint256 inrValue,   // INR value of scanned cash, integer units (e.g. 84000 for ₹84,000)
    bytes32 scanHash    // keccak256 of scan data (serial numbers, image hash, denomination breakdown)
) returns (uint256 escrowId)
```

**Important:**
- `inrValue` is in **integer INR** — not wei. ₹84,000 = `84000`, not `84000e18`.
- The contract multiplies by `1e18` internally.
- `scanHash` is an off-chain commitment to the physical scan data. Store the preimage in your backend.
- The returned `escrowId` must be stored and passed along to the loan draw flow.

**Reverts if:**
- Caller does not hold `UNION_ROLE`
- `inrValue` is zero
- `fundCore` not set on NilaFxPool (configuration issue)

**Event emitted:**
```solidity
CashScanMint(
    uint256 indexed escrowId,
    address indexed union,
    address indexed fundAddr,
    uint256 ninAmount,    // = inrValue * 1e18
    uint256 inrValue,
    uint256 rate,         // INR/USD rate at scan time (oracleDecimals)
    uint64  deadline,     // Unix timestamp — escrow expires after this
    bytes32 scanHash
)
```

### 1b. Escrow status

Read escrow state at any time:
```solidity
NilaFxPool.getEscrow(uint256 escrowId) returns (CashEscrow memory)
```

```solidity
struct CashEscrow {
    address union;       // union that scanned
    address fundAddr;    // GenericFundCore address
    uint256 ninAmount;   // remaining nIN in escrow (decreases as loans are drawn)
    uint256 inrValue;    // original INR value scanned
    uint256 mintRate;    // INR/USD rate at scan time
    uint64  deadline;    // expiry timestamp
    uint8   status;      // 0=Active, 1=ResolvedCash, 2=ResolvedUsdt, 3=Burned
    bytes32 scanHash;
    bytes32 loanType;    // junior market credited
}
```

Status values:
| Value | Meaning |
|---|---|
| `0` | Active — escrow is live, deadline not yet passed |
| `1` | ResolvedCash — all nIN consumed by loans (farmers picked up cash) |
| `2` | ResolvedUsdt — union deposited USDT to back this nIN |
| `3` | Burned — deadline passed, nIN was burned, cash was not verified |

Check if expired (before calling burn):
```solidity
NilaFxPool.isEscrowExpired(uint256 escrowId) returns (bool)
```

### 1c. Resolution path A — cash loans drawn (automatic)

When `drawLoanWithVoucher` or `AcceptLoan` is called with a non-zero `escrowId`, the contract automatically calls `resolveEscrowCash` on NilaFxPool. The PWA does not need to call this directly.

A single `cashScanMint` can back **multiple loans** drawn at different times. The escrow's `ninAmount` decreases by each loan's amount. `status` only moves to `1` (ResolvedCash) when `ninAmount` reaches zero.

### 1d. Resolution path B — union converts to USDT (union side)

If the farmer did not draw a loan but the union physically converted the cash to USDT, the union resolves the escrow by depositing USDT:

```solidity
// Step 1: approve USDT transfer (exact amount computed below)
USDT.approve(NilaFxPool_address, usdtAmount);

// Step 2: resolve
NilaFxPool.resolveEscrowUsdt(uint256 escrowId)
```

The USDT amount is computed from the escrow's locked `mintRate`:
```
usdtAmount = (ninAmount * 10^oracleDecimals / mintRate) / 10^(18 - 6)
```

In practice: read `getEscrow(escrowId)` to get `ninAmount` and `mintRate`, then compute off-chain, then approve that exact USDT amount before calling `resolveEscrowUsdt`.

**Reverts if:**
- Caller is not the union that created the escrow
- Escrow is not Active (status != 0)
- Deadline has passed (3 days expired)
- USDT allowance is insufficient

### 1e. Resolution path C — burn expired escrow (permissionless)

After the deadline, anyone can burn the nIN:

```solidity
// Single escrow
NilaFxPool.burnExpiredEscrow(uint256 escrowId)

// Batch (skip non-eligible silently)
NilaFxPool.burnExpiredEscrowBatch(uint256[] calldata escrowIds)
```

The PWA can surface a "Burn expired escrow" action for admin users, or this can be triggered by a keeper/bot.

**Event emitted:**
```solidity
EscrowBurned(uint256 indexed escrowId, uint256 ninAmount)
```

---

## Part 2 — Updated Loan Draw Flow

### 2a. New parameters on `drawLoanWithVoucher`

Three parameters are appended to the existing call. The full signature is now:

```solidity
GenericFundCore.drawLoanWithVoucher(
    address unionAddr,
    bytes32 loanId,       // borrower-supplied unique ID
    bytes32 loanType,
    uint128 amount,
    uint16  rateBP,
    uint40  maturityTs,
    bytes32 paramsHash,
    bytes   calldata oracleSig,
    uint256 maxAmount,    // from voucher
    uint16  minRateBP,    // from voucher
    bool    fastDraw,     // from voucher
    uint256 escrowId,     // NEW — cash-scan escrow to resolve (0 if none)
    uint40  sosDate,      // NEW — start-of-season date, Unix timestamp (0 if none)
    uint256 nonce         // NEW — per-borrower replay-protection nonce
)
```

**`escrowId`** — pass `0` for loans not associated with a cash-scan. When non-zero, the contract calls `resolveEscrowCash(escrowId, amount)` on NilaFxPool automatically after disbursement. The oracle signs this value into the voucher — the PWA must pass whatever the oracle returned.

**`sosDate`** — informational, stored on the loan and emitted in the `LoanClaimed` event. Pass `0` if not applicable.

**`nonce`** — replay protection. The PWA must:
1. Read `GenericFundCore.nonces(borrowerAddress)` before submitting the tx.
2. Pass that value as `nonce`.
3. The oracle has already signed this nonce into the voucher — if the nonce is stale (another tx mined between signing and submission), the tx will revert with `BadNonce()`.

### 2b. Reading the nonce

```javascript
const nonce = await genericFundCore.nonces(borrowerAddress); // returns BigInt
```

The nonce increments by 1 on every successful `drawLoanWithVoucher`. It never decrements. If a tx reverts, the nonce is unchanged.

### 2c. Revert errors to handle

| Error | Meaning | User message |
|---|---|---|
| `BadNonce()` | Nonce is stale — another voucher was used between signing and submission | "Voucher expired — please request a new one" |
| `SignatureInvalid()` | Oracle signature does not match the parameters | Should not happen unless PWA passes wrong values |
| `VoucherAmountTooHigh()` | `amount > maxAmount` from the voucher | "Amount exceeds your voucher limit" |
| `BadRatio()` | Junior liquidity too low relative to senior | "Insufficient junior liquidity — more cash deposits needed" |
| `InsufficientCash()` | Not enough nIN in the fund | "Fund has insufficient liquidity" |
| `LoanNotExist()` | `loanId` already used | Ensure `loanId` is unique per union |

### 2d. `LoanClaimed` event (updated)

```solidity
event LoanClaimed(
    address indexed unionAddr,
    bytes32 indexed loanId,
    address borrower,
    bytes32 loanType,
    uint256 amount,
    uint16  rateBP,
    uint40  sosDate,      // NEW
    uint40  drawdownTs,   // RENAMED from createTs — 0 if pending (non-fastDraw)
    bool    fastDraw
)
```

Note: `drawdownTs` is `0` for pending loans (non-fastDraw) until `AcceptLoan` is called. For fast-draw loans it is set to the block timestamp immediately.

### 2e. Updated `AcceptLoan`

The union leader's `AcceptLoan` call now takes an `escrowId` parameter:

```solidity
GenericFundCore.AcceptLoan(
    address unionAddr,
    bytes32 loanId,
    uint256 escrowId   // NEW — 0 if no escrow, otherwise resolves it on disbursement
)
```

The `escrowId` to pass here is whatever the union leader knows is associated with the pending loan. If the loan was not linked to a cash-scan, pass `0`.

---

## Part 3 — Typical End-to-End Flows

### Flow A: Cash-scan → fast-draw loan (escrow resolved automatically)

```
1. Union calls cashScanMint(loanType, inrValue, scanHash)
   → escrowId returned in tx receipt (CashScanMint event)
   → nIN minted into fund, junior.cash credited

2. Oracle signs voucher with escrowId=<id>, nonce=nonces(borrower)
   → PWA fetches signed voucher from oracle API

3. Borrower calls drawLoanWithVoucher(..., escrowId=<id>, sosDate, nonce)
   → fastDraw=true: nIN transferred to borrower immediately
   → resolveEscrowCash(escrowId, amount) called automatically
   → escrow.ninAmount reduced; status=1 if fully consumed

4. No further action needed on the escrow.
```

### Flow B: Cash-scan → pending loan → AcceptLoan

```
1. Union calls cashScanMint(loanType, inrValue, scanHash)
   → escrowId returned

2. Oracle signs voucher with escrowId=<id>, fastDraw=false

3. Borrower calls drawLoanWithVoucher(..., escrowId=<id>, ..., fastDraw=false)
   → Loan created in pending state (drawdownTs=0)
   → escrow NOT yet resolved (disbursement hasn't happened)

4. Union leader calls AcceptLoan(unionAddr, loanId, escrowId=<id>)
   → nIN transferred to borrower
   → resolveEscrowCash(escrowId, amount) called automatically
```

### Flow C: Cash-scan → union converts to USDT

```
1. Union calls cashScanMint → escrowId returned
2. Farmer does not draw a loan within 3 days
   OR union physically converts cash to USDT before deadline
3. Union approves USDT on NilaFxPool, calls resolveEscrowUsdt(escrowId)
   → USDT deposited into NilaFxPool
   → escrow status=2 (ResolvedUsdt), burn path blocked permanently
```

### Flow D: Escrow expires — burn

```
1. cashScanMint called → escrowId returned
2. 3 days pass, no loan drawn, no USDT deposit
3. Anyone calls burnExpiredEscrow(escrowId)
   → nIN burned from fund
   → junior.cash debited
   → escrow status=3 (Burned)
```

---

## Part 4 — No changes needed

The following existing flows are **unchanged** and require no PWA update:
- `mintNin` / `redeemNin` on NilaFxPool
- `repayLoan` on GenericFundCore
- `setReserveConfigForUnion`, `CreateUnion`, investor deposit/withdraw
- NilaNIN ERC-20 transfers
