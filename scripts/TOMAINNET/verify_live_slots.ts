// Reads actual storage slot values from the live Polygon proxy contracts
// and verifies them against known-good expected values.
// This proves the storage layout is correct from on-chain state, not just
// from local manifest files.
//
// Run: npx hardhat run scripts/TOMAINNET/verify_live_slots.ts --network polygon

const { ethers } = require("hardhat");

const CORE   = "0x4173BbaF66A4f9A2705d05B800e8602370366756";
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const VIEWER = "0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA";

// Known on-chain addresses to cross-check against slot values
const KNOWN = {
  NIN:   "0xD1F49598E42D30Cd900Ea86244485ca0647d31C7",
  ROLES: "0xc0a03f3A5319cE29205AeED7FDC0e6013e3E9bF9",
  USDT:  "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", // USDT on Polygon
  CORE:  "0x4173BbaF66A4f9A2705d05B800e8602370366756",
};

function readAddr(slotValue: string): string {
  // Storage returns 32 bytes; address is the lower 20 bytes
  return ethers.getAddress("0x" + slotValue.slice(26));
}

function readUint16(slotValue: string, byteOffset: number): number {
  // Read 2 bytes at given byte offset from the 32-byte slot value (big-endian, right-aligned in slot)
  // Slot value is hex, 64 chars = 32 bytes. Right-most byte = offset 0 in storage.
  const hex = slotValue.slice(2); // strip 0x
  // offset 0 = rightmost bytes (index 62–63 in hex string)
  const start = 64 - (byteOffset + 2) * 2;
  return parseInt(hex.slice(start, start + 4), 16);
}

async function check(label: string, actual: string, expected: string): Promise<boolean> {
  const pass = actual.toLowerCase() === expected.toLowerCase();
  console.log(`  ${pass ? "✅" : "❌"} ${label}`);
  console.log(`       expected: ${expected}`);
  console.log(`       actual  : ${actual}`);
  return pass;
}

