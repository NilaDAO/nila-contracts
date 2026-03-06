// Upgrade NilaFxPool to CS003 implementation.
// Takes a full pre-upgrade slot snapshot, upgrades, then verifies every slot matches.
//
// LEDGER: run against the polygon-ledger network so the Ledger at FX_OWNER_ADDRESS signs.
//   Ledger must be: unlocked, Ethereum app open, blind signing enabled.
//   Two Ledger prompts will appear: (1) deploy new impl  (2) call upgradeToAndCall on proxy.
//
// Run: npx hardhat run scripts/TOMAINNET/do_upgrade_fxpool.ts --network polygon-ledger

const { ethers, upgrades } = require("hardhat");

const FXPOOL    = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

// Known addresses for cross-checks
const KNOWN = {
  USDT:  "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
  NIN:   "0xD1F49598E42D30Cd900Ea86244485ca0647d31C7",
};

async function snap(label: string, slot: number | string): Promise<string> {
  const val = await ethers.provider.getStorage(FXPOOL, slot);
  return val;
}

async function main() {
  const [owner] = await ethers.getSigners();
  const block = await ethers.provider.getBlockNumber();
  const bal   = await ethers.provider.getBalance(owner);
  console.log(`Block   : ${block}`);
  console.log(`Signer  : ${await owner.getAddress()}`);
  console.log(`Balance : ${ethers.formatEther(bal)} MATIC`);

  // 1. Owner check
  const fxRO = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const hasRole = await fxRO.hasRole(await fxRO.ONLY_OWNER(), await owner.getAddress());
  if (!hasRole) throw new Error(`Signer does not hold ONLY_OWNER role`);
  console.log(`ONLY_OWNER role ✅`);

  // 2. Full pre-upgrade slot snapshot — every slot that holds live data
  console.log(`\n${"─".repeat(60)}`);
  console.log(`PRE-UPGRADE SNAPSHOT (all slots read from chain)`);
  console.log(`${"─".repeat(60)}`);

  const pre: Record<string, string> = {};

  // Slots 0–15: all live config/state
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
    10: "twapRate",
    11: "lastObsRate",
    12: "lastObsTimestamp + twapWindow (packed)",
    13: "maxRawVsTwapDiffBps",
    14: "redeemPaused",
    15: "globalLimit (struct: windowStart + amount)",
    // 16–20: __gap[0..4] — all zeros pre-upgrade, become escrow vars post-upgrade
    16: "__gap[0]  → post-CS003: nextEscrowId",
    17: "__gap[1]  → post-CS003: escrows (mapping root)",
    18: "__gap[2]  → post-CS003: totalEscrowedNin",
    19: "__gap[3]  → post-CS003: escrowDuration",
    20: "__gap[4]  → post-CS003: fundCore",
  };

  for (const [slotNum, name] of Object.entries(slotNames)) {
    const val = await ethers.provider.getStorage(FXPOOL, Number(slotNum));
    pre[slotNum] = val;
    console.log(`  slot ${String(slotNum).padEnd(3)} ${name.padEnd(45)} ${val}`);
  }

  // 3. Also read USDT ERC20 balance (lives in USDT contract storage, unaffected by upgrade)
  const usdt = await ethers.getContractAt("IERC20", KNOWN.USDT);
  const usdtBalPre = await usdt.balanceOf(FXPOOL);
  console.log(`\n  USDT.balanceOf(fxPool) = ${ethers.formatUnits(usdtBalPre, 6)} USDT`);
  console.log(`  fxTreasuryUsdt (state) = ${ethers.formatUnits(BigInt(pre[3]), 6)} USDT`);

  // 4. Build factory and validate
  const FxF = await ethers.getContractFactory("NilaFxPool", { signer: owner });

  console.log(`\nvalidateUpgrade …`);
  await upgrades.validateUpgrade(FXPOOL, FxF, { kind: "uups" });
  console.log(`validateUpgrade ✅`);

  // 5. Upgrade
  const implBefore = ethers.getAddress("0x" + (await ethers.provider.getStorage(FXPOOL, IMPL_SLOT)).slice(26));
  console.log(`\nImpl BEFORE (chain): ${implBefore}`);
  console.log(`upgradeProxy (redeployImplementation=always) …`);

  const upgraded = await upgrades.upgradeProxy(FXPOOL, FxF, {
    kind: "uups",
    redeployImplementation: "always",
  });
  console.log(`Deploy tx hash: ${upgraded.deployTransaction?.hash ?? "(none)"}`);

  // 6. Post-upgrade: read impl from chain
  const implAfter = ethers.getAddress("0x" + (await ethers.provider.getStorage(FXPOOL, IMPL_SLOT)).slice(26));
  console.log(`Impl AFTER  (chain): ${implAfter}`);
  console.log(`Changed: ${implBefore.toLowerCase() !== implAfter.toLowerCase() ? "✅ YES" : "⚠️  NO (same address)"}`);

  // 7. Post-upgrade: verify every pre-upgrade slot is unchanged
  console.log(`\n${"─".repeat(60)}`);
  console.log(`POST-UPGRADE SLOT VERIFICATION`);
  console.log(`${"─".repeat(60)}`);

  let allOk = true;

  // Slots 0–15 must be byte-for-byte identical
  for (let i = 0; i <= 15; i++) {
    const post = await ethers.provider.getStorage(FXPOOL, i);
    const ok = post.toLowerCase() === pre[i].toLowerCase();
    if (!ok) allOk = false;
    console.log(`  ${ok ? "✅" : "❌"} slot ${String(i).padEnd(3)} ${slotNames[i] ?? ""}`);
    if (!ok) {
      console.log(`       BEFORE: ${pre[i]}`);
      console.log(`       AFTER : ${post}`);
    }
  }

  // Slots 16–20 were __gap (zeros) before; must still be zeros after
  // (escrow vars all default to 0 — nothing written yet)
  for (let i = 16; i <= 20; i++) {
    const post = await ethers.provider.getStorage(FXPOOL, i);
    const ok = post === "0x" + "0".repeat(64);
    if (!ok) allOk = false;
    console.log(`  ${ok ? "✅" : "❌"} slot ${String(i).padEnd(3)} ${slotNames[i] ?? ""}  = ${post}`);
  }

  // 8. USDT balance unchanged (lives in USDT token contract — unaffected)
  const usdtBalPost = await usdt.balanceOf(FXPOOL);
  const usdtOk = usdtBalPre === usdtBalPost;
  if (!usdtOk) allOk = false;
  console.log(`  ${usdtOk ? "✅" : "❌"} USDT.balanceOf unchanged: ${ethers.formatUnits(usdtBalPost, 6)} USDT`);

  // 9. Spot-check new CS003 getters via ABI
  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const nextEscrowId    = await fx.nextEscrowId();
  const escrowDuration  = await fx.escrowDuration();
  const fundCore        = await fx.fundCore();
  const totalEscrowedNin = await fx.totalEscrowedNin();
  console.log(`\n  New CS003 getters (all expect 0 — not yet configured):`);
  console.log(`  nextEscrowId     : ${nextEscrowId}`);
  console.log(`  escrowDuration   : ${escrowDuration}`);
  console.log(`  fundCore         : ${fundCore}`);
  console.log(`  totalEscrowedNin : ${totalEscrowedNin}`);

  // 10. Verify existing getters still work
  const usdt_ = await fx.usdt();
  const nin_  = await fx.nin();
  const fxTreasury = await fx.fxTreasuryUsdt();
  console.log(`\n  Existing getters still working:`);
  console.log(`  ${usdt_.toLowerCase() === KNOWN.USDT.toLowerCase() ? "✅" : "❌"} usdt()           = ${usdt_}`);
  console.log(`  ${nin_.toLowerCase()  === KNOWN.NIN.toLowerCase()  ? "✅" : "❌"} nin()            = ${nin_}`);
  console.log(`  fxTreasuryUsdt() = ${ethers.formatUnits(fxTreasury, 6)} USDT`);

  console.log(`\n${"═".repeat(60)}`);
  console.log(allOk ? "✅ FxPool upgrade complete and fully verified" : "❌ Issues detected — review above before proceeding");
  console.log(`${"═".repeat(60)}`);

  if (!allOk) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
