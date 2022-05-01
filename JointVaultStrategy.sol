// SPDX-License-Identifier: Apache-2.0

pragma solidity =0.8.9;

import "./IAAVE.sol";
import "./JointVaultUSDC.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPeriphery.sol";
import "./interfaces/IMarginEngine.sol";
import "./interfaces/fcms/IFCM.sol";
import "./core_libraries/Time.sol";


contract JointVaultStrategy is Ownable {
    //
    // Constants
    //

    uint160 MIN_SQRT_RATIO = 2503036416286949174936592462;
    uint160 MAX_SQRT_RATIO = 2507794810551837817144115957740;

    //
    // Token contracts
    //

    IERC20 public variableRateToken; // AUSDC
    IERC20 public underlyingToken; // USDC
    JointVaultUSDC public JVUSDC; // JVUSDC ERC instantiation

    //
    // Aave contracts
    //
    IAAVE AAVE;

    //
    // Voltz contracts
    //

    //
    // Logic variables
    //

    // CollectionWindow public collectionWindow;
    // uint256 public termEnd; // unix timestamp in seconds
    // uint public cRate; // Conversion rate

    //
    // Structs
    //
/*
    struct CollectionWindow {
        uint256 start; // unix timestamp in seconds
        uint256 end; // unix timestamp in seconds
    }

    //
    // Modifiers
    //

    modifier isInCollectionWindow() {
        require(collectionWindowSet(), "Collection window not set");
        require(inCollectionWindow(), "Collection window not open");
        _;
    }

    modifier isNotInCollectionWindow() {
        require(collectionWindowSet(), "Collection window not set");
        require(!inCollectionWindow(), "Collection window open");
        _;
    }

    modifier canExecute() {
        require(isAfterCollectionWindow(), "Collection round has not finished");
        _;
    }

    modifier canSettle() {
        require(isAfterEndTerm(), "Not past term end");
        _;
    }
*/  
    address fcm;
    address marginEngine;
    address factory;
    address periphery;
    uint256 public cRate;
    bytes public maturity;
    constructor(
        //CollectionWindow memory _collectionWindow
    ) {
        // Token contracts
        variableRateToken = IERC20(0x39914AdBe5fDbC2b9ADeedE8Bcd444b20B039204);
        underlyingToken = IERC20(0x016750AC630F711882812f24Dba6c95b9D35856d);

        // Deploy JVUSDC token
        JVUSDC = new JointVaultUSDC("Joint Vault USDC", "jvUSDC"); 

        // Voltz contracts
        factory = 0x07091fF74E2682514d860Ff9F4315b90525952b0;
        periphery = 0xcf0144e092f2B80B11aD72CF87C71d1090F97746;

        //periphery = IPeriphery(factory.periphery());
        fcm = 0xEF3195f842d97181b7E72E833D2eE0214dB77365;
        marginEngine = 0x13E30f8B91b5d0d9e075794a987827C21b06d4C1;

        // Aave contracts
        AAVE = IAAVE(0xE0fBa4Fc209b4948668006B2bE61711b7f465bAe);

        // Set initial collection window
        //collectionWindow = _collectionWindow;

        // initialize conversion rate
        cRate = 1e18; 
    }

    //
    // Modifier helpers
    //
/*
    function collectionWindowSet() internal returns (bool) {
        return collectionWindow.start != 0 && collectionWindow.end != 0;
    }

    function inCollectionWindow() internal returns (bool) {
        return block.timestamp >= collectionWindow.start && block.timestamp < collectionWindow.end;
    }

    function isAfterCollectionWindow() internal returns (bool) {
        // TODO: Also ensure that it's before the start of the next collection window
        return block.timestamp > collectionWindow.end;
    }

    function isAfterEndTerm() internal returns (bool) {
        return block.timestamp >= termEnd;
    }
*/
    //
    // Data functions
    //

    // Returns factor in 5 decimal format to handle sub 1 numbers.
    // TODO: remove hardcoded decimals
    function conversionFactor() internal view returns (uint256) {
        require(JVUSDC.totalSupply() != 0, "JVUSDC totalSupply is zero");

        return (
            // twelve decimals for aUSDC / jVUSDC decimal different + 18 from ctoken decimals
            variableRateToken.balanceOf(address(this)) * 10 ** 18
            / JVUSDC.totalSupply()
        );
    }
 
    // @notice Update conversion rate 
    function updateCRate() internal { // restriction needed
        cRate = conversionFactor();
    }

    //
    // Strategy functions
    //

    function getUnderlyingTokenOfMarginEngine() public returns(address me){
        return address(IMarginEngine(marginEngine).underlyingToken());
    }
    uint public endTimestamp;
    function getEndTimestampWad() public returns(uint endTimestampWad) {
        endTimestamp = IMarginEngine(marginEngine).termEndTimestampWad()/1e18;
        return IMarginEngine(marginEngine).termEndTimestampWad();
    }

    function windowIsClosed() public returns(bool closed) {
        emit test2(Time.isCloseToMaturityOrBeyondMaturity(getEndTimestampWad()));
        return Time.isCloseToMaturityOrBeyondMaturity(getEndTimestampWad());
    }

    function provideLiquidity(uint amount) public returns (bool success){
        require(underlyingToken.allowance(msg.sender, address(this)) >= amount, "Approve contract first;");
        underlyingToken.transferFrom(msg.sender, address(this), amount);
        IERC20(underlyingToken).approve(periphery, 10e27);
        IPeriphery.MintOrBurnParams memory mobp;
        mobp = IPeriphery.MintOrBurnParams(IMarginEngine(marginEngine),
                                                    -60,
                                                    60,
                                                    amount,
                                                    true,
                                                    amount);
        IPeriphery(periphery).mintOrBurn(mobp);
    }

    event test(uint aaaaaaaa);
    event test2(bool abcccccccccc);

    // @notice Interact with Voltz 
    function execute(uint amount) public  {
        IERC20(variableRateToken).approve(fcm, amount);
        emit test(variableRateToken.balanceOf(address(this)));
        (int a, int b,,) = IFCM(fcm).initiateFullyCollateralisedFixedTakerSwap(amount, MAX_SQRT_RATIO - 1);
        //(bool success, ) = fcm.call{value: 0}(
        //    abi.encodeWithSignature("initiateFullyCollateralisedFixedTakerSwap(uint256,uint160)",
         //   amount,
         //    MAX_SQRT_RATIO - 1));
        emit test(variableRateToken.balanceOf(address(this)));
        //emit test2(success);
        //require(variableRateToken.balanceOf(address(this)) == 0, "No Success");


        (bool success2, bytes memory termEnd) = marginEngine.call{value:0}(abi.encodeWithSignature("termEndTimestampWad()"));
        require(success2, "No Success-2");
        maturity = termEnd;
    }

    // @notice Update window in which 
    // @param  Amount of USDC to withdraw from AAVE
    //function updateCollectionWindow() public {
    //    collectionWindow.start = termEnd;
    //    collectionWindow.end = termEnd + 86400; // termEnd + 1 day
    //}
    
    // @notice Settle Strategie 
    function settle() public  {
        // Get AUSDC and USDC from Voltz position
        IFCM(fcm).settleTrader();
        //fcm.call{value: 0}(abi.encodeWithSignature("settleTrader()"));

        // Convert USDC to AUSDC
        uint256 underlyingTokenBalance = underlyingToken.balanceOf(address(this));

        underlyingToken.approve(address(AAVE), underlyingTokenBalance);
        AAVE.deposit(address(underlyingToken), underlyingTokenBalance, address(this), 0);

        // Update cRate
        updateCRate();

        // Update the collection window
        //updateCollectionWindow();
    }

    // TODO: Do not require custodian
    function setMarginEngine(address _marginEngine) public onlyOwner {
        marginEngine = _marginEngine;
    }

    //
    // User functions
    //
    
    // @notice Initiate deposit to AAVE Lending Pool and receive jvUSDC
    // @param  Amount of USDC to deposit to AAVE
    // TODO: remove hardcoded decimals
    function deposit(uint256 amount) public  {
        require(underlyingToken.allowance(msg.sender, address(this)) >= amount, "Approve contract first;");
        underlyingToken.transferFrom(msg.sender, address(this), amount);

        // Convert different denominations (6 <- 18)
        uint mintAmount = amount;  // * 1e12;
        emit test(mintAmount);

        // Approve AAve to spend the underlying token
        underlyingToken.approve(address(AAVE), amount);

        // Calculate deposit rate
        uint256 finalAmount = mintAmount * 1e18 / cRate;
        emit test(finalAmount);

        // Deposit to Aave
        AAVE.deposit(address(underlyingToken), amount, address(this), 0);
        require(variableRateToken.balanceOf(address(this)) > 0, "Aave deposit failed;");
        emit test(amount);

        // Mint jvUSDC
        JVUSDC.adminMint(msg.sender, finalAmount);      
    }

    // @notice Initiate withdraw from AAVE Lending Pool and pay back jvUSDC
    // @param  Amount of yvUSDC to redeem as USDC
    // TODO: remove hardcoded decimals
    function withdraw(uint256 amount) public  {
        // Convert different denominations (6 -> 18)
        uint256 withdrawAmount = amount; // / 1e12;
        uint256 finalAmount = cRate * withdrawAmount / 1e18;

        // Pull jvUSDC tokens from user
        JVUSDC.transferFrom(msg.sender, address(this), amount);

        // Burn jvUSDC tokens from this contract
        JVUSDC.adminBurn(address(this), amount);

        // Update payout amount
        uint256 wa = AAVE.withdraw(address(underlyingToken), withdrawAmount, address(this));
        require(wa == withdrawAmount, "Not enough collateral;");

        // Transfer USDC back to the user
        underlyingToken.transfer(msg.sender, finalAmount);
    }

    // @notice Receive this contracts USDC balance
    function contractBalanceUsdc() public view returns (uint256){
        return underlyingToken.balanceOf(address(this));      
    }

    // @notice Receive this contracts aUSDC balance
    function contractBalanceAUsdc() public view returns (uint256){
        return variableRateToken.balanceOf(address(this));      
    }

    function now() public view returns (uint) {
        return block.timestamp;
    }

    // @notice Fallback that ignores calls from jvUSDC
    // @notice Calls from jvUSDC happen when user deposits
    //fallback() external {
        //if (underlyingToken.balanceOf(address(this)) > 0) {
        //    AAVE.deposit(address(underlyingToken), underlyingToken.balanceOf(address(this)), address(this), 0);
        //}
        //if (msg.sender != address(JVUSDC)) {
        //    revert("No known function targeted");
        //} 
    //}
}
