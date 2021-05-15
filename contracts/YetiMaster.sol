
// File: @openzeppelin/contracts/token/ERC20/IERC20.sol

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/utils/ReentrancyGuard.sol";
import "./IBEP20.sol";
import "./SafeBEP20.sol";
import "./ISatisfiReferral.sol";
import "./SatisfiToken.sol";

// File: contracts/IStrategy.sol
interface IStrategy {
    // Total want tokens managed by stratfegy
    function wantLockedTotal() external view returns (uint256);

    // Main want token compounding function
    function earn() external;

    // Transfer want tokens yetiFarm -> strategy
    function deposit(uint256 _wantAmt)
        external
        returns (uint256);

    // Transfer want tokens strategy -> yetiFarm
    function withdraw(uint256 _wantAmt)
        external
        returns (uint256);

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external;
}


// File: contracts/YetiMaster.sol

pragma solidity 0.6.12;

contract YetiMaster is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many amount tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.

        // We do some fancy math here. Basically, any point in time, the amount of Satisfi
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (amount * pool.acccPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
        //   1. The pool's `accSatisfiPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    struct PoolInfo {
        IBEP20 want; // Address of the want token.
        uint256 allocPoint; // How many allocation points assigned to this pool. Satisfi to distribute per block.
        uint256 lastRewardBlock; // Last block number that Satisfi distribution occurs.
        uint256 accSatisfiPerShare; // Accumulated Satisfi per share, times 1e12. See below.
        address strat; // Strategy address that will Satisfi compound want tokens
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // Satisfi
    address public oldSatisfiToken = 0xA1928c0D8F83C0bFB7ebE51B412b1FD29A277893;
    // address public newSatisfiToken = 0xD3bb08Ca48AEC4FCe83F70120AD9e1Df81e17AD1;
    address public newSatisfiToken = 0x8fda94079913CB921D065Ed9c004Afb43e1f900e; // test new

     // Dev address.
    address public devaddr;

    address public burnAddress = 0x000000000000000000000000000000000000dEaD;

    address public feeAddr;

    address public wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 public SatisfiPerBlock = 0.1 ether;
    uint256 public SatisfiDevPerBlock =  0.00909 ether;
    uint256 public startBlock;
    uint256 public noFeeBlock; // No fee until Block
    
    // Satisfi referral contract address.
    ISatisfiReferral public satisfiReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 20%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 2000;

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event MigrateToV2(address indexed user,uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    constructor(
        address _devaddr,
        uint256 _startBlock,
        uint256 _noFeeBlock
    ) public {
        devaddr = _devaddr;
        startBlock = _startBlock;
        noFeeBlock = _noFeeBlock;
    }

    modifier poolExists(uint256 pid) {
        require(pid < poolInfo.length, "pool inexistent");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do. (Only if want tokens are stored here.)
    function add(
        uint256 _allocPoint,
        IBEP20 _want,
        bool _withUpdate,
        address _strat,
        uint16 _depositFeeBP
    ) public onlyOwner {
        require(_depositFeeBP <= 200, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                want: _want,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accSatisfiPerShare: 0,
                strat: _strat,
                depositFeeBP : _depositFeeBP
            })
        );
    }

    // Update the given pool's Satisfi allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint16 _depositFeeBP
    ) public onlyOwner poolExists(_pid) {
        require(_depositFeeBP <= 200, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        return _to.sub(_from);
    }

    // View function to see pending Satisfi on frontend.
    function pendingSatisfi(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSatisfiPerShare = pool.accSatisfiPerShare;
        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        if (block.number > pool.lastRewardBlock && wantLockedTotal != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 SatisfiReward =
                multiplier.mul(SatisfiPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accSatisfiPerShare = accSatisfiPerShare.add(
                SatisfiReward.mul(1e12).div(wantLockedTotal)
            );
        }
        return user.amount.mul(accSatisfiPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        if (wantLockedTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }
        uint256 SatisfiReward =  multiplier.mul(SatisfiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        SatisfiToken(newSatisfiToken).mint(
            devaddr,
            multiplier.mul(SatisfiDevPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            )
        );

        SatisfiToken(newSatisfiToken).mint(
            address(this),
            SatisfiReward
        );

        pool.accSatisfiPerShare = pool.accSatisfiPerShare.add(
            SatisfiReward.mul(1e12).div(wantLockedTotal)
        );
        pool.lastRewardBlock = block.number;
    }

    function deposit(uint256 _pid,uint256 _wantAmt, address _referrer) public nonReentrant poolExists(_pid){
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (_wantAmt > 0 && address(satisfiReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            satisfiReferral.recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accSatisfiPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            if (pending > 0) {
                safeSatisfiTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            pool.want.safeTransferFrom(address(msg.sender), address(this), _wantAmt);
            uint256 amount = _wantAmt;
            if (pool.depositFeeBP > 0 && block.number > noFeeBlock) {
                uint256 depositFee = _wantAmt.mul(pool.depositFeeBP).div(10000);
                pool.want.safeTransfer(feeAddr, depositFee);
                amount = (_wantAmt).sub(depositFee);
            }
            pool.want.safeIncreaseAllowance(pool.strat, amount);
            uint256 amountDeposit =
                IStrategy(poolInfo[_pid].strat).deposit(amount);
            user.amount = user.amount.add(amountDeposit);
        }
        user.rewardDebt = user.amount.mul(pool.accSatisfiPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant poolExists(_pid){
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 total = IStrategy(pool.strat).wantLockedTotal();

        require(user.amount > 0, "user.amount is 0");
        require(total > 0, "Total is 0");

        // Withdraw pending Satisfi
        uint256 pending =
            user.amount.mul(pool.accSatisfiPerShare).div(1e12).sub(
                user.rewardDebt
            );

        if (pending > 0) {
            safeSatisfiTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.amount;
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 amountRemove =
                IStrategy(pool.strat).withdraw(_wantAmt);

            if (amountRemove > user.amount) {
                user.amount = 0;
            } else {
                user.amount = user.amount.sub(amountRemove);
            }

            uint256 wantBal = IBEP20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.want.safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.amount.mul(pool.accSatisfiPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant poolExists(_pid){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;

        IStrategy(pool.strat).withdraw(amount);

        user.amount = 0;
        user.rewardDebt = 0;
        pool.want.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe Satisfi transfer function, just in case if rounding error causes pool to not have enough
    function safeSatisfiTransfer(address _to, uint256 _SatisfiAmt) internal {
        uint256 SatisfiBal = IBEP20(newSatisfiToken).balanceOf(address(this));
        if (_SatisfiAmt > SatisfiBal) {
            IBEP20(newSatisfiToken).transfer(_to, SatisfiBal);
        } else {
            IBEP20(newSatisfiToken).transfer(_to, _SatisfiAmt);
        }
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyOwner
    {
        require(_token != newSatisfiToken, "!safe");
        IBEP20(_token).safeTransfer(msg.sender, _amount);
    }

    function setDevAddress(address _devaddr) public onlyOwner {
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setFeeAddress(address _feeAddress) public onlyOwner {
        feeAddr = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }
    
    // Update the satisfi referral contract address by the owner
    function setSatisfiReferral(ISatisfiReferral _satisfiReferral) public onlyOwner {
        satisfiReferral = _satisfiReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(satisfiReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = satisfiReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                SatisfiToken(newSatisfiToken).mint(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
    
    function migrateSatisfiToken(uint256 _SatisfiAmt) public nonReentrant {
        require(_SatisfiAmt > 0, "old Satisfi token amount must be larger than 0");
        IBEP20(oldSatisfiToken).safeTransferFrom(address(msg.sender), burnAddress, _SatisfiAmt);
        uint256 newSatisfiAmt = _SatisfiAmt.mul(10205).div(10000);
        SatisfiToken(newSatisfiToken).mint(
          address(msg.sender),
          newSatisfiAmt
        );
    }
    
    function transferSatisfiTokenOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        Ownable(newSatisfiToken).transferOwnership(newOwner);
    }
    
}
