// npx hardhat run scripts/TOMAINNET/deploy_mockagg.ts --network amoy
// npx hardhat run scripts/deploy_mock_aggregator.ts --network amoy

import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", await deployer.getAddress());

  //
  // CONFIG
  //
  const decimals = 8; 
  const initialRate = "8300000000"; 
  // 83.00000000 INR per USD (just an example)
  // Adjust if you want a different INR/USD mock value.

  console.log(`Deploying MockAggregator with rate ${initialRate} and decimals ${decimals}...`);

  //
  // DEPLOY
  //
  const Mock = await ethers.getContractFactory("MockAggregator", deployer);
  const mock = await Mock.deploy(decimals, initialRate);
  await mock.waitForDeployment();

  const address = await mock.getAddress();
  console.log("MockAggregator deployed at:", address);

  //
  // POST CHECK
  //
  const decimalsRead = await mock.decimals();
  const round = await mock.latestRoundData();
  console.log("MockAggregator.decimals():", decimalsRead);
  console.log("MockAggregator.latestRoundData():", round);

  console.log("\nUse this address as ORACLE_ in FxPool deployment:");
  console.log(address);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
