// npx hardhat run scripts/TOMAINNET/deploy_landtitle.ts --network amoy

const { ethers, upgrades, run  } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deployer:", deployer.address);
  console.log(
    "Deployer balance:",
    (await ethers.provider.getBalance(deployer.address)).toString()
  );

  const NilaLandTitle = await ethers.getContractFactory("NilaLandTitle");

  console.log("Deploying NilaLandTitle UUPS proxy to Polygon mainnet...");

  // initializer: initialize(address initialOwner)
  const proxy = await upgrades.deployProxy(
    NilaLandTitle,
    [deployer.address],
    {
      kind: "uups",
    }
  );

  await proxy.waitForDeployment();

  const proxyAddress = await proxy.getAddress();
  console.log("NilaLandTitle proxy deployed at:", proxyAddress);

  // Optional: log implementation + admin for sanity
  const implAddress = await upgrades.erc1967.getImplementationAddress(
    proxyAddress
  );
  console.log("Implementation address:", implAddress);

  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);
  console.log("Proxy admin address:", adminAddress);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
