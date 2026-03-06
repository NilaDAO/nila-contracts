const { ethers } = require("hardhat");

/*
npx hardhat run scripts/localNodeMisc/topupbalance.js --network localhost
*/

async function main() {
    const addr = "0xC7FdEf69986317c1770d46C850560D9e469849Cf";                       // your test-net wallet
    await ethers.provider.send("hardhat_setBalance", [
    addr,
    "0x21E19E0C9BAB2400000"   // 10 000 ETH (hex) – overkill but free
    ]);
}

main().catch(console.error);
