/*
Run:
  npx hardhat run scripts/handleFunds/deployGenericFund.js --network amoy
Env:
  TREASURY=0x...
  ORACLE_SIGNER=0x...
*/

/* 
    V.1.2
    - updates: 
        - improve rate calc
        - add transfer loan
        - add roll-over loan
        - default loan
        - concept of senior and junior investors

        - earmark investments to union, but also to loan type
        - union leader set as part of union, not generic. 
        - to withdraw funds as an investor (either senior or junion),
            a unbonding period is minimal 2 weeks, 
            or estimated how long it takes for borrowers to repay.
                - discuss estimate based on reportMaturity ( so within ~6 weeks )
        - also allow ERC1155 assets to be deposited in the contract, registered to a union..


        MISSING: 
        - a governance exit hatch to auction escrowed 1155s and recycle proceeds back into the pool.
        - a view that previews loan funding feasibility with current buffer (returns required reserve and shortfall), 
        - and/or a per-union extra buffer on top of the per-token buffer.


        ISSUES:
        - we split payback 50/50, which means we split interest in two, then distribute equally to senior and junior, meaning that
        if one is much larger then the other, investors in those buckets get very different amounts..

        
*/

const { ethers, upgrades } = require("hardhat");

async function main() {
  const treasury     = process.env.TREASURY;
  const oracleSigner = process.env.ORACLE_SIGNER;

  if (!treasury || !oracleSigner) {
    throw new Error("Missing env: TREASURY and/or ORACLE_SIGNER");
  }

  console.log("Deploying GenericFundUpgradeable (UUPS)...");
  console.log("treasury     :", treasury);
  console.log("oracleSigner :", oracleSigner, "(will also become contract owner)");

  const Fund = await ethers.getContractFactory("GenericFundUpgradeable");

  // Deploy UUPS proxy + implementation, and call initialize(...)
  const proxy = await upgrades.deployProxy(
    Fund,
    [treasury, oracleSigner],
    { kind: "uups", initializer: "initialize" }
  );
  const proxyAddress = await proxy.getAddress();
  console.log("Proxy deployed at:", proxyAddress);

  const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log("Implementation deployed at:", implAddress);

  // Optional: show admin slot (for UUPS this is the ERC1967 admin—not used for auth)
  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("ERC1967 Admin (proxy):", adminAddress);

  console.log("\n✅ Deployed GenericFundUpgradeable (UUPS)");
  console.log("   proxy          :", proxyAddress);
  console.log("   implementation :", implAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
