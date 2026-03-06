const { ethers, upgrades } = require("hardhat");

/**
 npx hardhat run scripts/handleFoodTokens/deployBase.js --network amoy
 */
async function main() {
    const [master, unionLeader, investor] = await ethers.getSigners();
    console.log("Deploying as:", master.address);

    const Food = await ethers.getContractFactory("FoodTokenUpgradeable");
    const baseURI = "ipfs://QmYourCID/{id}.json";
    const initialOracle = master.address;

    // Sanity check:
    if (typeof initialOracle !== "string" || !initialOracle.startsWith("0x")) {
        throw new Error("initialOracle must be a hex string address!");
    }
    console.log("Deploying as:", baseURI, initialOracle);

    // Deploy a UUPS proxy
    const foodProxy = await upgrades.deployProxy(
        Food,
        [baseURI, initialOracle],
        { initializer: "initialize", kind: "uups" }
    );
    await foodProxy.waitForDeployment();

    console.log("FoodTokenUpgradeable proxy deployed to:", foodProxy.target);
    console.log("Implementation address:", await upgrades.erc1967.getImplementationAddress(foodProxy.target));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
