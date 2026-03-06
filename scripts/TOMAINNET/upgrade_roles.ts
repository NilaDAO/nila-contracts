// npx hardhat run scripts/TOMAINNET/upgrade_roles.ts --network amoy
const { ethers } = require("hardhat");


function addr(x: string | undefined, name: string) {
  if (!x) throw new Error(`Missing ${name}`);
  return ethers.getAddress(x.startsWith("0x") ? x : `0x${x}`);
}

async function main() {
  const CORE_PROXY   = addr(process.env.COREPROXY, "CORE (proxy)");
  const VIEWER_PROXY = addr(process.env.VIEWERPROXY, "VIEWER (proxy)");
  const ORACLE       = process.env.ORACLE_SIGNER_MAIN ? addr(process.env.ORACLE_SIGNER_MAIN, "ORACLE") : undefined;

  const [owner] = await ethers.getSigners();
  console.log("Signer:", await owner.getAddress());

  // 1) Deploy fresh RolesRegistry (non-upgradeable)
  const RolesF = await ethers.getContractFactory("RolesRegistry", owner);
  const roles  = await RolesF.deploy(await owner.getAddress());
  await roles.waitForDeployment();
  const rolesAddr = await roles.getAddress();
  console.log("RolesRegistry deployed at:", rolesAddr);

  // 2) Wire core/viewer to the new registry
  const core = await ethers.getContractAt("GenericFundCore", CORE_PROXY, owner);
  const viewer = await ethers.getContractAt("GenericFundViewer", VIEWER_PROXY, owner);

  console.log("Setting core.setRoles...");
  await (await core.setRoles(rolesAddr)).wait();
  console.log("Setting viewer.setRoles...");
  await (await viewer.setRoles(rolesAddr)).wait();

  // 3) Allow core in the registry
  console.log("Marking core as allowed in RolesRegistry...");
  await (await roles.setCore(CORE_PROXY, true)).wait();

  if (ORACLE) {
    console.log("Setting oracle role...");
    await (await roles.setOracle(ORACLE, true)).wait();
  }

  console.log("Done. Roles registry wired.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
