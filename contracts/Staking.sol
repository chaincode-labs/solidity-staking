/*
 * @Author: chaincode-labs dev@chaincode-labs.org
 * @Date: 2022-06-14 16:40:29
 * @LastEditors: chaincode-labs dev@chaincode-labs.org
 * @LastEditTime: 2022-06-17 17:19:05
 * @FilePath: /staking-contract/contracts/Staking.sol
 * @Description: 质押合约
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./MyToken.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "hardhat/console.sol";

contract Staking is Initializable , PausableUpgradeable, AccessControlUpgradeable {
    using SafeERC20Upgradeable for MyToken;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint public rewardTime;

    MyToken private token;
    
    enum PoolStatus {None, Run, Stop}
    struct Pool {
        // 质押的数量
        uint256 staked;
        // 已解压数量
        uint256 unstaked;
        // 年利率
        uint16 apy;
        // 质押期限
        uint period;
        // 已发放奖励数
        uint256 reward;
        
        PoolStatus status;
    }

    uint256[] private poolIds;
    mapping(uint256 => Pool) public pools;

    struct Account {
        // 可提现额度
        uint256 balance;
        // 质押中
        uint256 staked;
        // 已解押
        uint256 unstaked;
        // 获得的总奖励
        uint256 reward;

        bool isExist;
    }
    address[] private owners;
    mapping(address => Account)  public accounts;
    enum OrderStatus{ None, Staked, UnStaked }

    struct Order {
        address owner;
        uint256 poolId;
        uint256 amount;
        // 已提取奖励
        uint256 reward;
        // 下单时间
        uint date;
        OrderStatus status;
    }
    uint256[] private orderIds;
    mapping (uint256 => Order) public orders;

    event CreatedPool(uint256 id, uint period, uint16 apy);
    event StopPool(uint256 id);
    event Stake(address owner, uint256 poolId, uint256 orderId, uint256 amount);
    event UnStake(address owner, uint256 poolId, uint256 orderId, uint256 amount);
    event Withdraw(address owner, uint256 amount, uint256 beforeBalance, uint256 afterBalance);
    event Recharge(address owner, uint256 amount, uint256 beforeBalance, uint256 afterBalance);
    event Claim(uint orderId, address owner, uint256 totalReward, uint256 currentPaidReward);
    
    /*
     * @description: 初始化
     * @param {address} _token
     * @return {*}
     */    
    function initialize(address _token) public initializer {
        require(_token != address(0), "");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        token = MyToken(_token);
        console.log( _token );
        console.log(msg.sender);
    }
    /*
     * @description: 创建质押池
     * @param {uint256} id
     * @param {uint} period
     * @param {uint16} apy
     * @return {*}
     */
    function createPool(uint256 id, uint period, uint16 apy) public onlyRole(DEFAULT_ADMIN_ROLE) {
        //  判断id是否存在
        Pool memory pool = pools[id];
        require(pool.status == PoolStatus.None, "Pool id has exist");
        pools[id] = Pool({staked: 0, unstaked: 0, apy: apy, period: period, reward: 0, status: PoolStatus.Run});
        poolIds.push(id);

        emit CreatedPool(id, period, apy);
    }

    /*
     * @description: 废弃质押池
     * @param {uint} id
     * @return {*}
     */
    function stopPool(uint id) public onlyRole(DEFAULT_ADMIN_ROLE) {
        Pool storage pool = pools[id];
        require(pool.status == PoolStatus.Run, "Pool id has stop");
        // 解除质押
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order memory order = orders[orderIds[i]];
            if (order.poolId == id) {
                _unstake(orderIds[i]);
            }
        }
        pool.status = PoolStatus.Stop;
        emit StopPool(id);
    }
    /*
     * @description: 质押
     * @param {uint256} poolId
     * @param {uint256} orderId
     * @param {uint256} amount
     * @return {*}
     */
    function stake(uint256 poolId, uint256 orderId, uint256 amount) public whenNotPaused {
        _stake(msg.sender, poolId, orderId, amount);
    }

    /*
     * @description: 质押
     * @param {address} owner
     * @param {uint256} poolId
     * @param {uint256} orderId
     * @param {uint256} amount
     * @return {*}
     */    
    function _stake(address owner, uint256 poolId, uint256 orderId, uint256 amount) internal {
        Pool storage pool = pools[poolId];
        require(pool.status == PoolStatus.Run, "Pool has stop, or not exist");
        require(orders[orderId].status == OrderStatus.None, "Order id is exist");
        require( amount > 0, "Cannot stake 0");
        
        Account storage account = accounts[owner];
        require(account.isExist, "Account not exist");
        require(account.balance >= amount, "Lack of balance");

        account.balance -= amount;
        account.staked += amount;

        orders[orderId] = Order({owner: owner, poolId: poolId, amount: amount, reward: 0, date: block.timestamp, status: OrderStatus.Staked});

        pool.staked += amount;
        orderIds.push(orderId);

        emit Stake(owner, poolId, orderId, amount);
    }

    /*
     * @description: 解押
     * @param {uint256} orderId
     * @return {*}
     */
    function unstake(uint256 orderId) public {
        Order storage order = orders[orderId];
        require(order.owner == msg.sender, "Must be owner");
        _unstake(orderId);
    }

    /*
     * @description: 解押
     * @param {uint256} orderId
     * @return {*}
     */
    function _unstake(uint256 orderId) internal {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Staked, "Order is not exist, or unstaked");
        Pool storage pool = pools[order.poolId];

        require(order.date + pool.period < block.timestamp, "Order can't be unstake");

        Account storage account = accounts[msg.sender];
        require(account.isExist, "Account not exist");
        _claimAnyOrder(orderId);

        account.balance += order.amount;
        account.unstaked += order.amount;

        pool.staked -= order.amount;
        pool.unstaked += order.amount;        
        order.status = OrderStatus.UnStaked;

        emit UnStake(order.owner, order.poolId, orderId, order.amount);
    }
    /*
     * @description: 重新质押
     * @param {uint256} orderId
     * @param {uint256} toPoolId
     * @return {*}
     */
    function restake(uint256 orderId, uint256 toPoolId) public whenNotPaused {
        Order memory order = orders[orderId];
        require(order.owner == msg.sender, "Must be owner");
        require(order.poolId != toPoolId, "Must different pool");

        uint256 amount =  order.amount;
        // 先unstake
        _unstake(orderId);
        // 再stake
        _stake(msg.sender, toPoolId, orderId, amount);
    }

    /*
     * @description: 提现
     * @param {uint256} amount
     * @return {*}
     */    
    function withdraw(uint256 amount) public {
        require( amount > 0, "Cannot withdraw 0");
        Account storage account = accounts[msg.sender];

        require(account.isExist, "Account not exist");
        require(account.balance >= amount, "Lack of balance");
        uint256 beforeBalance = account.balance;
        account.balance -= amount;

        token.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, beforeBalance, account.balance);
    }

    /*
     * @description: 充值
     * @param {uint256} amount
     * @return {*}
     */    
    function recharge(uint256 amount) public {
        require( amount > 0, "Cannot rechage 0");
        Account storage account = accounts[msg.sender];
        uint256 beforeBalance = 0;
        if (account.isExist) {
            beforeBalance = account.balance;
            account.balance += amount;
        } else {
            accounts[msg.sender] = Account({balance: amount, staked: 0, unstaked: 0, reward: 0, isExist: true});
            owners.push(msg.sender);
        }
        token.transferFrom(msg.sender, address(this), amount);

        emit Recharge(msg.sender, amount, beforeBalance, account.balance);
    }


    /*
     * @description: 管理员主动为所有用户提取所有奖励
     * @param {public} onlyRole
     * @return {*}
     */    
    function claimall() public onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            _claimAnyOrder(orderIds[i]);
        }
    }
 
    // 
    /*
     * @description: 用户获取单个订单收益
     * @param {uint256} orderId
     * @return {*}
     */    
    function claimAnyOrder(uint256 orderId) public {
        Order storage order = orders[orderId];
        require(order.owner == msg.sender, "Must be owner");

        _claimAnyOrder(orderId);
    }

    /*
     * @description: 提取单个订单奖励
     * @param {Order storage} order
     * @return {*}
     */
    function _claimAnyOrder(uint256 orderId) internal {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Staked, "Order is not exist, or unstaked");        
        uint256 noPaidReward = calculateNoPaidReward(orderId);
        if (noPaidReward <= 0 ) {
            return;
        }

        token.mint(order.owner, noPaidReward);
        Account storage account = accounts[order.owner];
        account.reward += noPaidReward;
        account.balance += noPaidReward;

        order.reward += noPaidReward;

        Pool storage pool = pools[order.poolId];
        pool.reward += noPaidReward;

        emit Claim(orderId, order.owner, order.reward, noPaidReward);
    }

    /*
     * @description: 用户提取所有奖励
     * @param {public} onlyRole
     * @return {*}
     */    
    function claim() public {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order memory order = orders[orderIds[i]];
            if (order.owner == msg.sender) {
                _claimAnyOrder(orderIds[i]);
            }
        }
    }
    /*
     * @description: 设置奖励提取时间
     * @param {uint} time
     * @return {*}
     */
    function setRewardTime(uint time) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(time <= block.timestamp, "Must be less than last current timestamp");
        require(time > rewardTime, "Must be greater than last reward time");
        rewardTime = time;
    }

    /*
     * @description: 计算单个订单未领取的奖励
     * @param {uint256} orderId
     * @return {*}
     */    
    function calculateNoPaidReward(uint256 orderId) public view returns (uint256 noPaidReward) {
        Order storage order = orders[orderId];
        Pool storage pool = pools[order.poolId];
        if (rewardTime <= order.date) {
            return 0;
        }
        uint delta = rewardTime - order.date;
        if (delta > pool.period) {
            delta = pool.period;
        }

        uint256 reward = order.amount * pool.apy * delta / ((1 days * 365) * 100);
        noPaidReward = reward - order.reward;
    }

    /*
     * @description: 将质押金额和账号余额转入用户账户，不发放奖励
     * @param {public} onlyRole
     * @return {*}
     */    
    function urgency() public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint tempRewardTime = rewardTime;
        rewardTime = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            _unstake(orderIds[i]);
        }

        for (uint256 i = 0; i < owners.length; i++) {
            Account storage account = accounts[owners[i]];
            token.safeTransfer(owners[i], account.balance);
            account.balance = 0;
        }

        rewardTime = tempRewardTime;
    }

    /*
     * @description: ⽤户当前可领取奖励
     * @param {address} owner
     * @return {*}
     */    
    function getOwnerNoPaidReward(address owner) public view  returns (uint256 noPaidReward) {
        for (uint256 i = 0; i < orderIds.length; i++) {
           if (orders[orderIds[i]].owner == owner) {
               noPaidReward += calculateNoPaidReward(orderIds[i]);
           }
        }
    }

    /*
     * @description: 所有⽤户的可领取奖励
     * @param {public view } returns
     * @return {*}
     */    
    function getAllOwnerNoPaidReward() public view  returns (uint256 noPaidReward) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            noPaidReward += calculateNoPaidReward(orderIds[i]);
        }
    }
    /*
     * @description: 暂停
     * @param {public} onlyRole
     * @return {*}
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /*
     * @description: 取消暂停
     * @param {public} onlyRole
     * @return {*}
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

}