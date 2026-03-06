// Point NilaFxPool proxy to already-deployed CS003 impl.
// The impl contract 0xafe649... is already on Polygon (deployed by the timeout'd tx).
// This script ONLY calls upgradeToAndCall on the proxy — much cheaper than re-deploying.
//
// Signer: FX_OWNER_ADDRESS (0x7687...) — holds ONLY_OWNER on NilaFxPool.
//   Ledger must be: unlocked, Ethereum app open, blind signing enabled.
//
// Run: npx hardhat run scripts/TOMAINNET/do_upgrade_fxpool_proxy.ts --network polygon-ledger

const { ethers, upgrades } = require("hardhat");

const FXPOOL_PROXY = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const NEW_IMPL     = "0xafe649BC3Be3BFEd5e8BF1485722aCA98c9adB9c";
const IMPL_SLOT    = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function main() {
  const [owner] = await ethers.getSigners();
  const block   = await ethers.provider.getBlockNumber();
  const bal     = await ethers.provider.getBalance(owner);
  console.log(`Block   : ${block}`);
  console.log(`Signer  : ${await owner.getAddress()}`);
  console.log(`Balance : ${ethers.formatEther(bal)} MATIC`);

  // 1. Verify impl is already on-chain
  const code = await ethers.provider.getCode(NEW_IMPL);
  if (code.length <= 2) throw new Error(`Impl not deployed at ${NEW_IMPL}`);
  console.log(`\nImpl exists on-chain: ✅ (${NEW_IMPL})`);

  // 2. Check current proxy impl
  const raw    = await ethers.provider.getStorage(FXPOOL_PROXY, IMPL_SLOT);
  const current = ethers.getAddress("0x" + raw.slice(26));
  console.log(`Current proxy impl  : ${current}`);

  if (current.toLowerCase() === NEW_IMPL.toLowerCase()) {
    console.log(`Already pointing to new impl — nothing to do. ✅`);
    return;
  }

  // 3. Confirm signer holds ONLY_OWNER
  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL_PROXY, owner);
  const ONLY_OWNER = await fx.ONLY_OWNER();
  const hasOwner   = await fx.hasRole(ONLY_OWNER, await owner.getAddress());
  if (!hasOwner) throw new Error(`Signer does not hold ONLY_OWNER on FxPool`);
  console.log(`ONLY_OWNER check    : ✅`);

  // 4. Call upgradeTo on the UUPS proxy (Ledger prompt)
  console.log(`\nCalling upgradeToAndCall(${NEW_IMPL}) … (Ledger prompt)`);
  const tx = await fx.upgradeToAndCall(NEW_IMPL, "0x");
  console.log(`Tx hash : ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`Status  : ${receipt?.status === 1 ? "✅ success" : "❌ reverted"}`);
  console.log(`Gas used: ${receipt?.gasUsed}`);

  // 5. Verify
  const rawAfter  = await ethers.provider.getStorage(FXPOOL_PROXY, IMPL_SLOT);
  const implAfter = ethers.getAddress("0x" + rawAfter.slice(26));
  const ok        = implAfter.toLowerCase() === NEW_IMPL.toLowerCase();
  console.log(`\nImpl AFTER : ${implAfter}  ${ok ? "✅" : "❌"}`);

  console.log(`\n${"═".repeat(60)}`);
  console.log(ok ? "✅ NilaFxPool proxy upgraded to CS003 impl" : "❌ Upgrade did not take");
  console.log(`${"═".repeat(60)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
