// npx hardhat run scripts/TOMAINNET/add_roles.ts --network polygon
const { ethers  } = require("hardhat");

async function main() {
  const rolesAddr   = process.env.ROLES_MAIN;
  const oracleAddr  = process.env.ORACLE_SIGNER_MAIN;
  const unionAddr   = "0xF18E4966731bD6D3a56c1eb23Da7C708c9C48070";    // set this in your env before running
  const leaderAddr  = "0xaf7030023CF86611FfC5a71798a0f7022210F2b3";   // set this in your env before running

  if (!rolesAddr) throw new Error("ROLES_MAIN not set");
  if (!oracleAddr) throw new Error("ORACLE_SIGNER_MAIN not set");
  if (!unionAddr) throw new Error("UNION_ADDR not set");
  if (!leaderAddr) throw new Error("LEADER_ADDR not set");

  const [signer] = await ethers.getSigners();
  console.log("Using signer:", signer.address);
  console.log("Roles registry:", rolesAddr);
  console.log("Target union:", unionAddr);
  console.log("Oracle to add:", oracleAddr);
  console.log("Leader to add:", leaderAddr);

  const roles = await ethers.getContractAt("RolesRegistry", rolesAddr, signer);

  // Oracle
  const isOracle = await roles.oracles(oracleAddr);
  if (isOracle) {
    console.log("Oracle already set; skipping");
  } else {
    const tx = await roles.setOracle(oracleAddr, true);
    console.log("Setting oracle... tx:", tx.hash);
    await tx.wait();
    console.log("Oracle added");
  }

  // Leader for the union
  const isLeader = await roles.leaders(unionAddr, leaderAddr);
  if (isLeader) {
    console.log("Leader already set for union; skipping");
  } else {
    const tx = await roles.setLeader(unionAddr, leaderAddr, true);
    console.log("Setting leader... tx:", tx.hash);
    await tx.wait();
    console.log("Leader added for union");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
