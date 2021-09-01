/* 
-SPDX-License-Identifier: UNLICENSED 
-This smart contract is unlicensed ie. non-open-source code and is protected by EULA.
-Any attempt to copy, modifiy, or use this code without written consent from PolyHeist is prohibited.
-Please see https://poly-heist.gitbook.io/info/license-agreement/license for more information.
-
*/
pragma solidity 0.8.6;

import "./@openzeppelin/contracts/access/Ownable.sol";
import "./@openzeppelin/contracts/utils/Address.sol";
import "./@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IPolyHeistUserDatabase.sol";

contract PolyHeistMain is Ownable, ReentrancyGuard {
    using Address for address;

    /*--- Smart contract developed by @rd_ev_ ---*/

    /*--- CONTRACT VARIABLES ---*/

    struct DepositInfo {
        uint id;
        uint balance;
        uint referralRewards;
        uint refCharged;
        uint refRewardsWithdrew;
        uint rewardsWithdrew;
    }

    struct RecentDeposit {
        bytes16 name;
        uint64 date;
        uint64 countdownTime;
        uint amount;
    }

    struct PotInfo {
        uint fee;
        uint winnerPot;
    }

    /*--- CONSTANT VARIABLES ---*/

    // Maximum distribution fee that can be set
    uint private immutable maxDistributionFee = 30;
    // Maximum random drop fee that can be set
    uint private immutable maxDropFee = 10;
    // Maximum referral fee that can be set
    uint private immutable maxReferralFee = 5;
    // Maximum dev fee that can be set
    uint private immutable maxDevFee = 10;
    // Maximum referral fees a single user is made to pay - 10 matic
    uint private immutable maxRefCharged = 10 ether;
    // Minimum deposit % that can be made in respect to current total - 0.05%
    uint private immutable minDepPercent = 2000;

    /*--- INITIAL VARIABLES ---*/

    // Interface to interact with userDatabase contract
    IPolyHeistUserDatabase internal userDatabase_;
    // RandDrop contract address
    address public randDropAddress;
    // RandDrop contract cannot be changed after setting address
    bool private hasSetRandDrop;
    // Distribution fee set to 15% for early users
    uint private distributionFee = 15;
    // Referral fee set to 5%
    uint private referralFee = 5;
    // Random drop fee set to 5%
    uint private dropFee = 5;
    // Dev fee set to 5% for early users
    uint private devFee = 5;
    // Total number of deposits
    uint public depositsTotal;
    // Total matic in the pot to be won by the last user deposit
    uint private winnerPotTotal;
    // Total rewards from distribution fees, distributed to all users weighted by their share of the pool
    uint private rewardPotTotal;
    // Total rewards waiting to be won in random drop
    uint public dropBalance;
    // Current winner of pot
    address private lastDeposit;
    // Time pot opened
    uint64 private startingTimestamp = uint64(block.timestamp);
    // Time until manual claim can be made
    uint64 private claimTimer = uint64(157762710427);
    // Check if claim has been made
    bool private hasMadeClaim;
    // Time left before last deposit can be made
    uint64 private countdownTimer = startingTimestamp + 20 hours;
    // Store admin address'
    mapping (address => bool) admins;
    // Address dev fee is sent to for funding devs
    address private devFeeAddress;
    // Dev fee balance
    uint private devBalance;
    // Map user to their deposit info
    mapping (address => DepositInfo) depositInfo;
    // Map deposit id to relevant pot info
    mapping (uint => PotInfo) potInfo;
    // Create array of all deposits for recent deposit info
    RecentDeposit[] recentDeposits;

    /*--- EVENTS ---*/

    event Deposit(uint indexed depositId, address indexed user, uint amount);
    event WithdrawRewards(address indexed user, uint amount);
    event NewAdmin(address indexed admin);
    event RemovedAdmin(address indexed admin);
    event UpdatedDistributionFee(uint distributionFee);
    event UpdatedReferralFee(uint referralFee);
    event UpdatedDropFee(uint dropFee);
    event UpdatedDevFee(uint devFee);
    event UpdatedDevFeeAddress(address indexed _adminAddress);
    event TransferedDropBalance(uint amount);
    event WinnerPaid(address indexed winner, uint amount);

    /*--- MODIFIERS ---*/

    modifier notContract() {
        require(
            !address(msg.sender).isContract(),
             "contract not allowed"
        );
        require(
            msg.sender == tx.origin,
             "proxy contract not allowed"
        );
        _;
    }

    modifier isUser() {
        require(
            userDatabase_.isRegistered(msg.sender),
            "you must register first"
        );
        _;
    }

    modifier onlyAdmin() {
        require(
            msg.sender == owner() ||
            admins[msg.sender] == true,
            "only admins"
        );
        _;
    }

    /*--- CONTRACT DEPLOYMENT CONSTRUCTOR ---*/

    constructor(
        address _devFeeAddress,
        address _userDatabaseAddress
        ) 
    {
        devFeeAddress = _devFeeAddress;
        userDatabase_ = IPolyHeistUserDatabase(_userDatabaseAddress);
    }

    function setRandDrop(address _randDrop) 
        external
        onlyOwner()
    {
        require(
            !hasSetRandDrop, 
            "contract can only be set once"
        );
        randDropAddress = _randDrop;
        hasSetRandDrop = true;
    }

    /*--- MAIN FUNCTIONS ---*/

    function deposit(uint _amount)
        external
        payable
        isUser()
        notContract()
    {
        require(
            countdownTime() > 0, 
            "unlucky time is up!"
        );
        require(
            msg.value == _amount &&
            _amount >= minDeposit(), 
            "not enough matic, you broke"
        );
        require(
            _amount % 1 ether == 0, 
            "whole numbers only smh"
        );

        // If user has rewards they must be withdrawn before they can re-deposit
        if (getRewards(msg.sender) > 0) {
            withdrawRewards();
        }

        // Get users name and info of their referrer
        (bytes16 depositUsername, uint128 referrerId, address referrerAddress) = userDatabase_.getDepositVars(msg.sender);
        uint amount;
        uint refBonus;
        // User has been referred if referrer id is not 0
        if (referrerId > 0) {
            (uint _newAmount, uint _refBonus) = handleReferrer(_amount, referrerAddress);
            amount = _newAmount;
            refBonus = _refBonus;
        } else {
            amount = _amount;
            refBonus = 0;
        }

        // Calculate bonuses to be taken from deposit
        uint usersBonus = (amount * distributionFee) / 100;
        uint dropBonus = (amount * dropFee) / 100;
        uint devBonus = (amount * devFee) / 100;
        uint bonuses = usersBonus + dropBonus + devBonus;
        uint userBalance = amount - bonuses;

        // Store reward bonus and pot total for this deposit
        // Top up winners pot after pot info is saved
        potInfo[depositsTotal] = PotInfo(
            usersBonus,
            winnerPotTotal
        );
        winnerPotTotal += userBalance;
        rewardPotTotal+=usersBonus;
        dropBalance += dropBonus;
        devBalance += devBonus;

        // If user has already deposited, update necessary parameters
        // Else create a new struct for users first deposit
        if (hasDeposited(msg.sender)) {
            depositInfo[msg.sender].id = depositsTotal;
            depositInfo[msg.sender].balance += userBalance;
            depositInfo[msg.sender].refCharged += refBonus;
        } else {
            depositInfo[msg.sender] = DepositInfo(
                depositsTotal,
                userBalance,
                0,
                refBonus,
                0,
                0
            );
        }

        // Stores deposit with extra info to be used on frontend
        recentDeposits.push(RecentDeposit(
            depositUsername,
            uint64(block.timestamp),
            countdownTime(),
            _amount
        ));
        emit Deposit(depositsTotal, msg.sender, _amount);
        depositsTotal++;

        // Reset the countdown
        resetCountdown(msg.sender); 
    }

    // Referrers must have a balance of 5 matic to earn referral rewards
    // Individual users can only be charged up to 10 Matic in referral fees
    function handleReferrer(uint _amount, address _referrerAddress)
        private
        returns (uint _newAmount, uint _refBonus)
    {
        uint charged = depositInfo[msg.sender].refCharged;
        if (charged >= 10 ether || getUserBalance(_referrerAddress) < 5 ether) {
            _refBonus = 0;
            _newAmount = _amount; 
        } else {
            _refBonus = (_amount * referralFee) / 100;
            if (charged + _refBonus > 10 ether) {
                _refBonus = 10 ether - charged;
            }
            _newAmount = _amount - _refBonus;
            depositInfo[_referrerAddress].referralRewards += _refBonus;
        }
        return (_newAmount, _refBonus);
    }

    // Pot rewards are withdrawn after being calculated
    function withdrawRewards() 
        public  
        nonReentrant() 
        isUser() 
    {
        require(
            hasDeposited(msg.sender),
            "deposit to earn rewards"
        );
        uint rewards = getRewards(msg.sender);
        require(
            rewards > 0,
            "reward balance zero"
        );
        depositInfo[msg.sender].id = depositsTotal - 1;
        depositInfo[msg.sender].rewardsWithdrew += rewards;
        Address.sendValue(payable(msg.sender), rewards);
        emit WithdrawRewards(msg.sender, rewards);
    }

    // Referral rewards are already calculated 
    function withdrawRefRewards() 
        external 
        nonReentrant() 
        isUser() 
    {
        require(
            hasDeposited(msg.sender),
            "no rewards if you haven't deposited"
        );
        uint refBonus = getRefRewards(msg.sender);
        require(
            refBonus >= 1e17, 
            "minimum withdrawl is 0.1 MATIC"
        );
        depositInfo[msg.sender].referralRewards = 0;
        depositInfo[msg.sender].refRewardsWithdrew += refBonus;
        Address.sendValue(payable(msg.sender), refBonus);
        emit WithdrawRewards(msg.sender, refBonus);
    }

    // Reset countdown back and store the the address of the deposit
    function resetCountdown(address _lastDeposit) 
        private 
    {
        countdownTimer = uint64(block.timestamp) + 20 hours;
        lastDeposit = _lastDeposit;
    }

    // Winner is deemed to have won fairly, pay winner 70% of pot, 
    // Pay 20% to random drop contract for final drop split between 5 users
    // Pay 10% to dev fee address 
    function validWinner() 
        external 
        nonReentrant() 
        onlyAdmin() 
    {
        require(
            countdownTime() == 0,
            "pot is still open"
        );
        uint winTotal = (winnerPotTotal * 70) / 100;
        uint lastFee = (winnerPotTotal * 10)/ 100;
        uint finalDropBalance = lastFee * 2;

        Address.sendValue(payable(lastDeposit), winTotal);
        Address.sendValue(payable(randDropAddress), finalDropBalance);
        Address.sendValue(payable(devFeeAddress), lastFee);
        emit TransferedDropBalance(finalDropBalance);
        emit WinnerPaid(lastDeposit, winTotal);
    }

    // If winner is deemed to have won maliciously, countdown will be reset and pot will continue as normal
    // Only way to stop unfair wins - LEGITIMATE winner WILL be paid out
    // The winning wallet is NOT inspected, only malicous attacks are considered, such as bloating the network to stop other transactions
    function invalidWinner() 
        external
        onlyAdmin() 
    {
        require(
            countdownTime() == 0,
            "pot is still open"
        );
        resetCountdown(lastDeposit);
        claimTimer = uint64(157762710427);
        hasMadeClaim = false;
    }

    /*--- MANUAL CLAIM FUNCTIONS ---*/

    // If after 1 week winner has not been deemed valid or invalid, the winner can manually claim
    // Example scenarios: 
    // All admins are dead and cannot call contract from the afterlife - RIP
    // All admins are in a comma or involved in accident that causes terminal brain dead
    // All admins have achieved lambo status and dipped off the scene

    function startManualClaimTimer()
       external
       isUser()
    {
        require(
            countdownTime() == 0,
            "pot is still open"
        );
        require(
            msg.sender == lastDeposit,
            "only winner can start the claim"
        );
        require(
            !hasMadeClaim,
            "claim has already started"
        );
        claimTimer = uint64(block.timestamp) + 1 weeks;
        hasMadeClaim = true;
    }

    function manualClaim()
        external
        isUser()
    {
        require(
            countdownTime() == 0,
            "pot is still open"
        );
        require(
            hasMadeClaim,
            "claim must be started"
        );
        require(
            uint64(block.timestamp) >= claimTimer,
            "claim time has not run out"
        );
        require(
            msg.sender == lastDeposit,
            "only winner can claim"
        );
        // To avoid all admins being assasinated :| winner reward is reduced to 50%
        // If all admins are dead then final drop split cannot be made so fee will be burned
        // Therefore potential drop winners are incentivised to protect admins at all cost ;)
        uint splitWin = winnerPotTotal / 2;
        Address.sendValue(payable(lastDeposit), splitWin);
        Address.sendValue(payable(address(0)), splitWin);
        emit WinnerPaid(lastDeposit, splitWin);
    }

    /*--- VIEW FUNCTIONS ---*/

    function hasDeposited(address _address) 
        private 
        view 
        returns (bool) 
    {
        return (getUserBalance(_address) > 0);
    }

    function minDeposit() 
        public
        view
        returns (uint) 
    {
        return (winnerPotTotal / minDepPercent);
    }

    function getRewards(address _address)
        public
        view
        returns (uint)
    {
        uint usrReward;
        uint initial = depositInfo[_address].id + 1;
        uint balance = depositInfo[_address].balance;
        for (uint i = initial; i < depositsTotal; i++) {
            usrReward +=
                (balance * potInfo[i].fee) /
                potInfo[i].winnerPot;
        }
        return (usrReward);
    }

    function getRefRewards(address _address)
        public
        view
        returns (uint)
    {
        return depositInfo[_address].referralRewards;
    }

    function getUserBalance(address _address) 
        private 
        view 
        returns (uint) 
    {
        return (depositInfo[_address].balance);
    }

    function isPotOpen()
        external
        view
        returns (bool)
    {
        return (countdownTime() > 0);
    }

    function countdownTime() 
        public
        view
        returns (uint64)
    {
        if (countdownTimer > uint64(block.timestamp)) {
            return (countdownTimer - uint64(block.timestamp));
        } else {
            return 0;
        }
    }

    /*--- FRONTEND HELPER FUNCTIONS ---*/

    function getPotInfo()
        external
        view
        returns (
            bytes16 currentWinner,
            uint64 timeLeft,
            uint winnerTotal,
            uint rewardTotal
        )
    {
        currentWinner = userDatabase_.getAddressToUsername(lastDeposit);
        return (currentWinner,countdownTime(), winnerPotTotal, rewardPotTotal);
    }

    function getUserData(address _address) 
        external 
        view 
        returns (
            uint128 userId, 
            bytes16 username, 
            uint balance, 
            uint pendingReward
        ) 
    {
        (uint128 id,, bytes16 name) = userDatabase_.getUserInfo(_address);
        return (
            id, 
            name, 
            depositInfo[_address].balance, 
            getRewards(_address) 
        );
    }

    function getRecentDeposits() 
        external
        view
        returns (RecentDeposit[] memory)
    {
        uint count = recentDeposits.length;
        uint inital = count - 5;
        RecentDeposit[] memory recent = new RecentDeposit[](5);

        for (uint i = inital; i < count; i++) {
            recent[(i - inital)] = recentDeposits[i];
        }
        return (recent);
    }

    function getRewardsWithdrew(address _address)
       external
       view
       returns (uint rewardsWithdrew) 
    {
        return depositInfo[_address].rewardsWithdrew;
    }

    function getRefRewardsWithdrew(address _address)
       external
       view
       returns (uint refRewardsWithdrew) 
    {
        return depositInfo[_address].refRewardsWithdrew;
    }

    function getCurrentFees()
       external
       view
       returns (uint distribution, uint referral, uint drop, uint dev) 
    {
        return (distributionFee, referralFee, dropFee, devFee);
    }

    /*--- UPDATE FUNCTIONS ---*/

    function updateDistributionFee(uint _distributionFee)
        external
        onlyAdmin()
    {
        require(
            _distributionFee != distributionFee,
            "fee is already set to this value"
        );
        require(
            _distributionFee <= maxDistributionFee,
            "fee cannot be higher than maximum"
        );
        distributionFee = _distributionFee;
        emit UpdatedDistributionFee(distributionFee);
    }

    function updateReferralFee(uint _referralFee) 
        external 
        onlyAdmin()
    {
        require(
            _referralFee != referralFee,
            "fee is already set to this value"
        );
        require(
            _referralFee <= maxReferralFee,
            "fee cannot be higher than maximum"
        );
        referralFee = _referralFee;
        emit UpdatedReferralFee(referralFee);
    }

    function updateDropFee(uint _dropFee) 
        external 
        onlyAdmin() 
    {
        require(
            _dropFee != dropFee, 
            "fee is already set to this value"
        );
        require(
            _dropFee <= maxDropFee,
            "fee cannot be higher than maximum"
        );
        dropFee = _dropFee;
        emit UpdatedDropFee(dropFee);
    }

    function updateDevFee(uint _devFee) 
        external 
        onlyAdmin() 
    {
        require(
            _devFee != devFee, 
            "fee is already set to this value"
        );
        require(
            _devFee <= maxDevFee,
            "fee cannot be higher than maximum"
        );
        devFee = _devFee;
        emit UpdatedDevFee(devFee);
    }

    function addAdmin(address _adminAddress)
        external
        onlyOwner()
    {
        require(
            admins[_adminAddress] == false, 
            "address is already an admin"
        );
        require(
            _adminAddress != address(0), 
            "invalid address"
        );
        admins[_adminAddress] = true;
        emit NewAdmin(_adminAddress);
    }
    
    function removeAdmin(address _adminAddress)
        external
        onlyOwner()
    {
        require(
            admins[_adminAddress] == true, 
            "address is not an admin"
        );
        require(
            _adminAddress != address(0), 
            "invalid address"
        );
        admins[_adminAddress] = false;
        emit RemovedAdmin(_adminAddress);
    }

    function updateDevFeeAddress(address _devFeeAddress) 
        external 
        onlyOwner() 
    {
        require(
            devFeeAddress != _devFeeAddress, 
            "address already set"
        );
        require(
            _devFeeAddress != address(0), 
            "invalid address"
        );
        devFeeAddress = _devFeeAddress;
        emit UpdatedDevFeeAddress(_devFeeAddress);
    }
    /*--- DEV FUNCTIONSS ---*/
    
    // Transfers drop balance to contract (not final drop)
    function transferDropBalance() 
        external 
        nonReentrant()
        onlyAdmin()
    {
        require(
            dropBalance > 0, 
            "random drop balance is zero"
        );
        Address.sendValue(payable(randDropAddress), dropBalance);
        emit TransferedDropBalance(dropBalance);
        dropBalance = 0;
    }

    function withdrawDevBalance() 
        external 
        nonReentrant()
        onlyAdmin() 
    {
        require(
            devBalance > 0, 
            "dev balance is zero"
        );
        Address.sendValue(payable(devFeeAddress), devBalance);
        devBalance = 0;
    }

    // First deposit of 50 Matic by PolyHeist to incentivise user deposits
    function initalDeposit()
        external
        payable
        onlyOwner()
    {
        require(
            msg.value == 50 ether,
            "not equal to 50 Matic"
        );
        require(
            depositsTotal == 0,
            "not equal to 50 Matic"
        );
        winnerPotTotal += 50 ether;
        depositInfo[msg.sender] = DepositInfo(depositsTotal, 50 ether, 0, 0, 0, 0);

        recentDeposits.push(RecentDeposit(
            0x706f6c792d6865697374000000000000,
            uint64(block.timestamp),
            countdownTime(),
            50 ether
        ));
        depositsTotal++;
        resetCountdown(msg.sender);
        emit Deposit(depositsTotal, msg.sender, 50 ether);
    }
}