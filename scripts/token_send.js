const { ethers } = require("hardhat");

async function main() {
    const [sender] = await ethers.getSigners();
    const tokenAddress = "0x10D11eDD572ccb54D6D59f07521eA071Ed1C326E"; // Replace with your token address
    const recipient = "0x119a09055eDf0E204112948eE580bA2A236c01b0"; // Replace with recipient address
    const amount = ethers.parseUnits("10", 18); // Sending 10 tokens (adjust decimals)

    const token = await ethers.getContractAt("IERC20", tokenAddress);

    console.log(`Sending ${amount} tokens from ${sender.address} to ${recipient}`);

    // Sending the tokens
    //const tx = await token.transfer(recipient, amount);
    //await tx.wait();

    console.log(`Transaction successful! Hash: ${tx.hash}`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
