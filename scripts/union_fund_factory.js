// scripts/deployFactory.js
const hre = require("hardhat");
require("dotenv").config();

// CALL npx hardhat run scripts/union_fund_factory.js --network polygon_amoy_masternode

async function main() {
  // Fetch the deployer signer
  const [deployer] = await hre.ethers.getSigners();

  const balance = await hre.ethers.provider.getBalance(deployer.address);

  console.log(`Deploying with address: ${deployer.address}`);
  console.log(`Deployer MATIC balance: ${hre.ethers.formatEther(balance)} MATIC`);

  // Deploy FundFactory using the deployer's account
  const FundFactory = await hre.ethers.getContractFactory("FundFactoryUpgradeable", deployer);
  const factory = await FundFactory.deploy();

  // Wait for deployment to be mined
  await factory.waitForDeployment();

  console.log("FundFactory deployed at:", factory.target);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});