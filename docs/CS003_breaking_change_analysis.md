# CS003 — Breaking Change Analysis: GenericFundCore & GenericFundViewer

**Date:** 2026-03-02
**Scope:** Changes introduced by Change Spec 003 (Cash Scan Escrow & Contract Cleanup)
**Conclusion:** No breaking changes to on-chain storage. Breaking changes exist only at the ABI/off-chain layer and are listed explicitly with their migration actions.

---

## 1. GenericFundCore

### 1.1 `ICore.Loan` struct — new field `sosDate`

**Change:** A new field `uint40 sosDate` was appended at the end of the `ICore.Loan` struct (line 118).

**Why it is not a storage-breaking change:**
Solidity packs struct fields into 32-byte slots sequentially. The last field before `sosDate` was `bool lowerRate` (1 byte). `uint40` is 5 bytes. Both fit in the same slot that `lowerRate` already partially occupied, so no existing field shifts to a different storage slot.
All existing loans read `sosDate` as `0` until a new loan is created via the updated `drawLoanWithVoucher`. Zero is a valid and expected default — the field is informational only (no enforcement logic depends on it). Existing loan data is completely unaffected.

**ABI impact:** Any off-chain code (front-end, indexer) that decodes the `loans(address, bytes32)` return value will now receive a struct with one additional `uint40` field at the end. This is a **non-breaking extension** for callers that decode by field name (ethers.js, viem), but callers that decode by raw ABI-tuple offset must be updated to include the new field.

---

### 1.2 `ReserveCfg` struct — new field `escrowDuration`

**Change:** A new field `uint32 escrowDuration` was appended to the `ReserveCfg` struct (line 151).

**Why it is not a storage-breaking change:**
`ReserveCfg` is stored in `mapping(address => ReserveCfg) public reserveCfgByUnion`. Mappings store each value at an independent keccak slot; there is no adjacent-slot overlap risk. Appending a field to a struct in a mapping is always safe in Solidity — existing entries simply read `0` for the new field until `setReserveConfigForUnion` is called again. No previously written data is misread.

**ABI impact:** `setReserveConfigForUnion` now requires a fifth parameter `uint32 escrowDuration`. All callers (scripts, front-end) must pass this argument. Existing transactions that omit it will revert at the ABI-encoding layer. **Migration action:** Update all `setReserveConfigForUnion` call sites to pass `escrowDuration` (use `0` to keep the FxPool global fallback).

---

### 1.3 New state variables `fxPoolAddr` and `nonces`

**Change:** Two new storage slots are appended at the very end of the contract's declared state (lines 216–217):
```
address public fxPoolAddr;
mapping(address => uint256) public nonces;
```

**Why it is not a storage-breaking change:**
`GenericFundCore` has no `__gap`. Under the UUPS upgrade pattern, new variables are always appended after all existing declarations. The previous last variable was `rainyFeeBP` at storage slot 22 (packed alongside `treasuryFeeBP`). `fxPoolAddr` occupies slot 23; `nonces` occupies slot 24. No existing slot is displaced or reused. The OpenZeppelin `validateUpgrade` tool confirmed this is safe against the live Polygon mainnet proxy (all three contracts: PASS).

**ABI impact:** Two new public getters appear — `fxPoolAddr()` and `nonces(address)`. These are purely additive and do not affect existing callers.

---

### 1.4 `drawLoanWithVoucher` — three new parameters

**Change:** The function signature gains three parameters after `bool fastDraw` (lines 821–823):
- `uint256 escrowId` — cash-scan escrow ID to resolve on disbursement (pass `0` for none)
- `uint40 sosDate` — start-of-season date, stored on the loan (informational)
- `uint256 nonce` — per-borrower replay-protection nonce

**Why it is not a storage-breaking change:**
Function parameters do not occupy storage. The additional fields extend the calldata only.

**ABI impact:** This is a **breaking change to the function ABI**. All existing callers must pass the three new arguments. The nonce must equal `nonces[msg.sender]` on-chain at call time; the oracle signature must cover all new fields. **Migration action:**
1. Read `core.nonces(borrowerAddress)` before each call.
2. Update the EIP-712 signing backend to include `escrowId`, `sosDate`, and `nonce` in the signed payload (see Viewer change 2.1 below).
3. Pass `escrowId=0, sosDate=0, nonce=currentNonce` for normal loans with no cash-scan escrow.

