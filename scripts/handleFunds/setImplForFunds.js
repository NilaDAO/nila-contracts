const { ethers } = require("hardhat");

// scripts/handleFunds/setImplForFunds.js
/*
npx hardhat run scripts/handleFunds/setImplForFunds.js --network amoy
*/

/**
   IMPL history
      V1        : PlantingImpl: 0x63149f8DeB5A722EbD9128f276E6796052a7aEE0
 */

async function main() {
  const _type = "PlantingFundUpgradeable" // or "InputFundUpgradeable"
  // 1) Deploy the NEW PlantingFund logic contract
  const NewImpl = await ethers.getContractFactory(_type);
  const newImpl = await NewImpl.deploy();
  await newImpl.waitForDeployment();
  console.log("🔧 New logic deployed at:", newImpl.target);

  // 2) Point the factory at it
  //    (you must have a signer that is the owner of the factory)

  // ── existing FundFactory proxy ─────────────────────────────
  const factoryAddr = process.env.FUND_FACTORY_PROXY_ADDRESS;
    if (!factoryAddr) {
        throw new Error("Please set FUND_FACTORY_PROXY_ADDRESS in .env");
    }
  const factory = await ethers.getContractAt("FundFactoryUpgradeable",factoryAddr);

  if (_type === "InputFundUpgradeable") {
  const tx = await factory.setInputFundImpl(newImpl.target);
  await tx.wait();
  console.log("✅ Factory now points at:", newImpl.target);
  }
  if (_type === "PlantingFundUpgradeable") {
  const tx = await factory.setPlantingFundImpl(newImpl.target);
  await tx.wait();
  console.log("✅ Factory now points at:", newImpl.target);
  }
}

main().catch(console.error);
