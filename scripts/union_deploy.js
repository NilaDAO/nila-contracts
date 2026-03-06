const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const tokens      = [
    "0x10D11eDD572ccb54D6D59f07521eA071Ed1C326E",  // NILA
    "0x1b8739bB4CdF0089d07097A9Ae5Bd274b29C6F16"   // USDC
  ];
  const oracleSigner = "0x4387bf96c4da8Bd2d44981b276a8862B09BaE072";
  const baseRateBP   = 700;                          // 7% APR
  const unionLeader  = "0xC7FdEf69986317c1770d46C850560D9e469849Cf";
  const fundName     = "Mth Teresa CropCare Fund";
  const fundType     = "InputFund";

  const FertilizerFund = await hre.ethers.getContractFactory("FertilizerFund");
  const fund = await FertilizerFund.deploy(fundName,fundType,tokens, oracleSigner, baseRateBP, unionLeader);

  // Ethers v6 style
  await fund.waitForDeployment();
  console.log("FertilizerFund deployed at:", await fund.getAddress());
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
