// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEvaluator} from "../../../interfaces/IEvaluator.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {EvaluationResult} from "../../../interfaces/Structs.sol";
import {MathLib} from "../../../kernel/libraries/MathLib.sol";
import {Milestone} from "../interfaces/Structs.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract MilestoneBasedEvaluator is IEvaluator {

    error OracleNotSet();
    error InvalidValuationMode();

    address public immutable dac;
    uint256 public immutable dealId;
    address public immutable cell;

    struct Config {
        uint256 rewardShare;                            // e.g. MathLib.atScale(70) (70% of total rewards)
        Milestone[] milestones;
    }

    Config public config;

    // Stateful tracking
    uint256 public unlockedRewards;

    // Per-milestone state
    mapping(uint256 => bool) public evaluated;
    mapping(address => uint256) public snapshotPrice;   // oracle snapshot at creation

    constructor(
        address _dac,
        uint256 _dealId,
        address _cell,
        bytes memory _configData
    ) {
        dac = _dac;
        dealId = _dealId;
        cell = _cell;

        Config memory _config = abi.decode(_configData, (Config));
        config.rewardShare = _config.rewardShare;

        // Take oracle snapshot once at creation
        for (uint256 i = 0; i < _config.milestones.length; i++) {
            Milestone memory m = _config.milestones[i];
            config.milestones.push(m);

            if (m.valuationMode != 2) {
                if (m.valuationMode == 1) {
                    // If mode is `FDV` oracle must be set
                    require(m.oracle != address(0), OracleNotSet());
                }
                else {
                    require(m.valuationMode == 0, InvalidValuationMode());
                }

                // Only need snapshot for `growth` evaluation mode
                continue;
            }

            // If mode is `growth` oracle must be set
            require(m.oracle != address(0), OracleNotSet());

            // Skip if already have snapshot
            if (snapshotPrice[m.token] > 0) continue;

            if (m.oracle != address(0)) {
                snapshotPrice[m.token] = getOraclePrice(m.oracle, m.token);
            }
        }
    }

    function permitMint(address, address, uint256) external pure returns (bool permit) {
        // Basic evaluator will not do any additional authorization for unlocking LP rewards.
        // However it would be a good practice for external modules to allow such a protection.

        // With permitMint implemented evaluator can become an oracle for last-resort protection between
        //  vulnerabilities in the particular Deal contract.
        
        // Basic logic for evaluator - revert any mintLP call, until someone presses the button on the web
        //  and signs with EOA, then there is a 12 hours window, and if no other EOA objects and provide
        //  to an AI agent reasonable claims about a hack in a Deal - evaluator approves the single mint

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                          EVALUATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function evaluateDeal(uint256, address, address, address) external override returns (EvaluationResult[] memory) {
        EvaluationResult[] memory results = new EvaluationResult[](config.milestones.length * 3 + 1);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < config.milestones.length; i++) {
            Milestone memory m = config.milestones[i];
            if (evaluated[i]) continue;

            // progress < MathLib.SCALE
            uint256 progress = calculateProgress(m);

            bool deadlinePassed = block.timestamp >= m.timestamp;
            
            if (progress >= MathLib.SCALE) {
                // Milestone goal fully reached
                uint256 rewardPercent = m.rewardPercentage;

                // Rewards still limited by `rewardShare`
                if (unlockedRewards + rewardPercent > config.rewardShare) {
                    rewardPercent = config.rewardShare - unlockedRewards;
                }

                if (rewardPercent > 0) {
                    results[resultIndex++] = EvaluationResult(1, rewardPercent, 0);
                }
                
                if (m.milestoneType == 1) {
                    results[resultIndex++] = EvaluationResult(3, 0, 0);
                }
            }

            else if (deadlinePassed) {
                if (m.extension > 0 && progress > m.minPercentGrace) {
                    // Allowing extension if target not yet reached and grace enabled

                    config.milestones[i].timestamp = m.timestamp + m.extension;
                    results[resultIndex++] = EvaluationResult(2, 0, block.timestamp + m.extension);

                    // Allowing extension only once if minPercentGrace reached
                    config.milestones[i].extension = 0;

                }
                else {
                    // Unlocking partial reward, calculated by the curve
                    //  can be configured to be very low (or even zero)
                    uint256 rewardPercent = evaluateCurve(m.rewardCurve, progress);
                    if (unlockedRewards + rewardPercent > config.rewardShare) {
                        // Rewards limited by `rewardShare`
                        rewardPercent = config.rewardShare - unlockedRewards;
                    }

                    if (rewardPercent > 0) {
                        rewardPercent = MathLib.mul(rewardPercent, m.rewardPercentage);
                        results[resultIndex++] = EvaluationResult(1, rewardPercent, 0);
                    }

                    // Partial slash, calculated by the curve
                    //  can be configured to be raising quickly, even constant MathLib.SCALE on any miss
                    uint256 penaltyPercent = evaluateCurve(m.penaltyCurve, MathLib.SCALE - progress);
                    if (penaltyPercent > 0) {
                        results[resultIndex++] = EvaluationResult(0, penaltyPercent, 0);
                    }

                    if (m.milestoneType == 1) {
                        // Closing the deal
                        results[resultIndex++] = EvaluationResult(3, 0, 0);
                    }
                }
            }

            else {
                // Not evaluating this milestone yet
                continue;
            }

            evaluated[i] = true;
        }

        assembly { mstore(results, resultIndex) }
        return results;
    }

    function calculateProgress(Milestone memory m) internal view returns (uint256 progress) {
        if (m.valuationMode == 0) {
            // Volume returns mode
            uint256 totalReturnsVolume = IDealCell(cell).getReturnedCapital(m.token);
            totalReturnsVolume += IERC20(m.token).balanceOf(cell);

            if (m.oracle != address(0)) {
                uint256 price = getOraclePrice(m.oracle, m.token);
                totalReturnsVolume = MathLib.mul(totalReturnsVolume, price);
            }

            if (m.fundingToken != address(0)) {
                uint256 investedCapital = IDealCell(cell).getInvestedCapital(m.fundingToken);

                if (m.fundingToken == m.token) {
                    uint256 price = getOraclePrice(m.oracle, m.fundingToken);
                    investedCapital = MathLib.mul(investedCapital, price);
                }

                progress = MathLib.div(totalReturnsVolume, investedCapital);
            }
            else {
                // Funding token not set, assuming m.expectedReturn as monetary target
                //  and comparing it directly to oracle output (or just to balance returned)
                progress = MathLib.div(totalReturnsVolume, m.expectedReturn);
            }
        }
        else if (m.valuationMode == 1) {
            // FDV mode
            require(m.oracle != address(0), OracleNotSet());

            uint256 price = getOraclePrice(m.oracle, m.token);
            uint256 fdv = MathLib.mul(price, IERC20(m.token).totalSupply());

            progress = MathLib.div(fdv, m.expectedReturn);
        }
        else if (m.valuationMode == 2) {
            // Growth valuation mode
            require(m.oracle != address(0), OracleNotSet());
            
            uint256 currentPrice = getOraclePrice(m.oracle, m.token);
            uint256 growth = MathLib.div(currentPrice, snapshotPrice[m.token]);

            progress = MathLib.div(growth, m.expectedReturn);
        }
        else {
            revert InvalidValuationMode();
        }
    }

    function evaluateCurve(int256[] memory coeffs, uint256 progress) internal pure returns (uint256) {
        // casting to 'int256' is safe because progress is a result of division by expected returns
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 x = int256(progress);
        int256 y = coeffs[coeffs.length - 1];
        for (int256 i = int256(coeffs.length) - 2; i >= 0; i--) {
            // casting to 'uint256' is safe because `i` here always > 0
            // forge-lint: disable-next-line(unsafe-typecast)
            y = MathLib.mulDivSigned(y, x, MathLib.SCALE) + coeffs[uint256(i)];
        }
        
        if (y < 0) y = 0;
        // casting to 'uint256' is safe because `y` always > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return MathLib.capAt100(uint256(y));
    }

    // Simple oracle getter (Chainlink or TWAP stub)
    function getOraclePrice(address oracle, address token) internal view returns (uint256) {
        // Oracle should return "normalized" price, with 18 decimal digits
        return IPriceOracle(oracle).tokenPrice(token);
    }
}