---

### 1.5 `AcceptLoan` — new parameter `uint256 escrowId`

**Change:** The function signature changes from `AcceptLoan(address unionAddr, bytes32 loanId)` to `AcceptLoan(address unionAddr, bytes32 loanId, uint256 escrowId)` (line 904).

**Why it is not a storage-breaking change:**
Parameter-only change.

**ABI impact:** Breaking change to the function ABI. All callers must pass `escrowId`. For loans that were not originated via a cash-scan, pass `0`. **Migration action:** Update all `AcceptLoan` call sites to pass `escrowId=0` (or the relevant escrow ID if the loan is linked to a cash-scan mint).

---

### 1.6 `LoanClaimed` event — updated arguments

**Change:** The `LoanClaimed` event (line 259) has two changes:
- Renamed field: the timestamp field was previously named `createTs` in both the event declaration and the emit. It is now named `drawdownTs` and emits `ln.drawdownTs` (which is `createTs` for fast-draw loans, or `0` for pending loans waiting for `AcceptLoan`).
- New field: `uint40 sosDate` is emitted as a new argument before `drawdownTs`.

**Why it is not a storage-breaking change:**
Events are not stored on-chain; they exist only in the transaction receipt logs.

**ABI impact:** Any indexer or front-end that decodes `LoanClaimed` events by argument position must update its ABI. The new full signature is:
```
LoanClaimed(address indexed unionAddr, bytes32 indexed loanId, address borrower, bytes32 loanType, uint256 amount, uint16 rateBP, uint40 sosDate, uint40 drawdownTs, bool fastDraw)
```
**Migration action:** Update event ABI and reindex or handle the new argument at index 6 (`sosDate`) and the corrected index 7 (`drawdownTs`, which is now `0` for non-fast-draw loans until `AcceptLoan` is called).

---

### 1.7 `transferLoan` function — removed

**Change:** The `transferLoan` function (previously ~85 lines) has been deleted, along with its `LoanTransferred` event declaration.

**Why it is not a storage-breaking change:**
Removing a function does not touch storage. No storage slot is freed or moved.

**ABI impact:** Any caller that invokes `transferLoan` will revert with a function-not-found error after the upgrade. **Migration action:** Confirm that no active front-end, script, or third-party integration calls `transferLoan`. If needed, complete any in-flight loan transfers before deploying the upgrade.

---

### 1.8 New functions: `setFxPoolAddr`, `burnEscrowNin`, `getUnionEscrowDuration`

**Change:** Three new functions are added (lines 321–335).

**Why not breaking:**
Purely additive. Existing callers are unaffected. `burnEscrowNin` has an access guard (`msg.sender == fxPoolAddr`) so it cannot be called by unauthorized parties even before `setFxPoolAddr` is called (it will revert because `fxPoolAddr` defaults to `address(0)`).

---

## 2. GenericFundViewer

### 2.1 `VOUCHER_TYPEHASH` — updated

**Change:** Three new fields are appended to the EIP-712 type string (line 128):
```
uint256 escrowId, uint40 sosDate, uint256 nonce
```
Old typehash:
```
Voucher(address borrower,address union,bytes32 loanId,uint256 maxAmount,uint16 minRateBP,bytes32 loanType,bytes32 paramsHash,bool fastDraw)
```
New typehash:
```
Voucher(address borrower,address union,bytes32 loanId,uint256 maxAmount,uint16 minRateBP,bytes32 loanType,bytes32 paramsHash,bool fastDraw,uint256 escrowId,uint40 sosDate,uint256 nonce)
```

**Why it is not a storage-breaking change:**
`VOUCHER_TYPEHASH` is a `private constant` — it lives in bytecode, not in storage. No storage slot is affected.

