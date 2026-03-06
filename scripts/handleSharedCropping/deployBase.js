const { ethers, upgrades } = require("hardhat");

/**
 npx hardhat run scripts/handleSharedCropping/deployBase.js --network amoy
 */
async function main() {
    const [master, unionLeader, investor] = await ethers.getSigners();
    console.log("Deploying as:", master.address);

    const contract = await ethers.getContractFactory("SharedCroppingUpgradeable");
    const baseURI = "ipfs://QmYourCID/{id}.json";
    const initialOracle = master.address;

    // Sanity check:
    if (typeof initialOracle !== "string" || !initialOracle.startsWith("0x")) {
        throw new Error("initialOracle must be a hex string address!");
    }
    console.log("Deploying as:", baseURI, initialOracle);

    // Deploy a UUPS proxy
    const Proxy = await upgrades.deployProxy(
        contract,
        [
            baseURI, 
            initialOracle
        ],
        { initializer: "initialize", kind: "uups" }
    );
    await Proxy.waitForDeployment();

    console.log("SharedCroppingUpgradeable proxy deployed to:", Proxy.target);
    console.log("Implementation address:", await upgrades.erc1967.getImplementationAddress(Proxy.target));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
