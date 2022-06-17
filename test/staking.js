/*
 * @Author: chaincode-labs dev@chaincode-labs.org
 * @Date: 2022-06-16 16:11:24
 * @LastEditors: chaincode-labs dev@chaincode-labs.org
 * @LastEditTime: 2022-06-17 17:25:59
 * @FilePath: /staking-contract/test/staking.js
 * @Description: staking unit test.
 */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

const PoolStatus = {
    None: 0, Run: 1, Stop: 2
}
const OrderStatus = {
    None: 0, Staked: 1, UnStaked: 2
};

const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero;
const PAUSER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PAUSER_ROLE"));
const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));

let myToken;
let admin;
let staking;
let staker1;
let staker2;

describe("Staking", function () {
    beforeEach(async function () {
        const signers = await ethers.getSigners();
        admin = signers[0];
        staker1 = signers[1];
        staker2 = signers[2];

        console.log("admin: ", admin.address);
        console.log("staker1: ", staker1.address);
        console.log("staker2: ", staker2.address);

        const MyToken = ethers.getContractFactory("MyToken");
        myToken = await (await MyToken).deploy();
        console.log("MKT deployed to address: ", myToken.address);
        await myToken.initialize({ gasLimit: 25000000 })

        const Staking = await ethers.getContractFactory("Staking");
        //staking = await upgrades.deployProxy(Staking, [myToken.address], {gasLimit:25000000});
        staking = await (await Staking).deploy();


        console.log("Staking deployed to: ", staking.address);
        await staking.initialize(myToken.address, { gasLimit: 25000000 });

        myToken.grantRole(MINTER_ROLE, staking.address);

        myToken.mint(staker1.address, 100000);
        myToken.mint(staker2.address, 100000);
        myToken.connect(staker1).approve(staking.address, 100000);
        myToken.connect(staker2).approve(staking.address, 100000);

    });

    it("initialize", async function () {
        expect(await myToken.name()).to.equal("MyToken");
        expect(await myToken.symbol()).to.equal("MTK");
        expect(await myToken.hasRole(MINTER_ROLE, staking.address)).to.equal(true);
        expect(await myToken.hasRole(MINTER_ROLE, admin.address)).to.equal(true);
        expect(await myToken.hasRole(PAUSER_ROLE, admin.address)).to.equal(true);
        expect(await staking.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.equal(true);
        expect(await staking.hasRole(PAUSER_ROLE, admin.address)).to.equal(true);
    });

    it("createPool", async function () {
        await expect(staking.createPool(1, 3600 * 24 * 30, 60, { gasLimit: 25000000 }))
            .to.be.emit(staking, "CreatedPool")
            .withArgs(1, 3600 * 24 * 30, 60);
        const pool = await staking.pools(1);
        expect(pool.status).to.equal(PoolStatus.Run);

        await expect(staking.createPool(1, 3600 * 24 * 30, 20, { gasLimit: 25000000 })).to.be.revertedWith("Pool id has exist");
    });

    it("stopPool", async function () {

        await expect(staking.createPool(1, 3600 * 24 * 30, 60, { gasLimit: 25000000 }))
            .to.be.emit(staking, "CreatedPool")
            .withArgs(1, 3600 * 24 * 30, 60);

        await expect(staking.stopPool(1))
            .to.be.emit(staking, "StopPool")
            .withArgs(1);
        const pool = await staking.pools(1);
        expect(pool.status).to.equal(PoolStatus.Stop);
    });

    it("recharge", async function () {

        //emit Recharge(msg.sender, amount, beforeBalance, account.balance);

        await expect(staking.connect(staker1).recharge(50000))
            .to.be.emit(staking, "Recharge")
            .withArgs(staker1.address, 50000, 0, 50000);

        await expect(staking.connect(staker1).recharge(50000))
            .to.be.emit(staking, "Recharge")
            .withArgs(staker1.address, 50000, 50000, 100000);

        expect(await myToken.balanceOf(staking.address))
            .to.be.equal(100000);

        expect(await myToken.balanceOf(staker1.address))
            .to.be.equal(0);
    });
    it("withdraw", async function () {

        await expect(staking.connect(staker1).recharge(50000))
            .to.be.emit(staking, "Recharge")
            .withArgs(staker1.address, 50000, 0, 50000);

        await expect(staking.connect(staker1).recharge(50000))
            .to.be.emit(staking, "Recharge")
            .withArgs(staker1.address, 50000, 50000, 100000);

        expect(await myToken.balanceOf(staking.address))
            .to.be.equal(100000);

        expect(await myToken.balanceOf(staker1.address))
            .to.be.equal(0);
        //emit Withdraw(msg.sender, amount, beforeBalance, account.balance);

        await expect(staking.connect(staker1).withdraw(50000))
            .to.be.emit(staking, "Withdraw")
            .withArgs(staker1.address, 50000, 100000, 50000);

        expect(await myToken.balanceOf(staking.address))
            .to.be.equal(50000);

        expect(await myToken.balanceOf(staker1.address))
            .to.be.equal(50000);

        await expect(staking.connect(staker1).withdraw(50000))
            .to.be.emit(staking, "Withdraw")
            .withArgs(staker1.address, 50000, 50000, 0);

        expect(await myToken.balanceOf(staking.address))
            .to.be.equal(0);

        expect(await myToken.balanceOf(staker1.address))
            .to.be.equal(100000);
    });

    describe("stake unstake", () => {
        beforeEach(async function () {
            await staking.createPool(1, 3600 * 24 * 30, 60, { gasLimit: 25000000 });
            await staking.createPool(2, 3600 * 24 * 60, 40, { gasLimit: 25000000 });
            await staking.connect(staker1).recharge(80000);
        });

        it("stake unstake", async function () {
            //_stake(address owner, uint256 poolId, uint256 orderId, uint256 amount)
            //emit Stake(owner, poolId, orderId, amount);
            //emit UnStake(order.owner, order.poolId, orderId, order.amount);
            //emit Claim(orderId, order.owner, order.reward, noPaidReward);

            await expect(staking.connect(staker1).stake(1, 1, 50000))
                .to.be.emit(staking, "Stake")
                .withArgs(staker1.address, 1, 1, 50000);

            await expect(staking.connect(staker1).unstake(1)).to.be.revertedWith("Order can't be unstake");
            const timestamp = (await ethers.provider.getBlock()).timestamp;

            await ethers.provider.send("evm_mine", [timestamp + 3600 * 24 * 10 + 10]);
            await staking.setRewardTime(timestamp + 3600 * 24 * 10);
            console.log(await staking.rewardTime());
            const order = await staking.orders(1);
            console.log(await staking.rewardTime(), order.date);

            await expect(staking.connect(staker1).claim())
                .to.be.emit(staking, "Claim")
                .withArgs(1, staker1.address, 821, 821);

            let account = await staking.accounts(staker1.address);
            console.log(account);
            expect(account.reward).to.be.equal(821);

            await ethers.provider.send("evm_mine", [timestamp + 3600 * 24 * 30 + 1]);

            await staking.setRewardTime(timestamp + 3600 * 24 * 30 + 1);

            console.log(await staking.orders(1));
            await expect(staking.connect(staker1).unstake(1))
                .to.be.emit(staking, "UnStake")
                .withArgs(staker1.address, 1, 1, 50000);
            account = await staking.accounts(staker1.address);
            console.log(account);
            expect(account.reward).to.be.equal(2465);

        });
    });


});
