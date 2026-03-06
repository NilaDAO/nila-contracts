const hre = require("hardhat");

// npx hardhat run scripts/handleFunds/deployInputFundLogic.js --network polygon_amoy_union_leader

async function main() {
  const Factory = await hre.ethers.getContractFactory("InputFundUpgradeable");
  const impl    = await Factory.deploy();
  await impl.waitForDeployment();
  console.log("InputFundUpgradeable logic:", impl.target);
}
main();
