// Check NilaNIN role holders to determine who can grant BURNER_ROLE to FxPool.
// Run: npx hardhat run scripts/TOMAINNET/check_nin_roles.ts --network polygon
const { ethers } = require("hardhat");

const NIN    = "0xD1F49598E42D30Cd900Ea86244485ca0647d31C7";
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const CORE   = "0x4173BbaF66A4f9A2705d05B800e8602370366756";

const KNOWN = {
  "0xf2ea7d0870051903a64c075c22e95fb816d4fa64": "OWNER_ADDRESS (hot key)",
  "0x7687dd5c8ce4e42ebdd4a94ccd4fc9c4a7f18528": "FX_OWNER_ADDRESS (Ledger)",
  [FXPOOL.toLowerCase()]: "FxPool proxy",
  [CORE.toLowerCase()]:   "GenericFundCore proxy",
};

async function checkRole(nin: any, role: string, label: string, suspects: string[]) {
  const roleHash = role === "DEFAULT_ADMIN" ? ethers.ZeroHash : await nin[role]();
  console.log(`\n${label} (${roleHash.slice(0,10)}...):`);
  for (const addr of suspects) {
    const has = await nin.hasRole(roleHash, addr);
    const who = KNOWN[addr.toLowerCase()] ?? addr;
    console.log(`  ${has ? "✅" : "  "} ${who}  (${addr})`);
  }
}

async function main() {
  const nin = await ethers.getContractAt("NilaNIN", NIN);

  const suspects = [
    "0xF2Ea7D0870051903a64c075c22E95FB816d4fA64",
    "0x7687dd5c8ce4e42ebdd4a94ccd4fc9c4a7f18528",
    FXPOOL,
    CORE,
  ];

  await checkRole(nin, "DEFAULT_ADMIN", "DEFAULT_ADMIN_ROLE", suspects);
  await checkRole(nin, "MINTER_ROLE",   "MINTER_ROLE",        suspects);
  await checkRole(nin, "BURNER_ROLE",   "BURNER_ROLE",        suspects);
}

main().catch(console.error);
