const { ethers, upgrades } = require("hardhat");

/**
 npx hardhat run scripts/handleFoodTokens/upgradeBase.js --network amoy
 */


/**
🟢  FoodTokenUpgradeable deployed!

   proxy address : 0x27C4115d77ECA4f300fB34060b1719A3d1159709
   impl upgrades 
   v1            : 0x3e07979F39694f6EFae566de0cfCdFDE1ff75aD1 // updated voucher hash retreival and removed quantity and harvest date from voucher req, removed nonce and repeat check
 */


async function main() {
  const [master, unionLeader, investor] = await ethers.getSigners();
  const FOOD_PROXY = process.env.FOOD_TOKENS_PROXY_ADDRESS;
  console.log("Upgrading proxy at:", FOOD_PROXY);

  // compile & get new version
  const FoodV2 = await ethers.getContractFactory("FoodTokenUpgradeable"); // or your new version

  // 1) register the live proxy (only once, per network/project)
  await upgrades.forceImport(
    FOOD_PROXY,
    FoodV2,
    { kind: "uups", unsafeAllow: ["storageLayout"], signer: master }
  );

  // 0) check if we have the right owner
  const food = await ethers.getContractAt("FoodTokenUpgradeable", FOOD_PROXY);

  if ((await food.owner()).toLowerCase() !== master.address.toLowerCase()) {
    throw new Error("master is NOT the fund owner");
  }

  // 1) old impl address:”
  const before = await upgrades.erc1967.getImplementationAddress(FOOD_PROXY);
  console.log("Impl before:", before);
  return
  const newImplAddr = await upgrades.prepareUpgrade(FOOD_PROXY, FoodV2);

  const upgraded = await upgrades.upgradeProxy(
    FOOD_PROXY,
    FoodV2,
    {
      kind: "uups",
      unsafeAllow: ["storageLayout"],
      redeployImplementation: "always",  // ← force a fresh impl deploy
      signer: master,
    }
  );
  console.log("proxy upgraded...");
  const newImpl = await upgrades.erc1967.getImplementationAddress(upgraded.target);
  console.log("Impl after:", newImpl);

  const oldCode = await ethers.provider.getCode(before);
  const newCode = await ethers.provider.getCode(newImpl);
  console.log('CODE COMPARISON (should be false):', oldCode === newCode); // should be false
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
