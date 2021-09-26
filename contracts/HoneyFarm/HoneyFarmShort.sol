// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IStrategy {
    function wantLockedTotal() external view returns (uint256);
    function earn() external;
    function deposit(uint256 _wantAmt)
        external
        returns (uint256);
    function withdraw(uint256 _wantAmt)
        external
        returns (uint256);
    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external;
}

interface IEarningsReferral {
    function recordReferral(address _user, address _referrer) external;
    function recordReferralCommission(address _referrer, uint256 _commission) external;
    function getReferrer(address _user) external view returns (address);
    function updateOperator(address _operator, bool _status) external;
    function drainERC20Token(IERC20 _token, uint256 _amount, address _to) external;
}

contract HoneyToken is ERC20 {
    uint16 public transferTaxRate = 300;
    uint16 public constant MAXIMUM_TRANSFER_TAX_RATE = 1000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address private _operator;
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event TransferTaxRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    constructor() public ERC20("Honey token", "HONEY") {
        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);
    }

    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        if (recipient == BURN_ADDRESS || transferTaxRate == 0) {
            super._transfer(sender, recipient, amount);
        } else {
            uint256 taxAmount = amount.mul(transferTaxRate).div(10000);
            uint256 sendAmount = amount.sub(taxAmount);
            require(amount == sendAmount + taxAmount, "HONEY::transfer: Tax value invalid");
            super._transfer(sender, BURN_ADDRESS, taxAmount);
            super._transfer(sender, recipient, sendAmount);
            amount = sendAmount;
        }
    }
    
    function updateTransferTaxRate(uint16 _transferTaxRate) public onlyOperator {
        require(_transferTaxRate <= MAXIMUM_TRANSFER_TAX_RATE, "HONEY::updateTransferTaxRate: Transfer tax rate must not exceed the maximum rate.");
        emit TransferTaxRateUpdated(msg.sender, transferTaxRate, _transferTaxRate);
        transferTaxRate = _transferTaxRate;
    }

    function operator() public view returns (address) {
        return _operator;
    }

    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0), "HONEY::transferOperator: new operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }
}

