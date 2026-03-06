const { ethers } = require("hardhat");

/*
npx hardhat run scripts/handleFunds/removeToken.js --network amoy
*/

async function main() {
    const [master, unionLeader, investor] = await ethers.getSigners();

    const FUND_PROXY = "0xaFc72FCE73fBF15B919b4ae64Af4394d64c3A4A5" //"0x353A1B3eDcB20F2D58BB9a95DF85f77C4EbB3F0C";  // FUND FUND PROXY (NOT FACTORY)
    const fund = await ethers.getContractAt("InputFundUpgradeable", FUND_PROXY, unionLeader);

    // call the add token function
    const tx = await fund.revokeToken(process.env.NILA_ADDRESS);        // token address

    await tx.wait();
    // verify if ID has been set with similar target
    console.log("✅ token removed");

}

main().catch(console.error);
