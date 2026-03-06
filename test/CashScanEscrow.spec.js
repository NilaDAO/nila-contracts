/* eslint-disable no-console */
/**
 * CS003 — Cash Scan Escrow & Contract Cleanup
 * Tests for:
 *  - NilaFxPool: cashScanMint, resolveEscrowUsdt, resolveEscrowCash, burnExpiredEscrow, burnExpiredEscrowBatch
 *  - GenericFundCore: burnEscrowNin, setFxPoolAddr, drawLoanWithVoucher + AcceptLoan with escrowId
 *  - ABI check: transferLoan removed
 */
const { expect } = require("chai");
const { ethers, network, upgrades } = require("hardhat");
const { parseEther, keccak256, toUtf8Bytes, MaxUint256, encodeBytes32String } = require("ethers");

const DAY = 24 * 60 * 60;
const THREE_DAYS = 3 * DAY;

async function now() {
  return (await ethers.provider.getBlock("latest")).timestamp;
}
async function timeTravel(seconds) {
  await network.provider.send("evm_increaseTime", [Number(seconds)]);
  await network.provider.send("evm_mine");
}

// Oracle answer: USD/INR price feed.
// e.g. 1 USD = 0.012 INR → answer = 0.012 * 1e8 = 1_200_000 (8 decimals)
// i.e. if INR/USD = 83.5, then USD/INR = 1/83.5 ≈ 0.01198 → 1_197_605 * 1e0 in 8 dec
// For tests: we want the pool to just work. Use answer = 1_200_000 (8 dec) → INR/USD ≈ 83.33
const ORACLE_ANSWER = 1_200_000n; // 8 decimals → INR per USD ≈ 83.33

async function signVoucher({
  oracle, coreAddr, borrower, union, loanId, maxAmount, minRateBP, loanType,
  paramsHash = ethers.ZeroHash, fastDraw = true,
  escrowId = 0n, sosDate = 0, nonce = 0n,
}) {
  const domain = {
    name: "GenericFund",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: coreAddr,
  };
  const types = {
    Voucher: [
      { name: "borrower",   type: "address" },
      { name: "union",      type: "address" },
      { name: "loanId",     type: "bytes32" },
      { name: "maxAmount",  type: "uint256" },
      { name: "minRateBP",  type: "uint16"  },
      { name: "loanType",   type: "bytes32" },
      { name: "paramsHash", type: "bytes32" },
      { name: "fastDraw",   type: "bool"    },
      { name: "escrowId",   type: "uint256" },
      { name: "sosDate",    type: "uint40"  },
      { name: "nonce",      type: "uint256" },
    ],
  };
  const value = { borrower, union, loanId, maxAmount, minRateBP, loanType, paramsHash, fastDraw, escrowId, sosDate, nonce };
  return oracle.signTypedData(domain, types, value);
}

