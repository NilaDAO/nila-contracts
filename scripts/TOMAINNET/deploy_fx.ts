// npx hardhat run scripts/TOMAINNET/deploy_fx.ts --network polygon
const { ethers, upgrades, network } = require("hardhat");

upgrades.silenceWarnings = false;

function addr(x: string, name: string) {
  if (!x) throw new Error(`Missing env var: ${name}`);
  return ethers.getAddress(x);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Network  :", network.name);
  console.log("Deployer :", await deployer.getAddress());

  const USDT          = addr(String(process.env.USDT_ADDRESS), "USDT");
  const NIN           = addr(String(process.env.NIN_MAIN), "NIN_MAIN");
  const ORACLE        = addr(String(process.env.USD_INR_FEED), "USD_INR_FEED");
  const OWNER_ADDRESS = addr(String(process.env.OWNER_ADDRESS), "OWNER_ONLY");

  const fxThresholdBps   = 200;                          // 2%
  const globalCapPerDay  = ethers.parseUnits("500", 6);  // 500 USDT (6 decimals)
  const maxOracleDelay   = 3600 * 24;                    // 24h
  const epochDuration    = 90 * 24 * 60 * 60;            // 90 days

  console.log("USDT         :", USDT);
  console.log("NIN          :", NIN);
  console.log("ORACLE       :", ORACLE);
  console.log("OWNER (admin):", OWNER_ADDRESS);

  const FxPoolF = await ethers.getContractFactory("NilaFxPool", deployer);
  
  console.log("Starting deployProxy...");
  const fxPool = await upgrades.deployProxy(
    FxPoolF,
    [
      USDT,             // usdt_
      NIN,              // nin_
      ORACLE,           // oracle_
      fxThresholdBps,   // fxThresholdBps_
      globalCapPerDay,  // globalCapPerDay_
      maxOracleDelay,   // maxOracleDelay_
      epochDuration,    // epochDuration_
      OWNER_ADDRESS     // admin_
    ],
    {
      kind: "uups",
      initializer: "initialize",
      timeout: 0,            // 0 = wait indefinitely
      pollingInterval: 5000, // poll every 5 seconds
    }
  );
  console.log("deployProxy tx sent… waiting for receipt...");
  
  await fxPool.waitForDeployment();
  const fxPoolAddr = await fxPool.getAddress();
  console.log("FxPool proxy deployed at:", fxPoolAddr);

  // Show implementation address too
  const implAddr = await upgrades.erc1967.getImplementationAddress(fxPoolAddr);
  console.log("Implementation address  :", implAddr);

  const epoch = await fxPool.getFxEpoch();
  console.log("Initial FX epoch:", {
    rate: epoch[0].toString(),
    timestamp: epoch[1].toString(),
    duration: epoch[2].toString(),
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
