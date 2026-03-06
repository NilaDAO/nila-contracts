// test/planting_fund.spec.js – comprehensive Hardhat tests
// -----------------------------------------------------------------------------
// Common‑JS style (mocha default) | ethers‑js v6 | chai‑matchers
// Covers: FundFactory deployment, PlantingFund proxy creation, multi‑union
// registration, deposits, basic borrow‑cap enforcement with a mocked voucher,
// harvest reporting and repayment flow.  Adjust the typehash / struct field
// names if your on‑chain definitions differ.

const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { expect }            = require("chai");
const { ethers, upgrades }  = require("hardhat");
const { keccak256, toUtf8Bytes } = require("ethers");

/* ────────────────────────────────────────────────────────────────
 * Minimal ERC‑20 mock (inline)
 * ─────────────────────────────────────────────────────────────── */

async function deployToken() {
  const ERC20 = await ethers.getContractFactory("ERC20Mock");
  const token = await ERC20.deploy("TestToken", "TT", 18);
  await token.waitForDeployment();
  return token;
}

/* ─────────────────────────────────────────────────────────────── */
async function deployFixture() {
  const [deployer, unionA, unionB, investor, borrower, oracle, treasury, investor1, investor2, borrower1,borrower2] =
    await ethers.getSigners();

  console.log('prepare dummy signers')
  /* 1. mock token */
  const token = await deployToken();

  const thousand = ethers.parseUnits("1000", 18);
  await token.mint(investor.address,  thousand);
  await token.mint(investor1.address, thousand);
  await token.mint(investor2.address, thousand);
  console.log('deploy dummy tokens')

  /* 2. PlantingFund implementation */
  const PlantingFund = await ethers.getContractFactory("PlantingFundUpgradeable");
  const plantingImpl = await PlantingFund.deploy();
  await plantingImpl.waitForDeployment();
  console.log('deploy PlantingFund implementation')

  /* 2. PlantingFund implementation */
  const InputFund = await ethers.getContractFactory("InputFundUpgradeable");
  const inputImpl = await PlantingFund.deploy();
  await inputImpl.waitForDeployment();
  console.log('deploy InputFund implementation')

  /* 3. FundFactory (UUPS proxy) */
  const Factory = await ethers.getContractFactory("FundFactoryUpgradeable");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();
  console.log('deploy Factory implementation')

  // factory initializer: (_plantingImpl, _treasury)

  await factory.initialize(await inputImpl.getAddress(),await plantingImpl.getAddress());
  console.log('initialize Factory with planting & input impl')

  /* 4. create a global fund proxy via factory */
  const createTx = await factory.connect(oracle).createPlantingFund(treasury.address, oracle.address);
  const rc        = await createTx.wait();
  const fundAddr  = rc.logs.find(l => l.eventName === "GlobalFundCreated").args[0]; // 1: proxy, 2: impl
  const fund      = await ethers.getContractAt("PlantingFundUpgradeable", fundAddr);

  /* 5. wire up: owner sets oracle */
  await fund.connect(oracle).setOracleSigner(oracle.address, true);
  console.log('set OracleSigner', oracle.address)

  /* 6. register two unions 
  *    we call plantingfund that calls factory
  
  */
  await fund.connect(oracle).activateUnion(unionA.address);
  await fund.connect(oracle).activateUnion(unionB.address);
  await factory.connect(unionA).registerUnion(unionA.address,fundAddr,"Mth Teresa PlantFund A",'PlantingFundUpgradeable');
  await factory.connect(unionB).registerUnion(unionB.address,fundAddr,"Union‑B",'PlantingFundUpgradeable');
  console.log('registered 2 dummy unions')

  return { token, fund, factory, unionA, unionB, investor, borrower, oracle, treasury, investor1, investor2, borrower1,borrower2 };
}

// Sign EIP-712 Voucher with expiry as uint40
async function signVoucher(oracle, fundAddr, voucher) {
  const domain = {
    name: "PlantingFund",
    version: "1.0",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: fundAddr
  };
  const types = {
    Voucher: [
      { name: "borrower",   type: "address" },
      { name: "union",      type: "address" },
      { name: "token",      type: "address" },
      { name: "maxAmount",  type: "uint256" },
      { name: "minRateBP",  type: "uint16"  },
      { name: "nonce",      type: "uint256" }
    ]
  };
  return oracle.signTypedData(domain, types, voucher);
}

