// test/upgradeFactorySmoke.test.js
// -----------------------------------------------------------------------------
// Smoke test for verifying UUPS upgrade on an existing FundFactory proxy without
// creating new PlantingFund instances. Suitable for execution on a testnet.

const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("FundFactory UUPS Upgrade Smoke Test", function () {
  it("should import, inspect, and verify proxy implementation and state", async function () {
    // 1. Read proxy address and expected implementation from environment
    const proxyAddress = process.env.FUND_FACTORY_PROXY_ADDRESS;
    if (!proxyAddress) throw new Error("FUND_FACTORY_PROXY_ADDRESS not set in env");

    // 2. Load the contract factory for the on-chain proxy
    const Factory = await ethers.getContractFactory("FundFactoryUpgradeable");

    // 3. Import existing UUPS proxy into Hardhat upgrades plugin registry
    await upgrades.forceImport(proxyAddress, Factory, { kind: "uups" });

    // 4. Query on-chain implementation slot
    const implOnChain = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`Implementation address at proxy ${proxyAddress}: ${implOnChain}`);

    // 5. Optionally assert it matches an expected value from env
    const expectedImpl = process.env.FUND_FACTORY_EXPECT_IMPL;
    if (expectedImpl) {
      expect(implOnChain).to.equal(expectedImpl,
        "On-chain implementation does not match expected");
    }

    // 6. Attach to the proxy and call view functions
    const factory = Factory.attach(proxyAddress);

    // 6a. Check owner() remains intact
    const owner = await factory.owner();
    console.log(`Factory owner: ${owner}`);
    expect(owner).to.be.a.properAddress;

    // 6b. Inspect the registered PlantingFund implementation address
    const plantingImpl = await factory.plantingFundImpl();
    console.log(`plantingFundImpl: ${plantingImpl}`);
    expect(plantingImpl).to.be.a.properAddress;

    // 6c. (Optional) fetch existing funds for a known union
    const unionAddr = process.env.UNION_ADDRESS;
    if (unionAddr) {
      const funds = await factory.getFundsByOwner(unionAddr);
      console.log(`Funds registered for union ${unionAddr}:`, funds.map(f => f.fund));
      expect(Array.isArray(funds)).to.be.true;
    }
  });
});
