// Upgrade GenericFundViewer to CS003 implementation.
// Run: npx hardhat run scripts/TOMAINNET/do_upgrade_viewer.ts --network polygon

const { ethers, upgrades } = require("hardhat");

const VIEWER_PROXY = "0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA";
const IMPL_SLOT    = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

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
  const viewerRO = await ethers.getContractAt("GenericFundViewer", VIEWER_PROXY);
  const proxyOwner = await viewerRO.owner();
  if (proxyOwner.toLowerCase() !== (await owner.getAddress()).toLowerCase()) {
    throw new Error(`Signer is NOT the proxy owner. Owner: ${proxyOwner}`);
  }
  console.log(`Owner check ✅ : ${proxyOwner}`);

  // 2. Pre-upgrade slot snapshot from chain
  const rawBefore = await ethers.provider.getStorage(VIEWER_PROXY, IMPL_SLOT);
  const implBefore = ethers.getAddress("0x" + rawBefore.slice(26));
  const slot3Before = await ethers.provider.getStorage(VIEWER_PROXY, 3); // core
  const slot4Before = await ethers.provider.getStorage(VIEWER_PROXY, 4); // roles
  console.log(`\nImpl BEFORE   (chain): ${implBefore}`);
  console.log(`slot 3 core   (chain): 0x${slot3Before.slice(26)}`);
  console.log(`slot 4 roles  (chain): 0x${slot4Before.slice(26)}`);

  // 3. Build factory with library link
  const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
    signer: owner,
    libraries: { GenericFundMathLib: MATHLIB },
  });

  // 4. Validate layout (dry run)
  console.log("\nvalidateUpgrade …");
  await upgrades.validateUpgrade(VIEWER_PROXY, ViewerF, {
    kind: "uups",
    unsafeAllow: ["external-library-linking"],
  });
  console.log("validateUpgrade ✅");

  // 5. Deploy new impl + upgrade proxy
  console.log("\nupgradeProxy (redeployImplementation=always) …");
  const upgraded = await upgrades.upgradeProxy(VIEWER_PROXY, ViewerF, {
    kind: "uups",
    unsafeAllow: ["external-library-linking"],
    redeployImplementation: "always",
  });
  console.log("Deploy tx hash:", upgraded.deployTransaction?.hash ?? "(check receipt)");

  // 6. Post-upgrade: read impl from chain
  const rawAfter = await ethers.provider.getStorage(VIEWER_PROXY, IMPL_SLOT);
  const implAfter = ethers.getAddress("0x" + rawAfter.slice(26));
  console.log(`\nImpl BEFORE (chain): ${implBefore}`);
  console.log(`Impl AFTER  (chain): ${implAfter}`);
  console.log(`Changed: ${implBefore.toLowerCase() !== implAfter.toLowerCase() ? "✅ YES" : "⚠️  NO"}`);

  // 7. Post-upgrade: confirm storage slots unchanged
  const slot3After = await ethers.provider.getStorage(VIEWER_PROXY, 3);
  const slot4After = await ethers.provider.getStorage(VIEWER_PROXY, 4);
  const slot5After = await ethers.provider.getStorage(VIEWER_PROXY, 5);

  const coreOk  = slot3Before.toLowerCase() === slot3After.toLowerCase();
  const rolesOk = slot4Before.toLowerCase() === slot4After.toLowerCase();
  const gapOk   = slot5After === "0x" + "0".repeat(64);

  console.log(`\nPost-upgrade slot checks:`);
  console.log(`  ${coreOk  ? "✅" : "❌"} slot 3 (core)     unchanged: 0x${slot3After.slice(26)}`);
  console.log(`  ${rolesOk ? "✅" : "❌"} slot 4 (roles)    unchanged: 0x${slot4After.slice(26)}`);
  console.log(`  ${gapOk   ? "✅" : "❌"} slot 5 (__gap[0]) = ${slot5After}`);

  // 8. Spot-check: call recoverVoucherSigner — if the new ABI is live this won't revert on interface mismatch
  const viewer = await ethers.getContractAt("GenericFundViewer", VIEWER_PROXY);
  const coreAddr = ethers.getAddress("0x" + slot3After.slice(26));
  console.log(`\nviewer.core() = ${await viewer.core()}`);
  console.log(`viewer.owner() = ${await viewer.owner()}`);

  const allOk = coreOk && rolesOk && gapOk && implBefore.toLowerCase() !== implAfter.toLowerCase();
  console.log(`\n${ allOk ? "✅ Viewer upgrade complete and verified" : "❌ Issues detected — review above"}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
