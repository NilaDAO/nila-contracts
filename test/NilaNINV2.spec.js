/* eslint-disable no-console */
/**
 * CS004 — NilaNINV2 + burnFarmerNin
 * Tests for:
 *  - NilaNINV2: UUPS proxy deploy, mint, burn, ERC-20, EIP-2612 permit, UUPS upgrade
 *  - GenericFundCore: setNin
 *  - NilaFxPool: setNin, burnFarmerNin
 */
const { expect } = require("chai");
const { ethers, network, upgrades } = require("hardhat");
const {
  parseEther, keccak256, toUtf8Bytes, MaxUint256, ZeroAddress,
} = require("ethers");

async function now() {
  return (await ethers.provider.getBlock("latest")).timestamp;
}
async function timeTravel(seconds) {
  await network.provider.send("evm_increaseTime", [Number(seconds)]);
  await network.provider.send("evm_mine");
}

// Sign EIP-2612 permit off-chain
async function signPermit({ signer, token, spender, value, nonce, deadline, chainId }) {
  const domain = {
    name: "Nila INR Note",
    version: "1",
    chainId,
    verifyingContract: await token.getAddress(),
  };
  const types = {
    Permit: [
      { name: "owner",    type: "address" },
      { name: "spender",  type: "address" },
      { name: "value",    type: "uint256" },
      { name: "nonce",    type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };
  const values = { owner: await signer.getAddress(), spender, value, nonce, deadline };
  const sig = await signer.signTypedData(domain, types, values);
  return ethers.Signature.from(sig);
}


describe("CS004 — NilaNINV2 + burnFarmerNin", function () {
  let owner, minter, burner, farmer, unionSigner, rando;
  let ninV2, chainId;

  const MINTER_ROLE = keccak256(toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE  = keccak256(toUtf8Bytes("BURNER_ROLE"));
  const UNION_ROLE   = keccak256(toUtf8Bytes("UNION_ROLE"));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

  before(async () => {
    [owner, minter, burner, farmer, unionSigner, rando] = await ethers.getSigners();
    chainId = (await ethers.provider.getNetwork()).chainId;
  });

  // ─────────────────────────────────────────────────────────────
  // 1. NilaNINV2 — UUPS proxy deployment
  // ─────────────────────────────────────────────────────────────

  describe("1. UUPS proxy deployment", function () {
    before(async () => {
      const NinV2F = await ethers.getContractFactory("NilaNINV2");
      ninV2 = await upgrades.deployProxy(NinV2F, [await owner.getAddress()], { kind: "uups" });
      await ninV2.waitForDeployment();
    });

    it("1a: name and symbol", async () => {
      expect(await ninV2.name()).to.equal("Nila INR Note");
      expect(await ninV2.symbol()).to.equal("nIN");
    });

    it("1b: deployer holds DEFAULT_ADMIN_ROLE", async () => {
      expect(await ninV2.hasRole(DEFAULT_ADMIN_ROLE, await owner.getAddress())).to.be.true;
    });

    it("1c: initial supply is zero", async () => {
      expect(await ninV2.totalSupply()).to.equal(0n);
    });

    it("1d: cannot initialize again", async () => {
      await expect(ninV2.initialize(await owner.getAddress())).to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 2. mint / burn access control
  // ─────────────────────────────────────────────────────────────

  describe("2. mint / burn access control", function () {
    const AMOUNT = parseEther("1000");

    before(async () => {
      await ninV2.connect(owner).grantRole(MINTER_ROLE, await minter.getAddress());
      await ninV2.connect(owner).grantRole(BURNER_ROLE, await burner.getAddress());
    });

    it("2a: MINTER_ROLE can mint", async () => {
      await expect(ninV2.connect(minter).mint(await farmer.getAddress(), AMOUNT))
        .to.emit(ninV2, "Transfer")
        .withArgs(ZeroAddress, await farmer.getAddress(), AMOUNT);
      expect(await ninV2.balanceOf(await farmer.getAddress())).to.equal(AMOUNT);
    });

    it("2b: non-minter cannot mint", async () => {
      await expect(ninV2.connect(rando).mint(await rando.getAddress(), AMOUNT))
        .to.be.reverted;
    });

    it("2c: BURNER_ROLE can burn", async () => {
      const bal = await ninV2.balanceOf(await farmer.getAddress());
      await expect(ninV2.connect(burner).burn(await farmer.getAddress(), AMOUNT))
        .to.emit(ninV2, "Transfer")
        .withArgs(await farmer.getAddress(), ZeroAddress, AMOUNT);
      expect(await ninV2.balanceOf(await farmer.getAddress())).to.equal(bal - AMOUNT);
    });

    it("2d: non-burner cannot burn", async () => {
      await ninV2.connect(minter).mint(await farmer.getAddress(), AMOUNT);
      await expect(ninV2.connect(rando).burn(await farmer.getAddress(), AMOUNT))
        .to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 3. Standard ERC-20 behaviour
  // ─────────────────────────────────────────────────────────────

  describe("3. ERC-20 standard", function () {
    const AMOUNT = parseEther("500");

    before(async () => {
      // Ensure farmer has a balance
      await ninV2.connect(minter).mint(await farmer.getAddress(), AMOUNT * 2n);
    });

    it("3a: transfer", async () => {
      const before = await ninV2.balanceOf(await rando.getAddress());
      await ninV2.connect(farmer).transfer(await rando.getAddress(), AMOUNT);
      expect(await ninV2.balanceOf(await rando.getAddress())).to.equal(before + AMOUNT);
    });

    it("3b: approve + transferFrom", async () => {
      await ninV2.connect(rando).approve(await owner.getAddress(), AMOUNT);
      expect(await ninV2.allowance(await rando.getAddress(), await owner.getAddress())).to.equal(AMOUNT);
      await ninV2.connect(owner).transferFrom(await rando.getAddress(), await owner.getAddress(), AMOUNT);
      expect(await ninV2.allowance(await rando.getAddress(), await owner.getAddress())).to.equal(0n);
    });

    it("3c: transfer reverts with insufficient balance", async () => {
      await expect(ninV2.connect(rando).transfer(await owner.getAddress(), parseEther("999999")))
        .to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 4. EIP-2612 permit
  // ─────────────────────────────────────────────────────────────

  describe("4. EIP-2612 permit", function () {
    const AMOUNT = parseEther("100");

    it("4a: valid permit sets allowance and increments nonce", async () => {
      const spender = await owner.getAddress();
      const ownerAddr = await farmer.getAddress();
      const nonce = await ninV2.nonces(ownerAddr);
      const deadline = MaxUint256;

      const sig = await signPermit({ signer: farmer, token: ninV2, spender, value: AMOUNT, nonce, deadline, chainId });

      await expect(ninV2.permit(ownerAddr, spender, AMOUNT, deadline, sig.v, sig.r, sig.s))
        .to.emit(ninV2, "Approval")
        .withArgs(ownerAddr, spender, AMOUNT);

      expect(await ninV2.allowance(ownerAddr, spender)).to.equal(AMOUNT);
      expect(await ninV2.nonces(ownerAddr)).to.equal(nonce + 1n);
    });

    it("4b: expired deadline reverts", async () => {
      const spender = await owner.getAddress();
      const ownerAddr = await farmer.getAddress();
      const nonce = await ninV2.nonces(ownerAddr);
      const deadline = BigInt(await now()) - 1n; // already expired

      const sig = await signPermit({ signer: farmer, token: ninV2, spender, value: AMOUNT, nonce, deadline, chainId });

      await expect(ninV2.permit(ownerAddr, spender, AMOUNT, deadline, sig.v, sig.r, sig.s))
        .to.be.reverted;
    });

    it("4c: wrong signer reverts", async () => {
      const spender = await owner.getAddress();
      const ownerAddr = await farmer.getAddress();
      const nonce = await ninV2.nonces(ownerAddr);
      const deadline = MaxUint256;

      // rando signs for farmer's address — mismatch
      const sig = await signPermit({ signer: rando, token: ninV2, spender, value: AMOUNT, nonce, deadline, chainId });

      await expect(ninV2.permit(ownerAddr, spender, AMOUNT, deadline, sig.v, sig.r, sig.s))
        .to.be.reverted;
    });

    it("4d: permit followed by transferFrom works", async () => {
      const spender = await owner.getAddress();
      const ownerAddr = await farmer.getAddress();
      const nonce = await ninV2.nonces(ownerAddr);
      const deadline = MaxUint256;

      const sig = await signPermit({ signer: farmer, token: ninV2, spender, value: AMOUNT, nonce, deadline, chainId });
      await ninV2.permit(ownerAddr, spender, AMOUNT, deadline, sig.v, sig.r, sig.s);

      const balBefore = await ninV2.balanceOf(await owner.getAddress());
      await ninV2.connect(owner).transferFrom(ownerAddr, await owner.getAddress(), AMOUNT);
      expect(await ninV2.balanceOf(await owner.getAddress())).to.equal(balBefore + AMOUNT);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 5. UUPS upgrade
  // ─────────────────────────────────────────────────────────────

  describe("5. UUPS upgrade", function () {
    it("5a: upgrade to mock V3 preserves storage", async () => {
      const proxyAddr = await ninV2.getAddress();
      const supplyBefore = await ninV2.totalSupply();

      // Deploy a minimal mock V3 with an extra function
      const MockV3F = await ethers.getContractFactory("MockNilaNINV3");
      const upgraded = await upgrades.upgradeProxy(proxyAddr, MockV3F);
      await upgraded.waitForDeployment();

      expect(await upgraded.totalSupply()).to.equal(supplyBefore);
      expect(await upgraded.name()).to.equal("Nila INR Note");
      // Extra function from V3
      expect(await upgraded.version()).to.equal("V3");
    });

    it("5b: non-admin cannot upgrade", async () => {
      const MockV3F = await ethers.getContractFactory("MockNilaNINV3");
      const newImpl = await MockV3F.deploy();
      await newImpl.waitForDeployment();

      const proxyWithRando = await ethers.getContractAt("NilaNINV2", await ninV2.getAddress(), rando);
      await expect(proxyWithRando.upgradeToAndCall(await newImpl.getAddress(), "0x"))
        .to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 6. setNin on GenericFundCore
  // ─────────────────────────────────────────────────────────────

  describe("6. GenericFundCore.setNin", function () {
    let core, viewer, roles, land721, mathLib;
    const ORACLE_ANSWER = 1_200_000n;

    before(async () => {
      // Deploy supporting contracts
      const AggF = await ethers.getContractFactory("MockAggregator");
      const mockOracle = await AggF.deploy(8, ORACLE_ANSWER);
      await mockOracle.waitForDeployment();

      const ERC721F = await ethers.getContractFactory("contracts/mocks/MockERC721.sol:MockERC721");
      land721 = await ERC721F.deploy(await owner.getAddress());
      await land721.waitForDeployment();

      const MathLibF = await ethers.getContractFactory("GenericFundMathLib");
      mathLib = await MathLibF.deploy();
      await mathLib.waitForDeployment();

      const RolesF = await ethers.getContractFactory("RolesRegistry");
      roles = await RolesF.deploy(await owner.getAddress());
      await roles.waitForDeployment();

      const CoreF = await ethers.getContractFactory("GenericFundCore", {
        libraries: { GenericFundMathLib: await mathLib.getAddress() },
      });
      core = await CoreF.deploy();
      await core.waitForDeployment();

      const ViewerF = await ethers.getContractFactory("GenericFundViewer", {
        libraries: { GenericFundMathLib: await mathLib.getAddress() },
      });
      viewer = await ViewerF.deploy();
      await viewer.waitForDeployment();

      // Deploy original NilaNIN to initialize core with
      const NinF = await ethers.getContractFactory("NilaNIN");
      const ninOld = await NinF.deploy("Nila INR Note", "nIN", await owner.getAddress());
      await ninOld.waitForDeployment();

      await core.initialize(await land721.getAddress(), await roles.getAddress(), await ninOld.getAddress());
      await viewer.initialize(await core.getAddress(), await roles.getAddress());
      await core.setViewer(await viewer.getAddress());
      await roles.setCore(await core.getAddress(), true);
    });

    it("6a: owner can setNin to NilaNINV2 proxy", async () => {
      const NinV2F = await ethers.getContractFactory("NilaNINV2");
      const ninV2New = await upgrades.deployProxy(NinV2F, [await owner.getAddress()], { kind: "uups" });
      await ninV2New.waitForDeployment();

      await expect(core.connect(owner).setNin(await ninV2New.getAddress()))
        .to.not.be.reverted;
      expect(await core.nin()).to.equal(await ninV2New.getAddress());
    });

    it("6b: setNin reverts for zero address", async () => {
      await expect(core.connect(owner).setNin(ZeroAddress)).to.be.reverted;
    });

    it("6c: non-owner cannot setNin", async () => {
      await expect(core.connect(rando).setNin(await owner.getAddress())).to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 7. setNin on NilaFxPool
  // ─────────────────────────────────────────────────────────────

  describe("7. NilaFxPool.setNin", function () {
    let fxPool, erc20;
    const ORACLE_ANSWER = 1_200_000n;

    before(async () => {
      const AggF = await ethers.getContractFactory("MockAggregator");
      const mockOracle = await AggF.deploy(8, ORACLE_ANSWER);
      await mockOracle.waitForDeployment();

      const ERC20F = await ethers.getContractFactory("MockERC20");
      erc20 = await ERC20F.deploy("MockUSDT", "mUSDT", 6);
      await erc20.waitForDeployment();

      const NinF = await ethers.getContractFactory("NilaNIN");
      const ninOld = await NinF.deploy("Nila INR Note", "nIN", await owner.getAddress());
      await ninOld.waitForDeployment();

      const FxF = await ethers.getContractFactory("NilaFxPool");
      fxPool = await upgrades.deployProxy(FxF, [
        await erc20.getAddress(),
        await ninOld.getAddress(),
        await mockOracle.getAddress(),
        200,
        parseEther("999999"),
        3600 * 24 * 7,
        90 * 24 * 3600,
        await owner.getAddress(),
      ], { kind: "uups", initializer: "initialize" });
      await fxPool.waitForDeployment();
    });

    it("7a: ONLY_OWNER can setNin", async () => {
      const NinV2F = await ethers.getContractFactory("NilaNINV2");
      const ninV2New = await upgrades.deployProxy(NinV2F, [await owner.getAddress()], { kind: "uups" });
      await ninV2New.waitForDeployment();

      await expect(fxPool.connect(owner).setNin(await ninV2New.getAddress()))
        .to.not.be.reverted;
      expect(await fxPool.nin()).to.equal(await ninV2New.getAddress());
    });

    it("7b: setNin reverts for zero address", async () => {
      await expect(fxPool.connect(owner).setNin(ZeroAddress)).to.be.reverted;
    });

    it("7c: non-owner cannot setNin", async () => {
      await expect(fxPool.connect(rando).setNin(await owner.getAddress())).to.be.reverted;
    });
  });

  // ─────────────────────────────────────────────────────────────
  // 8. burnFarmerNin full flow
  // ─────────────────────────────────────────────────────────────

  describe("8. burnFarmerNin", function () {
    let fxPool, ninV2Local, erc20;
    const ORACLE_ANSWER = 1_200_000n;
    const AMOUNT = parseEther("1000");

    before(async () => {
      // Deploy NilaNINV2 proxy
      const NinV2F = await ethers.getContractFactory("NilaNINV2");
      ninV2Local = await upgrades.deployProxy(NinV2F, [await owner.getAddress()], { kind: "uups" });
      await ninV2Local.waitForDeployment();

      const AggF = await ethers.getContractFactory("MockAggregator");
      const mockOracle = await AggF.deploy(8, ORACLE_ANSWER);
      await mockOracle.waitForDeployment();

      const ERC20F = await ethers.getContractFactory("MockERC20");
      erc20 = await ERC20F.deploy("MockUSDT", "mUSDT", 6);
      await erc20.waitForDeployment();

      // Deploy NilaFxPool pointing to NilaNINV2
      const FxF = await ethers.getContractFactory("NilaFxPool");
      fxPool = await upgrades.deployProxy(FxF, [
        await erc20.getAddress(),
        await ninV2Local.getAddress(),
        await mockOracle.getAddress(),
        200,
        parseEther("999999"),
        3600 * 24 * 7,
        90 * 24 * 3600,
        await owner.getAddress(),
      ], { kind: "uups", initializer: "initialize" });
      await fxPool.waitForDeployment();

      // Grant FxPool MINTER + BURNER roles on NilaNINV2
      await ninV2Local.connect(owner).grantRole(MINTER_ROLE, await fxPool.getAddress());
      await ninV2Local.connect(owner).grantRole(BURNER_ROLE, await fxPool.getAddress());

      // Grant UNION_ROLE to unionSigner on FxPool
      await fxPool.connect(owner).grantRole(UNION_ROLE, await unionSigner.getAddress());

      // Grant owner MINTER_ROLE so we can seed nIN directly to farmer
      await ninV2Local.connect(owner).grantRole(MINTER_ROLE, await owner.getAddress());
    });

    it("8a: farmer has nIN (simulating loan disbursement)", async () => {
      await ninV2Local.connect(owner).mint(await farmer.getAddress(), AMOUNT);
      expect(await ninV2Local.balanceOf(await farmer.getAddress())).to.be.gte(AMOUNT);
    });

    it("8b: farmer signs permit for FxPool", async () => {
      const farmerAddr = await farmer.getAddress();
      const spenderAddr = await fxPool.getAddress();
      const nonce = await ninV2Local.nonces(farmerAddr);
      const sig = await signPermit({
        signer: farmer, token: ninV2Local,
        spender: spenderAddr, value: AMOUNT,
        nonce, deadline: MaxUint256, chainId,
      });
      await ninV2Local.permit(farmerAddr, spenderAddr, AMOUNT, MaxUint256, sig.v, sig.r, sig.s);
      expect(await ninV2Local.allowance(farmerAddr, spenderAddr)).to.be.gte(AMOUNT);
    });

    it("8c: union calls burnFarmerNin — balance decreases, supply decreases, event emitted", async () => {
      const farmerAddr = await farmer.getAddress();
      const supplyBefore = await ninV2Local.totalSupply();
      const balBefore = await ninV2Local.balanceOf(farmerAddr);

      await expect(fxPool.connect(unionSigner).burnFarmerNin(farmerAddr, AMOUNT))
        .to.emit(fxPool, "FarmerNinBurned")
        .withArgs(await unionSigner.getAddress(), farmerAddr, AMOUNT);

      expect(await ninV2Local.balanceOf(farmerAddr)).to.equal(balBefore - AMOUNT);
      expect(await ninV2Local.totalSupply()).to.equal(supplyBefore - AMOUNT);
    });

    it("8d: non-UNION_ROLE caller reverts", async () => {
      await expect(fxPool.connect(rando).burnFarmerNin(await farmer.getAddress(), AMOUNT))
        .to.be.reverted;
    });

    it("8e: zero farmer address reverts", async () => {
      await expect(fxPool.connect(unionSigner).burnFarmerNin(ZeroAddress, AMOUNT))
        .to.be.revertedWith("zero address");
    });

    it("8f: zero amount reverts", async () => {
      await expect(fxPool.connect(unionSigner).burnFarmerNin(await farmer.getAddress(), 0))
        .to.be.revertedWith("zero amount");
    });

    it("8g: no allowance (no permit) reverts with ERC20InsufficientAllowance", async () => {
      // Mint nIN to rando but do NOT set allowance
      await ninV2Local.connect(owner).mint(await rando.getAddress(), AMOUNT);
      await expect(fxPool.connect(unionSigner).burnFarmerNin(await rando.getAddress(), AMOUNT))
        .to.be.reverted;
    });
  });
});
