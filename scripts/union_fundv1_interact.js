// scripts/interact.js
const hre = require("hardhat");
const { parseUnits } = require("ethers");
require("dotenv").config();

async function main() {
  const fundAddress  = process.env.FUND_ADDRESS;
  const tokenAddress = process.env.NILA_ADDRESS;
  const [ investor ] = await hre.ethers.getSigners();

  console.log(`investor`,investor.address);

  const fund  = await hre.ethers.getContractAt("FertilizerFund", fundAddress);
  const token = await hre.ethers.getContractAt("IERC20", tokenAddress, investor);
  /*
  // Approve and invest
  const investAmount = parseUnits("1", 18);
  console.log(`investAmount ${investAmount.toString()}`);

  let tx = await token.approve(fundAddress, investAmount);
  await tx.wait();
  console.log(`Approved ${investAmount.toString()}`);

  const tokens = await fund.getTokenList();
  console.log(tokens, tokenAddress);

  tx = await fund.invest(tokenAddress, investAmount);
  await tx.wait();
  console.log(`Invested ${investAmount.toString()}`);

  // Read investor info
  const info = await fund.getInvestorInfo(tokenAddress, investor.address);
  console.log("Principal:", info.principalAmt.toString());
  console.log("Pending Interest:", info.pendingInterestAmt.toString());
  console.log("Daily Rate BP:", info.dailyRateBP);

  // Claim interest
  tx = await fund.claimInterest(tokenAddress);
  await tx.wait();
  console.log("Claimed interest");
  */
  // Withdraw part of principal
  const withdrawAmt = parseUnits("0.5", 18);
  tx = await fund.withdraw(tokenAddress, withdrawAmt);
  await tx.wait();
  console.log(`Withdrew ${withdrawAmt.toString()}`);

  // Fetch APR history
  const history = await fund.getAPRHistory(tokenAddress);
  const days   = history.dayNumbers;
  const rates  = history.rates;
  console.log("APR History:");
  for (let i = 0; i < days.length; i++) {
    const dayNum = days[i];
    const date   = new Date(Number(dayNum) * 24 * 3600 * 1000)
                     .toISOString().split('T')[0];
    console.log(`${date}: ${rates[i]}`);
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
