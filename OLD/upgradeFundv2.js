
/**
 rm -rf artifacts cache
 npx hardhat run scripts/handleFunds/upgradeFund.js --network amoy
 */
const { ethers, upgrades } = require("hardhat");

async function main() {
  // make sure the update is done by the owner
  const [master, unionLeader, investor] = await ethers.getSigners();

  const FUND_PROXY = "0x48F0bADd2A72Ebe2f29aE8b35a53CA9Ceeafc92b" //"0xaFc72FCE73fBF15B919b4ae64Af4394d64c3A4A5" // FUND FUND PROXY (NOT FACTORY)
  const FundImpl  = await ethers.getContractFactory("InputFundUpgradeable", unionLeader);

  // 1) deploy new impl
  const newImplAddr = await upgrades.deployImplementation(FundImpl, { kind: "uups", signer: unionLeader });
  console.log('new impl addr', newImplAddr)
  // 2) call upgradeTo on the proxy
  const proxy = await ethers.getContractAt("InputFundUpgradeable", FUND_PROXY, unionLeader);
  await proxy.upgradeTo(newImplAddr);

  console.log("now pointing at:", newImplAddr);

  }

main().catch(console.error);
