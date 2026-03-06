
/*
rm -rf artifacts cache
npx hardhat run scripts/handleGrants/addUnion.js --network amoy
*/
const { ethers, upgrades } = require("hardhat");
const grantAddress       = process.env.GRANT_ADDRESS;       // FoodToken ERC-1155 contract

async function main() {
  // signer 0 will be owner
  const [master, unionLeader, investor] = await ethers.getSigners();
  const unionAddress = "0xC7FdEf69986317c1770d46C850560D9e469849Cf"
  console.log("Adding union  with account:", master.address);
  const grant = await ethers.getContractAt("NilaGrants", grantAddress, master);

  console.log(`🔗 Calling addUnion(${unionAddress}) on ${grant}…`)
  const tx = await grant.AddUnions(unionAddress)
  console.log('📡 tx hash:', tx.hash)

  console.log('⏳ waiting for confirmation…')
  const receipt = await tx.wait()
  console.log('✅ mined in block', receipt.blockNumber)
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });