// npx hardhat run scripts/TOMAINNET/deploy_nin.ts --network amoy
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", await deployer.getAddress());

  const NIN = await ethers.getContractFactory("NilaNIN"); // or INilaNIN impl name
  const nin = await NIN.deploy("Nila INR", "nIN", await deployer.getAddress());
  await nin.waitForDeployment();

  console.log("nIN deployed at:", await nin.getAddress());
}

main().catch(console.error);
