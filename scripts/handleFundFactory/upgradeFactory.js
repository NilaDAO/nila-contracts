
const { ethers, upgrades } = require("hardhat");

/*
rm -rf artifacts cache
npx hardhat run scripts/handleFundFactory/upgradeFactory.js --network amoy
*/

/**
🟢  FundFactoryUpgradeable deployed!

   proxy address : 0xaD3018591e92dC0A369Cb51A235fE78C04fAAD9f
   original impl address : 0x7ecf2449fF74d4a905b3bD0d63bBE013370C5E84
   owner         : 0x4387bf96c4da8Bd2d44981b276a8862B09BaE072

   impl upgrades 
   v1            : 0x616f91c13Ed16d6Da0E3fc87016C79437637B401
   v2            : 0xCbE017dB16CE1dac9fDEe9757AF1724aC7fc6770 // added setPlantingFundImpl & setInputFundImpl
 */

/**
 rm -rf artifacts cache
 npx hardhat run scripts/handleFunds/upgradeFund.js --network amoy
 */

async function main() {
  // make sure the update is done by the owner
  const [master, unionLeader, investor] = await ethers.getSigners();

  const balance = await ethers.provider.getBalance(master.address)
  console.log(`balance: ${balance}`);

  const FACT_PROXY = "0xaD3018591e92dC0A369Cb51A235fE78C04fAAD9f" // FUND FACTORY PROXY (NOT FUND)
  const FactoryImpl  = await ethers.getContractFactory("FundFactoryUpgradeable", master);

  console.log(`FactoryImpl: ${FactoryImpl}`);
  // 1) register the live proxy (only once, per network/project)
  await upgrades.forceImport(
    FACT_PROXY,
    FactoryImpl,
    { kind: "uups", unsafeAllow: ["storageLayout"], signer: master }
  );

  // 0) check if we have the right owner
  const factory = await ethers.getContractAt("InputFundUpgradeable", FACT_PROXY);

  if ((await factory.owner()).toLowerCase() !== master.address.toLowerCase()) {
    throw new Error("master is NOT the fund owner");
  }
  // 1) old impl address:”
  const before = await upgrades.erc1967.getImplementationAddress(FACT_PROXY);
  console.log("Impl before:", before);
  return
  const newImplAddr = await upgrades.prepareUpgrade(FACT_PROXY, FactoryImpl);

  const upgraded = await upgrades.upgradeProxy(
    FACT_PROXY,
    FactoryImpl,
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

main().catch(console.error);