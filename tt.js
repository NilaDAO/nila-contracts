const { ethers, upgrades, network } = require("hardhat");

async function main() {
    const [d] = await ethers.getSigners()
    const addr = await d.getAddress()
    const fee = await ethers.provider.getFeeData()
    console.log("fee:", fee)
    const tx = await d.sendTransaction({
    to: addr,
    value: 0,
    nonce: 92,
    maxFeePerGas: fee.maxFeePerGas * 2n,
    maxPriorityFeePerGas: fee.maxPriorityFeePerGas * 2n,
    })
    await tx.wait()

    await ethers.provider.getTransactionCount(addr, "latest")
    await ethers.provider.getTransactionCount(addr, "pending")
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
