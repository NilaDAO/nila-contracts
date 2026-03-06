
/*
rm -rf artifacts cache
npx hardhat run scripts/handleFundFactory/deployFactory.js --network amoy
*/
const { ethers, upgrades } = require("hardhat");

async function main() {
  // signer 0 will be owner
  const [master, unionLeader, investor] = await ethers.getSigners();
  
  const Factory = await ethers.getContractFactory("FundFactoryUpgradeable");

  // ── deploy UUPS proxy ──────────────────────────────────────────
  const proxy = await upgrades.deployProxy(
    Factory,
    [master.address],              // initializer(owner, fundLogic)
    { kind: "uups", initializer: "initialize" }
  );
  await proxy.waitForDeployment();

  // ── grab implementation slot ──────────────────────────────────
  const impl = await upgrades.erc1967.getImplementationAddress(proxy.target);

  console.log(`
🟢  FundFactoryUpgradeable deployed!

   proxy address : ${proxy.target}
   impl  address : ${impl}
   owner         : ${master.address}
  `);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