**ABI impact:** All previously signed vouchers are invalid after the upgrade because the digest changes. This is intentional — the nonce field prevents replay attacks on the new scheme. **Migration action:** The oracle signing backend must be updated to sign with all three new fields (`escrowId`, `sosDate`, `nonce`) before the upgrade goes live. In-flight unsubmitted vouchers signed under the old scheme must be re-signed.

---

### 2.2 `recoverVoucherSigner` — three new parameters

**Change:** The function signature gains `uint256 escrowId`, `uint40 sosDate`, and `uint256 nonce` before the `bytes calldata sig` argument (lines 577–580).

**Why it is not a storage-breaking change:**
`GenericFundViewer` has no state that changes in this function — it is a pure view function. No storage is read or written by the typehash or signature recovery logic.

**ABI impact:** Any off-chain code that calls `recoverVoucherSigner` directly (e.g. for off-chain signature verification) must pass the three additional arguments. **Migration action:** Update any direct callers of `recoverVoucherSigner` to include `escrowId`, `sosDate`, and `nonce`.

---

### 2.3 `IFundCore.Loan` struct — new field `sosDate`

**Change:** The local `Loan` struct inside `GenericFundViewer`'s `IFundCore` interface (line 52) has `uint40 sosDate` appended, mirroring the change in `GenericFundCore`.

**Why not breaking:**
This is an interface definition used only for ABI-decoding the return value of `core.loans(...)`. The Viewer reads the loan struct from `GenericFundCore` via an external call; if the Viewer's interface definition does not match the Core's struct exactly, the ABI decode will silently mis-align fields. Adding `sosDate` here keeps the Viewer's decode in sync with the Core's storage layout.

Existing loans in storage have `sosDate = 0` at that slot offset, so all Viewer read functions that return `Loan` data will correctly surface `sosDate = 0` for pre-upgrade loans.

**ABI impact:** Any front-end or indexer that calls Viewer functions returning a full `Loan` struct (e.g. `getLoanDetail`) will receive an extra `uint40` field at the end of the tuple. Non-breaking for named-field decoders; requires update for positional tuple decoders.

---

## 3. Summary Table

| # | Contract | Change | Storage Impact | ABI Impact | Migration Required |
|---|---|---|---|---|---|
| 1.1 | Core | `Loan.sosDate` field added | None — packs into existing slot | New field in `loans()` return tuple | Update positional tuple decoders |
| 1.2 | Core | `ReserveCfg.escrowDuration` field added | None — safe struct extension in mapping | New param on `setReserveConfigForUnion` | Pass `escrowDuration` (use 0 for default) |
| 1.3 | Core | `fxPoolAddr` + `nonces` state vars | 2 new slots appended at end | New getters `fxPoolAddr()`, `nonces(addr)` | Call `setFxPoolAddr` post-upgrade |
| 1.4 | Core | `drawLoanWithVoucher` new params | None | **Breaking** — 3 new params, new nonce req | Re-sign vouchers; pass nonce, escrowId, sosDate |
| 1.5 | Core | `AcceptLoan` new param | None | **Breaking** — 1 new param | Pass `escrowId=0` for existing loans |
| 1.6 | Core | `LoanClaimed` event updated | None (event only) | **Breaking** — new field, renamed field | Re-index event decoders |
| 1.7 | Core | `transferLoan` removed | None | **Breaking** — function no longer exists | Ensure no active callers before upgrade |
| 2.1 | Viewer | `VOUCHER_TYPEHASH` updated | None (constant in bytecode) | **Breaking** — old signatures invalid | Update oracle backend before upgrade |
| 2.2 | Viewer | `recoverVoucherSigner` new params | None | Breaking for direct off-chain callers | Update off-chain verifiers |
| 2.3 | Viewer | `IFundCore.Loan.sosDate` mirrored | None | New field in Loan read results | Update positional tuple decoders |

### Storage Safety Confirmation
- `validateUpgrade` run against live Polygon mainnet proxies for all three contracts: **all PASS**
- GenericFundCore: 2 new slots (23, 24) cleanly appended after `rainyFeeBP`
- NilaFxPool: 5 new escrow slots consumed from `__gap` (40 → 35); net slot count unchanged
- GenericFundViewer: no storage changes whatsoever
