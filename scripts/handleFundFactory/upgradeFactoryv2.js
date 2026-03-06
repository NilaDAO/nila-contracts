
/**
 rm -rf artifacts cache
 npx hardhat run scripts/handleFunds/upgradeFund.js --network amoy
 */
const { ethers, upgrades } = require("hardhat");

async function main() {
  // make sure the update is done by the owner
  const [master, unionLeader, investor] = await ethers.getSigners();

  const FACT_PROXY = "0xaD3018591e92dC0A369Cb51A235fE78C04fAAD9f" // FUND FACTORY PROXY (NOT FUND)
  const FactoryImpl  = await ethers.getContractFactory("FundFactoryUpgradeable", master);

  // 1) deploy new impl
  const newImplAddr = await upgrades.deployImplementation(FactoryImpl, { kind: "uups", signer: master });
  console.log('new impl addr', newImplAddr)
  // 2) call upgradeTo on the proxy
  const proxy = await ethers.getContractAt("FundFactoryUpgradeable", FACT_PROXY, master);
  await proxy.upgradeTo(newImplAddr);

  console.log("now pointing at:", newImplAddr);

  }

main().catch(console.error);
