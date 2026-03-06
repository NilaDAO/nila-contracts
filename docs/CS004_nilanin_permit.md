# Change Spec 004: Upgradeable NilaNIN with EIP-2612 Permit

## Why

The current `NilaNIN` is a plain `ERC20 + AccessControl` — not a proxy, no `permit`. CS004 replaces it with a UUPS-upgradeable `NilaNINV2` that adds EIP-2612 `permit`, enabling the union's `burnFarmerNin` flow without a separate approve transaction from the farmer.

---

## Critical Facts

### Current NilaNIN
- `contracts/NilaNIN.sol` — plain ERC20 + AccessControl, NOT a proxy
- Mainnet: `0xD1F49598E42D30Cd900Ea86244485ca0647d31C7`
- Roles: MINTER_ROLE + BURNER_ROLE → FxPool (`0xBaE3...`), DEFAULT_ADMIN_ROLE → hot key (`0xF2Ea...`)
- No in-place upgrade path — must deploy new proxy and migrate

### Live supply to migrate (~5,699 nIN)
- ~4,739 nIN in GenericFundCore (`0x4173...`)
- ~960 nIN held by external farmer addresses (active loan holders)
- 220k nIN in junior/senior accounting structs — not actual tokens, no migration needed

### nin storage in dependent contracts
- `GenericFundCore.nin` — slot 0, type `INilaNIN`, set in `initialize`. No setter exists.
- `NilaFxPool.nin` — slot 1, type `INilaNIN`, set in `initialize`. No setter exists.
- `GenericFundViewer` — does NOT reference NilaNIN.

### Pause mechanism
- `GenericFundCore` has `pause() / unpause()` (onlyOwner, hot key). Covers: depositSenior/Junior, requestUnbond*, drawLoanWithVoucher, AcceptLoan.
- `NilaFxPool` has `setRedeemPaused(bool)` (onlyRole ONLY_OWNER, Ledger). Covers redemptions.
- Use both to create a safe migration window.

### OZ v5 storage: ERC-7201 namespaced
All inherited OZ v5 upgradeable contracts store state at fixed keccak-derived high-entropy slots (not sequential 0, 1, 2…). The NilaNINV2 proxy has no inherited sequential state. Future upgrades are safe without extra `__gap` in the base contract — but a `__gap[50]` is added to the contract itself for any future NilaNINV2-specific storage.

---

## Files to Change

| File | Change |
|---|---|
| `contracts/NilaNINV2.sol` | NEW — UUPS upgradeable NilaNIN with permit |
| `contracts/NilaGasSwap.sol` | NEW — standalone nIN→POL gas faucet |
| `contracts/GenericFundCore.sol` | Add `setNin(address)` — onlyOwner |
| `contracts/NilaFxPool.sol` | Add `setNin(address)`, add `burnFarmerNin(address, uint256)` — onlyRole(ONLY_OWNER) / onlyRole(UNION_ROLE) |
| `test/NilaNINV2.spec.js` | NEW — full test suite including permit + burnFarmerNin flow |
| `test/NilaGasSwap.spec.js` | NEW — gas swap test suite |
| `scripts/TOMAINNET/validate_cs004.ts` | NEW — storage layout dry-run |
| `scripts/TOMAINNET/migrate_cs004_nin.ts` | NEW — migration orchestration |

---

## Step 1 — NilaNINV2.sol (new file)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract NilaNINV2 is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin_) external initializer {
        __ERC20_init("Nila INR Note", "nIN");
        __ERC20Permit_init("Nila INR Note");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
