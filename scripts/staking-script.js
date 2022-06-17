const {ethers, upgrades} = require("hardhat");

async function main() {
    const Staking = await ethers.getContractFactory("Staking");
    const staking = await upgrades.deployProxy(Staking, [100]);
    await staking.deployed();

    console.log("Staking deployed to: ", staking.address);
}

main();