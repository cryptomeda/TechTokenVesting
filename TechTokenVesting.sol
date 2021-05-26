// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.0;

interface ERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract TechTokenVesting {

    ERC20 public techToken;
    address public owner_;

    modifier onlyAdmin {
        require(msg.sender == owner_, "Not Admin");
        _;
    }

    modifier onlyValidAddress(address _recipient) {
        require(_recipient != address(0) && _recipient != address(this) && _recipient != address(techToken), "not valid _recipient");
        _;
    }

    uint24 constant internal SECONDS_PER_DAY = 86400;

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
                Public}

    struct Grant {
        uint256 startTime;
        uint256 amount;
        uint16 vestingDuration; // In months
        uint16 vestingCliff;    // In months
        uint16 daysClaimed;
        uint256 totalClaimed;
        address recipient;
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

    uint256 public totalVestingCount = 1;

    constructor(ERC20 _techToken)  {
        require(address(_techToken) != address(0));
        owner_ = msg.sender;
        techToken = _techToken;
    }

    function vestingGroupParameter(VGroup _name, 
                            uint8 _vestingDurationInMonths, 
                            uint8 _vestingCliffInMonths, 
                            uint8 _percent) 
                            external onlyAdmin{
        require(_vestingDurationInMonths >= _vestingCliffInMonths, "Duration < Cliff");
        parameter[_name] = VestingGroup(_vestingDurationInMonths, _vestingCliffInMonths, _percent);
    }

    /// @notice Add one or more token grants
    /// The amount of tokens here needs to be preapproved for this TokenVesting contract before calling this fucntion
    /// @param _recipient Address of the token grant recipient
    /// @param _name Vesting group name, which is mapped to its specific parameters 
    /// @param _startTime Grant start time in seconds (unix timestamp)
    /// @param _amount Total number of tokens in grant
    function addTokenGrant(address[] memory _recipient, 
                            VGroup[] memory _name, 
                           uint256[] memory _startTime,
                           uint256[] memory _amount)
                            external onlyAdmin {
        require(_recipient.length == _name.length, "Different array length");
        require(_recipient.length == _startTime.length, "Different array length");
        require(_recipient.length == _amount.length, "Different array length");

        for(uint i=0;i<_recipient.length;i++) {

            // Transfer the grant tokens under the control of the vesting contract
            require(techToken.transferFrom(owner_, address(this), _amount[i]), "transfer failed");

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
            emit GrantAdded(_recipient[i], totalVestingCount);
            totalVestingCount++;    //grantId
        }
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

        require(techToken.transfer(tokenGrant.recipient, amountVested), "no tokens");
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

        require(techToken.transfer(recipient, amountVested));
        require(techToken.transfer(owner_, amountNotVested));

        tokenGrant.startTime = 0;
        tokenGrant.amount = 0;
        tokenGrant.vestingDuration = 0;
        tokenGrant.vestingCliff = 0;
        tokenGrant.daysClaimed = 0;
        tokenGrant.totalClaimed = 0;
        tokenGrant.recipient = address(0);

        emit GrantRemoved(recipient, amountVested, amountNotVested);
    }

    function currentTime() public view returns(uint256) {
        return block.timestamp;
    }

    function tokensVestedPerDay(uint256 _grantId) public view returns(uint256) {
        Grant memory tokenGrant = tokenGrants[_grantId];
        return tokenGrant.amount/(uint256(tokenGrant.vestingDuration*(30)));
    }

    function changeAdmin(address _newAdmin) 
        external 
        onlyAdmin
        onlyValidAddress(_newAdmin)
    {
        owner_ = _newAdmin;
        emit ChangedAdmin(_newAdmin);
    }

}