```

Notes:
- `ERC20PermitUpgradeable` inherits `EIP712Upgradeable` + `NoncesUpgradeable` automatically — no double-init
- MINTER_ROLE and BURNER_ROLE keccak values are **identical** to old contract
- `_authorizeUpgrade` gated by DEFAULT_ADMIN_ROLE (hot key `0xF2Ea...`)
- permit domain name: `"Nila INR Note"` (version `"1"` from OZ default)

---

## Step 2 — GenericFundCore.sol: add setNin

Add after `setFxPoolAddr` (around line 323). No new storage vars:

```solidity
function setNin(address _nin) external onlyOwner {
    require(_nin != address(0), "zero address");
    nin = INilaNIN(_nin);
}
```

`INilaNIN` interface at line 49 (`interface INilaNIN is IERC20 {}`) needs no change — Core only calls `transfer` and `transferFrom`.

---

## Step 3 — NilaFxPool.sol: add setNin + burnFarmerNin

### 3a. Add setNin

Add after `setFundCore` (around line 587). No new storage vars:

```solidity
function setNin(address _nin) external onlyRole(ONLY_OWNER) {
    require(_nin != address(0), "zero address");
    nin = INilaNIN(_nin);
}
```

`INilaNIN` interface in FxPool (lines 12–15) already has `mint` and `burn` — no change needed.

After `setNin` is called, the `rescueToken` guard (`require(token != address(nin))`) automatically protects the new address.

### 3b. Add burnFarmerNin

Add to the INilaNIN interface in FxPool (extend with `transferFrom`):
```solidity
interface INilaNIN {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
```

Add new event and function:
```solidity
event FarmerNinBurned(address indexed union, address indexed farmer, uint256 amount);

/// @notice Pull nIN from a farmer and burn it. Called by the union after the farmer
///         physically returns cash. The farmer must have signed a permit for FxPool
///         (or called approve) at drawLoanWithVoucher time.
/// @param farmer  Address that holds the nIN to burn.
/// @param amount  Amount of nIN to burn (must match loan principal).
function burnFarmerNin(address farmer, uint256 amount)
    external
    onlyRole(UNION_ROLE)
    nonReentrant
{
    require(farmer != address(0), "zero address");
    require(amount > 0, "zero amount");
    nin.transferFrom(farmer, address(this), amount);
    nin.burn(address(this), amount);
    emit FarmerNinBurned(msg.sender, farmer, amount);
}
```

Key design points:
- `onlyRole(UNION_ROLE)` — only the union that holds the cash-scan role can trigger this
- FxPool already holds `BURNER_ROLE` on NilaNINV2 — no new role needed
- The `transferFrom` requires prior `permit` (or `approve`) from the farmer
- No escrow interaction — the escrow was already resolved at `drawLoanWithVoucher` / `AcceptLoan`
- `junior.cash` is NOT modified — the liquidity slot was already debited when the loan was drawn

### 3c. Permit flow at drawLoanWithVoucher time

The farmer is online when calling `drawLoanWithVoucher`. The PWA must:

1. Get the oracle-signed voucher (includes `escrowId`, `nonce`)
2. Ask the farmer to sign a `permit` off-chain:
   ```
   domain : { name: "Nila INR Note", version: "1", chainId: 137, verifyingContract: NilaNINV2_proxy }
   types  : { Permit: [owner, spender, value, nonce, deadline] }
   values : { owner: farmer, spender: FxPool, value: loanAmount, nonce: nin.nonces(farmer), deadline: MaxUint256 }
   ```
3. Submit `drawLoanWithVoucher` tx on-chain (farmer signs this)
4. Submit `NilaNINV2.permit(farmer, FxPool, amount, MaxUint256, v, r, s)` on-chain

Steps 3 and 4 can be batched into a multicall or submitted sequentially in the same session. The permit sets the allowance — the nIN doesn't arrive in the farmer's wallet until after the tx (fast-draw) or after `AcceptLoan` (pending), but the allowance is in place regardless.

Later, when the farmer physically returns cash to the union:
```
union calls: NilaFxPool.burnFarmerNin(farmerAddress, loanAmount)
  → nin.transferFrom(farmer, FxPool, amount)   ← uses the permit allowance
  → nin.burn(FxPool, amount)                   ← FxPool has BURNER_ROLE
```

---

## Step 4 — validate_cs004.ts (new script)

Pattern from `validate_cs003.ts`:
1. `forceImport` + `validateUpgrade` GenericFundCore — confirms `setNin` is layout-safe (no storage change)
2. `forceImport` + `validateUpgrade` NilaFxPool — same
3. `upgrades.validateImplementation(NilaNINV2F)` — validates the new impl is upgrade-safe before deploy
4. Print PASS/FAIL summary

---

## Step 5 — migrate_cs004_nin.ts (new script)

Structured as independent phases — each can be run and verified separately.

### Phase A — Pre-migration read-only checks
1. Query Transfer events from old NilaNIN from deployment block → build holder balance map
2. Filter addresses with `balanceOf > 0`
3. Assert: sum of all balances == `totalSupply()`
4. Print holder list and balances

### Phase B — Deploy NilaNINV2 proxy (hot key)
5. `upgrades.deployProxy(NilaNINV2, [OWNER_ADDRESS], { kind: "uups" })`
6. Print new proxy address — **save this, needed for all remaining phases**

### Phase C — Grant roles on NilaNINV2 (hot key, DEFAULT_ADMIN)
7. `grantRole(MINTER_ROLE, FXPOOL)`
8. `grantRole(BURNER_ROLE, FXPOOL)`
9. Verify both roles

### Phase D — Pause system
10. `core.pause()` — hot key
11. `fxPool.setRedeemPaused(true)` — Ledger
(Two separate script runs or environment-based signer selection)

### Phase E — Migrate supply (hot key, MINTER_ROLE holder on new contract)
12. `nin_v2.mint(CORE, coreBalance)`
13. For each farmer: `nin_v2.mint(farmerAddr, balance)`
14. Assert: `nin_v2.totalSupply() == oldNin.totalSupply()`

### Phase F — Upgrade Core + setNin (hot key)
15. Deploy new GenericFundCore impl (adds `setNin`)
16. `core.setNin(NIN_V2_PROXY)`

### Phase G — Upgrade FxPool + setNin (Ledger)
17. Deploy new NilaFxPool impl (adds `setNin`)
18. `fxPool.setNin(NIN_V2_PROXY)`

### Phase H — Unpause system
19. `core.unpause()` — hot key
20. `fxPool.setRedeemPaused(false)` — Ledger

### Phase I — Post-migration verification
21. `core.nin() == NIN_V2_PROXY`
22. `fxPool.nin() == NIN_V2_PROXY`
23. NilaNINV2 MINTER_ROLE and BURNER_ROLE held by FxPool
24. Each holder's balance on new contract == old balance
25. `NilaNINV2.totalSupply() == old totalSupply`
26. Sanity: sign + submit a `permit` call to confirm EIP-2612 works

### Phase J — Freeze old NilaNIN (hot key)
27. Revoke MINTER_ROLE from FxPool on old NilaNIN
28. Revoke BURNER_ROLE from FxPool on old NilaNIN
(Old nIN balances remain held by farmers but are permanently non-mintable and non-burnable)

---

## Step 6 — test/NilaNINV2.spec.js

1. Deploy as UUPS proxy — verify name, symbol, admin role
2. mint: only MINTER_ROLE; others revert
3. burn: only BURNER_ROLE; others revert
4. Standard ERC-20: transfer, transferFrom, approve, allowance
5. EIP-2612 permit:
   - Sign with `ethers.signTypedData` (domain: `{ name: "Nila INR Note", version: "1", chainId, verifyingContract }`)
   - Call `permit(owner, spender, value, MaxUint256, v, r, s)` — verify allowance + nonce incremented
   - Expired deadline reverts
   - Wrong signer reverts
6. UUPS upgrade: upgrade to mock V3 (with extra function), verify storage preserved
7. setNin on Core/FxPool: deploy new impl, call setNin, verify; unauthorized reverts
8. burnFarmerNin full flow:
   - Farmer draws loan → receives nIN
   - Farmer signs permit off-chain (deadline = MaxUint256), submitted on-chain
   - Union calls `burnFarmerNin(farmer, amount)`
   - Verify: farmer nIN balance = 0, total supply decreased, FarmerNinBurned event
   - Non-UNION_ROLE caller reverts
   - Zero address reverts
   - Zero amount reverts
   - No allowance (no permit) reverts with ERC20InsufficientAllowance

---

## Step 7 — NilaGasSwap.sol (new standalone contract)

A simple gas faucet: any nIN holder swaps nIN for POL at the current INR/POL rate. Not upgradeable — simple enough to redeploy if needed.

### Chainlink feeds required
- **INR/USD**: already used by NilaFxPool (`inrUsdOracle`) — reuse the same feed address
- **POL/USD**: Chainlink Polygon mainnet feed — `0x97371dF4492605486e23Da797fA68e55Fc38a13f`

### Contract design

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20Transfer {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IChainlink {
    function latestRoundData() external view returns (
        uint80, int256 answer, uint256, uint256 updatedAt, uint80
    );
    function decimals() external view returns (uint8);
}

contract NilaGasSwap {
    address public immutable owner;
    IERC20Transfer public immutable nin;
    IChainlink public immutable inrUsdFeed;   // INR/USD (oracleDecimals)
    IChainlink public immutable polUsdFeed;   // POL/USD

    uint256 public maxNinPerDay = 100e18;     // 100 nIN cap per address per day (admin configurable)
    uint256 public maxOracleDelay = 3600;     // 1 hour staleness threshold

    mapping(address => uint256) public dayUsed;     // amount used today per address
    mapping(address => uint256) public lastResetDay; // UTC day number of last reset

    event Swapped(address indexed user, uint256 ninIn, uint256 polOut);
    event PolDeposited(uint256 amount);
    event PolWithdrawn(uint256 amount);
    event MaxNinPerDayUpdated(uint256 oldVal, uint256 newVal);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(address nin_, address inrUsdFeed_, address polUsdFeed_) {
        owner = msg.sender;
        nin = IERC20Transfer(nin_);
        inrUsdFeed = IChainlink(inrUsdFeed_);
        polUsdFeed = IChainlink(polUsdFeed_);
    }

    receive() external payable { emit PolDeposited(msg.value); }

    function setMaxNinPerDay(uint256 newMax) external onlyOwner {
        emit MaxNinPerDayUpdated(maxNinPerDay, newMax);
        maxNinPerDay = newMax;
    }

    function withdrawPol(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "insufficient POL");
        (bool ok,) = owner.call{value: amount}("");
        require(ok, "transfer failed");
        emit PolWithdrawn(amount);
    }

    function withdrawNin(uint256 amount) external onlyOwner {
        nin.transfer(owner, amount);
    }

    /// @notice Swap nIN for POL at current INR/POL rate.
    /// @param ninAmount Amount of nIN to swap (18 decimals). Max 100 nIN per address per day.
    function swap(uint256 ninAmount) external {
        require(ninAmount > 0, "zero amount");

        // Daily cap (resets at UTC midnight)
        uint256 today = block.timestamp / 1 days;
        if (lastResetDay[msg.sender] < today) {
            dayUsed[msg.sender] = 0;
            lastResetDay[msg.sender] = today;
        }
        require(dayUsed[msg.sender] + ninAmount <= maxNinPerDay, "daily cap exceeded");
        dayUsed[msg.sender] += ninAmount;

        // Compute POL amount
        uint256 polAmount = _ninToPol(ninAmount);
        require(polAmount > 0, "pol amount rounds to zero");
        require(address(this).balance >= polAmount, "insufficient POL in pool");

        // Pull nIN from caller (requires prior approve or permit)
        nin.transferFrom(msg.sender, address(this), ninAmount);

        // Send POL
        (bool ok,) = msg.sender.call{value: polAmount}("");
        require(ok, "pol transfer failed");

        emit Swapped(msg.sender, ninAmount, polAmount);
    }

    /// @dev ninAmount is 18-decimal INR. Returns POL in wei.
    ///      INR/USD feed gives: INR per 1 USD (e.g. 84000 * 10^decimals means 1 USD = 84000 INR)
    ///      POL/USD feed gives: USD per 1 POL (e.g. 0.23 * 10^decimals)
    ///      polAmount = ninAmount_inr / inrPerUsd * usdPerPol^-1
    ///                = ninAmount * polUsdPrice / inrUsdPrice   (adjusted for decimals)
    function _ninToPol(uint256 ninAmount) internal view returns (uint256) {
        (, int256 inrUsdAnswer,, uint256 inrUpdatedAt,) = inrUsdFeed.latestRoundData();
        (, int256 polUsdAnswer,, uint256 polUpdatedAt,) = polUsdFeed.latestRoundData();

        require(inrUsdAnswer > 0 && polUsdAnswer > 0, "invalid oracle price");
        require(block.timestamp - inrUpdatedAt <= maxOracleDelay, "INR/USD oracle stale");
        require(block.timestamp - polUpdatedAt <= maxOracleDelay, "POL/USD oracle stale");

        uint256 inrUsdPrice = uint256(inrUsdAnswer); // INR per USD, in inrFeed.decimals()
        uint256 polUsdPrice = uint256(polUsdAnswer); // USD per POL, in polFeed.decimals()
        uint8   inrDec = inrUsdFeed.decimals();
        uint8   polDec = polUsdFeed.decimals();

        // ninAmount is 18-decimal INR units
        // polAmount (wei) = ninAmount * polUsdPrice * 10^inrDec / (inrUsdPrice * 10^polDec * 1e18) * 1e18
        // simplified:
        // polAmount = ninAmount * polUsdPrice * 10^inrDec / (inrUsdPrice * 10^polDec)
        return (ninAmount * polUsdPrice * (10 ** inrDec)) / (inrUsdPrice * (10 ** polDec));
    }
}
```

### Key design points
- **Not upgradeable** — standalone, no proxy needed. Redeploy if logic changes.
- **nIN accumulates** — not burned. Admin calls `withdrawNin` periodically, redeems via FxPool (nIN→USDT), swaps USDT→POL off-chain, replenishes via `receive()`.
- **Daily cap** resets at UTC midnight (per address). `maxNinPerDay` defaults to 100 nIN (`100e18`), admin-configurable.
- **Any address** — no NFT gate, no role required.
- **Oracle math**: `polAmount = ninAmount * polUsdPrice * 10^inrDec / (inrUsdPrice * 10^polDec)`. Both feeds cancel their decimals correctly. Result is in wei (18 dec POL).
- **Staleness guard**: both feeds checked against `maxOracleDelay` (1 hour default).
- **POL pool drain protection**: reverts if `address(this).balance < polAmount`.

### Chainlink feed addresses (Polygon mainnet)
- INR/USD: same address as `NilaFxPool.inrUsdOracle` (already deployed and trusted)
- POL/USD: `0x97371dF4492605486e23Da797fA68e55Fc38a13f`

### Admin replenishment cycle
```
1. Call withdrawNin(amount)              ← pull accumulated nIN to admin wallet
2. Call NilaFxPool.redeemNin(amount)     ← swap nIN → USDT (existing function)
3. Swap USDT → POL off-chain (CEX/DEX)
4. Send POL to NilaGasSwap address       ← hits receive(), pool replenished
```

---

## Step 8 — test/NilaGasSwap.spec.js

1. Deploy with mock Chainlink feeds and mock nIN
2. `swap` happy path — verify POL received, nIN transferred to contract, dayUsed updated
3. Daily cap: two swaps totalling > 100 nIN in same day reverts
4. Daily cap resets next day (manipulate `block.timestamp`)
5. `setMaxNinPerDay` — only owner; verify updated
6. `withdrawPol` — only owner; verify balance
7. `withdrawNin` — only owner; verify nIN balance
8. Stale oracle reverts
9. Insufficient POL pool reverts
10. Zero amount reverts
11. Oracle math: verify POL amount correct for known INR/USD + POL/USD values

---

## Storage Layout Notes

### NilaNINV2 — no sequential inherited state
All OZ v5 upgradeable storage is ERC-7201 namespaced (high-entropy keccak slots). Slot 0 of the proxy only holds Initializable flags. The `__gap[50]` reserves space for future NilaNINV2-specific state variables.

### GenericFundCore — no change
`setNin` is a function addition only. `nin` at slot 0 holds the new address after the call. OZ validateUpgrade will pass.

### NilaFxPool — no change
`setNin` is a function addition only. `nin` at slot 1 holds the new address after the call. OZ validateUpgrade will pass.

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Incomplete farmer address enumeration | Cross-check: sum of balances must equal totalSupply. Abort if mismatch. |
| burnExpiredEscrow race during migration | Ensure no escrows are near deadline. Race window is brief and only burns from old contract (which is immediately decommissioned). |
| rescueToken no longer guards old nIN address | Old nIN is frozen (Phase J) — no balance should remain in FxPool. |
| permit nonces() collision with Core nonces | Different contracts, different mappings. No collision. |
| Future key rotation for DEFAULT_ADMIN_ROLE | Note for ops: rotate DEFAULT_ADMIN_ROLE before revoking old admin key. |
| Farmer permit used before nIN arrives (pending loan) | Allowance is set immediately on permit call. When AcceptLoan fires and nIN arrives, transferFrom works. No issue. |
| Union calls burnFarmerNin for wrong amount | Amount must match loan principal. PWA should read loan principal from `core.loans(unionAddr, loanId).principal` and pass that value. |
| Farmer revokes allowance before union burns | Off-chain issue. Union should call burnFarmerNin promptly after cash handback. Nothing enforces timing on-chain. |

---

## Deployment Sequence Summary

```
1. Write contracts (Steps 1–3)
2. npx hardhat compile
3. Write + run NilaNINV2.spec.js — all pass
4. npx hardhat test (full regression) — no new failures
5. validate_cs004.ts --network polygon — all PASS
6. migrate_cs004_nin.ts Phase A (read-only) — confirm holder list
7. Phase B–C: deploy proxy + grant roles (hot key)
8. Phase D: pause (hot key + Ledger)
9. Phase E: mint migration (hot key)
10. Phase F: upgrade Core + setNin (hot key)
11. Phase G: upgrade FxPool + setNin (Ledger)
12. Phase H: unpause (hot key + Ledger)
13. Phase I: post-migration verification
14. Phase J: freeze old NilaNIN (hot key)
```
