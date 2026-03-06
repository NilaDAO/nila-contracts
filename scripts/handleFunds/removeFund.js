const { ethers } = require("hardhat");

/*
rm -rf artifacts cache
npx hardhat run scripts/handleFunds/removeFund.js --network amoy
*/

async function main() {
    /* ------------------------------------------------------------
        Prep signer (must be the fund owner!)
    -------------------------------------------------------------*/
    const [master, unionLeader, investor] = await ethers.getSigners();

    /* ------------------------------------------------------------
        Attach to factory proxy
    -------------------------------------------------------------*/
    const factoryAddr = process.env.FUND_FACTORY_PROXY_ADDRESS;
    if (!factoryAddr) throw new Error("FACTORY_PROXY env var missing");

    const factory = await ethers.getContractAt(
        "FundFactoryUpgradeable",
        factoryAddr,
        unionLeader
    );

    /* ------------------------------------------------------------
        List funds owned by this signer
    -------------------------------------------------------------*/
    const list   = await factory.getFundsByOwner(unionLeader.address);
    console.log(`Funds owned by ${unionLeader.address} (${list.length}):`);
    list.forEach((fi, i) => console.log(`${i}. ${fi.fund}  –  ${fi.name}`));
    
    /* ------------------------------------------------------------
        Check the actual owner
    -------------------------------------------------------------*/

    console.log(`Funds registered for ${unionLeader.address} (${list.length}):`);
    for (let i = 0; i < list.length; i++) {
    const { fund, name } = list[i];

    // attach to the fund proxy (read-only)
    const fundCtr = await ethers.getContractAt("InputFundUpgradeable", fund);
    const onChainOwner = await fundCtr.owner();

    console.log(
        `${i}. ${name.padEnd(12)}  ${fund}  →  owner(): ${onChainOwner}`
    );
    }
    /* ------------------------------------------------------------
        Optionally remove one fund
    -------------------------------------------------------------*/
    const target = false //"0x353A1B3eDcB20F2D58BB9a95DF85f77C4EbB3F0C"
    if (!target) return;                         // only listing

    const found = list.find((fi) =>
        fi.fund.toLowerCase() === target.toLowerCase()
    );
    if (!found) throw new Error("Target fund not in your list");

    console.log(`\n→ Removing ${target} ...`);
    const tx = await factory.removeFund(target);
    await tx.wait();
    console.log("✓ Fund removed");
    }

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
