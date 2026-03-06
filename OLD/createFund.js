// scripts/deployAndCreateFund.js
const hre = require("hardhat");
require("dotenv").config();

// npx hardhat run scripts/handleFunds/createFund.js --network polygon_amoy_union_leader
async function main() {
  const [deployer]    = await hre.ethers.getSigners();
  const FACTORY_OWNER = process.env.UNION_ADDRESS;       // union address (owner of factory)
  const NILA_ADDRESS  = process.env.NILA_ADDRESS;
  const USDC_ADDRESS  = process.env.USDC_ADDRESS;
  const ORACLE_SIGNER = process.env.ORACLE_SIGNER;
  const BASE_RATE_BP  = Number(process.env.BASE_RATE_BP || "600");
  const FUND_NAME     = "Mth Teresa CropCare";
  const FUND_TYPE     = "InputFund";

  // 1) Deploy the factory logic
  const FactoryFactory = await hre.ethers.getContractFactory("FundFactoryUpgradeable", deployer);
  const factoryLogic   = await FactoryFactory.deploy();
  await factoryLogic.waitForDeployment();   // ← ethers v6
  console.log("Factory logic deployed at:", factoryLogic.target);

  // 2) Deploy the proxy for the factory, initializing it
  const initData = factoryLogic.interface.encodeFunctionData(
    "initialize",
    [FACTORY_OWNER, process.env.INPUT_FUND_LOGIC]
  );

  // If you already have InputFund logic deployed, replace the next line’s placeholder:
  const INPUT_FUND_LOGIC = process.env.INPUT_FUND_LOGIC; 
  if (!INPUT_FUND_LOGIC) throw new Error("Set INPUT_FUND_LOGIC in .env");

  const ProxyFactory   = await hre.ethers.getContractFactory("ERC1967Proxy", deployer);
  const factoryProxy   = await ProxyFactory.deploy(
    factoryLogic.target,
    factoryLogic.interface.encodeFunctionData("initialize", [FACTORY_OWNER, INPUT_FUND_LOGIC])
  );
  await factoryProxy.waitForDeployment();
  console.log("Factory proxy deployed at:", factoryProxy.target);

  // 3) Call createInputFund on the proxy
  const factory = await hre.ethers.getContractAt(
    "FundFactoryUpgradeable",
    factoryProxy.target,
    deployer
  );

  const tx = await factory.createInputFund(
    [NILA_ADDRESS, USDC_ADDRESS],
    FUND_NAME,
    FUND_TYPE,
    ORACLE_SIGNER,
    BASE_RATE_BP,
    FACTORY_OWNER
  );
  const receipt = await tx.wait();
  console.log("📝 createInputFund tx hash:", tx.hash);
  
  // parse the logs for FundCreated
  const fundCreatedEvent = receipt.logs
    .map(log => {
      try {
        return factory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find(e => e && e.name === "FundCreated");
  
  if (!fundCreatedEvent) {
    throw new Error("FundCreated event not found!");
  }
  
  const newFundProxy = fundCreatedEvent.args.fund;
  console.log("🏦 New fund proxy address:", newFundProxy);
  console.log("👤 Belongs to union:", fundCreatedEvent.args.owner);
  console.log("📖 Fund type/name:", fundCreatedEvent.args.fundType);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
