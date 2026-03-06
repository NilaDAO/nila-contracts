// Set oracle role in RolesRegistry for GenericFundCore / GenericFundViewer
// Signer: OWNER_PRIVATE_KEY (0xF2Ea7D0870051903a64c075c22E95FB816d4fA64)
// npx hardhat run scripts/handleRoles/setOracle.js --network polygon

const { ethers } = require("hardhat");

async function main() {
  const [owner] = await ethers.getSigners();
  console.log("Signer:", owner.address);

  const rolesAddr  = process.env.ROLES_MAIN;
  const oracleAddr = process.env.ORACLE_SIGNER_MAIN;

  console.log("RolesRegistry:", rolesAddr);
  console.log("Oracle addr  :", oracleAddr);

  const roles = await ethers.getContractAt(
    ["function setOracle(address,bool) external",
     "function isOracle(address) view returns (bool)",
     "function owner() view returns (address)"],
    rolesAddr,
    owner
  );

  // Sanity checks
  const contractOwner = await roles.owner();
  if (contractOwner.toLowerCase() !== owner.address.toLowerCase()) {
    throw new Error(`Signer ${owner.address} is not owner (${contractOwner})`);
  }

  const alreadySet = await roles.isOracle(oracleAddr);
  if (alreadySet) {
    console.log("Oracle is already registered — nothing to do.");
    return;
  }

  const tx = await roles.setOracle(oracleAddr, true);
  console.log("Tx sent:", tx.hash);
  await tx.wait();
  console.log("Done — oracle registered.");

  const confirmed = await roles.isOracle(oracleAddr);
  console.log("isOracle confirmed:", confirmed);
}

main().catch((e) => { console.error(e); process.exit(1); });
