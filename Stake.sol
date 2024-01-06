// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Stake is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _stakers;
    mapping(address => bool) private _isStaker;

    IERC20 public immutable TOKEN;
    address public launchPadContract;
    uint256 public immutable lockPeriod;

    uint256 public constant TIERS1AMOUNT = 10_000_000 * 1E18; 
    uint256 public constant TIERS2AMOUNT = 50_000_000 * 1E18;
    uint256 public constant TIERS3AMOUNT = 200_000_000 * 1E18;
    uint256 public constant TIERS4AMOUNT = 1_000_000_000 * 1E18;
    uint256 public constant TIERS5AMOUNT = 10_000_000_000 * 1E18;

    uint256 private _snapShotNumber;

    uint256[6] private _tiersStaked;

    struct UserData {
        uint256 staked;
        uint256 unlockDate;
        uint256 tiers;
    }

    mapping(address => uint256[]) private _userSnapshots;
    mapping(address => mapping(uint256 => UserData)) private _userDatas;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event LaunchpadSet(address launchpadAddress);

    constructor(IERC20 _token, uint256 _lockPeriod) {
        TOKEN = _token;
        lockPeriod = _lockPeriod;
    }

    function setLaunchpadContract(address _launchPad) external onlyOwner {
        launchPadContract = _launchPad;
        emit LaunchpadSet(_launchPad);
    }

    function getStakerNumber() external view returns(uint256){
        return _stakers.length();
    }

    function getStakerAtIndex(uint256 index) external view returns(address){
        return _stakers.at(index);
    }

    function getTiersStaked() external view returns(uint256[6] memory){
        return _tiersStaked;
    }

    function getUserData(
        address _user
    ) external view returns (UserData memory) {
        uint256[] memory _snaps = _userSnapshots[_user];
        if(_snaps.length == 0){
            return UserData(0,0,0);
        }else{
            return _getUserData(_user, _snaps[_snaps.length-1]);
        }
    }

    function canUserUnstake(address _user) external view returns(bool){
        uint256[] memory _snaps = _userSnapshots[_user];
        if(_snaps.length != 0){
            return block.timestamp >= _userDatas[_user][_snaps[_snaps.length-1]].unlockDate;
        }else {
            return false;
        }
    }

    function getInvestorsDatas(
        address _user,
        uint256 _snapNb
    ) external view returns (uint256 tiersNb, uint256 amountStaked) {
        UserData memory u;
        uint256[] memory _snaps = _userSnapshots[_user];
        
        if(_snaps.length == 0){
            return (0,0);
        }else if (_snapNb >= _snaps[_snaps.length-1]) {
            u = _userDatas[_user][_snaps[_snaps.length-1]];
            tiersNb = u.tiers;
            amountStaked = u.staked;
        } else {
            if(_snaps.length >= 2){
            for(uint256 i = _snaps.length - 2; i > 0  ; ){
                    if(_snapNb >= _snaps[i]){
                        u = _userDatas[_user][_snaps[i]];
                        tiersNb = u.tiers;
                        amountStaked = u.staked;
                        break;
                    }
                    unchecked {
                        -- i;
                    }
                }
            }else{
                return (0,0);
            }
        }
    }

    function _getUserData(
        address _user,
        uint256 _snapNb
    ) internal view returns (UserData memory) {
        return _userDatas[_user][_snapNb];
    }

    function getUserStakedAmount(
        address _user
    ) external view returns (uint256) {
        return _userDatas[_user][_userSnapshots[_user][_userSnapshots[_user].length-1]].staked;
    }

    function snapShotPool()
        external
        returns (
            uint256[6] memory tiersStaked,
            uint256 snapShotNb
        )
    {
        require(msg.sender == launchPadContract, "Not auth to snapshot");
        ++_snapShotNumber;

        snapShotNb = _snapShotNumber;
        tiersStaked = _tiersStaked;

    }

    function stake(uint256 _amount) external {
        address _sender = _msgSender();
        require(TOKEN.transferFrom(_sender, address(this), _amount),"Transfer failed");
        uint256 _userReadyForSnapshot = _snapShotNumber + 1;

        uint256 _oldTiers;
        uint256 _newTiers;

        if (!_isStaker[_sender]) {
            require(_amount >= TIERS1AMOUNT, "Minimum first stake not reached");
            _userSnapshots[_sender].push(_userReadyForSnapshot);
            _isStaker[_sender] = true;
            _stakers.add(_sender);
            _userDatas[_sender][_userReadyForSnapshot].staked = _amount;

            _newTiers = _getTiers(_amount);
            _userDatas[_sender][_userReadyForSnapshot].tiers = _newTiers;

            _tiersStaked[_newTiers] += _amount;


        } else {
            uint256[] memory _snaps = _userSnapshots[_sender];

            if(_snaps[_snaps.length - 1] != _userReadyForSnapshot){
                _userSnapshots[_sender].push(_userReadyForSnapshot);
            }

            UserData memory u = _userDatas[_sender][_snaps[_snaps.length - 1]];
            uint256 _newStakingAmount = _amount + u.staked;
            _userDatas[_sender][_userReadyForSnapshot].staked = _newStakingAmount;

            _oldTiers = u.tiers;
            _newTiers = _getTiers(_newStakingAmount);

            if (_oldTiers != _newTiers) {
                _userDatas[_sender][_userReadyForSnapshot].tiers = _newTiers;

                _tiersStaked[_oldTiers] -= u.staked;
                _tiersStaked[_newTiers] += _newStakingAmount;
            }else{
                _tiersStaked[_oldTiers] += _amount;
            }
        }

        _userDatas[_sender][_userReadyForSnapshot].unlockDate =
            uint256(block.timestamp) +
            lockPeriod;

        emit Staked(_sender, _amount);
    }

    function unStake(uint256 _amount) external  {
        address _sender = _msgSender();
        uint256[] memory _snaps = _userSnapshots[_sender];
        require(_isStaker[_sender], "You are not a staker");

        uint256 _lastSnapShotForUser = _snaps[_snaps.length - 1];
        UserData storage u = _userDatas[_sender][_lastSnapShotForUser];

        require(block.timestamp >= u.unlockDate, "To soon for unstake");
        require(u.staked >= _amount, "Can't unstake so much");
        u.staked -= _amount;
        uint256 _oldTiers = u.tiers;
        _tiersStaked[_oldTiers] -= _amount;

        if (u.staked == 0) {
            _isStaker[_sender] = false;
            _stakers.remove(_sender);
            _userSnapshots[_sender] = new uint256[](0);

        } else {
            uint256 _newTiers = _getTiers(u.staked);
            require(_newTiers != 0, "Can't stake less than Tiers1Amount");

            if (_oldTiers != _newTiers) {
                u.tiers = _newTiers;
                _tiersStaked[_newTiers] += u.staked;
                _tiersStaked[_oldTiers] -= u.staked;
            }
        }

        emit Unstaked(_sender, _amount);
        require(TOKEN.transfer(_sender, _amount),"Transfer error");
    }

    function _getTiers(uint256 _amount) internal pure returns (uint256) {
        if (_amount >= TIERS5AMOUNT) {
            return 5;
        }else if (_amount >= TIERS4AMOUNT) {
            return 4;
        }else if (_amount >= TIERS3AMOUNT) {
            return 3;
        } else if (_amount >= TIERS2AMOUNT) {
            return 2;
        } else if (_amount >= TIERS1AMOUNT) {
            return 1;
        } else {
            return 0;
        }
    }

}
