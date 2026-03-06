// scripts/handleFunds/deployFund.js
/*
npx hardhat run scripts/handleFunds/deployFund.js --network amoy
*/
const { ethers } = require("hardhat");
/**
 -
    owner          : 0xC7FdEf69986317c1770d46C850560D9e469849Cf
    proxy          : 0x48F0bADd2A72Ebe2f29aE8b35a53CA9Ceeafc92b
✅  implementation : 0x8F0Fcafd9b8Ec27102eD1B68eD1FFA60d9935632
    fundType       : INPUT
    tx hash        : 0x33ef15eb87898f27314eecdac4d94ee0006b9d012e6e39a257302bf22e25410c

   UPDATES WITH UPGRADEFUND
      V1        : 0x61Df4590E5c5dec69849988bE8993E222f6268e8 added getLoansByBorrower
      V2        : 0xEA1856c3383fD98B3FAd3C8DA08011B3bE44e4cF added name to getBorrowerInfo
      V3        : 0x9ecbc0D31ecA7F5B7f19800840a6642dDc195461 removed require duedate in repayLoan, returns data on repayloan and claimLoan

   ### to run this, first make sure you have the latest implementation set at
   the factory using callSetFundLogic.js
 */

   /**
    * Deployed PLantingFundUpgradeable
      - proxy: 0x154ACE2fbe1D3dF1e1A17B8E8EFa6fE8190984d5
    */

async function planting() {
  // ── existing FundFactory proxy ─────────────────────────────
  const factoryAddr = process.env.FUND_FACTORY_PROXY_ADDRESS;

  // -- getSigners not needed, factory will use unionAddr as owner.
  const factory     = await ethers.getContractAt("FundFactoryUpgradeable", factoryAddr);

  // ── fund parameters (adjust as needed) ─────────────────────
  const treasury   = process.env.TREASURY
  const oracle     = process.env.ORACLE_SIGNER;

  console.log(`treasury: ${treasury}`);
  console.log(`oracle  : ${oracle}`);

  // ── send tx (any user can call) ────────────────────────────
  const tx = await factory.createPlantingFund(
    treasury,
    oracle,

  );
  const rc  = await tx.wait();

  // ── read FundCreated(...) event ─
  const evt = rc.logs.find(l => l.fragment?.name === "GlobalFundCreated");
  console.log('fund created with tx hash:', tx.hash )
  console.log(`
    proxy          : ${evt.args.proxy}
✅  implementation : ${evt.args.impl}
`);
}

async function input() {
  // ── existing FundFactory proxy ─────────────────────────────
  const factoryAddr = process.env.FUND_FACTORY_PROXY_ADDRESS;

  // -- getSigners not needed, factory will use unionAddr as owner.
  const factory     = await ethers.getContractAt("FundFactoryUpgradeable", factoryAddr);

  // ── fund parameters (adjust as needed) ─────────────────────
  const tokenList    = [process.env.NILA_ADDRESS, process.env.USDC_ADDRESS];
  const fundName     = "Mth Teresa Cropcare";
  const fundType     = "INPUT";                         // <- maps to keccak256("INPUT")
  const oracleSigner = process.env.ORACLE_SIGNER;
  const baseRateBP   = Number(process.env.BASE_RATE_BP ?? "600");
  const unionAddr    = process.env.UNION_ADDRESS;

  // ── send tx (any user can call) ────────────────────────────
  const tx = await factory.createInputFund(
    tokenList,
    fundName,
    fundType,
    oracleSigner,
    baseRateBP,
    unionAddr
  );
  const rc  = await tx.wait();

  // ── read FundCreated(address owner,address fund,string type) event ─
  const evt = rc.logs.find(l => l.fragment?.name === "FundCreated");
  console.log('fund created with tx hash:', tx.hash )
  console.log(`
    owner          : ${evt.args._union}
    proxy          : ${evt.args.proxy}
✅  implementation : ${evt.args.fund}
    fundType       : ${evt.args.fundType}
`);
}

planting().catch(console.error);
