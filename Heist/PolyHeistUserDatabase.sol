/* SPDX-License-Identifier: UNLICENSED 
This smart contract is unlicensed ie. non-open-source code and is protected by EULA.
Any attempt to copy, modifiy, or use this code without written consent from PolyHeist is prohibited.
Please see https://poly-heist.gitbook.io/info/license-agreement/license for more information.
*/

pragma solidity 0.8.6;

/* 
   Welcome to Heist, a gamified long term investment brought to you by PolyHeist.
   This contract is the User Database, here you can register for access to the main Heist contract.
   To play Heist, register on our website:  https://polyheist.io
   Good luck!
*/

import "./@openzeppelin/contracts/access/Ownable.sol";
import "./@openzeppelin/contracts/utils/Address.sol";
import "./BytesLib.sol";

contract PolyHeistUserDatabase is Ownable {
    using Address for address;
    using BytesLib for bytes;

    /*
    ------------------------------------------------------------------------------------------
    CONTRACT VARIABLES
    ------------------------------------------------------------------------------------------
    */

    struct UserInfo {
        uint128 id;
        uint128 referrerId;
        bytes16 name;
    }

    // Register fee to "slightly" deter use of multiple wallets, [ 1 ether = 1 Matic ]
    // Set to 1 Matic but can be raised to 10 Matic if users abuse multiple wallets
    // Max fee is immutable and therefore cannot be modified
    uint public registerFee = 1 ether;
    uint private immutable maxRegisterFee = 10 ether;
    // Dev address to recieve register fees
    address private devAddress;
    // Map user address to their info
    mapping(address => UserInfo) private userInfo;
    // Map user id to their address
    mapping(uint128 => address) private idToAddress;
    // Allows easy checking of taken usernames
    mapping(bytes16 => uint128) private usernameToId;
    // Use referrer id to find users they have referred
    mapping(uint128 => uint128[]) private referrerIdToUsers; 
    // Total number of users registered
    uint128 private userTotal;
    
    /*
    ------------------------------------------------------------------------------------------
    EVENTS
    ------------------------------------------------------------------------------------------
    */

    event NewUser(bytes16 username, uint128 indexed id, uint128 indexed referrerId, uint blockTime);
    event UpdatedRegisterFee(uint registerFee, uint blockTime);

    /*
    ------------------------------------------------------------------------------------------
    MODIFIERS
    ------------------------------------------------------------------------------------------
    */

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

    /*
    ------------------------------------------------------------------------------------------
    CONTRACT DEPLOYMENT CONSTRUCTOR
    ------------------------------------------------------------------------------------------
    */

    constructor(
        address _devAddress
        ) 
    {
        devAddress = _devAddress;
    }

    /*
    ------------------------------------------------------------------------------------------
    MAIN FUNCTIONS
    ------------------------------------------------------------------------------------------
    */

    function registerUser(bytes16 _name, uint128 _referrerId)
        external
        payable
        notContract() 
    {
        require(
            msg.value >= registerFee, 
            "pay the fee broke boi"
        );
        require(
            !isRegistered(msg.sender), 
            "address already registered dummy boi, you stoopid"
        );
        require(
            validUsername(_name), 
            "invalid or taken username"
        );
        require(
            validReferral(_referrerId),
            "invalid referral code"
        );
        
        // Create new user
        userTotal++;
        userInfo[msg.sender] = UserInfo(userTotal, _referrerId, _name);
        referrerIdToUsers[_referrerId].push(userTotal);
        idToAddress[userTotal] = msg.sender;
        usernameToId[_name] = userTotal;
        emit NewUser(_name, userTotal, _referrerId, block.timestamp);
    }

    function isRegistered(address _address) 
        public 
        view 
        returns (bool) 
    {
        return (userInfo[_address].id > 0);
    }

    // Stops users from attempting to referrer themselves
    function validReferral(uint128 _referrer) 
        public 
        view 
        returns (bool) 
    {
        return (
            _referrer == 0 || 
            userInfo[idToAddress[_referrer]].id == _referrer
        );
    }

    function validUsername(bytes16 _name) 
        public 
        view 
        returns (bool) 
    {
        // Username must be between 3-16 characters
        if (_name.length < 3 || _name.length > 16) {
            return false;
        }
        // Check if username is registered 
        if (usernameToId[_name] > 0) {
            return false;
        }
        // Username cannot start with 0x
        if (_name[0] == 0x30) {
            if (_name[1] == 0x78 || _name[1] == 0x78) {
                return false;
            }
        }
        return true;
    }

    /*
    ------------------------------------------------------------------------------------------
    EXTERNAL FUNCTIONS
    ------------------------------------------------------------------------------------------
    */

    function getUserTotal() 
        external 
        view 
        returns (uint128) 
    {
        return (userTotal);
    }
    
    function getUserInfo(address _address) 
        external 
        view 
        returns (uint128 id, uint128 referrerId, bytes16 name) 
    {
        UserInfo memory user = userInfo[_address];
        return (user.id, user.referrerId, user.name);
    }

    function getAddressToId(address _address) 
        external 
        view 
        returns (uint128) 
    {
        return (userInfo[_address].id);
    }

    function getIdToAddress(uint128 _id) 
        external 
        view 
        returns (address)
    {
        return (idToAddress[_id]);
    }

    function getAddressToUsername(address _address) 
        external 
        view 
        returns (bytes16) 
    {
        return (userInfo[_address].name);
    }

    function getUsersReferred(uint128 _referrerId)
        external
        view
        returns (uint noOfUsers, uint128[] memory userIds)
    {
        return (referrerIdToUsers[_referrerId].length, referrerIdToUsers[_referrerId]);
    }
    
    function getUserReferrer(address _address) 
        external 
        view 
        returns (uint128) 
    {
        return (userInfo[_address].referrerId);
    }

    function getDepositVars(address _userAddress) 
        external 
        view
        returns (bytes16 _depositUsername, uint128 _referrerId, address _referrerAddress) 
    {
        _depositUsername = userInfo[_userAddress].name;
        _referrerId = userInfo[_userAddress].referrerId;
        _referrerAddress = idToAddress[_referrerId];

        return (_depositUsername, _referrerId, _referrerAddress);
    }

    /*
    ------------------------------------------------------------------------------------------
    MAINTENENCE FUNCTIONS
    ------------------------------------------------------------------------------------------
    */

    // In extreme cases were a username is far too inappropriate or hateful, the name will be reset to something random
    // We do not want to display nor condone these kind of names on our platform
    function resetUsername(address _address, bytes16 _newName)
        external 
        onlyOwner()
    {
        require(
            validUsername(_newName),
            "invalid username"
        );
        userInfo[_address].name = _newName;
    }

    function updateRegisterFee(uint _registerFeeInEth) 
        external 
        onlyOwner() 
    {
        uint newfee = _registerFeeInEth * 1 ether;
        require(
            newfee <= maxRegisterFee,
            "fee cannot be higher than the set maximum"
        );
        require(
            newfee != registerFee, 
            "fee is already set to this value"
        );
        registerFee = newfee;
        emit UpdatedRegisterFee(registerFee, block.timestamp);
    }

    function withdrawContractBalance()
        external 
        onlyOwner()
    {
        require(
            address(this).balance > 0,
            "contract has no balance"
        );
        Address.sendValue(payable(msg.sender), address(this).balance);
    }
}
