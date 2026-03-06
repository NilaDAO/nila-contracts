// scripts/deploy.js
require('dotenv').config();
const hre = require("hardhat");

async function main() {
  // Replace with your token addresses and parameters
  const tokens = [
    process.env.NILA_ADDRESS,  // e.g. "0x..."
    process.env.USDC_ADDRESS   // e.g. "0x..."
  ];
  const oracleSigner = process.env.ORACLE_SIGNER; // address
  const baseRateBP = 700;       // 7% APR
  const union = process.env.UNION_ADDRESS; // owner of contract

  const FertilizerFund = await hre.ethers.getContractFactory("FertilizerFund");
  const fund = await FertilizerFund.deploy(tokens, oracleSigner, baseRateBP, union);
  await fund.deployed();

  console.log("FertilizerFund deployed to:", fund.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });