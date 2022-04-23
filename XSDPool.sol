// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;


import "../../Math/SafeMath.sol";
import '../../Uniswap/TransferHelper.sol';
import "../../Staking/Owned.sol";
import "../../BankX/BankX.sol";
import "../../XSD/XSD.sol";
import '../../Oracle/Interfaces/IPIDController.sol';
import "../../ERC20/ERC20.sol";
import "../../Governance/AccessControl.sol";
import "./XSDPoolLibrary.sol";

contract XSDPool is AccessControl, Owned {
    using SafeMath for uint256;
    

    /* ========== STATE VARIABLES ========== */

    ERC20 private collateral_token;
    address private collateral_address;

    address public smartcontract_owner = 0xC34faEea3605a168dBFE6afCd6f909714F844cd7;
    address private xsd_contract_address;
    address private bankx_contract_address;
    address private pid_address;
    address private timelock_address;
    BankXToken private BankX;
    XSDStablecoin private XSD;
    IPIDController pid_controller;

    address private weth_address;
    struct MintInfo {
        uint256 accum_interest;
        uint256 interest_rate;
        uint256 time;
        uint256 amount;
        uint256 perXSD;
    }
    mapping(address=>MintInfo) mintMapping;
    mapping (address => uint256) public redeemBankXBalances;
    mapping (address => uint256) public redeemCollateralBalances;
    mapping (address => uint256) public redeemXSDBalances;
    mapping (address => uint256) public vestingtimestamp;
    uint256 public unclaimedPoolCollateral;
    uint256 public unclaimedPoolBankX;
    mapping (address => uint256) public lastRedeemed;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;

    // Number of decimals needed to get to 18
    uint256 private immutable missing_decimals;
    
    // Pool_ceiling is the total units of collateral that a pool contract can hold
    uint256 public pool_ceiling;

    // Stores price of the collateral, if price is paused
    uint256 public pausedPrice;

    // Bonus rate on BankX minted during recollateralizeXSD(); 6 decimals of precision, set to 0.75% on genesis
    //check if there's no bonus rate
    uint256 public amountpaid;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public redemption_delay = 1;
    // AccessControl Roles
    bytes32 private constant MINT_PAUSER = keccak256("MINT_PAUSER");
    bytes32 private constant REDEEM_PAUSER = keccak256("REDEEM_PAUSER");
    bytes32 private constant BUYBACK_PAUSER = keccak256("BUYBACK_PAUSER");
    bytes32 private constant RECOLLATERALIZE_PAUSER = keccak256("RECOLLATERALIZE_PAUSER");
    bytes32 private constant COLLATERAL_PRICE_PAUSER = keccak256("COLLATERAL_PRICE_PAUSER");
    
    // AccessControl state variables
    bool public mintPaused = false;
    bool public redeemPaused = false;
    bool public recollateralizePaused = false;
    bool public buyBackPaused = false;
    bool public collateralPricePaused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier notRedeemPaused() {
        require(redeemPaused == false, "Redeeming is paused");
        _;
    }

    modifier notMintPaused() {
        require(mintPaused == false, "Minting is paused");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */
    
    constructor(
        address _xsd_contract_address,
        address _bankx_contract_address,
        address _collateral_address,
        address _timelock_address,
        uint256 _pool_ceiling
    ) public Owned(smartcontract_owner){
        require(
            (_xsd_contract_address != address(0))
            && (_bankx_contract_address != address(0))
            && (_collateral_address != address(0))
            && (_timelock_address != address(0))
        , "Zero address detected"); 
        XSD = XSDStablecoin(_xsd_contract_address);
        BankX = BankXToken(_bankx_contract_address);
        xsd_contract_address = _xsd_contract_address;
        bankx_contract_address = _bankx_contract_address;
        collateral_address = _collateral_address;
        timelock_address = _timelock_address;
        collateral_token = ERC20(_collateral_address);
        pool_ceiling = _pool_ceiling;
        missing_decimals = uint(18).sub(collateral_token.decimals());
        
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        grantRole(MINT_PAUSER, timelock_address);
        grantRole(REDEEM_PAUSER, timelock_address);
        grantRole(RECOLLATERALIZE_PAUSER, timelock_address);
        grantRole(BUYBACK_PAUSER, timelock_address);
        grantRole(COLLATERAL_PRICE_PAUSER, timelock_address);
    }

    /* ========== VIEWS ========== */

    // Returns dollar value of collateral held in this XSD pool
    function collatDollarBalance() public view returns (uint256) {
        if(collateralPricePaused == true){
            return (collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral)).mul(10 ** missing_decimals).mul(pausedPrice).div(PRICE_PRECISION);
        } else {
            uint256 eth_usd_price = 3252;//XSD.eth_usd_price();
            return (collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral)).mul(10 ** missing_decimals).mul(eth_usd_price).div(PRICE_PRECISION);     
        }   
    }

    // Returns the value of excess collateral held in this XSD pool, compared to what is needed to maintain the global collateral ratio
    function availableExcessCollatDV() public returns (uint256) {
        uint256 total_supply = XSD.totalSupply();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();
        uint256 global_collat_value = XSD.globalCollateralValue();

        if (global_collateral_ratio > COLLATERAL_RATIO_PRECISION) global_collateral_ratio = COLLATERAL_RATIO_PRECISION; // Handles an overcollateralized contract with CR > 1
        uint256 required_collat_dollar_value_d18 = (total_supply.mul(global_collateral_ratio)).div(COLLATERAL_RATIO_PRECISION); // Calculates collateral needed to back each 1 XSD with $1 of collateral at current collat ratio
        if (global_collat_value > required_collat_dollar_value_d18) return global_collat_value.sub(required_collat_dollar_value_d18);
        else return 0;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    //new-code-start
    // We separate out the 1t1, fractional and algorithmic minting functions for gas efficiency 
    function mint1t1XSD(uint256 collateral_amount, uint256 XSD_out_min) external notMintPaused {
        require(collateral_amount>0, "Invalid collateral amount");
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);

        require(XSD.global_collateral_ratio() >= COLLATERAL_RATIO_MAX, "Collateral ratio must be >= 1");
        require((collateral_token.balanceOf(address(this))).sub(unclaimedPoolCollateral).add(collateral_amount) <= pool_ceiling, "[Pool's Closed]: Ceiling reached");
        
        (uint256 xsd_amount_d18) = XSDPoolLibrary.calcMint1t1XSD(
            XSD.eth_usd_price(),
            collateral_amount_d18
        ); //1 XSD for each $1 worth of collateral
        require(XSD_out_min <= xsd_amount_d18, "Slippage limit reached");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount) = XSDPoolLibrary.calcMintInterest(xsd_amount_d18, XSD.getInterestRate(), mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount);
        TransferHelper.safeTransferFrom(address(collateral_token), msg.sender, address(this), collateral_amount);
        XSD.pool_mint(msg.sender, xsd_amount_d18);
    }

    // 0% collateral-backed
    function mintAlgorithmicXSD(uint256 bankx_amount_d18, uint256 XSD_out_min) external notMintPaused {
        uint256 bankx_price = XSD.bankx_price();
        uint256 xag_usd_price = XSD.xag_usd_price();
        require(XSD.global_collateral_ratio() == 0, "Collateral ratio must be 0");
        (uint256 xsd_amount_d18) = XSDPoolLibrary.calcMintAlgorithmicXSD(
            bankx_price, // X BankX / 1 USD
            bankx_amount_d18
        );
        xsd_amount_d18 = xsd_amount_d18.div(xag_usd_price).mul(283495).div(1e4);
        require(XSD_out_min <= xsd_amount_d18, "Slippage limit reached");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount) = XSDPoolLibrary.calcMintInterest(xsd_amount_d18, XSD.getInterestRate(), mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount);
        BankX.pool_burn_from(msg.sender, bankx_amount_d18);
        XSD.pool_mint(msg.sender, xsd_amount_d18);
    }

    // Will fail if fully collateralized or fully algorithmic
    // > 0% and < 100% collateral-backed
    function mintFractionalXSD(uint256 collateral_amount, uint256 bankx_amount, uint256 XSD_out_min) external notMintPaused {
        uint256 bankx_price = XSD.bankx_price();
        uint256 xag_usd_price = XSD.xag_usd_price();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        require(collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral).add(collateral_amount) <= pool_ceiling, "Pool ceiling reached, no more XSD can be minted with this collateral");

        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        XSDPoolLibrary.MintFF_Params memory input_params = XSDPoolLibrary.MintFF_Params(
            bankx_price,
            XSD.eth_usd_price(),
            bankx_amount,
            collateral_amount_d18,
            global_collateral_ratio
        );

        (uint256 mint_amount, uint256 bankx_needed) = XSDPoolLibrary.calcMintFractionalXSD(input_params);
        mint_amount = mint_amount.div(xag_usd_price).mul(283495).div(1e4);
        require(XSD_out_min <= mint_amount, "Slippage limit reached");
        require(bankx_needed <= bankx_amount, "Not enough BankX inputted");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount) = XSDPoolLibrary.calcMintInterest(mint_amount, XSD.getInterestRate(), mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount);
        BankX.pool_burn_from(msg.sender, bankx_needed);
        TransferHelper.safeTransferFrom(address(collateral_token), msg.sender, address(this), collateral_amount);
        XSD.pool_mint(msg.sender, mint_amount);
    }
    
    //Newly added terra functionality for minting. Users can get 1 XSD per 1$ of bankx (less minting fee and slippage)
    //No requirement for 0 collateral ratio
    function mintTerraXSD(uint256 bankx_amount_d18, uint256 XSD_out_min) external notMintPaused {
        uint256 bankx_price = XSD.bankx_price();
        uint256 xag_usd_price = XSD.xag_usd_price();
        
        (uint256 xsd_amount_d18) = XSDPoolLibrary.calcMintAlgorithmicXSD(
            bankx_price, // X BankX / 1 USD
            bankx_amount_d18
        ).div(xag_usd_price).mul(283495).div(1e4);
        require(XSD_out_min <= xsd_amount_d18, "Slippage limit reached");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount) = XSDPoolLibrary.calcMintInterest(xsd_amount_d18, XSD.getInterestRate(), mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount);
        BankX.pool_burn_from(msg.sender, bankx_amount_d18);
        XSD.pool_mint(msg.sender, xsd_amount_d18);
    }

    //incase of deficit
    function provideLiquidity(address to, uint amount1) external notMintPaused {
        require(pid_controller.bucket3(), "There is no deficit detected");
        uint ethvalue = amount1.mul(XSD.eth_usd_price());
        uint difference = pid_controller.diff3();
        redeemBankXBalances[to] = redeemBankXBalances[to].add(ethvalue.mul(7)).div(100);
        if(amountpaid<difference.div(3)){
            redeemXSDBalances[to] = redeemXSDBalances[to].add(ethvalue.div(20));
            vestingtimestamp[to] = block.timestamp.add(604800);
        }
        else if(amountpaid<(difference.mul(2)).div(3)){
            redeemXSDBalances[to] = redeemXSDBalances[to].add(ethvalue.div(50));
            vestingtimestamp[to] = block.timestamp.add(1209600);
        }
        else{
            vestingtimestamp[to] = block.timestamp.add(1814400);
        }
        amountpaid = amountpaid.add(ethvalue);
        //emit provideLiquidity2(to, amount1);
    }

    // Redeem collateral. 100% collateral-backed
    function redeem1t1XSD(uint256 XSD_amount, uint256 COLLATERAL_out_min) external notRedeemPaused {
        require(XSD.global_collateral_ratio() == COLLATERAL_RATIO_MAX, "Collateral ratio must be == 1");

        // Need to adjust for decimals of collateral
        uint256 XSD_amount_precision = XSD_amount.div(10 ** missing_decimals);
        (uint256 collateral_needed) = XSDPoolLibrary.calcRedeem1t1XSD(
            XSD.eth_usd_price(),
            XSD_amount_precision
        );
        require(collateral_needed <= collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_needed, "Slippage limit reached");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD)=XSDPoolLibrary.calcRedemptionInterest(XSD_amount, mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD);
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(mintMapping[msg.sender].accum_interest);
        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_needed);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_needed);
        lastRedeemed[msg.sender] = block.number;
        unclaimedPoolBankX = unclaimedPoolBankX.add(mintMapping[msg.sender].accum_interest);
        // Move all external functions to the end
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), mintMapping[msg.sender].accum_interest);
    }

    // Will fail if fully collateralized or algorithmic
    // Redeem XSD for collateral and BankX. > 0% and < 100% collateral-backed
    function redeemFractionalXSD(uint256 XSD_amount, uint256 BankX_out_min, uint256 COLLATERAL_out_min) external notRedeemPaused {
        uint256 bankx_price = XSD.bankx_price();
        uint256 xag_usd_price = XSD.xag_usd_price();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        uint256 col_price_usd = XSD.eth_usd_price();

        uint256 bankx_dollar_value_d18 = XSD_amount.sub(XSD_amount.mul(global_collateral_ratio).div(PRICE_PRECISION));
        bankx_dollar_value_d18 = bankx_dollar_value_d18.mul(xag_usd_price).div(283495).mul(1e4);
        uint256 bankx_amount = bankx_dollar_value_d18.mul(PRICE_PRECISION).div(bankx_price);

        // Need to adjust for decimals of collateral
        uint256 XSD_amount_precision = XSD_amount.div(10 ** missing_decimals);
        uint256 collateral_dollar_value = XSD_amount_precision.mul(global_collateral_ratio).div(PRICE_PRECISION);
        uint256 collateral_amount = collateral_dollar_value.mul(PRICE_PRECISION).div(col_price_usd);


        require(collateral_amount <= collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_amount, "Slippage limit reached [collateral]");
        require(BankX_out_min <= bankx_amount, "Slippage limit reached [BankX]");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_amount);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_amount);

        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(bankx_amount);
        unclaimedPoolBankX = unclaimedPoolBankX.add(bankx_amount).add(mintMapping[msg.sender].accum_interest);

        lastRedeemed[msg.sender] = block.number;
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD) = XSDPoolLibrary.calcRedemptionInterest(XSD_amount, mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD);
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(mintMapping[msg.sender].accum_interest);
        // Move all external functions to the end
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), bankx_amount.add(mintMapping[msg.sender].accum_interest));
    }

    // Redeem XSD for BankX. 0% collateral-backed
    function redeemAlgorithmicXSD(uint256 XSD_amount, uint256 BankX_out_min) external notRedeemPaused {
        uint256 bankx_price = XSD.bankx_price();
        uint256 xag_usd_price = XSD.xag_usd_price();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();
        

        require(global_collateral_ratio == 0, "Collateral ratio must be 0"); 
        uint256 bankx_dollar_value_d18 = XSD_amount.mul(xag_usd_price).div(283495).mul(1e4);

        uint256 bankx_amount = bankx_dollar_value_d18.mul(PRICE_PRECISION).div(bankx_price);
        
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(bankx_amount);
        unclaimedPoolBankX = unclaimedPoolBankX.add(bankx_amount).add(mintMapping[msg.sender].accum_interest);
        
        lastRedeemed[msg.sender] = block.number;
        
        require(BankX_out_min <= bankx_amount, "Slippage limit reached");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD) = XSDPoolLibrary.calcRedemptionInterest(XSD_amount, mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD);
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(mintMapping[msg.sender].accum_interest);
        // Move all external functions to the end
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), bankx_amount.add(mintMapping[msg.sender].accum_interest));
    }
    
    // Newly added Terra capability. Redeem 1 XSD for 1$ BankX regardless of collateralization
    function redeemTerraXSD(uint256 XSD_amount, uint256 BankX_out_min) external notRedeemPaused {
        uint256 bankx_price = XSD.bankx_price();
        uint256 xag_usd_price = XSD.xag_usd_price();

        uint256 bankx_dollar_value_d18 = XSD_amount.mul(xag_usd_price).div(283495).mul(1e4);

        uint256 bankx_amount = bankx_dollar_value_d18.mul(PRICE_PRECISION).div(bankx_price);
        
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(bankx_amount);
        unclaimedPoolBankX = unclaimedPoolBankX.add(bankx_amount).add(mintMapping[msg.sender].accum_interest);
        
        lastRedeemed[msg.sender] = block.number;
        
        require(BankX_out_min <= bankx_amount, "Slippage limit reached");
        (mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD) = XSDPoolLibrary.calcRedemptionInterest(XSD_amount, mintMapping[msg.sender].accum_interest, mintMapping[msg.sender].interest_rate, mintMapping[msg.sender].time, mintMapping[msg.sender].amount, mintMapping[msg.sender].perXSD);
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender].add(mintMapping[msg.sender].accum_interest);
        // Move all external functions to the end
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), bankx_amount.add(mintMapping[msg.sender].accum_interest));
    }
    //new-code-end
    // After a redemption happens, transfer the newly minted BankX and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out XSD/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    function collectRedemption() external {
        require((lastRedeemed[msg.sender].add(redemption_delay)) <= block.number, "Must wait for redemption_delay blocks before collecting redemption");
        //require(redeemCollateralBalances[msg.sender]< , "Not enough collateral in the pool");
        //check for bucket and revert if there is a deficit.
        // add address parameter
        require(!pid_controller.bucket3(), "Cannot withdraw in times of deficit");
        bool sendBankX = false;
        bool sendCollateral = false;
        bool sendXSD = false;
        uint BankXAmount = 0;
        uint CollateralAmount = 0;
        uint XSDAmount = 0;

        // Use Checks-Effects-Interactions pattern
        if(redeemBankXBalances[msg.sender] > 0){
            BankXAmount = redeemBankXBalances[msg.sender];
            redeemBankXBalances[msg.sender] = 0;
            unclaimedPoolBankX = unclaimedPoolBankX.sub(BankXAmount);

            sendBankX = true;
        }
        
        if(redeemCollateralBalances[msg.sender] > 0){
            CollateralAmount = redeemCollateralBalances[msg.sender];
            redeemCollateralBalances[msg.sender] = 0;
            unclaimedPoolCollateral = unclaimedPoolCollateral.sub(CollateralAmount);

            sendCollateral = true;
        }

        if(redeemXSDBalances[msg.sender] > 0){
            XSDAmount = redeemXSDBalances[msg.sender];
            redeemXSDBalances[msg.sender] = 0;

            sendXSD = true;
        }

        if(sendBankX){
            TransferHelper.safeTransfer(address(BankX), msg.sender, BankXAmount);
        }
        if(sendCollateral){
            TransferHelper.safeTransfer(address(collateral_token), msg.sender, CollateralAmount);
        }
        if(sendXSD && vestingtimestamp[msg.sender]<= block.timestamp){
            TransferHelper.safeTransfer(address(XSD), msg.sender, XSDAmount);
        }
    }


    // When the protocol is recollateralizing, we need to give a discount of BankX to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get BankX for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of BankX + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra BankX value from the bonus rate as an arb opportunity
    function recollateralizeXSD(uint256 collateral_amount, uint256 BankX_out_min) external {
        require(recollateralizePaused == false, "Recollateralize is paused");
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        uint256 bankx_price = XSD.bankx_price();
        uint256 xsd_total_supply = XSD.totalSupply();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();
        uint256 global_collat_value = XSD.globalCollateralValue();

        (uint256 collateral_units, uint256 amount_to_recollat) = XSDPoolLibrary.calcRecollateralizeXSDInner(
            collateral_amount_d18,
            XSD.eth_usd_price(),
            global_collat_value,
            xsd_total_supply,
            global_collateral_ratio
        ); 

        uint256 collateral_units_precision = collateral_units.div(10 ** missing_decimals);

        uint256 bankx_paid_back = amount_to_recollat.div(bankx_price);

        require(BankX_out_min <= bankx_paid_back, "Slippage limit reached");
        TransferHelper.safeTransferFrom(address(collateral_token), msg.sender, address(this), collateral_units_precision);
        BankX.pool_mint(msg.sender, bankx_paid_back);
        
    }

    /* ========== RESTRICTED FUNCTIONS ========== 

    function toggleMinting() external {
        require(hasRole(MINT_PAUSER, msg.sender));
        mintPaused = !mintPaused;

        emit MintingToggled(mintPaused);
    }

    function toggleRedeeming() external {
        require(hasRole(REDEEM_PAUSER, msg.sender));
        redeemPaused = !redeemPaused;

        emit RedeemingToggled(redeemPaused);
    }

    function toggleRecollateralize() external {
        require(hasRole(RECOLLATERALIZE_PAUSER, msg.sender));
        recollateralizePaused = !recollateralizePaused;

        emit RecollateralizeToggled(recollateralizePaused);
    }
    
    function toggleBuyBack() external {
        require(hasRole(BUYBACK_PAUSER, msg.sender));
        buyBackPaused = !buyBackPaused;

        emit BuybackToggled(buyBackPaused);
    }

    function toggleCollateralPrice(uint256 _new_price) external {
        require(hasRole(COLLATERAL_PRICE_PAUSER, msg.sender));
        // If pausing, set paused price; else if unpausing, clear pausedPrice
        if(collateralPricePaused == false){
            pausedPrice = _new_price;
        } else {
            pausedPrice = 0;
        }
        collateralPricePaused = !collateralPricePaused;

        emit CollateralPriceToggled(collateralPricePaused);
    }*/

    // Combined into one function due to 24KiB contract memory limit
    function setPoolParameters(uint256 new_ceiling, uint256 new_redemption_delay) external onlyByOwnerOrGovernance {
        pool_ceiling = new_ceiling;
        redemption_delay = new_redemption_delay;

        emit PoolParametersSet(new_ceiling,new_redemption_delay);
    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    function setPIDController(address new_pid_address) external onlyByOwnerOrGovernance {
        pid_controller = IPIDController(new_pid_address);
        pid_address = new_pid_address;
    }


    /* ========== EVENTS ========== */

    event PoolParametersSet(uint256 new_ceiling, uint256 new_redemption_delay);
    event TimelockSet(address new_timelock);
    event MintingToggled(bool toggled);
    event RedeemingToggled(bool toggled);
    event RecollateralizeToggled(bool toggled);
    event BuybackToggled(bool toggled);
    event CollateralPriceToggled(bool toggled);

}