/* ─────────────────────────────────────────────────────────────── */
describe("PlantingFundUpgradeable end‑to‑end", function () {

  it("registers unions & processes deposits", async function () {
    const { token, fund, factory, treasury, oracle, unionA, unionB, investor, investor2, borrower } = await loadFixture(deployFixture);

    const amount = ethers.parseUnits("100", 18);
    await token.connect(investor).approve(fund.getAddress(), amount);
    await fund.connect(investor).invest(unionA.address, token.getAddress(), amount);

    // on‑chain helper: supply()
    const supplyAfter = await fund.supply(unionA.address, token.getAddress());
    expect(supplyAfter).to.equal(amount);
  });

  it("enforces 2× borrow‑cap per union", async function () {
    const { token, fund, unionA, borrower, oracle } = await loadFixture(deployFixture);

    // investor seeds 100 tokens
    const deposit = ethers.parseUnits("100", 18);

    await token.mint(borrower.address, deposit); // so borrower can repay interest later
    await token.connect(borrower).approve(fund, deposit);
    await fund.connect(borrower).invest(unionA.address, token, deposit);

    const cap = deposit * 2n; // 200
    const attempt = cap + 1n;
    
    const voucher = {
      borrower:     borrower.address,
      union:        unionA.address,
      token:        token.target,
      maxAmount:    attempt,
      minRateBP:    100,
      nonce:        1
    };

    // fix Voucher typehash USED TO GET THE HASH OF THE NEW VOUCHER STRUCT
    //const typeStr = "Voucher(address borrower,address union,address token,uint256 maxAmount,uint16 minRateBP,uint256 nonce)";
    // console.log(keccak256(toUtf8Bytes(typeStr)));

    const sig = await signVoucher(oracle, fund.target, voucher);
    expect(await fund.isOracleSigner(oracle.address)).to.be.true;
    // Recover signer and assert
    //const signer = await fund.recoverVoucherSigner(voucher, sig);
    //expect(signer).to.equal(oracle.address);
    //console.log('signer is ORACLE ADDRESS ')

    await expect(
      fund.connect(borrower).claimLoan(voucher, attempt, 600, sig) // raises amount
    ).to.be.revertedWith("borrow cap exceeded");
  });

  it("full loan lifecycle (claim → harvest → repay)", async function () {
    const { token, fund, unionA, investor, borrower, oracle, treasury } = await loadFixture(deployFixture);

    // investor deposits 1000
    const depositAmt = ethers.parseUnits("1000", 18);
    await token.connect(investor).approve(fund, depositAmt);
    await fund.connect(investor).invest(unionA.address, token, depositAmt);
    
    // borrower claims 500 @ 600 BP
    const loanPrincipal = ethers.parseUnits("500", 18);
   
    const voucher = {
      borrower:     borrower.address,
      union:        unionA.address,
      token:        token.target,
      maxAmount:    loanPrincipal,
      minRateBP:    100,
      nonce:        1
    };
    console.log('voucher',voucher, oracle.address)
    const sig = await signVoucher(oracle, fund.target, voucher);
    console.log('sig',sig)

    await fund.connect(borrower).claimLoan(voucher, loanPrincipal, 700, sig); // higher rate
    console.log('loan claimed')

    // find the loadids of the borrower
    loanIds = await fund.getLoansByBorrower(borrower.address);
    console.log('loanIds',loanIds)

    // move time 30 days
    await time.increase(30 * 24 * 3600);

    // oracle reports harvest
    await fund.connect(oracle).reportHarvest(unionA.address, loanIds[0], await time.latest());
    console.log('harvest reported',loanIds)

    // calc owed interest (simple): principal * rateBP / 10_000 * elapsed / YEAR
    const interest = loanPrincipal * 700n * 30n * 24n * 3600n / 365n / 24n / 3600n / 10_000n;
    const totalOwed = loanPrincipal + interest;

    // borrower mints owed + treasury fee to repay
    const fee = interest / 100n; // 1%
    await token.mint(borrower.address, totalOwed + fee);
    await token.connect(borrower).approve(fund, totalOwed + fee);
    await fund.connect(borrower).repayLoan(unionA.address,token.target,loanIds[0], totalOwed + fee);

    // treasury got its fee (check if slightly bigger (gte))
    expect(await token.balanceOf(treasury.address)).to.gte(fee);
  });

  it("should distribute interest only for correct cycles to investors", async function () {
    const { token, fund, factory, unionA, unionB, investor, borrower, oracle, treasury, investor1, investor2, borrower1,borrower2 } = await loadFixture(deployFixture);

    const deposit1 = ethers.parseUnits("200", 18);
    console.log('deposit1',deposit1)

    // Investor1 deposit cycle1
    await token.connect(investor1).approve(fund.getAddress(), deposit1);
    await fund.connect(investor1).invest(unionA.address,  token.getAddress(), deposit1);

    // borrower claims 500 @ 600 BP
    const loanPrincipal = ethers.parseUnits("100", 18);
    const chosenAmount = ethers.parseUnits("100", 18);
    const chosenRate = 600n;

    // Borrower1 takes and repays a loan
    const voucher1 = {
      borrower:     borrower1.address,
      union:        unionA.address,
      token:        token.target,
      maxAmount:    loanPrincipal,
      minRateBP:    chosenRate,
      nonce:        1
    };
    console.log('voucher',voucher1, oracle.address)
    const sig = await signVoucher(oracle, fund.target, voucher1);
    console.log('sig',sig)

    await fund.connect(borrower1).claimLoan(voucher1, chosenAmount, chosenRate, sig);
    console.log('borrower1 got:',chosenAmount, 'with rate', chosenRate)
    
    // fast forward
    await time.increase(10 * 24 * 3600);
    const now1 = await time.latest();
    const loans = await fund.getLoansByBorrower(borrower1.address)
    console.log('loans of borrower1:', loans)
    await fund.connect(oracle).reportHarvest(unionA.address, loans[0], now1);
    console.log('oracle reported harvest',now1)
    console.log('chosenAmount',chosenAmount)
    console.log('chosenRate',chosenRate)

    // borrower1 repays full
    const interest1 = chosenAmount * chosenRate * BigInt(10 * 24 * 3600) / BigInt(365 * 24 * 3600) / BigInt(10000);
    const total1 = chosenAmount + interest1;
    const fee1 = interest1 / BigInt(100);
    await token.mint(borrower1.address, total1 + fee1);
    await token.connect(borrower1).approve(fund, total1 + fee1);
    await fund.connect(borrower1).repayLoan(unionA.address, token.getAddress(), loans[0], total1 + fee1);
    console.log('borrower 1 repaid loan after 10 days for cost:',total1 + fee1)

    // Investor2 deposit cycle2
    const deposit2 = ethers.parseUnits("200", 18);
    await token.connect(investor2).approve(fund, deposit2);
    await fund.connect(investor2).invest(unionA.address, token.getAddress(), deposit2);
    console.log('investor2 invests:',deposit2)

    const loanPrincipal2 = ethers.parseUnits("100", 18);
    const chosenAmount2 = ethers.parseUnits("100", 18);
    const chosenRate2 = 600n;

    // Borrower1 takes and repays a loan
    const voucher2 = {
      borrower:     borrower2.address,
      union:        unionA.address,
      token:        token.target,
      maxAmount:    loanPrincipal2,
      minRateBP:    600n,
      nonce:        2
    };
    console.log('voucher',voucher2, oracle.address)
    const sig2 = await signVoucher(oracle, fund.target, voucher2);
    console.log('sig',sig2)

    await fund.connect(borrower2).claimLoan(voucher2, chosenAmount2, chosenRate2, sig2);
    console.log('borrower2 got:',chosenAmount2, 'with rate', chosenRate2)
    
    // fast forward 5 DAYS
    await time.increase(5 * 24 * 3600);
    const now2 = await time.latest();
    const loans2 = await fund.getLoansByBorrower(borrower2.address)
    await fund.connect(oracle).reportHarvest(unionA.address, loans2[0], now2);

    const interest2 = chosenAmount2 * chosenRate2 * BigInt(5 * 24 * 3600) / BigInt(365 * 24 * 3600) / BigInt(10000);
    const total2 = chosenAmount2 + interest2;
    const fee2 = interest2 / BigInt(100);
    await token.mint(borrower2.address, total2 + fee2);
    await token.connect(borrower2).approve(fund, total2 + fee2);
    await fund.connect(borrower2).repayLoan(unionA.address,  token.getAddress(), loans2[0], total2 + fee2);
    console.log('borrower 2 repaid loan after 5 days for cost:',total2 + fee2)

    // Now claim interest
    const before1 = await token.balanceOf(investor1.address);
    await fund.connect(investor1).claimInterest(unionA.address, token.getAddress());
    const after1 = await token.balanceOf(investor1.address);
    const claimed1 = after1 - before1;
    console.log('investor1 got :', ethers.formatEther(claimed1,18))

    const before2 = await token.balanceOf(investor2.address);
    await fund.connect(investor2).claimInterest(unionA.address, token.getAddress());
    const after2 = await token.balanceOf(investor2.address);
    const claimed2 = after2 - before2;
    console.log('investor2 got :', ethers.formatEther(claimed2,18))

    // investor1 should get interest1 + interest2 * (shares1 / (shares1 + shares2))
    const shares1 = Number(ethers.formatEther(deposit1,18));
    const shares2 = Number(ethers.formatEther(deposit2,18));
    const interest1_ = Number(ethers.formatEther(interest1,18));
    const interest2_ = Number(ethers.formatEther(interest2,18));
    const claimed1_ = Number(ethers.formatEther(claimed1,18));
    const claimed2_ = Number(ethers.formatEther(claimed2,18));
    const share_ownership =  shares1 / (shares1 + shares2)
    console.log('share_ownership :',share_ownership)
    const exp1_from2 = interest2_ * share_ownership;
    expect(claimed1_).to.be.closeTo(interest1_ + exp1_from2, 1);

    // investor2 should only get its share of interest2
    const share_ownership_investor2 =  shares2 / (shares1 + shares2)
    const exp2 = interest2_ * share_ownership_investor2;
    console.log('investor2 exp2 :',exp2)
    expect(claimed2_).to.be.closeTo(exp2, 1);
  });
  
  it("factory.getFundsByOwner() returns correct entry", async () => {
    const { factory, unionA } = await loadFixture(deployFixture);
    const list = await factory.getFundsByOwner(unionA.address);
    console.log('list',list)
    expect(list.length).to.equal(1);
    expect(list[0].contractname).to.equal("PlantingFundUpgradeable");
  });

  it("getTokenList, getFundTotals, getInvestorInfo work end-to-end", async () => {
    const { token, fund, unionA, investor } = await loadFixture(deployFixture);
  
    // investor deposits 200 tokens
    const amt = ethers.parseUnits("200",18);
    await token.connect(investor).approve(fund, amt);
    await fund.connect(investor).invest(unionA.address, token.target, amt);
    console.log('investor deposited:',amt)
    
    // now getTokenList returns one token
    const tokens = await fund.getTokenList(unionA.address);
    console.log('tokens deposited by address:',tokens)

    // getFundTotals reflects deposit & zero borrow
    const [deposits, borrows] = await fund.getFundTotals(unionA.address, token.target);
    console.log('getFundTotals:',deposits, borrows)
    expect(deposits).to.equal(amt);
    expect(borrows).to.equal(0);

    // pending interest should be zero immediately
    const [shares, pending, frozen] = 
      await fund.getInvestorInfo(unionA.address, token.target, investor.address);
    expect(shares).to.equal(amt);
    expect(pending).to.equal(0);
    expect(frozen).to.be.false;
  });

  it("getLoansByBorrower and getBorrowerInfo reflect a drawn loan", async () => {
    const { token, fund, unionA, borrower, oracle, treasury } = await loadFixture(deployFixture);

    // fund a deposit so borrow cap > 0
    await token.mint(borrower.address, ethers.parseUnits("100",18));
    await token.connect(borrower).approve(fund, ethers.parseUnits("100",18));
    await fund.connect(borrower).invest(unionA.address, token.target, ethers.parseUnits("100",18));

    // sign & claim a small loan
       
    // borrower claims 500 @ 600 BP
    const loanPrincipal = ethers.parseUnits("500", 18);
   
    const voucher3 = {
      borrower:     borrower.address,
      union:        unionA.address,
      token:        token.target,
      maxAmount:    loanPrincipal,
      minRateBP:    600,
      nonce:        1
    };
    console.log('voucher',voucher3, oracle.address)
    const sig = await signVoucher(oracle, fund.target, voucher3);
    console.log('sig',sig)

    await fund.connect(borrower).claimLoan(voucher3, ethers.parseUnits("30",18), 1100, sig);
    console.log('loan claimed')

    // getLoansByBorrower
    const loanIds = await fund.getLoansByBorrower(borrower.address);
    expect(loanIds.length).to.equal(1);

    // check getBorrowerInfo
    const info = await fund.getBorrowerInfo(unionA.address, loanIds[0]);
    expect(info.principal).to.equal(ethers.parseUnits("30",18));
    expect(info.repaid).to.equal(0);
    expect(info.rateBP).to.equal(1100);
    expect(info.outstanding).to.be.gt(0);
    expect(info.closed).to.be.false;
  });
});