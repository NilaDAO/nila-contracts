// SOP: Verify Oracle Registration in Roles Contract
// Reads addresses from .env — no private keys used (read-only calls only)
require("dotenv").config();
const { ethers } = require("ethers");

const RPC_URL = "https://polygon-mainnet.g.alchemy.com/v2/rJNzyTUoG75bsNITFKIw4d6uIHIuGWS2";

const VIEWER_PROXY  = process.env.VIEWERPROXY;   // 0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA
const CORE_PROXY    = process.env.COREPROXY;     // 0x4173BbaF66A4f9A2705d05B800e8602370366756
const ORACLE_ADDR   = process.env.ORACLE_SIGNER_MAIN; // 0x681b63c9320ada076133beacc75efb1e4752dc2f
const ENV_ROLES     = process.env.ROLES_MAIN;    // 0xc0a03f3A5319cE29205AeED7FDC0e6013e3E9bF9

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  console.log("\n=== SOP: Oracle Registration Verification ===\n");
  console.log("VIEWER_PROXY :", VIEWER_PROXY);
  console.log("CORE_PROXY   :", CORE_PROXY);
  console.log("ORACLE_ADDR  :", ORACLE_ADDR);
  console.log("ENV ROLES    :", ENV_ROLES);
  console.log("");

  // ── Step 1: viewer.roles() ──────────────────────────────────────────────
  const viewer = new ethers.Contract(
    VIEWER_PROXY,
    ["function roles() view returns (address)"],
    provider
  );
  const viewerRoles = await viewer.roles();
  console.log("Step 1 — viewer.roles()   :", viewerRoles);
  const step1Pass = viewerRoles !== ethers.ZeroAddress;
  console.log("  ✔ non-zero?             :", step1Pass ? "PASS" : "FAIL — zero address returned");

  // ── Step 2: roles.isOracle(ORACLE_ADDR) ────────────────────────────────
  // Try isOracle first; fall back to hasRole if needed
  let isOracle = false;
  let step2Method = "";
  const rolesABI = [
    "function isOracle(address) view returns (bool)",
    "function hasRole(bytes32,address) view returns (bool)",
  ];
  const roles = new ethers.Contract(viewerRoles, rolesABI, provider);

  try {
    isOracle = await roles.isOracle(ORACLE_ADDR);
    step2Method = "isOracle(address)";
  } catch (e) {
    console.log("  isOracle() not found, trying hasRole(ORACLE_ROLE, addr)...");
    // keccak256("ORACLE_ROLE")
    const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));
    try {
      isOracle = await roles.hasRole(ORACLE_ROLE, ORACLE_ADDR);
      step2Method = `hasRole(ORACLE_ROLE=${ORACLE_ROLE.slice(0,10)}…, addr)`;
    } catch (e2) {
      console.log("  hasRole() also failed:", e2.message);
    }
  }
  console.log(`\nStep 2 — roles.${step2Method}`);
  console.log("         oracle addr     :", ORACLE_ADDR);
  console.log("  ✔ isOracle?           :", isOracle ? "PASS (true)" : "FAIL (false) — oracle NOT registered");

  // ── Step 3: core.roles() — must match viewer ────────────────────────────
  const core = new ethers.Contract(
    CORE_PROXY,
    ["function roles() view returns (address)"],
    provider
  );
  const coreRoles = await core.roles();
  console.log("\nStep 3 — core.roles()    :", coreRoles);
  const step3Pass = coreRoles.toLowerCase() === viewerRoles.toLowerCase();
  console.log("  ✔ matches viewer?      :", step3Pass ? "PASS" : "FAIL — Core and Viewer point to DIFFERENT Roles contracts!");

  // ── Step 4: ENV cross-check ─────────────────────────────────────────────
  const step4Pass = ENV_ROLES && viewerRoles.toLowerCase() === ENV_ROLES.toLowerCase();
  console.log("\nStep 4 — ENV ROLES_MAIN vs viewer.roles()");
  console.log("  ENV ROLES_MAIN        :", ENV_ROLES);
  console.log("  viewer.roles()        :", viewerRoles);
  console.log("  ✔ match?              :", step4Pass ? "PASS" : "WARN — .env ROLES_MAIN differs from on-chain value");

  // ── Summary ─────────────────────────────────────────────────────────────
  console.log("\n=================== CHECKLIST ===================");
  console.log(`[${step1Pass ? "✓" : "✗"}] viewer.roles() returns non-zero Roles address`);
  console.log(`[${isOracle  ? "✓" : "✗"}] roles.isOracle(ORACLE_ADDR) == true`);
  console.log(`[${step3Pass ? "✓" : "✗"}] Core and Viewer point to the same Roles contract`);
  console.log(`[${step4Pass ? "✓" : "~"}] On-chain Roles matches .env ROLES_MAIN`);
  console.log("=================================================\n");

  if (!isOracle) {
    console.log("ACTION REQUIRED:");
    console.log("  Oracle is NOT registered. Run setOracle/grantOracle on:");
    console.log("  Roles contract :", viewerRoles);
    console.log("  Oracle address :", ORACLE_ADDR);
    console.log("  Example (cast):");
    console.log(`    cast send ${viewerRoles} "setOracle(address,bool)" ${ORACLE_ADDR} true \\`);
    console.log(`      --rpc-url ${RPC_URL.replace(/\/[^/]+$/, "/<KEY>")} --private-key <OWNER_PK>\n`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
