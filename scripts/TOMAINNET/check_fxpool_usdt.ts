// Read all USDT-related state from the live FxPool before upgrade.
// Run: npx hardhat run scripts/TOMAINNET/check_fxpool_usdt.ts --network polygon
const { ethers } = require("hardhat");

const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const USDT   = "0xc2132D05D31c914a87C6611C10748AEb04B58e8F";

async function main() {
  const block = await ethers.provider.getBlockNumber();
  console.log(`Block: ${block}\n`);

  const fxPool = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const usdt   = await ethers.getContractAt("IERC20", USDT);

  // 1. Actual ERC20 USDT balance held by the contract
  const usdtBalance = await usdt.balanceOf(FXPOOL);
  console.log(`USDT.balanceOf(fxPool)  : ${ethers.formatUnits(usdtBalance, 6)} USDT  (raw: ${usdtBalance})`);

  // 2. fxTreasuryUsdt — the accounting ledger for fees earned minus compensation paid
  const fxTreasury = await fxPool.fxTreasuryUsdt();
  console.log(`fxTreasuryUsdt (ledger) : ${ethers.formatUnits(fxTreasury, 6)} USDT  (raw: ${fxTreasury})`);

  // 3. Difference — USDT in contract that is NOT accounted for in fxTreasuryUsdt
  //    This is "user redemption float" — USDT deposited by mintNin users that backs their nIN.
  //    It is NOT tracked in any state variable — the contract relies on ERC20 balance directly.
  const unaccounted = usdtBalance > fxTreasury ? usdtBalance - fxTreasury : 0n;
  console.log(`\nBreakdown:`);
  console.log(`  fxTreasuryUsdt (fee pool, state var) : ${ethers.formatUnits(fxTreasury, 6)} USDT`);
  console.log(`  Backing float  (balance - treasury)  : ${ethers.formatUnits(unaccounted, 6)} USDT`);
  console.log(`  ─────────────────────────────────────────────────`);
  console.log(`  Total balance                        : ${ethers.formatUnits(usdtBalance, 6)} USDT`);

  // 4. Global daily cap state
  const globalLimit = await fxPool.globalLimit();
  console.log(`\nglobalLimit.windowStart : ${new Date(Number(globalLimit.windowStart) * 1000).toISOString()}`);
  console.log(`globalLimit.amount      : ${ethers.formatUnits(globalLimit.amount, 6)} USDT used in current window`);
  console.log(`globalCapPerDay         : ${ethers.formatUnits(await fxPool.globalCapPerDay(), 6)} USDT/day`);

  // 5. Key conclusion
  console.log(`\n${"─".repeat(60)}`);
  if (usdtBalance === 0n) {
    console.log(`ℹ️  No USDT currently held in fxPool — nothing to rescue before upgrade.`);
  } else {
    console.log(`⚠️  ${ethers.formatUnits(usdtBalance, 6)} USDT held in fxPool.`);
    console.log(`   fxTreasuryUsdt is a STATE VARIABLE tracking fee income.`);
    console.log(`   Removing USDT via rescueToken does NOT update fxTreasuryUsdt.`);
    console.log(`   After returning the USDT, the accounting will be restored`);
    console.log(`   because redeemNin checks balanceOf() directly (not fxTreasuryUsdt)`);
    console.log(`   for the solvency check at line 532: require(usdt.balanceOf(...) >= usdtOut)`);
    console.log(`   fxTreasuryUsdt only affects compensation/fee logic on redeem.`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
