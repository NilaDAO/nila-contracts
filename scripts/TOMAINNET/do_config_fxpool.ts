// CS003 post-upgrade config — NilaFxPool side (Ledger signer).
// Sets fundCore address, global escrow duration, and optionally grants UNION_ROLE.
//
// Signer: FX_OWNER_ADDRESS (0x7687...) — holds ONLY_OWNER on NilaFxPool.
//   Ledger must be: unlocked, Ethereum app open, blind signing enabled.
//
// Optional: set UNION_SIGNER env var to grant UNION_ROLE to a union cash-scan signer.
//   e.g.  UNION_SIGNER=0xABC... npx hardhat run scripts/TOMAINNET/do_config_fxpool.ts --network polygon-ledger
//
// Run: npx hardhat run scripts/TOMAINNET/do_config_fxpool.ts --network polygon-ledger

const { ethers } = require("hardhat");

const FXPOOL  = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const CORE    = "0x4173BbaF66A4f9A2705d05B800e8602370366756";

const ESCROW_DURATION_SECONDS = 3 * 24 * 60 * 60; // 3 days = 259200 s

async function main() {
  const [owner] = await ethers.getSigners();
  const block = await ethers.provider.getBlockNumber();
  const bal   = await ethers.provider.getBalance(owner);
  console.log(`Block   : ${block}`);
  console.log(`Signer  : ${await owner.getAddress()}`);
  console.log(`Balance : ${ethers.formatEther(bal)} MATIC`);

  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL, owner);
  const ONLY_OWNER = await fx.ONLY_OWNER();
  const UNION_ROLE = await fx.UNION_ROLE();

  // 1. Confirm signer holds ONLY_OWNER
  const hasOwner = await fx.hasRole(ONLY_OWNER, await owner.getAddress());
  if (!hasOwner) throw new Error(`Signer does not hold ONLY_OWNER role on FxPool`);
  console.log(`\nONLY_OWNER check ✅`);

  // ── Step A: setFundCore ──────────────────────────────────────────────────
  const currentCore = await fx.fundCore();
  console.log(`\nfundCore BEFORE : ${currentCore}`);

  if (currentCore.toLowerCase() === CORE.toLowerCase()) {
    console.log(`Already set — skipping setFundCore`);
  } else {
    console.log(`Calling setFundCore(${CORE}) … (Ledger prompt)`);
    const tx = await fx.setFundCore(CORE);
    console.log(`Tx hash : ${tx.hash}`);
    const r = await tx.wait();
    console.log(`Status  : ${r.status === 1 ? "✅ success" : "❌ reverted"}`);
  }

  const coreAfter = await fx.fundCore();
  const coreOk = coreAfter.toLowerCase() === CORE.toLowerCase();
  console.log(`fundCore AFTER  : ${coreAfter}  ${coreOk ? "✅" : "❌"}`);
  if (!coreOk) { console.error("setFundCore failed — aborting"); process.exit(1); }

  // ── Step B: setEscrowDuration ────────────────────────────────────────────
  const currentDuration = await fx.escrowDuration();
  console.log(`\nescrowDuration BEFORE : ${currentDuration} s`);

  if (Number(currentDuration) === ESCROW_DURATION_SECONDS) {
    console.log(`Already set to ${ESCROW_DURATION_SECONDS} s — skipping setEscrowDuration`);
  } else {
    console.log(`Calling setEscrowDuration(${ESCROW_DURATION_SECONDS}) … (Ledger prompt)`);
    const tx = await fx.setEscrowDuration(ESCROW_DURATION_SECONDS);
    console.log(`Tx hash : ${tx.hash}`);
    const r = await tx.wait();
    console.log(`Status  : ${r.status === 1 ? "✅ success" : "❌ reverted"}`);
  }

  const durAfter = await fx.escrowDuration();
  const durOk = Number(durAfter) === ESCROW_DURATION_SECONDS;
  console.log(`escrowDuration AFTER  : ${durAfter} s  ${durOk ? "✅" : "❌"}`);
  if (!durOk) { console.error("setEscrowDuration failed — aborting"); process.exit(1); }

  // ── Step C: grantRole(UNION_ROLE) — run once per union ───────────────────
  //
  // UNION_ROLE must be granted to each union's cash-scan signer address before
  // that union can call cashScanMint or resolveEscrowUsdt on NilaFxPool.
  // Multiple unions can hold this role simultaneously — run this step once
  // per new union. The signer for grantRole must hold ONLY_OWNER (this Ledger).
  //
  // To onboard a new union:
  //   UNION_SIGNER=0x<union_signer_addr> npx hardhat run scripts/TOMAINNET/do_config_fxpool.ts --network polygon-ledger
  //
  const unionSigner = process.env.UNION_SIGNER;
  if (unionSigner) {
    const unionAddr = ethers.getAddress(unionSigner); // checksum
    const alreadyHas = await fx.hasRole(UNION_ROLE, unionAddr);
    console.log(`\nUNION_ROLE target : ${unionAddr}`);
    console.log(`Has UNION_ROLE    : ${alreadyHas}`);

    if (alreadyHas) {
      console.log(`Already has UNION_ROLE — skipping grantRole`);
    } else {
      console.log(`Calling grantRole(UNION_ROLE, ${unionAddr}) … (Ledger prompt)`);
      const tx = await fx.grantRole(UNION_ROLE, unionAddr);
      console.log(`Tx hash : ${tx.hash}`);
      const r = await tx.wait();
      console.log(`Status  : ${r.status === 1 ? "✅ success" : "❌ reverted"}`);
      const granted = await fx.hasRole(UNION_ROLE, unionAddr);
      console.log(`UNION_ROLE granted: ${granted ? "✅" : "❌"}`);
    }
  } else {
    console.log(`\nNo UNION_SIGNER env var set — skipping UNION_ROLE grant.`);
    console.log(`Re-run with:  UNION_SIGNER=0x... npx hardhat run ... --network polygon-ledger`);
  }

  console.log(`\n${"═".repeat(60)}`);
  console.log(`✅ NilaFxPool CS003 configuration complete`);
  console.log(`${"═".repeat(60)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
