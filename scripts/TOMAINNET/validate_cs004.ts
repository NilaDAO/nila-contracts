// Dry-run storage layout validation for CS004 upgrade.
// Does NOT deploy or upgrade anything — read-only.
//
// Usage:
//   MATHLIB_MAIN=0xBea16D53399d5b6627D6c30aFDfB3f6482D5932B \
//   npx hardhat run scripts/TOMAINNET/validate_cs004.ts --network polygon
//
// What it does:
//   1. forceImport each live proxy into the local OZ manifest.
//   2. validateUpgrade for GenericFundCore and NilaFxPool (both gain a
//      setNin() function — no storage layout change, should PASS).
//   3. validateImplementation for NilaNINV2 (new contract, checks it is
//      upgrade-safe before the first deploy).
//   4. Prints PASS / FAIL for each check.
//
// Exit code: 0 = all PASS, 1 = any FAIL.

const { ethers, upgrades } = require("hardhat");

const CORE_PROXY   = "0x4173BbaF66A4f9A2705d05B800e8602370366756";
const FXPOOL_PROXY = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const MATHLIB      = process.env.MATHLIB_MAIN
  ? ethers.getAddress(process.env.MATHLIB_MAIN)
  : undefined;

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Signer     :", await signer.getAddress());
  console.log("Network    :", (await ethers.provider.getNetwork()).name);
  console.log();

  // ── GenericFundCore ──────────────────────────────────────────────────────
  // setNin() adds a function — no storage change. Should PASS.
  let corePass = false;
  try {
    const CoreF = await ethers.getContractFactory("GenericFundCore", {
      signer,
      libraries: MATHLIB ? { GenericFundMathLib: MATHLIB } : {},
    });

    console.log("── GenericFundCore ──");
    console.log("  forceImport proxy:", CORE_PROXY);
    await upgrades.forceImport(CORE_PROXY, CoreF, {
      kind: "uups",
      unsafeAllow: ["external-library-linking"],
    });

    console.log("  validateUpgrade…");
    await upgrades.validateUpgrade(CORE_PROXY, CoreF, {
      kind: "uups",
      unsafeAllow: ["external-library-linking"],
    });

    console.log("  ✅ GenericFundCore: PASS\n");
    corePass = true;
  } catch (err: any) {
    console.error("  ❌ GenericFundCore: FAIL");
    console.error("    ", err.message ?? err);
    console.log();
  }

  // ── NilaFxPool ───────────────────────────────────────────────────────────
  // setNin() + burnFarmerNin() add functions — no storage change. Should PASS.
  let fxPass = false;
  try {
    const FxF = await ethers.getContractFactory("NilaFxPool", { signer });

    console.log("── NilaFxPool ──");
    console.log("  forceImport proxy:", FXPOOL_PROXY);
    await upgrades.forceImport(FXPOOL_PROXY, FxF, { kind: "uups" });

    console.log("  validateUpgrade…");
    await upgrades.validateUpgrade(FXPOOL_PROXY, FxF, { kind: "uups" });

    console.log("  ✅ NilaFxPool: PASS\n");
    fxPass = true;
  } catch (err: any) {
    console.error("  ❌ NilaFxPool: FAIL");
    console.error("    ", err.message ?? err);
    console.log();
  }

  // ── NilaNINV2 ─────────────────────────────────────────────────────────────
  // New contract — not upgrading an existing proxy; just validate the
  // implementation is upgrade-safe (no selfdestruct, no delegatecall, etc.).
  let ninV2Pass = false;
  try {
    const NinV2F = await ethers.getContractFactory("NilaNINV2", { signer });

    console.log("── NilaNINV2 (new impl) ──");
    console.log("  validateImplementation…");
    await upgrades.validateImplementation(NinV2F, { kind: "uups" });

    console.log("  ✅ NilaNINV2: PASS\n");
    ninV2Pass = true;
  } catch (err: any) {
    console.error("  ❌ NilaNINV2: FAIL");
    console.error("    ", err.message ?? err);
    console.log();
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("═══════════════════════════════");
  console.log("Summary:");
  console.log(`  GenericFundCore : ${corePass  ? "✅ PASS" : "❌ FAIL"}`);
  console.log(`  NilaFxPool      : ${fxPass    ? "✅ PASS" : "❌ FAIL"}`);
  console.log(`  NilaNINV2       : ${ninV2Pass ? "✅ PASS" : "❌ FAIL"}`);
  console.log("═══════════════════════════════");

  if (!corePass || !fxPass || !ninV2Pass) {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
