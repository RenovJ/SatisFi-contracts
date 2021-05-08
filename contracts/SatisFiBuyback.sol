// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./openzeppelin_math_SafeMath.sol";
import "./IBEP20.sol";
import "./SafeBEP20.sol";
import "./openzeppelin_access_Ownable.sol";
import "./openzeppelin_utils_ReentrancyGuard.sol";

contract SatisfiBuyback is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    
    // applyList[epoch][index]
    address[][] public applyList;
    // [address][epoch]
    mapping(address => mapping(uint16 => uint256)) public userApplyAmount;
    mapping(address => uint256) public userBuybackedAmount;
    
    IBEP20 buybackToken;  // BUSD
    IBEP20 sellToken;     // Gokgweingi
    
    uint256 public buybackPrice;
    uint256 public epochBuybackAmount;
    uint16 public currentEpoch = 0;
    uint256 public nextEpochTimestamp;
    uint256 public totalBuybackAmountProvided = 0;
    uint256 public totalBuybackAmountToProvide = 0;
    uint256 public applyFeeAmount = 0;
    
    // 6 hr = 21600 sec = 7200 blocks
    uint16 public constant EPOCH_PERIOD_IN_SEC = 21600;
    uint16 public constant LOCKUP_EPOCH_PERIOD = 2;
    // bonus is in sellToken
    uint256 public constant FIRST_LUCK_BONUS = 1000000000000000000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    // Minimum buyback amount for every epoch $1000
    // uint256 public constant MIN_BUYBACK_AMOUNT = 1000000000000000000000;
    uint256 public constant MIN_BUYBACK_AMOUNT = 10000000000000000000; // $10 for TEST
    // Minimum buyback price is 50 BUSD for 1 SAT
    uint256 public constant MIN_BUYBACK_PRICE = 50;
    uint256 public constant MIN_TOKEN_BALANCE_TO_COUNT = 100000000000000; // 0.0001
    
    event Apply(address indexed user, uint256 amount, bool isReapply);
    event TokenToSellWithdraw(address indexed user, uint256 amount);
    event BuybackWithdraw(address indexed user, uint256 amount);
    // amount is in buybackToken
    event Buyback(address indexed user, uint256 amount);
    // newAmount is in buybackToken
    event BuybackAmountAdded(uint256 newAmount);
    // newPrice is the amount of buybackToken for one sellToken
    event BuybackPriceUpdated(uint256 newPrice);
    // newAmount is in buybackToken
    event BuybackAmountForEachEpochUpdated(uint256 newAmount);

    constructor(
        IBEP20 _buybackToken,
        IBEP20 _sellToken,
        uint256 _startTimestamp,
        uint256 _buybackPrice,
        uint256 _epochBuybackAmount,
        uint256 _applyFeeAmount
    ) public {
        buybackToken = _buybackToken;
        sellToken = _sellToken;
        nextEpochTimestamp = _startTimestamp;
        buybackPrice = _buybackPrice;
        epochBuybackAmount = _epochBuybackAmount;
        applyFeeAmount = _applyFeeAmount;
        
        address[] memory emptyAddressListForNewEpoch;
        applyList.push( emptyAddressListForNewEpoch );
    }

    function addBuybackAmount(uint256 _amount) public {
        require(_amount > 0, "addBuybackAmount: The amount to add must be 0");
        
        // transfer buyback token
        buybackToken.transferFrom(address(msg.sender), address(this), _amount);
        
        totalBuybackAmountToProvide = totalBuybackAmountToProvide.add(_amount);
        emit BuybackAmountAdded(_amount);
    }
    
    function setBuybackPriceHigher(uint256 _price) public onlyOwner {
        require(_price > MIN_BUYBACK_PRICE, "setBuybackPriceHigher: The new buyback price must be higher than MIN_BUYBACK_PRICE");
        
        buybackPrice = _price;
        emit BuybackPriceUpdated(_price);
    }
    
    function setBuybackAmountForEachEpochHigher(uint256 _amount) public onlyOwner {
        require(_amount > MIN_BUYBACK_AMOUNT, "setBuybackAmountForEachEpochHigher: The new buyback amount for each epoch must be higher than MIN_BUYBACK_AMOUNT");
        
        epochBuybackAmount = _amount;
        emit BuybackAmountForEachEpochUpdated(_amount);
    }
    
    function applyBuyback(uint256 _amount) public nonReentrant {
        require(_amount > applyFeeAmount, "applyBuyback: _amount must be higher than 'applyFeeAmount'");
        sellToken.transferFrom(address(msg.sender), address(this), _amount.sub(applyFeeAmount));
        sellToken.transferFrom(address(msg.sender), address(BURN_ADDRESS), applyFeeAmount);
        
        _amount = _amount.sub(applyFeeAmount);
        uint256 transferTax = _amount.mul(2).div(100);
        _amount = _amount.sub(transferTax);
        
        if (buyback() && _amount > FIRST_LUCK_BONUS) {
            _amount = _amount.sub(FIRST_LUCK_BONUS);
            userBuybackedAmount[msg.sender] = userBuybackedAmount[msg.sender].add(FIRST_LUCK_BONUS.mul(buybackPrice));
            totalBuybackAmountToProvide = totalBuybackAmountToProvide.sub(FIRST_LUCK_BONUS.mul(buybackPrice));
            totalBuybackAmountProvided = totalBuybackAmountProvided.add(FIRST_LUCK_BONUS.mul(buybackPrice));
        }
        
        applyList[currentEpoch].push(msg.sender);
        userApplyAmount[msg.sender][currentEpoch] = userApplyAmount[msg.sender][currentEpoch].add(_amount);
        emit Apply(msg.sender, _amount, false);
    }
    
    function reapplyBuyback() public nonReentrant {
        uint256 withdrawableBalance = gatherWithdrawableTokenToSell(address(msg.sender));
        require(withdrawableBalance > 0, "reapplyBuyback: no balance is available");
        
        applyList[currentEpoch].push(msg.sender);
        userApplyAmount[msg.sender][currentEpoch] = userApplyAmount[msg.sender][currentEpoch].add(withdrawableBalance);
        emit Apply(msg.sender, withdrawableBalance, true);
    }
    
    function withdrawSellToken() public nonReentrant {
        uint256 withdrawableBalance = gatherWithdrawableTokenToSell(address(msg.sender));
        require(withdrawableBalance > 0, "withdraw: no balance is available");
        sellToken.safeTransfer(address(msg.sender), withdrawableBalance);
        emit TokenToSellWithdraw(address(msg.sender), withdrawableBalance);
    }
    
    function withdrawBuybackToken() public nonReentrant {
        uint256 amount = userBuybackedAmount[msg.sender];
        require(amount > 0, "withdraw: withdrawable balance of buyback token must be higher than 0");
        
        buybackToken.safeTransfer(address(msg.sender), amount);
        emit BuybackWithdraw(msg.sender, amount);
        userBuybackedAmount[msg.sender] = 0;
    }
    
    function totalApplyAmountThisEpoch() external view returns (uint256) {
        uint256 amount = 0;
        for (uint16 idx = 0; idx < applyList[currentEpoch].length; idx++) {
            uint256 applyAmount = userApplyAmount[applyList[currentEpoch][idx]][currentEpoch];
            uint16 idxCount = 0;
            for (; idxCount < idx; idxCount++) {
                if (applyList[currentEpoch][idxCount] == applyList[currentEpoch][idx]) { // duplicated
                    break;
                }
            }
            if (idxCount == idx) {
                amount = amount.add(
                    applyAmount
                );
            }
        }
        return amount;
    }
    
    function gatherWithdrawableTokenToSell(address _target) internal returns (uint256) {
        if (currentEpoch < LOCKUP_EPOCH_PERIOD) {
            return 0;
        }
        uint256 withdrawableBalance = 0;
        uint16 epoch = currentEpoch - LOCKUP_EPOCH_PERIOD;
        for(; epoch >= 0; epoch--) {
            uint256 amount = userApplyAmount[_target][epoch];
            withdrawableBalance = withdrawableBalance.add(amount);
            userApplyAmount[_target][epoch] = 0;
            
            if (epoch == 0) {
                break;
            }
        }
        
        return withdrawableBalance;
    }
    
    function withdrawableTokenToSell(address _target) external view returns (uint256) {
        if (currentEpoch < LOCKUP_EPOCH_PERIOD) {
            return 0;
        }
        
        uint256 withdrawableBalance = 0;
        uint16 epoch = currentEpoch - LOCKUP_EPOCH_PERIOD;
        for(; epoch >= 0; epoch--) {
            uint256 amount = userApplyAmount[_target][epoch];
            withdrawableBalance = withdrawableBalance.add(amount);
            
            if (epoch == 0) {
                break;
            }
        }
        
        return withdrawableBalance;
    }
    
    function waitingAmountTokenToSell(address _target) external view returns (uint256) {
        uint256 waitingAmount = 0;
        uint16 epoch = currentEpoch;
        
        for(; epoch + LOCKUP_EPOCH_PERIOD > currentEpoch; epoch--) {
            uint256 amount = userApplyAmount[_target][epoch];
            waitingAmount = waitingAmount.add(amount);
            
            if (epoch == 0) {
                break;
            }
        }
        
        return waitingAmount;
    }
    
    function buyback() internal returns (bool) {
        // check if new epoch to buyback
        if (now < nextEpochTimestamp) {
            return false;
        }
        
        // buyback
        currentEpoch = currentEpoch + 1;
        nextEpochTimestamp = nextEpochTimestamp.add(EPOCH_PERIOD_IN_SEC);
        address[] memory emptyAddressListForNewEpoch;
        applyList.push( emptyAddressListForNewEpoch );
        
        if (currentEpoch < LOCKUP_EPOCH_PERIOD) {
            return false;
        }
        
        uint16 epoch = currentEpoch - LOCKUP_EPOCH_PERIOD;
        if (applyList[epoch].length > 0 && totalBuybackAmountToProvide > 0) {
            uint indexToBuyback = uint(keccak256(
                abi.encodePacked(blockhash(block.number - 1), msg.sender)
                )) % applyList[epoch].length;
            
            uint256 amountToBuyback = (totalBuybackAmountToProvide < epochBuybackAmount) ?
              totalBuybackAmountToProvide :
              epochBuybackAmount;
            amountToBuyback = amountToBuyback.sub(FIRST_LUCK_BONUS.mul(buybackPrice));
            uint256 buybackBalance = amountToBuyback;
            
            address userAddr;
            uint256 buybackAmount;
            uint256 amountToSell;
            do {
                userAddr = applyList[epoch][indexToBuyback];
                amountToSell = userApplyAmount[userAddr][epoch];
                if (amountToSell < MIN_TOKEN_BALANCE_TO_COUNT) {
                    break;
                }
                
                if (amountToSell.mul(buybackPrice) > buybackBalance) {
                    buybackAmount = buybackBalance;
                    amountToSell = buybackBalance.div(buybackPrice);
                } else {
                    buybackAmount = amountToSell.mul(buybackPrice);
                }
                 
                userApplyAmount[userAddr][epoch] = userApplyAmount[userAddr][epoch].sub(amountToSell);
                buybackBalance = buybackBalance.sub(buybackAmount);
                userBuybackedAmount[userAddr] = userBuybackedAmount[userAddr].add(buybackAmount);
                emit Buyback(userAddr, buybackAmount);
            
                indexToBuyback = (indexToBuyback == applyList[epoch].length - 1) ? 0 : indexToBuyback + 1;
            } while (buybackBalance > 0);
            
            totalBuybackAmountToProvide = totalBuybackAmountToProvide.sub(amountToBuyback.sub(buybackBalance));
            totalBuybackAmountProvided = totalBuybackAmountProvided.add(amountToBuyback.sub(buybackBalance));
            
            return true;
        }
        return false;
    }
}
