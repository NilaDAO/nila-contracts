//0xa097b2249F53aDBae6dEB543351dd3F47db76900
// scripts/upgradeInputFund.js
const hre = require("hardhat");
require("dotenv").config();

async function main() {
  const proxyAddr = '0xa097b2249F53aDBae6dEB543351dd3F47db76900';
  if (!proxyAddr) throw new Error("Set INPUT_FUND_PROXY in your .env");

  const [signer] = await hre.ethers.getSigners();
  const UUPS_ABI = [
    "function owner() view returns(address)",
    "function upgradeTo(address newImplementation) external",
    "function initializeV2() external",
    "function version() view returns(string)"
  ];
  const fund = new hre.ethers.Contract(proxyAddr, UUPS_ABI, signer);

  // 1) Confirm you’re talking to the right proxy:
  console.log("proxy.owner():", await fund.owner());
  if ((await fund.owner()).toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error("👎 signer is not owner");
  }

  // 2) Deploy V2 logic
  const V2 = await hre.ethers.getContractFactory("InputFundUpgradeableV2", signer);
  const impl = await V2.deploy();
  await impl.waitForDeployment();
  console.log("V2 logic at:", impl.target);

  // 3) Check proxiableUUID (should match 0x3608…bbc)
  try {
    const uuid = await fund.proxiableUUID();
    console.log("proxiableUUID:", uuid);
  } catch (e) {
    console.warn("No proxiableUUID()—that’s fine if it’s a UUPS proxy");
  }

  // 4) Upgrade
  try {
    const tx = await fund.upgradeTo(impl.target);
    await tx.wait();
    console.log("✅ upgradeTo succeeded:", tx.hash);
  } catch (e) {
    console.error("❌ upgradeTo reverted:", e.error?.message || e.message);
    process.exit(1);
  }

  // 5) Initialize your new domain separator (since you added EIP-712)
  try {
    const tx2 = await fund.initializeV2();
    await tx2.wait();
    console.log("✅ initializeV2 done");
  } catch (e) {
    console.warn("initializeV2:", e.error?.message || e.message);
  }

  // 6) Sanity-check
  console.log("new version():", await fund.version());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
