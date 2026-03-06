// Verify CS003 post-upgrade configuration from chain (read-only, no signer needed).
// Run after do_config_core.ts and do_config_fxpool.ts to confirm everything is wired up.
// Run: npx hardhat run scripts/TOMAINNET/check_cs003_config.ts --network polygon

const { ethers } = require("hardhat");

const CORE   = "0x4173BbaF66A4f9A2705d05B800e8602370366756";
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const NIN    = "0xD1F49598E42D30Cd900Ea86244485ca0647d31C7";

const CS003_ESCROW_DURATION = 259200; // 3 days in seconds

async function main() {
  const block = await ethers.provider.getBlockNumber();
  console.log(`Block: ${block}\n`);

  const core = await ethers.getContractAt("GenericFundCore", CORE);
  const fx   = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const nin  = await ethers.getContractAt("NilaNIN", NIN);

  const MINTER_ROLE = await nin.MINTER_ROLE();
  const BURNER_ROLE = await nin.BURNER_ROLE();
  const UNION_ROLE  = await fx.UNION_ROLE();

  let allOk = true;
  function check(label: string, ok: boolean, detail: string) {
    if (!ok) allOk = false;
    console.log(`  ${ok ? "✅" : "❌"} ${label.padEnd(38)} ${detail}`);
  }

  // ── GenericFundCore ───────────────────────────────────────────────────────
  console.log(`GenericFundCore (${CORE}):`);
  const fxPoolAddr = await core.fxPoolAddr();
  check("fxPoolAddr", fxPoolAddr.toLowerCase() === FXPOOL.toLowerCase(), fxPoolAddr);

  const nin_ = await core.nin();
  check("nin()", nin_.toLowerCase() === NIN.toLowerCase(), nin_);

  // ── NilaFxPool ────────────────────────────────────────────────────────────
  console.log(`\nNilaFxPool (${FXPOOL}):`);
  const fundCore = await fx.fundCore();
  check("fundCore", fundCore.toLowerCase() === CORE.toLowerCase(), fundCore);

  const escrowDuration = await fx.escrowDuration();
  check(
    "escrowDuration",
    Number(escrowDuration) === CS003_ESCROW_DURATION,
    `${escrowDuration} s  (expect ${CS003_ESCROW_DURATION})`
  );

  const nextEscrowId = await fx.nextEscrowId();
  check("nextEscrowId", nextEscrowId === 0n, nextEscrowId.toString());

  const usdt_ = await fx.usdt();
  check("usdt()", usdt_.toLowerCase() === "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", usdt_);

  // ── NilaNIN roles ─────────────────────────────────────────────────────────
  console.log(`\nNilaNIN roles (${NIN}):`);
  const fxHasMinter = await nin.hasRole(MINTER_ROLE, FXPOOL);
  const fxHasBurner = await nin.hasRole(BURNER_ROLE, FXPOOL);
  check("FxPool has MINTER_ROLE", fxHasMinter, FXPOOL);
  check("FxPool has BURNER_ROLE", fxHasBurner, FXPOOL);

  // ── UNION_ROLE holders (informational) ────────────────────────────────────
  console.log(`\nNilaFxPool UNION_ROLE holders (informational):`);
  const unionSigner = process.env.UNION_SIGNER;
  if (unionSigner) {
    const unionAddr = ethers.getAddress(unionSigner);
    const hasUnion = await fx.hasRole(UNION_ROLE, unionAddr);
    check("UNION_SIGNER has UNION_ROLE", hasUnion, unionAddr);
  } else {
    console.log(`  (set UNION_SIGNER=0x... env var to check a specific address)`);
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log(`\n${"═".repeat(60)}`);
  if (allOk) {
    console.log(`✅ CS003 fully configured — system is ready for cash-scan escrow`);
  } else {
    console.log(`❌ Configuration incomplete — run the missing do_config_*.ts scripts`);
  }
  console.log(`${"═".repeat(60)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
