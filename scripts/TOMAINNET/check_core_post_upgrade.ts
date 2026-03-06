// Verify GenericFundCore post-upgrade state directly from the chain.
// Run: npx hardhat run scripts/TOMAINNET/check_core_post_upgrade.ts --network polygon
const { ethers } = require("hardhat");

const CORE = "0x4173BbaF66A4f9A2705d05B800e8602370366756";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const EXPECTED_CS003_IMPL = "0xFE3E81b2FFb19d66B6E7aDCa5584DE1695312ECa";

async function main() {
  const block = await ethers.provider.getBlockNumber();
  console.log(`Block: ${block}`);

  // 1. Read the ERC-1967 impl slot from the live proxy
  const raw = await ethers.provider.getStorage(CORE, IMPL_SLOT);
  const impl = ethers.getAddress("0x" + raw.slice(26));
  const implMatch = impl.toLowerCase() === EXPECTED_CS003_IMPL.toLowerCase();
  console.log(`\nERC-1967 impl slot:`);
  console.log(`  live   : ${impl}`);
  console.log(`  CS003  : ${EXPECTED_CS003_IMPL}`);
  console.log(`  ${implMatch ? "✅ impl matches CS003 deployment" : "❌ impl does NOT match — proxy not yet pointing to CS003"}`);

  // 2. Slot 22: treasuryFeeBP (off=0, uint16), rainyFeeBP (off=2, uint16), fxPoolAddr (off=4, address)
  const slot22 = await ethers.provider.getStorage(CORE, 22);
  const hex = slot22.slice(2).padStart(64, "0");
  const treasuryFeeBP = parseInt(hex.slice(60, 64), 16);
  const rainyFeeBP    = parseInt(hex.slice(56, 60), 16);
  // address at offset 4: bytes 4..23 from the right = hex chars [64-48..64-8] = [16..56]
  const fxRaw = "0x" + hex.slice(16, 56);
  const fxIsZero = hex.slice(16, 56) === "0".repeat(40);
  const fxPoolAddr = fxIsZero ? "0x00..00 (not set)" : ethers.getAddress(fxRaw);

  console.log(`\nSlot 22 raw: 0x${hex}`);
  console.log(`  treasuryFeeBP (off=0) : ${treasuryFeeBP} bp`);
  console.log(`  rainyFeeBP    (off=2) : ${rainyFeeBP} bp`);
  console.log(`  fxPoolAddr    (off=4) : ${fxPoolAddr}`);

  // 3. Slot 23: nonces mapping root (must be 0)
  const slot23 = await ethers.provider.getStorage(CORE, 23);
  console.log(`\nSlot 23 (nonces mapping root): ${slot23}`);
  console.log(`  ${slot23 === "0x" + "0".repeat(64) ? "✅ correct (mappings always have zero root)" : "❌ unexpected non-zero"}`);

  // 4. Sanity: call a view function through the new ABI to prove the impl is responding
  const core = await ethers.getContractAt("GenericFundCore", CORE);
  const nin = await core.nin();
  console.log(`\ncore.nin() via new ABI  : ${nin}`);
  console.log(`  ${nin.toLowerCase() === "0xd1f49598e42d30cd900ea86244485ca0647d31c7" ? "✅" : "❌"} matches NIN_MAIN`);

  const fxPoolFromGetter = await core.fxPoolAddr();
  console.log(`core.fxPoolAddr()       : ${fxPoolFromGetter}`);
  console.log(`  ${fxPoolFromGetter === ethers.ZeroAddress ? "ℹ️  zero — setFxPoolAddr not yet called" : "✅ " + fxPoolFromGetter}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
