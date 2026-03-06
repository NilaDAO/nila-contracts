// npx hardhat run scripts/TOMAINNET/genericFund_deploy.ts --network polygon
const { ethers, upgrades, run  } = require("hardhat");

import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  const {
    LAND_TITLE_MAIN,
    OWNER_ADDRESS,
    ORACLE_SIGNER_MAIN,
    NIN_MAIN,
    MATHLIB_MAIN,
  } = process.env;

  if (!LAND_TITLE_MAIN || !NIN_MAIN || !OWNER_ADDRESS || !ORACLE_SIGNER_MAIN || !MATHLIB_MAIN ) {
    throw new Error("Missing one or more env vars: LAND_TITLE_MAIN, OWNER_ADDRESS, ORACLE_SIGNER_MAIN, NIN_MAIN, MATHLIB_MAIN");
  }
  
  // 1) Deploy the math library (linked, public/pure methods)
  /*
  const MathLibF = await ethers.getContractFactory("GenericFundMathLib");
  const mathLib = await MathLibF.deploy();
  await mathLib.waitForDeployment();
  const mathLibAddr = await mathLib.getAddress();
  console.log(`GenericFundMathLib: ${mathLibAddr}`);
  */
  const mathLib = await ethers.getContractAt("GenericFundMathLib", MATHLIB_MAIN, deployer);
  const mathLibAddr = await mathLib.getAddress();
  console.log(`mathLib: ${mathLibAddr}`);

  // 2) Deploy Roles registry (replace with your concrete registry)
  // Must implement: isOracle(address), isLeader(address,address)
  
  
  const RolesF = await ethers.getContractFactory("RolesRegistry");
  const roles = await RolesF.deploy(OWNER_ADDRESS);
  await roles.waitForDeployment();
  const rolesAddr = await roles.getAddress();

  /*
  const roles = await ethers.getContractAt("RolesRegistry", "0xDBeFBbc602e7D12C1a6718272765997deA07fd1e", deployer);
  const rolesAddr = await roles.getAddress();
  console.log(`roles: ${rolesAddr}`);
  // set initial oracle (for vouchers & quotes)
  */

  const setOracle = await roles.setOracle(ORACLE_SIGNER_MAIN, true);
  await setOracle.wait();
  console.log(`Oracle whitelisted: ${ORACLE_SIGNER_MAIN}`);
  
  // 3) Deploy Core (UUPS proxy) — linked to the library  
  const CoreF = await ethers.getContractFactory("GenericFundCore", {
    libraries: { GenericFundMathLib: mathLibAddr },
  });

  // Deploy UUPS proxy + implementation
  const core = await upgrades.deployProxy(
    CoreF,
    [LAND_TITLE_MAIN, rolesAddr, NIN_MAIN],
    {
      kind: "uups",
      unsafeAllowLinkedLibraries: true,
    }
  );
  await core.waitForDeployment();
  const coreProxyAddr = await core.getAddress();
  const coreImplAddr = await upgrades.erc1967.getImplementationAddress(coreProxyAddr);
  console.log(`GenericFundCore (proxy): ${coreProxyAddr}`);
  console.log(`GenericFundCore (impl) : ${coreImplAddr}`);
  
  /*
  const core = await ethers.getContractAt("GenericFundCore", "0xBea16D53399d5b6627D6c30aFDfB3f6482D5932B", deployer);
  
  const coreProxyAddr = await core.getAddress();
  const coreImplAddr = await upgrades.erc1967.getImplementationAddress(coreProxyAddr);
  console.log(`GenericFundCore (proxy): ${coreProxyAddr}`);
  console.log(`GenericFundCore (impl) : ${coreImplAddr}`);
  
  /*
  GenericFundCore (proxy): 0xDf1E3A369a6B03dc08BDA8cCCBDcAbFFfb10Ed70
  GenericFundCore (impl) : 0x3A4Fd5A73424E364d2f6a659D52Ca9DD54E2b86c
  */
  
  // Transfer ownership to OWNER_ADDRESS if deployer != owner
  /*
  if ((await core.owner()).toLowerCase() !== OWNER_ADDRESS.toLowerCase()) {
    const toOwner = await core.transferOwnership(OWNER_ADDRESS);
    await toOwner.wait();
    console.log(`Core ownership transferred to: ${OWNER_ADDRESS}`);
  }
  */

  const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
    libraries: { GenericFundMathLib: mathLibAddr },
  });
  // Deploy UUPS proxy + implementation
  const viewer = await upgrades.deployProxy(
    ViewerF,
    [coreProxyAddr,rolesAddr],
    {
      kind: "uups",
      unsafeAllowLinkedLibraries: true,
    }
  );
  await viewer.waitForDeployment();
  const viewerProxyAddr = await viewer.getAddress();
  const viewerImplAddr = await upgrades.erc1967.getImplementationAddress(viewerProxyAddr);
  const viewerAddr = await viewer.getAddress();
  /*
  GenericFundViewer (proxy): 0x78a4B60d18c85627f31108f6D0B31BE91A651e34
  GenericFundViewer (impl) : 0xa91eCE1dcdE65bA229D5FF8497E6e3B7091057ed
  */
  console.log(`GenericFundViewer (proxy): ${viewerProxyAddr}`);
  console.log(`GenericFundViewer (impl) : ${viewerImplAddr}`);

  // 4) Deploy Viewer (points to core proxy)
  /*
  const viewer = await ethers.getContractAt("GenericFundViewer", "0x78a4B60d18c85627f31108f6D0B31BE91A651e34", deployer);
  const viewerAddr = await viewer.getAddress();
  
  */
  
  // 5) Deploy ERC1155 Module (points to core; owner = MODULE_OWNER)
  /*
  const Mod1155F = await ethers.getContractAt("GenericFund1155Module", "0x5c1A7830E68bd955673C6564b4B51101295b0619", deployer);
  const mod1155Addr = await Mod1155F.getAddress();
  */

  const Mod1155F = await ethers.getContractFactory("GenericFund1155Module");
  const mod1155 = await Mod1155F.deploy(coreProxyAddr, OWNER_ADDRESS);
  await mod1155.waitForDeployment();
  const mod1155Addr = await mod1155.getAddress();
  console.log(`GenericFund1155Module: ${mod1155Addr}`);

  ////////////////////// SETTERS //////////////////////

  // Wire viewer in core
  const setV = await core.connect(deployer).setViewer(viewerAddr);
  await setV.wait();
  console.log(`Core.viewer set to ${viewerAddr}`);

  // Allow the 1155 module to call privileged mint on core (treat as oracle)
  const tx1 = await roles.setCore(coreProxyAddr, true);
  await tx1.wait();
  console.log(`Roles.core set to ${coreProxyAddr}`);

  // set hardcoded oracle
  const tx2 = await roles.setOracle(ORACLE_SIGNER_MAIN, true);
  await tx2.wait();
  console.log(`oracle set in roles: ${ORACLE_SIGNER_MAIN}`);

  // Allow the 1155 module to call privileged mint on core (treat as oracle)
  const tx3 = await roles.setOracle(mod1155Addr, true);
  await tx3.wait();
  console.log(`1155 module whitelisted as oracle: ${mod1155Addr}`);

  // 6) Optional: quick verify (libraries, impl, viewer, module)
  // (A) Library
  try {
    await run("verify:verify", { address: mathLibAddr, constructorArguments: [] });
    console.log("Verified: GenericFundMathLib");
  } catch (e) { console.log("Verify MathLib skipped:", (e as Error).message); }

  // (B) Core implementation
  try {
    await run("verify:verify", {
      address: coreImplAddr,
      constructorArguments: [],
      libraries: { GenericFundMathLib: mathLibAddr },
    });
    console.log("Verified: GenericFundCore implementation");
  } catch (e) { console.log("Verify Core impl skipped:", (e as Error).message); }

  // (C) Viewer
  try {
    await run("verify:verify", {
      address: viewerImplAddr,
      constructorArguments: [],
      libraries: { GenericFundMathLib: mathLibAddr },
    });
    console.log("Verified: GenericFundViewer implementation");
  } catch (e) { console.log("Verify Viewer skipped:", (e as Error).message); }

  // (D) 1155 Module
  try {
    await run("verify:verify", { address: mod1155Addr, constructorArguments: [coreProxyAddr, OWNER_ADDRESS] });
    console.log("Verified: GenericFund1155Module");
  } catch (e) { console.log("Verify Module skipped:", (e as Error).message); }

  console.log("\n=== Deployed (Amoy) ===");
  console.log(`MathLib:   ${mathLibAddr}`);
  console.log(`Roles:     ${rolesAddr}`);
  console.log(`CoreProxy: ${coreProxyAddr}`);
  console.log(`CoreImpl:  ${coreImplAddr}`);
  console.log(`Viewer:    ${viewerAddr}`);
  console.log(`1155Mod:   ${mod1155Addr}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
