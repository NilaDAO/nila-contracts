const { ethers } = require("hardhat");

/**
 npx hardhat run scripts/handleFoodTokens/setOracleSigner.js --network amoy
 */

async function main() {
  const [master, unionLeader, investor] = await ethers.getSigners();

  const proxyAddress = process.env.FOOD_TOKENS_PROXY_ADDRESS;
  const Food = await ethers.getContractFactory("FoodTokenUpgradeable");

  // Attach to the existing proxy
  const food = Food.attach(proxyAddress);

  const newOracle = process.env.ORACLE_SIGNER
  console.log("newOracle:",newOracle);
  return
  const tx = await food.connect(master).setOracleSigner(newOracle, true);
  console.log("Transaction:", tx.hash);
  await tx.wait();
  console.log("Oracle signer set:", newOracle);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
