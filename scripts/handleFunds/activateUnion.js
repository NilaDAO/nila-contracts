// scripts/handleFunds/registerFund.js
/*
npx hardhat run scripts/handleFunds/activateUnion.js --network amoy
*/
const { ethers } = require("hardhat");
/**
 * Register a new fund to the factory, simply setting the mapping fundsByOwner to specific union
 * 
 */

async function main() {
  const [master, unionLeader, investor] = await ethers.getSigners();

  console.log('master', master.address)
  
  // ── existing FundFactory proxy ─────────────────────────────
  const fundProxy = "0x154ACE2fbe1D3dF1e1A17B8E8EFa6fE8190984d5";

  // -- getSigners not needed, factory will use unionAddr as owner.
  const fund = await ethers.getContractAt("PlantingFundUpgradeable", fundProxy);

  // -- set union location as string format 'lat,lng' comma seperation
  const loc = '11.878691,78.964752'

  // ── fund parameters (adjust as needed) ─────────────────────
  const tx = await fund.connect(master).activateUnion(
    unionLeader.address,
    loc
  );
  const rc  = await tx.wait();
  
  console.log('Union activated with tx hash:', tx.hash );
  console.log(`rc's logs:`, rc.logs);

  
}

main().catch(console.error);
