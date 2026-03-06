// Check who holds ONLY_OWNER role on FxPool
const { ethers } = require("hardhat");
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
async function main() {
  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const ONLY_OWNER = await fx.ONLY_OWNER();
  const DEFAULT_ADMIN = "0x0000000000000000000000000000000000000000000000000000000000000000";
  console.log("ONLY_OWNER role:", ONLY_OWNER);
  const roleAdmin = await fx.getRoleAdmin(ONLY_OWNER);
  console.log("Role admin of ONLY_OWNER:", roleAdmin);
  const memberCount = await fx.getRoleMemberCount(ONLY_OWNER);
  console.log("ONLY_OWNER member count:", memberCount.toString());
  for (let i = 0; i < memberCount; i++) {
    const member = await fx.getRoleMember(ONLY_OWNER, i);
    console.log(`  member[${i}]: ${member}`);
  }
  const adminCount = await fx.getRoleMemberCount(DEFAULT_ADMIN);
  console.log("\nDEFAULT_ADMIN_ROLE member count:", adminCount.toString());
  for (let i = 0; i < adminCount; i++) {
    const member = await fx.getRoleMember(DEFAULT_ADMIN, i);
    console.log(`  member[${i}]: ${member}`);
  }
  // Check our signer
  const [signer] = await ethers.getSigners();
  const signerAddr = await signer.getAddress();
  console.log("\nSigner:", signerAddr);
  console.log("Has ONLY_OWNER:", await fx.hasRole(ONLY_OWNER, signerAddr));
  console.log("Has DEFAULT_ADMIN:", await fx.hasRole(DEFAULT_ADMIN, signerAddr));
}
main().catch(console.error);
