// Read the live implementation address from each proxy's ERC-1967 slot,
// then cross-reference against the local .openzeppelin/polygon.json manifest.
// Run: npx hardhat run scripts/TOMAINNET/get_live_impls.ts --network polygon

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function getImplAddress(proxyAddr: string): Promise<string> {
  const raw = await ethers.provider.getStorage(proxyAddr, IMPL_SLOT);
  return ethers.getAddress("0x" + raw.slice(26));
}

async function main() {
  const proxies: Record<string, string> = {
    GenericFundCore:   "0x4173BbaF66A4f9A2705d05B800e8602370366756",
    NilaFxPool:        "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA",
    GenericFundViewer: "0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA",
  };

  // Load local manifest
  const manifestPath = path.join(__dirname, "../../.openzeppelin/polygon.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const impls: Record<string, any> = manifest.impls ?? {};

  console.log("=".repeat(70));
  console.log("Live implementation addresses (read from chain ERC-1967 slot)");
  console.log("=".repeat(70));

  for (const [name, proxy] of Object.entries(proxies)) {
    const implAddr = await getImplAddress(proxy);
    const code = await ethers.provider.getCode(implAddr);
    const codeBytes = (code.length - 2) / 2;

    // Keccak256 of the deployed bytecode — OZ uses this as the impl hash key
    const codeHash = "0x" + crypto.createHash("sha256").update(Buffer.from(code.slice(2), "hex")).digest("hex");

    console.log(`\n── ${name}`);
    console.log(`   Proxy      : ${proxy}`);
    console.log(`   Impl (live): ${implAddr}`);
    console.log(`   Code size  : ${codeBytes} bytes`);

    // Check if this impl's bytecode hash appears in the manifest
    // OZ stores impls keyed by a content hash of the layout (not bytecode hash),
    // so we look for the impl address in any entry instead
    let found = false;
    for (const [hashKey, entry] of Object.entries(impls)) {
      const layout = (entry as any).layout ?? {};
      const storage = layout.storage ?? [];
      if (storage.length === 0) continue;
      const contractName = storage[0]?.contract ?? "";
      if (contractName === name || contractName.includes(name.replace("GenericFund", ""))) {
        // Check if the address field matches (some OZ versions store it)
        const entryAddr = (entry as any).address;
        if (entryAddr && entryAddr.toLowerCase() === implAddr.toLowerCase()) {
          console.log(`   Manifest   : ✅ FOUND by address (hash key: ${hashKey.slice(0, 12)})`);
          console.log(`   Layout vars: ${storage.length}`);
          found = true;
          break;
        }
      }
    }

    if (!found) {
      // OZ manifest may not store the impl address directly — show all matching contract entries
      console.log(`   Manifest   : (address not stored directly in manifest — showing all ${name} layout entries)`);
      for (const [hashKey, entry] of Object.entries(impls)) {
        const layout = (entry as any).layout ?? {};
        const storage = layout.storage ?? [];
        if (storage.length > 0 && storage[0]?.contract === name) {
          console.log(`     hash=${hashKey.slice(0, 12)}  vars=${storage.length}  last_var=${storage[storage.length - 1]?.label}`);
        }
      }
    }
  }

  console.log("\n" + "=".repeat(70));
  console.log("Cross-reference: manifest impl entries by date (createdAt field)");
  console.log("=".repeat(70));
  const entries = Object.entries(impls).map(([k, v]: [string, any]) => ({
    hash: k.slice(0, 12),
    contract: (v.layout?.storage?.[0]?.contract ?? "?"),
    vars: v.layout?.storage?.length ?? 0,
    createdAt: v.createdAt ?? "(none)",
    address: v.address ?? "(not stored)",
  }));

  // Sort by createdAt if available, otherwise just print
  entries.sort((a, b) => {
    if (a.createdAt === "(none)" && b.createdAt === "(none)") return 0;
    if (a.createdAt === "(none)") return 1;
    if (b.createdAt === "(none)") return -1;
    return a.createdAt.localeCompare(b.createdAt);
  });

  for (const e of entries) {
    if (!["GenericFundCore", "NilaFxPool", "GenericFundViewer"].includes(e.contract)) continue;
    console.log(`  ${e.contract.padEnd(20)} hash=${e.hash}  vars=${String(e.vars).padEnd(3)}  createdAt=${e.createdAt}  addr=${e.address}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
