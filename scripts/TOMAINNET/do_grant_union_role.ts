// Grant UNION_ROLE to a union's cash-scan signer on NilaFxPool.
// Run once per new union. Multiple unions can hold this role simultaneously.
//
// Signer: FX_OWNER_ADDRESS (0x7687...) — holds ONLY_OWNER on NilaFxPool.
//   Ledger must be: unlocked, Ethereum app open, blind signing enabled.
//
// Required env var:
//   UNION_SIGNER=0x<union_cash_scan_signer_address>
//
// Run: UNION_SIGNER=0x... npx hardhat run scripts/TOMAINNET/do_grant_union_role.ts --network polygon-ledger

const { ethers } = require("hardhat");

const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";

async function main() {
  const unionSigner = process.env.UNION_SIGNER;
  if (!unionSigner) throw new Error("Set UNION_SIGNER=0x<address> env var");
  const unionAddr = ethers.getAddress(unionSigner); // validate + checksum

  const [owner] = await ethers.getSigners();
  const block   = await ethers.provider.getBlockNumber();
  const bal     = await ethers.provider.getBalance(owner);
  console.log(`Block        : ${block}`);
  console.log(`Signer       : ${await owner.getAddress()}`);
  console.log(`Balance      : ${ethers.formatEther(bal)} MATIC`);
  console.log(`Union signer : ${unionAddr}`);

  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL, owner);
  const ONLY_OWNER = await fx.ONLY_OWNER();
  const UNION_ROLE = await fx.UNION_ROLE();

  // 1. Confirm signer holds ONLY_OWNER
  const hasOwner = await fx.hasRole(ONLY_OWNER, await owner.getAddress());
  if (!hasOwner) throw new Error(`Signer does not hold ONLY_OWNER on FxPool`);
  console.log(`\nONLY_OWNER check : ✅`);

  // 2. Check current state
  const alreadyHas = await fx.hasRole(UNION_ROLE, unionAddr);
  console.log(`Has UNION_ROLE   : ${alreadyHas}`);

  if (alreadyHas) {
    console.log(`\nAlready has UNION_ROLE — nothing to do. ✅`);
    return;
  }

  // 3. Grant
  console.log(`\nCalling grantRole(UNION_ROLE, ${unionAddr}) … (Ledger prompt)`);
  const tx = await fx.grantRole(UNION_ROLE, unionAddr);
  console.log(`Tx hash : ${tx.hash}`);
  const r = await tx.wait();
  console.log(`Status  : ${r.status === 1 ? "✅ success" : "❌ reverted"}`);

  // 4. Verify
  const granted = await fx.hasRole(UNION_ROLE, unionAddr);
  console.log(`\nUNION_ROLE granted: ${granted ? "✅" : "❌"}`);
  if (!granted) process.exit(1);

  console.log(`\n${"═".repeat(60)}`);
  console.log(`✅ ${unionAddr} can now call cashScanMint and resolveEscrowUsdt`);
  console.log(`${"═".repeat(60)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
