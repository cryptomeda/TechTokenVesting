// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface ERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

/*
Inspired by and based on following vesting contract:
https://gist.github.com/rstormsf/7cfb0c6b7a835c0c67b4a394b4fd9383
*/
contract TechTokenVesting is Ownable {
    using SafeERC20 for ERC20;

    event GrantAdded(address indexed recipient, uint256 grantId);
    event GrantTokensClaimed(address indexed recipient, uint256 amountClaimed);
    event GrantRemoved(address recipient, uint256 amountVested, uint256 amountNotVested);
    event ChangedAdmin(address admin);

    enum VGroup{ Ecosystem_community,
                Development_Tech,
                Development_Mktg,
                Founders,
                Team,
                Advisors,
                DEX_Liquidity,
                Seed,
                Private_TGE,
                Private_Linear,
                Public_TGE,
                Public_Linear,
                Public_Linear,
                Removed_Grant,
                Custom1,
                Custom2,
                Custom3}

    struct Grant {
        uint256 startTime;
        uint256 amount;
        uint16 vestingDuration; // In months
        uint16 vestingCliff;    // In months
        uint16 daysClaimed;
        address recipient;
        uint256 totalClaimed;
    }

    // Category of Vesting Group    
    struct VestingGroup {
        uint8 vestingDuration; // In months
        uint8 vestingCliff; // In months
        uint8 percent_tSupply;  // percent of total supply 
    }

    mapping (uint256 => Grant) public tokenGrants;
    mapping (address => uint[]) private activeGrants;
    mapping (VGroup => VestingGroup) private parameter; // Enum mapped to Struct

    address public admin;
    uint256 public totalVestingCount = 1;
    ERC20 public immutable techToken;
    uint24 constant internal SECONDS_PER_DAY = 86400;

    /// @notice There are two admin roles - admin and owner
    /// in case of need/risk, owner can substitute/change admin
    modifier onlyAdmin {
        require(msg.sender == admin || msg.sender == owner(), "Not Admin");
        _;
    }
    modifier onlyValidAddress(address _recipient) {
        require(_recipient != address(0) && _recipient != address(this) && _recipient != address(techToken), "not valid _recipient");
        _;
    }

    constructor(ERC20 _techToken)  {
        require(address(_techToken) != address(0), "invalid token address");
        admin = msg.sender;
        techToken = _techToken;
    }

    /// @notice Add vesting parameters for specific VestingGroup into mapping "parameters"
    /// Needs to be called before calling addTokenGrant
    function addVestingGroupParameter(VGroup _name, 
                            uint8 _vestingDurationInMonths, 
                            uint8 _vestingCliffInMonths, 
                            uint8 _percent) 
                            external onlyAdmin{
        require(_vestingDurationInMonths >= _vestingCliffInMonths, "Duration < Cliff");
        parameter[_name] = VestingGroup(_vestingDurationInMonths, _vestingCliffInMonths, _percent);
    }

    /// @notice Add one or more token grants
    /// The amount of tokens here needs to be preapproved for this TokenVesting contract before calling this function
    /// @param _recipient Address of the token grant recipient
    /// @param _name Vesting group name, which is mapped to its specific parameters 
    /// @param _startTime Grant start time in seconds (unix timestamp)
    /// @param _amount Total number of tokens in grant
    function addTokenGrant(address[] calldata _recipient, 
                            VGroup[] calldata _name, 
                           uint256[] calldata _startTime,
                           uint256[] calldata _amount)
                            external onlyAdmin {
        require(_recipient.length <= 20, "Limit of 20 grants in one call exceeded");
        require(_recipient.length == _name.length, "Different array length");
        require(_recipient.length == _startTime.length, "Different array length");
        require(_recipient.length == _amount.length, "Different array length");
        
        for(uint i=0;i<_recipient.length;i++) {
            require(_amount[i] > 0, "Amount <= 0");

            Grant memory grant = Grant({
                startTime: _startTime[i] == 0 ? currentTime() : _startTime[i],
                amount: _amount[i],
                vestingDuration: parameter[_name[i]].vestingDuration,
                vestingCliff: parameter[_name[i]].vestingCliff,
                daysClaimed: 0,
                totalClaimed: 0,
                recipient: _recipient[i]
            });

            tokenGrants[totalVestingCount] = grant;
            activeGrants[_recipient[i]].push(totalVestingCount);

            // Transfer the grant tokens under the control of the vesting contract
            techToken.safeTransferFrom(msg.sender, address(this), _amount[i]);

            emit GrantAdded(_recipient[i], totalVestingCount);
            totalVestingCount++;    //grantId
        }
    }

    /// @notice Allows a grant recipient to claim their vested tokens. Errors if no tokens have vested
    /// It is advised recipients check they are entitled to claim via `calculateGrantClaim` before calling this
    function claimVestedTokens(uint256 _grantId) external {
        uint16 timeVested;
        uint256 amountVested;
        (timeVested, amountVested) = calculateGrantClaim(_grantId);
        require(amountVested > 0, "amountVested is 0");

        Grant storage tokenGrant = tokenGrants[_grantId];
        tokenGrant.daysClaimed = uint16(tokenGrant.daysClaimed+(timeVested));
        tokenGrant.totalClaimed = uint256(tokenGrant.totalClaimed+(amountVested));

        techToken.safeTransfer(tokenGrant.recipient, amountVested);
        emit GrantTokensClaimed(tokenGrant.recipient, amountVested);
    }

    /// @notice Terminate token grant transferring all vested tokens to the `_grantId`
    /// and returning all non-vested tokens to the Admin
    /// Secured to the Admin only
    /// @param _grantId grantId of the token grant recipient
    function removeTokenGrant(uint256 _grantId) 
        external 
        onlyAdmin
    {
        Grant storage tokenGrant = tokenGrants[_grantId];
        address recipient = tokenGrant.recipient;
        uint16 timeVested;
        uint256 amountVested;
        (timeVested, amountVested) = calculateGrantClaim(_grantId);

        uint256 amountNotVested = (tokenGrant.amount-(tokenGrant.totalClaimed))-(amountVested);

        tokenGrant.startTime = 0;
        tokenGrant.amount = 0;
        tokenGrant.vestingDuration = 0;
        tokenGrant.vestingCliff = 0;
        tokenGrant.daysClaimed = 0;
        tokenGrant.totalClaimed = 0;
        tokenGrant.recipient = address(0);

        if (amountVested > 0) techToken.safeTransfer(recipient, amountVested); 
        
        // Non-vested tokens remain in smart contract
        // They can be withdrawn only using addTokenGrant 
        // if (amountNotVested > 0) techToken.safeTransfer(msg.sender, amountNotVested);

        emit GrantRemoved(recipient, amountVested, amountNotVested);
    }

    function changeAdmin(address _newAdmin) 
        external 
        onlyAdmin
        onlyValidAddress(_newAdmin)
    {
        owner = _newAdmin;
        emit ChangedAdmin(_newAdmin);
    }

    function getActiveGrants(address _recipient) public view returns(uint256[] memory){
        return activeGrants[_recipient];
    }

    /// @notice Calculate the vested and unclaimed months and tokens available for `_grantId` to claim
    /// Due to rounding errors once grant duration is reached, returns the entire left grant amount
    /// Returns (0, 0) if cliff has not been reached
    function calculateGrantClaim(uint256 _grantId) public view returns (uint16, uint256) {
        Grant storage tokenGrant = tokenGrants[_grantId];

        // For grants created with a future start date, that hasn't been reached, return 0, 0
        if (currentTime() < tokenGrant.startTime) {
            return (0, 0);
        }

        // Check cliff was reached
        uint elapsedTime = currentTime()-(tokenGrant.startTime);
        uint elapsedDays = elapsedTime/(SECONDS_PER_DAY);

        if (elapsedDays < tokenGrant.vestingCliff*(30)) {
            return (uint16(elapsedDays), 0);
        }

        // If over vesting duration, all tokens vested
        if (elapsedDays >= tokenGrant.vestingDuration*(30)) {
            uint256 remainingGrant = tokenGrant.amount-(tokenGrant.totalClaimed);
            return (tokenGrant.vestingDuration, remainingGrant);
        } else {
            uint16 timeVested = uint16(elapsedDays-(tokenGrant.daysClaimed));
            uint256 amountVestedPerDay = tokenGrant.amount/(uint256(tokenGrant.vestingDuration*(30)));
            uint256 amountVested = uint256(timeVested*(amountVestedPerDay));
            return (timeVested, amountVested);
        }
    }

    function currentTime() public view returns(uint256) {
        return block.timestamp;
    }

    function tokensVestedPerDay(uint256 _grantId) public view returns(uint256) {
        Grant memory tokenGrant = tokenGrants[_grantId];
        return tokenGrant.amount/(uint256(tokenGrant.vestingDuration*(30)));
    }

}
