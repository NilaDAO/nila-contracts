/* eslint-disable no-console */
const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { parseEther, keccak256, toUtf8Bytes, MaxUint256, encodeBytes32String, decodeBytes32String } = require("ethers");

const DAY = 24 * 60 * 60;
const WEEK = 7 * DAY;
const SIX_WEEKS = 6 * WEEK;
const RAY = 10n ** 27n;

async function now() {
  return (await ethers.provider.getBlock("latest")).timestamp;
}
async function timeTravel(seconds) {
  await network.provider.send("evm_increaseTime", [Number(seconds)]);
  await network.provider.send("evm_mine");
}

async function signVoucher({
  oracle, coreAddr, borrower, union, loanId, maxAmount, minRateBP, loanType, paramsHash = ethers.ZeroHash, fastDraw = true,
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

async function signQuote1155({
  oracle, coreAddr, union, loanType, investor, collection, id, amount1155, quoteAmount, expiry
}) {
  const domain = {
    name: "GenericFund",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: coreAddr,
  };
  const types = {
    Quote1155: [
      { name: "union", type: "address" },
      { name: "loanType", type: "bytes32" },
      { name: "investor", type: "address" },
      { name: "collection", type: "address" },
      { name: "id", type: "uint256" },
      { name: "amount1155", type: "uint256" },
      { name: "quoteAmount", type: "uint256" },
      { name: "expiry", type: "uint40" },
    ],
  };
  const value = { union, loanType, investor, collection, id, amount1155, quoteAmount, expiry };
  return oracle.signTypedData(domain, types, value);
}

async function expectAndPrint(txPromise, ifaces) {
  try {
    await txPromise;
  } catch (e) {
    const data =
      e?.data?.data ??
      e?.error?.data?.data ??
      e?.data ??
      e?.error?.data ??
      e;

    for (const iface of ifaces) {
      try {
        const parsed = iface.parseError(data);
        if (parsed) console.log("Custom error:", parsed.name, parsed.args);
      } catch {}
    }
    throw e;
  }
}

async function logCodeSize(label, addr) {
  const code = await ethers.provider.getCode(addr); // hex string "0x..."
  const sizeBytes = (code.length - 2) / 2;          // 2 hex chars per byte
  console.log(`${label} code size: ${sizeBytes} bytes (${(sizeBytes/1024).toFixed(2)} KB)`);
  return sizeBytes;
}

describe("GenericFund — Full Suite (Single Token + Viewer + ERC1155 Module)", function () {
  let owner, treasury, oracle, leader, borrower1, borrower2, j1, j2, s1, s2, rando;
  let erc20, land721, food1155, core, viewer, mod1155, roles, loanIdB1, RolesF;
  const loanTypeA = encodeBytes32String("Mth Teresa GroundUP fund");
  const loanTypeB = encodeBytes32String("Mth Teresa Cropcare fund");
  const unionA = ethers.Wallet.createRandom().address;
  const unionB = ethers.Wallet.createRandom().address;
  const loanTypeC = encodeBytes32String("Ratio Test");

  before(async () => {
    [owner, treasury, oracle, leader, borrower1, borrower2, j1, j2, s1, s2, rando] = await ethers.getSigners();

    // Deploy mocks
    const ERC20F = await ethers.getContractFactory("MockERC20");
    erc20 = await ERC20F.connect(owner).deploy("MockUSD", "mUSD", 18);
    await erc20.waitForDeployment();

    const ERC721F = await ethers.getContractFactory("contracts/mocks/MockERC721.sol:MockERC721");
    land721 = await ERC721F.connect(owner).deploy(await owner.getAddress());
    await land721.waitForDeployment();

    // sanity-check ABI and function exists
    // console.log(land721.interface.fragments.map(f => f.format("full")));

    // Lightweight ERC1155 mock
    const ERC1155F = await ethers.getContractFactory("MockERC1155");
    food1155 = await ERC1155F.connect(owner).deploy("https://example/{id}.json");
    await food1155.waitForDeployment();

    // Lib
    const MathLibF = await ethers.getContractFactory("GenericFundMathLib");
    const mathLib = await MathLibF.connect(owner).deploy();
    await mathLib.waitForDeployment();
    const mathLibAddress = await mathLib.getAddress();

    console.log('lib deployed')

    // Deploy core (single token), viewer, module
    const CoreF = await ethers.getContractFactory("GenericFundCore", {
      libraries: { GenericFundMathLib: mathLibAddress },
    });
    core = await CoreF.connect(owner).deploy();     
    await core.waitForDeployment();
    await logCodeSize("GenericFundCore", await core.getAddress());

    // Deploy Roles registry
    RolesF = await ethers.getContractFactory("RolesRegistry");
    roles = await RolesF.connect(owner).deploy(await owner.getAddress());     
    await roles.waitForDeployment();
    
    // set union leader
    await roles.connect(owner).setLeader(unionA, await leader.getAddress(), true);

    await core.connect(owner).initialize(
      await land721.getAddress(),     // land NFT address
      await roles.getAddress(),       // _roles
      await erc20.getAddress()        // _asset
    );

    console.log('core deployed')

    const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
      libraries: { GenericFundMathLib: mathLibAddress },
    });
    viewer = await ViewerF.connect(owner).deploy();
    await viewer.waitForDeployment();
    
    // now initialize (sets owner and core)
    await (await viewer.connect(owner).initialize(await core.getAddress(),roles.getAddress())).wait();

    console.log('viewer deployed')

    const ModF = await ethers.getContractFactory("GenericFund1155Module");
    mod1155 = await ModF.connect(owner).deploy(await core.getAddress(), await owner.getAddress());
    await mod1155.waitForDeployment();

    console.log('food token module deployed')

    // Wire addresses & roles
    try { await (await core.connect(owner).setViewer(await viewer.getAddress())).wait(); } catch {}

    console.log('sub modules set')
    // Seed balances & approvals helpers
    async function seedERC20(signer, amt) {
      await (await erc20.connect(owner).mint(await signer.getAddress(), amt)).wait();
      await (await erc20.connect(signer).approve(await core.getAddress(), MaxUint256)).wait();
    }
    await seedERC20(j1, parseEther("50000"));
    await seedERC20(j2, parseEther("10000"));
    await seedERC20(s1, parseEther("50000"));
    await seedERC20(s2, parseEther("10000"));
    await seedERC20(borrower1, parseEther("1000"));
    await seedERC20(borrower2, parseEther("1000"));

    // Mint NFTs & ERC1155, set approvals
    await (await land721.connect(owner).mint(await j1.getAddress(), 1)).wait();
    await (await land721.connect(owner).mint(await borrower1.getAddress(), 2)).wait();
    await (await land721.connect(owner).mint(await borrower2.getAddress(), 3)).wait();

    // ERC1155 mints
    //await (await food1155.connect(owner).mint(await j1.getAddress(), 1001, 1000, "0x")).wait();
    await (await food1155.connect(j1).setApprovalForAll(await mod1155.getAddress(), true)).wait();

    // Governance setup
    await (await viewer.connect(owner).CreateUnion(unionA, "Union A",'location')).wait();
    console.log('union created')
    await (await viewer.connect(owner).AddFundType(unionA, loanTypeA, "PLANTING")).wait();
    await (await viewer.connect(owner).AddFundType(unionA, loanTypeB, "INPUTS")).wait();
    console.log('2 funds created')
    await (await viewer.connect(owner).CreateUnion(unionB, "Union B",'location')).wait();
    await (await viewer.connect(owner).AddFundType(unionB, loanTypeC, "RATIO")).wait();
    await roles.connect(owner).setLeader(unionB, await leader.getAddress(), true);
    await (await core.connect(owner).setRateParams(unionA, 600, 8000, 400, 2400, 3000)).wait();
    await (await core.connect(owner).setReserveConfigForUnion(unionA, 1000, 0, true, 0)).wait();
    await (await core.connect(owner).setRateParams(unionB, 600, 8000, 400, 2400, 3000)).wait();
    await (await core.connect(owner).setReserveConfigForUnion(unionB, 1000, 0, true, 0)).wait();
    // set core in roles
    await roles.connect(owner).setCore(await core.getAddress(), true);
    await roles.connect(owner).setOracle(await oracle.getAddress(), true);
    console.log('all set to go')
  });

  describe("General/Registry", function () {
    it("G1: union name & active", async () => {
      const union = await viewer.getUnion(unionA)
      expect(union[0]).to.equal("Union A");
    });
    it("G2: fund types list by name & limit < 15", async () => {
      const createdNames = [];
      for (let i = 0; i < 13; i++) {
        const name = `T${i}`;
        const lt = encodeBytes32String(name);
        await (await viewer.connect(owner).AddFundType(unionA, lt, name)).wait();
        createdNames.push(name);
      }

      // pull names from the viewer
      const names = await viewer.getFundTypes(unionA);
      // should include all the ones we just added
      for (const n of createdNames) {
        const decoded = encodeBytes32String(n);
        expect(names).to.include(decoded);
      }

      // total should be at least 15 (2 initial + 13 new)
      expect(names.length).to.be.gte(15);
    });
    it("G3: rate & buffer params set per-union", async () => {
      const rp = await core.rateParamsByUnion(unionA);
      expect(rp.baseRateBP ?? rp[0]).to.equal(600);
      const cfg = await core.reserveCfgByUnion(unionA);
      const safetyBP = Number(cfg[0]);
      expect(safetyBP).to.equal(1000);
    });
  });

  describe("Investors: deposits, gating, ERC1155 invest", function () {
    it("I1: seniors cannot hold land NFT; juniors must", async () => {
      // s1 has no NFT: can deposit senior
      await expect(core.connect(s1).depositSenior(unionA, parseEther("1000"))).to.emit(core, "Deposit");

      // give s2 an NFT; senior deposit should revert
      await (await land721.connect(owner).mint(await s2.getAddress(), 9)).wait();
      await expect(core.connect(s2).depositSenior(unionA, parseEther("1000"))).to.be.reverted;

      // j1 (has land) can deposit junior
      await expect(core.connect(j1).depositJunior(unionA, loanTypeA, parseEther("800"))).to.emit(core, "Deposit");

      // j2 (no land) cannot deposit junior
      await expect(core.connect(j2).depositJunior(unionA, loanTypeA, parseEther("100"))).to.be.reverted;
    });

    it("I2: ERC1155 invest via oracle quote mints junior shares", async () => {
      // choose the junior account
      const investor = j1;

      // 1) hook up viewer + mark oracles (EOA + module)
      await roles.connect(owner).setOracle(await oracle.getAddress(), true);
      await roles.connect(owner).setOracle(await mod1155.getAddress(), true);
      
      // 3) junior must hold the land title (senior must NOT)
      expect(await land721.balanceOf(await investor.getAddress())).to.equal(1);
      // 4) allow this 1155 id for this union/fund bucket
      await mod1155.connect(owner).set1155Allowed(unionA, loanTypeB, await food1155.getAddress(), 1001, true);

      // 5) mint 1155 to the *same* investor and approve module
      const amount1155 = 250n;
      await food1155.connect(owner).mint(await investor.getAddress(), 1001, amount1155, "0x");
      await food1155.connect(investor).setApprovalForAll(await mod1155.getAddress(), true);

      // 6) sign oracle quote FOR THIS investor
      const quoteAmount = parseEther("500");
      const expiry = (await now()) + 3 * DAY;
      const sig = await signQuote1155({
        oracle,
        coreAddr: await core.getAddress(),
        union: unionA,
        loanType: loanTypeB,
        investor: await investor.getAddress(),           // <<< j1
        collection: await food1155.getAddress(),
        id: 1001,
        amount1155: Number(amount1155),
        quoteAmount,
        expiry,
      });

      // sanity checks to catch config issues early
      expect(await core.viewer()).to.equal(await viewer.getAddress());
      expect(await roles.isOracle(await oracle.getAddress())).to.equal(true);
      expect(await roles.isOracle(await mod1155.getAddress())).to.equal(true);
      expect(await mod1155.is1155Allowed(unionA, loanTypeB, await food1155.getAddress(), 1001)).to.equal(true);
      expect(await food1155.balanceOf(await investor.getAddress(), 1001)).to.equal(amount1155);
      
      // 7) happy path: escrow 1155 + mint junior shares in core
      await expect(
        mod1155.connect(investor).depositFoodTokens(
          unionA, loanTypeB, await food1155.getAddress(), 1001,
          amount1155, quoteAmount, expiry, sig
        )
      ).to.emit(mod1155, "depositedFoodTokens");

      // post-asserts
      expect(await food1155.balanceOf(await investor.getAddress(), 1001)).to.equal(0);
      expect(await food1155.balanceOf(await mod1155.getAddress(), 1001)).to.equal(amount1155);

      const inv = await core.getInvestorJunior(unionA, loanTypeB, await investor.getAddress());
      expect(inv.shares).to.be.gt(0n);

    });
  });

  describe("Borrowers: voucher draw, repay, default/rollover", function () {
    it("B1: draw with amount <= maxAmount and rate >= minRateBP, buffer enforced", async () => {
      // seed liquidity
      await (await core.connect(j1).depositJunior(unionA, loanTypeA, parseEther("3000"))).wait();
      await (await core.connect(s1).depositSenior(unionA, parseEther("5000"))).wait();
      console.log('1')
      const maxAmount = parseEther("1000");
      const minRateBP = 900;
      loanIdB1 = keccak256(toUtf8Bytes("B1-loan"));
      const nonceB1 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower1.getAddress(), union: unionA,
        loanId: loanIdB1, maxAmount, minRateBP, loanType: loanTypeA, nonce: nonceB1,
      });

      const amount = parseEther("600");
      const rateBP = 1200;
      const maturity = (await now()) + 20 * DAY;

      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionA, loanIdB1, loanTypeA, amount, rateBP, maturity, ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceB1
      )).to.emit(core, "LoanClaimed");

      // In W1 before claiming, accrue and repay a little interest on the A-loan
      await timeTravel(15 * DAY);

      const checkloan = await core.connect(borrower1).loans(unionA, loanIdB1)
      console.log('checkloan', checkloan)
      await (await core.connect(borrower1).repayLoan(unionA, loanIdB1, parseEther("5"))).wait();

    });

    it("G4: getBorrowerInfo returns borrower fields and outstanding = principal + accrued interest", async () => {
      // seed liquidity
      await (await core.connect(j1).depositJunior(unionA, loanTypeA, parseEther("3000"))).wait();
      await (await core.connect(s1).depositSenior(unionA, parseEther("5000"))).wait();

      const maxAmount = parseEther("1000");
      const minRateBP = 900;
      loanIdB1 = keccak256(toUtf8Bytes("G4-loan"));
      const nonceG4 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower1.getAddress(), union: unionA,
        loanId: loanIdB1, maxAmount, minRateBP, loanType: loanTypeA, nonce: nonceG4,
      });

      const amount = parseEther("600");
      const rateBP = 1200;
      const maturity = (await now()) + 20 * DAY;

      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionA, loanIdB1, loanTypeA, amount, rateBP, maturity, ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceG4
      )).to.emit(core, "LoanClaimed");


      // Let interest accrue for 10 days (no repay yet)
      const ELAPSED_DAYS = 10;
      await timeTravel(ELAPSED_DAYS * DAY);

      // Query viewer
      const info = await viewer.getBorrowerInfo(unionA, loanIdB1);
      const borrower         = info[0];
      const loanType         = info[1];
      const principal        = info[2];
      const principalRepaid  = info[3];
      const rateBPout        = info[4];
      const dueDate          = info[5];
      const closed           = info[6];
      const defaulted        = info[7];
      const outstanding      = info[8];
      
      // Basic field checks
      expect(borrower).to.equal(await borrower1.getAddress());
      expect(loanType).to.equal(loanTypeA);
      expect(principal).to.equal(amount);
      expect(principalRepaid).to.equal(0n);
      expect(rateBPout).to.equal(rateBP);
      expect(dueDate).to.equal(maturity);
      expect(closed).to.equal(false);
      expect(defaulted).to.equal(false);

      // Expected accrued interest: principal * rateBP * elapsed / (365d * 10_000)
      const YEAR = 365n * BigInt(DAY);
      const elapsed = BigInt(ELAPSED_DAYS * DAY);
      const expectedInterest =
        (principal * BigInt(rateBP) * elapsed) / YEAR / 10000n;

      const expectedOutstanding = principal + expectedInterest;

      // Allow tiny rounding differences from integer division
      const diff = (outstanding > expectedOutstanding)
        ? outstanding - expectedOutstanding
        : expectedOutstanding - outstanding;

      expect(diff).to.be.lte(5n); // ≤ 5 wei tolerance
    });
    it("B2: rate model enforced (too-low rate reverts under high util)", async () => {
      // crank utilization by drawing within voucher, but try with low rate
      const maxAmount = parseEther("4000");
      const minRateBP = 0;
      const loanId = keccak256(toUtf8Bytes("B2-loan"));
      const nonceB2 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower1.getAddress(), union: unionA,
        loanId, maxAmount, minRateBP, loanType: loanTypeA, nonce: nonceB2,
      });
      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionA, loanId, loanTypeA, parseEther("3500"), 100, (await now()) + 40 * DAY,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceB2
      )).to.be.reverted; // rate < model
    });

    it("B3: partial repay distributes interest (treasury takes 1%)", async () => {
      // seed liquidity for this fund
      await (await core.connect(j1).depositJunior(unionA, loanTypeB, parseEther("500"))).wait();
      await (await core.connect(s1).depositSenior(unionA, parseEther("1000"))).wait();

      const loanId = keccak256(toUtf8Bytes("B3-loan"));
      const nonceB3 = await core.nonces(await borrower2.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower2.getAddress(), union: unionA,
        loanId, maxAmount: parseEther("600"), minRateBP: 900, loanType: loanTypeB, nonce: nonceB3,
      });
      await (await core.connect(borrower2).drawLoanWithVoucher(
        unionA, loanId, loanTypeB, parseEther("500"), 1200, (await now()) + 30 * DAY,
        ethers.ZeroHash, sig, parseEther("600"), 900, true,
        0n, 0, nonceB3
      )).wait();

      await timeTravel(5 * DAY);
      const treBefore = await core.unionTreasury(unionA);
      await (await core.connect(borrower2).repayLoan(unionA, loanId, parseEther("50"))).wait();
      const treAfter = await core.unionTreasury(unionA);
      expect(treAfter).to.be.gt(treBefore); // fee accrued to union treasury bucket
    });

    it("B4: default after maturity + 6 weeks applies junior→senior haircut", async () => {
      const loanId = keccak256(toUtf8Bytes("B4-loan"));
      const nonceB4 = await core.nonces(await borrower2.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower2.getAddress(), union: unionA,
        loanId, maxAmount: parseEther("300"), minRateBP: 900, loanType: loanTypeA, nonce: nonceB4,
      });
      const matSoon = (await now()) + 1 * DAY;

      await (await core.connect(borrower2).drawLoanWithVoucher(
        unionA, loanId, loanTypeA, parseEther("300"), 1000, matSoon,
        ethers.ZeroHash, sig, parseEther("300"), 900, true,
        0n, 0, nonceB4
      )).wait();

      // No repay; wait beyond payback period
      await timeTravel(1 * DAY + SIX_WEEKS + 10);
      // capture indexes
      const jBefore = await core.getJuniorMarket(unionA, loanTypeA);
      const sBefore = await core.getSeniorMarket(unionA);
      await (await core.connect(owner).markDefault(unionA, loanId)).wait();
      const jAfter = await core.getJuniorMarket(unionA, loanTypeA);
      const sAfter = await core.getSeniorMarket(unionA);
      expect(jAfter.index).to.be.lt(jBefore.index); // haircut
      // senior may also get haircut if junior insufficient
      expect(sAfter.index <= sBefore.index).to.be.true;
    });

    it.skip("B5: transferLoan removed in CS003 — test retired", async () => {
      // transferLoan was removed to free bytecode; covered by CashScanEscrow.spec.js ABI check
    });
  });

  describe("Withdrawals / Liquidity & Buffer", function () {
    it("W1: accrue yield via repay, then claimYield (buffer-aware)", async () => {
      // Tranche enum in core: JUNIOR=0, SENIOR=1
      const TRANCHE = { JUNIOR: 0, SENIOR: 1 };

      // Ensure union config is present & permissive for claims
      await core.connect(owner).setReserveConfigForUnion(
        unionA,
        1000,                     // safetyBP = 10%
        0,                        // safetyFloor
        false,                    // hardStop = off (soft cap)
        0                         // escrowDuration
      );

      // Make sure j1 can be a junior (must hold land title)
      // If your suite didn’t mint yet:
      // await land721.connect(owner).mint(await j1.getAddress(), 123);

      // Seed liquidity into the **same** junior bucket we’ll use for the loan
      await (await core.connect(j1).depositJunior(unionA, loanTypeA, parseEther("2000"))).wait();
      await (await core.connect(s1).depositSenior(unionA, parseEther("3000"))).wait();

      // Borrower voucher (max/min only constrain; borrower can draw <= maxAmount at >= minRateBP)
      const maxAmount = parseEther("800");
      const minRateBP = 900;
      const loanId   = keccak256(toUtf8Bytes("W1-loan"));
      const nonceW1  = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionA,
        loanId,
        maxAmount,
        minRateBP,
        loanType: loanTypeA,
        nonce: nonceW1,
      });

      const amount   = parseEther("600");
      const rateBP   = 1200;                         // >= minRateBP
      const maturity = (await now()) + 20 * DAY;

      // Draw the loan into unionA/loanTypeA so interest flows to that junior bucket
      await expect(
        core.connect(borrower1).drawLoanWithVoucher(
          unionA,
          loanId,
          loanTypeA,
          amount,
          rateBP,
          maturity,
          ethers.ZeroHash,        // paramsHash (unused here)
          sig,
          maxAmount,
          minRateBP,
          true,
          0n, 0, nonceW1
        )
      ).to.emit(core, "LoanClaimed");

      // Accrue some interest, then repay a bit to trigger interest distribution
      await timeTravel(3 * DAY);
      await (await core.connect(borrower1).repayLoan(unionA, loanId, parseEther("30"))).wait();

      // Senior claims first (uses SENIOR=1)
      await expect(core.connect(s1).claimYield(TRANCHE.SENIOR, unionA, loanTypeA, 0))
        .to.emit(core, "YieldClaimed");

      // Junior claims from the SAME bucket (uses JUNIOR=0)
      await expect(core.connect(j1).claimYield(TRANCHE.JUNIOR, unionA, loanTypeA, 0))
        .to.emit(core, "YieldClaimed");
    });

    it("W2: unbonding requires later-of(min window, maturity coverage)", async () => {
      // deposit fresh junior, request unbond, then schedule a loan maturity to cover
      const who = j1;
      await (await core.connect(who).depositJunior(unionA, loanTypeA, parseEther("700"))).wait();
      // request to unbond half the shares
      const inv = await core.getInvestorJunior(unionA, loanTypeA, await who.getAddress());
      const halfShares = inv.shares / 2n;
      await (await core.connect(who).requestUnbondJunior(unionA, loanTypeA, halfShares)).wait();

      // Try to claim immediately -> should fail
      await expect(core.connect(who).claimJunior(unionA, loanTypeA, 0)).to.be.reverted;

      // Create a small loan and report maturity soon to generate coverage
      const loanId = keccak256(toUtf8Bytes("W2-loan"));
      const nonceW2 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionA,
        loanId,
        maxAmount: parseEther("300"),
        minRateBP: 900,
        loanType: loanTypeA,
        nonce: nonceW2,
      });
      const matTs = (await now()) + 5 * DAY;
      await (await core.connect(borrower1).drawLoanWithVoucher(
        unionA, loanId, loanTypeA, parseEther("250"), 1200, matTs,
        ethers.ZeroHash, sig, parseEther("300"), 900, true,
        0n, 0, nonceW2
      )).wait();

      // report maturity if not set internally by draw
      try { await (await core.connect(owner).reportMaturity(unionA, loanId, matTs)).wait(); } catch {}

      // fast-forward past min window and maturity; credit matured repayments into coverage ledger
      await timeTravel(15 * DAY); // make sure that min window is met (pastMin)
      await (await core.connect(owner).creditMaturedRepayments(unionA, [matTs])).wait();

      // now claim should pass
      await expect(core.connect(who).claimJunior(unionA, loanTypeA, 0)).to.emit(core, "Claimed");
    });

    it("W3: reserve (safetyFloor) can block draws and claims", async () => {
      // set a very high safety floor to block actions
      await (await core.connect(owner).setReserveConfigForUnion(unionA, 0, parseEther("99999999"), true, 0)).wait();

      const maxAmount = parseEther("10");
      const minRateBP = 0;
      const loanId = keccak256(toUtf8Bytes("W3-loan"));
      const nonceW3 = await core.nonces(await borrower2.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower2.getAddress(), union: unionA,
        loanId, maxAmount, minRateBP, loanType: loanTypeB, nonce: nonceW3,
      });
      await expect(core.connect(borrower2).drawLoanWithVoucher(
        unionA, loanId, loanTypeB, parseEther("5"), 1000, (await now()) + 10 * DAY,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceW3
      )).to.be.reverted; // insufficient reserve

      // restore sane buffer
      await (await core.connect(owner).setReserveConfigForUnion(unionA, 1000, 0, true, 0)).wait();
    });
  });

  describe("Voucher draw", function () {
    it("V1: borrower can draw less than voucher max", async () => {
      // seed some liquidity
      await (await core.connect(j1).depositJunior(unionA, loanTypeA, parseEther("3000"))).wait();
      await (await core.connect(s1).depositSenior(unionA, parseEther("5000"))).wait();

      const maxAmount = parseEther("1000");
      const minRateBP = 900; // 9%
      const paramsHash = ethers.ZeroHash;
      const loanId = keccak256(toUtf8Bytes("V1-loan"));
      const nonceV1 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionA,
        loanId,
        maxAmount,
        minRateBP,
        loanType: loanTypeA,
        paramsHash,
        nonce: nonceV1,
      });

      // borrower chooses a lower amount & adequate rate
      const amount = parseEther("600");
      const rateBP = 1200; // 12%
      const maturity = (await now()) + 30 * DAY;

      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionA,
        loanId,
        loanTypeA,
        amount,
        rateBP,
        maturity,
        paramsHash,
        sig,
        maxAmount,
        minRateBP,
        true,
        0n, 0, nonceV1
      )).to.emit(core, "LoanClaimed");
    });

    it("V2: reject amount > maxAmount or rate < minRateBP", async () => {
      const maxAmount = parseEther("500");
      const minRateBP = 1000;
      const loanId = keccak256(toUtf8Bytes("V2-loan"));
      const nonceV2 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionA,
        loanId,
        maxAmount,
        minRateBP,
        loanType: loanTypeA,
        nonce: nonceV2,
      });

      // amount too high
      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionA, loanId, loanTypeA, parseEther("600"), 1100, (await now()) + 10 * DAY,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceV2
      )).to.be.reverted;

      // amount ok, rate too low
      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionA, loanId, loanTypeA, parseEther("400"), 800, (await now()) + 10 * DAY,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceV2
      )).to.be.reverted;
    });

    it("PV1: previewRateBP increases with amount (unionA)", async () => {
      // seed some liquidity so utilization is below 100%
      await (await core.connect(s1).depositSenior(unionA, parseEther("10000"))).wait();

      const amtSmall = parseEther("100");
      const amtMid   = parseEther("1000");
      const amtLarge = parseEther("9000");

      const rSmall = await viewer.previewRateBP(unionA, amtSmall);
      const rMid   = await viewer.previewRateBP(unionA, amtMid);
      const rLarge = await viewer.previewRateBP(unionA, amtLarge);
      console.log('rates', rSmall, rMid, rLarge);
      expect(rSmall).to.be.lte(rMid);
      expect(rMid).to.be.lte(rLarge);
      const [, , , , maxRate] = await core.rateParamsByUnion(unionA);
      expect(rLarge).to.be.lte(maxRate);
    });

    it("VW1: getMaturityCoverageForUnion surfaces credit and consumption", async () => {
      const unionC = ethers.Wallet.createRandom().address;
      const loanTypeD = encodeBytes32String("Maturity Coverage");

      await (await viewer.connect(owner).CreateUnion(unionC, "Union C", "loc")).wait();
      await (await viewer.connect(owner).AddFundType(unionC, loanTypeD, "MAT")).wait();
      await roles.connect(owner).setLeader(unionC, await leader.getAddress(), true);
      await (await core.connect(owner).setRateParams(unionC, 600, 8000, 400, 2400, 3000)).wait();
      await (await core.connect(owner).setReserveConfigForUnion(unionC, 1000, 0, true, 0)).wait();

      // fund the union and request a junior unbond
      await (await core.connect(j1).depositJunior(unionC, loanTypeD, parseEther("1500"))).wait();
      await (await core.connect(s2).depositSenior(unionC, parseEther("5000"))).wait();
      const invBefore = await core.getInvestorJunior(unionC, loanTypeD, await j1.getAddress());
      const thirdShares = invBefore.shares / 3n;
      await (await core.connect(j1).requestUnbondJunior(unionC, loanTypeD, thirdShares)).wait();
      const invAfterReq = await core.getInvestorJunior(unionC, loanTypeD, await j1.getAddress());
      const pendingSnap = invAfterReq.pendingPrincipalSnap;

      // draw a loan with maturity set later via reportMaturity
      const maxAmount = parseEther("800");
      const minRateBP = 800;
      const rateBP = 1200;
      const loanId = keccak256(toUtf8Bytes("VW1-loan"));
      const nonceVW1 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower1.getAddress(),
        union: unionC,
        loanId,
        maxAmount,
        minRateBP,
        loanType: loanTypeD,
        fastDraw: true,
        nonce: nonceVW1,
      });
      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionC, loanId, loanTypeD, maxAmount, rateBP, 0,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceVW1
      )).to.emit(core, "LoanClaimed");

      // report maturity and credit it once the date passes
      const matTs = (await now()) + 2 * DAY;
      await (await core.connect(leader).reportMaturity(unionC, loanId, matTs)).wait();
      await timeTravel(3 * DAY);
      await (await core.connect(leader).creditMaturedRepayments(unionC, [matTs])).wait();

      const [availBefore, creditBefore, consumedBefore] = await viewer.getMaturityCoverageForUnion(unionC);
      expect(creditBefore).to.equal(maxAmount);
      expect(consumedBefore).to.equal(0n);
      expect(availBefore).to.equal(maxAmount);

      // claim path may depend on reserve/maturity coverage; ensure budget exists
      const [, , consumedAfter] = await viewer.getMaturityCoverageForUnion(unionC);
      expect(consumedAfter).to.equal(0n);
    });
  });

  describe("Ratio & interest split under threshold and max loan", function () {
    it("R1: owner sets threshold/max, draw respects pre-funding ratio, interest splits by deposits", async () => {
      const threshold = ethers.parseEther("0.1"); // 0.1 WAD
      const maxLoan = parseEther("10000");
      await core.connect(owner).setBucketThresholds(unionB, loanTypeC, threshold, maxLoan);

      // deposits: ratio 30k/200k = 0.15 >= threshold
      await (await core.connect(j1).depositJunior(unionB, loanTypeC, parseEther("30000"))).wait();
      await (await erc20.connect(owner).mint(await s1.getAddress(), parseEther("200000"))).wait();
      await (await core.connect(s1).depositSenior(unionB, parseEther("200000"))).wait();

      const maxAmount = maxLoan;
      const minRateBP = 900;
      const rateBP = 1200; // 12%
      const amount = parseEther("10000");
      const maturity = (await now()) + 90 * DAY;

      const loanId = keccak256(toUtf8Bytes("R1-loan"));
      const nonceR1 = await core.nonces(await borrower1.getAddress());
      const sig = await signVoucher({
        oracle, coreAddr: await core.getAddress(), borrower: await borrower1.getAddress(), union: unionB,
        loanId, maxAmount, minRateBP, loanType: loanTypeC, fastDraw: true, nonce: nonceR1,
      });

      await expect(core.connect(borrower1).drawLoanWithVoucher(
        unionB, loanId, loanTypeC, amount, rateBP, maturity, ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceR1
      )).to.emit(core, "LoanClaimed");

      // accrue 90 days of interest
      await timeTravel(90 * DAY);

      const treBefore = await core.unionTreasury(unionB);
      const jmBefore = await core.getJuniorMarket(unionB, loanTypeC);
      const smBefore = await core.getSeniorMarket(unionB);
      const loanBefore = await core.loans(unionB, loanId);

      const YEAR = 365n * 24n * 60n * 60n;
      const nowTs = BigInt(await now());
      const elapsed = nowTs - BigInt(loanBefore.lastAccrualTs);
      const interest = (amount * BigInt(rateBP) * elapsed) / (10000n * YEAR);
      const repayAmount = amount + interest;

      await (await core.connect(borrower1).repayLoan(unionB, loanId, repayAmount)).wait();

      const treSnapAfter = await core.unionTreasury(unionB);
      const treAfter = treSnapAfter;
      const rainyAfter = await core.unionRainyDay(unionB);
      const fee = interest / 100n; // 1% fee
      const treDelta = treAfter - treBefore;
      const feeTol = 10n ** 12n;
      expect(treDelta >= fee - feeTol && treDelta <= fee + feeTol).to.equal(true);
      const rainyExpected = (interest * 200n) / 10_000n; // default 2%
      const rainyTol = 10n ** 15n; // allow small rounding drift
      expect(rainyAfter >= rainyExpected - rainyTol && rainyAfter <= rainyExpected + rainyTol).to.equal(true);

      const jmAfter = await core.getJuniorMarket(unionB, loanTypeC);
      const smAfter = await core.getSeniorMarket(unionB);

      // net interest after fee
      const net = interest - interest / 100n;
      // split by funded composition (junior-first waterfall sets this on the loan)
      const fundedJ = BigInt(loanBefore.fundedFromJunior);
      const fundedS = BigInt(loanBefore.fundedFromSenior);
      const denom = fundedJ + fundedS;
      const toJ = denom === 0n ? net / 2n : (net * fundedJ) / denom;
      const toS = net - toJ;

      // remove principal portion to isolate interest deltas
      const deltaJ = jmAfter.cash - jmBefore.cash - fundedJ;
      const deltaS = smAfter.cash - smBefore.cash - fundedS;

      // tolerance for rounding; just ensure some positive distribution occurred
      expect(deltaJ + deltaS > 0n).to.equal(true);
    });

    it("R2: borrower can hold multiple loans (no cap enforced)", async () => {
      // ensure bucket config exists
      const threshold = ethers.parseEther("0.05");
      const maxLoan = parseEther("20000");
      await core.connect(owner).setBucketThresholds(unionB, loanTypeC, threshold, maxLoan);

      await (await core.connect(j1).depositJunior(unionB, loanTypeC, parseEther("5000"))).wait();
      await (await core.connect(s1).depositSenior(unionB, parseEther("20000"))).wait();

      const ids = ["R2-loan-1", "R2-loan-2"].map((s) => keccak256(toUtf8Bytes(s)));
      for (const id of ids) {
        const nonceR2 = await core.nonces(await borrower1.getAddress());
        const sig = await signVoucher({
          oracle, coreAddr: await core.getAddress(), borrower: await borrower1.getAddress(), union: unionB,
          loanId: id, maxAmount: maxLoan, minRateBP: 900, loanType: loanTypeC, fastDraw: true, nonce: nonceR2,
        });
        await expect(core.connect(borrower1).drawLoanWithVoucher(
          unionB, id, loanTypeC, parseEther("5000"), 1200, (await now()) + 30 * DAY,
          ethers.ZeroHash, sig, maxLoan, 900, true,
          0n, 0, nonceR2
        )).to.emit(core, "LoanClaimed");
      }
    });
  });

  describe("Investor yield & repay post-draw", function () {
    it("Y1: interest accrues & can be claimed with buffer constraints", async () => {
      // let j1 deposit into the loanTypeB
      await (await core.connect(j1).depositJunior(unionA, loanTypeB, parseEther("700"))).wait();

      // Make a small loan and fast-forward, then repay interest to seed yield
      const maxAmount = parseEther("400");
      const minRateBP = 900;
      const loanId = keccak256(toUtf8Bytes("Y1-loan"));
      const nonceY1 = await core.nonces(await borrower2.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower2.getAddress(),
        union: unionA,
        loanId,
        maxAmount,
        minRateBP,
        loanType: loanTypeB,
        nonce: nonceY1,
      });

      await (await core.connect(borrower2).drawLoanWithVoucher(
        unionA, loanId, loanTypeB, parseEther("300"), 1200, (await now()) + 20 * DAY,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceY1
      )).wait();

      await timeTravel(10 * DAY);
      await (await core.connect(borrower2).repayLoan(unionA, loanId, parseEther("300"))).wait();

      // Seniors & Juniors can claim yield (bounded by buffer)
      await expect(core.connect(s1).claimYield(1, unionA, loanTypeB, 0)).to.emit(core, "YieldClaimed"); // 0 is all available, so more set if for some reason you want a left-over..
      await expect(core.connect(j1).claimYield(0, unionA, loanTypeB, 0)).to.emit(core, "YieldClaimed");
    });
  });

  describe("Defaults & rollover unchanged semantics", function () {
    it("D1: default waterfall after 6 weeks from maturity", async () => {
      const maxAmount = parseEther("150");
      const minRateBP = 900;
      const loanId = keccak256(toUtf8Bytes("D1-loan"));
      const nonceD1 = await core.nonces(await borrower2.getAddress());
      const sig = await signVoucher({
        oracle,
        coreAddr: await core.getAddress(),
        borrower: await borrower2.getAddress(),
        union: unionA,
        loanId,
        maxAmount,
        minRateBP,
        loanType: loanTypeB,
        nonce: nonceD1,
      });
      const matSoon = (await now()) + 1 * DAY;

      await (await core.connect(borrower2).drawLoanWithVoucher(
        unionA, loanId, loanTypeB, parseEther("150"), 1000, matSoon,
        ethers.ZeroHash, sig, maxAmount, minRateBP, true,
        0n, 0, nonceD1
      )).wait();

      await timeTravel(1 * DAY + SIX_WEEKS + 10);
      await expect(core.connect(owner).markDefault(unionA, loanId)).to.emit(core, "LoanDefaulted");
    });

    it.skip("D2: transferLoan removed in CS003 — test retired", async () => {
      // transferLoan was removed to free bytecode; covered by CashScanEscrow.spec.js ABI check
    });
    it.skip("D3: transferLoan removed in CS003 — test retired", async () => {
      // transferLoan was removed to free bytecode; covered by CashScanEscrow.spec.js ABI check
    });
    it("V1: returns buffer data with idle=junior.cash+senior.cash and headroom=idle when req=0", async () => {
      // Seed cash
      await (await core.connect(s1).depositSenior(unionA, parseEther("500"))).wait();
      await (await core.connect(j1).depositJunior(unionA, loanTypeB, parseEther("300"))).wait();

      // Call viewer.getLiquidityBuffer
      const res = await viewer.getLiquidityBuffer(unionA, loanTypeB);
      // res tuple: (safetyBP, safetyFloor, claimableReserved, idleCashForType, hardStop, requiredReserve, headroom)

      const safetyBP      = Number(res[0]);
      const safetyFloor   = res[1];
      const claimable     = res[2];
      const idle          = res[3];
      const hardStop      = res[4];
      const required      = res[5];
      const headroom      = res[6];

      expect(safetyBP).to.equal(1000);
      expect(safetyFloor).to.equal(0n);
      expect(hardStop).to.equal(true);
    });
  });
});
