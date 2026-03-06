# CS003 Oracle Integration — Change Document

This document describes the contract changes in Change Spec 003 that the oracle backend must implement before new vouchers can be issued.

---

## 1. Updated EIP-712 Voucher

### New typehash

The `Voucher` struct has three new fields appended. The typehash string has changed:

**Before:**
```
Voucher(address borrower,address union,bytes32 loanId,uint256 maxAmount,uint16 minRateBP,bytes32 loanType,bytes32 paramsHash,bool fastDraw)
```

**After:**
```
Voucher(address borrower,address union,bytes32 loanId,uint256 maxAmount,uint16 minRateBP,bytes32 loanType,bytes32 paramsHash,bool fastDraw,uint256 escrowId,uint40 sosDate,uint256 nonce)
```

### New fields to sign

| Field | Type | Description |
|---|---|---|
| `escrowId` | `uint256` | ID of the cash-scan escrow that will be resolved when this loan is disbursed. Use `0` if no escrow is associated. |
| `sosDate` | `uint40` | Start-of-season date as a Unix timestamp (informational — stored on the loan, emitted in `LoanClaimed` event, not enforced). Use `0` if not applicable. |
| `nonce` | `uint256` | Per-borrower replay-protection nonce. Must match `GenericFundCore.nonces(borrower)` at the time of signing. |

### EIP-712 domain (unchanged)

```
EIP712Domain(string name,uint256 chainId,address verifyingContract)

name               : "GenericFund"
chainId            : 137  (Polygon mainnet)
verifyingContract  : 0x4173BbaF66A4f9A2705d05B800e8602370366756  (GenericFundCore proxy)
```

### Signing flow

1. Read the borrower's current nonce: `GenericFundCore.nonces(borrowerAddress)` — this is a public mapping, readable with no gas.
2. Determine `escrowId`: if the loan is backed by a cash-scan escrow, supply the escrow ID; otherwise `0`.
3. Determine `sosDate`: supply the start-of-season Unix timestamp, or `0`.
4. Sign the full struct (all 11 fields) using EIP-712.

### `abi.encode` field order for the struct hash

```
keccak256(abi.encode(
    VOUCHER_TYPEHASH,
    borrower,       // address
    union,          // address
    loanId,         // bytes32
    maxAmount,      // uint256
    minRateBP,      // uint16
    loanType,       // bytes32
    paramsHash,     // bytes32
    fastDraw,       // bool
    escrowId,       // uint256   ← NEW
    sosDate,        // uint40    ← NEW
    nonce           // uint256   ← NEW
))
```

---

## 2. Updated `drawLoanWithVoucher` call

The on-chain function signature has three new trailing parameters:

```solidity
drawLoanWithVoucher(
    address unionAddr,
    bytes32 loanId,
    bytes32 loanType,
    uint128 amount,
    uint16  rateBP,
    uint40  maturityTs,
    bytes32 paramsHash,
    bytes   calldata oracleSig,
    uint256 maxAmount,
    uint16  minRateBP,
    bool    fastDraw,
    uint256 escrowId,   // NEW — 0 if no escrow
    uint40  sosDate,    // NEW — 0 if not applicable
    uint256 nonce       // NEW — must match nonces(msg.sender) on-chain
)
```

The borrower (or the frontend on their behalf) must pass these three values when submitting the transaction. The contract will:
- Verify the oracle signature includes all three new fields.
- Reject the tx with `BadNonce()` if `nonce != nonces[msg.sender]`.
- Increment `nonces[msg.sender]` on success.
- If `escrowId != 0`, automatically call `NilaFxPool.resolveEscrowCash(escrowId, amount)` after disbursement.

---

## 3. Nonce management

- Nonces are **per-borrower**, stored in `GenericFundCore.nonces(address) → uint256`.
- Read the current nonce before signing: if it is `5`, sign with `nonce=5`; after the tx mines it becomes `6`.
- There is no expiry on vouchers other than what the oracle chooses to enforce off-chain (e.g. by checking `maturityTs`).
- If a voucher is signed but the tx is never submitted, the nonce is not consumed — the same nonce remains valid.
- If a voucher is signed and the tx reverts (e.g. bad amount, wrong rate), the nonce is **not** incremented — the voucher remains replayable unless the oracle revokes it.

---

## 4. No changes to `AcceptLoan` oracle signature

`AcceptLoan` does not require an oracle signature. The `escrowId` parameter added to `AcceptLoan` is supplied by the union leader directly (not signed by the oracle). No oracle change needed for this function.

---

## 5. Contract addresses (Polygon mainnet)

| Contract | Address |
|---|---|
| GenericFundCore (proxy) | `0x4173BbaF66A4f9A2705d05B800e8602370366756` |
| NilaFxPool (proxy) | `0xBaE307FE0A453955c649cD8f81e3DA572dF448eA` |
| GenericFundViewer (proxy) | `0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA` |
| NilaNIN | `0xD1F49598E42D30Cd900Ea86244485ca0647d31C7` |

---

## 6. Backwards compatibility

Existing loans already on-chain are unaffected. The oracle only needs to update its signing logic for **new vouchers issued after this deployment**. For any loan that has no associated cash-scan escrow, pass `escrowId=0, sosDate=0, nonce=nonces(borrower)`.
