// SPDX-License-Identifier: Apache-2.0

pragma solidity =0.8.9;

import "./IAAVE.sol";
import "./JointVoltzTUSD.sol";
import "./interfaces/fcms/IAaveFCM.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPeriphery.sol";
import "./interfaces/IMarginEngine.sol";
import "./interfaces/fcms/IFCM.sol";
import "./core_libraries/Time.sol";
import "./interfaces/rate_oracles/IRateOracle.sol";
import "./interfaces/IVAMM.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

contract VoltzStablecoin is Ownable {
    using PRBMathSD59x18 for int256;
    using PRBMathUD60x18 for uint256;
    uint160 constant MIN_SQRT_RATIO = 2503036416286949174936592462;
    uint160 constant MAX_SQRT_RATIO = 2507794810551837817144115957740;
    uint256 constant MAX_FEE = 2e16;
    uint256 constant SENCONDS_PER_YEAR = 31536000e18;

    address fcm;
    address marginEngine;
    address factory;
    address periphery;
    uint public maturity;
    uint public endTimestamp;

    IERC20 public variableRateToken; // ATUSD
    IERC20 public underlyingToken; // TUSD
    JointVaultTUSD public JVTUSD; // JVTUSD 
    IAAVE public AAVE;
    IRateOracle public rateOracle;
    IVAMM public vamm;

    event Payout(address beneficiary, 
                 int256 amount);

    event SwapResult(int fixedTokenDelta, 
                     int variableTokenDelta, 
                     uint fee,
                     int fixedTokenDeltaUnbalanced, 
                     uint rate,
                     uint secondsWeiToMaturity);

     event Interests(uint fixedTokenDelta);

    constructor(

    ) {
        // Deploy JVTUSD token
        JVTUSD = new JointVaultTUSD("Joint Vault TUSD", "jvTUSD"); 

        // Voltz contracts
        // Topic for new pools: 0xe134804702afa0f02bd7f0687d4c2f662a1790b4904d1c2cd6f41fcffbfc05c3
        factory = 0x71b5020bF90327F2241Cc7D66B60C72CEf9cC39b;
        //periphery = IPeriphery(factory.periphery());
        periphery = 0xcf0144e092f2B80B11aD72CF87C71d1090F97746;

        fcm = 0x4Cc36Eb58019bc679997035A161a4F1165e97Ef1;
        marginEngine = 0x15907812Fc62e953fef8441D7594031798E66cCD;
        
        rateOracle = IRateOracle(IMarginEngine(marginEngine).rateOracle());
        vamm = IVAMM(IMarginEngine(marginEngine).vamm());

        // Token contracts
        variableRateToken = IERC20(0x39914AdBe5fDbC2b9ADeedE8Bcd444b20B039204);
        //underlyingToken = IERC20(0x016750AC630F711882812f24Dba6c95b9D35856d);
        underlyingToken = IERC20(address(IMarginEngine(marginEngine).underlyingToken()));

        // Aave contracts
        //AAVE = IAAVE(0xE0fBa4Fc209b4948668006B2bE61711b7f465bAe);
        AAVE = IAAVE(address(IAaveFCM(fcm).aaveLendingPool()));
    }
    
    // @notice Initiate deposit to AAVE Lending Pool and receive jvTUSD
    // @param  Amount of TUSD to deposit to AAVE
    function deposit(uint256 amount) public  {
        require(underlyingToken.allowance(msg.sender, address(this)) >= amount, "Approve contract first");
        underlyingToken.transferFrom(msg.sender, address(this), amount);
        require(underlyingToken.balanceOf(address(this)) >= amount, "Not enough TUSD");

        // Calculate the approximate fee
        uint maxFee = getVoltzFee(amount);
        
        amount -= maxFee;

        // Approve Aave to spend the underlying token
        underlyingToken.approve(address(AAVE), 1e27);
        underlyingToken.approve(fcm, 1e27);

        // Deposit to Aave
        AAVE.deposit(address(underlyingToken), amount, address(this), 0);
        require(variableRateToken.balanceOf(address(this)) > 0, "Aave deposit failed");

        // Enter Voltz FT position
        (uint rate, uint secondsWeiToMaturity, uint fee) = enterFTPosition(amount);
        require(fee <= maxFee, "Fees for swap too high");

        uint ratePerSecondToMaturity = (rate * secondsWeiToMaturity) / SENCONDS_PER_YEAR;

         // Calculate deposit rate 
         // @ notice Divided by 1e11 because *1e9 earlier
        uint256 interests = (amount * ratePerSecondToMaturity) / 1e11;

        // Mint jvTUSD
        JVTUSD.adminMint(msg.sender, amount + interests); 

        // Return not needed fee to user
        uint payback = maxFee - fee;
        underlyingToken.transfer(msg.sender, payback);     
    }


    function enterFTPosition(uint amount) internal returns(uint rate, uint secondsWeiToMaturity, uint fee)  {
        IERC20(variableRateToken).approve(fcm, amount);

        // int256 fixedTokenDelta,int256 variableTokenDelta, ,int256 fixedTokenDeltaUnbalanced, 
        (int _a, int _b, uint _fee, int _d) = IFCM(fcm).initiateFullyCollateralisedFixedTakerSwap(amount, MAX_SQRT_RATIO - 1);
        maturity = IMarginEngine(marginEngine).termEndTimestampWad();
        secondsWeiToMaturity = maturity - (block.timestamp*1e18);
        //  fixedTokenDeltaUnbalanced * 1e9 / variableTokenDelta * -1
        rate = uint(_d*1e9/(_b*-1));
        emit SwapResult(_a,_b,_fee,_d,rate,secondsWeiToMaturity);
        return (rate, secondsWeiToMaturity, _fee);
    }


    // When maturity is reached - settle contract
    function settle() public  {
        require(windowIsClosed(), "Maturity not reached");
        // Get ATUSD and TUSD from Voltz position
        int delta = IFCM(fcm).settleTrader();
        emit Payout(address(this), delta);

        // Convert TUSD to ATUSD
        uint256 underlyingTokenBalance = underlyingToken.balanceOf(address(this));

        if (underlyingTokenBalance > 0) {
            underlyingToken.approve(address(AAVE), underlyingTokenBalance);
            AAVE.deposit(address(underlyingToken), underlyingTokenBalance, address(this), 0);
        }
    }


    // @notice Initiate withdraw from AAVE Lending Pool and pay back jvTUSD
    // @param  Amount of jvTUSD to redeem as TUSD
    function withdraw(uint256 amount) public  {

        // Burn jvTUSD tokens from this contract
        JVTUSD.adminBurn(msg.sender, amount);

        // Update payout amount
        uint256 wa = AAVE.withdraw(address(underlyingToken), amount, address(this));
        require(wa >= amount, "Not enough collateral");

        // Transfer TUSD back to the user
        underlyingToken.transfer(msg.sender, amount);
    }

    // @notice Receive this contracts TUSD balance
    function contractBalanceTUSD() public view returns (uint256){
        return underlyingToken.balanceOf(address(this));      
    }

    // @notice Receive this contracts aTUSD balance
    function contractBalanceATUSD() public view returns (uint256){
        return variableRateToken.balanceOf(address(this));      
    }

    // @notice Receive this contracts jvTUSD balance
    function contractBalanceJVTUSD() public view returns (uint256){
        return JVTUSD.balanceOf(address(this));      
    }

    function timeToMaturityInYearsWad() internal view returns (uint) {
        uint timeToMaturity = getEndTimestampWad() - (block.timestamp * 1e18);
        return timeToMaturity.div(SENCONDS_PER_YEAR); 
    }

    function getEndTimestampWad() internal view returns(uint endTimestampWad) {
        return IMarginEngine(marginEngine).termEndTimestampWad();
    }
    
    function windowIsClosed() internal view returns(bool isClosed) {
        return Time.isCloseToMaturityOrBeyondMaturity(getEndTimestampWad());
    }

    function _now() internal view returns (uint){
        return block.timestamp;
    }

    function getVoltzFee(uint amount) internal view returns (uint){
        return (amount * timeToMaturityInYearsWad() * vammFees()) / 1e36;
    }

    function vammFees() internal view returns (uint){
        return vamm.feeWad();
    }

    fallback() external {}

    // Only for testing --> funding if needed
    function provideLiquidity(uint notional, uint marginDelta) public {
        require(underlyingToken.allowance(msg.sender, address(this)) >= notional, "Approve contract first;");
        underlyingToken.transferFrom(msg.sender, address(this), notional);
        IERC20(underlyingToken).approve(periphery, notional);
        IPeriphery.MintOrBurnParams memory mobp;
        mobp = IPeriphery.MintOrBurnParams(IMarginEngine(marginEngine),
                                                    -60,
                                                    60,
                                                    notional,
                                                    true,
                                                    marginDelta);
        IPeriphery(periphery).mintOrBurn(mobp);
    }
}
