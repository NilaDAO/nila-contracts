// npx hardhat run scripts/TOMAINNET/genericFund_setBucketThreshold.ts --network polygon
const { ethers } = require("hardhat");
import { Wallet, JsonRpcProvider, encodeBytes32String } from "ethers";
import * as dotenv from "dotenv";
dotenv.config();

// ─── CONFIG ──────────────────────────────────────────────────────────────────
const CORE_PROXY  = (process.env.COREPROXY || "").trim();
const UNION_ADDR  = '0xF18E4966731bD6D3a56c1eb23Da7C708c9C48070'; // union id (EOA/contract)

// loanType: the display name used when the fund type was registered (e.g. "GroundUp Fund")
const LOAN_TYPE_NAME = "GroundUp Fund";

// Minimum junior/senior ratio required after a loan is funded, expressed in WAD (1e18 = 1.0).
// Examples:
//   0.5e18  → junior pool must be ≥ 50% of senior pool
//   1.0e18  → junior pool must be ≥ 100% of senior pool (1:1)
//   0       → ratio check disabled for this market
const THRESHOLD_WAD = ethers.parseEther("0.1"); // 10%

// Maximum single-loan amount in NIN (18 decimals).
// Set to 0 to disable the per-loan cap (unlimited).
const MAX_LOAN_AMOUNT = ethers.parseEther("100000"); // 100,000 NIN
// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  if (!CORE_PROXY) throw new Error("Missing env: COREPROXY");

  const provider = ethers.provider as unknown as JsonRpcProvider;
  const signer = process.env.OWNER_PK
    ? new Wallet(process.env.OWNER_PK!, provider)
    : (await ethers.getSigners())[0];

  const network = await provider.getNetwork();
  console.log(`Network  : ${network.name} (${network.chainId})`);
  console.log(`Signer   : ${await signer.getAddress()}`);
  console.log(`Core     : ${CORE_PROXY}`);
  console.log(`Union    : ${UNION_ADDR}`);
  console.log(`LoanType : ${LOAN_TYPE_NAME}`);
  console.log(`Threshold: ${ethers.formatEther(THRESHOLD_WAD)} (WAD)`);
  console.log(`MaxLoan  : ${MAX_LOAN_AMOUNT.toString()} (raw units)`);

  const core = await ethers.getContractAt("GenericFundCore", CORE_PROXY, signer);

  // Ownership check
  const owner = (await core.owner()).toLowerCase();
  if (owner !== (await signer.getAddress()).toLowerCase()) {
    throw new Error(`Signer is not Core owner. Core owner: ${owner}`);
  }

  const loanType = encodeBytes32String(LOAN_TYPE_NAME);

  // Read current values before updating
  const currentThreshold = await core.bucketTresholds(UNION_ADDR, loanType);
  const currentMax       = await core.bucketMaxAmount(UNION_ADDR, loanType);
  console.log(`\nCurrent threshold : ${ethers.formatEther(currentThreshold)} WAD`);
  console.log(`Current maxLoan   : ${currentMax.toString()} raw`);

  console.log("\n-> Calling setBucketThresholds…");
  const tx = await core.setBucketThresholds(UNION_ADDR, loanType, THRESHOLD_WAD, MAX_LOAN_AMOUNT);
  console.log(`   tx hash: ${tx.hash}`);
  await tx.wait();
  console.log("   Done.");

  // Confirm on-chain
  const newThreshold = await core.bucketTresholds(UNION_ADDR, loanType);
  const newMax       = await core.bucketMaxAmount(UNION_ADDR, loanType);
  console.log(`\nNew threshold : ${ethers.formatEther(newThreshold)} WAD`);
  console.log(`New maxLoan   : ${newMax.toString()} raw`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
