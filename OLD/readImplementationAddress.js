
const hre = require("hardhat");
// npx hardhat run scripts/handleFunds/readImplementationAddress.js --network polygon_amoy_union_leader

async function main() {
    const proxyAddr = process.env.FUND_FACTORY_ADDRESS;  

    const slot      = "0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC";
    const provider  = hre.ethers.provider;  // ethers v6
    
    // read the 32-byte slot
    const raw       = await provider.getStorage(proxyAddr, slot);
    
    // the implementation address is the lower 20 bytes
    const implAddr  = hre.ethers.getAddress("0x" + raw.slice(26));
    
    console.log("🔧 Implementation lives at:", implAddr);
}

main().catch(console.error);