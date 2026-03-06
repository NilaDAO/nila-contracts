// npx hardhat run scripts/TOMAINNET/genericFund_setFeeAndReserve.ts --network polygon
const { ethers } = require("hardhat");
import { Wallet, JsonRpcProvider } from "ethers";
import * as dotenv from "dotenv";
dotenv.config();

// ─── CONFIG ──────────────────────────────────────────────────────────────────
const CORE_PROXY = (process.env.COREPROXY || "").trim();
const UNION_ADDR = '0xF18E4966731bD6D3a56c1eb23Da7C708c9C48070';

// ── Global fee split (onlyOwner) ─────────────────────────────────────────────
// Both values are in basis points (100 bp = 1%). Applied to every interest payment across ALL unions.
// Defaults at deploy: treasury=100 (1%), rainy=200 (2%).
// Remainder after both fees goes to investors (junior + senior split pro-rata).
const TREASURY_FEE_BP = 100; // 1%  → union treasury bucket
const RAINY_DAY_FEE_BP = 77; // 2%  → union rainy-day bucket

// ── Per-union reserve / liquidity buffer (onlyOracleOrLeader) ────────────────
// safetyBP:    % of total pool that must remain idle before a loan can be funded.
//              e.g. 1000 = 10% of (junior+senior cash) must stay unlent.
// safetyFloor: absolute NIN floor (18 dec) that must stay idle regardless of %.
//              e.g. parseEther("500") = 500 NIN always kept in reserve.
//              Set to 0 to rely on safetyBP only.
// hardStop:    if true → loan funding AND yield/principal claims are blocked when
//              idle cash would drop below the reserve; if false → only loan
//              funding is blocked (claims are still allowed).
const SAFETY_BP    = 1000;                      // 10%
const SAFETY_FLOOR = ethers.parseEther("0");    // 0 NIN absolute floor
const HARD_STOP    = false;
// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  if (!CORE_PROXY) throw new Error("Missing env: COREPROXY");

  const provider = ethers.provider as unknown as JsonRpcProvider;
  const signer = process.env.OWNER_PK
    ? new Wallet(process.env.OWNER_PK!, provider)
    : (await ethers.getSigners())[0];

  const network = await provider.getNetwork();
  console.log(`Network       : ${network.name} (${network.chainId})`);
  console.log(`Signer        : ${await signer.getAddress()}`);
  console.log(`Core          : ${CORE_PROXY}`);
  console.log(`Union         : ${UNION_ADDR}`);
  console.log(`Treasury fee  : ${TREASURY_FEE_BP} bp (${TREASURY_FEE_BP / 100}%)`);
  console.log(`Rainy-day fee : ${RAINY_DAY_FEE_BP} bp (${RAINY_DAY_FEE_BP / 100}%)`);
  console.log(`Safety BP     : ${SAFETY_BP} (${SAFETY_BP / 100}%)`);
  console.log(`Safety floor  : ${ethers.formatEther(SAFETY_FLOOR)} NIN`);
  console.log(`Hard stop     : ${HARD_STOP}`);

  
  const core = await ethers.getContractAt("GenericFundCore", CORE_PROXY, signer);

  // Ownership check (required for setFeeBps)
  const owner = (await core.owner()).toLowerCase();
  if (owner !== (await signer.getAddress()).toLowerCase()) {
    throw new Error(`Signer is not Core owner. Core owner: ${owner}`);
  }

  // ── Read current values ───────────────────────────────────────────────────
  const curTreasuryBP = await core.treasuryFeeBP();
  const curRainyBP    = await core.rainyFeeBP();
  const curReserve    = await core.reserveCfgByUnion(UNION_ADDR);
  console.log(`\nCurrent treasury fee : ${curTreasuryBP} bp`);
  console.log(`Current rainy-day fee: ${curRainyBP} bp`);
  console.log(`Current reserve cfg  : safetyBP=${curReserve.safetyBP}, floor=${ethers.formatEther(curReserve.safetyFloor)} NIN, hardStop=${curReserve.hardStop}`);
  return
  // ── 1) Set global fee BPs (onlyOwner) ────────────────────────────────────
  console.log("\n-> setFeeBps…");
  const tx1 = await core.setFeeBps(TREASURY_FEE_BP, RAINY_DAY_FEE_BP);
  console.log(`   tx: ${tx1.hash}`);
  await tx1.wait();
  console.log("   Done.");
  return
  // ── 2) Set per-union reserve config (onlyOracleOrLeader) ─────────────────
  console.log("\n-> setReserveConfigForUnion…");
  const tx2 = await core.setReserveConfigForUnion(UNION_ADDR, SAFETY_BP, SAFETY_FLOOR, HARD_STOP);
  console.log(`   tx: ${tx2.hash}`);
  await tx2.wait();
  console.log("   Done.");

  // ── Confirm ───────────────────────────────────────────────────────────────
  const newTreasuryBP = await core.treasuryFeeBP();
  const newRainyBP    = await core.rainyFeeBP();
  const newReserve    = await core.reserveCfgByUnion(UNION_ADDR);
  console.log(`\nNew treasury fee : ${newTreasuryBP} bp`);
  console.log(`New rainy-day fee: ${newRainyBP} bp`);
  console.log(`New reserve cfg  : safetyBP=${newReserve.safetyBP}, floor=${ethers.formatEther(newReserve.safetyFloor)} NIN, hardStop=${newReserve.hardStop}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