async function main() {
  const block = await ethers.provider.getBlockNumber();
  console.log(`Reading from Polygon mainnet at block ${block}\n`);

  let allPass = true;

  // ── GenericFundCore ────────────────────────────────────────────────────────
  console.log("═".repeat(60));
  console.log("GenericFundCore proxy:", CORE);
  console.log("═".repeat(60));

  // slot 0 = nin (address)
  const slot0 = await ethers.provider.getStorage(CORE, 0);
  allPass = await check("slot 0 = nin", readAddr(slot0), KNOWN.NIN) && allPass;

  // slot 2 = roles (address)
  const slot2 = await ethers.provider.getStorage(CORE, 2);
  allPass = await check("slot 2 = roles", readAddr(slot2), KNOWN.ROLES) && allPass;

  // slot 22 = packed { treasuryFeeBP (off=0, uint16), rainyFeeBP (off=2, uint16) }
  const slot22 = await ethers.provider.getStorage(CORE, 22);
  const treasuryFeeBP = readUint16(slot22, 0);
  const rainyFeeBP    = readUint16(slot22, 2);
  console.log(`\n  Slot 22 raw: ${slot22}`);
  console.log(`  ℹ️  slot 22 offset 0 (treasuryFeeBP) = ${treasuryFeeBP} bp  (expect ~100 = 1%)`);
  console.log(`  ℹ️  slot 22 offset 2 (rainyFeeBP)    = ${rainyFeeBP} bp  (expect ~200 = 2%)`);

  // slot 22 offset 4 = fxPoolAddr (address, 20 bytes starting at byte 4)
  // In the 32-byte slot (hex 64 chars), byte offset 4 from right = chars [64-(4+20)*2 .. 64-4*2] = [16..56]
  const slot22hex = slot22.slice(2);
  const fxPoolAddrRaw = "0x" + slot22hex.slice(64 - (4 + 20) * 2, 64 - 4 * 2);
  const fxPoolAddrInSlot = fxPoolAddrRaw === "0x" + "0".repeat(40)
    ? "0x0000000000000000000000000000000000000000 (not set yet)"
    : ethers.getAddress(fxPoolAddrRaw);
  console.log(`  ℹ️  slot 22 offset 4 (fxPoolAddr)    = ${fxPoolAddrInSlot}  (0 = setFxPoolAddr not yet called post-upgrade)`);

  // slot 23 = nonces mapping (mapping slot is always 0x00...00 — values are at keccak(key||slot))
  const slot23 = await ethers.provider.getStorage(CORE, 23);
  console.log(`\n  ℹ️  slot 23 (nonces mapping head)    = ${slot23}  (expect 0x00...00 for any mapping)`);

  // ── NilaFxPool ─────────────────────────────────────────────────────────────
  console.log("\n" + "═".repeat(60));
  console.log("NilaFxPool proxy:", FXPOOL);
  console.log("═".repeat(60));

  // slot 0 = usdt (address)
  const fxSlot0 = await ethers.provider.getStorage(FXPOOL, 0);
  allPass = await check("slot 0 = usdt", readAddr(fxSlot0), KNOWN.USDT) && allPass;

  // slot 1 = packed { nin (address, off=0), usdtDecimals (uint8, off=20) }
  const fxSlot1 = await ethers.provider.getStorage(FXPOOL, 1);
  const ninAddr = readAddr(fxSlot1);
  allPass = await check("slot 1 = nin (lower 20 bytes)", ninAddr, KNOWN.NIN) && allPass;

  // slot 16 = __gap[0] (now nextEscrowId after CS003 upgrade — will read 0 on pre-upgrade chain)
  const fxSlot16 = await ethers.provider.getStorage(FXPOOL, 16);
  console.log(`\n  ℹ️  slot 16 (was __gap[0], post-CS003 = nextEscrowId) = ${fxSlot16}`);
  console.log(`       (0x00...00 = pre-upgrade chain, or no escrows created yet)`);

  // slot 21 = __gap array (was slot 16 with 40 elements, post-CS003 slot 21 with 35 elements)
  const fxSlot21 = await ethers.provider.getStorage(FXPOOL, 21);
  console.log(`  ℹ️  slot 21 (post-CS003 = __gap[0])                   = ${fxSlot21}`);

  // ── GenericFundViewer ────────────────────────────────────────────────────────
  console.log("\n" + "═".repeat(60));
  console.log("GenericFundViewer proxy:", VIEWER);
  console.log("═".repeat(60));
  // Layout: slot0=loansByBorrower(mapping), slot1=unions(mapping), slot2=fundTypeEnabled(mapping)
  //         slot3=core(address), slot4=roles(address), slot5=__gap[48]
  // Mappings always read 0x00 at their root slot — we verify the addresses at slots 3 and 4.

  const vSlot3 = await ethers.provider.getStorage(VIEWER, 3);
  allPass = await check("slot 3 = core", readAddr(vSlot3), KNOWN.CORE) && allPass;

  const vSlot4 = await ethers.provider.getStorage(VIEWER, 4);
  allPass = await check("slot 4 = roles", readAddr(vSlot4), KNOWN.ROLES) && allPass;

  // slot 5 = __gap[48] head — must be zero (no data written into gap)
  const vSlot5 = await ethers.provider.getStorage(VIEWER, 5);
  const vSlot5IsZero = vSlot5 === "0x" + "0".repeat(64);
  console.log(`\n  ${vSlot5IsZero ? "✅" : "❌"} slot 5 (__gap[0]) = ${vSlot5}  (expect 0x00...00)`);
  if (!vSlot5IsZero) allPass = false;

  // ── Summary ─────────────────────────────────────────────────────────────────
  console.log("\n" + "═".repeat(60));
  console.log(allPass ? "✅ All address checks PASSED" : "❌ Some checks FAILED — investigate before upgrading");
  console.log("═".repeat(60));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