describe("CS003 — Cash Scan Escrow & Contract Cleanup", function () {
  let owner, unionSigner, borrower1, borrower2, rando;

  // contracts
  let nin, mockOracle, fxPool;
  let core, viewer, roles, land721, erc20;

  const MINTER_ROLE = keccak256(toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE  = keccak256(toUtf8Bytes("BURNER_ROLE"));

  const unionAddr = ethers.Wallet.createRandom().address;
  const loanTypeA = encodeBytes32String("TestFund");
  const SCAN_HASH = keccak256(toUtf8Bytes("scan:abc123"));

  before(async () => {
    [owner, unionSigner, borrower1, borrower2, rando] = await ethers.getSigners();

    // ── NilaNIN ──
    const NinF = await ethers.getContractFactory("NilaNIN");
    nin = await NinF.connect(owner).deploy("Nila INR Note", "nIN", await owner.getAddress());
    await nin.waitForDeployment();

    // ── MockAggregator (USD/INR feed, 8 decimals) ──
    const AggF = await ethers.getContractFactory("MockAggregator");
    mockOracle = await AggF.connect(owner).deploy(8, ORACLE_ANSWER);
    await mockOracle.waitForDeployment();

    // ── MockUSDT (6 decimals) ──
    const ERC20F = await ethers.getContractFactory("MockERC20");
    erc20 = await ERC20F.connect(owner).deploy("MockUSDT", "mUSDT", 6);
    await erc20.waitForDeployment();

    // ── NilaFxPool (UUPS proxy) ──
    const FxF = await ethers.getContractFactory("NilaFxPool");
    fxPool = await upgrades.deployProxy(FxF, [
      await erc20.getAddress(),       // usdt_
      await nin.getAddress(),         // nin_
      await mockOracle.getAddress(),  // oracle_
      200,                            // fxThresholdBps_ = 2%
      parseEther("999999"),           // globalCapPerDay_ (no limit for tests)
      3600 * 24 * 7,                  // maxOracleDelay_ = 7 days (generous for tests)
      90 * 24 * 3600,                 // epochDuration_ = 90 days
      await owner.getAddress(),       // admin_
    ], { kind: "uups", initializer: "initialize" });
    await fxPool.waitForDeployment();

    // ── Land NFT mock ──
    const ERC721F = await ethers.getContractFactory("contracts/mocks/MockERC721.sol:MockERC721");
    land721 = await ERC721F.connect(owner).deploy(await owner.getAddress());
    await land721.waitForDeployment();
    // mint land to borrower1 so they can take loans
    await land721.connect(owner).mint(await borrower1.getAddress(), 1);

    // ── GenericFundMathLib ──
    const MathLibF = await ethers.getContractFactory("GenericFundMathLib");
    const mathLib = await MathLibF.connect(owner).deploy();
    await mathLib.waitForDeployment();
    const mathLibAddress = await mathLib.getAddress();

    // ── RolesRegistry ──
    const RolesF = await ethers.getContractFactory("RolesRegistry");
    roles = await RolesF.connect(owner).deploy(await owner.getAddress());
    await roles.waitForDeployment();

    // ── GenericFundCore ──
    const CoreF = await ethers.getContractFactory("GenericFundCore", {
      libraries: { GenericFundMathLib: mathLibAddress },
    });
    core = await CoreF.connect(owner).deploy();
    await core.waitForDeployment();

    // ── GenericFundViewer ──
    const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
      libraries: { GenericFundMathLib: mathLibAddress },
    });
    viewer = await ViewerF.connect(owner).deploy();
    await viewer.waitForDeployment();

    // ── Initialize core ──
    await core.connect(owner).initialize(
      await land721.getAddress(),
      await roles.getAddress(),
      await nin.getAddress(),   // nin token IS the lending asset
    );

    // ── Initialize viewer ──
    await viewer.connect(owner).initialize(await core.getAddress(), await roles.getAddress());
    await core.connect(owner).setViewer(await viewer.getAddress());

    // ── NilaNIN roles ──
    await nin.connect(owner).grantRole(MINTER_ROLE, await fxPool.getAddress());
    await nin.connect(owner).grantRole(BURNER_ROLE, await fxPool.getAddress());

    // ── FxPool: admin setup ──
    await fxPool.connect(owner).setEscrowDuration(THREE_DAYS);
    await fxPool.connect(owner).setFundCore(await core.getAddress());
    await fxPool.connect(owner).grantRole(keccak256(toUtf8Bytes("UNION_ROLE")), await unionSigner.getAddress());

    // ── Core: wire fxPool ──
    await core.connect(owner).setFxPoolAddr(await fxPool.getAddress());

    // ── Roles ──
    await roles.connect(owner).setCore(await core.getAddress(), true);
    await roles.connect(owner).setOracle(await owner.getAddress(), true); // owner as oracle for tests

    // ── Union + fund setup in core ──
    await viewer.connect(owner).CreateUnion(unionAddr, "Test Union", "loc");
    await viewer.connect(owner).AddFundType(unionAddr, loanTypeA, "TEST");
    await core.connect(owner).setRateParams(unionAddr, 600, 8000, 400, 2400, 3000);
    await core.connect(owner).setReserveConfigForUnion(unionAddr, 1000, 0, true, 0);

    // ── Seed nin supply in core (core needs to hold nIN to disburse loans) ──
    // Grant core a minter role temporarily to seed initial supply
    // OR: Fund the core directly by minting nIN to the owner and transferring
    await nin.connect(owner).grantRole(MINTER_ROLE, await owner.getAddress());
    // Seed junior + senior liquidity via nin (using nIN as the lending asset)
    const investorJ = borrower2; // borrower2 has no land NFT → can't be junior; use owner
    // For simplicity, just mint nIN to core directly to simulate deposits
    // In production, investors deposit nIN; for tests we seed directly
    await nin.connect(owner).mint(await owner.getAddress(), parseEther("100000"));

    // Approve and deposit as "senior" (owner has no land NFT)
    const ninAddr = await nin.getAddress();
    const ninerc20 = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", ninAddr);
    await ninerc20.connect(owner).approve(await core.getAddress(), MaxUint256);
    await core.connect(owner).depositSenior(unionAddr, parseEther("50000"));

    // deposit junior: mint land to owner and deposit
    await land721.connect(owner).mint(await owner.getAddress(), 99);
    await core.connect(owner).depositJunior(unionAddr, loanTypeA, parseEther("30000"));
  });

  // ─────────────────────────────────────────────────────────────
  // Admin setup tests
  // ─────────────────────────────────────────────────────────────

  describe("Admin setup", function () {
    it("A1: setEscrowDuration enforces range", async () => {
      await expect(fxPool.connect(owner).setEscrowDuration(0)).to.be.reverted;
      await expect(fxPool.connect(owner).setEscrowDuration(31 * DAY)).to.be.reverted;
      await expect(fxPool.connect(owner).setEscrowDuration(THREE_DAYS)).to.emit(fxPool, "EscrowDurationUpdated");
    });

    it("A2: setFundCore rejects zero address", async () => {
      await expect(fxPool.connect(owner).setFundCore(ethers.ZeroAddress)).to.be.reverted;
      await expect(fxPool.connect(rando).setFundCore(await core.getAddress())).to.be.reverted;
    });

    it("A3: UNION_ROLE is required for cashScanMint", async () => {
      await expect(
        fxPool.connect(rando).cashScanMint(loanTypeA, 1000, SCAN_HASH)
      ).to.be.reverted;
    });

    it("A4: setFxPoolAddr on core: only owner", async () => {
      await expect(core.connect(rando).setFxPoolAddr(await fxPool.getAddress())).to.be.reverted;
      await expect(core.connect(owner).setFxPoolAddr(await fxPool.getAddress())).to.not.be.reverted;
    });

    it("A5: escrowDuration and fundCore correctly set", async () => {
      expect(await fxPool.escrowDuration()).to.equal(THREE_DAYS);
      expect(await fxPool.fundCore()).to.equal(await core.getAddress());
    });
  });

  // ─────────────────────────────────────────────────────────────
  // cashScanMint
  // ─────────────────────────────────────────────────────────────

  describe("cashScanMint", function () {
    it("C1: happy path — creates escrow, mints nIN to fund, credits junior market, increments nextEscrowId", async () => {
      const inrValue = 84000n; // ₹84,000
      const ninAmountExpected = inrValue * 10n ** 18n;
      const fundAddr = await core.getAddress();

      const nInBefore = await nin.balanceOf(fundAddr);
      const escrowIdBefore = await fxPool.nextEscrowId();
      const totalEscrowedBefore = await fxPool.totalEscrowedNin();
      const juniorMarketBefore = await core.getJuniorMarket(await unionSigner.getAddress(), loanTypeA);

      await expect(
        fxPool.connect(unionSigner).cashScanMint(loanTypeA, inrValue, SCAN_HASH)
      ).to.emit(fxPool, "CashScanMint");

      const escrowId = escrowIdBefore;
      const e = await fxPool.getEscrow(escrowId);

      expect(e.union).to.equal(await unionSigner.getAddress());
      expect(e.fundAddr).to.equal(fundAddr);
      expect(e.loanType).to.equal(loanTypeA);
      expect(e.ninAmount).to.equal(ninAmountExpected);
      expect(e.inrValue).to.equal(inrValue);
      expect(e.status).to.equal(0); // Active
      expect(e.scanHash).to.equal(SCAN_HASH);
      expect(e.deadline).to.be.gt(await now());

      expect(await fxPool.nextEscrowId()).to.equal(escrowIdBefore + 1n);
      expect(await fxPool.totalEscrowedNin()).to.equal(totalEscrowedBefore + ninAmountExpected);
      expect(await nin.balanceOf(fundAddr)).to.equal(nInBefore + ninAmountExpected);

      // Junior market cash must be credited
      const juniorMarketAfter = await core.getJuniorMarket(await unionSigner.getAddress(), loanTypeA);
      expect(juniorMarketAfter.cash).to.equal(juniorMarketBefore.cash + ninAmountExpected);
    });

    it("C2: zero inrValue reverts", async () => {
      await expect(fxPool.connect(unionSigner).cashScanMint(loanTypeA, 0, SCAN_HASH)).to.be.reverted;
    });

    it("C3: fundCore not set reverts", async () => {
      // Deploy a fresh fxPool without fundCore
      const FxF = await ethers.getContractFactory("NilaFxPool");
      const fresh = await upgrades.deployProxy(FxF, [
        await erc20.getAddress(), await nin.getAddress(), await mockOracle.getAddress(),
        200, parseEther("999999"), 3600 * 24 * 7, 90 * 24 * 3600, await owner.getAddress(),
      ], { kind: "uups", initializer: "initialize" });
      await fresh.grantRole(keccak256(toUtf8Bytes("UNION_ROLE")), await unionSigner.getAddress());
      await expect(fresh.connect(unionSigner).cashScanMint(loanTypeA, 1000, SCAN_HASH)).to.be.reverted;
    });

    it("C4: per-union escrowDuration is used when set", async () => {
      const customDuration = 5 * DAY;
      // The FxPool queries getUnionEscrowDuration(msg.sender) where msg.sender is unionSigner.address
      // So we must configure the union entry keyed by unionSigner.address, not unionAddr
      const unionSignerAddr = await unionSigner.getAddress();
      // Set up minimal union config for unionSigner (create union in viewer first if needed)
      // For the duration check, only the storage entry matters
      await core.connect(owner).setReserveConfigForUnion(unionSignerAddr, 1000, 0, true, customDuration);

      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 1000n, SCAN_HASH);
      const eid = (await fxPool.nextEscrowId()) - 1n;
      const e = await fxPool.getEscrow(eid);
      const nowTs = await now(); // read AFTER mint so block.timestamp matches

      // Deadline should be ~5 days from now (not 3 days); allow 60s clock drift
      expect(Number(e.deadline)).to.be.closeTo(nowTs + customDuration - 1, 60);

      // Reset to 0 (use global fallback)
      await core.connect(owner).setReserveConfigForUnion(unionSignerAddr, 1000, 0, true, 0);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // resolveEscrowUsdt
  // ─────────────────────────────────────────────────────────────

  describe("resolveEscrowUsdt", function () {
    let escrowId;
    const USDT_MINT = 10_000_000_000n; // 10,000 USDT (6 dec) — plenty of buffer

    before(async () => {
      // Give unionSigner USDT and approve FxPool to pull it
      await erc20.connect(owner).mint(await unionSigner.getAddress(), USDT_MINT);
      await erc20.connect(unionSigner).approve(await fxPool.getAddress(), USDT_MINT);

      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 10000n, SCAN_HASH);
      escrowId = (await fxPool.nextEscrowId()) - 1n;
    });

    it("U1: happy path — union deposits USDT, escrow resolved, totalEscrowedNin decremented", async () => {
      const e = await fxPool.getEscrow(escrowId);
      const totalBefore   = await fxPool.totalEscrowedNin();
      const fxUsdtBefore  = await erc20.balanceOf(await fxPool.getAddress());
      const unionUsdtBefore = await erc20.balanceOf(await unionSigner.getAddress());

      // Compute expected USDT amount: ninAmount * 10^oracleDec / mintRate / 10^(18-usdtDec)
      const oracleDec = await fxPool.oracleDecimals();
      const usdtDec   = await fxPool.usdtDecimals();
      const usdAmount18 = (e.ninAmount * (10n ** oracleDec)) / e.mintRate;
      const expectedUsdt = usdAmount18 / (10n ** (18n - usdtDec));

      await expect(
        fxPool.connect(unionSigner).resolveEscrowUsdt(escrowId)
      ).to.emit(fxPool, "EscrowResolved").withArgs(escrowId, 2);

      const eAfter = await fxPool.getEscrow(escrowId);
      expect(eAfter.status).to.equal(2); // ResolvedUsdt

      expect(await fxPool.totalEscrowedNin()).to.equal(totalBefore - e.ninAmount);

      // FxPool received the USDT; union paid it
      expect(await erc20.balanceOf(await fxPool.getAddress())).to.equal(fxUsdtBefore + expectedUsdt);
      expect(await erc20.balanceOf(await unionSigner.getAddress())).to.equal(unionUsdtBefore - expectedUsdt);
    });

    it("U2: wrong union cannot resolve", async () => {
      // Create new escrow
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 1000n, SCAN_HASH);
      const eid = (await fxPool.nextEscrowId()) - 1n;
      await expect(fxPool.connect(rando).resolveEscrowUsdt(eid)).to.be.reverted;
    });

    it("U3: already resolved cannot resolve again", async () => {
      await expect(fxPool.connect(unionSigner).resolveEscrowUsdt(escrowId)).to.be.reverted;
    });

    it("U4: expired escrow cannot be resolved as Usdt", async () => {
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 500n, SCAN_HASH);
      const eid = (await fxPool.nextEscrowId()) - 1n;
      await timeTravel(THREE_DAYS + 1);
      await expect(fxPool.connect(unionSigner).resolveEscrowUsdt(eid)).to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // resolveEscrowCash (called by fund core)
  // ─────────────────────────────────────────────────────────────

  describe("resolveEscrowCash", function () {
    let escrowId;
    const ESCROW_INR = 9000n;
    const ESCROW_NIN = ESCROW_INR * 10n ** 18n;

    async function impersonateCore(fn) {
      const coreAddr = await core.getAddress();
      await network.provider.send("hardhat_setBalance", [coreAddr, "0xDE0B6B3A7640000"]);
      await network.provider.request({ method: "hardhat_impersonateAccount", params: [coreAddr] });
      const coreSigner = await ethers.getSigner(coreAddr);
      await fn(coreSigner);
      await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [coreAddr] });
    }

    before(async () => {
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, ESCROW_INR, SCAN_HASH);
      escrowId = (await fxPool.nextEscrowId()) - 1n;
    });

    it("R1: only fundCore can call", async () => {
      const partialAmount = ESCROW_NIN / 3n;
      await expect(fxPool.connect(rando).resolveEscrowCash(escrowId, partialAmount)).to.be.reverted;
      await expect(fxPool.connect(owner).resolveEscrowCash(escrowId, partialAmount)).to.be.reverted;
    });

    it("R2: partial resolve — escrow stays Active, ninAmount reduced, totalEscrowedNin decremented", async () => {
      const partialAmount = ESCROW_NIN / 3n; // resolve 1/3 of the escrow
      const totalBefore = await fxPool.totalEscrowedNin();

      await impersonateCore(async (coreSigner) => {
        await expect(
          fxPool.connect(coreSigner).resolveEscrowCash(escrowId, partialAmount)
        ).to.emit(fxPool, "EscrowResolved").withArgs(escrowId, 0); // status still 0 (Active)
      });

      const e = await fxPool.getEscrow(escrowId);
      expect(e.status).to.equal(0); // still Active
      expect(e.ninAmount).to.equal(ESCROW_NIN - partialAmount);
      expect(await fxPool.totalEscrowedNin()).to.equal(totalBefore - partialAmount);
    });

    it("R3: second partial resolve — consumes remaining amount, status becomes ResolvedCash", async () => {
      const e = await fxPool.getEscrow(escrowId);
      const remaining = e.ninAmount; // whatever is left
      const totalBefore = await fxPool.totalEscrowedNin();

      await impersonateCore(async (coreSigner) => {
        await expect(
          fxPool.connect(coreSigner).resolveEscrowCash(escrowId, remaining)
        ).to.emit(fxPool, "EscrowResolved").withArgs(escrowId, 1); // status = ResolvedCash
      });

      const eAfter = await fxPool.getEscrow(escrowId);
      expect(eAfter.status).to.equal(1); // ResolvedCash — fully consumed
      expect(eAfter.ninAmount).to.equal(0n);
      expect(await fxPool.totalEscrowedNin()).to.equal(totalBefore - remaining);
    });

    it("R4: fully resolved escrow cannot be resolved again", async () => {
      await impersonateCore(async (coreSigner) => {
        await expect(fxPool.connect(coreSigner).resolveEscrowCash(escrowId, 1n)).to.be.reverted;
      });
    });

    it("R5: amount exceeding escrow ninAmount reverts", async () => {
      // Create fresh escrow and try to over-resolve it
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 1000n, SCAN_HASH);
      const freshId = (await fxPool.nextEscrowId()) - 1n;
      const freshEscrow = await fxPool.getEscrow(freshId);
      await impersonateCore(async (coreSigner) => {
        await expect(
          fxPool.connect(coreSigner).resolveEscrowCash(freshId, freshEscrow.ninAmount + 1n)
        ).to.be.reverted;
      });
    });
  });

  // ─────────────────────────────────────────────────────────────
  // burnExpiredEscrow
  // ─────────────────────────────────────────────────────────────

  describe("burnExpiredEscrow", function () {
    let escrowId;
    let ninAmountEscrow;

    before(async () => {
      const inrValue = 2000n;
      ninAmountEscrow = inrValue * 10n ** 18n;
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, inrValue, SCAN_HASH);
      escrowId = (await fxPool.nextEscrowId()) - 1n;
      // Advance past deadline
      await timeTravel(THREE_DAYS + 10);
    });

    it("B1: isEscrowExpired returns true after deadline", async () => {
      expect(await fxPool.isEscrowExpired(escrowId)).to.equal(true);
    });

    it("B2: burnExpiredEscrow works permissionlessly, burns nIN, decrements totalEscrowedNin", async () => {
      const supplyBefore = await nin.totalSupply();
      const fundBalBefore = await nin.balanceOf(await core.getAddress());
      const totalBefore = await fxPool.totalEscrowedNin();

      await expect(
        fxPool.connect(rando).burnExpiredEscrow(escrowId)
      ).to.emit(fxPool, "EscrowBurned").withArgs(escrowId, ninAmountEscrow);

      const e = await fxPool.getEscrow(escrowId);
      expect(e.status).to.equal(3); // Burned
      expect(await nin.totalSupply()).to.equal(supplyBefore - ninAmountEscrow);
      expect(await nin.balanceOf(await core.getAddress())).to.equal(fundBalBefore - ninAmountEscrow);
      expect(await fxPool.totalEscrowedNin()).to.equal(totalBefore - ninAmountEscrow);
    });

    it("B3: not-yet-expired escrow cannot be burned", async () => {
      // Create fresh escrow with full 3-day window
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 100n, SCAN_HASH);
      const freshId = (await fxPool.nextEscrowId()) - 1n;
      await expect(fxPool.connect(rando).burnExpiredEscrow(freshId)).to.be.reverted;
    });

    it("B4: already burned escrow cannot be burned again", async () => {
      await expect(fxPool.connect(rando).burnExpiredEscrow(escrowId)).to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // burnExpiredEscrowBatch
  // ─────────────────────────────────────────────────────────────

  describe("burnExpiredEscrowBatch", function () {
    it("BB1: batch burns eligible, skips ineligible (not expired / already resolved)", async () => {
      // Create 3 escrows: 2 will expire, 1 will be resolved before
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 100n, SCAN_HASH);
      const eid0 = (await fxPool.nextEscrowId()) - 1n;
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 200n, SCAN_HASH);
      const eid1 = (await fxPool.nextEscrowId()) - 1n;
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 300n, SCAN_HASH);
      const eid2 = (await fxPool.nextEscrowId()) - 1n;

      // Resolve eid1 before expiry
      await fxPool.connect(unionSigner).resolveEscrowUsdt(eid1);

      // Expire eid0 and eid2
      await timeTravel(THREE_DAYS + 10);

      const supplyBefore = await nin.totalSupply();

      // Run batch: eid0 should burn, eid1 should skip (already resolved), eid2 should burn
      await expect(
        fxPool.connect(rando).burnExpiredEscrowBatch([eid0, eid1, eid2])
      ).to.emit(fxPool, "EscrowBurned");

      const e0 = await fxPool.getEscrow(eid0);
      const e1 = await fxPool.getEscrow(eid1);
      const e2 = await fxPool.getEscrow(eid2);

      expect(e0.status).to.equal(3); // Burned
      expect(e1.status).to.equal(2); // ResolvedUsdt (unchanged)
      expect(e2.status).to.equal(3); // Burned

      // nIN supply decreased by eid0.ninAmount + eid2.ninAmount (not eid1)
      const burned = e0.ninAmount + e2.ninAmount;
      expect(await nin.totalSupply()).to.equal(supplyBefore - burned);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // burnEscrowNin on GenericFundCore
  // ─────────────────────────────────────────────────────────────

  describe("burnEscrowNin on GenericFundCore", function () {
    it("E1: only fxPoolAddr can call burnEscrowNin", async () => {
      await expect(core.connect(rando).burnEscrowNin(unionAddr, loanTypeA, 1000n)).to.be.reverted;
      await expect(core.connect(owner).burnEscrowNin(unionAddr, loanTypeA, 1000n)).to.be.reverted;
    });

    it("E2: zero amount reverts", async () => {
      const fxAddr = await fxPool.getAddress();
      await network.provider.send("hardhat_setBalance", [fxAddr, "0xDE0B6B3A7640000"]);
      await network.provider.request({ method: "hardhat_impersonateAccount", params: [fxAddr] });
      const fxSigner = await ethers.getSigner(fxAddr);
      await expect(core.connect(fxSigner).burnEscrowNin(unionAddr, loanTypeA, 0)).to.be.reverted;
      await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [fxAddr] });
    });

    it("E3: fxPool can call burnEscrowNin and transfers nIN from core to fxPool", async () => {
      const amount = parseEther("100");
      const coreBefore = await nin.balanceOf(await core.getAddress());
      const fxBefore = await nin.balanceOf(await fxPool.getAddress());

      const fxAddr = await fxPool.getAddress();
      await network.provider.send("hardhat_setBalance", [fxAddr, "0xDE0B6B3A7640000"]);
      await network.provider.request({ method: "hardhat_impersonateAccount", params: [fxAddr] });
      const fxSigner = await ethers.getSigner(fxAddr);
      // unionAddr/loanTypeA has cash from prior cashScanMint calls; burning partial amount
      await core.connect(fxSigner).burnEscrowNin(unionAddr, loanTypeA, amount);
      await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [fxAddr] });

      expect(await nin.balanceOf(await core.getAddress())).to.equal(coreBefore - amount);
      expect(await nin.balanceOf(await fxPool.getAddress())).to.equal(fxBefore + amount);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // drawLoanWithVoucher with escrowId
  // ─────────────────────────────────────────────────────────────

  describe("drawLoanWithVoucher with escrowId", function () {
    let activeEscrowId;
    // Escrow sized to exactly match the loan so a single draw fully resolves it (status→1)
    const BORROW_AMOUNT = parseEther("1000");
    const ESCROW_INR_D  = 1000n; // 1000 INR → 1000e18 nIN = BORROW_AMOUNT exactly

    before(async () => {
      // Create a fresh escrow sized exactly to the loan amount
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, ESCROW_INR_D, SCAN_HASH);
      activeEscrowId = (await fxPool.nextEscrowId()) - 1n;
    });

    it("D1: fast-draw with escrowId fully resolves escrow (status→ResolvedCash)", async () => {
      const loanId = keccak256(toUtf8Bytes("D1-escrow-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());

      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId,
        maxAmount: BORROW_AMOUNT,
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: true,
        escrowId: activeEscrowId,
        nonce,
      });

      const escrowBefore = await fxPool.getEscrow(activeEscrowId);
      expect(escrowBefore.status).to.equal(0); // Active

      await expect(
        core.connect(borrower1).drawLoanWithVoucher(
          unionAddr, loanId, loanTypeA, BORROW_AMOUNT, 1200, (await now()) + 30 * DAY,
          ethers.ZeroHash, sig, BORROW_AMOUNT, 900, true,
          activeEscrowId, 0, nonce
        )
      ).to.emit(core, "LoanClaimed");

      const escrowAfter = await fxPool.getEscrow(activeEscrowId);
      expect(escrowAfter.status).to.equal(1); // ResolvedCash
    });

    it("D2: escrowId=0 does not attempt resolution (no revert)", async () => {
      const loanId = keccak256(toUtf8Bytes("D2-no-escrow-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());

      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId,
        maxAmount: BORROW_AMOUNT,
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: true,
        escrowId: 0n,
        nonce,
      });

      await expect(
        core.connect(borrower1).drawLoanWithVoucher(
          unionAddr, loanId, loanTypeA, BORROW_AMOUNT, 1200, (await now()) + 30 * DAY,
          ethers.ZeroHash, sig, BORROW_AMOUNT, 900, true,
          0n, 0, nonce
        )
      ).to.emit(core, "LoanClaimed");
    });

    it("D3: nonce replay protection — reusing same nonce reverts", async () => {
      const nonce = 0n; // stale nonce (borrower1 already has higher nonce)
      const loanId = keccak256(toUtf8Bytes("D3-replay-loan"));

      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId,
        maxAmount: BORROW_AMOUNT,
        minRateBP: 900,
        loanType: loanTypeA,
        nonce,
      });

      await expect(
        core.connect(borrower1).drawLoanWithVoucher(
          unionAddr, loanId, loanTypeA, BORROW_AMOUNT, 1200, (await now()) + 30 * DAY,
          ethers.ZeroHash, sig, BORROW_AMOUNT, 900, true,
          0n, 0, nonce
        )
      ).to.be.revertedWithCustomError(core, "BadNonce");
    });

    it("D4: sosDate is stored on loan", async () => {
      const loanId = keccak256(toUtf8Bytes("D4-sosdate-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());
      const testSosDate = 1_700_000_000; // arbitrary unix ts

      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId,
        maxAmount: BORROW_AMOUNT,
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: true,
        sosDate: testSosDate,
        nonce,
      });

      await core.connect(borrower1).drawLoanWithVoucher(
        unionAddr, loanId, loanTypeA, BORROW_AMOUNT, 1200, (await now()) + 30 * DAY,
        ethers.ZeroHash, sig, BORROW_AMOUNT, 900, true,
        0n, testSosDate, nonce
      );

      const loan = await core.loans(unionAddr, loanId);
      expect(loan.sosDate).to.equal(testSosDate);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // AcceptLoan with escrowId
  // ─────────────────────────────────────────────────────────────

  describe("AcceptLoan with escrowId", function () {
    let pendingLoanId;
    let acceptEscrowId;
    let leader;

    before(async () => {
      // Set up a leader
      leader = rando;
      await roles.connect(owner).setLeader(unionAddr, await leader.getAddress(), true);

      // Create a fresh escrow sized exactly to the pending loan amount (500 INR → 500e18 nIN)
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, 500n, SCAN_HASH);
      acceptEscrowId = (await fxPool.nextEscrowId()) - 1n;

      // Draw a pending loan (fastDraw=false) — escrow resolved on AcceptLoan, not here
      pendingLoanId = keccak256(toUtf8Bytes("AL-pending-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());

      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId: pendingLoanId,
        maxAmount: parseEther("500"),
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: false,
        escrowId: 0n,
        nonce,
      });

      await core.connect(borrower1).drawLoanWithVoucher(
        unionAddr, pendingLoanId, loanTypeA, parseEther("500"), 1200, (await now()) + 30 * DAY,
        ethers.ZeroHash, sig, parseEther("500"), 900, false,
        0n, 0, nonce
      );
    });

    it("AL1: AcceptLoan with escrowId fully resolves escrow (status→ResolvedCash)", async () => {
      const escrowBefore = await fxPool.getEscrow(acceptEscrowId);
      expect(escrowBefore.status).to.equal(0); // Active

      await expect(
        core.connect(leader).AcceptLoan(unionAddr, pendingLoanId, acceptEscrowId)
      ).to.emit(core, "LoanAccepted");

      const escrowAfter = await fxPool.getEscrow(acceptEscrowId);
      expect(escrowAfter.status).to.equal(1); // ResolvedCash — fully consumed
    });

    it("AL2: AcceptLoan with escrowId=0 does not attempt resolution", async () => {
      // Create another pending loan
      const loanId2 = keccak256(toUtf8Bytes("AL2-pending-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId: loanId2,
        maxAmount: parseEther("200"),
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: false,
        nonce,
      });

      await core.connect(borrower1).drawLoanWithVoucher(
        unionAddr, loanId2, loanTypeA, parseEther("200"), 1200, (await now()) + 30 * DAY,
        ethers.ZeroHash, sig, parseEther("200"), 900, false,
        0n, 0, nonce
      );

      await expect(
        core.connect(leader).AcceptLoan(unionAddr, loanId2, 0n)
      ).to.emit(core, "LoanAccepted");
    });
  });

  // ─────────────────────────────────────────────────────────────
  // Integration: full cash-scan lifecycle
  // ─────────────────────────────────────────────────────────────

  describe("Integration: full lifecycle", function () {
    it("I1: scan → draw loan → escrow fully resolved → nIN supply unchanged", async () => {
      // Escrow sized exactly to the loan amount so one draw fully consumes it
      const loanNin = parseEther("1000");  // 1000 nIN
      const inrValue = 1000n;              // 1000 INR → 1000e18 nIN (1:1)
      const ninAmount = inrValue * 10n ** 18n;
      const supplyBefore = await nin.totalSupply();

      // 1) Scan cash → mint nIN to fund, credit junior market
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, inrValue, SCAN_HASH);
      const eid = (await fxPool.nextEscrowId()) - 1n;
      expect(await nin.totalSupply()).to.equal(supplyBefore + ninAmount);

      // 2) Draw loan for the full escrow amount → fully resolves escrow (status→1)
      const loanId = keccak256(toUtf8Bytes("I1-lifecycle-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId,
        maxAmount: loanNin,
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: true,
        escrowId: eid,
        nonce,
      });

      await core.connect(borrower1).drawLoanWithVoucher(
        unionAddr, loanId, loanTypeA, loanNin, 1200, (await now()) + 30 * DAY,
        ethers.ZeroHash, sig, loanNin, 900, true,
        eid, 0, nonce
      );

      // 3) Escrow fully consumed (status=1), nIN supply unchanged (no burn)
      const e = await fxPool.getEscrow(eid);
      expect(e.status).to.equal(1); // ResolvedCash — fully consumed
      expect(e.ninAmount).to.equal(0n);
      expect(await nin.totalSupply()).to.equal(supplyBefore + ninAmount); // unchanged
    });

    it("I2: scan → 3 days pass → burnExpiredEscrow → nIN supply decreases", async () => {
      const inrValue = 5000n;
      const ninAmount = inrValue * 10n ** 18n;
      const supplyBefore = await nin.totalSupply();

      // 1) Scan cash → mint nIN to fund
      await fxPool.connect(unionSigner).cashScanMint(loanTypeA, inrValue, SCAN_HASH);
      const eid = (await fxPool.nextEscrowId()) - 1n;
      expect(await nin.totalSupply()).to.equal(supplyBefore + ninAmount);

      // 2) 3 days pass with no farmer showing up
      await timeTravel(THREE_DAYS + 1);

      // 3) Anyone can burn the expired escrow
      await expect(fxPool.connect(rando).burnExpiredEscrow(eid))
        .to.emit(fxPool, "EscrowBurned");

      // 4) nIN supply is back to before
      expect(await nin.totalSupply()).to.equal(supplyBefore);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ABI check: transferLoan removed
  // ─────────────────────────────────────────────────────────────

  describe("transferLoan removed", function () {
    it("T1: GenericFundCore ABI does not contain transferLoan", async () => {
      const fragments = core.interface.fragments;
      const names = fragments.map(f => f.name);
      expect(names).to.not.include("transferLoan");
    });

    it("T2: GenericFundCore ABI does not contain LoanTransferred event", async () => {
      const fragments = core.interface.fragments;
      const eventNames = fragments
        .filter(f => f.type === "event")
        .map(f => f.name);
      expect(eventNames).to.not.include("LoanTransferred");
    });
  });

  // ─────────────────────────────────────────────────────────────
  // LoanClaimed event structure
  // ─────────────────────────────────────────────────────────────

  describe("LoanClaimed event", function () {
    it("LC1: event includes sosDate and drawdownTs fields", async () => {
      const loanId = keccak256(toUtf8Bytes("LC1-event-loan"));
      const nonce = await core.nonces(await borrower1.getAddress());
      const testSosDate = 1_710_000_000;

      const sig = await signVoucher({
        oracle: owner,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionAddr,
        loanId,
        maxAmount: parseEther("500"),
        minRateBP: 900,
        loanType: loanTypeA,
        fastDraw: true,
        sosDate: testSosDate,
        nonce,
      });

      const tx = await core.connect(borrower1).drawLoanWithVoucher(
        unionAddr, loanId, loanTypeA, parseEther("500"), 1200, (await now()) + 30 * DAY,
        ethers.ZeroHash, sig, parseEther("500"), 900, true,
        0n, testSosDate, nonce
      );
      const receipt = await tx.wait();
      const loanClaimedEvent = receipt.logs.find(
        log => {
          try { return core.interface.parseLog(log)?.name === "LoanClaimed"; } catch { return false; }
        }
      );
      expect(loanClaimedEvent).to.not.be.undefined;
      const parsed = core.interface.parseLog(loanClaimedEvent);
      // sosDate is arg index 6, drawdownTs is arg 7, fastDraw is arg 8
      expect(Number(parsed.args[6])).to.equal(testSosDate); // sosDate
      expect(Number(parsed.args[7])).to.be.gt(0);          // drawdownTs (for fast draw)
      expect(parsed.args[8]).to.equal(true);               // fastDraw
    });
  });
});
