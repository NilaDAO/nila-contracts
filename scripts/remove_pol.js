const { ethers } = require("hardhat");
const { AES } = require('crypto-js')
const Utf8 = require("crypto-js/enc-utf8");

// RUN: npx hardhat run --no-compile scripts/remove_pol.js
/**
 * Decypher PK encrypt with salt
 * get amount, minus 0.5 
 * send to recipient
 */


async function sendPOL(senderPK, recipient) {
    // Connect wallet using private key
    const provider = new ethers.JsonRpcProvider('https://rpc.ankr.com/polygon_amoy');
    const wallet = new ethers.Wallet(senderPK, provider);

    // Get sender balance
    const balance = await provider.getBalance(wallet.address);
    const balanceInETH = ethers.formatEther(balance);
    
    console.log(`Sender Balance: ${balanceInETH} POL`);

    // Ensure enough balance
    if (balanceInETH <= 0.4) {
        console.log("Not enough POL to send.");
        return;
    }

    // Calculate new amount (minus 0.5 POL)
    const amountToSend = ethers.parseEther((balanceInETH - 0.4).toString());

    // Create transaction
    const tx = await wallet.sendTransaction({
        to: recipient,
        value: amountToSend
    });

    console.log(`Transaction sent: ${tx.hash}`);
    await tx.wait(); // Wait for confirmation
    console.log("Transaction confirmed!");
}

async function deductPOL() {
    const pk = 'U2FsdGVkX1+AfJEFONlfsR8ttLLkzBhnsjUV3xhngOSIszTzU0BTPoReOY1j6JaxAJho9IVUPIB8oD699HxahFSror0jSjJqtqDe+KcDwz2+RLy8LEMdYdRemqkYl+0S'
    const salt = '72kjs6rtgxl'
    const recipient = '0x4387bf96c4da8Bd2d44981b276a8862B09BaE072'

    const decryptedBytes = AES.decrypt(pk, salt);
    const decryptedKey = decryptedBytes.toString(Utf8);
    console.log('decryptedKey', decryptedKey)

    //sendPOL(decryptedKey, recipient)
}

async function listPOL(addresses) {
    const provider = new ethers.JsonRpcProvider('https://rpc.ankr.com/polygon_amoy');

    for (const address of addresses) {
        const balance = await provider.getBalance(address);
        const balanceInPOL = ethers.formatEther(balance);
        console.log(`${address}: ${balanceInPOL} POL`);
    }
}

const addrs = ['0x8494eF5B87AeE125F0BC9dB3693016f8157701Da',
    '0x1740b2ceE45537d70f936C978e7B0c31cC3cB61C',
    '0x43E40d95a1A3bB44e5416D37A729834A45117C21',
    '0x6E2e26C8c537F03fbf70988a7F9e2D6EC75Df8cF',
    '0x187bbA14E53F54BB4d4b1daeAC23a14AF58A8c67',
    '0x1f537d67743ab44547E484cA79830f01A5225271',
    '0x2257097d07D0aA72c59Dc307fa74Eb9040b93256',
    '0x5A5A5f667120359D50589db991380a9e9ae2D135',
    '0xF1B306c4845673B1B98be4Ad4C2D39C6F544D5Fc',
    '0x82fA5cDf27cf3f7b0175C4928713d102758FaB0e',
    '0x4E2d0272B417E01FA92BE56f2A25864eE987c37B',
    '0xa198D4A40Fdf084AA0D8f34F0474f435c248c094',
    '0xfDddE5ef9383de9638293DA9Ac1bbB318D749109',
    '0xa2AAc30b7E730bD6289187Ae2D545103Ade1e3f2',
    '0x9ed8127114780cf3cbb19bF1A34C4E16EAC0b88A',
    '0xC341709E918DaA4960809C9F7E06ECDCe9AF295e',
    '0x2d0beabd341990B60d9a0Be739f44c27DfbF6000',
    '0x7F7AB67d1243F18605D21B8A0D65012B33Fee681',
    '0x8c14410D96773E3b45f02B50De9ea9f4cb0d8D89',
    '0xcE373E31B9160cDf5f13E606062806457a64E98E',
    '0x56df482D569FAc185Dfc3af45Bac32dbC8d7b07e',
    '0x4A35a200E6557e6fe695EA555e05Ddf94d8b0a20',
    '0xb13B71f3d66314c8E316b9bc749650a9EA35787C',
    '0x45647Ee0fb2aF8838969A0fc396a8BbCcFE58bF7',
    '0x954C396B90767D6416FbEAEb2C9761ed752e59f1',
    '0x7f94255A168Bca155d2c12068FF6AeF36f7736E4',
    '0x384EE7f00F4432b73f714D3F308Caf6C5E1a0f29',
    '0x834733e692eFF259877981228e5206a9A468C056',
    '0xC65Fd63055EE573975Ecc111f86776392B24eCbf',
    '0x4Ba22D562F4e308c539c08E7544d9dAe8DB020A6',
    '0xC1DDF1b3a5199f148612c6C3fF492e78AA853168',
    '0x630273be5f452234a8Dd251989b05352ed8C00bb',
    '0x61315ea89b4B51b28521021A9E6A94e54BDfe10b',
    '0x486b5Ca41dc0e0A96fF27cc5970282394E651635',
    '0x41b4B49353544CBCA454b2130b9c907FA8119d42',
    '0xd403A0A36a72b74a105019542B2fb41e2AB8f2D1',
    '0xd324F11BF7386376bA173B57E7D5322a0a2D30D7',
    '0xaf7030023CF86611FfC5a71798a0f7022210F2b3',
    '0x2905E7273b9A7Acc923C8eA0bd65ACE962d8E39a',
    '0xAF7e0FB6ef4Aba17EBa4088242b8731858a29540',
    '0x8A4897174e219FeD129DCd925f2219f498305A2B',
    '0xF2FCB9898b5F6863e3a53A78d36c1B1bF67bE706',
    '0x1bC518EA75a0eEfC8f307E7197A75DDE46824646']

    deductPOL()
    .catch((error) => {
        console.error(error);
    });
    return
    
    listPOL(addrs)
    .catch((error) => {
        console.error(error);
    });

