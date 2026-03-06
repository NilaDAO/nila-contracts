const { ethers } = require("hardhat");
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const VIEWER = "0x435A12c4fD4B5a2D1D2ae6AB19D431D62084AdDA";
const TX_HASH = "0x6afce6c1eb882e851f2f288ea25f096abc170bc1defd550ffa0f744d86bb7caf";
async function main() {
  const tx      = await ethers.provider.getTransaction(TX_HASH);
  const receipt = await ethers.provider.getTransactionReceipt(TX_HASH);
  console.log("tx.to         :", tx?.to);
  console.log("receipt.status:", receipt?.status, "(1=success, 0=revert)");
  console.log("gas used      :", receipt?.gasUsed?.toString());
  console.log("logs count    :", receipt?.logs?.length);

  // Current impl on chain right now
  const raw  = await ethers.provider.getStorage(VIEWER, IMPL_SLOT);
  const impl = ethers.getAddress("0x" + raw.slice(26));
  console.log("\nViewer impl now (chain):", impl);

  // Does it have the new recoverVoucherSigner with 13 params?
  const viewer = await ethers.getContractAt("GenericFundViewer", VIEWER);
  // Count params on recoverVoucherSigner fragment
  const frag = viewer.interface.getFunction("recoverVoucherSigner");
  console.log("recoverVoucherSigner param count:", frag?.inputs?.length, "(expect 13 for CS003)");
  console.log("params:", frag?.inputs?.map((i: any) => `${i.type} ${i.name}`).join(", "));
}
main().catch(console.error);
