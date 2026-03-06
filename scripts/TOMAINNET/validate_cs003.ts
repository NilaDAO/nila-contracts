// Dry-run storage layout validation for CS003 upgrade.
// Does NOT deploy or upgrade anything — read-only.
//
// Usage:
//   npx hardhat run scripts/TOMAINNET/validate_cs003.ts --network polygon
//
// What it does:
//   1. forceImport each live proxy into the local OZ manifest (sets the
//      "current layout" baseline from the on-chain implementation bytecode).
//   2. validateUpgrade for each contract against the new local source.
//   3. Prints PASS / FAIL for each contract.
//
// Exit code: 0 = all PASS, 1 = any FAIL.

const { ethers, upgrades } = require("hardhat");

const CORE_PROXY   = "0x4173BbaF66A4f9A2705d05B800e8602370366756";
const FXPOOL_PROXY = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const VIEWER_PROXY = "0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA";
const MATHLIB      = process.env.MATHLIB_MAIN
  ? ethers.getAddress(process.env.MATHLIB_MAIN)
  : undefined;

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Signer     :", await signer.getAddress());
  console.log("Network    :", (await ethers.provider.getNetwork()).name);
  console.log();

  // ── GenericFundCore ──────────────────────────────────────────────────────
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

  // ── GenericFundViewer ─────────────────────────────────────────────────────
  let viewerPass = false;
  try {
    const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
      signer,
      libraries: MATHLIB ? { GenericFundMathLib: MATHLIB } : {},
    });

    console.log("── GenericFundViewer ──");
    console.log("  forceImport proxy:", VIEWER_PROXY);
    await upgrades.forceImport(VIEWER_PROXY, ViewerF, {
      kind: "uups",
      unsafeAllow: ["external-library-linking"],
    });

    console.log("  validateUpgrade…");
    await upgrades.validateUpgrade(VIEWER_PROXY, ViewerF, {
      kind: "uups",
      unsafeAllow: ["external-library-linking"],
    });

    console.log("  ✅ GenericFundViewer: PASS\n");
    viewerPass = true;
  } catch (err: any) {
    console.error("  ❌ GenericFundViewer: FAIL");
    console.error("    ", err.message ?? err);
    console.log();
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("═══════════════════════════════");
  console.log("Summary:");
  console.log(`  GenericFundCore   : ${corePass   ? "✅ PASS" : "❌ FAIL"}`);
  console.log(`  NilaFxPool        : ${fxPass     ? "✅ PASS" : "❌ FAIL"}`);
  console.log(`  GenericFundViewer : ${viewerPass ? "✅ PASS" : "❌ FAIL"}`);
  console.log("═══════════════════════════════");

  if (!corePass || !fxPass || !viewerPass) {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
