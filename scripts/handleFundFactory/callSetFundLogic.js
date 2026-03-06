
/*
rm -rf artifacts cache
npx hardhat run scripts/handleFundFactory/callSetFundLogic.js --network amoy
*/

/**
 * v1: 'INPUT', 0x24FDE2709333e6e63ACc200f143ad66EC29EE7b3  (may 10,2025)
 * v2: 'INPUT', 0x15d58a1fB5a3937723283DEa01f87bC73d5224cd  (may 10,2025)
 */

const { ethers, upgrades } = require("hardhat");

async function main() {

  // signer 0 will be owner
  const [master, unionLeader, investor] = await ethers.getSigners();
  const proxyAddr = process.env.FUND_FACTORY_PROXY_ADDRESS

  // 1️⃣  attach to the *deployed* proxy
  const factory = await ethers.getContractAt(
    "FundFactoryUpgradeable",
    proxyAddr,
    master                     // connect with owner signer
  );

  const FUND_ID = "INPUT" //ethers.id("INPUT");       // ↔ keccak256("INPUT")
  // TO SEE IF ALREADY SET: only fetch fundLogic with ID
  //console.log(await factory.fundLogic(ethers.id(FUND_ID)))

  /* 2️⃣ ──generate a new InputFund impl ──────────────────────── */
  const FundImplFactory = await ethers.getContractFactory("InputFundUpgradeable");
  const fundImpl        = await FundImplFactory.deploy();
  await fundImpl.waitForDeployment();

  console.log('fundImpl.address ', fundImpl.target )

  // 3 call the setter
  const tx = await factory.setFundLogic(
    FUND_ID,        // bytes32("INPUT")
    fundImpl.target                    // implementation address
  );
  await tx.wait();
  // verify if ID has been set with similar target
  console.log(await factory.fundLogic(ethers.id(FUND_ID)))
  console.log("✅  INPUT logic set to:", fundImpl.target );

}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
