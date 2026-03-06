// npx hardhat run scripts/TOMAINNET/deploy_mathlib.ts --network polygon

const { ethers } = require("hardhat");

async function main() {
  const LibF = await ethers.getContractFactory("GenericFundMathLib");
  const lib = await LibF.deploy();
  await lib.waitForDeployment();
  console.log("GenericFundMathLib deployed at:", await lib.getAddress());
}

main().catch(console.error);