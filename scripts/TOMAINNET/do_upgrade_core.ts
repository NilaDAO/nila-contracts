// Upgrade GenericFundCore to CS003 implementation.
// Skips forceImport (which can confuse the manifest) — goes straight to upgradeProxy.
// Uses upgrades.erc1967.getImplementationAddress to read the LIVE impl from chain.
//
// Run: MATHLIB_MAIN=<addr> npx hardhat run scripts/TOMAINNET/do_upgrade_core.ts --network polygon

const { ethers, upgrades } = require("hardhat");

const CORE_PROXY = "0x4173BbaF66A4f9A2705d05B800e8602370366756";

function addr(x: string | undefined, name: string): string {
  if (!x) throw new Error(`Missing env var: ${name}`);
  return ethers.getAddress(x);
}

async function main() {
  const MATHLIB = addr(process.env.MATHLIB_MAIN, "MATHLIB_MAIN");
  const [owner] = await ethers.getSigners();

  const block = await ethers.provider.getBlockNumber();
  const bal   = await ethers.provider.getBalance(owner);
  console.log(`Block   : ${block}`);
  console.log(`Signer  : ${await owner.getAddress()}`);
  console.log(`Balance : ${ethers.formatEther(bal)} MATIC`);

  // 1. Confirm signer is the proxy owner
  const coreRO = await ethers.getContractAt("GenericFundCore", CORE_PROXY);
  const proxyOwner = await coreRO.owner();
  if (proxyOwner.toLowerCase() !== (await owner.getAddress()).toLowerCase()) {
    throw new Error(`Signer is NOT the proxy owner. Owner: ${proxyOwner}`);
  }
  console.log(`Owner check ✅ : ${proxyOwner}`);

  // 2. Read live impl BEFORE from chain (not manifest)
  const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const rawBefore = await ethers.provider.getStorage(CORE_PROXY, IMPL_SLOT);
  const implBefore = ethers.getAddress("0x" + rawBefore.slice(26));
  console.log(`\nImpl BEFORE (chain): ${implBefore}`);

  // 3. Build factory
  const CoreF = await ethers.getContractFactory("GenericFundCore", {
    signer: owner,
    libraries: { GenericFundMathLib: MATHLIB },
  });

  // 4. Validate storage layout (dry run — no tx)
  console.log("validateUpgrade …");
  await upgrades.validateUpgrade(CORE_PROXY, CoreF, {
    kind: "uups",
    unsafeAllow: ["external-library-linking"],
  });
  console.log("validateUpgrade ✅");

  // 5. Deploy new impl + call upgradeToAndCall on proxy
  console.log("\nupgradeProxy (redeployImplementation=always) …");
  const upgraded = await upgrades.upgradeProxy(CORE_PROXY, CoreF, {
    kind: "uups",
    unsafeAllow: ["external-library-linking"],
    redeployImplementation: "always",
  });
  const receipt = await upgraded.deployTransaction?.wait?.();
  console.log("Deploy tx hash:", upgraded.deployTransaction?.hash ?? "(check receipt)");

  // 6. Read live impl AFTER from chain
  const rawAfter = await ethers.provider.getStorage(CORE_PROXY, IMPL_SLOT);
  const implAfter = ethers.getAddress("0x" + rawAfter.slice(26));
  console.log(`\nImpl BEFORE (chain): ${implBefore}`);
  console.log(`Impl AFTER  (chain): ${implAfter}`);
  console.log(`Changed: ${implBefore.toLowerCase() !== implAfter.toLowerCase() ? "✅ YES" : "⚠️  NO (same address)"}`);

  // 7. Spot-check: call fxPoolAddr() — new getter only exists in CS003
  const coreCS3 = await ethers.getContractAt("GenericFundCore", CORE_PROXY);
  const fxPoolAddr = await coreCS3.fxPoolAddr();
  console.log(`\ncore.fxPoolAddr() = ${fxPoolAddr} (0x00 expected — setFxPoolAddr not yet called)`);
  const nin = await coreCS3.nin();
  console.log(`core.nin()        = ${nin} ✅`);
}

main().catch((e) => { console.error(e); process.exit(1); });
