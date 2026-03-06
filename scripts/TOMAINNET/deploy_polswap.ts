// npx hardhat run scripts/TOMAINNET/deploy_polswap.ts --network polygon
const { ethers, upgrades, network } = require("hardhat");

upgrades.silenceWarnings = false;

function addr(x: string, name: string) {
  if (!x) throw new Error(`Missing env var: ${name}`);
  return ethers.getAddress(x);
}

function boolEnv(x: string | undefined, fallback: boolean) {
  if (x === undefined) return fallback;
  return x.toLowerCase() === "true";
}

function numEnv(x: string | undefined, fallback: number) {
  if (x === undefined) return fallback;
  const n = Number(x);
  if (!Number.isFinite(n)) throw new Error(`Invalid number: ${x}`);
  return n;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Network  :", network.name);
  console.log("Deployer :", await deployer.getAddress());

  const NIN = addr(String(process.env.NIN_MAIN), "NIN_MAIN");
  const INR_ORACLE = addr(String(process.env.USD_INR_FEED), "USD_INR_FEED");
  const POL_ORACLE = addr(String(process.env.POL_USD_FEED), "POL_USD_FEED");
  const SUBSIDY_ADDRESS = addr(String(process.env.SUBSIDY_ADDRESS), "SUBSIDY_ADDRESS");
  const OWNER_ADDRESS = addr(String(process.env.OWNER_ADDRESS), "OWNER_ONLY");

  const POL_ORACLE_USD_PER_POL = boolEnv(process.env.POL_ORACLE_USD_PER_POL, true);
  const maxOracleDelay = numEnv(process.env.MAX_ORACLE_DELAY, 3600 * 24);

  console.log("NIN           :", NIN);
  console.log("INR ORACLE    :", INR_ORACLE);
  console.log("POL ORACLE    :", POL_ORACLE);
  console.log("POL/USD feed  :", POL_ORACLE_USD_PER_POL);
  console.log("SUBSIDY       :", SUBSIDY_ADDRESS);
  console.log("OWNER (admin) :", OWNER_ADDRESS);
  console.log("MAX ORACLE DEL:", maxOracleDelay);

  const SwapF = await ethers.getContractFactory("NilaPOLSwap", deployer);

  console.log("Starting deployProxy...");
  const swap = await upgrades.deployProxy(
    SwapF,
    [
      NIN,
      INR_ORACLE,
      POL_ORACLE,
      POL_ORACLE_USD_PER_POL,
      maxOracleDelay,
      SUBSIDY_ADDRESS,
      OWNER_ADDRESS,
    ],
    {
      kind: "uups",
      initializer: "initialize",
      timeout: 600000,
      pollingInterval: 5000,
    }
  );
  console.log("deployProxy tx sent… waiting for receipt...");

  await swap.waitForDeployment();
  const swapAddr = await swap.getAddress();
  console.log("NilaPOLSwap proxy deployed at:", swapAddr);

  const implAddr = await upgrades.erc1967.getImplementationAddress(swapAddr);
  console.log("Implementation address  :", implAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
