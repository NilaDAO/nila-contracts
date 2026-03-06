// scripts/handleFunds/registerFund.js
/*
npx hardhat run scripts/handleFunds/registerFund.js --network amoy
*/
const { ethers } = require("hardhat");
/**
 * Register a new fund to the factory, simply setting the mapping fundsByOwner to specific union
 * 
 */

async function main() {
  const [master, unionLeader, investor] = await ethers.getSigners();

  // ── existing FundFactory proxy ─────────────────────────────
  const factoryAddr = process.env.FUND_FACTORY_PROXY_ADDRESS;

  // -- getSigners not needed, factory will use unionAddr as owner.
  const factory     = await ethers.getContractAt("FundFactoryUpgradeable", factoryAddr);

  // ── fund parameters (adjust as needed) ─────────────────────
  const fundName     = "Mth Teresa GroundUp";
  const fundAddress  = "0x154ACE2fbe1D3dF1e1A17B8E8EFa6fE8190984d5";             

  console.log(`
    Registering fund with parameters:
    - factory address : ${factoryAddr}
    - union           : ${unionLeader.address}
    - fund name       : ${fundName}
    - fund address    : ${fundAddress}
  `);
  const preupdate = await factory.getFundsByOwner(unionLeader.address)
  console.log('preupdate funds:', preupdate);
  return
  const tx = await factory.connect(unionLeader).registerUnion(
    unionLeader.address,
    fundAddress,
    fundName,
    'PlantingFundUpgradeable',
  );
  const rc  = await tx.wait();

  // ── read FundCreated(address owner,address fund,string type) event ─
  const evt = rc.logs.find(l => l.fragment?.name === "FundRegistered");
  console.log('fund created with tx hash:', tx.hash )
  console.log(`
    owner          : ${evt.args.union}
    proxy          : ${evt.args.fund}
✅  implementation : ${evt.args.name}
`);
}

main().catch(console.error);