contract YetiMaster is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    struct UserInfo {
        uint256 amount; // How many amount tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lastDepositBlock; // Block number of the last deposit.
    }
    struct PoolInfo {
        IERC20 want; // Address of the want token.
        uint256 allocPoint; // How many allocation points assigned to this pool. Earnings to distribute per block.
        uint256 lastRewardBlock; // Last block number that earnings distribution occurs.
        uint256 accEarningsPerShare; // Accumulated earnings per share, times 1e12. See below.
        address strat; // Strategy address that will earnings compound want tokens
        uint16 depositFeeBP;      // Deposit fee in basis points
        bool isWithdrawFee;      // if the pool has withdraw fee
    }
    address public constant earningToken = 0xE8c93310af068aa50bd7bF0ebFa459Df2a02ceba;
    address public devaddr;
    address public constant burnAddress = 0x000000000000000000000000000000000000dEaD;
    address public feeAddr;
    uint256 public constant EarningsPerBlock = 0.05 ether;
    uint256 public constant EarningsDevPerBlock =  0.005 ether;
    uint256 public startBlock;
    uint256 public endBlock;
    IEarningsReferral public earningReferral;
    uint16 public referralCommissionRate = 300;
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 2000;
    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256[] public withdrawalFeeIntervals = [1];
    uint16[] public withdrawalFeeBP = [0, 0];
    uint16 public constant MAX_WITHDRAWAL_FEE_BP = 300;
    uint16 public constant MAX_DEPOSIT_FEE_BP = 400;
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
        address _feeAddr,
        uint256 _startBlock,
        uint256 _endBlock
    ) public {
        devaddr = _devaddr;
        feeAddr = _feeAddr;
        startBlock = _startBlock;
        endBlock = _endBlock;
    }

    modifier poolExists(uint256 pid) {
        require(pid < poolInfo.length, "pool inexistent");
        _;
    }

    function add(
        uint256 _allocPoint,
        IERC20 _want,
        bool _withUpdate,
        address _strat,
        uint16 _depositFeeBP,
        bool _isWithdrawFee
    ) public onlyOwner {
        require(_depositFeeBP <= MAX_DEPOSIT_FEE_BP, "add: invalid deposit fee basis points");
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
                accEarningsPerShare: 0,
                strat: _strat,
                depositFeeBP : _depositFeeBP,
                isWithdrawFee: _isWithdrawFee
            })
        );
    }

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint16 _depositFeeBP,
        bool _isWithdrawFee
    ) public onlyOwner poolExists(_pid) {
        require(_depositFeeBP <= MAX_DEPOSIT_FEE_BP, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].isWithdrawFee = _isWithdrawFee;
    }

    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_from > _to)
            return 0;
        return _to.sub(_from);
    }

    function pendingEarnings(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accEarningsPerShare = pool.accEarningsPerShare;
        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        uint256 blockNumber = endBlock < block.number ? endBlock : block.number;
        if (blockNumber > pool.lastRewardBlock && wantLockedTotal != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, blockNumber);
            uint256 earningsReward =
                multiplier.mul(EarningsPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accEarningsPerShare = accEarningsPerShare.add(
                earningsReward.mul(1e12).div(wantLockedTotal)
            );
        }
        return user.amount.mul(accEarningsPerShare).div(1e12).sub(user.rewardDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 blockNumber = endBlock < block.number ? endBlock : block.number;
        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        if (wantLockedTotal == 0) {
            pool.lastRewardBlock = blockNumber;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, blockNumber);
        if (multiplier <= 0) {
            return;
        }
        uint256 earningsReward =  multiplier.mul(EarningsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        HoneyToken(earningToken).mint(
            devaddr,
            multiplier.mul(EarningsDevPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            )
        );
        HoneyToken(earningToken).mint(
            address(this),
            earningsReward
        );
        pool.accEarningsPerShare = pool.accEarningsPerShare.add(
            earningsReward.mul(1e12).div(wantLockedTotal)
        );
        pool.lastRewardBlock = blockNumber;
    }

    function deposit(uint256 _pid,uint256 _wantAmt, address _referrer) public nonReentrant poolExists(_pid){
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (_wantAmt > 0 && address(earningReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            earningReferral.recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accEarningsPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            if (pending > 0) {
                safeEarningsTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            uint256 wantBalBefore = IERC20(pool.want).balanceOf(address(this));
            pool.want.safeTransferFrom(address(msg.sender), address(this), _wantAmt);
            uint256 wantBalAfter = IERC20(pool.want).balanceOf(address(this));
            _wantAmt = wantBalAfter.sub(wantBalBefore);
            uint256 amount = _wantAmt;
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _wantAmt.mul(pool.depositFeeBP).div(10000);
                pool.want.safeTransfer(feeAddr, depositFee);
                amount = (_wantAmt).sub(depositFee);
            }
            pool.want.safeIncreaseAllowance(pool.strat, amount);
            uint256 amountDeposit =
                IStrategy(poolInfo[_pid].strat).deposit(amount);
            user.amount = user.amount.add(amountDeposit);
            user.lastDepositBlock = block.number;
        }
        user.rewardDebt = user.amount.mul(pool.accEarningsPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant poolExists(_pid){
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 total = IStrategy(pool.strat).wantLockedTotal();
        require(user.amount > 0, "user.amount is 0");
        require(total > 0, "Total is 0");
        uint256 pending =
            user.amount.mul(pool.accEarningsPerShare).div(1e12).sub(
                user.rewardDebt
            );
        if (pending > 0) {
            safeEarningsTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        uint256 amount = user.amount;
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 amountRemove = IStrategy(pool.strat).withdraw(_wantAmt);
            if (amountRemove > user.amount) {
                user.amount = 0;
            } else {
                user.amount = user.amount.sub(amountRemove);
            }
            uint256 wantBal = IERC20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            if (pool.isWithdrawFee) {
                uint16 withdrawFeeBP = getWithdrawFee(_pid, msg.sender);
                if (withdrawFeeBP > 0) {
                    uint256 withdrawFee = _wantAmt.mul(withdrawFeeBP).div(10000);
                    pool.want.safeTransfer(feeAddr, withdrawFee);
                    _wantAmt = (_wantAmt).sub(withdrawFee);
                }
            }
            pool.want.safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.amount.mul(pool.accEarningsPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }
    
    function emergencyWithdraw(uint256 _pid) public nonReentrant poolExists(_pid){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        amount = IStrategy(pool.strat).withdraw(amount);
        if (pool.isWithdrawFee) {
            uint16 withdrawFeeBP = getWithdrawFee(_pid, msg.sender);
            if (withdrawFeeBP > 0) {
                uint256 withdrawFee = amount.mul(withdrawFeeBP).div(10000);
                pool.want.safeTransfer(feeAddr, withdrawFee);
                amount = (amount).sub(withdrawFee);
            }
        }
        user.amount = 0;
        user.rewardDebt = 0;
        pool.want.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function safeEarningsTransfer(address _to, uint256 _EarningsAmt) internal {
        uint256 EarningsBal = IERC20(earningToken).balanceOf(address(this));
        if (_EarningsAmt > EarningsBal) {
            IERC20(earningToken).transfer(_to, EarningsBal);
        } else {
            IERC20(earningToken).transfer(_to, _EarningsAmt);
        }
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyOwner
    {
        require(_token != earningToken, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function setDevAddress(address _devaddr) public onlyOwner {
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setFeeAddress(address _feeAddress) public onlyOwner {
        feeAddr = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }
    
    function setEarningsReferral(IEarningsReferral _earningReferral) public onlyOwner {
        earningReferral = _earningReferral;
    }

    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(earningReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = earningReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                HoneyToken(earningToken).mint(referrer, commissionAmount);
                earningReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
    
    function transferEarningTokenOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        Ownable(earningToken).transferOwnership(newOwner);
    }
    
    function getWithdrawFee(uint256 _pid, address _user) public view returns (uint16) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        if (!pool.isWithdrawFee)
            return 0;
        uint256 blockElapsed = block.number - user.lastDepositBlock;
        uint i = 0;
        for (; i < withdrawalFeeIntervals.length; i++) {
            if (blockElapsed < withdrawalFeeIntervals[i])
                break;
        }
        return withdrawalFeeBP[i];
    }
    
    function setWithdrawFee(uint256[] memory _withdrawalFeeIntervals, uint16[] memory _withdrawalFeeBP) public onlyOwner {
        require (_withdrawalFeeIntervals.length + 1 == _withdrawalFeeBP.length, 'setWithdrawFee: _withdrawalFeeBP length is one more than _withdrawalFeeIntervals length');
        require (_withdrawalFeeBP.length > 0, 'setWithdrawFee: _withdrawalFeeBP length is one more than 0');
        for (uint i = 0; i < _withdrawalFeeIntervals.length - 1; i++) {
            require (_withdrawalFeeIntervals[i] < _withdrawalFeeIntervals[i + 1], 'setWithdrawFee: The interval must be ascending');
        }
        for (uint i = 0; i < _withdrawalFeeBP.length; i++) {
            require (_withdrawalFeeBP[i] <= MAX_WITHDRAWAL_FEE_BP, 'setWithdrawFee: invalid withdrawal fee basis points');
        }
        withdrawalFeeIntervals = _withdrawalFeeIntervals;
        withdrawalFeeBP = _withdrawalFeeBP;
    }
}
