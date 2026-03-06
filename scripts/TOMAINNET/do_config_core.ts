// CS003 post-upgrade config — GenericFundCore side (hot-key signer).
// Sets fxPoolAddr on GenericFundCore so burnEscrowNin can be called by FxPool.
//
// Signer: OWNER_ADDRESS (0xF2Ea...) — holds onlyOwner on GenericFundCore.
// Run: npx hardhat run scripts/TOMAINNET/do_config_core.ts --network polygon

const { ethers } = require("hardhat");

const CORE   = "0x4173BbaF66A4f9A2705d05B800e8602370366756";
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";

async function main() {
  const [owner] = await ethers.getSigners();
  const block = await ethers.provider.getBlockNumber();
  const bal   = await ethers.provider.getBalance(owner);
  console.log(`Block   : ${block}`);
  console.log(`Signer  : ${await owner.getAddress()}`);
  console.log(`Balance : ${ethers.formatEther(bal)} MATIC`);

  const core = await ethers.getContractAt("GenericFundCore", CORE, owner);

  // 1. Confirm signer is owner
  const coreOwner = await core.owner();
  if (coreOwner.toLowerCase() !== (await owner.getAddress()).toLowerCase()) {
    throw new Error(`Signer is NOT GenericFundCore owner. Owner: ${coreOwner}`);
  }
  console.log(`\nonlyOwner check ✅ : ${coreOwner}`);

  // 2. Current value
  const current = await core.fxPoolAddr();
  console.log(`fxPoolAddr BEFORE : ${current}`);
  if (current.toLowerCase() === FXPOOL.toLowerCase()) {
    console.log(`Already set to FxPool — nothing to do.`);
    return;
  }

  // 3. Set fxPoolAddr
  console.log(`\nCalling setFxPoolAddr(${FXPOOL}) …`);
  const tx = await core.setFxPoolAddr(FXPOOL);
  console.log(`Tx hash : ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`Status  : ${receipt.status === 1 ? "✅ success" : "❌ reverted"}`);
  console.log(`Gas     : ${receipt.gasUsed}`);

  // 4. Verify
  const after = await core.fxPoolAddr();
  const ok = after.toLowerCase() === FXPOOL.toLowerCase();
  console.log(`fxPoolAddr AFTER  : ${after}`);
  console.log(`\n${ok ? "✅ GenericFundCore.fxPoolAddr configured" : "❌ fxPoolAddr mismatch — check above"}`);
  if (!ok) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
