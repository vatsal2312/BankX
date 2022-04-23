// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

import "./SafeMath.sol";


library XSDPoolLibrary {
    using SafeMath for uint256;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;

    // ================ Structs ================
    // Needed to lower stack size
    struct MintFF_Params {
        uint256 bankx_price_usd; 
        uint256 col_price_usd;
        uint256 bankx_amount;
        uint256 collateral_amount;
        uint256 col_ratio;
    }

    struct BuybackBankX_Params {
        uint256 excess_collateral_dollar_value_d18;
        uint256 bankx_price_usd;
        uint256 col_price_usd;
        uint256 BankX_amount;
    }



    // ================ Functions ================

    function calcMint1t1XSD(uint256 col_price, uint256 collateral_amount_d18) public pure returns (uint256) {
        return (collateral_amount_d18.mul(col_price)).div(1e6);
    }

    function calcMintAlgorithmicXSD(uint256 bankx_price_usd, uint256 bankx_amount_d18) public pure returns (uint256) {
        return bankx_amount_d18.mul(bankx_price_usd).div(1e6);
    }
//new-code-start
    function calcMintInterest(uint256 XSD_amount,uint256 rate, uint256 accum_interest, uint256 interest_rate, uint256 time, uint256 amount) internal view returns(uint256, uint256, uint256, uint256) {
        if(time == 0){
        interest_rate = rate;
        amount = XSD_amount;
        time = block.timestamp;
        }
        else{
        uint delta_t = block.timestamp - time;
        delta_t = delta_t.div(86400); //1 day = 86400
        accum_interest = accum_interest.add((amount.mul(interest_rate).mul(delta_t)).div(365));
        interest_rate = (amount.mul(interest_rate)) + (XSD_amount.mul(rate));//interest rate calculation must be added
        amount = amount.add(XSD_amount);
        time = block.timestamp;
        }
        return (
            accum_interest,
            interest_rate,
            time, 
            amount
        );
    }

    function calcRedemptionInterest(uint256 XSD_amount, uint256 accum_interest, uint256 interest_rate, uint256 time, uint256 amount, uint256 perXSD) internal view returns(uint256, uint256, uint256, uint256, uint256){
        uint delta_t = block.timestamp - time;
        delta_t = delta_t.div(86400);
        accum_interest = accum_interest.add((amount.mul(interest_rate).mul(delta_t)).div(365));
        amount = amount - XSD_amount;
        time = block.timestamp;
        perXSD = accum_interest.div(amount);
        return (
            accum_interest,
            interest_rate,
            time, 
            amount,
            perXSD
        );
    }
    //new-code-end
    // Must be internal because of the struct
    function calcMintFractionalXSD(MintFF_Params memory params) internal pure returns (uint256, uint256) {
        // Since solidity truncates division, every division operation must be the last operation in the equation to ensure minimum error
        // The contract must check the proper ratio was sent to mint XSD. We do this by seeing the minimum mintable XSD based on each amount 
        uint256 bankx_dollar_value_d18;
        uint256 c_dollar_value_d18;
        
        // Scoping for stack concerns
        {    
            // USD amounts of the collateral and the BankX
            bankx_dollar_value_d18 = params.bankx_amount.mul(params.bankx_price_usd).div(1e6);
            c_dollar_value_d18 = params.collateral_amount.mul(params.col_price_usd).div(1e6);

        }
        uint calculated_bankx_dollar_value_d18 = 
                    (c_dollar_value_d18.mul(1e6).div(params.col_ratio))
                    .sub(c_dollar_value_d18);

        uint calculated_bankx_needed = calculated_bankx_dollar_value_d18.mul(1e6).div(params.bankx_price_usd);

        return (
            c_dollar_value_d18.add(calculated_bankx_dollar_value_d18),
            calculated_bankx_needed
        );
    }

    function calcRedeem1t1XSD(uint256 col_price_usd, uint256 XSD_amount) public pure returns (uint256) {
        return XSD_amount.mul(1e6).div(col_price_usd);
    }

    // Must be internal because of the struct
    function calcBuyBackBankX(BuybackBankX_Params memory params) internal pure returns (uint256) {
        // If the total collateral value is higher than the amount required at the current collateral ratio then buy back up to the possible BankX with the desired collateral
        require(params.excess_collateral_dollar_value_d18 > 0, "No excess collateral to buy back!");

        // Make sure not to take more than is available
        uint256 bankx_dollar_value_d18 = params.BankX_amount.mul(params.bankx_price_usd).div(1e6);
        require(bankx_dollar_value_d18 <= params.excess_collateral_dollar_value_d18, "You are trying to buy back more than the excess!");

        // Get the equivalent amount of collateral based on the market value of BankX provided 
        uint256 collateral_equivalent_d18 = bankx_dollar_value_d18.mul(1e6).div(params.col_price_usd);
        //collateral_equivalent_d18 = collateral_equivalent_d18.sub((collateral_equivalent_d18.mul(params.buyback_fee)).div(1e6));

        return (
            collateral_equivalent_d18
        );

    }


    // Returns value of collateral that must increase to reach recollateralization target (if 0 means no recollateralization)
    function recollateralizeAmount(uint256 total_supply, uint256 global_collateral_ratio, uint256 global_collat_value) public pure returns (uint256) {
        uint256 target_collat_value = total_supply.mul(global_collateral_ratio).div(1e6); // We want 18 decimals of precision so divide by 1e6; total_supply is 1e18 and global_collateral_ratio is 1e6
        // Subtract the current value of collateral from the target value needed, if higher than 0 then system needs to recollateralize
        return target_collat_value.sub(global_collat_value); // If recollateralization is not needed, throws a subtraction underflow
        // return(recollateralization_left);
    }

    function calcRecollateralizeXSDInner(
        uint256 collateral_amount, 
        uint256 col_price,
        uint256 global_collat_value,
        uint256 xsd_total_supply,
        uint256 global_collateral_ratio
    ) public pure returns (uint256, uint256) {
        uint256 collat_value_attempted = collateral_amount.mul(col_price).div(1e6);
        uint256 effective_collateral_ratio = global_collat_value.mul(1e6).div(xsd_total_supply); //returns it in 1e6
        uint256 recollat_possible = (global_collateral_ratio.mul(xsd_total_supply).sub(xsd_total_supply.mul(effective_collateral_ratio))).div(1e6);

        uint256 amount_to_recollat;
        if(collat_value_attempted <= recollat_possible){
            amount_to_recollat = collat_value_attempted;
        } else {
            amount_to_recollat = recollat_possible;
        }

        return (amount_to_recollat.mul(1e6).div(col_price), amount_to_recollat);

    }

}
