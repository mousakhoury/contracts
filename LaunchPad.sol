// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IStake {
    function getInvestorsDatas(
        address _user,
        uint256 _snapNb
    ) external view returns (uint256 tiersNb, uint256 amountStaked);

    function snapShotPool()
        external
        returns (
            uint256[6] memory tiersStaked,
            uint256 snapShotNb
        );
}

contract LaunchPad is Ownable {
    IERC20 public immutable STABLE;
    IStake public immutable STAKINGCONTRACT;
    uint256 public immutable PRECISION = 100_000_000;

    uint256[] public tiersAllocs = [0, 10, 15, 15, 20, 40];
    uint256 public firstRoundDuration = 3600;

    uint256 public maxFcfsAmount = 500 * 1E18;

    uint256 public currentPoolId;

    struct PoolData {
        uint256 amountTarget;
        uint256 amountRaised;
        uint256[6] allocByTokenForTiers;
        uint256 startingDate;
        uint256 snapShotNb;
        bool isFinished;
        bool fundWithdrawn;
        string poolName;
    }

    mapping(uint256 => PoolData) private _poolDatas;
    mapping(address => mapping(uint256 => uint256)) private _userAllocRound1;
    mapping(address => mapping(uint256 => uint256)) private _userAllocFcfs;
    mapping(address => mapping(uint256 => uint256)) private _userInvest;


    event PoolCreated(
        string indexed poolName,
        uint256 indexed poolId,
        uint256 amountTarget,
        uint256 startingDate
    );
    event PoolFinished(
        string indexed poolName,
        uint256 amountTarget,
        uint256 amountRaised
    );
    event UserInvest(address investor, uint256 indexed poolId, uint256 amount);
    event TiersAllocSet(uint256[6] allocsPercentage);
    event RoundDurationUpdated(uint256 roundDuration);
    event MaxFcfsAmountUpdated(uint256 maxFcfsAmount);

    constructor(IERC20 _stable, IStake _stakingContract) {
        STABLE = _stable;
        STAKINGCONTRACT = _stakingContract;
    }

    function setTiersAllocs(uint256[6] calldata _allocs) external onlyOwner {
        require(_allocs[0] == 0, "_allocs[0] is used for no tiers and must be 0");
        require(_allocs[1] + _allocs[2]+ _allocs[3]+ _allocs[4]+ _allocs[5] == 100, "Maths not good");
        emit TiersAllocSet(_allocs);
        tiersAllocs = _allocs;
    }

    function setRoundDuration(uint256 _firstRoundDuration) external onlyOwner {
        firstRoundDuration = _firstRoundDuration;
        emit RoundDurationUpdated(_firstRoundDuration);
    }

    function setMaxFcfsAmount(uint256 _maxFcfsAmount) external onlyOwner {
        maxFcfsAmount = _maxFcfsAmount;
        emit MaxFcfsAmountUpdated(_maxFcfsAmount);
    }

    function closePool(uint256 _poolId) external onlyOwner {
        PoolData storage p = _poolDatas[_poolId];
        require(p.startingDate != 0, "Pool doesn't exist");
        p.isFinished = true;
        emit PoolFinished(p.poolName, p.amountTarget, p.amountRaised);
    }

    function getPoolDatas(uint256 _poolId) external view returns(PoolData memory){
        return _poolDatas[_poolId];
    }

    function getUserInvestForPool(
        address _user,
        uint256 _pool
    ) external view returns (uint256) {
        return _userInvest[_user][_pool];
    }

    function createPool(
        string memory _poolName,
        uint256 _amountTarget,
        uint256 _startingDate
    ) external onlyOwner {
        require(_startingDate > block.timestamp, "Can't retro create pool");
        require(_amountTarget > 1 * 1E18, "Decimals error");
        currentPoolId++;
        _poolDatas[currentPoolId].amountTarget = _amountTarget;
        _poolDatas[currentPoolId].startingDate = _startingDate;
        _poolDatas[currentPoolId].poolName = _poolName;
        emit PoolCreated(_poolName, currentPoolId, _amountTarget, _startingDate);
    }

    function snapShotPool(
        uint256 _poolId
    ) external onlyOwner {
        PoolData storage pool = _poolDatas[_poolId];
        require(pool.snapShotNb == 0, "Only 1 snapshot by pool");

        (
            uint256[6] memory tiersStaked,
            uint256 snapShotNb
        ) = STAKINGCONTRACT.snapShotPool();


        pool.snapShotNb = snapShotNb;

        uint256 allocForPool = _poolDatas[_poolId].amountTarget * PRECISION;


        pool.allocByTokenForTiers[1] = tiersStaked[1] != 0 ? ((allocForPool*tiersAllocs[1]/100) / tiersStaked[1]) : 0; 
        pool.allocByTokenForTiers[2] = tiersStaked[2] != 0 ? ((allocForPool*tiersAllocs[2]/100) / tiersStaked[2]) : 0;
        pool.allocByTokenForTiers[3] = tiersStaked[3] != 0 ? ((allocForPool*tiersAllocs[3]/100) / tiersStaked[3]) : 0; 
        pool.allocByTokenForTiers[4] = tiersStaked[4] != 0 ? ((allocForPool*tiersAllocs[4]/100) / tiersStaked[4]) : 0; 
        pool.allocByTokenForTiers[5] = tiersStaked[5] != 0 ? ((allocForPool*tiersAllocs[5]/100) / tiersStaked[5]) : 0; 


    }

    function getUserAllocForPool(address _user, uint256 _poolId) external view returns(uint256){
        PoolData memory p = _poolDatas[_poolId];
        return _getUserAllocForPool(_user,p,_poolId);
    }

    function _getUserAllocForPool(address _user, PoolData memory p, uint256 _poolId) internal view returns(uint256){
        // calculate user's allocation for pool
        uint256 _allocCalculated = _calculateUserAlloc(_user,p);

        if(_allocCalculated == 0){
            // user is not whitelisted for this pool, 
            return 0;
        }else {
            if(block.timestamp >= p.startingDate + firstRoundDuration){
                // We are in round 2 FCFS
                if(_userInvest[_user][_poolId] != 0){
                    return _userAllocFcfs[_user][_poolId];
                }else {
                    return maxFcfsAmount;
                }
            }else{
                // We are on round 1 or pool didn't began
                if(_userInvest[_user][_poolId] != 0){
                    return _userAllocRound1[_user][_poolId];
                }else {
                    return _allocCalculated;
                }

            }
        }
    }

    function _calculateUserAlloc(address _user, PoolData memory p) internal view returns(uint256 alloc){
        if(p.snapShotNb == 0){
            alloc = 0;
        }else{
            (uint256 tiersNb, uint256 amountStaked) = STAKINGCONTRACT.getInvestorsDatas(_user,p.snapShotNb);
            alloc = amountStaked * p.allocByTokenForTiers[tiersNb] / PRECISION;
        }

    }

    function investInPool(uint256 _poolId, uint256 _amount) external {
        require(_amount != 0, "Amount can't be Zero");
        PoolData memory p = _poolDatas[_poolId];
        uint256 _now = block.timestamp;
        // check if pool has began
        require(_now >= p.startingDate, "Pool isn't opened");
        // check if pool is finished
        require(!p.isFinished, "Pool already finished");
        address _sender = _msgSender();

        // calculate allocation
        uint256 _userAlloc = _getUserAllocForPool(_sender,p,_poolId);
        // check if alloc is > 0 and if amount <= to alloc
        require(_userAlloc != 0, "You are not WL for this pool or you already used your Alloc");
        require(_userAlloc >= _amount, "You don't have enough allocation for this amount");
        // check if pool target reached
        require(p.amountRaised + _amount <= p.amountTarget, "too much, reduce the amount");

        if(_now >= p.startingDate + firstRoundDuration){
            // this is FCFS round
            if(_userInvest[_sender][_poolId] == 0){
                // set alloc
                _userAllocFcfs[_sender][_poolId] = _userAlloc;
            }
            // decrease amount to alloc
            _userAllocFcfs[_sender][_poolId] -= _amount;
        }else{
            if(_userInvest[_sender][_poolId] == 0){
                // set alloc for Round 1 and FCFS
                _userAllocRound1[_sender][_poolId] = _userAlloc;
                _userAllocFcfs[_sender][_poolId] = maxFcfsAmount;

            }
            // decrease amount to alloc
            _userAllocRound1[_sender][_poolId] -= _amount;
        }

        // increase user investment in the pool
        _userInvest[_sender][_poolId] += _amount;
        //increase amount raised in the pool
        _poolDatas[_poolId].amountRaised += _amount;

        if(p.amountRaised + _amount == p.amountTarget){
            // if amount target is reached close the pool 
            _poolDatas[_poolId].isFinished = true;
            emit PoolFinished(p.poolName, p.amountTarget, p.amountRaised);
        }
        emit UserInvest(_sender,_poolId, _amount);
        require(STABLE.transferFrom(_sender, address(this), _amount),"Transfer failed");

    }

    function withdrawPoolFund(uint256 _poolId) external onlyOwner {
        PoolData storage p = _poolDatas[_poolId];
        require(!p.fundWithdrawn, "funds already withdrawn");
        require(p.isFinished, "pool isn't finished yet");
        p.fundWithdrawn = true;

        STABLE.transfer(
            _msgSender(),
            p.amountRaised
        );
    }

    function emergencyWithdraw(IERC20 _token, uint256 _amount) external onlyOwner {
        require(_token != STABLE, "Stable can only be withdrawn by calling withdrawPoolFund()");
        _token.transfer(
            _msgSender(),
            _amount != 0 ? _amount : _token.balanceOf(address(this))
        );
    }
}