// CS003 NilaFxPool upgrade — Ledger signer (FX_OWNER_ADDRESS holds ONLY_OWNER).
//
// Ledger must be: unlocked, Ethereum app open, blind signing enabled.
//
// Run: npx hardhat run scripts/TOMAINNET/upgrade_fxpool.ts --network polygon-ledger

const { ethers, upgrades } = require("hardhat");

const FXPOOL_PROXY = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";

async function main() {
  const [owner] = await ethers.getSigners();
  const block   = await ethers.provider.getBlockNumber();
  const bal     = await ethers.provider.getBalance(owner);
  console.log(`Block   : ${block}`);
  console.log(`Signer  : ${await owner.getAddress()}`);
  console.log(`Balance : ${ethers.formatEther(bal)} MATIC`);

  const FxF = await ethers.getContractFactory("NilaFxPool", { signer: owner });

  // 1. Confirm signer holds ONLY_OWNER on FxPool
  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL_PROXY, owner);
  const ONLY_OWNER = await fx.ONLY_OWNER();
  const hasOwner   = await fx.hasRole(ONLY_OWNER, await owner.getAddress());
  if (!hasOwner) throw new Error(`Signer does not hold ONLY_OWNER on FxPool`);
  console.log(`\nONLY_OWNER check ✅`);

  // 2. Register live proxy in OZ manifest (idempotent)
  console.log(`\nforceImport proxy: ${FXPOOL_PROXY}`);
  await upgrades.forceImport(FXPOOL_PROXY, FxF, { kind: "uups" });

  // 3. Validate storage layout before touching anything
  console.log(`validateUpgrade…`);
  await upgrades.validateUpgrade(FXPOOL_PROXY, FxF, { kind: "uups" });
  console.log(`Storage layout: ✅ PASS`);

  // 4. Impl BEFORE
  const implBefore = await upgrades.erc1967.getImplementationAddress(FXPOOL_PROXY);
  console.log(`\nImpl BEFORE : ${implBefore}`);

  // 5. Upgrade (Ledger will prompt for blind-sign)
  console.log(`\nCalling upgradeProxy … (Ledger prompt)`);
  const upgraded = await upgrades.upgradeProxy(FXPOOL_PROXY, FxF, {
    kind: "uups",
    redeployImplementation: "always",
    signer: owner,
  });
  await upgraded.waitForDeployment();

  // 6. Impl AFTER
  const implAfter = await upgrades.erc1967.getImplementationAddress(FXPOOL_PROXY);
  console.log(`Impl AFTER  : ${implAfter}`);

  const oldCode = await ethers.provider.getCode(implBefore);
  const newCode = await ethers.provider.getCode(implAfter);
  console.log(`Bytecode changed? ${oldCode !== newCode ? "✅ YES" : "⚠️  NO (same address)"}`);

  const tx = upgraded.deploymentTransaction?.();
  console.log(`Upgrade tx  : ${tx ? tx.hash : "(none — already at this impl)"}`);

  console.log(`\n${"═".repeat(60)}`);
  console.log(`✅ NilaFxPool CS003 upgrade complete`);
  console.log(`${"═".repeat(60)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
