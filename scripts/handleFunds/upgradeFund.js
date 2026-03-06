
/**
 rm -rf artifacts cache
 npx hardhat run scripts/handleFunds/upgradeFund.js --network amoy
 */
const { ethers, upgrades } = require("hardhat");

async function input() {
  // make sure the update is done by the owner
  const [master, unionLeader, investor] = await ethers.getSigners();

  const balance = await ethers.provider.getBalance(unionLeader.address)
  console.log(`balance: ${balance}`);

  const FUND_PROXY = "0x48F0bADd2A72Ebe2f29aE8b35a53CA9Ceeafc92b" //"0xaFc72FCE73fBF15B919b4ae64Af4394d64c3A4A5" // FUND FUND PROXY (NOT FACTORY)
  const FundImpl  = await ethers.getContractFactory("InputFundUpgradeable", unionLeader);

  console.log(`FundImpl: ${FundImpl}`);
  // 1) register the live proxy (only once, per network/project)
  await upgrades.forceImport(
    FUND_PROXY,
    FundImpl,
    { kind: "uups", unsafeAllow: ["storageLayout"], signer: unionLeader }
  );

  // 0) check if we have the right owner
  const fund = await ethers.getContractAt("InputFundUpgradeable", FUND_PROXY);

  if ((await fund.owner()).toLowerCase() !== unionLeader.address.toLowerCase()) {
    throw new Error("unionLeader is NOT the fund owner");
  }
  // 1) old impl address:”
  const before = await upgrades.erc1967.getImplementationAddress(FUND_PROXY);
  console.log("Impl before:", before);
  const newImplAddr = await upgrades.prepareUpgrade(FUND_PROXY, FundImpl);

  console.log("Impl after :", newImplAddr);
  return
  const upgraded = await upgrades.upgradeProxy(
    FUND_PROXY,
    FundImpl,
    {
      kind: "uups",
      unsafeAllow: ["storageLayout"],
      redeployImplementation: "always",  // ← force a fresh impl deploy
      signer: unionLeader,
    }
  );
  console.log("proxy upgraded...");
  const newImpl = await upgrades.erc1967.getImplementationAddress(upgraded.target);
  console.log(`🆙  Fund upgraded – new impl: ${newImpl}`);

  const oldCode = await ethers.provider.getCode(before);
  const newCode = await ethers.provider.getCode(newImpl);
  console.log('CODE COMPARISON (should be false):', oldCode === newCode); // should be false
}

/**
 * first upgrade: impl: 0x63149f8DeB5A722EbD9128f276E6796052a7aEE0
 * june 25: 0xC9adB3fC75911Ec846d73afc7df27BdeC8464d40
 */

async function planting() {
  // make sure the update is done by the owner
  const [master, unionLeader, investor] = await ethers.getSigners();

  const balance = await ethers.provider.getBalance(master.address)
  console.log(`balance: ${balance}`, master.address);

  const FUND_PROXY = "0x154ACE2fbe1D3dF1e1A17B8E8EFa6fE8190984d5" //"0xaFc72FCE73fBF15B919b4ae64Af4394d64c3A4A5" // FUND FUND PROXY (NOT FACTORY)
  const FundImpl  = await ethers.getContractFactory("PlantingFundUpgradeable", master);

  console.log(`FundImpl: ${FundImpl}`);
  // 1) register the live proxy (only once, per network/project)
  await upgrades.forceImport(
    FUND_PROXY,
    FundImpl,
    { kind: "uups", unsafeAllow: ["storageLayout"], signer: master }
  );

  // 0) check if we have the right owner
  const fund = await ethers.getContractAt("PlantingFundUpgradeable", FUND_PROXY);

  if ((await fund.owner()).toLowerCase() !== master.address.toLowerCase()) {
    throw new Error("master is NOT the fund owner");
  }
  // 1) old impl address:”
  const before = await upgrades.erc1967.getImplementationAddress(FUND_PROXY);
  console.log("Impl before:", before);
  const newImplAddr = await upgrades.prepareUpgrade(FUND_PROXY, FundImpl);

  console.log("Impl after :", newImplAddr);
  return
  const upgraded = await upgrades.upgradeProxy(
    FUND_PROXY,
    FundImpl,
    {
      kind: "uups",
      unsafeAllow: ["storageLayout"],
      redeployImplementation: "always",  // ← force a fresh impl deploy
      signer: master,
    }
  );
  console.log("proxy upgraded...");
  const newImpl = await upgrades.erc1967.getImplementationAddress(upgraded.target);
  console.log(`🆙  Fund upgraded – new impl: ${newImpl}`);

  const oldCode = await ethers.provider.getCode(before);
  const newCode = await ethers.provider.getCode(newImpl);
  console.log('CODE COMPARISON (should be false):', oldCode === newCode); // should be false
}
//input().catch(console.error);

planting().catch(console.error);
