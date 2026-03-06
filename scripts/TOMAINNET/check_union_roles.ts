const { ethers } = require("hardhat");
const FXPOOL = "0xBaE307FE0A453955c649cD8f81e3DA572dF448eA";

async function main() {
  const fx = await ethers.getContractAt("NilaFxPool", FXPOOL);
  const UNION_ROLE = await fx.UNION_ROLE();
  console.log(`UNION_ROLE: ${UNION_ROLE}`);

  const count = await fx.getRoleMemberCount(UNION_ROLE);
  console.log(`Members   : ${count}`);

  for (let i = 0n; i < count; i++) {
    const member = await fx.getRoleMember(UNION_ROLE, i);
    console.log(`  [${i}] ${member}`);
  }

  if (count === 0n) {
    console.log(`  (no union has been granted UNION_ROLE yet)`);
  }
}
main().catch(console.error);
