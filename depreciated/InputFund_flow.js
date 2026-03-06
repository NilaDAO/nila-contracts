// JavaScript (Mocha) test suite for InputFundUpgradeable
// run with: npx hardhat test

const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

/**
 * fixes | additions | improvements
 *  0 - allow only USDC and NILA, let onlyOwner addTokens
 *  1 - use cap rate 
 *  2 - add view calls that make sense for front-ui
 *  3 - oracle sets deadline once harvest is known
 *  4 - delinquency operations; in contract (DONE), in other contracts (NOT DONE), use NilaSweeper 
 *  5 - withdrawal || borrowing pause procedures because of insufficient funds
 */

describe("InputFundUpgradeable", function () {
  let dai, fund;
  let master,unionLeader,investor,borrower
  const BASE_RATE_BP = 800; // 8%

  beforeEach(async function () {
    [master,unionLeader,investor,borrower] = await ethers.getSigners();

    // deploy mock DAI with permit (OpenZeppelin)
    const DAI = await ethers.getContractFactory("ERC20PermitMock");
    dai = await DAI.deploy("Mock DAI", "mDAI", await borrower.getAddress(), ethers.parseEther("1000000"));

    // deploy upgradeable fund proxy
    const Fund = await ethers.getContractFactory("InputFundUpgradeable");
    fund = await upgrades.deployProxy(
      Fund,
      [
        'NILADummy',
        'InputFund',
        [await dai.getAddress()],  // initial whitelist
        await master.getAddress(), // oracle signer
        BASE_RATE_BP,
      ],
      {
        kind: "uups",
        initializer: "initialize"
      }
    );

    const DaiAddress = await dai.getAddress()
    await fund.addToken(DaiAddress);

    // borrower approve large amount
    await dai.connect(borrower).approve(await fund.getAddress(), ethers.parseEther("100000"));
  });

  it("invest and withdraw", async function () {
    const DaiAddress = await dai.getAddress()
    const deposit = ethers.parseEther("1000");
    await fund.connect(borrower).invest(DaiAddress, deposit);

    const shares = await fund.userShares(await borrower.getAddress(),DaiAddress);
    expect(shares).to.equal(deposit);                // 1:1 when index = 1 RAY

    // withdraw 200 DAI
    const withdrawAmt = ethers.parseEther("200");
    await fund.connect(borrower).withdraw(DaiAddress, withdrawAmt);

    const bal = await fund.balanceOf(await borrower.getAddress(), DaiAddress);
    expect(bal).to.equal(deposit - withdrawAmt);     // bigint arithmetic
  });

  it("borrow via voucher and repay distributes interest", async function () {
    // investor deposits to earn interest
    const fundAddr = await fund.getAddress()
    const daiAddr = await dai.getAddress()
    await dai.connect(borrower).transfer(await investor.getAddress(), ethers.parseEther("5000"));
    await dai.connect(investor).approve(fundAddr, ethers.parseEther("5000"));
    await fund.connect(investor).invest(daiAddr, ethers.parseEther("5000"));

    // prepare voucher
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const voucher = {
      loanId: 1,
      borrower: await borrower.getAddress(),
      token: daiAddr,
      amount: ethers.parseEther("1000").toString(),
      interestBP: 800,
      dueDate: now + 30 * 24 * 60 * 60,
      nonce: 42
    };

    // build EIP712 domain & types
    const domain = {
      name: "InputFundUpgradeable",
      version: "3",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: fundAddr
    };

    const types = {
      LoanVoucher: [
        { name: "loanId", type: "uint256" },
        { name: "borrower", type: "address" },
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "interestBP", type: "uint256" },
        { name: "dueDate", type: "uint256" },
        { name: "nonce", type: "uint256" }
      ]
    };
    const signature = await master.signTypedData(domain, types, voucher);

    // borrower borrows
    await fund.connect(borrower).claimLoan(voucher, signature);

    // repay full amount with interest
    const principal = ethers.parseEther("1000");
    const owed = principal * BigInt(voucher.interestBP + 10_000) / 10_000n;
    await dai.connect(borrower).approve(await fund.getAddress(), owed);
    await fund.connect(borrower).repayLoan(voucher.loanId, owed);

    const balAfter = await fund.balanceOf(await investor.getAddress(), await dai.getAddress());
    expect(balAfter).to.be.gt(ethers.parseEther("5000")); // earned interest
  });
});
