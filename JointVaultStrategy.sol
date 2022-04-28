// SPDX-License-Identifier: Apache-2.0

pragma solidity =0.8.9;

import "./IAAVE.sol";
import "./JointVaultUSDC.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPeriphery.sol";
import "./interfaces/IMarginEngine.sol";


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
    uint256 cRate;
    bytes public maturity;
    constructor(
        //CollectionWindow memory _collectionWindow
    ) {
        // Token contracts
        variableRateToken = IERC20(0xe12AFeC5aa12Cf614678f9bFeeB98cA9Bb95b5B0);
        underlyingToken = IERC20(0x016750AC630F711882812f24Dba6c95b9D35856d);

        // Deploy JVUSDC token
        JVUSDC = new JointVaultUSDC("Joint Vault USDC", "jvUSDC"); 

        // Voltz contracts
        factory = 0x4cd7e3fF2bF87E848d2f2F178f613e1391e189B1;
        periphery = 0x8614B5fa62BBB45be5B320E1B6727E5828B5b513;

        //periphery = IPeriphery(factory.periphery());
        fcm = 0x96a9595e79dB2B74b72dB7cf6d35028720C4Abe1;
        marginEngine = 0x173F0a3Ff16a036AcB7135b69AF717993F932F67;

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
            variableRateToken.balanceOf(address(this)) * 10 ** 30
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
    //struct MintOrBurnParams {
    //    address marginEngine;
   //     int24 tickLower;
    //    int24 tickUpper;
        uint256 notional;
    //    bool isMint;
    //    uint256 marginDelta;
    //}

    function getUnderlyingTokenOfMarginEngine() public returns(address me){
        return address(IMarginEngine(marginEngine).underlyingToken());
    }
    uint256 public endTimestamp;
    function getEndTimestamp() public {
        endTimestamp = IMarginEngine(marginEngine).termEndTimestampWad();
    }
    function provideLiquidityApproval(uint amount) public {
        IERC20(underlyingToken).approve(marginEngine, amount);
        IERC20(underlyingToken).approve(periphery, amount);
     }

    function provideLiquidity(uint amount, uint amount2) public returns (bool success){

        IPeriphery.MintOrBurnParams memory mobp;
        mobp = IPeriphery.MintOrBurnParams(IMarginEngine(marginEngine),
                                                    -60,
                                                    60,
                                                    amount,
                                                    true,
                                                    amount2);
        IPeriphery(periphery).mintOrBurn(mobp);
        //bytes memory data = abi.encodeWithSignature("mintOrBurn((address,int24,int24,uint256,bool,uint256))", params);
        //(bool success,) = periphery.call(data);
        //return success;
        //require(success,"deadbeaf");
    }

    // @notice Interact with Voltz 
    function execute() public  {
        uint amount = variableRateToken.balanceOf(address(this));
        IERC20(variableRateToken).approve(fcm, amount);

        fcm.call{value: 0}(
            abi.encodeWithSignature("initiateFullyCollateralisedFixedTakerSwap(uint256,uint160)",
            variableRateToken.balanceOf(address(this)),
             MAX_SQRT_RATIO - 1));
        require(variableRateToken.balanceOf(address(this)) == 0, "No Success");


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
        fcm.call{value: 0}(abi.encodeWithSignature("settleTrader()"));

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
        underlyingToken.transferFrom(msg.sender, address(this), amount);
 
        // Convert different denominations (6 <- 18)
        uint mintAmount = amount * 1e12;

        // Approve AAve to spend the underlying token
        underlyingToken.approve(address(AAVE), amount);

        // Calculate deposit rate
        uint256 finalAmount = mintAmount / cRate * 1e18;

        // Deposit to Aave
        uint aave_t0 = variableRateToken.balanceOf(address(this));
        AAVE.deposit(address(underlyingToken), amount, address(this), 0);
        uint aave_t1 = variableRateToken.balanceOf(address(this));
        require(aave_t1 - aave_t0 == amount, "Aave deposit failed;");

        JVUSDC.adminMint(msg.sender, finalAmount);      
    }

    // @notice Initiate withdraw from AAVE Lending Pool and pay back jvUSDC
    // @param  Amount of yvUSDC to redeem as USDC
    // TODO: remove hardcoded decimals
    function withdraw(uint256 amount) public  {
        // Convert different denominations (6 -> 18)
        uint256 withdrawAmount = amount / 1e12;
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

    // @notice Fallback that ignores calls from jvUSDC
    // @notice Calls from jvUSDC happen when user deposits
    fallback() external {
        if (msg.sender == address(JVUSDC)) {
            revert("No known function targeted");
        }
    }
}
