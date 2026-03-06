
/*
rm -rf artifacts cache
npx hardhat run scripts/handleGrants/deployContract.js --network amoy
*/
const { ethers, upgrades } = require("hardhat");

async function main() {
  // signer 0 will be owner
  const [master, unionLeader, investor] = await ethers.getSigners();
  console.log("Deploying NilaGrants with account:", master.address);

  // Addresses for constructor arguments, set these in your .env or replace directly
  const nilaTokenAddress       = process.env.NILA_ADDRESS;       // Nila ERC-20 token contract
  const landTitleAddress       = process.env.LAND_TITLE;       // LandTitle ERC-721 contract
  const investmentContractAddr = process.env.FUND_ADDRESS;  // UnionLending contract
  const foodTokenAddress       = process.env.FOOD_TOKENS_PROXY_ADDRESS;       // FoodToken ERC-1155 contract

  if (!nilaTokenAddress || !landTitleAddress || !investmentContractAddr || !foodTokenAddress) {
    console.error("Missing one or more environment variables: NILA_TOKEN, LAND_TITLE, INVESTMENT_CONTRACT, FOOD_TOKEN");
    process.exit(1);
  }

  const NilaGrants = await ethers.getContractFactory("NilaGrants", master);
  const nilaGrants = await NilaGrants.deploy(
    nilaTokenAddress,
    landTitleAddress,
    investmentContractAddr,
    foodTokenAddress
  );

  await nilaGrants.waitForDeployment();
  console.log("NilaGrants deployed to target:", nilaGrants.target);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });