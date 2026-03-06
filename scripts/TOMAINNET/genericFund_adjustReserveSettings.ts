// npx hardhat run scripts/TOMAINNET/genericfund_adjustReserveSettings.ts --network polygon
const { ethers } = require("hardhat");
import { keccak256, toUtf8Bytes, Wallet, JsonRpcProvider, encodeBytes32String, BytesLike } from "ethers";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const CORE_PROXY = (process.env.COREPROXY  || "").trim();     // Core proxy address
  const VIEWER_PROXY = (process.env.VIEWERPROXY || "").trim(); // Viewer proxy address
  const ROLES = (process.env.ROLES_MAIN  || "").trim();
  const UNION_ADDR = '0xF18E4966731bD6D3a56c1eb23Da7C708c9C48070'; // Union address (EOA/contract used as union id)
  const UNION_NAME = 'Mother Theresa';                          // Human-readable name
  const UNION_LOCATION = '11.878671,78.964561';             // Human-readable location string
  const FUND_TYPES = "GroundUp Fund".split(",")             // Comma-separated list of display names
  .map(s => s.trim())
  .filter(Boolean);
  const FUND_IDS = "PLANTING".split(",")                    // Comma-separated list of fund ids (aligned with FUND_TYPES)
    .map(s => s.trim())
    .filter(Boolean);

  if (FUND_TYPES.length !== FUND_IDS.length) {
    throw new Error("FUND_TYPES and FUND_IDS must have the same length/order");
  }

  if (!CORE_PROXY || !VIEWER_PROXY || !UNION_ADDR || !UNION_NAME || !ROLES) {
    throw new Error("Missing env. Require CORE_PROXY, VIEWER_PROXY, ROLES, UNION_ADDR, UNION_NAME");
  }

  // Pick signer: OWNER_PK (if provided) or first hardhat signer
  const provider = ethers.provider as unknown as JsonRpcProvider;
  const signer = process.env.OWNER_PK
    ? new Wallet(process.env.OWNER_PK!, provider)
    : (await ethers.getSigners())[0];

  console.log(`Network : ${await provider.getNetwork().then(n => `${n.name} (${n.chainId})`)}`);
  console.log(`Signer  : ${await signer.getAddress()}`);
  console.log(`Core    : ${CORE_PROXY}`);
  console.log(`Viewer  : ${VIEWER_PROXY}`);
  console.log(`Roles   : ${ROLES}`);
  console.log(`Union   : ${UNION_ADDR} (${UNION_NAME})`);
  console.log(`Types   : ${FUND_TYPES.join(", ") || "(none)"}`);
  console.log(`IDs     : ${FUND_IDS.join(", ") || "(none)"}`);

  const core = await ethers.getContractAt("GenericFundCore", CORE_PROXY, signer);
  const viewer = await ethers.getContractAt("GenericFundViewer", VIEWER_PROXY, signer);
  const roles = await ethers.getContractAt("RolesRegistry", ROLES, signer);

  const union_onchain = await viewer.getUnion(UNION_ADDR);
  console.log('union_onchain', union_onchain);

  // Sanity: roles wiring on core/viewer
  try {
    console.log("core.roles():   ", await core.roles());
  } catch (e) {
    console.log("core.roles() unavailable:", e?.shortMessage || e);
  }
  try {
    console.log("viewer.roles(): ", await viewer.roles());
  } catch (e) {
    console.log("viewer.roles() unavailable:", e?.shortMessage || e);
  }
  
  // Ensure core points to this viewer
  const viewerAddr = await viewer.getAddress();
  const currentViewer = await core.viewer();
  if (currentViewer.toLowerCase() !== viewerAddr.toLowerCase()) {
    console.log(`Updating core.viewer from ${currentViewer} -> ${viewerAddr}`);
    const tx = await core.setViewer(viewerAddr);
    await tx.wait();
  }

  // Ensure signer is owner of viewer/core (required for CreateUnion/AddFundType/setViewer)
  const signerAddr = (await signer.getAddress()).toLowerCase();
  const coreOwner = (await core.owner()).toLowerCase();
  const viewerOwner = (await viewer.owner()).toLowerCase();
  const rolesOwner = (await roles.owner()).toLowerCase();
  if (coreOwner !== signerAddr) throw new Error(`Signer is not Core owner. Core owner: ${coreOwner}`);
  if (viewerOwner !== signerAddr) throw new Error(`Signer is not Viewer owner. Viewer owner: ${viewerOwner}`);
  if (rolesOwner !== signerAddr) throw new Error(`Signer is not Roles owner. Roles owner: ${rolesOwner}`);

  // 4) set rate params
  // WE ASSUME 6% ON 90 DAYS + 21 days (payback time), SO 356 DAYS IS 19.24%
  const baseRateBP = 600;
  const maxRateBP = 1924;
  const kink = 9000; // when utilization rate hits kink (e.g. 8000 = 80%), rate steepener kicks in.
  const tx2 = await core.setRateParams(UNION_ADDR, baseRateBP, kink, 100, 4000, maxRateBP);
  await tx2.wait();
  console.log(`rate params set for "${UNION_ADDR}".`);
  
  // 5) add leaders (hardcoded list)
  const leader = UNION_ADDR;
  const txLeader = await roles.setLeader(UNION_ADDR, leader, true);
  await txLeader.wait();
  const worker1 = '0x4Ba22D562F4e308c539c08E7544d9dAe8DB020A6'; // louisa
  const txworker1 = await roles.setLeader(UNION_ADDR, worker1, true);
  await txworker1.wait();
  const worker2 = '0xaF48a2282FD8A3cCb52D17EF08FE5db7d346Dbb7'; // anand
  const txworker2 = await roles.setLeader(UNION_ADDR, worker2, true);
  await txworker2.wait();
  const worker3 = '0xaf7030023CF86611FfC5a71798a0f7022210F2b3'; // Me
  const txworker3 = await roles.setLeader(UNION_ADDR, worker3, true);
  await txworker3.wait();
  console.log(`Leader set: ${leader}`);

  /*
  // 5) add a loan with known id to viewer (in case proxy was updated in viewer but core still similar)
  
  const tx5 = await viewer.onLoanCreated(UNION_ADDR,'0x00000000000000000000000000000000000000000000000000000000000de95d' ,'0xaf7030023CF86611FfC5a71798a0f7022210F2b3');
  await tx5.wait();
  console.log(`loan id added "${UNION_ADDR}".`);


  // 6) remove fund
  const loanType = "0x9c5a6278f58a60708cd5a4a4dd7507dc95924d7e8e23165514e0701932c6cb37"
  const tx = await core.removeFundType(UNION_ADDR, loanType);
  await tx.wait();
  */

}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
