// Verify NilaFxPool post-CS003-upgrade state from chain.
// Run: npx hardhat run scripts/TOMAINNET/check_fxpool_post_upgrade.ts --network polygon

const { ethers } = require("hardhat");

const FXPOOL    = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const CS003_IMPL = "0xc1a3cB3efC11C00dbf1873e7E17b3518e233a3c4";

const KNOWN = {
  USDT: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
  NIN:  "0xD1F49598E42D30Cd900Ea86244485ca0647d31C7",
};

async function main() {
  const block = await ethers.provider.getBlockNumber();
  console.log(`Block: ${block}\n`);

  // 1. Impl slot
  const raw  = await ethers.provider.getStorage(FXPOOL, IMPL_SLOT);
  const impl = ethers.getAddress("0x" + raw.slice(26));
  const implOk = impl.toLowerCase() === CS003_IMPL.toLowerCase();
  console.log(`ERC-1967 impl:`);
  console.log(`  live  : ${impl}`);
  console.log(`  CS003 : ${CS003_IMPL}`);
  console.log(`  ${implOk ? "✅ matches CS003" : "❌ does NOT match CS003"}`);

  // 2. Core data slots still intact
  const slotNames: Record<number, string> = {
    0:  "usdt (address)",
    1:  "nin + usdtDecimals (packed)",
    2:  "inrUsdOracle + oracleDecimals (packed)",
    3:  "fxTreasuryUsdt",
    4:  "fxThresholdBps",
    5:  "maxOracleDelay",
    6:  "globalCapPerDay",
    7:  "epochDuration",
    8:  "lastFxRate",
    9:  "lastEpochTimestamp",
    15: "globalLimit (struct: windowStart + amount)",
  };
  console.log(`\nKey storage slots:`);
  for (const [s, name] of Object.entries(slotNames)) {
    const val = await ethers.provider.getStorage(FXPOOL, Number(s));
    console.log(`  slot ${String(s).padEnd(3)} ${name.padEnd(42)} ${val}`);
  }

  // 3. New CS003 escrow slots (all must be 0 — nothing configured yet)
  console.log(`\nNew CS003 slots (expect all zeros):`);
  const newSlots: Record<number, string> = {
    16: "nextEscrowId",
    17: "escrows (mapping root)",
    18: "totalEscrowedNin",
    19: "escrowDuration",
    20: "fundCore",
  };
  let allZero = true;
  for (const [s, name] of Object.entries(newSlots)) {
    const val = await ethers.provider.getStorage(FXPOOL, Number(s));
    const ok = val === "0x" + "0".repeat(64);
    if (!ok) allZero = false;
    console.log(`  ${ok ? "✅" : "❌"} slot ${s} ${name.padEnd(25)} = ${val}`);
  }

  // 4. New CS003 ABI getters
  console.log(`\nCS003 ABI getters (via upgraded proxy):`);
  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const nextEscrowId    = await fx.nextEscrowId();
  const escrowDuration  = await fx.escrowDuration();
  const fundCore        = await fx.fundCore();
  const totalEscrowedNin = await fx.totalEscrowedNin();
  console.log(`  nextEscrowId     : ${nextEscrowId}    (expect 0)`);
  console.log(`  escrowDuration   : ${escrowDuration}    (expect 0 — not configured yet)`);
  console.log(`  fundCore         : ${fundCore}  (expect 0x00 — not configured yet)`);
  console.log(`  totalEscrowedNin : ${totalEscrowedNin}    (expect 0)`);

  // 5. Existing getters still work
  console.log(`\nExisting getters (must still work):`);
  const usdt_ = await fx.usdt();
  const nin_  = await fx.nin();
  const fxTreasury = await fx.fxTreasuryUsdt();
  const globalCapPerDay = await fx.globalCapPerDay();
  const usdtOk = usdt_.toLowerCase() === KNOWN.USDT.toLowerCase();
  const ninOk  = nin_.toLowerCase()  === KNOWN.NIN.toLowerCase();
  console.log(`  ${usdtOk ? "✅" : "❌"} usdt()           = ${usdt_}`);
  console.log(`  ${ninOk  ? "✅" : "❌"} nin()            = ${nin_}`);
  console.log(`  fxTreasuryUsdt() = ${ethers.formatUnits(fxTreasury, 6)} USDT`);
  console.log(`  globalCapPerDay  = ${ethers.formatUnits(globalCapPerDay, 6)} USDT/day`);

  // 6. USDT balance
  const usdt = await ethers.getContractAt("IERC20", KNOWN.USDT);
  const bal  = await usdt.balanceOf(FXPOOL);
  console.log(`\n  USDT.balanceOf(fxPool) = ${ethers.formatUnits(bal, 6)} USDT`);

  const allOk = implOk && allZero && usdtOk && ninOk;
  console.log(`\n${"═".repeat(60)}`);
  console.log(allOk
    ? "✅ FxPool CS003 upgrade fully verified"
    : "❌ Issues detected — review above");
  console.log(`${"═".repeat(60)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
