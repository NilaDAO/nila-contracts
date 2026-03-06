// npx hardhat run scripts/TOMAINNET/deploy_fx_manual.ts --network polygon
const { ethers } = require("hardhat");

function addr(x: string | undefined, name: string) {
  if (!x) throw new Error(`Missing env var: ${name}`);
  return ethers.getAddress(x);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", await deployer.getAddress());

  // already deployed implementation
  const impl = "0xF23EF57656189b5B1D1811c98a72d06058c1D1f9";

  const USDT          = addr(process.env.USDT_ADDRESS, "USDT_ADDRESS");
  const NIN           = addr(process.env.NIN_MAIN, "NIN_MAIN");
  const ORACLE        = addr(process.env.USD_INR_FEED, "USD_INR_FEED");
  const OWNER_ADDRESS = addr(process.env.OWNER_ADDRESS, "OWNER_ADDRESS");

  const fxThresholdBps  = 200;
  const globalCapPerDay = ethers.parseUnits("500", 6);
  const maxOracleDelay  = 3600 * 24;
  const epochDuration   = 90 * 24 * 60 * 60;

  // Encode initializer call
  const FxPoolF = await ethers.getContractFactory("NilaFxPool");
  const initData = FxPoolF.interface.encodeFunctionData("initialize", [
    USDT,
    NIN,
    ORACLE,
    fxThresholdBps,
    globalCapPerDay,
    maxOracleDelay,
    epochDuration,
    OWNER_ADDRESS,
  ]);

  const ProxyF = await ethers.getContractFactory("NilaFxPoolProxy");

  console.log("Deploying proxy pointing to impl:", impl);
  const proxy = await ProxyF.deploy(impl, initData, {
    // you can bump this if Polygon is busy
    gasPrice: ethers.parseUnits("80", "gwei"),
  });

  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  console.log("FX Pool PROXY deployed at:", proxyAddr);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
