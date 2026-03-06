const { ethers } = require("hardhat");
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";
const TX = "0x2e5d1f3162e68c4fb6e30967a98f90086955c4f222f2d968418818ea27683ae5";

async function main() {
  const tx = await ethers.provider.getTransaction(TX);
  const receipt = await ethers.provider.getTransactionReceipt(TX);
  console.log("tx.to           :", tx?.to);
  console.log("receipt.status  :", receipt?.status, "(1=success, 0=revert)");
  console.log("contractAddress :", receipt?.contractAddress ?? "(none — not a deploy tx)");
  console.log("gas used        :", receipt?.gasUsed?.toString());
  console.log("logs count      :", receipt?.logs?.length);

  const raw = await ethers.provider.getStorage(FXPOOL, IMPL_SLOT);
  const impl = ethers.getAddress("0x" + raw.slice(26));
  console.log("\nFxPool impl NOW (chain):", impl);
  console.log("Is still pre-CS003 (94f2)?", impl.toLowerCase() === "0x94f2bf94d27e480227341c66a8df90c700bd6b0d");
}
main().catch(console.error);
